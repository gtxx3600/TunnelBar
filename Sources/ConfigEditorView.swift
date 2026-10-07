import SwiftUI
import AppKit

/// 编辑器只维护草稿；预览和浏览不会实例化管理器或操作连接。
struct ConfigWorkspaceView: View {
    let config: AppConfig
    let runtime: [String: ConfigRuntimeState]
    let configError: String?
    let save: (AppConfig, AppConfig) throws -> Void

    @State private var draft: AppConfig
    @State private var baseline: AppConfig
    @State private var selected: ConfigResource?
    @State private var search = ""
    @State private var deletion: ConfigResource?
    @State private var saveError: String?
    @State private var didSave = false
    @State private var showsSSHImport = false
    @State private var showsTemplates = false

    init(config: AppConfig, runtime: [String: ConfigRuntimeState] = [:],
         configError: String? = nil, selection: ConfigResource? = nil,
         initialDraft: AppConfig? = nil, save: @escaping (AppConfig, AppConfig) throws -> Void = { _, _ in }) {
        self.config = config; self.runtime = runtime; self.configError = configError; self.save = save
        _draft = State(initialValue: initialDraft ?? config)
        _baseline = State(initialValue: config)
        _selected = State(initialValue: selection ?? config.tunnels.first.map { .tunnel($0.id) }
                          ?? config.groups.first.map { .group($0.id) }
                          ?? config.nodes.first.map { .node($0.id) })
    }

    private var isDirty: Bool { draft != baseline }
    private var issues: [ConfigIssue] { ConfigDraftRules.issues(in: draft) }
    private var impact: ConfigSaveImpact {
        ConfigDraftRules.impact(from: baseline, to: draft, activeIDs: Set(runtime.filter { $0.value.isActive }.keys))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar.frame(width: 220)
                Divider()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(minWidth: 820, minHeight: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if !isDirty {
                draft = config; baseline = config
                repairSelection()
            }
        }
        .alert(deletionTitle, isPresented: Binding(
            get: { deletion != nil }, set: { if !$0 { deletion = nil } })) {
                Button("删除", role: .destructive) { deleteResource() }
                Button("取消", role: .cancel) { deletion = nil }
            } message: {
                Text(deletionMessage)
            }
        .sheet(isPresented: $showsSSHImport) {
            SSHConfigImportView(existingNodes: draft.nodes) { nodes in
                guard !nodes.isEmpty else { return }
                draft.nodes.append(contentsOf: nodes)
                selected = .node(nodes[0].id); search = ""; didSave = false; saveError = nil
                showsSSHImport = false
            }
        }
        .sheet(isPresented: $showsTemplates) {
            TunnelTemplatePicker(nodes: draft.nodes, groups: draft.groups,
                                 selectedNode: preferredNodeID, selectedGroup: preferredGroupID) { template, nodeID, groupID in
                var tunnel = template.make(nodeID: nodeID, existing: draft.tunnels)
                tunnel.groupId = groupID
                draft.tunnels.append(tunnel)
                selected = .tunnel(tunnel.id); search = ""; didSave = false; saveError = nil
                showsTemplates = false
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("TunnelBar").font(.system(size: 17, weight: .semibold))
                Text("连接配置").font(.system(size: 12)).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索分组、隧道或节点", text: $search)
                        .textFieldStyle(.plain)
                        .accessibilityLabel("搜索分组、隧道或节点")
                    if !search.isEmpty {
                        Button { search = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }.buttonStyle(.plain).accessibilityLabel("清除搜索")
                    }
                }
                .font(.system(size: 11.5))
                .padding(7)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                .padding(.top, 10)
            }
            .padding(16)

            List(selection: $selected) {
                Section {
                    ForEach(filteredGroups) { group in
                        resourceRow(name: group.name.isEmpty ? "未命名分组" : group.name,
                                    subtitle: "\(draft.tunnelIDs(inGroup: group.id).count) 条隧道",
                                    icon: "folder", resource: .group(group.id))
                            .tag(ConfigResource.group(group.id))
                            .contextMenu {
                                Button("删除分组…", role: .destructive) { deletion = .group(group.id) }
                            }
                    }
                    if draft.groups.isEmpty {
                        Button("新建分组", action: addGroup)
                            .font(.system(size: 11)).buttonStyle(.link)
                    }
                } header: {
                    sectionLabel("分组", count: draft.groups.count)
                }
                Section {
                    ForEach(filteredTunnels) { tunnel in
                        resourceRow(name: tunnel.name.isEmpty ? "未命名隧道" : tunnel.name,
                                    subtitle: "\(draft.groupName(tunnel.groupId)) · \(nodeName(tunnel.nodeId))",
                                    icon: "arrow.left.arrow.right", resource: .tunnel(tunnel.id))
                            .tag(ConfigResource.tunnel(tunnel.id))
                            .contextMenu {
                                Button("复制隧道") { duplicateTunnel(tunnel.id) }
                                Button("删除隧道…", role: .destructive) { deletion = .tunnel(tunnel.id) }
                            }
                    }
                    if draft.tunnels.isEmpty {
                        Text("还没有隧道").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                } header: {
                    sectionLabel("隧道", count: draft.tunnels.count)
                }
                Section {
                    ForEach(filteredNodes) { node in
                        resourceRow(name: node.name.isEmpty ? (node.host.isEmpty ? "未命名节点" : node.host) : node.name,
                                    subtitle: node.host.isEmpty ? "未设置主机" : node.sshTarget,
                                    icon: "server.rack", resource: .node(node.id))
                            .tag(ConfigResource.node(node.id))
                            .contextMenu {
                                Button("删除节点…", role: .destructive) { deletion = .node(node.id) }
                                    .disabled(isNodeUsed(node.id))
                            }
                    }
                    if draft.nodes.isEmpty {
                        Text("还没有 SSH 节点").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                } header: {
                    sectionLabel("SSH 节点", count: draft.nodes.count)
                }
                if !search.isEmpty && filteredGroups.isEmpty && filteredTunnels.isEmpty && filteredNodes.isEmpty {
                    Text("没有匹配的资源").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Divider().padding(.horizontal, 12)
            VStack(alignment: .leading, spacing: 11) {
                Menu {
                    Button("新建分组", action: addGroup)
                    Button("新建隧道", action: addTunnel).disabled(draft.nodes.isEmpty)
                    Button("新建 SSH 节点", action: addNode)
                    Divider()
                    Button("从 SSH 配置导入…") { showsSSHImport = true }
                } label: {
                    Label("添加资源", systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .menuStyle(.borderlessButton)
                .help("创建分组、隧道或 SSH 节点")
                Button { showsSSHImport = true } label: {
                    Label("从 SSH 配置导入…", systemImage: "square.and.arrow.down")
                        .font(.system(size: 11.5)).foregroundStyle(Color.accentColor)
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
        }
        .background(Color.primary.opacity(0.025))
    }

    private func sectionLabel(_ title: String, count: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(count)").monospacedDigit()
        }.font(.system(size: 11, weight: .medium))
    }

    private func resourceRow(name: String, subtitle: String, icon: String,
                             resource: ConfigResource) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon).font(.system(size: 13)).frame(width: 17).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(subtitle).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if issues.contains(where: { $0.resource == resource }) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange).help("配置需要补全")
            } else if case .tunnel(let id) = resource, let state = runtime[id] {
                Circle().fill(state == .running ? Color.green : Color.orange).frame(width: 6, height: 6)
                    .padding(.top, 5).help(state.label)
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var detail: some View {
        if let selected {
            switch selected {
            case .group(let id):
                if let index = draft.groups.firstIndex(where: { $0.id == id }) {
                    detailScroll(title: draft.groups[index].name, subtitle: "项目分组", icon: "folder") {
                        groupForm(index)
                    }
                } else { emptyDetail }
            case .tunnel(let id):
                if let index = draft.tunnels.firstIndex(where: { $0.id == id }) {
                    detailScroll(title: draft.tunnels[index].name, subtitle: "隧道设置", icon: "arrow.left.arrow.right") {
                        TunnelConfigForm(tunnel: $draft.tunnels[index], nodes: draft.nodes, groups: draft.groups,
                                         isNew: !baseline.tunnels.contains { $0.id == id },
                                         warnings: TunnelPreflight.warnings(for: draft.tunnels[index], in: draft),
                                         editNode: { self.selected = .node($0) })
                            .id(id)
                    }
                } else { emptyDetail }
            case .node(let id):
                if let index = draft.nodes.firstIndex(where: { $0.id == id }) {
                    detailScroll(title: draft.nodes[index].name.isEmpty ? draft.nodes[index].host : draft.nodes[index].name,
                                 subtitle: "SSH 连接节点", icon: "server.rack") {
                        NodeConfigForm(node: $draft.nodes[index],
                                       tunnels: draft.tunnels.filter { $0.nodeId == id },
                                       selectTunnel: { self.selected = .tunnel($0) })
                            .id(id)
                    }
                } else { emptyDetail }
            }
        } else { emptyDetail }
    }

    private func groupForm(_ index: Int) -> some View {
        let group = draft.groups[index]
        let members = draft.tunnels.filter { $0.groupId == group.id }
        let candidates = draft.tunnels.filter { $0.groupId != group.id }
        return VStack(spacing: 16) {
            WorkspaceSection("分组设置", icon: "folder") {
                ConfigField("分组名称", text: $draft.groups[index].name, placeholder: "例如：项目 A、公共连接",
                            error: group.nameProblem(in: draft.groups))
                Text("每条隧道只属于一个分组，SSH 节点可以复用。共享服务可放在“公共连接”分组，单独启停。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            WorkspaceSection("组内隧道 · \(members.count)", icon: "arrow.left.arrow.right") {
                HStack {
                    Menu("移入已有隧道") {
                        ForEach(candidates) { tunnel in
                            Button("\(tunnel.name)（\(draft.groupName(tunnel.groupId))）") {
                                moveTunnel(tunnel.id, to: group.id)
                            }
                        }
                    }.disabled(candidates.isEmpty)
                    Button("新建隧道", action: addTunnel).disabled(draft.nodes.isEmpty)
                    Spacer()
                }.controlSize(.small)
                if members.isEmpty {
                    Text("这个分组还没有隧道。移入已有隧道，或新建一条。")
                        .font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 8)
                }
                ForEach(members) { tunnel in
                    Divider()
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Button(tunnel.name.isEmpty ? "未命名隧道" : tunnel.name) {
                                selected = .tunnel(tunnel.id); search = ""
                            }.buttonStyle(.link).font(.system(size: 12, weight: .medium))
                            Text("\(nodeName(tunnel.nodeId)) · \(tunnel.forwards.count) 条转发规则")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("移出分组") { moveTunnel(tunnel.id, to: nil) }
                            .buttonStyle(.borderless).font(.system(size: 11))
                            .help("将「\(tunnel.name)」移到未分组")
                    }
                }
                Text("调整归属、重命名或删除分组在保存后生效，已有连接继续运行。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func detailScroll<Content: View>(title: String, subtitle: String, icon: String,
                                            @ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: icon).font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Color.accentColor).frame(width: 44, height: 44)
                        .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title.isEmpty ? "未命名" : title).font(.system(size: 21, weight: .semibold))
                            .lineLimit(1).truncationMode(.middle)
                        Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if case .tunnel(let id) = selected {
                        Button { duplicateTunnel(id) } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless).help("复制隧道（默认不自动启动）")
                            .accessibilityLabel("复制隧道")
                    }
                    Button { deletion = selected } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .disabled(selected.map { if case .node(let id) = $0 { return isNodeUsed(id) }; return false } ?? true)
                        .help(deleteHelp)
                }
                if let error = saveError ?? configError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                }
                content()
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .id(selected)
    }

    private var emptyDetail: some View {
        VStack(spacing: 12) {
            Image(systemName: "server.rack").font(.system(size: 38, weight: .light)).foregroundStyle(.secondary)
            Text(draft.nodes.isEmpty ? "从一个 SSH 节点开始" : "选择一个分组、节点或隧道")
                .font(.system(size: 18, weight: .semibold))
            Text(draft.nodes.isEmpty ? "添加服务器地址或 SSH 别名，再创建端口转发。" : "在左侧选择资源，编辑连接与转发设置。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Button("添加 SSH 节点", action: addNode).buttonStyle(.borderedProminent).padding(.top, 5)
            Button("从 SSH 配置导入…") { showsSSHImport = true }.buttonStyle(.bordered)
            if !draft.nodes.isEmpty { Button("新建隧道", action: addTunnel).buttonStyle(.bordered) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                if let first = issues.first {
                    Button {
                        search = ""; selected = first.resource
                    } label: {
                        Label("\(issues.count) 处需要补全", systemImage: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                    }.buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                } else {
                    Label(isDirty ? "有未保存的修改" : (configError != nil ? "配置需要处理" : (didSave ? "已保存，配置已生效" : "配置已是最新")),
                          systemImage: isDirty ? "pencil.circle" : (configError != nil ? "exclamationmark.circle" : "checkmark.circle"))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Text(isDirty && !impact.description.isEmpty ? impact.description : "修改先保存在草稿中，点击保存后生效")
                    .font(.system(size: 11))
                    .foregroundStyle(isDirty && impact.interruptsConnection ? Color.orange : Color.secondary)
                    .lineLimit(2).truncationMode(.tail)
                    .help(impact.description)
            }
            Spacer(minLength: 6)
            Button("撤销修改") {
                draft = config; baseline = config; didSave = false; saveError = nil; repairSelection()
            }.disabled(!isDirty)
            Button(impact.interruptsConnection && isDirty ? "保存并应用" : "保存") { saveDraft() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!isDirty || !issues.isEmpty)
        }
        .controlSize(.regular)
        .padding(.horizontal, 20).padding(.vertical, 14)
        .background(.bar)
    }

    private var filteredTunnels: [TunnelConfig] {
        draft.tunnels.filter { search.isEmpty || ($0.name + " " + nodeName($0.nodeId) + " " + draft.groupName($0.groupId)).localizedCaseInsensitiveContains(search) }
    }
    private var filteredGroups: [TunnelGroupConfig] {
        draft.groups.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }
    private var filteredNodes: [NodeConfig] {
        draft.nodes.filter { search.isEmpty || ($0.name + " " + $0.sshTarget).localizedCaseInsensitiveContains(search) }
    }
    private func nodeName(_ id: String) -> String {
        draft.nodes.first { $0.id == id }.map { $0.name.isEmpty ? $0.host : $0.name } ?? "未选节点"
    }
    private func isNodeUsed(_ id: String) -> Bool { draft.tunnels.contains { $0.nodeId == id } }
    private var deleteHelp: String {
        if case .node(let id) = selected, isNodeUsed(id) { return "节点仍被隧道引用，请先调整关联隧道" }
        return "删除当前资源（保存后生效）"
    }
    private var deletionTitle: String {
        if case .group = deletion { return "删除这个分组？" }
        if case .node = deletion { return "删除这个 SSH 节点？" }
        return "删除这条隧道？"
    }
    private var deletionMessage: String {
        if case .group = deletion {
            return "保存后，组内隧道会移到未分组，已有连接继续运行。保存前可以撤销修改。"
        }
        if case .tunnel(let id) = deletion, runtime[id] != nil {
            return "删除先写入草稿；保存后会停止这条正在运行的隧道。"
        }
        return "删除先写入草稿，保存后生效。保存前可以撤销修改。"
    }
    private func addNode() {
        let node = NodeConfig(name: "新节点 \(draft.nodes.count + 1)")
        draft.nodes.append(node); selected = .node(node.id); search = ""
    }
    private func addGroup() {
        let id = draft.addGroup()
        selected = .group(id); search = ""; didSave = false; saveError = nil
    }
    private func moveTunnel(_ id: String, to groupID: String?) {
        guard let index = draft.tunnels.firstIndex(where: { $0.id == id }) else { return }
        draft.tunnels[index].groupId = groupID
        didSave = false; saveError = nil
    }
    private func addTunnel() {
        guard !draft.nodes.isEmpty else { addNode(); return }
        showsTemplates = true
    }
    private var preferredNodeID: String? {
        if case .node(let id) = selected { return id }
        if case .tunnel(let id) = selected { return draft.tunnels.first { $0.id == id }?.nodeId }
        return draft.nodes.first?.id
    }
    private var preferredGroupID: String? {
        if case .group(let id) = selected { return id }
        if case .tunnel(let id) = selected { return draft.tunnels.first { $0.id == id }?.groupId }
        return nil
    }
    private func duplicateTunnel(_ id: String) {
        guard let original = draft.tunnels.first(where: { $0.id == id }) else { return }
        let copy = TunnelTemplate.duplicate(original, existing: draft.tunnels)
        draft.tunnels.append(copy); selected = .tunnel(copy.id); search = ""
        didSave = false; saveError = nil
    }
    private func deleteResource() {
        guard let target = deletion else { return }
        switch target {
        case .group(let id): draft.removeGroup(id)
        case .tunnel(let id): draft.tunnels.removeAll { $0.id == id }
        case .node(let id):
            guard !isNodeUsed(id) else { deletion = nil; return }
            draft.nodes.removeAll { $0.id == id }
        }
        deletion = nil; repairSelection()
    }
    private func repairSelection() {
        if case .group(let id) = selected, draft.groups.contains(where: { $0.id == id }) { return }
        if case .tunnel(let id) = selected, draft.tunnels.contains(where: { $0.id == id }) { return }
        if case .node(let id) = selected, draft.nodes.contains(where: { $0.id == id }) { return }
        selected = draft.tunnels.first.map { .tunnel($0.id) }
            ?? draft.groups.first.map { .group($0.id) } ?? draft.nodes.first.map { .node($0.id) }
    }
    private func saveDraft() {
        guard isDirty, issues.isEmpty else { return }
        let normalized = ConfigDraftRules.normalized(draft)
        do {
            try save(normalized, baseline)
            draft = normalized; baseline = normalized; didSave = true; saveError = nil
        } catch {
            saveError = "保存失败，草稿已保留：\(error.localizedDescription)"
        }
    }
}

private struct TunnelConfigForm: View {
    @Binding var tunnel: TunnelConfig
    let nodes: [NodeConfig]
    let groups: [TunnelGroupConfig]
    let isNew: Bool
    let warnings: [String]
    let editNode: (String) -> Void
    @State private var showsAdvanced: Bool

    init(tunnel: Binding<TunnelConfig>, nodes: [NodeConfig], groups: [TunnelGroupConfig], isNew: Bool, warnings: [String], editNode: @escaping (String) -> Void) {
        _tunnel = tunnel; self.nodes = nodes; self.groups = groups; self.isNew = isNew; self.editNode = editNode
        self.warnings = warnings
        _showsAdvanced = State(initialValue: !tunnel.wrappedValue.extraArgs.isEmpty)
    }

    var body: some View {
        VStack(spacing: 16) {
            if !warnings.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("监听端口重叠", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12, weight: .medium))
                    ForEach(warnings, id: \.self) { warning in
                        Text(warning).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .foregroundStyle(.orange).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            }
            WorkspaceSection("基本设置", icon: "slider.horizontal.3") {
                ConfigField("隧道名称", text: $tunnel.name, placeholder: "例如：数据库访问",
                            error: ConfigDraftRules.trimmed(tunnel.name).isEmpty ? "请填写隧道名称" : nil)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("SSH 节点").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        Spacer()
                        Button("编辑节点") { editNode(tunnel.nodeId) }
                            .buttonStyle(.link).font(.system(size: 11))
                            .disabled(!nodes.contains { $0.id == tunnel.nodeId })
                    }
                    Picker("SSH 节点", selection: $tunnel.nodeId) {
                        if !nodes.contains(where: { $0.id == tunnel.nodeId }) { Text("请选择节点").tag(tunnel.nodeId) }
                        ForEach(nodes) { node in
                            Text(node.name.isEmpty ? node.host : node.name).tag(node.id)
                        }
                    }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("所属分组").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Picker("所属分组", selection: Binding(
                        get: { tunnel.groupId ?? "" },
                        set: { tunnel.groupId = $0.isEmpty ? nil : $0 })) {
                        Text("未分组").tag("")
                        ForEach(groups) { group in Text(group.name).tag(group.id) }
                        if let id = tunnel.groupId, !groups.contains(where: { $0.id == id }) {
                            Text("分组不存在，请重新选择").tag(id)
                        }
                    }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("自动启动").font(.system(size: 12, weight: .medium))
                        Text(isNew ? "启用后，保存时立即启动，之后随应用启动" : "下次启动 TunnelBar 时自动建立这条隧道")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("自动启动", isOn: $tunnel.autoStart).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("转发规则", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 13, weight: .semibold))
                    Text("\(tunnel.forwards.count)").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button { tunnel.forwards.append(ForwardSpec(bind: "127.0.0.1", host: "127.0.0.1")) } label: {
                        Label("添加规则", systemImage: "plus")
                    }.controlSize(.small)
                }
                // 直接编辑草稿中的规则，切换隧道不会留下另一份 @State 行数据。
                ForEach($tunnel.forwards) { $forward in
                    let ruleID = forward.id
                    ForwardRuleEditor(forward: $forward,
                                      number: (tunnel.forwards.firstIndex { $0.id == ruleID } ?? 0) + 1) {
                        tunnel.forwards.removeAll { $0.id == ruleID }
                    }
                }
                if tunnel.forwards.isEmpty {
                    Text("至少添加一条转发规则").font(.system(size: 12)).foregroundStyle(.orange).padding(12)
                }
            }

            WorkspaceSection {
                DisclosureGroup(isExpanded: $showsAdvanced) {
                    ConfigField("附加 SSH 参数", text: extraString, placeholder: "例如：-v",
                                hint: "按空格分隔；通常无需填写。")
                        .padding(.top, 12)
                } label: {
                    Label("高级选项", systemImage: "gearshape").font(.system(size: 13, weight: .semibold))
                }
            }
        }
    }
    private var extraString: Binding<String> {
        Binding(get: { tunnel.extraArgs.joined(separator: " ") },
                set: { tunnel.extraArgs = $0.split(whereSeparator: { $0.isWhitespace }).map(String.init) })
    }
}

private struct ForwardRuleEditor: View {
    @Binding var forward: ForwardSpec
    let number: Int
    let remove: () -> Void

    var body: some View {
        WorkspaceSection {
            HStack(spacing: 10) {
                Text("规则 \(number)").font(.system(size: 12, weight: .semibold))
                Spacer()
                Picker("转发类型", selection: $forward.type) {
                    Text("本地转发 · L").tag("L")
                    Text("远程转发 · R").tag("R")
                    Text("SOCKS 代理 · D").tag("D")
                }.labelsHidden().frame(width: 146)
                Button(action: remove) { Image(systemName: "trash").foregroundStyle(.secondary) }
                    .buttonStyle(.borderless).help("删除规则 \(number)").accessibilityLabel("删除规则 \(number)")
            }
            HStack(alignment: .top, spacing: 12) {
                endpoint(title: forward.type == "R" ? "节点上监听" : "本机监听",
                         address: $forward.bind, port: $forward.port)
                if forward.type != "D" {
                    Image(systemName: "arrow.right").font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 37)
                    endpoint(title: forward.type == "R" ? "转发到本机" : "节点侧目标",
                             address: $forward.host, port: $forward.rport)
                } else {
                    VStack(alignment: .leading, spacing: 7) {
                        Label("SOCKS5 代理", systemImage: "network").font(.system(size: 12, weight: .medium))
                        Text("通过 SSH 节点访问网络").font(.system(size: 11)).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 25)
                }
            }
            if let error = ConfigDraftRules.forwardProblem(forward) {
                Label(error, systemImage: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(.orange)
            } else {
                Text(forward.type == "R" ? "目标地址由本机访问，监听端口开在 SSH 节点上。"
                     : (forward.type == "D" ? "在应用中使用此端口作为 SOCKS5 代理。" : "目标地址由 SSH 节点访问，监听端口开在本机上。"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func endpoint(title: String, address: Binding<String>, port: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            TextField("127.0.0.1 / 域名", text: address)
                .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                .accessibilityLabel("规则 \(number)，\(title)地址")
            HStack(spacing: 8) {
                Text("端口").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("1–65535", text: port).textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(
                        !ConfigDraftRules.validPort(port.wrappedValue) ? Color.orange.opacity(0.5) : .clear, lineWidth: 1) }
                    .accessibilityLabel("规则 \(number)，\(title)端口")
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct NodeConfigForm: View {
    @Binding var node: NodeConfig
    let tunnels: [TunnelConfig]
    let selectTunnel: (String) -> Void
    @State private var showsOptions: Bool

    init(node: Binding<NodeConfig>, tunnels: [TunnelConfig], selectTunnel: @escaping (String) -> Void) {
        _node = node; self.tunnels = tunnels; self.selectTunnel = selectTunnel
        let n = node.wrappedValue
        _showsOptions = State(initialValue: !n.port.isEmpty || !n.user.isEmpty || !n.identityFile.isEmpty)
    }
    var body: some View {
        VStack(spacing: 16) {
            WorkspaceSection("节点信息", icon: "server.rack") {
                ConfigField("显示名称", text: $node.name, placeholder: "例如：开发服务器",
                            hint: "用于列表显示，不影响 SSH 连接。")
                ConfigField("主机地址 / SSH 别名", text: $node.host, placeholder: "例如：example 或 192.168.1.10",
                            hint: "支持 ~/.ssh/config 中的别名。",
                            error: ConfigDraftRules.trimmed(node.host).isEmpty ? "请填写主机地址或 SSH 别名" : nil,
                            monospaced: true)
            }
            WorkspaceSection {
                DisclosureGroup(isExpanded: $showsOptions) {
                    VStack(spacing: 14) {
                        HStack(alignment: .top, spacing: 16) {
                            ConfigField("SSH 用户", text: $node.user, placeholder: "沿用 SSH 设置")
                            ConfigField("SSH 端口", text: $node.port, placeholder: "沿用 SSH 设置",
                                        error: !node.port.isEmpty && !ConfigDraftRules.validPort(node.port) ? "端口需为 1–65535" : nil,
                                        monospaced: true)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("私钥路径").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                                Spacer()
                                Button("选择文件…", action: chooseKey).buttonStyle(.link).font(.system(size: 11))
                            }
                            TextField("留空使用 SSH 默认密钥", text: $node.identityFile)
                                .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                                .accessibilityLabel("私钥路径")
                        }
                    }.padding(.top, 14)
                } label: {
                    Label("连接选项", systemImage: "key").font(.system(size: 13, weight: .semibold))
                }
                Text("端口、用户和密钥留空时，沿用 SSH 别名或默认设置。")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            WorkspaceSection("关联隧道", icon: "link") {
                if tunnels.isEmpty {
                    Text("此节点还没有关联隧道。保存后可在左侧添加隧道。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    ForEach(tunnels) { tunnel in
                        Button { selectTunnel(tunnel.id) } label: {
                            HStack {
                                Label(tunnel.name.isEmpty ? "未命名隧道" : tunnel.name, systemImage: "arrow.left.arrow.right")
                                Spacer()
                                Text("\(tunnel.forwards.count) 条规则").foregroundStyle(.secondary)
                                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.secondary)
                            }.font(.system(size: 12)).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    Text("节点被引用时无法删除；修改连接选项会影响关联的运行中隧道。")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.title = "选择 SSH 私钥"; panel.canChooseDirectories = false
        panel.canChooseFiles = true; panel.allowsMultipleSelection = false; panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
        if panel.runModal() == .OK, let url = panel.url { node.identityFile = url.path }
    }
}

private struct ConfigField: View {
    let title: String
    @Binding var text: String
    let placeholder: String
    var hint: String? = nil
    var error: String? = nil
    var monospaced = false

    init(_ title: String, text: Binding<String>, placeholder: String, hint: String? = nil,
         error: String? = nil, monospaced: Bool = false) {
        self.title = title; _text = text; self.placeholder = placeholder
        self.hint = hint; self.error = error; self.monospaced = monospaced
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            TextField(placeholder, text: $text).textFieldStyle(.roundedBorder)
                .font(.system(size: 13, design: monospaced ? .monospaced : .default))
                .accessibilityLabel(title)
                .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(error != nil ? Color.orange.opacity(0.5) : .clear, lineWidth: 1) }
            if let message = error ?? hint {
                Text(message).font(.system(size: 11)).foregroundStyle(error != nil ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct WorkspaceSection<Content: View>: View {
    let title: String?
    let icon: String?
    let content: Content

    init(_ title: String? = nil, icon: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.icon = icon; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                if let icon { Label(title, systemImage: icon).font(.system(size: 13, weight: .semibold)) }
                else { Text(title).font(.system(size: 13, weight: .semibold)) }
            }
            content
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.065), lineWidth: 0.5) }
    }
}
