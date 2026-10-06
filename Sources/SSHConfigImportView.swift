import SwiftUI

enum SSHConfigImportState {
    case loading
    case loaded(SSHConfigImportResult)
    case failed(String)
}

struct SSHConfigImportView: View {
    let existingNodes: [NodeConfig]
    let onImport: ([NodeConfig]) -> Void
    private let load: () async throws -> SSHConfigImportResult
    private let loadsOnAppear: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var state: SSHConfigImportState
    @State private var selected: Set<String>
    @State private var search = ""
    @State private var reload = 0

    init(existingNodes: [NodeConfig], initialState: SSHConfigImportState? = nil,
         initialSelection: Set<String> = [], load: @escaping () async throws -> SSHConfigImportResult = SSHConfigImporter.loadUserConfig,
         onImport: @escaping ([NodeConfig]) -> Void) {
        self.existingNodes = existingNodes; self.onImport = onImport; self.load = load
        loadsOnAppear = initialState == nil
        _state = State(initialValue: initialState ?? .loading)
        _selected = State(initialValue: initialSelection)
    }

    private var existingHosts: Set<String> {
        Set(existingNodes.map { $0.host.trimmingCharacters(in: .whitespacesAndNewlines) })
    }
    private var result: SSHConfigImportResult? {
        if case .loaded(let result) = state { return result }
        return nil
    }
    private var visibleHosts: [SSHConfigHost] {
        (result?.hosts ?? []).filter { search.isEmpty || $0.alias.localizedCaseInsensitiveContains(search) }
    }
    private var selectableHosts: Set<String> {
        Set(visibleHosts.map(\.alias)).subtracting(existingHosts)
    }
    private var importNodes: [NodeConfig] {
        SSHConfigImporter.nodes(from: result?.hosts ?? [], selected: selected, existing: existingNodes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Label("从 SSH 配置导入", systemImage: "square.and.arrow.down")
                    .font(.system(size: 17, weight: .semibold))
                Text("~/.ssh/config").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                Text("选择 Host 别名。用户、端口、私钥和跳板机继续沿用 SSH 配置。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.padding(20)
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 12) {
                Text(importNodes.isEmpty ? "导入后加入草稿，保存后生效" : "已选择 \(importNodes.count) 个 · 导入后加入草稿")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(importNodes.isEmpty ? "导入节点" : "导入 \(importNodes.count) 个节点") { onImport(importNodes) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(importNodes.isEmpty)
            }.padding(.horizontal, 20).padding(.vertical, 16)
        }
        .frame(width: 540, height: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: reload) {
            guard loadsOnAppear else { return }
            state = .loading
            do {
                let loaded = try await load()
                guard !Task.isCancelled else { return }
                state = .loaded(loaded)
                selected = selected.intersection(Set(loaded.hosts.map(\.alias))).subtracting(existingHosts)
            } catch {
                guard !Task.isCancelled else { return }
                state = .failed(error.localizedDescription)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .loading:
            ProgressView("正在读取 SSH 配置…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            emptyState("无法读取 SSH 配置", message: message, icon: "exclamationmark.triangle")
        case .loaded(let result):
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("搜索 Host 别名", text: $search).textFieldStyle(.plain)
                        if !search.isEmpty {
                            Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("清除搜索")
                        }
                    }.font(.system(size: 12)).padding(7)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                    Button(selected.isSuperset(of: selectableHosts) && !selectableHosts.isEmpty ? "取消全选" : "全选") {
                        if selected.isSuperset(of: selectableHosts) { selected.subtract(selectableHosts) }
                        else { selected.formUnion(selectableHosts) }
                    }.disabled(selectableHosts.isEmpty)
                    Button { reload += 1 } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("重新读取 SSH 配置").accessibilityLabel("重新读取 SSH 配置")
                }.padding(.horizontal, 20).padding(.vertical, 12)
                if result.hosts.isEmpty {
                    emptyState("没有可导入的 Host", message: "请在 SSH 配置中定义具体 Host 别名。Host * 等通配规则不会作为节点。",
                               icon: "server.rack")
                } else if visibleHosts.isEmpty {
                    Text("没有匹配的 Host 别名").font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(visibleHosts) { host in
                        HStack(spacing: 12) {
                            Toggle(isOn: Binding(get: { selected.contains(host.alias) && !existingHosts.contains(host.alias) }, set: { value in
                                if value { selected.insert(host.alias) } else { selected.remove(host.alias) }
                            })) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(host.alias).font(.system(size: 13, weight: .medium))
                                        .lineLimit(1).truncationMode(.middle)
                                    Text("\(host.source.lastPathComponent) · 第 \(host.line) 行")
                                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                                        .help(host.source.path)
                                }
                            }.toggleStyle(.checkbox).disabled(existingHosts.contains(host.alias))
                            Spacer(minLength: 0)
                            if existingHosts.contains(host.alias) {
                                Label("已添加", systemImage: "checkmark")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 5)
                    }.listStyle(.plain).scrollContentBackground(.hidden)
                }
                if !result.warnings.isEmpty {
                    DisclosureGroup("\(result.warnings.count) 条读取提示") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(result.warnings, id: \.self) { warning in
                                    Text(warning).frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }.padding(.top, 6)
                        }.frame(maxHeight: 72)
                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                        .padding(.horizontal, 20).padding(.vertical, 10)
                }
            }
        }
    }

    private func emptyState(_ title: String, message: String, icon: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 26, weight: .light)).foregroundStyle(.secondary)
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(message).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("重新读取") { reload += 1 }.padding(.top, 3)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
