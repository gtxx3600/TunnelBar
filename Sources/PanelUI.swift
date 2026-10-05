// 菜单栏入口 + 面板

import SwiftUI
import AppKit

@main
struct TunnelBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @ObservedObject private var manager = TunnelManager.shared

    /// 调试: TUNNELBAR_OPEN_CONFIG=1 启动时直接弹配置窗口（截图/走查用）
    static let debugOpenConfig = ProcessInfo.processInfo.environment["TUNNELBAR_OPEN_CONFIG"] == "1"

    var body: some Scene {
        MenuBarExtra {
            TunnelPanel()
        } label: {
            MenuIcon(reconnecting: manager.statuses.contains { $0.state == .reconnecting })
        }
        .menuBarExtraStyle(.window)

        Window("TunnelBar 配置", id: "cfg") {
            ConfigEditor()
        }
        .defaultSize(width: 720, height: 520)
    }
}

/// 菜单栏图标；调试模式下顺带自动弹配置窗口（截图/走查用）
struct MenuIcon: View {
    @Environment(\.openWindow) private var openWindow
    let reconnecting: Bool

    var body: some View {
        Image(systemName: reconnecting ? "arrow.triangle.2.circlepath" : "arrow.left.arrow.right")
            .onAppear {
                if TunnelBarApp.debugOpenConfig {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        NSApp.activate(ignoringOtherApps: true)
                        openWindow(id: "cfg")
                    }
                }
            }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if TunnelBarApp.debugOpenConfig {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // 隧道生命周期独立于 app：退出不杀 ssh（无终端的子进程会被 launchd 接管继续跑），
    // pid 文件留在 run/ 目录供下次启动接管。要停隧道用面板里的开关或「全部停止」。
    func applicationWillTerminate(_ notification: Notification) {}
}

struct TunnelPanel: View {
    @ObservedObject var manager = TunnelManager.shared
    @State private var expanded: Set<String> = []
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            if manager.statuses.isEmpty {
                Text("暂无隧道 · 点右上角 ⚙ 添加")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 28)
            }
            ForEach(manager.statuses) { row($0) }
            Divider().padding(.vertical, 8)
            footer
        }
        .padding(12)
        .frame(width: 380)
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
            parts.append(manager.nodeName(t.config.nodeId))
            parts.append(Self.forwardSummary(t.config.forwards))
        case .reconnecting:
            parts.append(t.detail)
        case .stopped:
            parts.append(manager.nodeName(t.config.nodeId))
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
            Button {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "cfg")
            } label: {
                Image(systemName: "gearshape").help("配置（节点 / 隧道）")
            }
            Button { manager.editConfig() } label: {
                Image(systemName: "doc.text").help("打开原始 JSON")
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
