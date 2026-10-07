import Foundation

@main
struct ConfigDraftTests {
    static func main() throws {
        let node = NodeConfig(id: "node", name: "shared", host: "fixture")
        let rule = ForwardSpec(id: "rule", bind: "127.0.0.1", port: "15432", host: "127.0.0.1", rport: "5432")
        let a = TunnelConfig(id: "a", name: "A", nodeId: node.id, forwards: [rule], autoStart: true)
        let b = TunnelConfig(id: "b", name: "B", nodeId: node.id,
                             forwards: [ForwardSpec(type: "D", port: "1080")])
        let original = AppConfig(nodes: [node], tunnels: [a, b])
        func check(_ value: Bool, _ message: String) throws {
            if !value { throw NSError(domain: "ConfigDraftTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func impact(_ next: AppConfig, active: Set<String> = ["a", "b"]) -> ConfigSaveImpact {
            ConfigDraftRules.impact(from: original, to: next, activeIDs: active)
        }
        try check(ConfigDraftRules.issues(in: original).isEmpty, "Valid L/D configuration was rejected")
        var next = original
        next.tunnels[0].name = "Renamed"; next.tunnels[0].autoStart = false; next.nodes[0].name = "Renamed node"
        try check(impact(next).description.isEmpty, "Metadata-only edits must not report a restart")
        next = original; next.nodes[0].host = "other-fixture"
        try check(impact(next).reconnect == ["A", "B"], "Shared node edits must report all affected active tunnels")
        try check(impact(next, active: ["a"]).reconnect == ["A"], "Stopped tunnels must not be reported as interrupted")
        next = original; next.tunnels[0].forwards[0].port = "15433"
        try check(impact(next).reconnect == ["A"], "Forward edits must report the affected tunnel")
        next = original; next.tunnels[0].extraArgs = ["-v"]
        try check(impact(next).reconnect == ["A"], "Extra SSH arguments must be included in save impact")
        next = original; next.tunnels.removeFirst()
        try check(impact(next).stop == ["A"], "Removing an active tunnel must report that it will stop")
        next = original
        next.nodes.append(NodeConfig(id: "same-connection", name: "Other label", host: "fixture"))
        next.tunnels[0].nodeId = "same-connection"
        try check(impact(next).description.isEmpty, "Changing to an equivalent node must not report interruption")
        next = original
        next.tunnels.append(TunnelConfig(id: "new", name: "New", nodeId: node.id,
                                        forwards: [ForwardSpec(type: "D", port: "1081")], autoStart: true))
        try check(impact(next).start == ["New"], "A new auto-start tunnel must report its startup")
        print("PASS save impact: metadata, shared nodes, forwards, deletion, equivalent nodes, auto-start")

        let legacy = Data(#"{"nodes":[{"id":"n","host":"fixture"}],"tunnels":[{"id":"t","name":"Old","nodeId":"n","forwards":[{"type":"D","port":"1080"}]}]}"#.utf8)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: legacy)
        try check(decoded.groups.isEmpty && decoded.tunnels[0].groupId == nil,
                  "Existing configurations without group fields must remain ungrouped")
        var grouped = original
        grouped.groups = [TunnelGroupConfig(id: "project", name: "项目 A"), TunnelGroupConfig(id: "shared", name: "公共连接")]
        grouped.tunnels[0].groupId = "project"; grouped.tunnels[1].groupId = "shared"
        let roundTrip = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(grouped))
        try check(roundTrip == grouped && ConfigDraftRules.issues(in: grouped).isEmpty,
                  "Group order and single membership must round-trip while nodes remain reusable")
        try check(impact(grouped).description.isEmpty, "Assigning groups must not change running connections")
        let groupedCopy = TunnelTemplate.duplicate(grouped.tunnels[0], existing: grouped.tunnels)
        try check(groupedCopy.groupId == "project", "Duplicating a tunnel must retain its group")
        next = grouped; next.groups[0].name = " 项目 B \n"; next.tunnels[0].groupId = "shared"
        try check(ConfigDraftRules.normalized(next).groups[0].name == "项目 B" && grouped.groups[0].name == "项目 A",
                  "Group normalization must leave the baseline untouched")
        try check(ConfigDraftRules.impact(from: grouped, to: next, activeIDs: ["a", "b"]).description.isEmpty,
                  "Renaming groups and moving members must not interrupt connections")
        next = grouped; next.removeGroup("project")
        var ungroupedA = a; ungroupedA.groupId = nil
        try check(next.groups.map(\.id) == ["shared"] && next.tunnels[0] == ungroupedA && next.tunnels[1] == grouped.tunnels[1],
                  "Deleting a group must only remove that group and unassign its members")
        try check(ConfigDraftRules.impact(from: grouped, to: next, activeIDs: ["a", "b"]).description.isEmpty,
                  "Deleting a group must not stop its tunnels")
        for name in ["  ", " 未分组 ", " 公共连接 "] {
            next = grouped; next.groups[0].name = name
            try check(ConfigDraftRules.issues(in: next).contains { $0.resource == .group("project") && $0.field == "name" },
                      "Invalid group names must point to their group: \(name)")
        }
        next = grouped; next.groups[0].name = "Project"; next.groups[1].name = "project"
        try check(!ConfigDraftRules.issues(in: next).isEmpty, "Case-only duplicate group names must be rejected")
        next = grouped; next.tunnels[0].groupId = "missing"
        try check(ConfigDraftRules.issues(in: next).contains { $0.resource == .tunnel("a") && $0.field == "group" },
                  "A missing group must point to its member tunnel")
        next = grouped
        let newGroupID = next.addGroup(), anotherGroupID = next.addGroup()
        try check(newGroupID != anotherGroupID && ConfigDraftRules.issues(in: next).isEmpty,
                  "New groups must have distinct IDs and valid unique names")
        print("PASS groups: old configuration, round-trip, single membership, node reuse, copy, safe move/delete and name validation")

        for port in ["0", "65536", "-1", "", "abc"] {
            var invalid = rule; invalid.port = port
            try check(ConfigDraftRules.forwardProblem(invalid) != nil, "Invalid listening port accepted: \(port)")
            try check(invalid.arg == nil, "File/runtime validation accepted a port rejected by the editor: \(port)")
        }
        for port in ["1", "65535", " 1080 "] {
            try check(ConfigDraftRules.validPort(port), "Valid port rejected: \(port)")
        }
        var remote = rule; remote.type = "R"
        try check(ConfigDraftRules.forwardProblem(remote) == nil, "Valid remote rule rejected")
        remote.rport = "0"
        try check(ConfigDraftRules.forwardProblem(remote) != nil, "Zero target port accepted")
        try check(ConfigDraftRules.forwardProblem(ForwardSpec(type: "D", port: "1080")) == nil,
                  "SOCKS must not require a target address")
        next = original; next.nodes[0].host = " "
        try check(ConfigDraftRules.issues(in: next).contains { $0.resource == .node("node") && $0.field == "host" },
                  "Missing node host must point to the node")
        next = original; next.tunnels[0].forwards = []
        try check(ConfigDraftRules.issues(in: next).contains { $0.resource == .tunnel("a") && $0.field == "forwards" },
                  "Missing forwarding rules must point to the tunnel")
        next = original; next.tunnels[0].nodeId = "missing"
        try check(ConfigDraftRules.issues(in: next).contains { $0.field == "node" }, "Missing node reference accepted")
        next = original; next.tunnels[0].forwards[0].port = " 15432 "
        let normalized = ConfigDraftRules.normalized(next)
        try check(normalized.tunnels[0].forwards[0].port == "15432", "Port whitespace was not normalized")
        try check(original.tunnels[0].forwards[0].port == "15432" && next.tunnels[0].forwards[0].port == " 15432 ",
                  "Normalization must not mutate the source snapshot or draft")
        try check(normalized.tunnels[0].forwards[0].id == rule.id, "Normalization changed rule identity")
        print("PASS validation: L/R/D rules, port boundaries, targeted errors, normalization, snapshot isolation")

        let postgres = TunnelTemplate.postgresql.make(nodeID: node.id, existing: original.tunnels)
        try check(postgres.forwards[0].port == "15433" && postgres.forwards[0].rport == "5432" && !postgres.autoStart,
                  "Template must avoid configured local ports and default to stopped")
        for template in TunnelTemplate.allCases where template != .custom {
            let created = template.make(nodeID: node.id, existing: [])
            try check(ConfigDraftRules.issues(in: AppConfig(nodes: [node], tunnels: [created])).isEmpty,
                      "Template produced an invalid draft: \(template.title)")
        }
        let copy = TunnelTemplate.duplicate(a, existing: original.tunnels)
        try check(copy.id != a.id && copy.forwards[0].id != a.forwards[0].id && !copy.autoStart,
                  "Copy must have fresh identities and must not auto-start")
        try check(copy.nodeId == a.nodeId && copy.forwards[0].arg == a.forwards[0].arg && copy.extraArgs == a.extraArgs,
                  "Copy lost connection settings")
        let another = TunnelTemplate.duplicate(a, existing: original.tunnels + [copy])
        try check(another.name != copy.name && !TunnelPreflight.warnings(for: copy, in: AppConfig(nodes: [node], tunnels: [a, copy])).isEmpty,
                  "Copies need unique names and an overlapping-port warning")
        let copiedConfig = AppConfig(nodes: [node], tunnels: [a, b, copy])
        try check(ConfigDraftRules.impact(from: original, to: copiedConfig, activeIDs: [a.id]).description.isEmpty,
                  "Copying a tunnel must not affect existing connections")
        print("PASS templates/copy: valid presets, unused ports, fresh IDs, stopped defaults, overlap warnings and no lifecycle impact")
    }
}
