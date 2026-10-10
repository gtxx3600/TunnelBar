import SwiftUI
import AppKit

/// 线上配置与纯展示编辑器的边界；只有明确保存才应用草稿。
struct ConfigEditor: View {
    @ObservedObject var manager = TunnelManager.shared
    @State private var initialFrameSet = false
    @StateObject private var loginItem = LoginItemController()

    var body: some View {
        ConfigWorkspaceView(
            config: manager.current,
            runtime: Dictionary(uniqueKeysWithValues: manager.statuses.compactMap { status in
                switch status.state {
                case .running: return (status.id, ConfigRuntimeState.running)
                case .reconnecting: return (status.id, ConfigRuntimeState.reconnecting)
                case .connecting: return (status.id, ConfigRuntimeState.connecting)
                case .needsAttention: return (status.id, ConfigRuntimeState.needsAttention)
                case .unverified: return (status.id, ConfigRuntimeState.unverified)
                case .stopped: return nil
                }
            }),
            configError: manager.configError,
            loginState: loginItem.state, loginError: loginItem.errorMessage,
            setLoginEnabled: loginItem.setEnabled, refreshLogin: loginItem.refresh,
            openLoginSettings: loginItem.openSettings,
            importFile: ConfigFilePanels.chooseImport,
            exportFile: { try ConfigFilePanels.export($0, protecting: TunnelManager.configURL) },
            save: { updated, original, imported in
                guard manager.current == original else {
                    throw ConfigStoreError.invalid("配置已在其他位置更新，请撤销修改并载入最新配置后再保存")
                }
                try manager.applyConfig(updated, backupBeforeImport: imported)
            }
        )
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
        }
        .onAppear {
            loginItem.refresh()
            guard !initialFrameSet else { return }
            initialFrameSet = true
            DispatchQueue.main.async {
                guard let window = NSApp.windows.first(where: { $0.title == "TunnelBar 配置" }) else { return }
                let size = window.contentRect(forFrameRect: window.frame).size
                if size.width < 920 || size.height < 700 {
                    window.setContentSize(NSSize(width: max(size.width, 920), height: max(size.height, 700)))
                }
            }
        }
    }
}
