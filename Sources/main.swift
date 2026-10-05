// TunnelBar — macOS 菜单栏 SSH 隧道管理器
// 每条隧道一个 ssh -N -L 进程，退出后指数退避自动重连（autossh 风格）
// 隧道进程生命周期独立于 app：退出 app 不杀隧道，重启后按 pid 文件接管
// 配置: ~/.config/tunnel-bar/config.json

import SwiftUI
import AppKit

// MARK: - 配置模型

struct TunnelConfig: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    /// ~/.ssh/config 里的别名，或 user@host -p port 形式
    var sshTarget: String
    /// 每项是一条 -L 参数值，如 "127.0.0.1:15432:127.0.0.1:5432"，可多条
    var forwards: [String]
    /// 附加 ssh 参数，如 ["-o", "ServerAliveInterval=30"]
    var extraArgs: [String]
    /// 应用启动时自动拉起
    var autoStart: Bool

    init(id: String, name: String, sshTarget: String, forwards: [String],
         extraArgs: [String] = [], autoStart: Bool = false) {
        self.id = id; self.name = name; self.sshTarget = sshTarget
        self.forwards = forwards; self.extraArgs = extraArgs; self.autoStart = autoStart
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        sshTarget = try c.decode(String.self, forKey: .sshTarget)
        forwards = try c.decodeIfPresent([String].self, forKey: .forwards) ?? []
        extraArgs = try c.decodeIfPresent([String].self, forKey: .extraArgs) ?? []
        autoStart = try c.decodeIfPresent(Bool.self, forKey: .autoStart) ?? false
    }
}

struct AppConfig: Codable {
    var tunnels: [TunnelConfig] = []
}

// MARK: - 状态

enum TunnelState {
    case stopped, running, reconnecting
}

struct TunnelStatus: Identifiable {
    let config: TunnelConfig
    var state: TunnelState = .stopped
    var detail: String = ""
    var id: String { config.id }
}

// MARK: - 隧道管理器

final class TunnelManager: ObservableObject {
    static let shared = TunnelManager()

    @Published var statuses: [TunnelStatus] = []

    private var procs: [String: Process] = [:]           // app 自己拉起的 ssh
    private var adoptedPids: [String: pid_t] = [:]       // 重启后接管的 ssh
    private var intended: [String: Bool] = [:]           // 用户是否期望它在跑
    private var attempts: [String: Int] = [:]
    private var startedAt: [String: Date] = [:]
    private var restartWork: [String: DispatchWorkItem] = [:]
    private var oldConfigs: [String: TunnelConfig] = [:]
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

    // MARK: 配置读写

    private func readOrCreateConfig() -> AppConfig {
        let url = Self.configURL
        if !FileManager.default.fileExists(atPath: url.path) {
            let def = AppConfig(tunnels: [
                TunnelConfig(id: "database-forward", name: "数据库访问",
                             sshTarget: "example",
                             forwards: ["127.0.0.1:15432:127.0.0.1:5432"],
                             autoStart: true)
            ])
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = JSONEncoder.output(encoded: def) {
                try? data.write(to: url, options: .atomic)
            }
            return def
        }
        guard let data = try? Data(contentsOf: url),
              let cfg = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            return AppConfig(tunnels: [])
        }
        return cfg
    }

    func loadConfig() {
        let cfg = readOrCreateConfig()
        let newIDs = Set(cfg.tunnels.map(\.id))

        // 已被删除的隧道 → 停掉
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

        // 在跑但配置变了 → 重启生效
        for c in cfg.tunnels where intended[c.id] == true && oldConfigs[c.id] != c {
            stop(c.id)
            start(c.id)
        }
        oldConfigs = Dictionary(uniqueKeysWithValues: cfg.tunnels.map { ($0.id, $0) })
    }

    func editConfig() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-t", Self.configURL.path]
        try? p.run()
    }

    // MARK: pid 文件（跨重启接管用）

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
    private static func processMatches(_ pid: pid_t, config: TunnelConfig) -> Bool {
        guard pid > 0, kill(pid, 0) == 0 else { return false }
        guard let cmd = ps(pid, columns: ["command="]) else { return false }
        return cmd.contains("ssh") && cmd.contains(config.sshTarget)
            && config.forwards.allSatisfy { cmd.contains($0) }
    }

    /// ps -p <pid> -o <columns>，失败返回 nil
    private static func ps(_ pid: pid_t, columns: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-p", String(pid)] + columns
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
            guard Self.processMatches(pid, config: s.config) else {
                removePidFile(s.id)      // 进程没了或 pid 被复用 → 陈旧文件
                continue
            }
            adoptedPids[s.id] = pid
            intended[s.id] = true
            startedAt[s.id] = Self.processStartDate(pid) ?? Date()
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

    // MARK: 启停

    func isOn(_ id: String) -> Bool { intended[id] == true }

    func toggle(_ id: String) { isOn(id) ? stop(id) : start(id) }

    func start(_ id: String) {
        guard procs[id] == nil, restartWork[id] == nil, adoptedPids[id] == nil else { return }
        guard statuses.contains(where: { $0.id == id }) else { return }
        intended[id] = true
        spawn(id)
    }

    private func spawn(_ id: String) {
        guard let cfg = statuses.first(where: { $0.id == id })?.config else { return }

        // 上一轮存活超过 60s 视为稳定，重试计数清零
        if let t = startedAt[id], Date().timeIntervalSince(t) > 60 { attempts[id] = 0 }

        var args = ["-N",
                    "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=4",
                    "-o", "ExitOnForwardFailure=yes", "-o", "ConnectTimeout=10"]
        for f in cfg.forwards { args += ["-L", f] }
        args += cfg.extraArgs
        args.append(cfg.sshTarget)

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

    // MARK: 私有工具

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

private extension JSONEncoder {
    static func output<T: Encodable>(encoded value: T) -> Data? {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? e.encode(value)
    }
}

// MARK: - 菜单栏面板 UI

@main
struct TunnelBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @ObservedObject private var manager = TunnelManager.shared

    var body: some Scene {
        MenuBarExtra {
            TunnelPanel()
        } label: {
            Image(systemName: manager.statuses.contains { $0.state == .reconnecting }
                  ? "arrow.triangle.2.circlepath"
                  : "arrow.left.arrow.right")
        }
        .menuBarExtraStyle(.window)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    // 隧道生命周期独立于 app：退出不杀 ssh（无终端的子进程会被 launchd 接管继续跑），
    // pid 文件留在 run/ 目录供下次启动接管。要停隧道用面板里的开关或「全部停止」。
    func applicationWillTerminate(_ notification: Notification) {}
}

struct TunnelPanel: View {
    @ObservedObject var manager = TunnelManager.shared
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            if manager.statuses.isEmpty {
                Text("暂无隧道 · 点右上角 ✎ 编辑配置添加")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 28)
            }
            ForEach(manager.statuses) { row($0) }
            Divider().padding(.vertical, 8)
            footer
        }
        .padding(12)
        .frame(width: 360)
    }

    // MARK: 每条隧道一行

    @ViewBuilder
    private func row(_ t: TunnelStatus) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(t.state == .running ? Color.green
                        : t.state == .reconnecting ? Color.orange : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.config.name).font(.system(size: 13, weight: .medium))
                    Text(subtitle(t))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if manager.errorText(t.id) != nil, t.state != .running {
                    Button {
                        toggleExpand(t.id)
                    } label: {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                            .help("查看错误")
                    }
                    .buttonStyle(.borderless)
                }
                Toggle("", isOn: switchBinding(t))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
            if expanded.contains(t.id), let err = manager.errorText(t.id) {
                Text(err)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 4).fill(Color.red.opacity(0.08)))
            }
        }
        .padding(.vertical, 5)
        if t.id != manager.statuses.last?.id { Divider() }
    }

    private func switchBinding(_ t: TunnelStatus) -> Binding<Bool> {
        Binding(
            get: { manager.isOn(t.id) },
            set: { _ in manager.toggle(t.id) }
        )
    }

    private func subtitle(_ t: TunnelStatus) -> String {
        var parts: [String] = []
        switch t.state {
        case .running:
            parts.append(manager.uptimeText(t.id).map { "已连 \($0)" } ?? "运行中")
            parts.append(Self.forwardSummary(t.config.forwards))
        case .reconnecting:
            parts.append(t.detail)
        case .stopped:
            parts.append(t.config.sshTarget)
            parts.append(Self.forwardSummary(t.config.forwards))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// "127.0.0.1:15432:127.0.0.1:5432" → "15432→5432"
    private static func forwardSummary(_ forwards: [String]) -> String {
        forwards.map { f in
            let c = f.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            if c.count == 4,
               ["127.0.0.1", "localhost", "[::1]"].contains(c[0]),
               ["127.0.0.1", "localhost", "[::1]"].contains(c[2]) {
                return "\(c[1])→\(c[3])"
            }
            return f
        }.joined(separator: " ")
    }

    private func toggleExpand(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    // MARK: 底部操作

    private var footer: some View {
        HStack(spacing: 12) {
            Button("全部启动") {
                for s in manager.statuses { manager.start(s.id) }
            }
            Button("全部停止") { manager.stopAll() }
            Spacer()
            Button { manager.editConfig() } label: {
                Image(systemName: "square.and.pencil").help("编辑配置")
            }
            Button { manager.loadConfig() } label: {
                Image(systemName: "arrow.clockwise").help("重新载入配置")
            }
            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power").help("退出 TunnelBar（隧道继续运行）")
            }
        }
        .buttonStyle(.link)
        .font(.system(size: 12))
    }
}
