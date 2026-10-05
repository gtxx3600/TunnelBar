// 配置窗口：节点 / 隧道 图形化管理（主从式：左列表右表单）

import SwiftUI
import AppKit

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

    private let sidebarWidth: CGFloat = 150

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $mode) {
                Text("隧道 · \(draft.tunnels.count)").tag(0)
                Text("节点 · \(draft.nodes.count)").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 264)
            .padding(.top, 14)
            .padding(.bottom, 12)

            HStack(spacing: 0) {
                listPane.frame(width: sidebarWidth)
                Divider()
                detailPane
            }

            Divider()
            footer
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .frame(minWidth: 680, idealWidth: 720, minHeight: 500, idealHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            draft = manager.current
            selT = draft.tunnels.first?.id
            selN = draft.nodes.first?.id
            enforceDefaultFrameOnce()
        }
        .alert("无法保存", isPresented: Binding(
            get: { !problems.isEmpty },
            set: { if !$0 { problems = [] } })) {
            Button("好") { problems = [] }
        } message: {
            Text(problems.joined(separator: "\n"))
        }
        .alert(noticeTitle, isPresented: Binding(
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

    private var noticeTitle: String { notice.isEmpty ? "" : String(notice.prefix(20)) }

    /// macOS 26 上经 openWindow 延迟创建的窗口有时按内容最小尺寸(680×500)打开、
    /// 忽略场景的 defaultSize；首次出现时若小于默认尺寸，恢复为 720×520。
    /// 只放大，不缩小用户手动调大的窗口。
    private func enforceDefaultFrameOnce() {
        DispatchQueue.main.async {
            guard let w = NSApp.windows.first(where: { $0.title == "TunnelBar 配置" }) else { return }
            let content = w.contentRect(forFrameRect: w.frame).size
            guard content.width < 720 || content.height < 520 else { return }
            w.setContentSize(NSSize(width: 720, height: 520))
        }
    }

    // MARK: 左侧列表

    private var listPane: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 3) {
                    if mode == 0 {
                        ForEach(draft.tunnels) { t in
                            listRow(title: t.name.isEmpty ? "（未命名）" : t.name,
                                    sub: "\(nodeNameInDraft(t.nodeId)) · \(t.forwards.count) 条转发",
                                    badge: t.autoStart ? "自启" : nil,
                                    selected: selT == t.id)
                                .onTapGesture { selT = t.id }
                        }
                    } else {
                        ForEach(draft.nodes) { n in
                            listRow(title: n.name.isEmpty ? n.host : n.name,
                                    sub: n.sshTarget + (n.port.isEmpty ? "" : " :\(n.port)"),
                                    badge: nil,
                                    selected: selN == n.id)
                                .onTapGesture { selN = n.id }
                        }
                    }
                }
                .padding(8)
            }
            Divider()
            Button {
                mode == 0 ? addTunnel() : addNode()
            } label: {
                Label(mode == 0 ? "新建隧道" : "新建节点", systemImage: "plus")
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
    }

    private func listRow(title: String, sub: String, badge: String?, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            HStack(spacing: 5) {
                Text(sub)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Color.accentColor.opacity(0.12) : Color.clear))
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
                ScrollView {
                    TunnelForm(t: $draft.tunnels[i], nodes: draft.nodes)
                        // 按选中 id 重建表单身份：否则同窗口内切换隧道时
                        // TunnelForm 的 @State rows 不会重新解析，旧数据会串进新隧道
                        .id(selT)
                        .padding(12)
                }
            } else {
                placeholder("选择左侧隧道，或新建一条")
            }
        } else {
            if let i = draft.nodes.firstIndex(where: { $0.id == selN }) {
                ScrollView {
                    NodeForm(n: $draft.nodes[i],
                             usedBy: draft.tunnels.filter { $0.nodeId == draft.nodes[i].id }
                                 .map { $0.name.isEmpty ? $0.id : $0.name })
                        .id(selN)
                        .padding(12)
                }
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
        HStack(spacing: 10) {
            Spacer()

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

            Button("恢复未保存的修改") {
                draft = manager.current
                selT = draft.tunnels.first?.id
                selN = draft.nodes.first?.id
            }

            Button("保存") { save() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .buttonStyle(.bordered)
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

    @State private var rows: [ForwardRow] = []

    var body: some View {
        VStack(spacing: 12) {
            SectionCard(title: "基本信息") {
                VStack(spacing: 10) {
                    FormRow(label: "名称") {
                        TextField("隧道名称", text: $t.name)
                            .textFieldStyle(.roundedBorder)
                    }
                    FormRow(label: "节点") {
                        Picker("", selection: $t.nodeId) {
                            ForEach(nodes) { n in
                                Text(n.name.isEmpty ? n.host : n.name).tag(n.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                    }
                }
            }

            SectionCard(title: "转发规则") {
                VStack(alignment: .leading, spacing: 10) {
                    forwardGrid

                    HStack(spacing: 8) {
                        Button {
                            rows.append(ForwardRow(bind: "127.0.0.1"))
                        } label: {
                            Label("添加转发", systemImage: "plus.circle")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.borderless)

                        Spacer()

                        if rows.filter({ $0.problem != nil }).count > 0 {
                            let n = rows.filter { $0.problem != nil }.count
                            Text("⚠︎ \(n) 条规则未填完整，保存时将被忽略")
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }

            SectionCard(title: "高级") {
                VStack(spacing: 10) {
                    FormRow(label: "附加参数") {
                        TextField("空格分隔，如 -v", text: extraString)
                            .textFieldStyle(.roundedBorder)
                    }
                    FormRow(label: "自动启动") {
                        Toggle("", isOn: $t.autoStart)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .help("应用启动时自动拉起这条隧道")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .onAppear {
            rows = t.forwards.compactMap { ForwardRow.parse($0) }
            if rows.isEmpty { rows = [ForwardRow(bind: "127.0.0.1")] }
        }
        .onChange(of: rows) { _ in
            t.forwards = rows.compactMap(\.serialized)
        }
    }

    // MARK: 转发规则表格（Grid 严格列对齐）
    // 列：本地地址(110) / 本地端口(64) / 箭头(24) / 目标地址(可伸展，默认窗口下 ≥180)
    //     / 目标端口(64) / 状态与删除(48)

    private var forwardGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 8) {
            GridRow {
                forwardHeader("本地地址", width: 110)
                forwardHeader("本地端口", width: 68)
                Color.clear.frame(width: 24)
                Text("目标地址")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                forwardHeader("目标端口", width: 68)
                Color.clear.frame(width: 56)
            }
            ForEach($rows) { $row in
                GridRow {
                    forwardCell($row.bind, "127.0.0.1", width: 110, invalid: false)
                    forwardCell($row.port, "端口", width: 68,
                                invalid: !row.port.isEmpty && UInt16(row.port) == nil)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                    forwardCell($row.host, "127.0.0.1 / 域名", width: nil, invalid: false)
                    forwardCell($row.rport, "端口", width: 68,
                                invalid: !row.rport.isEmpty && UInt16(row.rport) == nil)
                    forwardStatus(row) {
                        rows.removeAll { $0.id == row.id }
                    }
                }
            }
        }
    }

    private func forwardHeader(_ title: String, width: CGFloat) -> some View {
        Text(title)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: .leading)
    }

    @ViewBuilder
    private func forwardCell(_ text: Binding<String>, _ placeholder: String,
                             width: CGFloat?, invalid: Bool) -> some View {
        let field = TextField(placeholder, text: text)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, design: .monospaced))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(invalid ? Color.red.opacity(0.6) : Color.clear, lineWidth: 1))
        if let width {
            field.frame(width: width)
        } else {
            field.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func forwardStatus(_ row: ForwardRow, onDelete: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            if let p = row.problem {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .help(p)
            }
            Button(action: onDelete) {
                Image(systemName: "minus.circle.fill").foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help("删除这条转发")
        }
        .frame(width: 56)
    }

    private var extraString: Binding<String> {
        Binding(
            get: { t.extraArgs.joined(separator: " ") },
            set: { t.extraArgs = $0.split(separator: " ").map(String.init).filter { !$0.isEmpty } }
        )
    }
}

// MARK: - 转发规则行（结构化编辑，稳定的 UUID 身份）

struct ForwardRow: Identifiable, Equatable {
    let id = UUID()
    var bind = ""
    var port = ""
    var host = ""
    var rport = ""

    var isEmpty: Bool { bind.isEmpty && port.isEmpty && host.isEmpty && rport.isEmpty }

    /// 合法且填写完整才序列化；不完整/非法返回 nil（编辑中不落盘）
    var serialized: String? {
        guard !isEmpty,
              let _ = UInt16(port), let _ = UInt16(rport),
              !host.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let b = bind.trimmingCharacters(in: .whitespaces)
        let h = host.trimmingCharacters(in: .whitespaces)
        return b.isEmpty ? "\(port):\(h):\(rport)" : "\(b):\(port):\(h):\(rport)"
    }

    /// 具体哪里没填好；全空行不算问题
    var problem: String? {
        if isEmpty { return nil }
        if port.isEmpty { return "本地端口未填" }
        if UInt16(port) == nil { return "本地端口「\(port)」需为 1-65535" }
        if rport.isEmpty { return "目标端口未填" }
        if UInt16(rport) == nil { return "目标端口「\(rport)」需为 1-65535" }
        if host.trimmingCharacters(in: .whitespaces).isEmpty { return "目标地址未填" }
        return nil
    }

    /// 宽容解析既有 -L 字符串；对不认识的格式塞进地址栏让用户自己修
    static func parse(_ s: String) -> ForwardRow? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let seg = trimmed.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        switch seg.count {
        case 3:
            return ForwardRow(bind: "", port: seg[0], host: seg[1], rport: seg[2])
        case 4:
            return ForwardRow(bind: seg[0], port: seg[1], host: seg[2], rport: seg[3])
        case let n where n > 4:
            // IPv6 目标：bind、port 取头两段，rport 取尾，中间合并为地址
            return ForwardRow(bind: seg[0], port: seg[1],
                              host: seg[2..<(n - 1)].joined(separator: ":"),
                              rport: seg[n - 1])
        default:
            return ForwardRow(host: trimmed)
        }
    }
}

// MARK: - 节点表单

struct NodeForm: View {
    @Binding var n: NodeConfig
    let usedBy: [String]

    var body: some View {
        VStack(spacing: 12) {
            SectionCard(title: "连接信息") {
                VStack(spacing: 10) {
                    FormRow(label: "名称") {
                        TextField("节点名称", text: $n.name)
                            .textFieldStyle(.roundedBorder)
                    }
                    FormRow(label: "主机") {
                        TextField("域名 / IP / ssh 别名", text: $n.host)
                            .textFieldStyle(.roundedBorder)
                    }
                    FormRow(label: "端口") {
                        TextField("留空 = 沿用别名或默认 22", text: $n.port)
                            .textFieldStyle(.roundedBorder)
                    }
                    FormRow(label: "用户") {
                        TextField("留空 = 沿用别名或本机用户", text: $n.user)
                            .textFieldStyle(.roundedBorder)
                    }
                    FormRow(label: "密钥路径") {
                        TextField("留空 = 默认", text: $n.identityFile)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }

            SectionCard(title: "说明") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    if !usedBy.isEmpty {
                        Text("被隧道使用：\(usedBy.joined(separator: "、"))")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var hint: String {
        if n.host.contains(" ") || n.host.isEmpty {
            return "提示：主机一栏填 ~/.ssh/config 里的别名时，端口/用户/密钥留空即可沿用别名里的定义"
        }
        return "端口/用户/密钥留空 = 不附加对应参数，交给 ssh 默认行为处理"
    }
}

// MARK: - 分节卡片与表单行（系统设置观感的复用件）

private struct SectionCard<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.07)))
    }
}

private struct FormRow<Content: View>: View {
    let label: String
    let content: Content

    init(label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 13))
                .frame(width: 76, alignment: .leading)
            content
        }
    }
}
