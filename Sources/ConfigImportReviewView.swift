import SwiftUI

struct ConfigImportReview: Identifiable {
    let document: ConfigImportDocument
    let mergePlan: ConfigImportPlan
    var id: UUID { document.id }
}

enum ConfigImportMode: String, CaseIterable {
    case merge = "合并到草稿"
    case replace = "替换草稿"
}

struct ConfigImportReviewView: View {
    let review: ConfigImportReview
    let baseline: AppConfig
    let existingDraft: AppConfig
    let activeIDs: Set<String>
    let apply: (AppConfig) -> Void
    @State private var mode: ConfigImportMode
    @Environment(\.dismiss) private var dismiss

    init(review: ConfigImportReview, baseline: AppConfig, existingDraft: AppConfig,
         activeIDs: Set<String> = [], initialMode: ConfigImportMode = .merge,
         apply: @escaping (AppConfig) -> Void) {
        self.review = review; self.baseline = baseline; self.existingDraft = existingDraft
        self.activeIDs = activeIDs; self.apply = apply
        _mode = State(initialValue: initialMode)
    }

    private var candidate: AppConfig { mode == .merge ? review.mergePlan.config : review.document.config }
    private var impact: ConfigSaveImpact {
        ConfigDraftRules.impact(from: baseline, to: candidate, activeIDs: activeIDs)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Label("导入配置", systemImage: "square.and.arrow.down")
                    .font(.system(size: 18, weight: .semibold))
                Text(review.document.source.lastPathComponent).font(.system(size: 12)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(review.document.source.path)
                HStack(spacing: 24) {
                    count("分组", review.document.config.groups.count)
                    count("SSH 节点", review.document.config.nodes.count)
                    count("隧道", review.document.config.tunnels.count)
                }.padding(.top, 8)
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("导入方式", selection: $mode) {
                        ForEach(ConfigImportMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                    Text(mode == .merge
                         ? "保留现有草稿，同名分组合并。相同的节点和隧道会跳过，其余作为新资源加入。"
                         : "用文件中的内容替换整个草稿，文件中没有的分组、节点与隧道会被移除。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if mode == .merge {
                        Text(review.mergePlan.summary).font(.system(size: 12, weight: .medium))
                            .fixedSize(horizontal: false, vertical: true)
                    } else if existingDraft != baseline {
                        Label("当前未保存的修改也会被替换。", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12)).foregroundStyle(.orange)
                    }
                    if !impact.description.isEmpty {
                        Text("保存后：\(impact.description)")
                            .font(.system(size: 12)).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if candidate == existingDraft {
                        Text("与当前草稿相同，无需重复导入。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    if !review.document.config.tunnels.isEmpty {
                        Divider()
                        ForEach(Array(review.document.config.tunnels.prefix(50))) { tunnel in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(tunnel.name.isEmpty ? tunnel.id : tunnel.name)
                                    .font(.system(size: 12, weight: .medium))
                                Text(tunnelDetail(tunnel)).font(.system(size: 11)).foregroundStyle(.secondary)
                                    .lineLimit(2).truncationMode(.middle)
                            }
                        }
                        if review.document.config.tunnels.count > 50 {
                            Text("仅预览前 50 条，导入包含全部隧道。").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }.padding(20)
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("导入先写入草稿，点击保存后生效；保存前会自动备份当前配置。私钥和 SSH 别名配置需在本机另行准备。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("导入到草稿") { apply(candidate) }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(candidate == existingDraft)
                }
            }.padding(20)
        }
        .frame(width: 560, height: 570)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func count(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(value)").font(.system(size: 21, weight: .semibold)).monospacedDigit()
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tunnelDetail(_ tunnel: TunnelConfig) -> String {
        let node = review.document.config.nodes.first { $0.id == tunnel.nodeId }
        return "\(node?.sshTarget ?? tunnel.nodeId) · \(tunnel.forwards.count) 条转发" +
            (tunnel.autoStart ? " · 自动启动" : "")
    }
}
