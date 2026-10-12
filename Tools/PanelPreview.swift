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
        let ideal = content.sizeThatFits(ProposedViewSize(width: TunnelPanelView.panelWidth, height: nil))
        result.ideal = ideal
        result.constrained = [600.0, 1000.0].map { height in
            content.sizeThatFits(ProposedViewSize(width: TunnelPanelView.panelWidth, height: height))
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
        let stopped = TunnelPanelItem(id: "stopped", name: "远程开发访问", nodeName: "example",
                                      forwards: [ForwardSpec(type: "R", port: "10022", host: "127.0.0.1", rport: "22")],
                                      state: .stopped, isOn: false,
                                      error: "debug1: Entering interactive session.\nKilled by signal 15.")
        let long = TunnelPanelItem(id: "long", name: "示例环境 · 数据库与应用服务转发",
                                   nodeName: "example-production-bastion-01",
                                   forwards: [
                                    ForwardSpec(port: "15432", host: "database.production.example.net", rport: "5432"),
                                    ForwardSpec(type: "D", port: "1080"),
                                    ForwardSpec(type: "R", port: "9000", host: "127.0.0.1", rport: "9000")
                                   ], state: .needsAttention, isOn: false,
                                   detail: "SSH 认证失败\n检查用户名、私钥和 SSH Agent，修改后重试。",
                                   error: "Permission denied (publickey).\n请检查节点的用户与密钥设置后再试。")

        try render("dark-single", items: [example], scheme: .dark, output: output)
        try render("light-single", items: [example], scheme: .light, output: output)
        try render("dark-multiple", items: [database, retry, socks], scheme: .dark, output: output)
        try render("light-multiple", items: [database, retry, socks], scheme: .light, output: output)
        try render("dark-readme", items: [database, retry], scheme: .dark, output: output)
        try render("light-readme", items: [database, retry], scheme: .light, output: output)
        try render("dark-manual-stop", items: [example, stopped], scheme: .dark, expanded: true, output: output)
        try render("light-manual-stop", items: [example, stopped], scheme: .light, expanded: true, output: output)
        try render("light-empty", items: [], scheme: .light, output: output)
        try render("dark-error", items: [long], scheme: .dark, expanded: true, output: output)
        let connecting = TunnelPanelItem(id: "connecting", name: "数据库访问", nodeName: "example",
                                         forwards: [local], state: .connecting, isOn: true,
                                         detail: "正在进行 SSH 认证并建立转发…")
        let unverified = TunnelPanelItem(id: "unverified", name: "已有的远程连接", nodeName: "staging-api",
                                         forwards: [ForwardSpec(type: "R", port: "9000", host: "127.0.0.1", rport: "3000")],
                                         state: .unverified, isOn: true,
                                         detail: "已接管现有进程；缺少本次连接的确认记录，连接继续保留。")
        for scheme in [ColorScheme.light, .dark] {
            try render(scheme == .light ? "light-connecting" : "dark-connecting", items: [connecting], scheme: scheme, output: output)
            try render(scheme == .light ? "light-unverified" : "dark-unverified", items: [unverified], scheme: scheme, output: output)
        }
        try render("light-config-error", items: [example], scheme: .light,
                   configError: "配置读取失败，原文件和现有隧道已保留：节点或隧道 ID 重复", output: output)
        let many = (0..<8).map { index in
            TunnelPanelItem(id: "many-\(index)", name: "应用服务 \(index + 1)", nodeName: "node-\(index + 1)",
                            forwards: [local], state: .running, isOn: true, uptime: "18分钟")
        }
        try render("dark-scroll", items: many, scheme: .dark, output: output)
        let groups = [TunnelGroupConfig(id: "project", name: "项目 A"), TunnelGroupConfig(id: "shared", name: "公共连接")]
        var projectDB = database; projectDB.groupId = "project"
        var projectRetry = retry; projectRetry.groupId = "project"
        var sharedSOCKS = socks; sharedSOCKS.groupId = "shared"
        let groupedItems = [projectDB, projectRetry, sharedSOCKS, example]
        for scheme in [ColorScheme.light, .dark] {
            let prefix = scheme == .light ? "light" : "dark"
            try render("\(prefix)-flat-with-saved-collapse", items: [example, stopped], scheme: scheme,
                       collapsed: ["ungrouped"], output: output)
            try render("\(prefix)-single-group", items: [projectDB, example], scheme: scheme,
                       groups: [groups[0]], output: output)
            try render("\(prefix)-empty-group-with-ungrouped", items: [example, stopped], scheme: scheme,
                       groups: [groups[0]], output: output)
            try render("\(prefix)-groups", items: groupedItems, scheme: scheme,
                       groups: groups, collapsed: ["group:project", "ungrouped"], output: output)
            try render("\(prefix)-groups-expanded", items: groupedItems, scheme: scheme, groups: groups, output: output)
            try render("\(prefix)-groups-collapsed", items: groupedItems, scheme: scheme,
                       groups: groups, collapsed: ["group:project", "group:shared", "ungrouped"], output: output)
        }
        try render("light-empty-group", items: [], scheme: .light,
                   groups: [TunnelGroupConfig(id: "empty", name: "新项目")], output: output)
        var longGroups = groups; longGroups[0].name = "项目 A · 测试环境与数据库共享服务"
        try render("dark-long-group", items: groupedItems, scheme: .dark, groups: longGroups,
                   collapsed: ["group:project", "group:shared", "ungrouped"], output: output)
    }

    private static func render(_ name: String, items: [TunnelPanelItem], scheme: ColorScheme,
                               expanded: Bool = false, configError: String? = nil,
                               groups: [TunnelGroupConfig] = [], collapsed: Set<String> = [], output: URL) throws {
        let content = TunnelPanelView(items: items, groups: groups, collapsedGroupIDs: collapsed,
                                      configError: configError, expandErrorsInitially: expanded)
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
        let width = TunnelPanelView.panelWidth
        let window = PreviewWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 600),
                                   styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = hosting.appearance
        window.contentView = hosting
        hosting.setFrameSize(NSSize(width: width, height: 600))
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let size = NSSize(width: width, height: ceil(hosting.fittingSize.height))
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
