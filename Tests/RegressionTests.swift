import Foundation
import Darwin

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure(description: message) }
}

func pump(_ seconds: TimeInterval = 0.15) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

func eventually(_ message: String, timeout: TimeInterval = 2,
                _ condition: () -> Bool) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline { pump(0.02) }
    try expect(condition(), message)
}

final class TestContext {
    let url: URL
    let executable: URL
    let config: AppConfig
    var managers: [TunnelManager] = []
    var fixtures: [Process] = []
    var ownedPids: Set<pid_t> = []

    init(root: URL, executable: URL, name: String, autoStart: Bool = false,
         allTypes: Bool = false) throws {
        self.executable = executable
        try Data("test-only identity placeholder".utf8).write(to: root.appendingPathComponent("key with spaces"))
        url = root.appendingPathComponent(name).appendingPathComponent("config.json")
        let node = NodeConfig(id: "node", name: "Test", host: "isolated-\(name)",
                              identityFile: root.appendingPathComponent("key with spaces").path)
        var tunnels = [TunnelConfig(id: "probe", name: "Probe", nodeId: node.id,
                                   forwards: [ForwardSpec(type: "L", bind: "127.0.0.1", port: "18080", host: "127.0.0.1", rport: "80")],
                                   autoStart: autoStart)]
        if allTypes {
            tunnels.append(TunnelConfig(id: "socks", name: "SOCKS", nodeId: node.id,
                                        forwards: [ForwardSpec(type: "D", port: "18081")], autoStart: autoStart))
            tunnels.append(TunnelConfig(id: "remote", name: "Remote", nodeId: node.id,
                                        forwards: [ForwardSpec(type: "R", port: "18082", host: "127.0.0.1", rport: "80")], autoStart: autoStart))
        }
        config = AppConfig(nodes: [node], tunnels: tunnels)
        try ConfigStore(url: url).save(config)
    }

    var runDir: URL { url.deletingLastPathComponent().appendingPathComponent("run") }
    func pidURL(_ id: String = "probe") -> URL { runDir.appendingPathComponent("\(id).pid") }

    func manager() -> TunnelManager {
        let manager = TunnelManager(configURL: url, sshExecutable: executable)
        managers.append(manager)
        pump(0.35)
        return manager
    }

    func pid(_ id: String = "probe") throws -> pid_t {
        try eventually("Expected a PID file for \(id)", timeout: 4) { FileManager.default.fileExists(atPath: pidURL(id).path) }
        let text = try String(contentsOf: pidURL(id), encoding: .utf8)
        guard let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else {
            throw TestFailure(description: "Invalid test PID")
        }
        ownedPids.insert(pid)
        return pid
    }

    func fixture(args: [String], executable other: URL? = nil) throws -> Process {
        let process = Process()
        process.executableURL = other ?? executable
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        fixtures.append(process)
        return process
    }

    func record(_ pid: pid_t) throws {
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        try String(pid).write(to: pidURL(), atomically: true, encoding: .utf8)
    }

    func cleanup() {
        for manager in managers {
            manager.stopAll()
            manager.prepareForAppExit()
        }
        for fixture in fixtures where fixture.isRunning { fixture.terminate() }
        // 只清理本次测试专用可执行文件的进程，绝不向用户 SSH 进程发信号。
        for pid in ownedPids where kill(pid, 0) == 0 {
            let ps = Process()
            ps.executableURL = URL(fileURLWithPath: "/bin/ps")
            ps.arguments = ["-p", String(pid), "-o", "comm="]
            let pipe = Pipe()
            ps.standardOutput = pipe
            ps.standardError = FileHandle.nullDevice
            if (try? ps.run()) != nil {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                ps.waitUntilExit()
                let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                if path == executable.path { kill(pid, SIGTERM) }
            }
        }
        pump()
    }
}

@main
struct RegressionTests {
    static func main() {
        do {
            try run()
        } catch {
            fflush(stdout)
            fputs("FAIL \(error)\n", stderr)
            exit(1)
        }
    }

    static func run() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let executable = URL(fileURLWithPath: CommandLine.arguments[2])
        if CommandLine.arguments.last == "--exit-owner" {
            let manager = TunnelManager(configURL: root.appendingPathComponent("config.json"), sshExecutable: executable)
            for status in manager.statuses { manager.start(status.id) }
            manager.prepareForAppExit()
            // 真正退出拥有子进程的进程，验证退出不是 stopAll。
            return
        }

        try configFailures(root: root, executable: executable)
        try migration(root: root, executable: executable)
        try privateStorage(root: root, executable: executable)
        try restartRace(root: root, executable: executable)
        try reconnect(root: root, executable: executable)
        try recovery(root: root, executable: executable)
        try exitAndAdopt(root: root, executable: executable)
        try importNodesPreservesTunnels(root: root, executable: executable)
        try projectGroups(root: root, executable: executable)
        try groupPresentation()
        try connectionStates(root: root, executable: executable)
        try diagnosticRetention(root: root, executable: executable)
        print("All regression tests passed (isolated config + mock SSH; no network connections).")
    }

    static func projectGroups(root: URL, executable: URL) throws {
        let context = try TestContext(root: root, executable: executable, name: "project-groups", allTypes: true)
        defer { context.cleanup() }
        var config = context.config
        config.groups = [TunnelGroupConfig(id: "project", name: "项目 A"), TunnelGroupConfig(id: "shared", name: "公共连接")]
        config.tunnels[0].groupId = "project"; config.tunnels[1].groupId = "shared"
        try ConfigStore(url: context.url).save(config)
        var manager = context.manager()
        manager.startGroup("project")
        let firstPID = try context.pid()
        try expect(manager.isOn("probe") && !manager.isOn("socks") && !manager.isOn("remote"),
                   "Starting a project must leave shared and ungrouped tunnels stopped")
        manager.startGroup("shared"); manager.startGroup(nil)
        var pids = try Dictionary(uniqueKeysWithValues: config.tunnels.map { ($0.id, try context.pid($0.id)) })
        try eventually("All group members must establish") { manager.statuses.allSatisfy { $0.state == .running } }
        manager.startGroup("project")
        let repeatedPID = try context.pid()
        try expect(firstPID == repeatedPID, "Starting a group again must retain its running PID")

        let savedBytes = try Data(contentsOf: context.url)
        var invalid = config; invalid.tunnels[0].groupId = "missing"
        do {
            try manager.applyConfig(invalid)
            throw TestFailure(description: "Saving a missing group reference must fail")
        } catch is TestFailure { throw TestFailure(description: "Saving a missing group reference must fail") }
        catch {}
        let retainedBytes = try Data(contentsOf: context.url)
        try expect(manager.current == config && retainedBytes == savedBytes, "Invalid membership must preserve disk and live config")

        config.groups[0].name = "项目 B"; config.tunnels[0].groupId = "shared"
        try manager.applyConfig(config)
        for (id, pid) in pids {
            let retained = try context.pid(id)
            try expect(retained == pid && kill(pid, 0) == 0 && manager.isOn(id),
                       "Renaming and moving groups must preserve running L/R/D PIDs")
        }
        manager.stopGroup("project")
        try expect(config.tunnels.allSatisfy { manager.isOn($0.id) }, "Stopping an old group must use current membership")
        manager.stopGroup("shared")
        try eventually("Shared group members must stop") { kill(pids["probe"]!, 0) != 0 && kill(pids["socks"]!, 0) != 0 }
        try expect(manager.isOn("remote") && kill(pids["remote"]!, 0) == 0,
                   "Stopping one group must retain the ungrouped connection")

        manager.startGroup("shared")
        let retryPID = try context.pid()
        _ = try context.pid("socks")
        kill(retryPID, SIGTERM)
        try eventually("Group member must enter reconnect backoff") { manager.statuses.first { $0.id == "probe" }?.state == .reconnecting }
        manager.stopGroup("shared")
        pump(1.8)
        try expect(!manager.isOn("probe") && !manager.isOn("socks") && manager.isOn("remote") &&
                   !FileManager.default.fileExists(atPath: context.pidURL().path), "Stopping a group must cancel its pending retries")

        manager.startGroup("shared")
        pids = try Dictionary(uniqueKeysWithValues: config.tunnels.map { ($0.id, try context.pid($0.id)) })
        try eventually("Restarted shared members must establish") { manager.statuses.allSatisfy { $0.state == .running } }
        manager.prepareForAppExit()
        manager = context.manager()
        try expect(manager.current == config && config.tunnels.allSatisfy { manager.isOn($0.id) },
                   "Saved group membership must survive startup adoption")
        config.removeGroup("shared")
        try manager.applyConfig(config)
        for (id, pid) in pids {
            let retained = try context.pid(id)
            try expect(retained == pid && manager.isOn(id), "Deleting a group must preserve adopted processes")
        }
        try expect(manager.statuses.allSatisfy { $0.config.groupId == nil }, "Deleted group members must appear ungrouped")
        manager.stopGroup("shared"); manager.startGroup("missing"); manager.stopGroup("missing")
        try expect(config.tunnels.allSatisfy { manager.isOn($0.id) }, "Missing and empty groups must not affect other connections")
        manager.stopGroup(nil)
        try eventually("Stopping ungrouped must stop only its members") { pids.values.allSatisfy { kill($0, 0) != 0 } }
        print("PASS groups: scoped start/stop, repeat start, live move/rename/delete, retry cancellation, invalid-save protection and adoption")
    }

    static func groupPresentation() throws {
        let groups = [TunnelGroupConfig(id: "project", name: "项目"), TunnelGroupConfig(id: "ungrouped", name: "公共连接"),
                      TunnelGroupConfig(id: "empty", name: "空分组")]
        let states: [TunnelState] = [.running, .connecting, .reconnecting, .needsAttention, .unverified, .stopped]
        let items = states.enumerated().map { index, state in
            TunnelPanelItem(id: "t\(index)", name: "Tunnel", nodeName: "Node", forwards: [], state: state,
                            isOn: ![.stopped, .needsAttention].contains(state), groupId: index < 5 ? "project" : nil)
        }
        let sections = TunnelPanelGroup.sections(groups: groups, items: items)
        try expect(sections.map(\.id) == ["group:project", "group:ungrouped", "group:empty", "ungrouped"],
                   "Panel must preserve group order, show empty groups and append ungrouped without ID collisions")
        try expect(sections.flatMap(\.items).count == items.count && sections[0].establishedCount == 1 &&
                   sections[0].attentionCount == 3 && sections[0].canStart && sections[0].canStop,
                   "Partial groups must count confirmed and attention states separately and allow explicit start/stop")
        try expect(!sections[2].canStart && !sections[2].canStop && sections[3].canStart && !sections[3].canStop,
                   "Empty and stopped groups must expose the appropriate operations")
        let collapsed = TunnelGroupCollapseState.toggled("group:ungrouped", in: "[]")
        try expect(TunnelGroupCollapseState.decode(collapsed) == ["group:ungrouped"], "Collapsed groups must round-trip by stable ID")
        try expect(TunnelGroupCollapseState.decode(TunnelGroupCollapseState.toggled("group:ungrouped", in: collapsed)).isEmpty &&
                   TunnelGroupCollapseState.decode("invalid").isEmpty, "Expanding and corrupt local preferences must recover safely")
        print("PASS group presentation: ordered partition, empty groups, partial states, scoped controls and collapse preferences")
    }

    static func importNodesPreservesTunnels(root: URL, executable: URL) throws {
        let context = try TestContext(root: root, executable: executable, name: "ssh-node-import", autoStart: true, allTypes: true)
        defer { context.cleanup() }
        let manager = context.manager()
        let pids = try Dictionary(uniqueKeysWithValues: context.config.tunnels.map { ($0.id, try context.pid($0.id)) })
        let source = context.url.deletingLastPathComponent().appendingPathComponent("ssh-config")
        try "Host imported-a imported-b\n    ProxyJump inherited-jump\n".write(to: source, atomically: true, encoding: .utf8)
        let parsed = try SSHConfigImporter.read(source, home: root)
        var draft = manager.current
        draft.nodes += SSHConfigImporter.nodes(from: parsed.hosts, selected: Set(parsed.hosts.map(\.alias)), existing: draft.nodes)
        try manager.applyConfig(draft)
        pump()
        try expect(manager.current.nodes.count == 3 && manager.current.tunnels == context.config.tunnels,
                   "Saving imported nodes must preserve existing tunnel configurations")
        for (id, originalPID) in pids {
            let currentPID = try context.pid(id)
            try expect(currentPID == originalPID && kill(originalPID, 0) == 0 && manager.isOn(id),
                       "Saving imported nodes must retain each running L/R/D process")
        }
        let reopened = context.manager()
        for (id, originalPID) in pids {
            let currentPID = try context.pid(id)
            try expect(currentPID == originalPID && reopened.isOn(id), "Saved imports must retain adoption on next startup")
        }
        print("PASS saving SSH node imports preserves running L/R/D PIDs and startup adoption")
    }

    static func privateStorage(root: URL, executable: URL) throws {
        func mode(_ url: URL) throws -> Int {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
        }
        let freshURL = root.appendingPathComponent("empty-startup/config.json")
        let fresh = TunnelManager(configURL: freshURL, sshExecutable: executable)
        defer { fresh.prepareForAppExit() }
        try expect(fresh.current.nodes.isEmpty && fresh.current.tunnels.isEmpty && fresh.statuses.isEmpty,
                   "First launch must create an empty configuration without starting a connection")
        let freshDirectoryMode = try mode(freshURL.deletingLastPathComponent())
        let freshFileMode = try mode(freshURL)
        try expect(freshDirectoryMode == 0o700 && freshFileMode == 0o600, "New configuration must be private")

        let context = try TestContext(root: root, executable: executable, name: "private-storage", autoStart: true, allTypes: true)
        defer { context.cleanup() }
        let manager = context.manager()
        let pids = try Dictionary(uniqueKeysWithValues: context.config.tunnels.map { ($0.id, try context.pid($0.id)) })
        let backup = context.url.appendingPathExtension("v1.bak")
        let previous = Data("previous configuration fixture".utf8)
        try previous.write(to: backup)
        let configBytes = try Data(contentsOf: context.url)
        let directory = context.url.deletingLastPathComponent()
        let files = [context.url, backup] + (try FileManager.default.contentsOfDirectory(at: context.runDir, includingPropertiesForKeys: nil))
        for file in files {
            if file != backup {
                let permissions = try mode(file)
                try expect(permissions == 0o600, "New configuration, PID and log files must use 0600")
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        }
        for folder in [directory, context.runDir] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        }
        try expect(manager.loadConfig(), "Permission repair must load the existing configuration")
        for folder in [directory, context.runDir] {
            let permissions = try mode(folder)
            try expect(permissions == 0o700, "Existing app directories must be repaired to 0700")
        }
        for file in files {
            let permissions = try mode(file)
            try expect(permissions == 0o600, "Existing app files and backups must be repaired to 0600")
        }
        let retained = try Data(contentsOf: context.url)
        let retainedBackup = try Data(contentsOf: backup)
        try expect(retained == configBytes && retainedBackup == previous, "Permission repair must preserve exact file contents")
        for (id, pid) in pids {
            let currentPID = try context.pid(id)
            try expect(currentPID == pid && kill(pid, 0) == 0 && manager.isOn(id), "Permission repair must preserve L/R/D processes")
        }

        let target = root.appendingPathComponent("external-file")
        try previous.write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
        let link = directory.appendingPathComponent("linked-config.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        do {
            try PrivateStorage.write(Data("replacement".utf8), to: link)
            throw TestFailure(description: "Private storage must reject a symlink target")
        } catch is TestFailure { throw TestFailure(description: "Private storage must reject a symlink target") }
        catch {}
        let externalBytes = try Data(contentsOf: target)
        let externalMode = try mode(target)
        try expect(externalBytes == previous && externalMode == 0o644, "Rejected paths must not alter unrelated files")
        print("PASS private storage: empty startup, 0700/0600 creation and repair, exact contents, L/R/D continuity, symlink safety")
    }

    static func configFailures(root: URL, executable: URL) throws {
        let context = try TestContext(root: root, executable: executable, name: "config-failures", autoStart: true)
        defer { context.cleanup() }
        let manager = context.manager()
        let pid = try context.pid()
        let invalidInputs = ["{invalid-json", "{}",
                             #"{"nodes":[],"tunnels":[{"id":"bad","nodeId":"missing"}]}"#,
                             #"{"nodes":[{"id":"n","host":"a"}],"tunnels":[{"id":"bad","forwards":[]}]}"#,
                             #"{"nodes":[{"id":"n","host":"a"},{"id":"n","host":"b"}],"tunnels":[]}"#,
                             #"{"groups":[{"id":"g","name":"A"},{"id":"g","name":"B"}],"tunnels":[]}"#,
                             #"{"groups":[{"id":"g","name":"A"},{"id":"h","name":" a "}],"tunnels":[]}"#,
                             #"{"groups":[{"id":"g","name":"未分组"}],"tunnels":[]}"#,
                             #"{"groups":[{"id":"","name":"A"}],"tunnels":[]}"#,
                             #"{"nodes":[{"id":"n","host":"a"}],"tunnels":[{"id":"bad","nodeId":"n","groupId":"missing","forwards":[{"type":"D","port":"1080"}]}]}"#]
        for text in invalidInputs {
            let data = Data(text.utf8)
            try data.write(to: context.url)
            try expect(!manager.loadConfig(), "Invalid config must fail to load")
            let after = try Data(contentsOf: context.url)
            try expect(after == data, "Invalid config must remain byte-identical")
            try expect(manager.current == context.config && manager.configError != nil, "Keep previous config and report error")
            try expect(manager.statuses[0].state == .running && kill(pid, 0) == 0, "Read failure must preserve running tunnel")
            let retained = try context.pid()
            try expect(retained == pid, "Read failure must retain original PID")
        }
        try FileManager.default.removeItem(at: context.url)
        try expect(!manager.loadConfig(), "Missing config on reload must fail")
        try expect(!FileManager.default.fileExists(atPath: context.url.path), "Reload must not replace missing config with defaults")
        try ConfigStore(url: context.url).save(context.config)
        try expect(manager.loadConfig() && manager.configError == nil, "Corrected config must load and clear error")
        let original = try context.pid()
        try expect(original == pid, "Corrected unchanged config must not restart tunnel")

        let saved = context.url.appendingPathExtension("original")
        try FileManager.default.moveItem(at: context.url, to: saved)
        try FileManager.default.createDirectory(at: context.url, withIntermediateDirectories: false)
        var changed = context.config
        changed.tunnels[0].forwards[0].port = "18082"
        do {
            try manager.applyConfig(changed)
            throw TestFailure(description: "Write failure must be returned to editor")
        } catch is TestFailure { throw TestFailure(description: "Write failure must be returned to editor") }
        catch {}
        try expect(manager.current == context.config && manager.configError != nil, "Save failure must retain current config")
        try expect(kill(pid, 0) == 0 && manager.statuses[0].state == .running, "Save failure must not restart or stop tunnel")

        let fresh = try TestContext(root: root, executable: executable, name: "invalid-startup")
        defer { fresh.cleanup() }
        let invalid = Data("{invalid-json".utf8)
        try invalid.write(to: fresh.url)
        let failed = fresh.manager()
        try expect(failed.statuses.isEmpty && failed.configError != nil, "Invalid startup must not autostart defaults")
        let preserved = try Data(contentsOf: fresh.url)
        try expect(preserved == invalid, "Invalid startup must preserve original bytes")
        print("PASS config errors preserve disk, memory, and live tunnels; write errors surface")
    }

    static func migration(root: URL, executable: URL) throws {
        let context = try TestContext(root: root, executable: executable, name: "migration")
        defer { context.cleanup() }
        let legacy = Data(#"{"tunnels":[{"id":"probe","name":"Probe","sshTarget":"user@legacy-test","forwards":["18080:127.0.0.1:80"],"autoStart":false}]}"#.utf8)
        let backup = context.url.appendingPathExtension("v1.bak")
        try legacy.write(to: context.url)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: false)
        let store = ConfigStore(url: context.url)
        do {
            _ = try store.load(createIfMissing: false)
            throw TestFailure(description: "Migration must abort when backup fails")
        } catch is TestFailure { throw TestFailure(description: "Migration must abort when backup fails") }
        catch {}
        let untouched = try Data(contentsOf: context.url)
        try expect(untouched == legacy, "Failed migration must preserve original")
        try FileManager.default.removeItem(at: backup)
        let migrated = try store.load(createIfMissing: false)
        let backedUp = try Data(contentsOf: backup)
        try expect(backedUp == legacy, "Migration backup must contain exact original bytes")
        let backupAttributes = try FileManager.default.attributesOfItem(atPath: backup.path)
        try expect((backupAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Migration backups must be private")
        try expect(migrated.nodes[0].host == "legacy-test" && migrated.nodes[0].user == "user", "Legacy target must migrate")
        let again = try store.load(createIfMissing: false)
        try expect(again == migrated, "Migrated config must load unchanged")
        try legacy.write(to: context.url)
        _ = try store.load(createIfMissing: false)
        let originalBackup = try Data(contentsOf: backup)
        try expect(originalBackup == legacy, "Existing migration backup must not be overwritten")
        let newerLegacy = Data(String(decoding: legacy, as: UTF8.self).replacingOccurrences(of: "legacy-test", with: "another-test").utf8)
        try newerLegacy.write(to: context.url)
        _ = try store.load(createIfMissing: false)
        let files = try FileManager.default.contentsOfDirectory(at: context.url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        let additional = files.filter {
            $0.lastPathComponent.hasPrefix("config.json.v1.") && $0.lastPathComponent != backup.lastPathComponent
        }
        try expect(additional.count == 1, "A different legacy input must get its own backup: found \(additional.map(\.lastPathComponent))")
        let additionalBytes = try Data(contentsOf: additional[0])
        try expect(additionalBytes == newerLegacy, "Additional backup must preserve new original bytes")
        print("PASS migration backs up original bytes and aborts safely on backup failure")
    }

    static func restartRace(root: URL, executable: URL) throws {
        let context = try TestContext(root: root, executable: executable, name: "restart-race")
        defer { context.cleanup() }
        let manager = context.manager()
        manager.start("probe")
        let first = try context.pid()
        manager.stop("probe")
        manager.start("probe")
        let second = try context.pid()
        pump(0.3)
        let retained = try context.pid()
        try expect(second != first && retained == second, "Old exit callback must retain new PID")
        try expect(manager.statuses[0].state == .running && kill(second, 0) == 0, "New process must remain managed and running")

        var changed = context.config
        changed.tunnels[0].forwards[0].port = "18082"
        try manager.applyConfig(changed)
        let third = try context.pid()
        pump(0.3)
        let reloaded = try context.pid()
        try expect(third != second && reloaded == third && manager.statuses[0].state == .running, "Config restart must ignore previous process callback")
        manager.stop("probe")
        try eventually("Stop must terminate the currently managed process") { kill(third, 0) != 0 }
        print("PASS rapid stop/start and config restart retain ownership of the new process")
    }

    static func reconnect(root: URL, executable: URL) throws {
        let context = try TestContext(root: root, executable: executable, name: "reconnect", autoStart: true)
        defer { context.cleanup() }
        let manager = context.manager()
        let first = try context.pid()
        kill(first, SIGTERM)
        try eventually("Unexpected exit must schedule reconnect") { manager.statuses[0].state == .reconnecting }
        try eventually("Reconnect must launch a replacement", timeout: 3) { manager.statuses[0].state == .running }
        let second = try context.pid()
        try expect(second != first, "Reconnect must have a new PID")
        kill(second, SIGTERM)
        try eventually("Second unexpected exit must schedule reconnect") { manager.statuses[0].state == .reconnecting }
        manager.stop("probe")
        manager.start("probe")
        let manual = try context.pid()
        pump(3.2)
        let afterPending = try context.pid()
        try expect(afterPending == manual && manager.statuses[0].state == .running, "Cancelled retry must not replace manually started process")
        kill(manual, SIGTERM)
        try eventually("Exit before deletion must reconnect") { manager.statuses[0].state == .reconnecting }
        try manager.applyConfig(AppConfig(nodes: context.config.nodes, tunnels: []))
        pump(1.7)
        try expect(manager.statuses.isEmpty && !FileManager.default.fileExists(atPath: context.pidURL().path), "Deleted tunnel must not respawn from queued retry")
        print("PASS reconnect, cancelled retries, and deletion during backoff")
    }

    static func recovery(root: URL, executable: URL) throws {
        for mode in ["valid", "missing", "stale", "reordered", "legacy", "legacy-verbose", "stale-log", "ambiguous", "mismatch"] {
            let context = try TestContext(root: root, executable: executable, name: "recovery-\(mode)", autoStart: mode == "ambiguous" || mode == "mismatch")
            defer { context.cleanup() }
            // 用无自启的准备配置取得生产代码生成的参数。
            var preparation = context.config
            preparation.tunnels[0].autoStart = false
            if mode == "legacy-verbose" { preparation.tunnels[0].extraArgs = ["-o", "LogLevel=DEBUG1"] }
            try ConfigStore(url: context.url).save(preparation)
            let preparer = context.manager()
            var args = preparer.sshArgs(for: preparation.tunnels[0])!
            preparer.prepareForAppExit()
            if mode.hasPrefix("legacy"), let index = args.firstIndex(of: "LogLevel=DEBUG1") {
                args.removeSubrange(index - 1...index)
            }
            if mode == "reordered", let index = args.firstIndex(of: "-L") {
                let pair = Array(args[index...index + 1])
                args.removeSubrange(index...index + 1)
                args.insert(contentsOf: pair, at: 0)
            }
            if mode == "mismatch" { args.insert(contentsOf: ["-p", "22223"], at: 0) }
            let fixture = try context.fixture(args: args)
            if ["valid", "reordered", "mismatch", "legacy", "legacy-verbose", "stale-log"].contains(mode) {
                try context.record(fixture.processIdentifier)
            } else if mode == "stale" {
                let unrelated = try context.fixture(args: ["60"], executable: URL(fileURLWithPath: "/bin/sleep"))
                try context.record(unrelated.processIdentifier)
            } else if mode == "ambiguous" {
                _ = try context.fixture(args: args)
            }
            if mode == "stale-log" {
                try PrivateStorage.write(Data("12345".utf8), to: context.runDir.appendingPathComponent("probe.log.pid"))
                try PrivateStorage.write(Data("12345".utf8), to: context.runDir.appendingPathComponent("probe.ready.pid"))
                try PrivateStorage.write(Data("debug1: Entering interactive session.\ndebug1: Local forwarding listening on 127.0.0.1 port 18080.\n".utf8), to: context.runDir.appendingPathComponent("probe.log"))
            }
            try ConfigStore(url: context.url).save(mode == "legacy-verbose" ? preparation : context.config)
            let adopter = context.manager()
            if mode == "ambiguous" {
                try expect(adopter.statuses[0].state == .needsAttention && adopter.errorText("probe") != nil, "Ambiguous matches must not spawn or kill")
                try expect(context.fixtures.allSatisfy(\.isRunning), "All ambiguous connections must survive")
            } else if mode == "mismatch" {
                let newPID = try context.pid()
                try expect(newPID != fixture.processIdentifier && fixture.isRunning, "Different complete arguments must not adopt or terminate unrelated process")
            } else {
                let pid = try context.pid()
                try expect(pid == fixture.processIdentifier, "Recovery must retain the existing PID: \(mode)")
                try expect(adopter.isOn("probe") && adopter.statuses[0].state == .unverified,
                           "Existing process without correlated diagnostics must be preserved without claiming readiness: \(mode)")
            }
        }
        print("PASS startup adoption, lost/stale PID recovery, option order, and mismatch/ambiguity safety")
    }

    static func exitAndAdopt(root: URL, executable: URL) throws {
        let context = try TestContext(root: root, executable: executable, name: "exit-owner", allTypes: true)
        defer { context.cleanup() }
        let owner = Process()
        owner.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        owner.arguments = [context.url.deletingLastPathComponent().path, executable.path, "--exit-owner"]
        owner.standardOutput = FileHandle.nullDevice
        owner.standardError = FileHandle.nullDevice
        try owner.run()
        owner.waitUntilExit()
        try expect(owner.terminationStatus == 0, "Owning app process must exit cleanly")
        let local = try context.pid()
        let socks = try context.pid("socks")
        let remote = try context.pid("remote")
        try expect([local, socks, remote].allSatisfy { kill($0, 0) == 0 }, "Normal app exit must preserve every tunnel")
        let adopter = context.manager()
        let adoptedLocal = try context.pid()
        let adoptedSocks = try context.pid("socks")
        let adoptedRemote = try context.pid("remote")
        try expect(adoptedLocal == local && adoptedSocks == socks && adoptedRemote == remote, "Relaunch must preserve original PIDs")
        try expect(adopter.statuses.allSatisfy { $0.state == .running && adopter.isOn($0.id) }, "Relaunch must restore all running states")
        adopter.prepareForAppExit()
        pump(0.2)
        try expect([local, socks, remote].allSatisfy { kill($0, 0) == 0 }, "Quitting after adoption must also preserve every tunnel")
        print("PASS owning app exits without killing L/R/D tunnels; next startup restores the same processes")
    }

    static func connectionStates(root: URL, executable: URL) throws {
        for mode in ["delayed", "remote-delayed", "auth", "network", "port", "ready-warning"] {
            let context = try TestContext(root: root, executable: executable, name: "state-\(mode)")
            defer { context.cleanup() }
            var cfg = context.config
            cfg.tunnels[0].extraArgs = ["--fixture-mode=\(mode)"]
            if mode == "remote-delayed" { cfg.tunnels[0].forwards[0].type = "R" }
            try ConfigStore(url: context.url).save(cfg)
            let manager = context.manager()
            manager.start("probe")
            try expect(manager.statuses[0].state == .connecting, "Spawn must never immediately claim readiness")
            _ = try context.pid()
            if mode == "ready-warning" {
                try eventually("A harmless warning must allow establishment") { manager.statuses[0].state == .running }
                let pid = try context.pid()
                kill(pid, SIGTERM)
                try eventually("Old startup warnings must not stop network recovery") { manager.statuses[0].state == .reconnecting }
            } else if mode == "delayed" || mode == "remote-delayed" {
                pump(0.35)
                try expect(manager.statuses[0].state == .connecting, "Authentication/session entry must not bypass forwarding confirmation")
                try eventually("Complete forwarding evidence must establish the tunnel") { manager.statuses[0].state == .running }
            } else if mode == "network" {
                try eventually("Network failure must retry") { manager.statuses[0].state == .reconnecting }
                try expect(manager.isOn("probe"), "Transient error must retain user intent")
            } else {
                try eventually("Actionable failure must pause retries") { manager.statuses[0].state == .needsAttention }
                try expect(!manager.isOn("probe") && manager.errorText("probe") != nil, "Actionable errors need an explanation and no infinite retry")
                pump(1.7)
                try expect(!FileManager.default.fileExists(atPath: context.pidURL().path), "Actionable failure respawned without user action")
                cfg.tunnels[0].extraArgs = []
                try manager.applyConfig(cfg)
                manager.start("probe")
                try eventually("Manual retry after repair must recover") { manager.statuses[0].state == .running }
            }
        }
        let context = try TestContext(root: root, executable: executable, name: "missing-key")
        defer { context.cleanup() }
        var cfg = context.config
        cfg.nodes[0].identityFile = root.appendingPathComponent("nonexistent-key").path
        try ConfigStore(url: context.url).save(cfg)
        let manager = context.manager()
        manager.start("probe")
        try expect(manager.statuses[0].state == .needsAttention && !FileManager.default.fileExists(atPath: context.pidURL().path), "Missing key must fail before launching SSH")
        print("PASS connecting/ready states, delayed remote confirmation, classified failures, manual recovery and key preflight")
    }

    static func diagnosticRetention(root: URL, executable: URL) throws {
        let context = try TestContext(root: root, executable: executable, name: "diagnostic-retention", autoStart: true)
        defer { context.cleanup() }
        let manager = context.manager()
        try eventually("Initial connection must be ready") { manager.statuses[0].state == .running }
        let pid = try context.pid()
        let log = context.runDir.appendingPathComponent("probe.log")
        let writer = try FileHandle(forWritingTo: log)
        try writer.seekToEnd()
        try writer.write(contentsOf: Data(repeating: 120, count: Int(SSHLogReader.maximumLogBytes) + 1))
        try writer.close()
        try eventually("Live diagnostics must be bounded") {
            let size = (try? FileManager.default.attributesOfItem(atPath: log.path)[.size] as? NSNumber)?.uint64Value ?? .max
            return size <= SSHLogReader.maximumLogBytes
        }
        manager.prepareForAppExit()
        let adopter = context.manager()
        let adoptedPID = try context.pid()
        try expect(adoptedPID == pid && adopter.statuses[0].state == .running,
                   "Trimming diagnostics must preserve confirmed readiness across adoption")
        print("PASS bounded logs and PID-correlated readiness survive adoption after log trimming")
    }
}
