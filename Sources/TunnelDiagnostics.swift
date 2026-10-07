import Foundation

enum TunnelFailureKind {
    case authentication, hostKey, portInUse, identityFile, configuration, network, unknown
}

struct TunnelFailure {
    let kind: TunnelFailureKind
    let title: String
    let suggestion: String
    let retryable: Bool

    var message: String { "\(title)\n\(suggestion)" }

    static func classify(_ log: String) -> TunnelFailure {
        let text = log.lowercased()
        if text.contains("host key verification failed") || text.contains("remote host identification has changed") {
            return TunnelFailure(kind: .hostKey, title: "服务器身份需要确认", suggestion: "请在终端核对服务器指纹并完成首次连接；如果指纹变更，请先向管理员确认。", retryable: false)
        }
        if text.contains("bad permissions") || text.contains("unprotected private key") || text.contains("load key ") || text.contains("identity file") && text.contains("not accessible") {
            return TunnelFailure(kind: .identityFile, title: "私钥文件不可用", suggestion: "检查私钥路径、文件权限和格式；带口令的私钥可先加入 SSH Agent。", retryable: false)
        }
        if text.contains("permission denied (") || text.contains("authentication failed") || text.contains("too many authentication failures") || text.contains("read_passphrase: can't open") {
            return TunnelFailure(kind: .authentication, title: "SSH 认证失败", suggestion: "检查用户名、私钥和 SSH Agent；需要密码或私钥口令时，请先在终端完成认证配置。", retryable: false)
        }
        if text.contains("address already in use") || text.contains("cannot listen to port") {
            return TunnelFailure(kind: .portInUse, title: "监听端口已被占用", suggestion: "停止占用该地址和端口的连接，或修改这条隧道的监听端口，再点击重试。", retryable: false)
        }
        if text.contains("remote port forwarding failed") || text.contains("could not request local forwarding") || text.contains("could not request remote forwarding") {
            return TunnelFailure(kind: .configuration, title: "转发规则未能建立", suggestion: "检查监听端口是否被占用，以及服务器是否允许对应的端口转发。", retryable: false)
        }
        if text.contains("bad configuration option") || text.contains("bad local forwarding") || text.contains("bad remote forwarding") || text.contains("bad dynamic forwarding") || text.contains("illegal option") || text.contains("unknown option") || text.contains("missing argument") || text.contains("bad port") || text.contains("cannot assign requested address") || text.contains("administratively prohibited") {
            return TunnelFailure(kind: .configuration, title: "SSH 配置需要修改", suggestion: "检查节点、监听地址、转发规则和附加参数，修改后再点击重试。", retryable: false)
        }
        if text.contains("timed out") || text.contains("connection refused") || text.contains("connection reset") || text.contains("connection closed") || text.contains("broken pipe") || text.contains("no route to host") || text.contains("network is unreachable") || text.contains("could not resolve hostname") {
            return TunnelFailure(kind: .network, title: "网络或服务器暂时不可达", suggestion: "将自动重试；也可检查网络、VPN 和服务器的 SSH 服务。", retryable: true)
        }
        return TunnelFailure(kind: .unknown, title: "SSH 连接已中断", suggestion: "将自动重试；展开诊断可查看 SSH 的原始输出。", retryable: true)
    }
}

/// 只接受 OpenSSH 的完整诊断行。认证成功本身不表示转发已经建立。
/// 日志协议依据 openssh-portable ssh.c / clientloop.c；未知输出保持待确认。
struct SSHConnectionEvidence {
    private(set) var enteredSession = false
    private(set) var localPorts: Set<String> = []
    private(set) var remotePorts: Set<String> = []
    private(set) var sawRemoteRequest = false
    private(set) var remoteRepliesComplete = false
    private(set) var forwardingFailed = false

    mutating func consume(_ line: String) {
        if line == "debug1: Entering interactive session." { enteredSession = true }
        if line.hasPrefix("debug1: Local forwarding listening on "),
           let range = line.range(of: " port ", options: .backwards) {
            localPorts.insert(String(line[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: ".\r")))
        }
        if line.hasPrefix("debug1: Remote connections from ") { sawRemoteRequest = true }
        if line == "debug1: forwarding_success: all expected forwarding replies received" { remoteRepliesComplete = true }
        if line.hasPrefix("debug1: remote forward success for: listen "),
           let listen = line.components(separatedBy: ", connect ").first {
            let endpoint = listen.replacingOccurrences(of: "debug1: remote forward success for: listen ", with: "")
            remotePorts.insert(String(endpoint.split(separator: ":").last ?? ""))
        }
        if line.hasPrefix("Error: remote port forwarding failed") || line == "Could not request local forwarding." {
            forwardingFailed = true
        }
    }

    func isReady(for forwards: [ForwardSpec]) -> Bool {
        guard enteredSession, !forwardingFailed else { return false }
        let rules = forwards.filter { $0.arg != nil }
        let remote = rules.filter { $0.type == "R" }
        return rules.filter { $0.type != "R" }.allSatisfy { localPorts.contains($0.port.trimmingCharacters(in: .whitespaces)) }
            && remote.allSatisfy { remotePorts.contains($0.port.trimmingCharacters(in: .whitespaces)) }
            && ((!sawRemoteRequest && remote.isEmpty) || remoteRepliesComplete)
    }
}

/// 增量读取且限制单次内存占用；SSH 继续直接写文件，应用退出不关闭它的日志端。
struct SSHLogReader {
    static let maximumLogBytes: UInt64 = 2 * 1024 * 1024
    private var offset: UInt64 = 0
    private var pending = Data()
    private(set) var evidence = SSHConnectionEvidence()

    mutating func update(from url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            if size < offset { offset = 0; pending = Data(); evidence = SSHConnectionEvidence() }
            try handle.seek(toOffset: offset)
            let bytes = try handle.read(upToCount: 64 * 1024) ?? Data()
            offset += UInt64(bytes.count)
            pending.append(bytes)
            while let newline = pending.firstIndex(of: 10) {
                let line = String(decoding: pending[..<newline], as: UTF8.self).trimmingCharacters(in: .newlines)
                evidence.consume(line)
                pending.removeSubrange(...newline)
            }
            if pending.count > 64 * 1024 { pending.removeAll() }
        } catch { /* 下次轮询重试，不把读取失败当作连接成功。 */ }
    }

    static func tail(_ url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return "" }
        try? handle.seek(toOffset: size > 8192 ? size - 8192 : 0)
        let data = (try? handle.read(upToCount: 8192)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// SSH 的文件描述符以 O_APPEND 写入；截短后仍会接着写，不产生稀疏大文件。
    /// 仅在本次连接已确认并持久化后使用，避免丢掉启动确认记录。
    static func trimIfNeeded(_ url: URL) {
        guard let handle = try? FileHandle(forUpdating: url) else { return }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            guard size > maximumLogBytes else { return }
            try handle.seek(toOffset: size - 64 * 1024)
            let recent = try handle.read(upToCount: 64 * 1024) ?? Data()
            try handle.truncate(atOffset: 0)
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: recent)
        } catch { /* 不因日志维护影响活跃连接。 */ }
    }
}
