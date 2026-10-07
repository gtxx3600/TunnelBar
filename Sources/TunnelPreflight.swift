import Foundation
import Darwin

enum TunnelPreflight {
    static func check(_ tunnel: TunnelConfig, node: NodeConfig) -> TunnelFailure? {
        let path = node.identityFile.trimmingCharacters(in: .whitespacesAndNewlines)
        // OpenSSH 自己展开动态路径；这里仅检查用户明确选择或填写的普通路径。
        if !path.isEmpty && !path.contains("%") && !path.contains("${") {
            let expanded = (path as NSString).expandingTildeInPath
            var directory: ObjCBool = false
            if !FileManager.default.fileExists(atPath: expanded, isDirectory: &directory) || directory.boolValue || !FileManager.default.isReadableFile(atPath: expanded) {
                return TunnelFailure(kind: .identityFile, title: "找不到或无法读取私钥文件", suggestion: "请在节点设置中重新选择私钥：\(path)", retryable: false)
            }
        }
        let local = tunnel.forwards.filter { ["L", "D"].contains($0.type) && $0.arg != nil }
        for (index, rule) in local.enumerated() {
            if local[..<index].contains(where: { conflicts($0, rule) }) {
                return TunnelFailure(kind: .portInUse, title: "同一隧道重复使用监听端口 \(rule.port)", suggestion: "请为每条本地转发或 SOCKS 规则设置不同的监听地址和端口。", retryable: false)
            }
            if let failure = checkPort(rule) { return failure }
        }
        return nil
    }

    /// 不连接任何服务；临时 bind 后立即关闭，最终建立结果仍由 SSH 确认。
    private static func checkPort(_ rule: ForwardSpec) -> TunnelFailure? {
        for address in addresses(rule.bind) {
            var hints = addrinfo()
            hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(address, rule.port.trimmingCharacters(in: .whitespaces), &hints, &result) == 0, let info = result else { continue }
            defer { freeaddrinfo(info) }
            let fd = socket(info.pointee.ai_family, SOCK_STREAM, 0)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
            if info.pointee.ai_family == AF_INET6 {
                setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &one, socklen_t(MemoryLayout<Int32>.size))
            }
            if Darwin.bind(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) != 0 && errno == EADDRINUSE {
                return TunnelFailure(kind: .portInUse, title: "监听端口 \(rule.port) 已被占用", suggestion: "\(address):\(rule.port) 正被其他连接使用。请停止占用者或修改监听端口，再点击重试。", retryable: false)
            }
        }
        return nil
    }

    static func conflicts(_ a: ForwardSpec, _ b: ForwardSpec) -> Bool {
        guard ["L", "D"].contains(a.type), ["L", "D"].contains(b.type),
              let port = Int(a.port.trimmingCharacters(in: .whitespaces)),
              port == Int(b.port.trimmingCharacters(in: .whitespaces)) else { return false }
        return addresses(a.bind).contains { left in
            addresses(b.bind).contains { right in
                left == right || (left == "0.0.0.0" && !right.contains(":"))
                    || (right == "0.0.0.0" && !left.contains(":"))
                    || (left == "::" && right.contains(":")) || (right == "::" && left.contains(":"))
            }
        }
    }

    static func warnings(for tunnel: TunnelConfig, in config: AppConfig) -> [String] {
        var messages: [String] = []
        for other in config.tunnels where other.id != tunnel.id {
            let ports = Set(tunnel.forwards.filter { rule in other.forwards.contains { conflicts(rule, $0) } }.map(\.port)).sorted()
            if !ports.isEmpty {
                messages.append("监听端口 \(ports.joined(separator: "、")) 与「\(other.name)」重叠，请避免同时启动。")
            }
        }
        return messages
    }

    private static func addresses(_ bind: String) -> [String] {
        let host = bind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        switch host {
        case "", "localhost": return ["127.0.0.1", "::1"]
        case "*": return ["0.0.0.0", "::"]
        default: return [host]
        }
    }
}
