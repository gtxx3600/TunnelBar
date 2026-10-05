// 隧道管理器：进程生命周期 / 接管 / 重连 / 配置应用

import SwiftUI
import AppKit

enum TunnelState {
    case stopped, running, reconnecting
}

struct TunnelStatus: Identifiable {
    let config: TunnelConfig
    var state: TunnelState = .stopped
    var detail: String = ""
    var id: String { config.id }
}

final class TunnelManager: ObservableObject {
    static let shared = TunnelManager()

    @Published var statuses: [TunnelStatus] = []
    private(set) var current = AppConfig()

    private var procs: [String: Process] = [:]           // app 自己拉起的 ssh
    private var adoptedPids: [String: pid_t] = [:]       // 重启后接管的 ssh
    private var intended: [String: Bool] = [:]           // 用户是否期望它在跑
    private var attempts: [String: Int] = [:]
    private var startedAt: [String: Date] = [:]
    private var restartWork: [String: DispatchWorkItem] = [:]
    private var argSigs: [String: String] = [:]          // 在跑隧道的生效参数签名
    private var lastError: [String: String] = [:]
    private var timer: Timer?

    static var configURL: URL {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: home)
            .appendingPathComponent(".config/tunnel-bar/config.json")
    }

    static var runDir: URL {
        configURL.deletingLastPathComponent().appendingPathComponent("run")
    }

    init() {
        loadConfig()
        adoptExisting()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.pollAdopted()
                self?.objectWillChange.send()
            }
        }
        for s in statuses where s.config.autoStart && !isOn(s.id) {
            start(s.id)
        }
    }

    // MARK: - 生效 ssh 参数

    func node(_ id: String) -> NodeConfig? {
        current.nodes.first { $0.id == id }
    }

    func nodeName(_ id: String) -> String {
        node(id).map { $0.name.isEmpty ? $0.host : $0.name } ?? "?"
    }

    /// 这条隧道完整 ssh 命令行（节点不存在返回 nil）
    func sshArgs(for tunnel: TunnelConfig) -> [String]? {
        guard let n = node(tunnel.nodeId) else { return nil }
        var args = ["-N",
                    "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=4",
                    "-o", "ExitOnForwardFailure=yes", "-o", "ConnectTimeout=10"]
        if let port = Int(n.port.trimmingCharacters(in: .whitespaces)), port > 0 {
            args += ["-p", n.port.trimmingCharacters(in: .whitespaces)]
        }
        if !n.identityFile.trimmingCharacters(in: .whitespaces).isEmpty {
            args += ["-i", n.identityFile.trimmingCharacters(in: .whitespaces)]
        }
        for f in tunnel.forwards where !f.trimmingCharacters(in: .whitespaces).isEmpty {
            args += ["-L", f]
        }
        args += tunnel.extraArgs
        args.append(n.sshTarget)
        return args
    }

    // MARK: - 配置

    private func persist(_ cfg: AppConfig) {
        try? FileManager.default.createDirectory(
            at: Self.configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = JSONEncoder.encodePretty(cfg) {
            try? data.write(to: Self.configURL, options: .atomic)
        }
    }

    private func readOrCreateConfig() -> AppConfig {
        guard FileManager.default.fileExists(atPath: Self.configURL.path),
              let data = try? Data(contentsOf: Self.configURL),
              let cfg = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            let def = AppConfig.defaultConfig()
            persist(def)
            return def
        }
        persist(cfg)   // 归一化落盘（老格式迁移/缺省字段补全后回写）
        return cfg
    }

    func loadConfig() {
        let cfg = readOrCreateConfig()
        current = cfg
        let newIDs = Set(cfg.tunnels.map(\.id))

        for (id, _) in procs where !newIDs.contains(id) { stop(id) }
        for (id, _) in adoptedPids where !newIDs.contains(id) { stop(id) }

        var next: [TunnelStatus] = []
        for c in cfg.tunnels {
            var s = TunnelStatus(config: c)
            if let old = statuses.first(where: { $0.id == c.id }) {
                s.state = old.state
                s.detail = old.detail
            }
            next.append(s)
        }
        statuses = next

        // 在跑但生效参数变了（改了节点/转发/附加参数）→ 重启生效
        for c in cfg.tunnels where isOn(c.id) {
            if let args = sshArgs(for: c), argSigs[c.id] != args.joined(separator: " ") {
                stop(c.id)
                start(c.id)
            }
        }
        argSigs = Dictionary(uniqueKeysWithValues: cfg.tunnels.compactMap { c in
            sshArgs(for: c).map { (c.id, $0.joined(separator: " ")) }
        })
    }

    /// 配置窗口「保存」入口：落盘 → 重载 → 拉起新增的 autoStart 隧道
    func applyConfig(_ cfg: AppConfig) {
        persist(cfg)
        loadConfig()
        for t in cfg.tunnels where t.autoStart && !isOn(t.id) {
            start(t.id)
        }
    }

    func editConfig() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-t", Self.configURL.path]
        try? p.run()
    }

    // MARK: - pid / 日志文件（跨重启接管用）

    private func pidFileURL(_ id: String) -> URL {
        Self.runDir.appendingPathComponent("\(id).pid")
    }

    /// stderr 落盘成文件：app 退出后孤儿 ssh 仍有合法的写入端，重启接管后还能读错误
    private func logFileURL(_ id: String) -> URL {
        Self.runDir.appendingPathComponent("\(id).log")
    }

    private func freshLogHandle(_ id: String) -> FileHandle? {
        try? FileManager.default.createDirectory(
            at: Self.runDir, withIntermediateDirectories: true)
        let url = logFileURL(id)
        try? FileManager.default.removeItem(at: url)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return FileHandle(forWritingAtPath: url.path)
    }

    private func writePidFile(_ id: String, _ pid: pid_t) {
        try? FileManager.default.createDirectory(
            at: Self.runDir, withIntermediateDirectories: true)
        try? String(pid).write(to: pidFileURL(id), atomically: true, encoding: .utf8)
    }

    private func removePidFile(_ id: String) {
        try? FileManager.default.removeItem(at: pidFileURL(id))
    }

    /// 校验 pid 还活着且命令行确实是这条隧道的 ssh（防 pid 复用误接管）
    private static func processMatches(_ pid: pid_t, tunnel: TunnelConfig, node: NodeConfig) -> Bool {
        guard pid > 0, kill(pid, 0) == 0 else { return false }
        guard let cmd = ps(pid, columns: ["command="]) else { return false }
        return cmd.contains("ssh") && cmd.contains(node.sshTarget)
            && tunnel.forwards.allSatisfy { cmd.contains($0) }
    }

    /// ps -p <pid> -o <columns>，失败返回 nil
    private static func ps(_ pid: pid_t, columns: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-p", String(pid), "-o"] + columns
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { return nil }
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
            let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch { return nil }
    }

    /// ps etime（"MM:SS" / "HH:MM:SS" / "D-HH:MM:SS"）换算进程启动时刻
    private static func processStartDate(_ pid: pid_t) -> Date? {
        guard let etime = ps(pid, columns: ["etime="]) else { return nil }
        var days = 0
        var body = etime
        if let dash = etime.firstIndex(of: "-") {
            days = Int(etime[etime.startIndex..<dash]) ?? 0
            body = String(etime[etime.index(after: dash)...])
        }
        let segs = body.split(separator: ":").compactMap { Int($0) }
        guard segs.count == 2 || segs.count == 3 else { return nil }
        let hh = segs.count == 3 ? segs[0] : 0
        let mm = segs.count == 3 ? segs[1] : segs[0]
        let ss = segs.count == 3 ? segs[2] : segs[1]
        return Date().addingTimeInterval(
            -TimeInterval(days * 86400 + hh * 3600 + mm * 60 + ss))
    }

    /// 启动时接管上次遗留的隧道进程
    private func adoptExisting() {
        for s in statuses {
            guard let text = try? String(contentsOf: pidFileURL(s.id), encoding: .utf8),
                  let pidNum = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  pidNum > 0
            else { continue }
            let pid = pid_t(pidNum)
            guard let n = node(s.config.nodeId),
                  Self.processMatches(pid, tunnel: s.config, node: n) else {
                removePidFile(s.id)
                continue
            }
            adoptedPids[s.id] = pid
            intended[s.id] = true
            startedAt[s.id] = Self.processStartDate(pid) ?? Date()
            argSigs[s.id] = sshArgs(for: s.config).map { $0.joined(separator: " ") }
            setState(s.id, .running, "")
        }
    }

    /// 轮询接管的进程是否还活着（拿不到子进程退出回调，只能轮询）
    private func pollAdopted() {
        for (id, pid) in adoptedPids where kill(pid, 0) != 0 {
            adoptedPids[id] = nil
            removePidFile(id)
            if intended[id] == true {
                handleExit(id: id)
            } else {
                setState(id, .stopped, "")
            }
        }
    }

    // MARK: - 启停

    func isOn(_ id: String) -> Bool { intended[id] == true }

    func toggle(_ id: String) { isOn(id) ? stop(id) : start(id) }

    func start(_ id: String) {
        guard procs[id] == nil, restartWork[id] == nil, adoptedPids[id] == nil else { return }
        guard let cfg = statuses.first(where: { $0.id == id })?.config,
              sshArgs(for: cfg) != nil else { return }
        intended[id] = true
        spawn(id)
    }

    private func spawn(_ id: String) {
        guard let cfg = statuses.first(where: { $0.id == id })?.config,
              let args = sshArgs(for: cfg) else {
            intended[id] = nil
            return
        }

        // 上一轮存活超过 60s 视为稳定，重试计数清零
        if let t = startedAt[id], Date().timeIntervalSince(t) > 60 { attempts[id] = 0 }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = freshLogHandle(id)

        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.handleExit(id: id) }
        }

        do {
            try p.run()
        } catch {
            intended[id] = nil
            lastError[id] = "启动失败: \(error.localizedDescription)"
            setState(id, .stopped, "")
            return
        }
        procs[id] = p
        writePidFile(id, p.processIdentifier)
        startedAt[id] = Date()
        lastError[id] = nil
        setState(id, .running, "")
    }

    private func handleExit(id: String) {
        procs[id] = nil
        removePidFile(id)
        let err = Self.logTail(logFileURL(id))
        guard intended[id] == true else {
            setState(id, .stopped, "")
            return
        }
        let n = (attempts[id] ?? 0) + 1
        attempts[id] = n
        let delay = min(30.0, 1.5 * pow(2, Double(n - 1)))
        if !err.isEmpty {
            lastError[id] = "第\(n)次尝试失败 (\(Self.clockText()))\n\(err)"
        }
        setState(id, .reconnecting, "↻ 第\(n)次重连 · \(Int(delay))s后重试")
        let w = DispatchWorkItem { [weak self] in self?.spawn(id) }
        restartWork[id] = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    func stop(_ id: String) {
        intended[id] = nil
        restartWork[id]?.cancel()
        restartWork[id] = nil
        attempts[id] = 0
        if let p = procs[id] {
            procs[id] = nil
            removePidFile(id)
            if p.isRunning { p.terminate() }
        }
        if let pid = adoptedPids.removeValue(forKey: id) {
            removePidFile(id)
            kill(pid, SIGTERM)
        }
        setState(id, .stopped, "")
    }

    func stopAll() {
        for s in statuses { stop(s.id) }
    }

    func errorText(_ id: String) -> String? {
        lastError[id]
    }

    func uptimeText(_ id: String) -> String? {
        guard statuses.first(where: { $0.id == id })?.state == .running,
              let t = startedAt[id] else { return nil }
        let sec = Int(Date().timeIntervalSince(t))
        if sec < 0 { return nil }
        if sec < 60 { return "\(sec)s" }
        if sec < 3600 { return "\(sec / 60)分钟" }
        return "\(sec / 3600)小时\(max(0, sec % 3600 / 60))分"
    }

    // MARK: - 私有工具

    private func setState(_ id: String, _ s: TunnelState, _ detail: String) {
        guard let i = statuses.firstIndex(where: { $0.id == id }) else { return }
        statuses[i].state = s
        statuses[i].detail = detail
    }

    private static func clockText() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }

    /// 取隧道 stderr 日志末尾几行作为错误摘要
    private static func logTail(_ url: URL) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        let lines = text.split(separator: "\n").map { String($0) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return "" }
        return String(lines.suffix(6).joined(separator: "\n").suffix(600))
    }
}
