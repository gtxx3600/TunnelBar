import SwiftUI

struct TunnelTemplatePicker: View {
    let nodes: [NodeConfig]
    let groups: [TunnelGroupConfig]
    let create: (TunnelTemplate, String, String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var nodeID: String
    @State private var groupID: String
    @State private var template: TunnelTemplate

    init(nodes: [NodeConfig], groups: [TunnelGroupConfig] = [], selectedNode: String? = nil,
         selectedGroup: String? = nil, initialTemplate: TunnelTemplate = .custom,
         create: @escaping (TunnelTemplate, String, String?) -> Void) {
        self.nodes = nodes; self.groups = groups; self.create = create
        _nodeID = State(initialValue: selectedNode ?? nodes.first?.id ?? "")
        _groupID = State(initialValue: selectedGroup ?? "")
        _template = State(initialValue: initialTemplate)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("新建隧道").font(.system(size: 21, weight: .semibold))
                Text("选择用途，自动填好常用转发规则。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Picker("SSH 节点", selection: $nodeID) {
                ForEach(nodes) { node in
                    Text(node.name.isEmpty ? node.host : node.name).tag(node.id)
                }
            }
            Picker("所属分组", selection: $groupID) {
                Text("未分组").tag("")
                ForEach(groups) { group in Text(group.name).tag(group.id) }
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(TunnelTemplate.allCases) { option in
                    Button { template = option } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: option.icon).font(.system(size: 17))
                                .frame(width: 22).padding(.top, 2)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(option.title).font(.system(size: 13, weight: .semibold))
                                Text(option.subtitle).font(.system(size: 10.5)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                            if template == option { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
                        }
                        .foregroundStyle(.primary)
                        .padding(12).frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
                        .background(template == option ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.025),
                                    in: RoundedRectangle(cornerRadius: 9))
                        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(template == option ? Color.accentColor : Color.primary.opacity(0.10), lineWidth: 1) }
                        .contentShape(RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(option.title + "，" + option.subtitle)
                    .accessibilityAddTraits(template == option ? .isSelected : [])
                }
            }
            Text("本机端口会避开已有配置。创建后可继续编辑，保存后生效；默认不自动启动。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("创建草稿") { create(template, nodeID, groupID.isEmpty ? nil : groupID) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!nodes.contains { $0.id == nodeID })
            }
        }
        .padding(24).frame(width: 580)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
