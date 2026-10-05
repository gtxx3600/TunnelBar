import AppKit
import SwiftUI

@main
struct ConfigPreview {
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let example = NodeConfig(id: "example", name: "example", host: "example")
        let server = NodeConfig(id: "prod", name: "开发服务器", host: "dev.example.net", port: "2222",
                                user: "developer", identityFile: "/Users/example/.ssh/id_ed25519")
        let tunnel = TunnelConfig(id: "database", name: "数据库访问", nodeId: example.id,
                                  forwards: [ForwardSpec(id: "local", bind: "127.0.0.1", port: "15432",
                                                         host: "127.0.0.1", rport: "5432")], autoStart: true)
        let db = TunnelConfig(id: "db", name: "开发数据库", nodeId: server.id,
                              forwards: [ForwardSpec(bind: "127.0.0.1", port: "15432", host: "database.internal", rport: "5432")])
        let config = AppConfig(nodes: [example, server], tunnels: [tunnel, db])
        let runtime: [String: ConfigRuntimeState] = ["database": .running]
        try render("dark-tunnel", config: config, runtime: runtime, scheme: .dark, output: output)
        try render("light-tunnel", config: config, runtime: runtime, scheme: .light, output: output)
        try render("light-node-alias", config: config, selection: .node("example"), scheme: .light, output: output)
        try render("dark-node-options", config: config, selection: .node("prod"), scheme: .dark, output: output)
        var changed = config
        changed.tunnels[0].forwards[0].port = "15433"
        try render("dark-save-impact", config: config, draft: changed, runtime: runtime, scheme: .dark, output: output)
        var invalid = config
        invalid.tunnels[0].forwards[0].port = "0"
        try render("light-invalid", config: config, draft: invalid, runtime: runtime, scheme: .light, output: output)
        var types = config
        types.tunnels[0].forwards += [ForwardSpec(type: "R", port: "9000", host: "127.0.0.1", rport: "3000"),
                                     ForwardSpec(type: "D", bind: "127.0.0.1", port: "1080")]
        try render("dark-many-rules", config: types, scheme: .dark, output: output)
        let socks = TunnelConfig(id: "socks", name: "开发 SOCKS 代理", nodeId: server.id,
                                 forwards: [ForwardSpec(type: "D", bind: "127.0.0.1", port: "1080")])
        let remote = TunnelConfig(id: "remote", name: "远程调试", nodeId: server.id,
                                  forwards: [ForwardSpec(type: "R", port: "9000", host: "127.0.0.1", rport: "3000")])
        try render("light-socks", config: AppConfig(nodes: [server], tunnels: [socks]), scheme: .light, output: output)
        try render("dark-remote", config: AppConfig(nodes: [server], tunnels: [remote]), scheme: .dark, output: output)
        try render("light-empty", config: AppConfig(), scheme: .light, output: output)
        try render("dark-minimum", config: config, runtime: runtime, scheme: .dark,
                   size: NSSize(width: 820, height: 600), output: output)
    }

    private static func render(_ name: String, config: AppConfig, draft: AppConfig? = nil,
                               runtime: [String: ConfigRuntimeState] = [:], selection: ConfigResource? = nil,
                               scheme: ColorScheme, size: NSSize = NSSize(width: 920, height: 700), output: URL) throws {
        let view = ConfigWorkspaceView(config: config, runtime: runtime, selection: selection, initialDraft: draft)
            .environment(\.colorScheme, scheme)
            .environment(\.controlActiveState, .active)
            .frame(width: size.width, height: size.height)
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = hosting.appearance
        window.contentView = hosting
        hosting.setFrameSize(size)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        guard abs(hosting.bounds.width - size.width) < 0.5, abs(hosting.bounds.height - size.height) < 0.5 else {
            throw NSError(domain: "ConfigPreview", code: 1, userInfo: [NSLocalizedDescriptionKey: "Preview frame mismatch"])
        }
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2),
                                           pixelsHigh: Int(size.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
                                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                           bytesPerRow: 0, bitsPerPixel: 0) else { throw NSError(domain: "ConfigPreview", code: 2) }
        bitmap.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "ConfigPreview", code: 3) }
        try png.write(to: output.appendingPathComponent("\(name).png"))
        print("\(name): \(Int(size.width)) × \(Int(size.height)) pt")
        window.contentView = nil
    }
}
