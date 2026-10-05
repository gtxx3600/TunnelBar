// 配置窗口：节点 / 隧道 图形化管理（主从式：左列表右表单）

import SwiftUI

struct ConfigEditor: View {
    @ObservedObject var manager = TunnelManager.shared

    @State private var mode = 0                 // 0=隧道 1=节点
    @State private var draft = AppConfig()
    @State private var selT: String?
    @State private var selN: String?
    @State private var problems: [String] = []
    @State private var showDeleteConfirm = false
    @State private var notice = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $mode) {
                Text("隧道 · \(draft.tunnels.count)").tag(0)
                Text("节点 · \(draft.nodes.count)").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)
            .padding(.bottom, 10)

            HStack(spacing: 0) {
                listPane.frame(width: 200)
                Divider()
                detailPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(14)
            }

            Divider()
            footer.padding(8)
        }
        .frame(minWidth: 660, minHeight: 470)
        .onAppear {
            draft = manager.current
            selT = draft.tunnels.first?.id
            selN = draft.nodes.first?.id
        }
        .alert("无法保存", isPresented: Binding(
            get: { !problems.isEmpty },
            set: { if !$0 { problems = [] } })) {
            Button("好") { problems = [] }
        } message: {
            Text(problems.joined(separator: "\n"))
        }
        .alert(notceTitle, isPresented: Binding(
            get: { !notice.isEmpty },
            set: { if !$0 { notice = "" } })) {
            Button("好") { notice = "" }
        } message: {
            Text(notice)
        }
        .confirmationDialog("确定删除？", isPresented: $showDeleteConfirm,
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) { deleteSelected() }
            Button("取消", role: .cancel) {}
        }
    }

    private var notceTitle: String { notice.isEmpty ? "" : String(notice.prefix(20)) }

    // MARK: 左侧列表

    private var listPane: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 2) {
                    if mode == 0 {
                        ForEach(draft.tunnels) { t in
                            listRow(title: t.name.isEmpty ? "（未命名）" : t.name,
                                    sub: "\(nodeNameInDraft(t.nodeId)) · \(t.forwards.count) 条转发"
                                        + (t.autoStart ? " · 自启" : ""),
                                    selected: selT == t.id)
                                .onTapGesture { selT = t.id }
                        }
                    } else {
                        ForEach(draft.nodes) { n in
                            listRow(title: n.name.isEmpty ? n.host : n.name,
                                    sub: n.sshTarget + (n.port.isEmpty ? "" : " :\(n.port)"),
                                    selected: selN == n.id)
                                .onTapGesture { selN = n.id }
                        }
                    }
                }
                .padding(6)
            }
            Divider()
            Button {
                mode == 0 ? addTunnel() : addNode()
            } label: {
                Label(mode == 0 ? "新建隧道" : "新建节点", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }

    private func listRow(title: String, sub: String, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Text(sub).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Color.accentColor.opacity(0.15) : Color.clear))
        .contentShape(Rectangle())
    }

    private func nodeNameInDraft(_ id: String) -> String {
        draft.nodes.first { $0.id == id }.map { $0.name.isEmpty ? $0.host : $0.name } ?? "未选节点"
    }

    // MARK: 右侧表单

    @ViewBuilder
    private var detailPane: some View {
        if mode == 0 {
            if let i = draft.tunnels.firstIndex(where: { $0.id == selT }) {
                TunnelForm(t: $draft.tunnels[i], nodes: draft.nodes)
            } else {
                placeholder("选择左侧隧道，或新建一条")
            }
        } else {
            if let i = draft.nodes.firstIndex(where: { $0.id == selN }) {
                NodeForm(n: $draft.nodes[i],
                         usedBy: draft.tunnels.filter { $0.nodeId == draft.nodes[i].id }
                             .map { $0.name.isEmpty ? $0.id : $0.name })
            } else {
                placeholder("选择左侧节点，或新建一个")
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 底部操作

    private var footer: some View {
        HStack(spacing: 12) {
            Button(role: .destructive) {
                let hasSel = mode == 0 ? selT != nil : selN != nil
                if hasSel {
                    if mode == 1, let id = selN,
                       !draft.tunnels.filter({ $0.nodeId == id }).isEmpty {
                        notice = "该节点正被隧道使用，请先修改那些隧道的节点选择"
                    } else {
                        showDeleteConfirm = true
                    }
                }
            } label: {
                Label("删除", systemImage: "trash")
            }
            .disabled(mode == 0 ? selT == nil : selN == nil)

            Spacer()

            Button("恢复未保存的修改") {
                draft = manager.current
                selT = draft.tunnels.first?.id
                selN = draft.nodes.first?.id
            }
            Button("保存") { save() }
                .keyboardShortcut(.defaultAction)
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 4)
    }

    // MARK: 增删改

    private func addNode() {
        let n = NodeConfig(name: "新节点 \(draft.nodes.count + 1)", host: "")
        draft.nodes.append(n)
        selN = n.id
    }

    private func addTunnel() {
        if draft.nodes.isEmpty {
            let n = NodeConfig(name: "新节点 1", host: "")
            draft.nodes.append(n)
            selN = n.id
        }
        let t = TunnelConfig(name: "新隧道 \(draft.tunnels.count + 1)",
                             nodeId: draft.nodes[0].id)
        draft.tunnels.append(t)
        selT = t.id
    }

    private func deleteSelected() {
        if mode == 0, let id = selT {
            draft.tunnels.removeAll { $0.id == id }
            selT = draft.tunnels.first?.id
        } else if mode == 1, let id = selN {
            draft.nodes.removeAll { $0.id == id }
            selN = draft.nodes.first?.id
        }
    }

    private func save() {
        // 归一化：去首尾空白、剔除空转发
        draft.nodes = draft.nodes.map { n in
            var n = n
            n.name = n.name.trimmingCharacters(in: .whitespaces)
            n.host = n.host.trimmingCharacters(in: .whitespaces)
            n.port = n.port.trimmingCharacters(in: .whitespaces)
            n.user = n.user.trimmingCharacters(in: .whitespaces)
            n.identityFile = n.identityFile.trimmingCharacters(in: .whitespaces)
            return n
        }
        draft.tunnels = draft.tunnels.map { t in
            var t = t
            t.name = t.name.trimmingCharacters(in: .whitespaces)
            t.forwards = t.forwards
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return t
        }

        problems = validate()
        guard problems.isEmpty else { return }

        manager.applyConfig(draft)
        dismiss()
    }

    private func validate() -> [String] {
        var errs: [String] = []
        let nodeIDs = Set(draft.nodes.map(\.id))

        for n in draft.nodes {
            if n.host.isEmpty {
                errs.append("节点「\(n.name.isEmpty ? "未命名" : n.name)」：主机不能为空")
            }
            if !n.port.isEmpty {
                if let p = Int(n.port), (1...65535).contains(p) {} else {
                    errs.append("节点「\(n.name.isEmpty ? n.host : n.name)」：端口「\(n.port)」非法")
                }
            }
        }
        for t in draft.tunnels {
            let label = t.name.isEmpty ? "（未命名隧道）" : t.name
            if t.name.isEmpty { errs.append("有一条隧道没有名称") }
            if !nodeIDs.contains(t.nodeId) {
                errs.append("隧道「\(label)」：未选择节点")
            }
            if t.forwards.isEmpty {
                errs.append("隧道「\(label)」：至少需要一条转发规则")
            }
            for f in t.forwards {
                let seg = f.split(separator: ":", omittingEmptySubsequences: false)
                if !(3...4).contains(seg.count) {
                    errs.append("隧道「\(label)」：转发「\(f)」格式应为 [绑定地址:]端口:目标:目标端口")
                }
            }
        }
        return errs
    }
}

// MARK: - 隧道表单

struct TunnelForm: View {
    @Binding var t: TunnelConfig
    let nodes: [NodeConfig]

    var body: some View {
        Form {
            TextField("名称", text: $t.name)

            Picker("节点", selection: $t.nodeId) {
                ForEach(nodes) { n in
                    Text(n.name.isEmpty ? n.host : n.name).tag(n.id)
                }
            }

            LabeledContent("转发规则 (-L)") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(t.forwards.indices, id: \.self) { i in
                        HStack {
                            TextField("127.0.0.1:15432:127.0.0.1:5432", text: $t.forwards[i])
                                .font(.system(size: 12, design: .monospaced))
                            Button {
                                t.forwards.remove(at: i)
                            } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                            .help("删除这条转发")
                        }
                    }
                    Button {
                        withAnimation { t.forwards.append("") }
                    } label: {
                        Label("添加转发", systemImage: "plus.circle")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                }
            }

            TextField("附加参数（空格分隔，如 -v）", text: extraString)

            Toggle("自动启动", isOn: $t.autoStart)
                .help("应用启动时自动拉起这条隧道")
        }
        .formStyle(.grouped)
    }

    private var extraString: Binding<String> {
        Binding(
            get: { t.extraArgs.joined(separator: " ") },
            set: { t.extraArgs = $0.split(separator: " ").map(String.init).filter { !$0.isEmpty } }
        )
    }
}

// MARK: - 节点表单

struct NodeForm: View {
    @Binding var n: NodeConfig
    let usedBy: [String]

    var body: some View {
        Form {
            TextField("名称", text: $n.name)
            TextField("主机（域名 / IP / ssh 别名）", text: $n.host)
            TextField("端口（留空 = 沿用别名或默认 22）", text: $n.port)
            TextField("用户（留空 = 沿用别名或本机用户）", text: $n.user)
            TextField("密钥路径（留空 = 默认）", text: $n.identityFile)

            Text(hint)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            if !usedBy.isEmpty {
                Text("被隧道使用：\(usedBy.joined(separator: "、"))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var hint: String {
        if n.host.contains(" ") || n.host.isEmpty {
            return "提示：主机一栏填 ~/.ssh/config 里的别名时，端口/用户/密钥留空即可沿用别名里的定义"
        }
        return "端口/用户/密钥留空 = 不附加对应参数，交给 ssh 默认行为处理"
    }
}
