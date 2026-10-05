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

        for port in ["0", "65536", "-1", "", "abc"] {
            var invalid = rule; invalid.port = port
            try check(ConfigDraftRules.forwardProblem(invalid) != nil, "Invalid listening port accepted: \(port)")
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
    }
}
