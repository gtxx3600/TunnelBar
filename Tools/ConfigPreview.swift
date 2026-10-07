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
                              forwards: [ForwardSpec(bind: "127.0.0.1", port: "15433", host: "database.example.net", rport: "5432")])
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
        let copy = TunnelTemplate.duplicate(tunnel, existing: config.tunnels)
        let copied = AppConfig(nodes: config.nodes, tunnels: config.tunnels + [copy])
        try render("light-copied-tunnel", config: config, draft: copied, runtime: runtime,
                   selection: .tunnel(copy.id), scheme: .light, output: output)
        var grouped = config
        grouped.groups = [TunnelGroupConfig(id: "project", name: "项目 A"),
                          TunnelGroupConfig(id: "shared", name: "公共连接"),
                          TunnelGroupConfig(id: "empty", name: "新项目")]
        grouped.tunnels[0].groupId = "project"; grouped.tunnels[1].groupId = "project"
        var sharedSocks = socks; sharedSocks.groupId = "shared"
        grouped.tunnels.append(sharedSocks)
        for scheme in [ColorScheme.light, .dark] {
            let prefix = scheme == .light ? "light" : "dark"
            try render("\(prefix)-group", config: grouped, runtime: runtime, selection: .group("project"),
                       scheme: scheme, size: NSSize(width: 820, height: 600), output: output)
            try render("\(prefix)-grouped-tunnel", config: grouped, runtime: runtime,
                       scheme: scheme, output: output)
            try render(scheme == .light ? "light-templates" : "dark-templates",
                       content: TunnelTemplatePicker(nodes: grouped.nodes, groups: grouped.groups,
                                                     selectedNode: example.id, selectedGroup: "project",
                                                     initialTemplate: .postgresql, create: { _, _, _ in }),
                       scheme: scheme, size: NSSize(width: 580, height: 510), output: output)
        }
        try render("light-empty-group", config: grouped, selection: .group("empty"), scheme: .light, output: output)
        var invalidGroup = grouped; invalidGroup.groups[0].name = "公共连接"
        try render("dark-invalid-group", config: grouped, draft: invalidGroup, selection: .group("project"),
                   scheme: .dark, output: output)
        var moved = grouped; moved.tunnels[0].groupId = "shared"
        try render("light-moved-tunnel", config: grouped, draft: moved, runtime: runtime,
                   selection: .group("shared"), scheme: .light, output: output)

        let sshSource = URL(fileURLWithPath: "/Users/example/.ssh/config")
        let hosts = ["example", "production", "development", "bastion", "database", "a-long-server-alias-for-staging-environment"].enumerated().map {
            SSHConfigHost(alias: $0.element, source: sshSource, line: $0.offset * 5 + 1)
        }
        let imports = SSHConfigImportResult(source: sshSource, hosts: hosts)
        for scheme in [ColorScheme.dark, .light] {
            try render(scheme == .dark ? "dark-ssh-import" : "light-ssh-import",
                       content: SSHConfigImportView(existingNodes: [example], initialState: .loaded(imports),
                                                    initialSelection: ["production", "development"], onImport: { _ in }),
                       scheme: scheme, size: NSSize(width: 540, height: 480), output: output)
        }
        let cases: [(String, SSHConfigImportState)] = [
            ("light-ssh-import-empty", .loaded(SSHConfigImportResult(source: sshSource))),
            ("dark-ssh-import-error", .failed("未找到 ~/.ssh/config。请先在 SSH 配置中添加 Host 别名。")),
            ("light-ssh-import-warning", .loaded(SSHConfigImportResult(source: sshSource, hosts: hosts,
                                                                     warnings: ["config:30：条件 Include 中的额外别名未展开。"]))),
            ("dark-ssh-import-loading", .loading)
        ]
        for (name, state) in cases {
            try render(name, content: SSHConfigImportView(existingNodes: [example], initialState: state, onImport: { _ in }),
                       scheme: name.hasPrefix("dark") ? .dark : .light, size: NSSize(width: 540, height: 480), output: output)
        }
    }

    private static func render(_ name: String, config: AppConfig, draft: AppConfig? = nil,
                               runtime: [String: ConfigRuntimeState] = [:], selection: ConfigResource? = nil,
                               scheme: ColorScheme, size: NSSize = NSSize(width: 920, height: 700), output: URL) throws {
        try render(name, content: ConfigWorkspaceView(config: config, runtime: runtime, selection: selection, initialDraft: draft),
                   scheme: scheme, size: size, output: output)
    }

    private static func render<Content: View>(_ name: String, content: Content,
                                              scheme: ColorScheme, size: NSSize, output: URL) throws {
        let view = content
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
