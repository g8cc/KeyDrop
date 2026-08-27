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

    /// 多 key 写聚合条目到 `openai-compatibility:` 段下,同 baseURL 的 key 归一组,
    /// 共享一组 models 列表。CPA 加载后会在此组内轮询所有 api-key。
    /// 模型列表自动探测:探测失败写入空 models 段,后续可手动刷新。
    func addMulti(baseURL: String, keys: [String], proxy: String? = nil) throws -> String {
        guard !keys.isEmpty else {
            throw WriterError.file("addMulti 收到空 keys 列表")
        }
        try Self.validateYAML(path: configPath)
        let content = try String(contentsOfFile: configPath, encoding: .utf8)
        var lines = content.components(separatedBy: "\n")
        let providerName = aggregatedName(for: baseURL)

        // 探测模型列表(失败不阻断,写入空 models 段供后续刷新)
        var models: [String] = []
        if let firstKey = keys.first {
            let test = APITester.test(url: baseURL, key: firstKey, proxy: proxy)
            if test.ok { models = test.models.filter { Parser.looksLikeModel($0) } }
        }

        // 定位 openai-compatibility 段下同 name 的现有条目
        if let entryRange = findAggregatedEntry(in: lines, providerName: providerName) {
            // 已有同 name 条目:合并新 key 进 api-key-entries,合并 models
            try mergeIntoAggregatedEntry(&lines, range: entryRange, keys: keys, models: models)
        } else {
            // 新建条目
            try appendAggregatedEntry(&lines, providerName: providerName, baseURL: baseURL,
                                      keys: keys, models: models, proxy: proxy)
        }
        try atomicWrite(lines.joined(separator: "\n"))
        let modelPart = models.isEmpty ? "" : ", 探测到 \(models.count) 个模型"
        return "已写入 \(keys.count) 个 key 到 CPA 聚合条目「\(providerName)」\(modelPart)"
    }

    /// 聚合条目 name 取 baseURL 主机名(去端口);失败回退完整 URL
    private func aggregatedName(for baseURL: String) -> String {
        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let host = URL(string: trimmed)?.host ?? URL(string: "https://\(trimmed)")?.host,
           !host.isEmpty {
            return host
        }
        return trimmed
    }

    /// 找 `openai-compatibility:` 段下指定 name 的条目范围(从 `- name: X` 行到下一个 `- name:` 行或段尾)
    private func findAggregatedEntry(in lines: [String], providerName: String) -> Range<Int>? {
        guard let section = findNamedSection(in: lines, key: "openai-compatibility:") else { return nil }
        var idx = section.start
        while idx < section.end {
            let l = lines[idx]
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("- name:") || t == "-" || t.hasPrefix("- ") {
                // 进入一个条目:取该条目起始行
                let entryStart = idx
                // 条目 name 行匹配?
                let nameOnLine = t.hasPrefix("- name:")
                    ? stripYAMLValue(String(t.dropFirst("- name:".count))).trimmingCharacters(in: .whitespaces)
                    : nil
                // 扫到下一个 `- name:` 或段尾
                var j = idx + 1
                while j < section.end {
                    let lt = lines[j].trimmingCharacters(in: .whitespaces)
                    if lt.hasPrefix("- name:") || lt == "-" { break }
                    j += 1
                }
                if nameOnLine == providerName {
                    return entryStart..<j
                }
                idx = j
            } else {
                idx += 1
            }
        }
        return nil
    }

    private func stripYAMLValue(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.count >= 2 {
            if t.hasPrefix("\"") && t.hasSuffix("\"") {
                return String(t.dropFirst().dropLast())
            }
            if t.hasPrefix("'") && t.hasSuffix("'") {
                return String(t.dropFirst().dropLast())
            }
        }
        return t
    }

    private func addSingle(key: String?, url: String?, model: String?, proxy: String? = nil) throws {        guard let key, !key.isEmpty, let url, !url.isEmpty else { throw WriterError.missingURL }
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

    // MARK: - aggregated write helpers

    /// 合并 keys 和 models 进现有聚合条目;keys 去重(已有的跳过),models 同样
    private func mergeIntoAggregatedEntry(_ lines: inout [String], range: Range<Int>, keys: [String], models: [String]) throws {
        // 提取已有 keys
        var existingKeys = Set<String>()
        if let entriesRange = findAPIKeyEntriesSubrange(in: lines, entryRange: range) {
            for i in entriesRange {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("- api-key:") {
                    let scalar = String(t.dropFirst("- api-key:".count)).trimmingCharacters(in: .whitespaces)
                    existingKeys.insert(decodeYAMLScalar(scalar))
                }
            }
        }
        let newKeys = keys.filter { !existingKeys.contains($0) }
        guard !newKeys.isEmpty || !models.isEmpty else { return }

        // 在 api-key-entries 末尾追加新 key
        if !newKeys.isEmpty,
           let entriesRange = findAPIKeyEntriesSubrange(in: lines, entryRange: range) {
            // 计算 entries 缩进(从首行推断)
            let indent: String = {
                if entriesRange.isEmpty { return "      " }
                let firstLine = lines[entriesRange.lowerBound]
                let pre = firstLine.prefix(while: { $0 == " " || $0 == "\t" })
                return String(pre)
            }()
            // 插入位置:entries 段尾部前一行(跳过空行)
            var insertAt = entriesRange.upperBound
            while insertAt > entriesRange.lowerBound, lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                insertAt -= 1
            }
            let block = newKeys.map { "\(indent)- api-key: \(yamlScalar($0))" }
            lines.insert(contentsOf: block, at: insertAt)
        }

        // models 合并:找到现有 models 段追加,或新建
        if !models.isEmpty {
            try mergeAggregatedModels(&lines, entryRange: range, newModels: models)
        }
    }

    /// 在聚合条目范围内合并 models(去重)
    private func mergeAggregatedModels(_ lines: inout [String], entryRange: Range<Int>, newModels: [String]) throws {
        // 找现有 `models:` 段位置
        var modelsHeader: Int? = nil
        for i in entryRange {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("models:") { modelsHeader = i; break }
        }
        var existing = Set<String>()
        if let header = modelsHeader {
            let headerIndent = lines[header].prefix(while: { $0 == " " || $0 == "\t" }).count
            var modelItemIndent = ""
            var endModels = entryRange.upperBound
            for j in (header + 1)..<entryRange.upperBound {
                let line = lines[j]
                let curIndent = line.prefix(while: { $0 == " " || $0 == "\t" }).count
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && curIndent <= headerIndent { endModels = j; break }
                if trimmed.hasPrefix("- name:") {
                    if modelItemIndent.isEmpty { modelItemIndent = String(line.prefix(curIndent)) }
                    let nm = stripYAMLValue(String(trimmed.dropFirst("- name:".count)))
                    existing.insert(nm.trimmingCharacters(in: .whitespaces))
                }
            }
            let toAdd = newModels.filter { !existing.contains($0) }
            if toAdd.isEmpty { return }
            let indent = modelItemIndent.isEmpty ? String(repeating: " ", count: headerIndent + 2) : modelItemIndent
            var insertAt = endModels
            while insertAt > header + 1, lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty { insertAt -= 1 }
            let block = toAdd.flatMap { ["\(indent)- name: \(yamlScalar($0))", "\(indent)  alias: \(yamlScalar($0))"] }
            lines.insert(contentsOf: block, at: insertAt)
        } else {
            // 条目无 models 段:在条目末尾(去空行后)追加
            let headerIndent: Int = {
                let firstLine = lines[entryRange.lowerBound]
                return firstLine.prefix(while: { $0 == " " || $0 == "\t" }).count
            }()
            let propIndent = String(repeating: " ", count: headerIndent + 2)
            var insertAt = entryRange.upperBound
            while insertAt > entryRange.lowerBound + 1, lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty { insertAt -= 1 }
            var block: [String] = ["\(propIndent)models:"]
            for m in newModels {
                block.append("\(propIndent)  - name: \(yamlScalar(m))")
                block.append("\(propIndent)    alias: \(yamlScalar(m))")
            }
            lines.insert(contentsOf: block, at: insertAt)
        }
    }

    /// 追加全新聚合条目到 `openai-compatibility:` 段末尾;段不存在则创建
    private func appendAggregatedEntry(_ lines: inout [String], providerName: String, baseURL: String,
                                       keys: [String], models: [String], proxy: String?) throws {
        // 段不存在时新建
        guard let section = findNamedSection(in: lines, key: "openai-compatibility:") else {
            if let last = lines.last, !last.isEmpty { lines.append("") }
            lines.append("openai-compatibility:")
            let entryIndent = "  "
            lines.append(contentsOf: aggregatedEntryLines(indent: entryIndent, name: providerName, baseURL: baseURL,
                                                          keys: keys, models: models, proxy: proxy))
            return
        }
        // 段末尾追加(跳过末尾空行)
        var insertAt = section.end
        while insertAt > section.start + 1, lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty { insertAt -= 1 }
        // 缩进从现有条目推断
        let existingIndent: String = {
            for i in (section.start + 1)..<section.end {
                let l = lines[i]
                let t = l.drop(while: { $0 == " " || $0 == "\t" })
                if t.hasPrefix("- name:") || t == "-" {
                    return String(l.prefix(l.count - t.count))
                }
            }
            return "  "
        }()
        lines.insert(contentsOf: aggregatedEntryLines(indent: existingIndent, name: providerName, baseURL: baseURL,
                                                      keys: keys, models: models, proxy: proxy), at: insertAt)
    }

    /// 生成一个聚合条目所有行
    private func aggregatedEntryLines(indent: String, name: String, baseURL: String,
                                       keys: [String], models: [String], proxy: String?) -> [String] {
        var out: [String] = []
        out.append("\(indent)- name: \(yamlScalar(name))")
        out.append("\(indent)  base-url: \(yamlScalar(baseURL))")
        if let proxy, !proxy.isEmpty {
            out.append("\(indent)  proxy-url: \(yamlScalar(proxy))")
        }
        out.append("\(indent)  api-key-entries:")
        for k in keys { out.append("\(indent)    - api-key: \(yamlScalar(k))") }
        if !models.isEmpty {
            out.append("\(indent)  models:")
            for m in models {
                out.append("\(indent)    - name: \(yamlScalar(m))")
                out.append("\(indent)      alias: \(yamlScalar(m))")
            }
        }
        return out
    }

    // MARK: - remove

    /// 删除 keys:同时清理 `claude-api-key:` 平铺段和 `openai-compatibility:` 聚合段。
    /// 平铺段命中 → 删整条目;聚合段命中 → 删单个 api-key 子项,删空则整条目移除。
    func remove(apiKeys: [String]) throws -> String {
        guard FileManager.default.fileExists(atPath: configPath) else {
            return "CPA config 不存在,跳过"
        }
        try Self.validateYAML(path: configPath)
        let content = try String(contentsOfFile: configPath, encoding: .utf8)
        var lines = content.components(separatedBy: "\n")
        var removed = 0
        var pending = Set(apiKeys)

        // 多轮扫描:删一行后行号变化,重新扫直到无命中
        var changed = true
        while changed {
            changed = false
            // 1. claude-api-key 平铺段
            if let section = findSection(in: lines) {
                let items = splitItems(lines: lines, section: section)
                for item in items {
                    let hitKey = pending.first { itemContainsAPIKey(item, in: lines, key: $0) }
                    guard let k = hitKey else { continue }
                    var newSectionLines: [String] = [lines[section.start]]
                    var emitted = Set<Int>()
                    for it in items where it.range.lowerBound != item.range.lowerBound {
                        for i in it.range { newSectionLines.append(lines[i]); emitted.insert(i) }
                    }
                    for i in (section.start + 1)..<section.end where !emitted.contains(i) {
                        let l = lines[i]
                        if l.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || l.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
                            newSectionLines.append(l)
                        }
                    }
                    if newSectionLines.count == 1 {
                        lines.removeSubrange(section.start..<section.end)
                    } else {
                        lines.replaceSubrange(section.start..<section.end, with: newSectionLines)
                    }
                    pending.remove(k)
                    removed += 1
                    changed = true
                    break
                }
            }
            if changed { continue }
            // 2. openai-compatibility 聚合段:定位条目→api-key-entries→删命中行
            if let section = findNamedSection(in: lines, key: "openai-compatibility:") {
                let entries = aggregatedEntries(in: lines, section: section)
                for entry in entries {
                    guard let entriesRange = findAPIKeyEntriesSubrange(in: lines, entryRange: entry.range),
                          let hitLine = findAPIKeyLine(in: lines, range: entriesRange, keys: Array(pending)) else { continue }
                    // 找到的具体 key 用于扣减计数
                    let t = lines[hitLine].trimmingCharacters(in: .whitespaces)
                    let scalar = String(t.dropFirst("- api-key:".count)).trimmingCharacters(in: .whitespaces)
                    let matchedKey = decodeYAMLScalar(scalar)
                    let remainingInEntry = (entriesRange.lowerBound..<entriesRange.upperBound).filter { $0 != hitLine }.count
                    if remainingInEntry == 0 {
                        // 整条目移除
                        lines.removeSubrange(entry.range)
                    } else {
                        lines.remove(at: hitLine)
                    }
                    if pending.contains(matchedKey) { pending.remove(matchedKey); removed += 1 }
                    changed = true
                    break
                }
            }
        }
        if removed == 0 { return "未在 CPA 配置中找到 \(pending.count) 个 key" }
        try atomicWrite(lines.joined(separator: "\n"))
        return pending.isEmpty
            ? "已从 CPA 配置移除 \(removed) 个 key"
            : "已从 CPA 配置移除 \(removed) 个 key,余 \(pending.count) 个未找到"
    }

    func remove(apiKey: String) throws -> String {
        try remove(apiKeys: [apiKey])
    }

    /// 在 openai-compatibility 段下枚举所有条目范围(每个 `- name:` 开头为一组)
    private func aggregatedEntries(in lines: [String], section: Section) -> [Item] {
        var items: [Item] = []
        var current: Range<Int>? = nil
        for i in section.start..<section.end {
            let l = lines[i]
            let t = l.drop(while: { $0 == " " || $0 == "\t" })
            let indent = String(l.prefix(l.count - t.count))
            if (t.hasPrefix("- name:") || t == "-") && !indent.hasPrefix("    ") {
                if let c = current { items.append(Item(range: c)) }
                current = i..<(i + 1)
            } else if current != nil {
                current = current!.lowerBound..<(i + 1)
            }
        }
        if let c = current { items.append(Item(range: c)) }
        return items
    }

    /// 聚合条目范围内找 `api-key-entries:` 子段下的 `- api-key:` 行范围
    private func findAPIKeyEntriesSubrange(in lines: [String], entryRange: Range<Int>) -> Range<Int>? {
        var entriesHeader: Int? = nil
        for i in entryRange {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("api-key-entries:") {
                entriesHeader = i
                break
            }
        }
        guard let header = entriesHeader else { return nil }
        let headerIndent = lines[header].prefix(while: { $0 == " " || $0 == "\t" }).count
        var end = entryRange.upperBound
        for j in (header + 1)..<entryRange.upperBound {
            let line = lines[j]
            let curIndent = line.prefix(while: { $0 == " " || $0 == "\t" }).count
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && curIndent <= headerIndent {
                end = j
                break
            }
        }
        return (header + 1)..<end
    }

    private func findAPIKeyLine(in lines: [String], range: Range<Int>, keys: [String]) -> Int? {
        for i in range {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("- api-key:") else { continue }
            let scalar = String(t.dropFirst("- api-key:".count)).trimmingCharacters(in: .whitespaces)
            let decoded = decodeYAMLScalar(scalar)
            if keys.contains(decoded) { return i }
        }
        return nil
    }

    /// 找任意顶层命名段(如 `openai-compatibility:`),返回段范围
    private func findNamedSection(in lines: [String], key: String) -> Section? {
        var start: Int? = nil
        for (i, l) in lines.enumerated() {
            if !l.hasPrefix(" ") && !l.hasPrefix("\t") && l.trimmingCharacters(in: .whitespaces) == key {
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
        return Section(start: s, end: end, itemIndent: nil)
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
            let bakPath = url.appendingPathExtension("keydrop-bak").path
            var rollbackFailed = false
            if let old = try? Data(contentsOf: URL(fileURLWithPath: bakPath)) {
                do { try old.write(to: url) }
                catch { rollbackFailed = true }
            }
            let suffix = rollbackFailed
                ? "。⚠ 回滚也失败,请手动用备份恢复: \(bakPath)"
                : "(备份: \(bakPath))"
            throw WriterError.file("CPA 配置 YAML 校验失败,已回滚: \(error.localizedDescription)\(suffix)")
        }
    }

    private static let validatorLock = NSLock()
    private static var validatorState = 0  // 0=未探测 1=可用 2=不可用

    /// python3/PyYAML 缺失 → 校验器不可用。这只意味着「无法校验」而非「YAML 非法」,
    /// 此时放行写入,避免无 PyYAML 的机器上 CPA 功能整体瘫痪。
    private static func yamlValidatorAvailable() -> Bool {
        validatorLock.lock(); defer { validatorLock.unlock() }
        if validatorState != 0 { return validatorState == 1 }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-c", "import yaml"]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            validatorState = p.terminationStatus == 0 ? 1 : 2
        } catch {
            validatorState = 2
        }
        return validatorState == 1
    }

    private static func markValidatorUnavailable() {
        validatorLock.lock()
        validatorState = 2
        validatorLock.unlock()
    }

    /// 用系统 python3(yaml) 校验配置:语法 + 重复键(Go yaml.v3 会拒绝重复键,容器拒启)
    private static func validateYAML(path: String) throws {
        guard yamlValidatorAvailable() else {
            Logger.warn("CPA YAML 校验器不可用(缺 python3/PyYAML),已跳过校验")
            return
        }
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
        // 先读完再等退出:输出超过管道缓冲时,先 wait 会导致子进程写阻塞而死锁
        let errData = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus != 0 else { return }
        let err = String(data: errData, encoding: .utf8) ?? "未知错误"
        // 运行中途才暴露的 import 失败按「校验器不可用」处理,不误判为 YAML 非法
        if err.contains("No module named") || err.contains("ImportError") || err.contains("ModuleNotFoundError") {
            markValidatorUnavailable()
            Logger.warn("CPA YAML 校验器不可用(缺 PyYAML),已跳过校验")
            return
        }
        throw WriterError.file(err.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
