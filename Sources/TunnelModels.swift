// 配置模型：节点(SSH端点) + 隧道(转发规则)
// v1 老格式(tunnels[].sshTarget 字符串)自动迁移为节点

import Foundation

struct NodeConfig: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    /// 域名 / IP / ~/.ssh/config 别名
    var host: String
    /// 空 = 不传 -p（沿用别名里的定义，无别名则默认 22）
    var port: String = ""
    /// 空 = 不传 user@（沿用别名或本机用户名）
    var user: String = ""
    /// 空 = 不传 -i
    var identityFile: String = ""

    init(id: String = UUID().uuidString, name: String = "", host: String = "",
         port: String = "", user: String = "", identityFile: String = "") {
        self.id = id; self.name = name; self.host = host
        self.port = port; self.user = user; self.identityFile = identityFile
    }

    enum CodingKeys: String, CodingKey {
        case id, name, host, port, user, identityFile
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        host = try c.decode(String.self, forKey: .host)
        port = try c.decodeIfPresent(String.self, forKey: .port) ?? ""
        user = try c.decodeIfPresent(String.self, forKey: .user) ?? ""
        identityFile = try c.decodeIfPresent(String.self, forKey: .identityFile) ?? ""
    }

    var sshTarget: String { user.isEmpty ? host : "\(user)@\(host)" }
}

struct TunnelConfig: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var nodeId: String
    /// 每项是一条 -L 参数值，如 "127.0.0.1:15432:127.0.0.1:5432"，可多条
    var forwards: [String]
    /// 附加 ssh 参数（不支持含空格的参数值）
    var extraArgs: [String] = []
    /// 应用启动时自动拉起
    var autoStart: Bool = false

    init(id: String = UUID().uuidString, name: String = "", nodeId: String = "",
         forwards: [String] = [], extraArgs: [String] = [], autoStart: Bool = false) {
        self.id = id; self.name = name; self.nodeId = nodeId
        self.forwards = forwards; self.extraArgs = extraArgs; self.autoStart = autoStart
    }

    enum CodingKeys: String, CodingKey {
        case id, name, nodeId, forwards, extraArgs, autoStart
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        nodeId = try c.decodeIfPresent(String.self, forKey: .nodeId) ?? ""
        forwards = try c.decodeIfPresent([String].self, forKey: .forwards) ?? []
        extraArgs = try c.decodeIfPresent([String].self, forKey: .extraArgs) ?? []
        autoStart = try c.decodeIfPresent(Bool.self, forKey: .autoStart) ?? false
    }
}

struct AppConfig: Codable, Equatable {
    var nodes: [NodeConfig] = []
    var tunnels: [TunnelConfig] = []

    init() {}

    init(nodes: [NodeConfig], tunnels: [TunnelConfig]) {
        self.nodes = nodes
        self.tunnels = tunnels
    }

    enum CodingKeys: String, CodingKey { case nodes, tunnels }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nodes = try c.decodeIfPresent([NodeConfig].self, forKey: .nodes) ?? []
        tunnels = try c.decodeIfPresent([TunnelConfig].self, forKey: .tunnels) ?? []

        // 老格式隧道没有 nodeId → 丢弃，走下面的迁移重建
        tunnels.removeAll { $0.nodeId.isEmpty }

        // v1 迁移: sshTarget 字符串 → 节点
        if nodes.isEmpty {
            struct LegacyTunnel: Decodable {
                let id, name, sshTarget: String
                let forwards: [String]?
                let extraArgs: [String]?
                let autoStart: Bool?
            }
            if let legacy = try? c.decodeIfPresent([LegacyTunnel].self, forKey: .tunnels),
               !legacy.isEmpty {
                for lt in legacy {
                    let (user, host) = AppConfig.splitUserHost(lt.sshTarget)
                    let node = NodeConfig(id: "node-\(lt.id)", name: host.isEmpty ? lt.sshTarget : host,
                                          host: host, user: user)
                    nodes.append(node)
                    tunnels.append(TunnelConfig(id: lt.id, name: lt.name, nodeId: node.id,
                                                forwards: lt.forwards ?? [],
                                                extraArgs: lt.extraArgs ?? [],
                                                autoStart: lt.autoStart ?? false))
                }
            }
        }
    }

    static func splitUserHost(_ s: String) -> (String, String) {
        if let at = s.firstIndex(of: "@") {
            return (String(s[s.startIndex..<at]), String(s[s.index(after: at)...]))
        }
        return ("", s)
    }

    static func defaultConfig() -> AppConfig {
        let node = NodeConfig(id: "node-example", name: "example", host: "example")
        let tunnel = TunnelConfig(id: "database-forward", name: "数据库访问",
                                  nodeId: node.id,
                                  forwards: ["127.0.0.1:15432:127.0.0.1:5432"],
                                  autoStart: true)
        return AppConfig(nodes: [node], tunnels: [tunnel])
    }
}

extension JSONEncoder {
    static func encodePretty<T: Encodable>(_ value: T) -> Data? {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? e.encode(value)
    }
}
