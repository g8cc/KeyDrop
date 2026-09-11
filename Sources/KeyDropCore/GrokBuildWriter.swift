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
            for model in selected {
                upsertModel(&lines, model: model, baseURL: normalizedURL, key: normalizedKey)
            }
            try write(lines: lines)
            return "已写入 Grok Build(\(configPath)): \(selected.count) 个模型"
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

    private func sectionRange(in lines: [String], model: String) -> Range<Int>? {
        guard let start = lines.firstIndex(where: { modelID(from: $0) == model }) else { return nil }
        var end = lines.count
        for i in (start + 1)..<lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasPrefix("[") && t.hasSuffix("]") {
                end = i
                break
            }
        }
        return start..<end
    }

    private func upsertModel(_ lines: inout [String], model: String, baseURL: String, key: String) {
        let values: [(String, String)] = [
            ("model", model),
            ("base_url", baseURL),
            ("api_key", key),
            ("name", model),
            ("api_backend", "chat_completions")
        ]
        if let range = sectionRange(in: lines, model: model) {
            var block = Array(lines[range])
            for (name, value) in values { upsertKey(&block, name: name, value: value) }
            lines.replaceSubrange(range, with: block)
        } else {
            if let last = lines.last, !last.isEmpty { lines.append("") }
            lines.append(modelHeader(model))
            for (name, value) in values {
                lines.append("\(name) = \(tomlString(value))")
            }
        }
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

    private func removeModelSections(
        _ lines: inout [String],
        models: [String],
        baseURL: String,
        key: String
    ) -> Int {
        var ranges: [Range<Int>] = []
        for model in models {
            guard let range = sectionRange(in: lines, model: model),
                  sectionMatches(lines, range: range, baseURL: baseURL, key: key) else { continue }
            ranges.append(range)
        }
        for range in ranges.sorted(by: { $0.lowerBound > $1.lowerBound }) {
            lines.removeSubrange(range)
        }
        return ranges.count
    }

    private func sectionMatches(_ lines: [String], range: Range<Int>, baseURL: String, key: String) -> Bool {
        var foundURL: String?
        var foundKey: String?
        for line in lines[range] {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            for field in ["base_url", "api_key"] {
                let prefix = "\(field)"
                guard t.hasPrefix(prefix) else { continue }
                let rest = t.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                guard rest.first == "=" else { continue }
                let value = decodeTomlString(String(rest.dropFirst()))
                if field == "base_url" { foundURL = value }
                else { foundKey = value }
            }
        }
        return foundKey == key && normalizeURL(foundURL ?? "") == baseURL
    }
}
