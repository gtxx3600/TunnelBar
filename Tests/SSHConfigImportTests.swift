import Foundation

@main
struct SSHConfigImportTests {
    static func main() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("tunnelbar-import-\(UUID().uuidString)")
        let ssh = home.appendingPathComponent(".ssh")
        try FileManager.default.createDirectory(at: ssh.appendingPathComponent("hosts"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        func write(_ name: String, _ text: String) throws {
            try text.write(to: ssh.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        func check(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain: "SSHConfigImportTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func read() throws -> SSHConfigImportResult {
            try SSHConfigImporter.read(ssh.appendingPathComponent("config"), home: home, environment: ["SSH_IMPORT_FIXTURE": ssh.path])
        }

        try write("config", """
        # Host commented-out
        Host example secondary # readable aliases
            HostName 192.0.2.1
            User fixture
            Port 2222
            IdentityFile ~/.ssh/id_example
            ProxyJump bastion
        hOsT = "quoted" 'single'
        Host wildcard-* server? !negated
        Host excluded !excluded included
        Host example
        Host -oProxyCommand=anything "invalid alias"
        Host "broken
        Host after-broken
        """)
        let original = try Data(contentsOf: ssh.appendingPathComponent("config"))
        let result = try read()
        try check(result.hosts.map(\.alias) == ["example", "secondary", "quoted", "single", "included", "after-broken"],
                  "Literal aliases, comments, quotes, equals syntax, exclusions and deduplication failed")
        try check(result.hosts[0].line == 2 && result.hosts[0].source == ssh.appendingPathComponent("config"),
                  "Source location was not preserved")
        try check(result.warnings.count == 1, "Malformed Host must produce a visible warning without losing later aliases")
        let imported = SSHConfigImporter.nodes(from: result.hosts, selected: ["example", "quoted", "single", "not-in-config"],
                                              existing: [NodeConfig(id: "existing", host: " example ", user: "overridden")])
        try check(imported.map(\.host) == ["quoted", "single"], "Selection or existing-node deduplication failed")
        try check(imported.allSatisfy { $0.name == $0.host && $0.user.isEmpty && $0.port.isEmpty && $0.identityFile.isEmpty },
                  "Imported nodes must preserve SSH aliases and leave overrides empty")
        try check(Set(imported.map(\.id)).count == imported.count, "Imported nodes must have unique IDs")
        try check(try Data(contentsOf: ssh.appendingPathComponent("config")) == original, "Import modified SSH configuration")
        print("PASS SSH aliases: syntax, comments, patterns, duplicates, source locations, selection, alias inheritance")

        try write("config", """
        Include hosts/*.conf
        Include "space file" ${SSH_IMPORT_FIXTURE}/env.conf
        Include %d/.ssh/percent.conf ~/.ssh/tilde.conf missing-*.conf
        Host root
        """)
        try write("hosts/10-first.conf", "Include nested.conf\nHost first\nHost shared\n")
        try write("hosts/20-second.conf", "Host second\nHost shared\n")
        try write("nested.conf", "Host nested\n")
        try write("space file", "Host spaced\n")
        try write("env.conf", "Host env\n")
        try write("percent.conf", "Host percent\n")
        try write("tilde.conf", "Host tilde\n")
        let included = try read()
        try check(included.hosts.map(\.alias) == ["nested", "first", "shared", "second", "spaced", "env", "percent", "tilde", "root"],
                  "Include glob order, nested paths relative to ~/.ssh, quotes, environment or home expansion failed")
        try check(included.hosts[0].source.lastPathComponent == "nested.conf" && included.warnings.isEmpty,
                  "Include source or missing-glob handling failed")
        print("PASS Include: lexical glob order, nested files, spaced paths, environment, home and source locations")

        let marker = home.appendingPathComponent("must-not-exist")
        try write("config", """
        Include loop.conf
        Host *
            Include star.conf
        Host specific
            Include conditional.conf
        Match exec "touch \(marker.path)"
            Include conditional.conf
        Match all
            Include always.conf
        Include ${MISSING_IMPORT_VARIABLE}/hosts %h.conf
        Host final
        """)
        try write("loop.conf", "Include config\nHost loop\n")
        try write("star.conf", "Host star\n")
        try write("conditional.conf", "Host conditional\n")
        try write("always.conf", "Host always\n")
        let guarded = try read()
        try check(guarded.hosts.map(\.alias) == ["loop", "star", "specific", "always", "final"],
                  "Unconditional Include or conditional-include handling failed")
        try check(guarded.warnings.contains { $0.contains("循环") } && guarded.warnings.contains { $0.contains("条件 Include") }
                  && guarded.warnings.contains { $0.contains("动态值") }, "Skipped Include must have visible diagnostics")
        try check(!FileManager.default.fileExists(atPath: marker.path), "Reading config executed Match exec")
        print("PASS safe discovery: circular includes, conditional diagnostics, dynamic paths, no Match exec")

        try Data([0xff, 0xfe]).write(to: ssh.appendingPathComponent("invalid.conf"))
        try write("config", "Include invalid.conf\nInclude hosts\nHost retained\n")
        let partial = try read()
        try check(partial.hosts.map(\.alias) == ["retained"] && partial.warnings.count == 2,
                  "Unreadable or non-file includes must not hide valid aliases")
        try write("config", "# only defaults\nHost *\n    User fixture\n")
        try check(try read().hosts.isEmpty, "Default-only configuration must have an empty candidate list")
        try FileManager.default.removeItem(at: ssh.appendingPathComponent("config"))
        do {
            _ = try read()
            throw NSError(domain: "SSHConfigImportTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing root config was accepted"])
        } catch {
            try check(error.localizedDescription.contains("未找到"), "Missing config needs a useful error")
        }
        print("PASS errors: partial reads, directories, empty candidates and missing configuration")

        let node = NodeConfig(id: "fixture-node", name: "Fixture", host: "fixture-host")
        let baseline = AppConfig(nodes: [node], tunnels: [
            TunnelConfig(id: "fixture-tunnel", name: "Fixture", nodeId: node.id,
                         forwards: [ForwardSpec(port: "15432", host: "127.0.0.1", rport: "5432")])
        ])
        var draft = baseline
        draft.nodes += SSHConfigImporter.nodes(from: included.hosts, selected: Set(included.hosts.map(\.alias)), existing: baseline.nodes)
        try check(draft.tunnels == baseline.tunnels && draft.nodes[0] == baseline.nodes[0], "Import changed existing resources")
        try check(ConfigDraftRules.issues(in: draft).isEmpty && ConfigDraftRules.impact(from: baseline, to: draft, activeIDs: ["fixture-tunnel"]).description.isEmpty,
                  "Adding imported nodes must not start, stop or reconnect tunnels on save")
        print("PASS draft integration: existing resources unchanged, valid nodes, no tunnel lifecycle impact")
    }
}
