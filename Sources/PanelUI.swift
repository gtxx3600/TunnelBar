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
    func applicationWillTerminate(_ notification: Notification) {
        TunnelManager.shared.prepareForAppExit()
    }
}

struct TunnelPanel: View {
    @ObservedObject var manager = TunnelManager.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        TunnelPanelView(
            items: manager.statuses.map { status in
                TunnelPanelItem(id: status.id, name: status.config.name,
                                nodeName: manager.nodeName(status.config.nodeId),
                                forwards: status.config.forwards.filter { $0.arg != nil },
                                state: status.state, isOn: manager.isOn(status.id),
                                uptime: manager.uptimeText(status.id),
                                detail: status.detail, error: manager.errorText(status.id))
            },
            configError: manager.configError,
            actions: TunnelPanelActions(
                toggle: { id, enabled in
                    if enabled { manager.start(id) } else { manager.stop(id) }
                },
                configure: {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "cfg")
                },
                startAll: { for status in manager.statuses { manager.start(status.id) } },
                stopAll: { manager.stopAll() },
                openConfig: { manager.editConfig() },
                reload: { manager.loadConfig() },
                quit: { NSApp.terminate(nil) }
            )
        )
    }
}
