import Foundation

enum ConfigStoreError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        }
    }
}

/// 只有首次启动且文件不存在时才创建默认配置；读取失败不改动原文件。
struct ConfigStore {
    let url: URL

    func load(createIfMissing: Bool) throws -> AppConfig {
        guard FileManager.default.fileExists(atPath: url.path) else {
            guard createIfMissing else {
                throw ConfigStoreError.invalid("配置文件不存在")
            }
            let cfg = AppConfig.defaultConfig()
            try save(cfg)
            return cfg
        }

        let data = try Data(contentsOf: url)
        let cfg = try JSONDecoder().decode(AppConfig.self, from: data)
        try validate(cfg)

        // 迁移前保存原始字节，已有备份不覆盖。备份失败则整个迁移失败。
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let tunnels = json["tunnels"] as? [[String: Any]],
           tunnels.contains(where: { $0["sshTarget"] != nil }) {
            var backup = url.appendingPathExtension("v1.bak")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: backup.path, isDirectory: &isDirectory) {
                guard !isDirectory.boolValue else {
                    throw ConfigStoreError.invalid("迁移备份路径不是文件")
                }
                if try Data(contentsOf: backup) != data {
                    backup = url.appendingPathExtension("v1.\(UUID().uuidString).bak")
                    try data.write(to: backup, options: .withoutOverwriting)
                }
            } else {
                try data.write(to: backup, options: .withoutOverwriting)
            }
            try save(cfg)
        }
        return cfg
    }

    func save(_ cfg: AppConfig) throws {
        try validate(cfg)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(cfg)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private func validate(_ cfg: AppConfig) throws {
        guard Set(cfg.nodes.map(\.id)).count == cfg.nodes.count,
              Set(cfg.tunnels.map(\.id)).count == cfg.tunnels.count else {
            throw ConfigStoreError.invalid("节点或隧道 ID 重复")
        }
        for node in cfg.nodes {
            guard !node.id.isEmpty, !node.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ConfigStoreError.invalid("节点 ID 和主机不能为空")
            }
            let port = node.port.trimmingCharacters(in: .whitespaces)
            if !port.isEmpty {
                guard let value = Int(port), (1...65535).contains(value) else {
                    throw ConfigStoreError.invalid("节点「\(node.name)」的端口无效")
                }
            }
        }
        let nodeIDs = Set(cfg.nodes.map(\.id))
        for tunnel in cfg.tunnels {
            guard !tunnel.id.isEmpty, !tunnel.id.contains("/"), nodeIDs.contains(tunnel.nodeId) else {
                throw ConfigStoreError.invalid("隧道「\(tunnel.name)」的 ID 或节点引用无效")
            }
            guard tunnel.forwards.contains(where: { $0.arg != nil }),
                  tunnel.forwards.allSatisfy({ ["L", "R", "D"].contains($0.type) && ($0.isEmpty || $0.arg != nil) }) else {
                throw ConfigStoreError.invalid("隧道「\(tunnel.name)」的转发规则无效")
            }
        }
    }
}
