import Foundation

enum TunnelTemplate: String, CaseIterable, Identifiable {
    case custom, postgresql, mysql, redis, web, socks
    var id: String { rawValue }
    var title: String {
        switch self {
        case .custom: return "自定义隧道"
        case .postgresql: return "PostgreSQL"
        case .mysql: return "MySQL"
        case .redis: return "Redis"
        case .web: return "网页访问"
        case .socks: return "SOCKS 代理"
        }
    }
    var subtitle: String {
        switch self {
        case .custom: return "自行设置 L / R / D 转发"
        case .postgresql: return "本机 15432 → 节点侧 5432"
        case .mysql: return "本机 13306 → 节点侧 3306"
        case .redis: return "本机 16379 → 节点侧 6379"
        case .web: return "本机 8080 → 节点侧 80"
        case .socks: return "本机 1080 · SOCKS5 代理"
        }
    }
    var icon: String {
        switch self {
        case .custom: return "slider.horizontal.3"
        case .postgresql, .mysql, .redis: return "externaldrive"
        case .web: return "globe"
        case .socks: return "network"
        }
    }
    func make(nodeID: String, existing: [TunnelConfig]) -> TunnelConfig {
        var rule = ForwardSpec(bind: "127.0.0.1", host: "127.0.0.1")
        switch self {
        case .custom: break
        case .postgresql: rule.port = "15432"; rule.rport = "5432"
        case .mysql: rule.port = "13306"; rule.rport = "3306"
        case .redis: rule.port = "16379"; rule.rport = "6379"
        case .web: rule.port = "8080"; rule.rport = "80"
        case .socks: rule.type = "D"; rule.port = "1080"; rule.host = ""
        }
        let used = Set(existing.flatMap(\.forwards).filter { $0.type != "R" }.compactMap { Int($0.port.trimmingCharacters(in: .whitespaces)) })
        if var port = Int(rule.port) {
            while used.contains(port) && port < 65535 { port += 1 }
            rule.port = String(port)
        }
        return TunnelConfig(name: Self.uniqueName(title, existing: existing), nodeId: nodeID, forwards: [rule])
    }
    static func duplicate(_ original: TunnelConfig, existing: [TunnelConfig]) -> TunnelConfig {
        var copy = original
        copy.id = UUID().uuidString
        copy.name = uniqueName(original.name + " 副本", existing: existing)
        copy.autoStart = false
        copy.forwards = original.forwards.map { rule in
            var copied = rule; copied.id = UUID().uuidString; return copied
        }
        return copy
    }
    private static func uniqueName(_ base: String, existing: [TunnelConfig]) -> String {
        let names = Set(existing.map(\.name))
        var name = base, count = 2
        while names.contains(name) { name = "\(base) \(count)"; count += 1 }
        return name
    }
}
