import AppKit
import UniformTypeIdentifiers

enum ConfigFilePanels {
    static func chooseImport() throws -> ConfigImportDocument? {
        let panel = NSOpenPanel()
        panel.title = "导入 TunnelBar 配置"
        panel.prompt = "预览导入"
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return try ConfigTransfer.read(from: url)
    }

    static func export(_ config: AppConfig, protecting configURL: URL) throws -> URL? {
        let panel = NSSavePanel()
        panel.title = "导出已保存的配置"
        panel.prompt = "导出"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "TunnelBar-config-\(date.string(from: Date())).json"
        panel.message = "导出分组、节点与隧道。私钥仅包含路径；登录时启动设置仅保存在本机。"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        try ConfigTransfer.export(config, to: url, protecting: configURL)
        return url
    }
}
