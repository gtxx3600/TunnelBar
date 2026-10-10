import Foundation
import Darwin

/// 应用私有目录先设为 0700，再写入文件；配置、备份、PID 与日志均为 0600。
enum PrivateStorage {
    static func prepareDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try restrict(url, type: .typeDirectory, mode: 0o700)
    }

    static func protectFile(_ url: URL) throws {
        try restrict(url, type: .typeRegular, mode: 0o600)
    }

    static func write(_ data: Data, to url: URL, options: Data.WritingOptions = .atomic) throws {
        try prepareDirectory(url.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: url.path) { try protectFile(url) }
        try data.write(to: url, options: options)
        try protectFile(url)
    }

    static func logHandle(at url: URL) throws -> FileHandle {
        try prepareDirectory(url.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: url.path) {
            try protectFile(url)
            try FileManager.default.removeItem(at: url)
        }
        guard FileManager.default.createFile(atPath: url.path, contents: Data(),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw ConfigStoreError.invalid("无法创建私有日志文件")
        }
        let handle = try FileHandle(forWritingTo: url)
        let flags = fcntl(handle.fileDescriptor, F_GETFL)
        guard flags >= 0, fcntl(handle.fileDescriptor, F_SETFL, flags | O_APPEND) == 0 else {
            try? handle.close()
            throw ConfigStoreError.invalid("无法设置诊断日志的追加写入模式")
        }
        return handle
    }

    /// 兼容旧版本创建的文件：仅修改应用自身文件的权限，不修改内容或连接状态。
    static func protectExistingStorage(config url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try prepareDirectory(directory)
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let name = file.lastPathComponent
            let importBackup = name.hasPrefix(url.deletingPathExtension().lastPathComponent + ".before-import.") && name.hasSuffix(".json")
            if name == url.lastPathComponent || importBackup || (name.hasPrefix(url.lastPathComponent + ".v1.") && name.hasSuffix(".bak")) {
                try protectFile(file)
            }
        }
        let run = directory.appendingPathComponent("run")
        if FileManager.default.fileExists(atPath: run.path) {
            try prepareDirectory(run)
            for file in try FileManager.default.contentsOfDirectory(at: run, includingPropertiesForKeys: nil)
                where ["pid", "log"].contains(file.pathExtension) {
                try protectFile(file)
            }
        }
    }

    private static func restrict(_ url: URL, type: FileAttributeType, mode: Int) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == type,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
            throw ConfigStoreError.invalid("私有存储路径必须是当前用户拥有的普通文件或目录")
        }
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }
}
