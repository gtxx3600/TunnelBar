import Foundation

/// 由 local-ssh-test.py 提供临时节点、密钥和仅监听回环地址的 sshd。
@main
struct LocalSSHIntegration {
    static func main() throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let manager = TunnelManager(configURL: url)
        var adopted: TunnelManager?
        defer {
            adopted?.stopAll(); adopted?.prepareForAppExit()
            manager.stopAll(); manager.prepareForAppExit()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        manager.start("local-integration")
        guard manager.statuses.first?.state == .connecting else {
            throw failure("SSH spawn did not begin in connecting state", manager)
        }
        try wait(manager)
        print("PASS real OpenSSH: authenticated L/R/D forwarding confirmed")

        // 相同端口上的真实旧进程必须退出后才执行下一次预检。
        manager.stop("local-integration")
        manager.start("local-integration")
        try wait(manager)
        print("PASS real OpenSSH: rapid restart waits for listener release")

        manager.prepareForAppExit()
        let next = TunnelManager(configURL: url)
        adopted = next
        try wait(next)
        print("PASS real OpenSSH: adoption retains verified L/R/D connection")
    }

    private static func wait(_ manager: TunnelManager) throws {
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            if manager.statuses.first?.state == .running { return }
            if manager.statuses.first?.state == .needsAttention { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        throw failure("Real SSH did not confirm readiness", manager)
    }

    private static func failure(_ message: String, _ manager: TunnelManager) -> NSError {
        NSError(domain: "LocalSSHIntegration", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message + "\n" + (manager.diagnosticText("local-integration") ?? "No diagnostics")])
    }
}
