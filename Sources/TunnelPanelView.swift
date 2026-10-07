import SwiftUI

/// 展示层只接收快照和明确的操作，预览不需要启动 TunnelManager 或 SSH。
struct TunnelPanelItem: Identifiable {
    let id: String
    let name: String
    let nodeName: String
    let forwards: [ForwardSpec]
    let state: TunnelState
    let isOn: Bool
    var uptime: String? = nil
    var detail: String = ""
    var error: String? = nil
    var groupId: String? = nil
}

struct TunnelPanelGroup: Identifiable {
    let groupId: String?
    let name: String
    let items: [TunnelPanelItem]
    var id: String { groupId.map { "group:\($0)" } ?? "ungrouped" }
    var establishedCount: Int { items.filter { $0.state == .running }.count }
    var attentionCount: Int {
        items.filter { [.needsAttention, .reconnecting, .unverified].contains($0.state) }.count
    }
    var canStart: Bool { items.contains { !$0.isOn } }
    var canStop: Bool { items.contains(where: \.isOn) }

    static func sections(groups: [TunnelGroupConfig], items: [TunnelPanelItem]) -> [TunnelPanelGroup] {
        var sections = groups.map { group in
            TunnelPanelGroup(groupId: group.id, name: group.name, items: items.filter { $0.groupId == group.id })
        }
        let groupIDs = Set(groups.map(\.id))
        let ungrouped = items.filter { item in item.groupId.map { !groupIDs.contains($0) } ?? true }
        if !ungrouped.isEmpty { sections.append(TunnelPanelGroup(groupId: nil, name: "未分组", items: ungrouped)) }
        return sections
    }
}

/// 折叠是本机展示偏好，不写入连接配置；预览和测试不访问 UserDefaults。
enum TunnelGroupCollapseState {
    static func decode(_ value: String) -> Set<String> {
        Set((try? JSONDecoder().decode([String].self, from: Data(value.utf8))) ?? [])
    }
    static func toggled(_ id: String, in value: String) -> String {
        var ids = decode(value)
        if !ids.insert(id).inserted { ids.remove(id) }
        return String(decoding: (try? JSONEncoder().encode(ids.sorted())) ?? Data("[]".utf8), as: UTF8.self)
    }
}

struct TunnelPanelActions {
    var toggle: (String, Bool) -> Void = { _, _ in }
    var configure: () -> Void = {}
    var startAll: () -> Void = {}
    var stopAll: () -> Void = {}
    var startGroup: (String?) -> Void = { _ in }
    var stopGroup: (String?) -> Void = { _ in }
    var toggleGroup: (String) -> Void = { _ in }
    var openConfig: () -> Void = {}
    var reload: () -> Void = {}
    var quit: () -> Void = {}
}

struct TunnelPanelView: View {
    static let panelWidth: CGFloat = 340
    static let maximumListHeight: CGFloat = 300

    let items: [TunnelPanelItem]
    var groups: [TunnelGroupConfig] = []
    var collapsedGroupIDs: Set<String> = []
    var configError: String? = nil
    var actions = TunnelPanelActions()
    var expandErrorsInitially = false
    @FocusState private var configurationFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.bottom, 8)

            if let error = configError {
                configNotice(error)
                    .padding(.bottom, 8)
            }

            if items.isEmpty && groups.isEmpty {
                emptyState
            } else {
                ViewThatFits(in: .vertical) {
                    cards.fixedSize(horizontal: false, vertical: true)
                    ScrollView { cards }
                        .frame(height: Self.maximumListHeight)
                }
                .frame(maxHeight: Self.maximumListHeight)
            }

            Divider()
                .padding(.top, 8)
                .padding(.bottom, 6)
            footer
        }
        .padding(10)
        .frame(width: Self.panelWidth)
        // MenuBarExtra 的窗口会给出额外的高度；按内容的理想高度布局，
        // 避免可伸展的列表区域把标题和底栏挤出弹窗。
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("TunnelBar")
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            Text(summary)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .frame(height: 18)
    }

    private var summary: String {
        let running = items.filter { $0.state == .running }.count
        let retrying = items.filter { $0.state == .reconnecting }.count
        if items.isEmpty { return "SSH 隧道管理" }
        let attention = items.filter { $0.state == .needsAttention || $0.state == .unverified }.count
        let connecting = items.filter { $0.state == .connecting }.count
        if attention > 0 { return "\(running) 条已建立 · \(attention) 条待处理" }
        if connecting > 0 { return "\(running) 条已建立 · \(connecting) 条连接中" }
        if retrying > 0 { return "\(running) 条已建立 · \(retrying) 条重连" }
        if running == items.count { return "\(running) 条已建立" }
        if running > 0 { return "\(running) / \(items.count) 条已建立" }
        return "\(items.count) 条已停止"
    }

    private var cards: some View {
        VStack(spacing: 10) {
            ForEach(TunnelPanelGroup.sections(groups: groups, items: items)) { group in
                VStack(spacing: 6) {
                    groupHeader(group)
                    if !collapsedGroupIDs.contains(group.id) {
                        if group.items.isEmpty {
                            Text("还没有隧道，可在配置中添加")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                        }
                        ForEach(group.items) { item in
                            TunnelCardView(item: item, toggle: actions.toggle,
                                           initiallyExpanded: expandErrorsInitially)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 1)
    }

    private func groupHeader(_ group: TunnelPanelGroup) -> some View {
        HStack(spacing: 6) {
            Button { actions.toggleGroup(group.id) } label: {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: collapsedGroupIDs.contains(group.id) ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold)).frame(width: 10).padding(.top, 3)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.name).font(.system(size: 12, weight: .semibold))
                            .lineLimit(1).truncationMode(.middle)
                        HStack(spacing: 6) {
                            Text("\(group.establishedCount) / \(group.items.count) 已建立")
                                .foregroundStyle(.secondary).monospacedDigit()
                            if group.attentionCount > 0 {
                                Text("\(group.attentionCount) 需关注").foregroundStyle(.orange)
                            }
                        }.font(.system(size: 10)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help((collapsedGroupIDs.contains(group.id) ? "展开" : "收起") + "「\(group.name)」")
            .accessibilityLabel("分组：\(group.name)")
            .accessibilityValue("\(group.establishedCount) / \(group.items.count) 已建立，\(group.attentionCount) 条需关注，" + (collapsedGroupIDs.contains(group.id) ? "已折叠" : "已展开"))

            Button("启动本组") { actions.startGroup(group.groupId) }
                .disabled(!group.canStart)
                .help("启动「\(group.name)」中尚未启用的隧道")
                .accessibilityLabel("启动本组：\(group.name)")
            Button("停止本组") { actions.stopGroup(group.groupId) }
                .disabled(!group.canStop)
                .help("停止「\(group.name)」中的隧道，包括等待重连的连接")
                .accessibilityLabel("停止本组：\(group.name)")
        }
        .buttonStyle(.borderless).font(.system(size: 10.5))
        .padding(.horizontal, 6).padding(.vertical, 7)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 6))
    }

    private func configNotice(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("配置需要处理", systemImage: "exclamationmark.triangle")
                .font(.system(size: 12, weight: .medium))
            Text(error)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .textSelection(.enabled)
                .help(error)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: configError == nil ? "point.3.connected.trianglepath.dotted" : "doc.badge.gearshape")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.secondary)
                .padding(.bottom, 3)
            Text(configError == nil ? "还没有隧道" : "配置暂时不可用")
                .font(.system(size: 13, weight: .medium))
            Text(configError == nil ? "添加节点和转发规则，开始管理连接" : "修复配置后重新载入，现有连接会继续运行")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button(configError == nil ? "添加隧道" : "打开配置文件") {
                if configError == nil { actions.configure() } else { actions.openConfig() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Button(action: actions.configure) {
                Label("配置", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(PanelQuietButtonStyle())
            .focused($configurationFocused)
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(configurationFocused ? Color.accentColor : .clear, lineWidth: 2)
            }
            .help("管理节点和隧道")

            Spacer()
            Label("退出不停止隧道", systemImage: "link")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .help("退出后 SSH 连接继续运行，下次启动自动校准状态")

            Menu {
                Button(action: actions.startAll) {
                    Label("全部启动", systemImage: "play")
                }
                .disabled(items.allSatisfy(\.isOn))
                Button(role: .destructive, action: actions.stopAll) {
                    Label("全部停止", systemImage: "stop")
                }
                .disabled(!items.contains(where: \.isOn))
                Divider()
                Button(action: actions.openConfig) {
                    Label("打开配置文件…", systemImage: "curlybraces")
                }
                Button(action: actions.reload) {
                    Label("重新载入配置", systemImage: "arrow.clockwise")
                }
                Divider()
                Button(action: actions.quit) {
                    Label("退出 TunnelBar", systemImage: "power")
                }
                .keyboardShortcut("q", modifiers: .command)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 24)
                    .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("更多操作：批量启停、载入配置与退出")
            .accessibilityLabel("更多操作")
        }
        .frame(height: 24)
    }
}

private struct TunnelCardView: View {
    let item: TunnelPanelItem
    let toggle: (String, Bool) -> Void
    @State private var showsError: Bool
    @State private var showsAllForwards = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(item: TunnelPanelItem, toggle: @escaping (String, Bool) -> Void,
         initiallyExpanded: Bool = false) {
        self.item = item
        self.toggle = toggle
        _showsError = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(item.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.name)
                Spacer(minLength: 4)
                Toggle("启用\(item.name)", isOn: Binding(
                    get: { item.isOn },
                    set: { toggle(item.id, $0) }))
                    .toggleStyle(.switch)
                    .tint(.accentColor)
                    .controlSize(.mini)
                    .labelsHidden()
                    .help(item.isOn ? "停止这条隧道" : "启动这条隧道")
                    .accessibilityLabel("启用\(item.name)")
            }

            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                Text(statusLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(statusColor)
                    .help(item.state == .running ? "SSH 连接与转发已建立；目标服务未主动探测" : item.detail)
                if item.state == .running, let uptime = item.uptime {
                    Text(uptime)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 8)
                Label(item.nodeName, systemImage: "server.rack")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("SSH 节点：\(item.nodeName)")
                    .frame(maxWidth: 100, alignment: .trailing)
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(visibleForwards) { forward in
                    ForwardRouteView(forward: forward)
                }
                if item.forwards.count > 2 {
                    Button(showsAllForwards ? "收起规则" : "+\(item.forwards.count - 2) 条规则") {
                        showsAllForwards.toggle()
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
                    .help("查看这条隧道的所有转发规则")
                }
            }
            .padding(.top, 1)

            if item.state != .running && item.state != .stopped, !item.detail.isEmpty {
                Text(item.detail.replacingOccurrences(of: "↻ ", with: ""))
                    .font(.system(size: 11))
                    .foregroundStyle(statusColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if item.state != .running, let error = item.error, !error.isEmpty {
                Button {
                    showsError.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.circle")
                        Text(showsError ? "收起诊断" : "查看诊断")
                        Spacer()
                        Image(systemName: showsError ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(item.state == .reconnecting ? statusColor : errorColor)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if showsError {
                    Text(error)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            if item.state == .needsAttention {
                Button("重试连接") { toggle(item.id, true) }
                    .buttonStyle(.bordered).controlSize(.small)
                    .help("修改配置或排除问题后，重新执行预检并连接")
            }
        }
        .padding(10)
        .background(Color.primary.opacity(colorScheme == .dark ? 0.045 : 0.025),
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.09 : 0.08), lineWidth: 0.5)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: showsError)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: showsAllForwards)
    }

    private var visibleForwards: [ForwardSpec] {
        showsAllForwards ? item.forwards : Array(item.forwards.prefix(2))
    }

    private var statusLabel: String {
        switch item.state {
        case .running: return "已建立"
        case .connecting: return "连接中"
        case .needsAttention: return "需要处理"
        case .unverified: return "待确认"
        case .reconnecting: return "重连中"
        case .stopped: return "已停止"
        }
    }

    private var statusColor: Color {
        switch item.state {
        case .running:
            return colorScheme == .dark ? Color(red: 0.43, green: 0.85, blue: 0.62)
                : Color(red: 0.15, green: 0.43, blue: 0.28)
        case .reconnecting, .connecting, .unverified:
            return colorScheme == .dark ? Color(red: 0.95, green: 0.72, blue: 0.37)
                : Color(red: 0.54, green: 0.34, blue: 0.06)
        case .stopped:
            return .secondary
        case .needsAttention:
            return errorColor
        }
    }

    private var errorColor: Color {
        colorScheme == .dark ? Color(red: 0.95, green: 0.54, blue: 0.51)
            : Color(red: 0.68, green: 0.20, blue: 0.18)
    }
}

private struct ForwardRouteView: View {
    let forward: ForwardSpec
    private let loopbacks: Set<String> = ["", "127.0.0.1", "localhost", "::1", "[::1]"]

    var body: some View {
        HStack(spacing: 6) {
            Text(typeLabel)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 17)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 4))
            Text(source)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.primary.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.middle)
            if forward.type != "D" {
                Image(systemName: forward.type == "R" ? "arrow.left" : "arrow.right")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(destination)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.primary.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .help("\(forward.typeLabel)：\(forward.arg ?? "未完成")")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(forward.typeLabel)，\(forward.arg ?? "未完成")")
    }

    private var typeLabel: String {
        switch forward.type {
        case "R": return "远程"
        case "D": return "SOCKS"
        default: return "本地"
        }
    }

    private var source: String {
        loopbacks.contains(forward.bind) ? forward.port : "\(forward.bind):\(forward.port)"
    }

    private var destination: String {
        loopbacks.contains(forward.host) ? forward.rport : "\(forward.host):\(forward.rport)"
    }
}

private struct PanelQuietButtonStyle: ButtonStyle {
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background(Color.primary.opacity(configuration.isPressed ? 0.1 : isHovered ? 0.055 : 0),
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { isHovered = $0 }
    }
}
