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

/// 一条转发规则。type: "L"=本地转发(-L), "R"=远程转发(-R), "D"=动态SOCKS(-D)
/// 兼容 v2 老格式：纯字符串 "-L 参数值" 一律按 L 解析
struct ForwardSpec: Codable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var type: String = "L"
    var bind: String = ""
    var port: String = ""
    var host: String = ""
    var rport: String = ""

    enum CodingKeys: String, CodingKey { case id, type, bind, port, host, rport }

    init(id: String = UUID().uuidString, type: String = "L", bind: String = "",
         port: String = "", host: String = "", rport: String = "") {
        self.id = id; self.type = type; self.bind = bind
        self.port = port; self.host = host; self.rport = rport
    }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let legacy = try? single.decode(String.self) {
            self = ForwardSpec.parse(legacy)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "L"
        bind = try c.decodeIfPresent(String.self, forKey: .bind) ?? ""
        port = try c.decodeIfPresent(String.self, forKey: .port) ?? ""
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        rport = try c.decodeIfPresent(String.self, forKey: .rport) ?? ""
    }

    var isEmpty: Bool { bind.isEmpty && port.isEmpty && host.isEmpty && rport.isEmpty }

    /// ssh 转发参数值；填写不完整/非法返回 nil
    var arg: String? {
        guard !isEmpty, problem == nil else { return nil }
        let b = bind.trimmingCharacters(in: .whitespaces)
        let h = host.trimmingCharacters(in: .whitespaces)
        let port = port.trimmingCharacters(in: .whitespaces)
        let rport = rport.trimmingCharacters(in: .whitespaces)
        func address(_ value: String) -> String {
            value.contains(":") && !value.hasPrefix("[") ? "[\(value)]" : value
        }
        if type == "D" {
            return b.isEmpty ? port : "\(address(b)):\(port)"
        }
        return b.isEmpty ? "\(port):\(address(h)):\(rport)" : "\(address(b)):\(port):\(address(h)):\(rport)"
    }

    /// 具体哪里没填好；全空行不算问题
    var problem: String? {
        if isEmpty { return nil }
        if !["L", "R", "D"].contains(type) { return "请选择转发类型" }
        if port.isEmpty { return "端口未填" }
        if !Self.validPort(port) { return "监听端口需为 1–65535" }
        if type != "D" {
            if rport.isEmpty { return "目标端口未填" }
            if !Self.validPort(rport) { return "目标端口需为 1–65535" }
            if host.trimmingCharacters(in: .whitespaces).isEmpty { return "目标地址未填" }
        }
        return nil
    }

    static func validPort(_ text: String) -> Bool {
        guard let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return (1...65535).contains(value)
    }

    var typeLabel: String {
        switch type {
        case "R": return "远程 R"
        case "D": return "SOCKS D"
        default: return "本地 L"
        }
    }

    /// 宽容解析既有 -L 字符串；对不认识的格式塞进地址栏让用户自己修
    static func parse(_ s: String) -> ForwardSpec {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return ForwardSpec() }
        let seg = trimmed.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        switch seg.count {
        case 3:
            return ForwardSpec(bind: "", port: seg[0], host: seg[1], rport: seg[2])
        case 4:
            return ForwardSpec(bind: seg[0], port: seg[1], host: seg[2], rport: seg[3])
        case let n where n > 4:
            // IPv6 目标：bind、port 取头两段，rport 取尾，中间合并为地址
            return ForwardSpec(bind: seg[0], port: seg[1],
                               host: seg[2..<(n - 1)].joined(separator: ":"),
                               rport: seg[n - 1])
        default:
            return ForwardSpec(host: trimmed)
        }
    }
}

struct TunnelGroupConfig: Codable, Identifiable, Equatable {
    var id: String
    var name: String

    init(id: String = UUID().uuidString, name: String = "") {
        self.id = id; self.name = name
    }

    func nameProblem(in groups: [TunnelGroupConfig]) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "请填写分组名称" }
        if trimmed == "未分组" { return "“未分组”是保留名称，请换一个名称" }
        if groups.contains(where: { $0.id != id && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return "分组名称已存在，请换一个名称"
        }
        return nil
    }
}

struct TunnelConfig: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var nodeId: String
    /// 单归属分组；nil 表示未分组，旧配置自动保留在未分组中。
    var groupId: String? = nil
    /// 转发规则，可混合 L/R/D 类型
    var forwards: [ForwardSpec]
    /// 附加 ssh 参数（不支持含空格的参数值）
    var extraArgs: [String] = []
    /// 应用启动时自动拉起
    var autoStart: Bool = false

    init(id: String = UUID().uuidString, name: String = "", nodeId: String = "",
         forwards: [ForwardSpec] = [], extraArgs: [String] = [], autoStart: Bool = false,
         groupId: String? = nil) {
        self.id = id; self.name = name; self.nodeId = nodeId
        self.groupId = groupId
        self.forwards = forwards; self.extraArgs = extraArgs; self.autoStart = autoStart
    }

    enum CodingKeys: String, CodingKey {
        case id, name, nodeId, groupId, forwards, extraArgs, autoStart
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        nodeId = try c.decodeIfPresent(String.self, forKey: .nodeId) ?? ""
        groupId = try c.decodeIfPresent(String.self, forKey: .groupId)
        forwards = try c.decodeIfPresent([ForwardSpec].self, forKey: .forwards) ?? []
        extraArgs = try c.decodeIfPresent([String].self, forKey: .extraArgs) ?? []
        autoStart = try c.decodeIfPresent(Bool.self, forKey: .autoStart) ?? false
    }
}

struct AppConfig: Codable, Equatable {
    /// 数组顺序就是分组的展示顺序；公共连接也是普通分组。
    var groups: [TunnelGroupConfig] = []
    var nodes: [NodeConfig] = []
    var tunnels: [TunnelConfig] = []

    init() {}

    init(nodes: [NodeConfig], tunnels: [TunnelConfig], groups: [TunnelGroupConfig] = []) {
        self.nodes = nodes
        self.tunnels = tunnels
        self.groups = groups
    }

    enum CodingKeys: String, CodingKey { case groups, nodes, tunnels }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groups = try c.decodeIfPresent([TunnelGroupConfig].self, forKey: .groups) ?? []
        nodes = try c.decodeIfPresent([NodeConfig].self, forKey: .nodes) ?? []
        tunnels = try c.decode([TunnelConfig].self, forKey: .tunnels)

        // v1 迁移: sshTarget 字符串 → 节点
        if nodes.isEmpty && tunnels.contains(where: { $0.nodeId.isEmpty }) {
            struct LegacyTunnel: Decodable {
                let id, name, sshTarget: String
                let forwards: [String]?
                let extraArgs: [String]?
                let autoStart: Bool?
            }
            let legacy = try c.decode([LegacyTunnel].self, forKey: .tunnels)
            tunnels = []
            for lt in legacy {
                let (user, host) = AppConfig.splitUserHost(lt.sshTarget)
                let node = NodeConfig(id: "node-\(lt.id)", name: host.isEmpty ? lt.sshTarget : host,
                                      host: host, user: user)
                nodes.append(node)
                tunnels.append(TunnelConfig(id: lt.id, name: lt.name, nodeId: node.id,
                                            forwards: (lt.forwards ?? []).map { ForwardSpec.parse($0) },
                                            extraArgs: lt.extraArgs ?? [],
                                            autoStart: lt.autoStart ?? false))
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
        AppConfig()
    }

    func groupName(_ id: String?) -> String {
        guard let id else { return "未分组" }
        return groups.first { $0.id == id }?.name ?? "分组不存在"
    }

    func tunnelIDs(inGroup id: String?) -> [String] {
        tunnels.filter { $0.groupId == id }.map(\.id)
    }

    /// 删除组织结构只解除归属，不删除或停止任何隧道。
    mutating func removeGroup(_ id: String) {
        groups.removeAll { $0.id == id }
        for index in tunnels.indices where tunnels[index].groupId == id {
            tunnels[index].groupId = nil
        }
    }

    mutating func addGroup() -> String {
        let names = Set(groups.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) })
        var name = "新分组", number = 2
        while names.contains(name) { name = "新分组 \(number)"; number += 1 }
        let group = TunnelGroupConfig(name: name)
        groups.append(group)
        return group.id
    }
}

extension JSONEncoder {
    static func encodePretty<T: Encodable>(_ value: T) -> Data? {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? e.encode(value)
    }
}
