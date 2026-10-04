// TunnelBar — macOS 菜单栏 SSH 隧道管理器
// 每条隧道一个 ssh -N -L 进程，退出后指数退避自动重连（autossh 风格）
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

    private var procs: [String: Process] = [:]
    private var intended: [String: Bool] = [:]      // 用户是否期望它在跑
    private var attempts: [String: Int] = [:]
    private var startedAt: [String: Date] = [:]
    private var restartWork: [String: DispatchWorkItem] = [:]
    private var oldConfigs: [String: TunnelConfig] = [:]
    private var lastError: [String: String] = [:]
    private var lastErrorAt: [String: Date] = [:]
    private var timer: Timer?

    static var configURL: URL {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: home)
            .appendingPathComponent(".config/tunnel-bar/config.json")
    }

    init() {
        loadConfig()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.objectWillChange.send() }
        }
        for s in statuses where s.config.autoStart {
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

    // MARK: 启停

    func isOn(_ id: String) -> Bool { intended[id] == true }

    func toggle(_ id: String) { isOn(id) ? stop(id) : start(id) }

    func start(_ id: String) {
        guard procs[id] == nil, restartWork[id] == nil else { return }
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
        let errPipe = Pipe()
        p.standardError = errPipe

        p.terminationHandler = { [weak self] _ in
            let err = Self.stderrTail(errPipe)
            DispatchQueue.main.async { self?.handleExit(id: id, err: err) }
        }

        do {
            try p.run()
        } catch {
            intended[id] = nil
            lastError[id] = "启动失败: \(error.localizedDescription)"
            lastErrorAt[id] = Date()
            setState(id, .stopped, "")
            return
        }
        procs[id] = p
        startedAt[id] = Date()
        lastError[id] = nil
        setState(id, .running, "")
    }

    private func handleExit(id: String, err: String) {
        procs[id] = nil
        guard intended[id] == true else {
            setState(id, .stopped, "")
            return
        }
        let n = (attempts[id] ?? 0) + 1
        attempts[id] = n
        let delay = min(30.0, 1.5 * pow(2, Double(n - 1)))
        if !err.isEmpty {
            lastError[id] = "第\(n)次尝试失败 (\(Self.clockText()))\n\(err)"
            lastErrorAt[id] = Date()
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
            if p.isRunning { p.terminate() }
        }
        setState(id, .stopped, "")
    }

    func stopAll() {
        for s in statuses { stop(s.id) }
    }

    func errorText(_ id: String) -> String? {
        guard lastError[id] != nil else { return nil }
        return lastError[id]!
    }

    func uptimeText(_ id: String) -> String? {
        guard statuses.first(where: { $0.id == id })?.state == .running,
              let t = startedAt[id] else { return nil }
        let sec = Int(Date().timeIntervalSince(t))
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

    /// 取 stderr 末尾几行作为错误摘要
    private static func stderrTail(_ pipe: Pipe) -> String {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return "" }
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
    func applicationWillTerminate(_ notification: Notification) {
        TunnelManager.shared.stopAll()
    }
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
                Image(systemName: "power").help("退出 TunnelBar")
            }
        }
        .buttonStyle(.link)
        .font(.system(size: 12))
    }
}
