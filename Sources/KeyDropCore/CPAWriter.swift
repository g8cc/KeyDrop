import Foundation

final class CPAWriter {

    let configPath: String

    init(configPath: String) {
        self.configPath = configPath
    }

    static func locateConfig() -> String? {
        if let override = ProcessInfo.processInfo.environment["KEYDROP_CPA_CONFIG"] {
            return FileManager.default.fileExists(atPath: override) ? override : nil
        }
        if let fromPrefs = Prefs.shared.cpaConfigPath,
           FileManager.default.fileExists(atPath: fromPrefs) {
            return fromPrefs
        }
        if let fromProc = runningProcessConfig() { return fromProc }
        let candidates = [
            NSHomeDirectory() + "/cliproxyapi/config.yaml",
            NSHomeDirectory() + "/.cli-proxy-api/config.yaml",
            NSHomeDirectory() + "/.config/cli-proxy-api/config.yaml"
        ]
        for c in candidates {
            if FileManager.default.fileExists(atPath: c) { return c }
        }
        return nil
    }

    private static func runningProcessConfig() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-eo", "args="]
        let pipe = Pipe()
        proc.standardOutput = pipe
        do {
            try proc.run()
        } catch { return nil }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        proc.waitUntilExit()
        for line in out.split(whereSeparator: \.isNewline) {
            if line.contains("cli-proxy-api") || line.contains("CLIProxyAPI") {
                let parts = line.split(separator: " ").map(String.init)
                for (i, t) in parts.enumerated() {
                    if (t == "-config" || t == "--config" || t == "-c") && i + 1 < parts.count {
                        let p = NSString(string: parts[i + 1]).expandingTildeInPath
                        if FileManager.default.fileExists(atPath: p) { return p }
                    }
                    if t.hasPrefix("--config=") {
                        let p = NSString(string: String(t.dropFirst(9))).expandingTildeInPath
                        if FileManager.default.fileExists(atPath: p) { return p }
                    }
                }
            }
        }
        return nil
    }

    // MARK: - CPA endpoint info

    struct CPAEndpoint {
        let baseURL: String
        let clientKey: String
    }

    static func endpointInfo() -> CPAEndpoint? {
        let port = ProcessInfo.processInfo.environment["KEYDROP_CPA_PORT"]
            ?? readPortFromConfig() ?? "8317"
        let host = ProcessInfo.processInfo.environment["KEYDROP_CPA_HOST"] ?? "127.0.0.1"
        let baseURL: String
        if let envURL = ProcessInfo.processInfo.environment["KEYDROP_LLM_ENDPOINT"], !envURL.isEmpty {
            baseURL = envURL.hasSuffix("/v1") ? String(envURL.dropLast(3)) : envURL
        } else {
            baseURL = "http://\(host):\(port)"
        }
        let clientKey = LLMParser.apiKey
        guard !clientKey.isEmpty else { return nil }
        return CPAEndpoint(baseURL: baseURL, clientKey: clientKey)
    }

    private static func readPortFromConfig() -> String? {
        guard let cfg = locateConfig(),
              let content = try? String(contentsOfFile: cfg, encoding: .utf8)
        else { return nil }
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = String(line)
            let trimmed = l.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("port:"), !l.hasPrefix(" ") {
                let v = trimmed.dropFirst("port:".count).trimmingCharacters(in: .whitespaces)
                if !v.isEmpty { return v }
            }
        }
        return nil
    }

    // MARK: - add

    func add(_ p: ParsedKey, proxy: String? = nil) throws -> String {
        try addSingle(key: p.key, url: p.url, model: p.model, proxy: proxy)
        return "已写入 CPA 配置(\(configPath));CPA 运行时会自动热重载"
    }

    func addMulti(baseURL: String, keys: [String], proxy: String? = nil) throws -> String {
        var added = 0
        var skipped = 0
        for key in keys {
            do {
                try addSingle(key: key, url: baseURL, model: nil, proxy: proxy)
                added += 1
            } catch {
                if "\(error)".contains("已存在") { skipped += 1 } else { throw error }
            }
        }
        var parts: [String] = ["已写入 \(added) 个 key 到 CPA 配置(\(configPath))"]
        if skipped > 0 { parts.append("\(skipped) 个已存在,跳过") }
        return parts.joined(separator: "; ")
    }

    private func addSingle(key: String?, url: String?, model: String?, proxy: String? = nil) throws {
        guard let key, !key.isEmpty, let url, !url.isEmpty else { throw WriterError.missingURL }
        guard FileManager.default.fileExists(atPath: configPath) else {
            throw WriterError.file("CPA config 不存在: \(configPath)")
        }
        // 写入前校验现有配置,已损坏则拒绝修改(避免继续污染)
        do {
            try Self.validateYAML(path: configPath)
        } catch {
            throw WriterError.file("现有 CPA 配置 YAML 非法,拒绝修改: \(error.localizedDescription)\n(可用 config.yaml.keydrop-bak 恢复)")
        }
        let content = try String(contentsOfFile: configPath, encoding: .utf8)
        var lines = content.components(separatedBy: "\n")
        let section = findSection(in: lines)
        if let section,
           splitItems(lines: lines, section: section).contains(where: { itemContainsAPIKey($0, in: lines, key: key) }) {
            throw WriterError.file("该 key 已存在于 CPA 配置,跳过")
        }

        let secStart = section?.start ?? lines.count
        let secEnd = section?.end ?? lines.count
        let itemIndent = section?.itemIndent ?? "  "

        var block: [String] = []
        block.append("\(itemIndent)- api-key: \(yamlScalar(key))")
        block.append("\(itemIndent)  base-url: \(yamlScalar(url))")
        if let proxy, !proxy.isEmpty {
            block.append("\(itemIndent)  proxy-url: \(yamlScalar(proxy))")
        }
        if let model, !model.isEmpty {
            block.append("\(itemIndent)  models:")
            block.append("\(itemIndent)    - name: \(yamlScalar(model))")
            block.append("\(itemIndent)      alias: \(yamlScalar(model))")
        }

        if section != nil {
            var insertAt = secEnd
            while insertAt > secStart + 1, lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                insertAt -= 1
            }
            lines.insert(contentsOf: block, at: insertAt)
        } else {
            if let last = lines.last, !last.isEmpty { lines.append("") }
            lines.append("claude-api-key:")
            lines.append(contentsOf: block)
        }

        try atomicWrite(lines.joined(separator: "\n"))
    }

    // MARK: - remove

    func remove(apiKey: String) throws -> String {
        guard FileManager.default.fileExists(atPath: configPath) else {
            return "CPA config 不存在,跳过"
        }
        let content = try String(contentsOfFile: configPath, encoding: .utf8)
        var lines = content.components(separatedBy: "\n")
        guard let section = findSection(in: lines) else {
            return "CPA 配置中无 claude-api-key 段,跳过"
        }

        let items = splitItems(lines: lines, section: section)
        var removed = false
        var keepIdx = Set<Int>()
        for item in items {
            let isTarget = itemContainsAPIKey(item, in: lines, key: apiKey)
            if isTarget { removed = true } else { keepIdx.formUnion(item.range) }
        }
        if !removed { return "未在 CPA 配置中找到该 key" }

        let sectionRange = section.start..<section.end
        var newSectionLines: [String] = [lines[section.start]]
        var emitted = Set<Int>()
        for item in items where keepIdx.contains(item.range.lowerBound) {
            for i in item.range {
                newSectionLines.append(lines[i])
                emitted.insert(i)
            }
        }
        for i in (section.start + 1)..<section.end where !emitted.contains(i) {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || line.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
                newSectionLines.append(line)
            }
        }
        if newSectionLines.count == 1 {
            lines.removeSubrange(sectionRange)
        } else {
            lines.replaceSubrange(sectionRange, with: newSectionLines)
        }
        try atomicWrite(lines.joined(separator: "\n"))
        return "已从 CPA 配置移除该 key"
    }

    // MARK: - internals

    struct Section {
        let start: Int
        let end: Int
        let itemIndent: String?
    }

    private func findSection(in lines: [String]) -> Section? {
        var start: Int? = nil
        for (i, l) in lines.enumerated() {
            if !l.hasPrefix(" ") && !l.hasPrefix("\t") && l.trimmingCharacters(in: .whitespaces) == "claude-api-key:" {
                start = i
                break
            }
        }
        guard let s = start else { return nil }
        var end = lines.count
        for i in (s + 1)..<lines.count {
            let l = lines[i]
            guard !l.isEmpty else { continue }
            let first = l.first!
            if first != " " && first != "\t" {
                end = i
                break
            }
        }
        var itemIndent: String? = nil
        for i in (s + 1)..<end {
            let l = lines[i]
            let t = l.drop(while: { $0 == " " || $0 == "\t" })
            if t.hasPrefix("- ") || t == "-" {
                itemIndent = String(l.prefix(l.count - t.count))
                break
            }
        }
        return Section(start: s, end: end, itemIndent: itemIndent)
    }

    private struct Item {
        let range: Range<Int>
    }

    private func splitItems(lines: [String], section: Section) -> [Item] {
        var items: [Item] = []
        var current: Range<Int>? = nil
        for i in (section.start + 1)..<section.end {
            let l = lines[i]
            let t = l.drop(while: { $0 == " " || $0 == "\t" })
            let indent = String(l.prefix(l.count - t.count))
            if (t.hasPrefix("- ") || t == "-"), let base = section.itemIndent, indent == base {
                if let c = current { items.append(Item(range: c)) }
                current = i..<(i + 1)
            } else if current != nil {
                current = current!.lowerBound..<(i + 1)
            }
        }
        if let c = current { items.append(Item(range: c)) }
        return items
    }

    private func itemContainsAPIKey(_ item: Item, in lines: [String], key: String) -> Bool {
        for index in item.range {
            var line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("-") {
                line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            guard line.hasPrefix("api-key:") else { continue }
            let scalar = String(line.dropFirst("api-key:".count))
                .trimmingCharacters(in: .whitespaces)
            if decodeYAMLScalar(scalar) == key { return true }
        }
        return false
    }

    private func decodeYAMLScalar(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        if value.hasPrefix("\"") && value.hasSuffix("\"") {
            let inner = String(value.dropFirst().dropLast())
            return inner.replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        if value.hasPrefix("'") && value.hasSuffix("'") {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return value
    }

    private func yamlScalar(_ s: String) -> String {
        if s.range(of: #"^[A-Za-z0-9_\-./]+$"#, options: .regularExpression) != nil,
           !s.hasPrefix("-"), !s.isEmpty {
            return s
        }
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func atomicWrite(_ content: String) throws {
        let url = URL(fileURLWithPath: configPath)
        let bak = url.appendingPathExtension("keydrop-bak")
        try? FileManager.default.removeItem(at: bak)
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.copyItem(at: url, to: bak)
        }
        guard let data = content.data(using: .utf8) else {
            throw WriterError.file("CPA 配置无法编码为 UTF-8")
        }
        // 注意:禁止 rename/原子替换(config.yaml 可能被 Docker 单文件 bind mount,
        // inode 更换会导致容器内挂载断链,报 open ...: no such file or directory)。
        // 必须原地写入保持 inode;崩溃损坏可用 keydrop-bak 恢复。
        try data.write(to: url)
        // 写后校验 YAML;失败则回滚旧内容,避免损坏配置导致网关拒绝启动
        do {
            try Self.validateYAML(path: configPath)
        } catch {
            if let old = try? Data(contentsOf: bak) {
                try? old.write(to: url)
            }
            throw WriterError.file("CPA 配置 YAML 校验失败,已回滚: \(error.localizedDescription)")
        }
    }

    /// 用系统 python3(yaml) 校验配置:语法 + 重复键(Go yaml.v3 会拒绝重复键,容器拒启)
    private static func validateYAML(path: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-c",
            "import sys,yaml\n"
            + "def walk(n):\n"
            + "    if isinstance(n, yaml.MappingNode):\n"
            + "        seen = set()\n"
            + "        for k, v in n.value:\n"
            + "            key = k.value\n"
            + "            if key in seen:\n"
            + "                print(f'重复键 {key} (第 {k.start_mark.line+1} 行)', file=sys.stderr)\n"
            + "                sys.exit(1)\n"
            + "            seen.add(key)\n"
            + "            walk(v)\n"
            + "    elif isinstance(n, yaml.SequenceNode):\n"
            + "        for v in n.value: walk(v)\n"
            + "try:\n"
            + "    walk(yaml.compose(open(sys.argv[1])))\n"
            + "except Exception as e:\n"
            + "    print(e, file=sys.stderr)\n"
            + "    sys.exit(1)",
            path]
        let pipe = Pipe()
        p.standardError = pipe
        p.standardOutput = Pipe()
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let err = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "未知错误"
            throw WriterError.file(err.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
