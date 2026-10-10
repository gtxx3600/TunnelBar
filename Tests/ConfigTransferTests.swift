import Foundation

@main
struct ConfigTransferTests {
    static func check(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: "ConfigTransferTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func rejected(_ message: String, _ action: () throws -> Void) throws {
        do { try action() } catch { return }
        try check(false, message)
    }
    static func mode(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue
    }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tunnelbar-transfer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        let node = NodeConfig(id: "node", name: "服务器", host: "example.invalid", user: "developer", identityFile: "/missing/key")
        let rules = [ForwardSpec(id: "local", type: "L", bind: "127.0.0.1", port: "15432", host: "::1", rport: "5432"),
                     ForwardSpec(id: "remote", type: "R", port: "9000", host: "localhost", rport: "3000"),
                     ForwardSpec(id: "socks", type: "D", port: "1080")]
        let tunnel = TunnelConfig(id: "tunnel", name: "数据库与代理", nodeId: node.id, forwards: rules,
                                  extraArgs: ["-o", "Compression=yes"], autoStart: true, groupId: "group")
        let config = AppConfig(nodes: [node], tunnels: [tunnel], groups: [TunnelGroupConfig(id: "group", name: "项目 A")])
        let exported = root.appendingPathComponent("导出.json")
        try ConfigTransfer.export(config, to: exported)
        let read = try ConfigTransfer.read(from: exported)
        try check(read.config == config, "Export/import must retain IDs, order, groups, L/R/D rules, SSH options and autostart")
        try check(try mode(root) == 0o755 && mode(exported) == 0o600, "Export must protect only its file, not change the destination directory")
        let bytes = try Data(contentsOf: exported)
        try check(!String(decoding: bytes, as: UTF8.self).contains("loginItem"), "Machine login preference must not be exported")
        let identical = ConfigTransfer.merge(read.config, into: config)
        try check(identical.config == config && identical.skippedTunnels == 1, "Importing the same configuration must not duplicate resources")
        var sameEndpoint = config
        var secondNode = node; secondNode.id = "second-node"
        sameEndpoint.nodes.append(secondNode)
        sameEndpoint.tunnels[0].nodeId = secondNode.id
        try check(ConfigTransfer.merge(sameEndpoint, into: sameEndpoint).config == sameEndpoint,
                  "Equivalent nodes with separate identities must retain existing tunnel references")
        var spaced = config
        spaced.nodes[0].host = " example.invalid "
        spaced.nodes[0].name = " 服务器 "
        spaced.tunnels[0].name = " 数据库与代理 "
        spaced.tunnels[0].forwards[0].port = " 15432 "
        try check(ConfigTransfer.merge(spaced, into: config).config == config,
                  "Reimport after save-time whitespace normalization must not create duplicates")
        try check(ConfigTransfer.merge(config, into: spaced).config == spaced,
                  "Duplicate matching must preserve whitespace in an existing unsaved draft")
        print("PASS configuration round-trip, private export file, unchanged parent permissions and duplicate import")

        var incoming = config
        incoming.groups[0].name = "项目 B"
        incoming.nodes[0].host = "other.invalid"
        incoming.tunnels[0].forwards[0].port = "15433"
        let merged = ConfigTransfer.merge(incoming, into: config)
        let next = merged.config
        try check(next.groups[0] == config.groups[0] && next.nodes[0] == node && next.tunnels[0] == tunnel,
                  "Conflicts must never modify existing resources")
        try check(next.nodes.count == 2 && next.tunnels.count == 2 && next.groups.count == 2, "Conflicts must append new resources")
        try check(next.nodes[1].id != node.id && next.groups[1].id != "group" && next.tunnels[1].id != tunnel.id,
                  "All conflicting IDs must be remapped")
        try check(next.tunnels[1].nodeId == next.nodes[1].id && next.tunnels[1].groupId == next.groups[1].id,
                  "Imported references must follow remapped IDs")
        _ = try ConfigTransfer.decode(ConfigStore.encode(next))
        try check(ConfigTransfer.merge(incoming, into: next).config == next, "Repeated conflict import must remain idempotent")
        var sameGroup = incoming
        sameGroup.groups[0] = TunnelGroupConfig(id: "another-group", name: " 项目 A ")
        sameGroup.tunnels[0].groupId = "another-group"
        let reused = ConfigTransfer.merge(sameGroup, into: config)
        try check(reused.config.groups == config.groups && reused.config.tunnels.last?.groupId == "group", "Same-name groups must reuse local membership")
        var dirty = config; dirty.nodes[0].host = ""
        try check(ConfigTransfer.merge(incoming, into: dirty).config.nodes[0] == dirty.nodes[0], "Import must preserve unfinished existing drafts")
        print("PASS collision remapping, group reuse, idempotence and preservation of unsaved edits")

        let legacy = Data(#"{"tunnels":[{"id":"old","name":"旧版","sshTarget":"dev@legacy.invalid","forwards":["8080:localhost:80"],"autoStart":false}]}"#.utf8)
        let legacyURL = root.appendingPathComponent("legacy.json")
        try legacy.write(to: legacyURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: legacyURL.path)
        let old = try ConfigTransfer.read(from: legacyURL).config
        let again = try ConfigTransfer.read(from: legacyURL).config
        try check(old.nodes[0].user == "dev" && old.nodes[0].host == "legacy.invalid", "Legacy configuration must migrate in memory")
        try check(try Data(contentsOf: legacyURL) == legacy && mode(legacyURL) == 0o444, "Import must not rewrite or chmod its source")
        try check(ConfigTransfer.merge(again, into: old).config == old, "Regenerated legacy forward IDs must not create duplicates")
        for malformed in ["{}", "[]", "not-json", #"{"nodes":[],"tunnels":[{"id":"broken","nodeId":"missing","forwards":[]}]}"#] {
            try rejected("Malformed configuration was accepted") { _ = try ConfigTransfer.decode(Data(malformed.utf8)) }
        }
        var invalid = config; invalid.tunnels[0].groupId = "missing"
        try rejected("Dangling group reference was accepted") { _ = try ConfigTransfer.decode(JSONEncoder().encode(invalid)) }
        invalid = config; invalid.nodes.append(node)
        try rejected("Duplicate node IDs were accepted") { _ = try ConfigTransfer.decode(JSONEncoder().encode(invalid)) }
        invalid = config; invalid.tunnels[0].forwards.append(rules[0])
        try rejected("Duplicate rule IDs were accepted") { _ = try ConfigTransfer.decode(JSONEncoder().encode(invalid)) }
        try rejected("Oversized import was accepted") { _ = try ConfigTransfer.decode(Data(repeating: 32, count: ConfigTransfer.maximumBytes + 1)) }
        print("PASS read-only legacy migration, malformed files, missing references, duplicate IDs and size limits")

        let live = root.appendingPathComponent("private/config.json")
        let store = ConfigStore(url: live)
        try store.save(config)
        let original = try Data(contentsOf: live)
        try rejected("Export overwrote the live configuration") { try ConfigTransfer.export(incoming, to: live, protecting: live) }
        let alias = root.appendingPathComponent("alias.json")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: live)
        try rejected("Export followed a link to the live configuration") { try ConfigTransfer.export(incoming, to: alias, protecting: live) }
        try check(try Data(contentsOf: live) == original, "Protected export changed live bytes")
        try rejected("Invalid export replaced an existing file") { try ConfigTransfer.export(invalid, to: exported) }
        try check(try Data(contentsOf: exported) == bytes, "Failed export must preserve the previous backup")
        let protectedDirectory = root.appendingPathComponent("directory.json")
        try FileManager.default.createDirectory(at: protectedDirectory, withIntermediateDirectories: false)
        try rejected("Export replaced a directory") { try ConfigTransfer.export(config, to: protectedDirectory) }
        try check(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".tunnelbar-export-") },
                  "Export must clean temporary files")
        try store.save(incoming, backupBeforeImport: true)
        let backups = try FileManager.default.contentsOfDirectory(at: live.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("config.before-import.") }
        try check(backups.count == 1, "Saving an import must create one backup")
        try check(try Data(contentsOf: backups[0]) == original && mode(backups[0]) == 0o600, "Backup must preserve exact original bytes privately")
        try check(try store.load(createIfMissing: false) == incoming, "Saving the replacement must retain its original IDs and values")
        var broken = incoming; broken.tunnels[0].nodeId = "missing"
        try rejected("Invalid import was saved") { try store.save(broken, backupBeforeImport: true) }
        try check(try store.load(createIfMissing: false) == incoming, "Rejected save must preserve the current configuration")
        print("PASS protected live path, atomic export failures, private pre-import backup and replacement save")
    }
}
