import Foundation
import Combine
import ServiceManagement

enum LoginItemState {
    case notRegistered, enabled, requiresApproval, notFound

    var isRequested: Bool { self == .enabled || self == .requiresApproval }
    var description: String {
        switch self {
        case .notRegistered: return "已关闭"
        case .enabled: return "已开启，下次登录时启动"
        case .requiresApproval: return "等待允许，请在系统设置中开启 TunnelBar 登录项"
        case .notFound: return "尚未设置，可开启登录时启动"
        }
    }
}

protocol LoginItemService {
    var state: LoginItemState { get }
    func register() throws
    func unregister() throws
    func openSettings()
}

struct SystemLoginItemService: LoginItemService {
    var state: LoginItemState {
        switch SMAppService.mainApp.status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .notFound
        }
    }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// 显示系统实际状态，不另外存储可能失真的 UserDefaults 开关。
final class LoginItemController: ObservableObject {
    @Published private(set) var state: LoginItemState
    @Published private(set) var errorMessage: String?
    private let service: LoginItemService

    init(service: LoginItemService = SystemLoginItemService()) {
        self.service = service
        state = service.state
    }

    func refresh() {
        let updated = service.state
        if updated != state { errorMessage = nil }
        state = updated
    }

    func setEnabled(_ enabled: Bool) {
        refresh()
        guard enabled != state.isRequested else { return }
        errorMessage = nil
        do {
            if enabled { try service.register() } else { try service.unregister() }
        } catch {
            errorMessage = "登录项设置失败：\(error.localizedDescription)"
        }
        state = service.state
    }

    func openSettings() { service.openSettings() }
}
