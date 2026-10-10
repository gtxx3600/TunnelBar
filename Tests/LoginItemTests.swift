import Foundation

private final class FakeLoginItemService: LoginItemService {
    var state: LoginItemState = .notRegistered
    var nextState: LoginItemState = .enabled
    var failure: Error?
    var registrations = 0, removals = 0, openedSettings = 0
    func register() throws {
        registrations += 1
        if let failure { throw failure }
        state = nextState
    }
    func unregister() throws {
        removals += 1
        if let failure { throw failure }
        state = .notRegistered
    }
    func openSettings() { openedSettings += 1 }
}

@main
struct LoginItemTests {
    static func check(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: "LoginItemTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func main() throws {
        let service = FakeLoginItemService()
        let controller = LoginItemController(service: service)
        try check(!controller.state.isRequested && service.registrations == 0, "Opening settings must not enable login startup")
        controller.setEnabled(true)
        try check(controller.state == .enabled && service.registrations == 1, "Enabling must register and read actual system state")
        controller.setEnabled(true)
        try check(service.registrations == 1, "Repeated enable must not register twice")
        service.state = .requiresApproval; controller.refresh()
        try check(controller.state == .requiresApproval, "External system changes must refresh and must not report enabled")
        controller.openSettings()
        try check(service.openedSettings == 1, "Approval guidance must open login item settings")
        controller.setEnabled(false)
        try check(controller.state == .notRegistered && service.removals == 1, "Pending registration must be removable")
        service.nextState = .requiresApproval; controller.setEnabled(true)
        try check(controller.state == .requiresApproval && controller.errorMessage == nil, "Registration can succeed while awaiting approval")
        service.failure = NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Operation denied"])
        controller.setEnabled(false)
        try check(controller.state == .requiresApproval && controller.errorMessage != nil, "Failed unregister must retain actual state and expose error")
        service.state = .notRegistered; controller.refresh()
        try check(controller.errorMessage == nil, "Changed external state must clear an obsolete error")
        controller.setEnabled(true)
        try check(controller.state == .notRegistered && controller.errorMessage != nil, "Failed registration must not leave the switch falsely on")
        service.failure = nil; service.nextState = .enabled; controller.setEnabled(true)
        try check(controller.state == .enabled && controller.errorMessage == nil, "Retry after failure must recover")
        service.state = .notFound; controller.refresh(); controller.setEnabled(true)
        try check(controller.state == .enabled, "A new app with no service record must still be able to register")
        print("PASS login items: no implicit enable, registration, external refresh, approval, unregister, failure rollback and retry (isolated service)")
    }
}
