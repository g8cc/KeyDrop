import Foundation

/// Writes OpenAI-compatible model entries understood by Grok Build.
///
/// Grok Build keeps custom models in `config.toml` as `[model.<id>]` tables.
/// Model ids are quoted so ids containing `/` or `.` remain a single TOML key.
public final class GrokBuildWriter {
    public let configPath: String

    public init(configPath: String? = nil) {
        self.configPath = configPath ?? Self.locateConfig()
    }

    public static func locateConfig() -> String {
        if let override = ProcessInfo.processInfo.environment["KEYDROP_GROK_CONFIG"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return override
        }
        let home = ProcessInfo.processInfo.environment["GROK_HOME"]
            ?? (NSHomeDirectory() + "/.grok")
        return (home as NSString).appendingPathComponent("config.toml")
    }

    public func add(baseURL: String, key: String, models: [String]) throws -> String {
        try sync(baseURL: baseURL, key: key, models: models, removing: [])
    }

    /// Upsert the selected models and remove stale models belonging to the same provider.
    public func sync(baseURL: String, key: String, models: [String], removing oldModels: [String]) throws -> String {
        let normalizedURL = normalizeURL(baseURL)
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = uniqueModels(models)
        guard !normalizedURL.isEmpty else { throw WriterError.file("Grok Build 缺少 base URL") }
        guard !normalizedKey.isEmpty else { throw WriterError.missingKey }
        guard !selected.isEmpty else { throw WriterError.file("Grok Build 没有可写入的模型") }

        return try FileLock.withLock(FileLock.lockPath(for: configPath)) {
            var lines = try readLines()
            let stale = uniqueModels(oldModels).filter { !selected.contains($0) }
            _ = removeModelSections(&lines, models: stale, baseURL: normalizedURL, key: normalizedKey)
            var namespaced = 0
            for model in selected {
                if upsertModel(&lines, model: model, baseURL: normalizedURL, key: normalizedKey) {
                    namespaced += 1
                }
            }
            try write(lines: lines)
            let coexist = namespaced > 0 ? ",\(namespaced) 个同名模型已加 #尾号 与既有 key 共存" : ""
            return "已写入 Grok Build(\(configPath)): \(selected.count) 个模型\(coexist)"
        }
    }

    public func remove(baseURL: String, key: String, models: [String]) throws -> String {
        let normalizedURL = normalizeURL(baseURL)
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedURL.isEmpty, !normalizedKey.isEmpty else {
            throw WriterError.file("Grok Build 删除缺少 base URL 或 key")
        }
        return try FileLock.withLock(FileLock.lockPath(for: configPath)) {
            var lines = try readLines()
            let removed = removeModelSections(
                &lines,
                models: uniqueModels(models),
                baseURL: normalizedURL,
                key: normalizedKey
            )
            if removed > 0 { try write(lines: lines) }
            return removed > 0
                ? "已从 Grok Build 移除 \(removed) 个模型"
                : "Grok Build 未找到匹配模型"
        }
    }

    private func uniqueModels(_ models: [String]) -> [String] {
        var seen = Set<String>()
        return models.compactMap { raw in
            let model = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty, seen.insert(model).inserted else { return nil }
            return model
        }
    }

    private func normalizeURL(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func readLines() throws -> [String] {
        guard FileManager.default.fileExists(atPath: configPath) else { return [] }
        let text = try String(contentsOfFile: configPath, encoding: .utf8)
        return text.components(separatedBy: "\n")
    }

    private func write(lines: [String]) throws {
        let url = URL(fileURLWithPath: configPath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: configPath) {
            let backup = url.appendingPathExtension("keydrop-bak")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: url, to: backup)
        }
        guard let data = lines.joined(separator: "\n").data(using: .utf8) else {
            throw WriterError.file("Grok Build 配置无法编码为 UTF-8")
        }
        try data.write(to: url, options: .atomic)
    }

    private func modelHeader(_ model: String) -> String {
        "[model.\(tomlString(model))]"
    }

    private func tomlString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(escaped)\""
    }

    private func decodeTomlString(_ value: String) -> String {
        let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 2, t.first == "\"", t.last == "\"" else { return t }
        let inner = String(t.dropFirst().dropLast())
        return inner
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\r", with: "\r")
    }

    private func modelID(from line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("[model."), t.hasSuffix("]") else { return nil }
        let raw = String(t.dropFirst("[model.".count).dropLast())
        guard !raw.isEmpty else { return nil }
        return decodeTomlString(raw)
    }

    /// 一个已解析的 `[model.*]` 段:内容身份 = model 字段 + base_url + api_key。
    /// 定位必须按内容而非 table id:同名模型被第二把 key 导入时 table id 会带
    /// `#尾号` 后缀共存,按 id 找会漏;按内容找则写/删都精确到自己的凭据
    private struct ModelSection {
        let range: Range<Int>
        let id: String        // table key 原文(可能带 #尾号)
        let model: String     // `model = ` 字段(上游模型名)
        let baseURL: String?
        let apiKey: String?
    }

    private func scanModelSections(in lines: [String]) -> [ModelSection] {
        var out: [ModelSection] = []
        var i = 0
        while i < lines.count {
            guard let id = modelID(from: lines[i]) else { i += 1; continue }
            var end = lines.count
            for j in (i + 1)..<lines.count {
                let t = lines[j].trimmingCharacters(in: .whitespacesAndNewlines)
                if t.hasPrefix("[") && t.hasSuffix("]") { end = j; break }
            }
            var model = id
            var baseURL: String?
            var apiKey: String?
            for line in lines[(i + 1)..<end] {
                let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
                for field in ["model", "base_url", "api_key"] {
                    guard t.hasPrefix(field) else { continue }
                    let rest = t.dropFirst(field.count).trimmingCharacters(in: .whitespaces)
                    guard rest.first == "=" else { continue }
                    let value = decodeTomlString(String(rest.dropFirst()))
                    if field == "model" { model = value }
                    else if field == "base_url" { baseURL = value }
                    else { apiKey = value }
                }
            }
            out.append(ModelSection(range: i..<end, id: id, model: model, baseURL: baseURL, apiKey: apiKey))
            i = end
        }
        return out
    }

    /// 同模型同 key → 原地更新(base_url 修正也走这里);
    /// 同模型不同 key → 新 table id 用「模型#key尾4」共存,绝不覆盖他人凭据。
    /// 返回 true 表示本次因冲突启用了后缀 id
    @discardableResult
    private func upsertModel(_ lines: inout [String], model: String, baseURL: String, key: String) -> Bool {
        let values: [(String, String)] = [
            ("model", model),
            ("base_url", baseURL),
            ("api_key", key),
            ("name", model),
            ("api_backend", "chat_completions")
        ]
        let sections = scanModelSections(in: lines)
        if let own = sections.first(where: { $0.model == model && $0.apiKey == key }) {
            var block = Array(lines[own.range])
            for (name, value) in values { upsertKey(&block, name: name, value: value) }
            lines.replaceSubrange(own.range, with: block)
            return false
        }
        var newID = model
        let ids = Set(sections.map(\.id))
        var namespaced = false
        if ids.contains(newID) {
            namespaced = true
            var candidate = "\(model)#\(key.suffix(4))"
            var n = 2
            while ids.contains(candidate) {
                candidate = "\(model)#\(key.suffix(4))-\(n)"
                n += 1
            }
            newID = candidate
        }
        if let last = lines.last, !last.isEmpty { lines.append("") }
        lines.append(modelHeader(newID))
        for (name, value) in values {
            lines.append("\(name) = \(tomlString(value))")
        }
        return namespaced
    }

    private func upsertKey(_ block: inout [String], name: String, value: String) {
        let prefix = "\(name)"
        if let index = block.firstIndex(where: { line in
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.hasPrefix(prefix) else { return false }
            let rest = t.dropFirst(prefix.count)
            return rest.first == "=" || rest.first == " " || rest.first == "\t"
        }) {
            let indent = String(block[index].prefix { $0 == " " || $0 == "\t" })
            block[index] = "\(indent)\(name) = \(tomlString(value))"
        } else {
            block.append("\(name) = \(tomlString(value))")
        }
    }

    /// 删除条件 = model 字段命中 ∧ api_key 相同 ∧ base_url 相同。
    /// 按 table id 删除在「#尾号共存」后会漏删/误删,必须按内容
    private func removeModelSections(
        _ lines: inout [String],
        models: [String],
        baseURL: String,
        key: String
    ) -> Int {
        let targets = Set(models)
        let ranges = scanModelSections(in: lines)
            .filter { targets.contains($0.model) && $0.apiKey == key && normalizeURL($0.baseURL ?? "") == baseURL }
            .map(\.range)
        for range in ranges.sorted(by: { $0.lowerBound > $1.lowerBound }) {
            lines.removeSubrange(range)
        }
        return ranges.count
    }
}
