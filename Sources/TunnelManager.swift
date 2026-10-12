// 隧道管理器：进程生命周期 / 接管 / 重连 / 配置应用

import SwiftUI
import AppKit
import Darwin

enum TunnelState {
    case stopped, connecting, running, reconnecting, needsAttention, unverified
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
    @Published private(set) var configError: String?
    private(set) var current = AppConfig()

    private let configStore: ConfigStore
    private let sshExecutable: URL
    private var hasLoadedConfig = false
    private var isExiting = false
    private var ambiguousIDs: Set<String> = []

    private var procs: [String: Process] = [:]           // app 自己拉起的 ssh
    private var adoptedPids: [String: pid_t] = [:]       // 重启后接管的 ssh
    private var intended: [String: Bool] = [:]           // 用户是否期望它在跑
    private var attempts: [String: Int] = [:]
    private var startedAt: [String: Date] = [:]
    private var restartWork: [String: (token: UUID, work: DispatchWorkItem)] = [:]
    private var argSigs: [String: [String]] = [:]        // 在跑隧道的生效参数
    private var lastError: [String: String] = [:]
    private var logReaders: [String: SSHLogReader] = [:]
    private var launchedAt: [String: Date] = [:]
    private var retiring: [String: [(pid: pid_t, args: [String])]] = [:]
    private var waitingSince: [String: Date] = [:]
    private var lastAdoptedPoll = Date.distantPast
    private var timer: Timer?

    static var configURL: URL {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: home)
            .appendingPathComponent(".config/tunnel-bar/config.json")
    }

    static var runDir: URL {
        configURL.deletingLastPathComponent().appendingPathComponent("run")
    }

    /// 可注入临时配置和模拟 SSH 程序，测试不接触用户隧道。
    init(configURL: URL = TunnelManager.configURL,
         sshExecutable: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
         autoStartOnLaunch: Bool = !CommandLine.arguments.contains("--no-autostart")) {
        configStore = ConfigStore(url: configURL)
        self.sshExecutable = sshExecutable
        loadConfig()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, !self.isExiting else { return }
                if Date().timeIntervalSince(self.lastAdoptedPoll) >= 1 {
                    self.pollAdopted()
                    self.trimLogs()
                    self.lastAdoptedPoll = Date()
                }
                self.refreshReadiness()
                self.objectWillChange.send()
            }
        }
        // 更新应用时可用 --no-autostart 保留当前连接状态；仅影响本次启动，不修改配置。
        if autoStartOnLaunch {
            for s in statuses where s.config.autoStart && !isOn(s.id) {
                start(s.id)
            }
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
        var args = ["-N", "-o", "LogLevel=DEBUG1",
                    "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=4",
                    "-o", "ExitOnForwardFailure=yes", "-o", "ConnectTimeout=10"]
        if let port = Int(n.port.trimmingCharacters(in: .whitespaces)), port > 0 {
            args += ["-p", n.port.trimmingCharacters(in: .whitespaces)]
        }
        if !n.identityFile.trimmingCharacters(in: .whitespaces).isEmpty {
            args += ["-i", n.identityFile.trimmingCharacters(in: .whitespaces)]
        }
        for f in tunnel.forwards {
            guard let a = f.arg else { continue }
            args += ["-\(f.type)", a]
        }
        args += tunnel.extraArgs
        args.append(n.sshTarget)
        return args
    }

    // MARK: - 配置

    @discardableResult
    func loadConfig() -> Bool {
        guard !isExiting else { return false }
        do {
            let cfg = try configStore.load(createIfMissing: !hasLoadedConfig)
            reconcileConfig(cfg)
            hasLoadedConfig = true
            configError = nil
            return true
        } catch {
            configError = "配置读取失败，原文件和现有隧道已保留：\(error.localizedDescription)"
            return false
        }
    }

    private func reconcileConfig(_ cfg: AppConfig) {
        let newIDs = Set(cfg.tunnels.map(\.id))
        // 删除隧道也要取消待重连任务；此时仍使用旧配置校验被停止的进程。
        for id in Set(intended.keys).union(procs.keys).union(adoptedPids.keys).union(restartWork.keys)
            where !newIDs.contains(id) { stop(id) }
        current = cfg

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
            if let args = sshArgs(for: c), argSigs[c.id] != args {
                stop(c.id)
                start(c.id)
            }
        }
        argSigs = Dictionary(uniqueKeysWithValues: cfg.tunnels.compactMap { c in
            sshArgs(for: c).map { (c.id, $0) }
        })
        adoptExisting()
    }

    /// 配置窗口「保存」入口：落盘成功后应用，拉起新增的 autoStart 隧道。
    func applyConfig(_ cfg: AppConfig, backupBeforeImport: Bool = false) throws {
        guard !isExiting else { throw ConfigStoreError.invalid("应用正在退出") }
        let oldIDs = Set(current.tunnels.map(\.id))
        do {
            try configStore.save(cfg, backupBeforeImport: backupBeforeImport)
        } catch {
            configError = "配置保存失败，现有隧道已保留：\(error.localizedDescription)"
            throw error
        }
        reconcileConfig(cfg)
        hasLoadedConfig = true
        configError = nil
        for t in cfg.tunnels where !oldIDs.contains(t.id) && t.autoStart && !isOn(t.id) {
            start(t.id)
        }
    }

    func editConfig() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-t", configStore.url.path]
        try? p.run()
    }

    // MARK: - pid / 日志文件（跨重启接管用）

    private var runtimeDirectory: URL {
        configStore.url.deletingLastPathComponent().appendingPathComponent("run")
    }

    private func pidFileURL(_ id: String) -> URL {
        runtimeDirectory.appendingPathComponent("\(id).pid")
    }

    /// stderr 落盘成文件：app 退出后孤儿 ssh 仍有合法的写入端，重启接管后还能读错误
    private func logFileURL(_ id: String) -> URL {
        runtimeDirectory.appendingPathComponent("\(id).log")
    }

    private func logOwnerURL(_ id: String) -> URL {
        runtimeDirectory.appendingPathComponent("\(id).log.pid")
    }

    private func readyFileURL(_ id: String) -> URL {
        runtimeDirectory.appendingPathComponent("\(id).ready.pid")
    }

    private func writePidFile(_ id: String, _ pid: pid_t) {
        try? PrivateStorage.write(Data(String(pid).utf8), to: pidFileURL(id))
    }

    private func removePidFile(_ id: String) {
        try? FileManager.default.removeItem(at: pidFileURL(id))
        try? FileManager.default.removeItem(at: readyFileURL(id))
        try? FileManager.default.removeItem(at: logOwnerURL(id))
    }

    /// 核对可执行文件和完整 argv，避免子串匹配把别的 SSH 连接当成当前隧道。
    private func processMatches(_ pid: pid_t, args: [String]) -> Bool {
        guard pid > 0, kill(pid, 0) == 0 else { return false }
        guard let command = Self.processCommand(pid),
              command.executable == sshExecutable.resolvingSymlinksInPath().path else { return false }
        if command.args == args { return true }
        // 兼容旧版本调整过选项顺序；同一个选项的多个值仍按原顺序比较。
        // 新增的诊断日志选项不改变连接语义，升级仍接管旧进程。
        guard let actual = Self.groupSSHOptions(command.args),
              let expected = Self.groupSSHOptions(args) else { return false }
        return actual == expected || actual == Self.groupSSHOptions(Self.withoutDiagnosticOption(args))
    }

    private static func withoutDiagnosticOption(_ args: [String]) -> [String] {
        var result = args
        if let index = result.indices.dropLast().first(where: { result[$0] == "-o" && result[$0 + 1] == "LogLevel=DEBUG1" }) {
            result.removeSubrange(index...index + 1)
        }
        return result
    }

    private static func groupSSHOptions(_ args: [String]) -> [String: [String]]? {
        guard let target = args.last else { return nil }
        let optionsWithValue: Set<String> = ["-o", "-L", "-R", "-D", "-p", "-i", "-F", "-l", "-J", "-b", "-c", "-m", "-S", "-E", "-w"]
        var groups: [String: [String]] = ["target": [target]]
        var i = 0
        while i < args.count - 1 {
            let option = args[i]
            guard option.hasPrefix("-") else { return nil }
            if optionsWithValue.contains(option) {
                guard i + 1 < args.count - 1 else { return nil }
                groups[option, default: []].append(args[i + 1])
                i += 2
            } else {
                groups[option, default: []].append("")
                i += 1
            }
        }
        return groups
    }

    /// KERN_PROCARGS2 保留参数边界；ps 的文本命令行无法区分含空格的参数。
    private static func processCommand(_ pid: pid_t) -> (executable: String, args: [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        let result = bytes.withUnsafeMutableBytes {
            sysctl(&mib, UInt32(mib.count), $0.baseAddress, &size, nil, 0)
        }
        guard result == 0 else { return nil }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc < 65536 else { return nil }
        var cursor = MemoryLayout<Int32>.size
        func nextString() -> String? {
            guard cursor < size, let end = bytes[cursor..<size].firstIndex(of: 0) else { return nil }
            let value = String(bytes: bytes[cursor..<end], encoding: .utf8)
            cursor = end + 1
            return value
        }
        guard let executable = nextString() else { return nil }
        while cursor < size && bytes[cursor] == 0 { cursor += 1 }
        var argv: [String] = []
        for _ in 0..<argc {
            guard let argument = nextString() else { return nil }
            argv.append(argument)
        }
        return (URL(fileURLWithPath: executable).resolvingSymlinksInPath().path, Array(argv.dropFirst()))
    }

    private func matchingCandidates() -> [pid_t] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,comm="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0, let text = String(data: output, encoding: .utf8) else { return [] }
            let executable = sshExecutable.resolvingSymlinksInPath().path
            return text.split(separator: "\n").compactMap { line in
                let fields = line.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
                guard fields.count == 2,
                      String(fields[1]).trimmingCharacters(in: .whitespaces) == executable else { return nil }
                return pid_t(fields[0])
            }
        } catch { return [] }
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
        ambiguousIDs = []
        let candidates = matchingCandidates()
        var claimed = Set(procs.values.map(\.processIdentifier)).union(adoptedPids.values)
        for s in statuses where procs[s.id] == nil && adoptedPids[s.id] == nil && restartWork[s.id] == nil {
            guard let args = sshArgs(for: s.config) else { continue }
            let text = try? String(contentsOf: pidFileURL(s.id), encoding: .utf8)
            let recorded = text.flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            let matches: [pid_t]
            if let pid = recorded, !claimed.contains(pid), processMatches(pid, args: args) {
                matches = [pid]
            } else {
                // 旧版本竞态可能丢了 pid 文件；仅恢复唯一且参数完整匹配的进程。
                matches = candidates.filter { !claimed.contains($0) && processMatches($0, args: args) }
            }
            guard matches.count == 1, let pid = matches.first else {
                if matches.count > 1 {
                    ambiguousIDs.insert(s.id)
                    lastError[s.id] = "发现多个匹配的 SSH 进程，已保留连接；请先处理重复进程再重新载入配置"
                    setState(s.id, .needsAttention, "发现多个匹配进程，请处理后重新载入配置。")
                }
                removePidFile(s.id)
                continue
            }
            claimed.insert(pid)
            adoptedPids[s.id] = pid
            writePidFile(s.id, pid)
            intended[s.id] = true
            startedAt[s.id] = Self.processStartDate(pid) ?? Date()
            argSigs[s.id] = args
            let logOwner = try? String(contentsOf: logOwnerURL(s.id), encoding: .utf8)
            let readyOwner = try? String(contentsOf: readyFileURL(s.id), encoding: .utf8)
            if logOwner == String(pid), readyOwner == String(pid) {
                setState(s.id, .running, "SSH 连接与转发已建立；目标服务未主动探测。")
            } else if logOwner == String(pid) {
                logReaders[s.id] = SSHLogReader()
                launchedAt[s.id] = startedAt[s.id]
                setState(s.id, .connecting, "正在确认已有连接的转发状态…")
            } else {
                setState(s.id, .unverified, "已接管现有进程；缺少本次连接的确认记录，连接继续保留。")
            }
        }
        refreshReadiness()
    }

    private func refreshReadiness() {
        guard !isExiting else { return }
        for status in statuses where status.state == .connecting || status.state == .unverified {
            let id = status.id
            guard procs[id]?.isRunning == true || adoptedPids[id] != nil,
                  var reader = logReaders[id] else { continue }
            reader.update(from: logFileURL(id))
            logReaders[id] = reader
            if reader.evidence.isReady(for: status.config.forwards) {
                lastError[id] = nil
                if let pid = procs[id]?.processIdentifier ?? adoptedPids[id] {
                    try? PrivateStorage.write(Data(String(pid).utf8), to: readyFileURL(id))
                }
                setState(id, .running, "SSH 连接与转发已建立；目标服务未主动探测。")
            } else if let launched = launchedAt[id], Date().timeIntervalSince(launched) >= 30 {
                setState(id, .unverified, "SSH 仍在运行，尚未收到完整转发确认；请查看诊断。")
            }
        }
    }

    private func trimLogs() {
        for status in statuses where status.state == .running {
            guard let pid = procs[status.id]?.processIdentifier ?? adoptedPids[status.id],
                  (try? String(contentsOf: readyFileURL(status.id), encoding: .utf8)) == String(pid) else { continue }
            SSHLogReader.trimIfNeeded(logFileURL(status.id))
        }
    }

    /// 轮询接管的进程是否还活着（拿不到子进程退出回调，只能轮询）
    private func pollAdopted() {
        guard !isExiting else { return }
        for (id, pid) in adoptedPids where !processMatches(pid, args: argSigs[id] ?? []) {
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
        guard !isExiting else { return }
        if ambiguousIDs.contains(id) { adoptExisting() }
        guard !ambiguousIDs.contains(id) else { return }
        guard procs[id] == nil, restartWork[id] == nil, adoptedPids[id] == nil else { return }
        guard let cfg = statuses.first(where: { $0.id == id })?.config,
              sshArgs(for: cfg) != nil else { return }
        intended[id] = true
        waitingSince[id] = Date()
        lastError[id] = nil
        spawn(id)
    }

    private func spawn(_ id: String) {
        guard !isExiting, intended[id] == true, procs[id] == nil, adoptedPids[id] == nil else { return }
        guard let cfg = statuses.first(where: { $0.id == id })?.config,
              let args = sshArgs(for: cfg), let node = node(cfg.nodeId) else {
            intended[id] = nil
            return
        }

        // 等旧进程释放监听端口，再做预检；快速启停不会误报自己的端口占用。
        retiring[id] = retiring[id]?.filter { processMatches($0.pid, args: $0.args) }
        if !(retiring[id] ?? []).isEmpty {
            let began = waitingSince[id] ?? Date()
            waitingSince[id] = began
            guard Date().timeIntervalSince(began) < 3 else {
                fail(id, TunnelFailure(kind: .portInUse, title: "上一条连接尚未退出", suggestion: "请稍候再重试，避免重复占用监听端口。", retryable: false))
                return
            }
            setState(id, .connecting, "等待上一条连接释放监听端口…")
            scheduleSpawn(id, after: 0.1)
            return
        }
        waitingSince[id] = nil
        if let failure = TunnelPreflight.check(cfg, node: node) {
            fail(id, failure)
            return
        }

        let log: FileHandle
        do {
            log = try PrivateStorage.logHandle(at: logFileURL(id))
        } catch {
            fail(id, TunnelFailure(kind: .configuration, title: "无法创建连接诊断日志", suggestion: error.localizedDescription, retryable: false))
            return
        }
        defer { try? log.close() }

        let p = Process()
        p.executableURL = sshExecutable
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = log

        p.terminationHandler = { [weak self] exited in
            DispatchQueue.main.async {
                // stop/start 后的旧回调不能清除新进程、PID 文件或重连任务。
                guard let self, !self.isExiting, self.procs[id] === exited else { return }
                self.procs[id] = nil
                self.handleExit(id: id)
            }
        }

        do {
            try p.run()
        } catch {
            fail(id, TunnelFailure(kind: .configuration, title: "SSH 启动失败", suggestion: error.localizedDescription, retryable: false))
            return
        }
        procs[id] = p
        argSigs[id] = args
        writePidFile(id, p.processIdentifier)
        try? PrivateStorage.write(Data(String(p.processIdentifier).utf8), to: logOwnerURL(id))
        logReaders[id] = SSHLogReader()
        launchedAt[id] = Date()
        startedAt[id] = Date()
        lastError[id] = nil
        setState(id, .connecting, "正在进行 SSH 认证并建立转发…")
    }

    private func handleExit(id: String) {
        guard !isExiting else { return }
        let wasEstablished = statuses.first(where: { $0.id == id })?.state == .running
        removePidFile(id)
        logReaders[id] = nil
        launchedAt[id] = nil
        let err = SSHLogReader.tail(logFileURL(id))
        guard intended[id] == true else {
            setState(id, .stopped, "")
            return
        }
        var failure = TunnelFailure.classify(err)
        // 已建立的连接可能留有启动时的非致命警告；不能用旧警告阻止断线恢复。
        if wasEstablished && !failure.retryable {
            failure = TunnelFailure(kind: .network, title: "SSH 连接已中断", suggestion: "将自动重试；如果连接持续失败，请查看最新诊断。", retryable: true)
        }
        if !failure.retryable {
            fail(id, failure, raw: err)
            return
        }
        // 按退出时的实际运行时长判断稳定，避免把等待重连的时间算进去。
        if let t = startedAt[id], Date().timeIntervalSince(t) >= 60 { attempts[id] = 0 }
        let n = (attempts[id] ?? 0) + 1
        attempts[id] = n
        let delay = min(30.0, 1.5 * pow(2, Double(min(n - 1, 5))))
        lastError[id] = failure.message + (err.isEmpty ? "" : "\n\n" + err)
        setState(id, .reconnecting, "\(failure.title) · 第\(n)次重连，\(Int(delay))s 后重试")
        scheduleSpawn(id, after: delay)
    }

    private func scheduleSpawn(_ id: String, after delay: TimeInterval) {
        let token = UUID()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.restartWork[id]?.token == token else { return }
            self.restartWork[id] = nil
            self.spawn(id)
        }
        restartWork[id] = (token, w)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    private func fail(_ id: String, _ failure: TunnelFailure, raw: String = "") {
        intended[id] = nil
        restartWork[id]?.work.cancel()
        restartWork[id] = nil
        lastError[id] = failure.message + (raw.isEmpty ? "" : "\n\n" + raw)
        setState(id, .needsAttention, failure.message)
    }

    func stop(_ id: String) {
        intended[id] = nil
        restartWork[id]?.work.cancel()
        restartWork[id] = nil
        attempts[id] = 0
        waitingSince[id] = nil
        launchedAt[id] = nil
        logReaders[id] = nil
        lastError[id] = nil
        if let p = procs[id] {
            procs[id] = nil
            removePidFile(id)
            if p.isRunning {
                retiring[id, default: []].append((p.processIdentifier, argSigs[id] ?? []))
                p.terminate()
            }
        }
        if let pid = adoptedPids.removeValue(forKey: id) {
            removePidFile(id)
            if processMatches(pid, args: argSigs[id] ?? []) {
                retiring[id, default: []].append((pid, argSigs[id] ?? []))
                kill(pid, SIGTERM)
            }
        }
        setState(id, .stopped, "")
    }

    func stopAll() {
        for s in statuses { stop(s.id) }
    }

    /// nil 仅代表未分组；操作时使用当前归属，避免编辑后影响原分组。
    func startGroup(_ id: String?) {
        for tunnelID in current.tunnelIDs(inGroup: id) { start(tunnelID) }
    }

    func stopGroup(_ id: String?) {
        for tunnelID in current.tunnelIDs(inGroup: id) { stop(tunnelID) }
    }

    /// 普通退出只停止 app 内的监控/重试，保留所有 SSH 进程和 PID 文件供下次校准。
    func prepareForAppExit() {
        isExiting = true
        timer?.invalidate()
        timer = nil
        for pending in restartWork.values { pending.work.cancel() }
        restartWork.removeAll()
        for process in procs.values { process.terminationHandler = nil }
    }

    func errorText(_ id: String) -> String? {
        lastError[id]
    }

    func diagnosticText(_ id: String) -> String? {
        // 已停止的隧道仍保留 SSH 日志；普通退出输出不应重新变成错误提示。
        guard let state = statuses.first(where: { $0.id == id })?.state,
              state != .running, state != .stopped else { return nil }
        if let error = lastError[id] { return error }
        let text = SSHLogReader.tail(logFileURL(id))
        return text.isEmpty ? nil : text
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

}
