import Foundation
import Darwin

struct ConfigImportDocument: Identifiable {
    let id = UUID()
    let source: URL
    let config: AppConfig
}

struct ConfigImportPlan {
    var config: AppConfig
    var addedGroups = 0
    var addedNodes = 0
    var addedTunnels = 0
    var skippedTunnels = 0

    var summary: String {
        "新增 \(addedGroups) 个分组、\(addedNodes) 个节点、\(addedTunnels) 条隧道" +
            (skippedTunnels > 0 ? "；跳过 \(skippedTunnels) 条已有隧道" : "")
    }
}

/// 外部 JSON 只进入内存；只有编辑器明确保存才应用到本机。
enum ConfigTransfer {
    static let maximumBytes = 8 * 1024 * 1024

    static func read(from url: URL) throws -> ConfigImportDocument {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw ConfigStoreError.invalid("请选择普通 JSON 配置文件")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        return ConfigImportDocument(source: url, config: try decode(data))
    }

    static func decode(_ data: Data) throws -> AppConfig {
        guard data.count <= maximumBytes else {
            throw ConfigStoreError.invalid("配置文件超过 8 MiB，请检查是否选对文件")
        }
        let config: AppConfig
        do { config = try ConfigStore.decode(data) }
        catch is DecodingError { throw ConfigStoreError.invalid("不是有效的 TunnelBar 配置，请选择导出的 JSON 或原始 config.json") }
        try validateForwardIDs(config)
        return config
    }

    private static func validateForwardIDs(_ config: AppConfig) throws {
        for tunnel in config.tunnels {
            guard tunnel.forwards.allSatisfy({ !$0.id.isEmpty }), Set(tunnel.forwards.map(\.id)).count == tunnel.forwards.count else {
                throw ConfigStoreError.invalid("隧道「\(tunnel.name)」存在重复的转发规则 ID")
            }
        }
    }

    /// 相同条目复用；冲突条目换 ID 并重新映射引用，现有资源原样保留。
    static func merge(_ imported: AppConfig, into current: AppConfig) -> ConfigImportPlan {
        let imported = ConfigDraftRules.normalized(imported)
        let normalizedCurrent = ConfigDraftRules.normalized(current)
        var plan = ConfigImportPlan(config: current)
        var matchingNodes = normalizedCurrent.nodes
        var matchingTunnels = normalizedCurrent.tunnels
        var groupMap: [String: String] = [:], nodeMap: [String: String] = [:]
        func sameName(_ a: String, _ b: String) -> Bool {
            a.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(b.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
        }
        for original in imported.groups {
            if let match = plan.config.groups.first(where: { sameName($0.name, original.name) }) {
                groupMap[original.id] = match.id
                continue
            }
            var group = original
            if plan.config.groups.contains(where: { $0.id == group.id }) { group.id = UUID().uuidString }
            groupMap[original.id] = group.id
            plan.config.groups.append(group); plan.addedGroups += 1
        }
        for original in imported.nodes {
            func matches(_ existing: NodeConfig) -> Bool {
                var comparison = original; comparison.id = existing.id
                return comparison == existing
            }
            if let match = matchingNodes.first(where: { $0.id == original.id && matches($0) })
                ?? matchingNodes.first(where: matches) {
                nodeMap[original.id] = match.id
                continue
            }
            var node = original
            if plan.config.nodes.contains(where: { $0.id == node.id }) { node.id = UUID().uuidString }
            nodeMap[original.id] = node.id
            plan.config.nodes.append(node); plan.addedNodes += 1
            matchingNodes.append(node)
        }
        for original in imported.tunnels {
            var tunnel = original
            tunnel.nodeId = nodeMap[original.nodeId] ?? original.nodeId
            tunnel.groupId = original.groupId.map { groupMap[$0] ?? $0 }
            if matchingTunnels.contains(where: { equivalent(tunnel, $0) }) {
                plan.skippedTunnels += 1
                continue
            }
            if plan.config.tunnels.contains(where: { $0.id == tunnel.id }) { tunnel.id = UUID().uuidString }
            plan.config.tunnels.append(tunnel); plan.addedTunnels += 1
            matchingTunnels.append(tunnel)
        }
        return plan
    }

    private static func equivalent(_ a: TunnelConfig, _ b: TunnelConfig) -> Bool {
        guard a.forwards.count == b.forwards.count else { return false }
        var comparison = a; comparison.id = b.id
        for index in comparison.forwards.indices { comparison.forwards[index].id = b.forwards[index].id }
        return comparison == b
    }

    /// 外部目录不属于应用私有存储：仅导出文件为 0600，不改变桌面等目录权限。
    static func export(_ config: AppConfig, to url: URL, protecting configURL: URL? = nil) throws {
        if let configURL, url.resolvingSymlinksInPath().standardizedFileURL == configURL.resolvingSymlinksInPath().standardizedFileURL {
            throw ConfigStoreError.invalid("请选择其他位置，导出不能覆盖正在使用的配置文件")
        }
        let data = try ConfigStore.encode(config)
        try validateForwardIDs(config)
        guard data.count <= maximumBytes else { throw ConfigStoreError.invalid("导出配置超过 8 MiB") }
        if FileManager.default.fileExists(atPath: url.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw ConfigStoreError.invalid("导出目标必须是普通文件")
            }
        }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".tunnelbar-export-\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        guard fchmod(descriptor, 0o600) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        // rename 原子替换目标；在此之前的任何错误都保留目标文件。
        guard rename(temporary.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
