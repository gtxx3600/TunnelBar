import Foundation

enum ConfigResource: Hashable {
    case tunnel(String)
    case node(String)
}

enum ConfigRuntimeState {
    case running, reconnecting
}

struct ConfigIssue: Identifiable {
    let resource: ConfigResource
    let field: String
    let message: String
    var id: String { "\(resource)-\(field)" }
}

struct ConfigSaveImpact {
    var reconnect: [String] = []
    var stop: [String] = []
    var start: [String] = []
    var description: String {
        var parts: [String] = []
        if !reconnect.isEmpty { parts.append("将重连：\(reconnect.joined(separator: "、"))") }
        if !stop.isEmpty { parts.append("将停止：\(stop.joined(separator: "、"))") }
        if !start.isEmpty { parts.append("将启动：\(start.joined(separator: "、"))") }
        return parts.joined(separator: "；")
    }
    var interruptsConnection: Bool { !reconnect.isEmpty || !stop.isEmpty }
}

/// 草稿校验与保存影响只计算数据，不读写配置，也不操作 SSH。
enum ConfigDraftRules {
    static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func validPort(_ text: String) -> Bool {
        guard let value = Int(trimmed(text)) else { return false }
        return (1...65535).contains(value)
    }
    static func normalized(_ config: AppConfig) -> AppConfig {
        var result = config
        result.nodes = config.nodes.map { original in
            var node = original
            node.name = trimmed(node.name); node.host = trimmed(node.host)
            node.port = trimmed(node.port); node.user = trimmed(node.user)
            node.identityFile = trimmed(node.identityFile)
            return node
        }
        result.tunnels = config.tunnels.map { original in
            var tunnel = original
            tunnel.name = trimmed(tunnel.name)
            tunnel.forwards = tunnel.forwards.map { original in
                var forward = original
                forward.bind = trimmed(forward.bind); forward.port = trimmed(forward.port)
                forward.host = trimmed(forward.host); forward.rport = trimmed(forward.rport)
                return forward
            }
            return tunnel
        }
        return result
    }
    static func forwardProblem(_ forward: ForwardSpec) -> String? {
        if !["L", "R", "D"].contains(forward.type) { return "请选择转发类型" }
        if !validPort(forward.port) { return "监听端口需为 1–65535" }
        if forward.type != "D" {
            if trimmed(forward.host).isEmpty { return "请填写目标地址" }
            if !validPort(forward.rport) { return "目标端口需为 1–65535" }
        }
        return nil
    }
    static func issues(in config: AppConfig) -> [ConfigIssue] {
        let config = normalized(config)
        var result: [ConfigIssue] = []
        for node in config.nodes {
            let resource = ConfigResource.node(node.id)
            if node.host.isEmpty {
                result.append(ConfigIssue(resource: resource, field: "host", message: "请填写主机地址或 SSH 别名"))
            }
            if !node.port.isEmpty && !validPort(node.port) {
                result.append(ConfigIssue(resource: resource, field: "port", message: "SSH 端口需为 1–65535"))
            }
        }
        let nodeIDs = Set(config.nodes.map(\.id))
        for tunnel in config.tunnels {
            let resource = ConfigResource.tunnel(tunnel.id)
            if tunnel.name.isEmpty {
                result.append(ConfigIssue(resource: resource, field: "name", message: "请填写隧道名称"))
            }
            if !nodeIDs.contains(tunnel.nodeId) {
                result.append(ConfigIssue(resource: resource, field: "node", message: "请选择一个 SSH 节点"))
            }
            if tunnel.forwards.isEmpty {
                result.append(ConfigIssue(resource: resource, field: "forwards", message: "至少添加一条转发规则"))
            }
            for forward in tunnel.forwards {
                if let problem = forwardProblem(forward) {
                    result.append(ConfigIssue(resource: resource, field: forward.id, message: problem))
                }
            }
        }
        return result
    }
    static func impact(from baseline: AppConfig, to draft: AppConfig,
                       activeIDs: Set<String>) -> ConfigSaveImpact {
        let next = normalized(draft)
        var result = ConfigSaveImpact()
        for old in baseline.tunnels where activeIDs.contains(old.id) {
            let name = old.name.isEmpty ? old.id : old.name
            guard let updated = next.tunnels.first(where: { $0.id == old.id }) else {
                result.stop.append(name)
                continue
            }
            if connectionSignature(old, in: baseline) != connectionSignature(updated, in: next) {
                result.reconnect.append(name)
            }
        }
        let oldIDs = Set(baseline.tunnels.map(\.id))
        result.start = next.tunnels.filter { !oldIDs.contains($0.id) && $0.autoStart }
            .map { $0.name.isEmpty ? $0.id : $0.name }
        return result
    }
    // 名称和自动启动不改变生效连接；节点名称/ID 也不参与连接参数。
    private static func connectionSignature(_ tunnel: TunnelConfig, in config: AppConfig) -> [String]? {
        guard let node = config.nodes.first(where: { $0.id == tunnel.nodeId }) else { return nil }
        return [node.sshTarget, node.port.trimmingCharacters(in: .whitespaces),
                node.identityFile.trimmingCharacters(in: .whitespaces)]
            + tunnel.forwards.flatMap { forward -> [String] in
                guard let arg = forward.arg else { return [] }
                return [forward.type, arg]
            } + tunnel.extraArgs
    }
}
