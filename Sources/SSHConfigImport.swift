import Foundation
import Darwin

struct SSHConfigHost: Identifiable, Equatable {
    let alias: String
    let source: URL
    let line: Int
    var id: String { alias }
}

struct SSHConfigImportResult {
    let source: URL
    var hosts: [SSHConfigHost] = []
    var warnings: [String] = []
}

/// 仅发现静态 Host 别名。导入后仍由 SSH 解析用户、密钥、跳板机及其他选项。
/// 不运行 ssh -G，因为它也可能执行配置中的 Match exec。
enum SSHConfigImporter {
    static func loadUserConfig() async throws -> SSHConfigImportResult {
        try await Task.detached(priority: .userInitiated) {
            let home = FileManager.default.homeDirectoryForCurrentUser
            return try read(home.appendingPathComponent(".ssh/config"), home: home)
        }.value
    }

    static func read(_ source: URL, home: URL,
                     environment: [String: String] = ProcessInfo.processInfo.environment) throws -> SSHConfigImportResult {
        var reader = Reader(home: home, environment: environment, result: SSHConfigImportResult(source: source))
        try reader.scan(source, depth: 0)
        return reader.result
    }

    static func nodes(from hosts: [SSHConfigHost], selected: Set<String>, existing: [NodeConfig]) -> [NodeConfig] {
        var added = Set(existing.map { $0.host.trimmingCharacters(in: .whitespacesAndNewlines) })
        return hosts.compactMap { host in
            guard selected.contains(host.alias), added.insert(host.alias).inserted else { return nil }
            return NodeConfig(name: host.alias, host: host.alias)
        }
    }

    private struct Reader {
        let home: URL
        let environment: [String: String]
        var result: SSHConfigImportResult
        var visited: Set<String> = []
        var stack: Set<String> = []
        var aliases: Set<String> = []
        var byteCount = 0

        mutating func warn(_ message: String) {
            if result.warnings.count < 20 && !result.warnings.contains(message) {
                result.warnings.append(message)
            }
        }

        mutating func scan(_ source: URL, depth: Int) throws {
            let path = source.resolvingSymlinksInPath().standardizedFileURL.path
            guard depth < 32, visited.count < 256 else {
                warn("Include 层级或文件数量过多，部分文件已跳过。")
                return
            }
            guard !stack.contains(path) else {
                warn("\(source.lastPathComponent)：循环 Include 已跳过。")
                return
            }
            guard visited.insert(path).inserted else { return }
            let text: String
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: path)
                guard attributes[.type] as? FileAttributeType == .typeRegular else {
                    throw ImportError.message("路径不是普通配置文件。")
                }
                let handle = try FileHandle(forReadingFrom: source)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: 1_048_577) ?? Data()
                guard data.count <= 1_048_576, byteCount + data.count <= 8_388_608 else {
                    throw ImportError.message("配置文件过大，读取已停止。")
                }
                guard let decoded = String(data: data, encoding: .utf8) else {
                    throw ImportError.message("文件不是 UTF-8 文本。")
                }
                text = decoded; byteCount += data.count
            } catch {
                if depth == 0 {
                    if (error as NSError).code == NSFileReadNoSuchFileError {
                        throw ImportError.message("未找到 ~/.ssh/config。请先在 SSH 配置中添加 Host 别名。")
                    }
                    throw ImportError.message("无法读取 SSH 配置：\(error.localizedDescription)")
                }
                warn("\(source.lastPathComponent)：无法读取，已跳过。")
                return
            }
            stack.insert(path)
            defer { stack.remove(path) }
            var unconditional = true
            for (offset, line) in text.components(separatedBy: .newlines).enumerated() {
                guard let (keyword, arguments) = directive(line) else { continue }
                if keyword == "match" {
                    // 只识别恒真的 Match all；其他条件交给 SSH 在实际连接时判断。
                    unconditional = (try? tokens(arguments).map { $0.lowercased() }) == ["all"]
                    continue
                }
                guard keyword == "host" || keyword == "include" else { continue }
                let values: [String]
                do { values = try tokens(arguments) }
                catch {
                    warn("\(source.lastPathComponent):\(offset + 1)：引号未闭合，已跳过。")
                    if keyword == "host" { unconditional = false }
                    continue
                }
                if keyword == "host" {
                    unconditional = values.contains("*") && !values.contains { $0.hasPrefix("!") }
                    for alias in values where isLiteral(alias) {
                        let excluded = values.filter { $0.hasPrefix("!") }.contains {
                            matches(alias, pattern: String($0.dropFirst()))
                        }
                        if !excluded && aliases.insert(alias).inserted {
                            result.hosts.append(SSHConfigHost(alias: alias, source: source, line: offset + 1))
                        }
                    }
                } else {
                    guard unconditional else {
                        warn("\(source.lastPathComponent):\(offset + 1)：条件 Include 中的额外别名未展开。")
                        continue
                    }
                    for value in values {
                        guard let pattern = includePath(value) else {
                            warn("\(source.lastPathComponent):\(offset + 1)：Include 路径依赖动态值，已跳过。")
                            continue
                        }
                        for included in globPaths(pattern) {
                            try scan(URL(fileURLWithPath: included), depth: depth + 1)
                        }
                    }
                }
            }
        }

        func includePath(_ value: String) -> String? {
            var path = ""
            var index = value.startIndex
            while index < value.endIndex {
                let char = value[index]
                let next = value.index(after: index)
                if char == "$", next < value.endIndex, value[next] == "{" {
                    guard let end = value[next...].firstIndex(of: "}"),
                          let replacement = environment[String(value[value.index(after: next)..<end])] else { return nil }
                    path += replacement; index = value.index(after: end)
                } else if char == "%" {
                    guard next < value.endIndex else { return nil }
                    switch value[next] {
                    case "%": path += "%"
                    case "d": path += home.path
                    default: return nil
                    }
                    index = value.index(after: next)
                } else {
                    path.append(char); index = next
                }
            }
            if path == "~" { path = home.path }
            else if path.hasPrefix("~/") { path = home.path + String(path.dropFirst()) }
            else if path.hasPrefix("~") { path = (path as NSString).expandingTildeInPath }
            guard !path.isEmpty, !path.hasPrefix("~") else { return nil }
            return path.hasPrefix("/") ? path : home.appendingPathComponent(".ssh").appendingPathComponent(path).path
        }
    }

    private enum ImportError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
    }

    private static func isLiteral(_ alias: String) -> Bool {
        !alias.isEmpty && !alias.hasPrefix("!") && !alias.hasPrefix("-")
            && !alias.contains("*") && !alias.contains("?")
            && alias.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
    }

    private static func matches(_ alias: String, pattern: String) -> Bool {
        let expression = "^" + pattern.map { char -> String in
            if char == "*" { return ".*" }
            if char == "?" { return "." }
            return NSRegularExpression.escapedPattern(for: String(char))
        }.joined() + "$"
        return alias.range(of: expression, options: .regularExpression) != nil
    }

    private static func directive(_ line: String) -> (String, String)? {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !text.hasPrefix("#") else { return nil }
        let end = text.firstIndex { $0.isWhitespace || $0 == "=" } ?? text.endIndex
        let keyword = String(text[..<end]).lowercased()
        var rest = text[end...].trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("=") { rest = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces) }
        return (keyword, rest)
    }

    private static func tokens(_ text: String) throws -> [String] {
        var result: [String] = [], token = ""
        var quote: Character?, escaped = false, started = false
        for char in text {
            if escaped { token.append(char); escaped = false; started = true; continue }
            if char == "\\", quote != "'" { escaped = true; started = true; continue }
            if let delimiter = quote {
                if char == delimiter { quote = nil } else { token.append(char) }
                continue
            }
            if char == "#", !started { break }
            if char == "\"" || char == "'" { quote = char; started = true }
            else if char.isWhitespace {
                if started { result.append(token); token = ""; started = false }
            } else { token.append(char); started = true }
        }
        guard quote == nil, !escaped else { throw ImportError.message("引号未闭合") }
        if started { result.append(token) }
        return result
    }

    private static func globPaths(_ pattern: String) -> [String] {
        var matches = glob_t()
        defer { globfree(&matches) }
        guard glob(pattern, 0, nil, &matches) == 0, let paths = matches.gl_pathv else { return [] }
        return (0..<Int(matches.gl_pathc)).compactMap { paths[$0].map { String(cString: $0) } }.sorted()
    }
}
