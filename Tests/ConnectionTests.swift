import Foundation
import Darwin

@main
struct ConnectionTests {
    static func main() throws {
        func check(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain: "ConnectionTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        let local = ForwardSpec(bind: "127.0.0.1", port: "8080", host: "127.0.0.1", rport: "80")
        let remote = ForwardSpec(type: "R", port: "9000", host: "127.0.0.1", rport: "3000")
        let socks = ForwardSpec(type: "D", port: "1080")
        var evidence = SSHConnectionEvidence()
        evidence.consume("Authenticated to fixture ([127.0.0.1]:22) using publickey.")
        try check(!evidence.isReady(for: [local]), "Authentication alone was marked ready")
        evidence.consume("debug1: Entering interactive session.")
        try check(!evidence.isReady(for: [local]), "Session without listener was marked ready")
        evidence.consume("debug1: Local forwarding listening on 127.0.0.1 port 8080.")
        try check(evidence.isReady(for: [local]), "Established local forwarding was not detected")
        try check(!evidence.isReady(for: [local, socks]), "An unconfirmed SOCKS listener was marked ready")
        evidence.consume("debug1: Local forwarding listening on ::1 port 1080.")
        evidence.consume("debug1: Remote connections from LOCALHOST:9000 forwarded to local address 127.0.0.1:3000")
        try check(!evidence.isReady(for: [local, remote, socks]), "Remote request was mistaken for confirmation")
        evidence.consume("debug1: remote forward success for: listen 9000, connect 127.0.0.1:3000")
        try check(!evidence.isReady(for: [local, remote, socks]), "Pending remote replies were ignored")
        evidence.consume("debug1: forwarding_success: all expected forwarding replies received")
        try check(evidence.isReady(for: [local, remote, socks]), "Mixed L/R/D confirmation failed")
        evidence.consume("Error: remote port forwarding failed for listen port 9000")
        try check(!evidence.isReady(for: [local, remote, socks]), "Failure did not override readiness")
        print("PASS readiness: authentication, individual listeners, delayed R confirmation, mixed L/R/D and failure")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tunnelbar-log-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.log")
        try Data("debug1: Entering interactive session.\ndebug1: Local forwarding listening on 127.0.0.1 port 80".utf8).write(to: url)
        var reader = SSHLogReader()
        reader.update(from: url)
        try check(!reader.evidence.isReady(for: [local]), "Partial line was consumed prematurely")
        let writer = try FileHandle(forWritingTo: url)
        try writer.seekToEnd(); try writer.write(contentsOf: Data("80.\n".utf8)); try writer.close()
        reader.update(from: url)
        try check(reader.evidence.isReady(for: [local]), "Split log line was lost")
        try Data("new attempt\n".utf8).write(to: url)
        reader.update(from: url)
        try check(!reader.evidence.isReady(for: [local]), "Truncated log retained stale readiness")
        try Data((String(repeating: "x", count: 9000) + "Connection timed out\n").utf8).write(to: url)
        let tail = SSHLogReader.tail(url)
        try check(tail.utf8.count <= 8192 && tail.hasSuffix("Connection timed out\n"), "Diagnostic tail was not bounded")
        print("PASS logs: partial writes, truncation, bounded diagnostic reads")

        let permanent: [(String, TunnelFailureKind)] = [
            ("Permission denied (publickey).", .authentication),
            ("Host key verification failed.", .hostKey),
            ("bind: Address already in use", .portInUse),
            ("Warning: Identity file /missing not accessible: No such file or directory.", .identityFile),
            ("Warning: Identity file /missing not accessible.\nfixture: Permission denied (publickey).", .identityFile),
            ("Bad configuration option: typo", .configuration),
            ("Error: remote port forwarding failed for listen port 9000", .configuration)
        ]
        for (log, kind) in permanent {
            let failure = TunnelFailure.classify(log)
            try check(failure.kind == kind && !failure.retryable && !failure.suggestion.isEmpty, "Incorrect permanent error classification: \(log)")
        }
        for log in ["Connection timed out", "Connection reset by peer", "Could not resolve hostname fixture", ""] {
            try check(TunnelFailure.classify(log).retryable, "Recoverable exit stopped retrying")
        }
        print("PASS diagnostics: authentication, host key, ports, identity, configuration and transient network errors")

        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        try check(socketFD >= 0, "Could not create test listener")
        defer { close(socketFD) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        try check(bound == 0 && listen(socketFD, 1) == 0, "Could not bind test listener")
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &size) }
        }
        let port = String(UInt16(bigEndian: address.sin_port))
        let node = NodeConfig(id: "fixture", host: "fixture")
        var tunnel = TunnelConfig(nodeId: node.id, forwards: [ForwardSpec(type: "D", bind: "127.0.0.1", port: port)])
        try check(TunnelPreflight.check(tunnel, node: node)?.kind == .portInUse, "Existing listener was not detected")
        tunnel.forwards[0] = ForwardSpec(type: "R", port: port, host: "127.0.0.1", rport: "80")
        try check(TunnelPreflight.check(tunnel, node: node) == nil, "Remote forwarding checked a local listening port")
        tunnel.forwards = [local, local]
        try check(TunnelPreflight.check(tunnel, node: node)?.kind == .portInUse, "Duplicate local rules were not detected")
        var wildcard = local; wildcard.bind = "0.0.0.0"
        var separate = local; separate.bind = "127.0.0.2"
        var v6 = local; v6.bind = "[::1]"
        var defaultBind = local; defaultBind.bind = ""
        try check(TunnelPreflight.conflicts(wildcard, separate), "Wildcard listener overlap was missed")
        try check(!TunnelPreflight.conflicts(local, separate), "Distinct addresses were incorrectly conflated")
        try check(!TunnelPreflight.conflicts(local, v6) && TunnelPreflight.conflicts(defaultBind, v6), "IPv6/localhost overlap was incorrect")
        try check(!TunnelPreflight.conflicts(local, remote), "Remote and local scopes were conflated")
        print("PASS preflight: real occupied port, duplicate rules, bind scope, IPv6 and remote-port isolation (no connections)")
    }
}
