import AppKit
import SwiftUI

private final class PreviewWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

private final class PanelSizingResult {
    var ideal: CGSize?
    var constrained: [CGSize] = []
}

/// 检查弹窗提供较大高度时仍按内容收紧；不能用预览专属的 fixedSize 掩盖问题。
private struct PanelSizingCheck: Layout {
    let result: PanelSizingResult

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let ideal = content.sizeThatFits(ProposedViewSize(width: 396, height: nil))
        result.ideal = ideal
        result.constrained = [600.0, 1000.0].map { height in
            content.sizeThatFits(ProposedViewSize(width: 396, height: height))
        }
        return content.sizeThatFits(proposal)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(bounds.size))
    }
}

/// 离屏渲染真实 SwiftUI 组件；没有 TunnelManager 实例、SSH 进程或在线配置。
@main
struct PanelPreview {
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let local = ForwardSpec(bind: "127.0.0.1", port: "15432", host: "127.0.0.1", rport: "5432")
        let example = TunnelPanelItem(id: "example", name: "数据库访问", nodeName: "example",
                                   forwards: [local], state: .running, isOn: true, uptime: "13小时59分")
        let database = TunnelPanelItem(id: "db", name: "生产数据库", nodeName: "prod-db-01",
                                       forwards: [ForwardSpec(port: "15432", host: "127.0.0.1", rport: "5432")],
                                       state: .running, isOn: true, uptime: "2小时08分")
        let retry = TunnelPanelItem(id: "retry", name: "测试环境 · 远程调试", nodeName: "staging-api",
                                    forwards: [ForwardSpec(type: "R", port: "9000", host: "127.0.0.1", rport: "9000")],
                                    state: .reconnecting, isOn: true, detail: "↻ 第3次重连 · 6s后重试",
                                    error: "ssh: connect to host staging-api.example.net port 22: Connection timed out")
        let socks = TunnelPanelItem(id: "socks", name: "开发 SOCKS 代理", nodeName: "dev-box",
                                    forwards: [ForwardSpec(type: "D", port: "1080")], state: .stopped, isOn: false)
        let long = TunnelPanelItem(id: "long", name: "示例环境 · 数据库与应用服务转发",
                                   nodeName: "example-production-bastion-01",
                                   forwards: [
                                    ForwardSpec(port: "15432", host: "database.production.example.net", rport: "5432"),
                                    ForwardSpec(type: "D", port: "1080"),
                                    ForwardSpec(type: "R", port: "9000", host: "127.0.0.1", rport: "9000")
                                   ], state: .stopped, isOn: false,
                                   error: "Permission denied (publickey).\n请检查节点的用户与密钥设置后再试。")

        try render("dark-single", items: [example], scheme: .dark, output: output)
        try render("light-single", items: [example], scheme: .light, output: output)
        try render("dark-multiple", items: [database, retry, socks], scheme: .dark, output: output)
        try render("light-multiple", items: [database, retry, socks], scheme: .light, output: output)
        try render("light-empty", items: [], scheme: .light, output: output)
        try render("dark-error", items: [long], scheme: .dark, expanded: true, output: output)
        try render("light-config-error", items: [example], scheme: .light,
                   configError: "配置读取失败，原文件和现有隧道已保留：节点或隧道 ID 重复", output: output)
        let many = (0..<8).map { index in
            TunnelPanelItem(id: "many-\(index)", name: "应用服务 \(index + 1)", nodeName: "node-\(index + 1)",
                            forwards: [local], state: .running, isOn: true, uptime: "18分钟")
        }
        try render("dark-scroll", items: many, scheme: .dark, output: output)
    }

    private static func render(_ name: String, items: [TunnelPanelItem], scheme: ColorScheme,
                               expanded: Bool = false, configError: String? = nil, output: URL) throws {
        let content = TunnelPanelView(items: items, configError: configError, expandErrorsInitially: expanded)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            }
            .environment(\.colorScheme, scheme)
            .environment(\.controlActiveState, .active)
            .accentColor(.blue)
        let sizing = PanelSizingResult()
        let validation = NSHostingView(rootView: PanelSizingCheck(result: sizing) { content })
        _ = validation.fittingSize
        guard let ideal = sizing.ideal,
              sizing.constrained.allSatisfy({ abs($0.height - ideal.height) < 0.5 }),
              ideal.height < 550 else {
            throw NSError(domain: "PanelPreview", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "\(name) 在弹窗高度约束下布局伸展：\(sizing.constrained)"
            ])
        }
        let hosting = NSHostingView(rootView: content)
        hosting.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let window = PreviewWindow(contentRect: NSRect(x: 0, y: 0, width: 396, height: 600),
                                   styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = hosting.appearance
        window.contentView = hosting
        hosting.setFrameSize(NSSize(width: 396, height: 600))
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let size = NSSize(width: 396, height: ceil(hosting.fittingSize.height))
        window.setContentSize(size)
        hosting.setFrameSize(size)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2),
                                           pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw NSError(domain: "PanelPreview", code: 1)
        }
        bitmap.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "PanelPreview", code: 2)
        }
        try png.write(to: output.appendingPathComponent("\(name).png"))
        print("\(name): \(Int(size.width)) × \(Int(size.height)) pt")
        window.contentView = nil
    }
}
