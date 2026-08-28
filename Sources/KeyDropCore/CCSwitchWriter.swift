import Foundation
import AppKit

public struct CCAddResult {
    public let providerID: String
    public let providerName: String
    var renamedFrom: String? = nil
    var renamedTo: String? = nil
    var directMode = false
    var proxyMode = false
    public var warnings: [String] = []
}

enum WriterError: LocalizedError {
    case missingURL
    case missingKey
    case file(String)
    case json(String)

    var errorDescription: String? {
        switch self {
        case .missingURL: return ParseError.noURL.localizedDescription
        case .missingKey: return "缺少 API key"
        case .file(let s): return s
        case .json(let s): return "JSON 处理失败: \(s)"
        }
    }
}

public final class CCSwitchWriter {
    public init() {}

    public static var dbPath: String {
        ProcessInfo.processInfo.environment["KEYDROP_CC_DB"]
            ?? (NSHomeDirectory() + "/.cc-switch/cc-switch.db")
    }
    public static var switchSettingsPath: String {
        ProcessInfo.processInfo.environment["KEYDROP_CC_SETTINGS"]
            ?? (NSHomeDirectory() + "/.cc-switch/settings.json")
    }
    static public var claudeSettingsPath: String {
        ProcessInfo.processInfo.environment["KEYDROP_CLAUDE_SETTINGS"]
            ?? (NSHomeDirectory() + "/.claude/settings.json")
    }
    static var codexConfigPath: String {
        ProcessInfo.processInfo.environment["KEYDROP_CODEX_CONFIG"]
            ?? (NSHomeDirectory() + "/.codex/config.toml")
    }
    static var codexAuthPath: String {
        ProcessInfo.processInfo.environment["KEYDROP_CODEX_AUTH"]
            ?? (NSHomeDirectory() + "/.codex/auth.json")
    }

    // MARK: - add

    public func add(_ p: ParsedKey, nameOverride: String? = nil, appType: String = "claude", models: [String] = [], proxy: String? = nil) throws -> CCAddResult {
        guard let key = p.key, !key.isEmpty else { throw WriterError.missingKey }
        guard let url = p.url, !url.isEmpty else { throw WriterError.missingURL }
        try Self.ensureDB()

        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let id = UUID().uuidString.lowercased()
        let name = (nameOverride?.isEmpty == false ? nameOverride! : p.name) ?? defaultName(for: url)
        let wireApi = "responses"
        let fakeRunning = ProcessInfo.processInfo.environment["KEYDROP_FAKE_CC_RUNNING"] == "1"
        let supportsResponses = appType == "codex" && !fakeRunning
            ? APITester.supportsResponsesAPI(base: url, key: key, proxy: proxy) : true
        let apiFormat = supportsResponses ? "openai_responses" : "openai_chat"
        let meta = appType == "codex"
            ? "{\"commonConfigEnabled\":false,\"endpointAutoSelect\":true,\"apiFormat\":\"\(apiFormat)\"}"
            : "{}"

        // opencode 双写(DB settings_config + opencode.json)必须共用同一份 modelDict,
        // 否则两路随机后缀会 drift。firstModel 保留用户传入顺序优先级。
        let opencodeModels = models.isEmpty ? (p.model.map { [$0] } ?? []) : models
        let opencodeDict = opencodeModelDict(providerID: id, baseURL: url, models: opencodeModels)

        let settingsConfig: String
        if appType == "opencode" {
            settingsConfig = try opencodeSettingsConfig(p, modelDict: opencodeDict)
        } else if appType == "codex" {
            settingsConfig = try codexSettingsConfig(p, models: models, wireApi: wireApi)
        } else {
            settingsConfig = try claudeSettingsConfig(p, models: models, proxy: proxy)
        }

        let diskCurrent = readSwitchSettings()?[currentKey(appType)] as? String
        let appRunning = Self.ccSwitchRunning()

        let db = try DB(path: Self.dbPath)
        try db.exec("BEGIN IMMEDIATE")
        var dedupReplacedID: String? = nil
        do {
            if appType == "opencode" || appType == "codex" {
                let normURL = appType == "opencode" ? opencodeBaseURL(url) : normalizeEndpointURL(url)
                // endpoint url 可能带或不带 /v1/尾部斜杠,规范化后比较
                let candidates = try db.query(
                    "SELECT p.id, e.url FROM providers p JOIN provider_endpoints e ON p.id=e.provider_id WHERE p.app_type=?",
                    [appType]
                )
                let existing = candidates.first { row in
                    guard row.count > 1, let u = row[1] else { return false }
                    return normalizeEndpointURL(u) == normURL
                }
                if let id = existing?[0] {
                    try db.run("DELETE FROM provider_endpoints WHERE provider_id=?", [id])
                    try db.run("DELETE FROM providers WHERE id=?", [id])
                    dedupReplacedID = id
                }
            }
            try db.run(
                """
                INSERT INTO providers
                (id, app_type, name, settings_config, website_url, category,
                 created_at, sort_index, notes, icon, icon_color, meta, is_current, in_failover_queue)
                VALUES (?, ?, ?, ?, NULL, NULL, ?, NULL, NULL, NULL, NULL, ?, 1, 0)
                """,
                [id, appType, name, settingsConfig, now, meta]
            )
            try db.run("UPDATE providers SET is_current = 0 WHERE app_type = ? AND id != ?", [appType, id])
            try db.run(
                "INSERT INTO provider_endpoints (provider_id, app_type, url, added_at) VALUES (?, ?, ?, ?)",
                [id, appType, appType == "opencode" ? opencodeBaseURL(url) : url, now]
            )

            // 历史 bug 修复:不再 mutate 旧 provider 的 id 主键。
            // 旧实现把上一个 current 的 id 改成随机 UUID,意图是「retired 暂存 + 删除新 provider 时还原」,
            // 但 cc-switch 是独立进程、内存里缓存旧 id,看到 id 突变会认知错位(写回 DB 时或外键错乱)。
            // 新方案:仅靠 is_current=0 表达「非激活」,删除新 provider 时用「最近创建的同 app_type provider」兜底恢复。
            // CCAddResult.renamedFrom / renamedTo 保留字段(二进制兼容),值永远为 nil。
            let renamedFrom: String? = nil
            let renamedTo: String? = nil
            try db.exec("COMMIT")

            // opencode.json 是共享文件:被去重替换的旧 provider 条目要同步移除,避免孤儿
            if appType == "opencode", let old = dedupReplacedID {
                do { try clearOpencodeProvider(id: old) }
                catch { AppLog.warn("opencode.json 旧 provider 清理失败: \(error.localizedDescription)") }
            }

            var result = CCAddResult(providerID: id, providerName: name)
            if appType == "codex" && !supportsResponses {
                result.warnings.append("该网关不支持 Responses API(codex 新版仅支持 responses 格式),codex 可能无法使用;建议将同 key 导入到 opencode")
            }
            result.renamedFrom = renamedFrom
            result.renamedTo = renamedTo

            do {
                try updateSwitchSettings(id, for: appType)
            } catch {
                result.warnings.append("switch settings 更新失败: \(error.localizedDescription)")
            }

            if appType == "opencode" {
                do {
                    try mergeOpencodeProvider(p, providerID: id, modelDict: opencodeDict, firstModel: opencodeModels.first)
                    result.directMode = true
                } catch {
                    result.warnings.append("opencode.json 更新失败: \(error.localizedDescription)")
                }
                return result
            }

            if appType == "codex" {
                let proxied = (try? String(contentsOfFile: Self.codexConfigPath, encoding: .utf8))
                    .flatMap { c -> Bool in
                        let custom = c.components(separatedBy: "[model_providers.custom]").dropFirst().first ?? ""
                        return custom.contains("PROXY_MANAGED") || custom.contains("127.0.0.1:15721")
                    } ?? false
                if proxied {
                    // cc-switch 接管中:不直写 config.toml,仅 DB + switch settings 由 cc-switch 应用
                    // (base_url 必须保持指向本地代理,转换链路才生效)
                    result.proxyMode = true
                } else {
                    do {
                        try mergeCodexConfig(p, models: models)
                        result.directMode = true
                    } catch {
                        result.warnings.append("codex config.toml 更新失败: \(error.localizedDescription)")
                    }
                }
                return result
            }

            if let claude = readClaudeSettings() {
                let token = ((claude["env"] as? [String: Any])?["ANTHROPIC_AUTH_TOKEN"] as? String) ?? ""
                if token != "PROXY_MANAGED" {
                    do {
try mergeEnvIntoClaudeSettings(claudeEnv(for: p, models: models, proxy: proxy))
                        result.directMode = true
                    } catch {
                        result.warnings.append("Claude settings 更新失败: \(error.localizedDescription)")
                    }
                } else {
                    result.proxyMode = true
                }
            } else if !FileManager.default.fileExists(atPath: Self.claudeSettingsPath) {
                do {
                    try mergeEnvIntoClaudeSettings(claudeEnv(for: p, models: models, proxy: proxy))
                    result.directMode = true
                } catch {
                    result.warnings.append("Claude settings 写入失败: \(error.localizedDescription)")
                }
            } else {
                result.warnings.append("Claude settings 不是有效 JSON,为避免覆盖未修改")
            }
            return result
        } catch {
            try? db.exec("ROLLBACK")
            throw error
        }
    }

    // MARK: - app type helpers

    static func supportedAppTypes() -> [String] { ["claude", "opencode", "codex"] }

    private func currentKey(_ appType: String) -> String {
        "currentProvider" + appType.prefix(1).uppercased() + appType.dropFirst()
    }

    private func claudeEnv(for p: ParsedKey, models: [String], proxy: String? = nil) -> [String: String] {
        var env: [String: String] = [
            "ANTHROPIC_AUTH_TOKEN": p.key ?? "",
            "ANTHROPIC_BASE_URL": p.url ?? ""
        ]
        if let proxy, !proxy.isEmpty {
            env["HTTPS_PROXY"] = proxy
            env["HTTP_PROXY"] = proxy
        }
        if let model = models.first(where: { !$0.isEmpty }) ?? (p.model?.isEmpty == false ? p.model : nil) {
            let modelKeys = [
                "ANTHROPIC_MODEL", "ANTHROPIC_REASONING_MODEL",
                "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL_NAME",
                "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL_NAME",
                "ANTHROPIC_DEFAULT_HAIKU_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME",
                "ANTHROPIC_DEFAULT_FABLE_MODEL", "ANTHROPIC_DEFAULT_FABLE_MODEL_NAME",
                "CLAUDE_CODE_SUBAGENT_MODEL"
            ]
            for k in modelKeys { env[k] = model }
        }
        return env
    }

    private func claudeSettingsConfig(_ p: ParsedKey, models: [String], proxy: String? = nil) throws -> String {
        try jsonString(["env": claudeEnv(for: p, models: models, proxy: proxy)])
    }

    /// 计算 opencode 模型显示名的权威映射(modelKey -> {"name": displayName})。
    /// cc-switch DB settings_config 与 opencode.json 两个写入路径必须共用同一份映射,
    /// 否则各自随机后缀必然 drift(https://... 例:DB 里 3BEFE594 / opencode.json 里 FA4FEB90)。
    /// 优先级:opencode.json 现有同名条目(保留用户已复制的名字)> 新随机后缀。
    /// 匹配顺序:同 providerID > 同 baseURL(去重重建换 ID 时旧条目仍在 opencode.json)> 旧版聚合键 KeyDrop。
    /// 调用方:add() / repairMissingProvider() / syncModelsAfterRefresh() 必须只算一次,把结果传给两个 writer。
    func opencodeModelDict(providerID: String, baseURL: String?, models: [String]) -> [String: Any] {
        var existing: [String: String] = [:]
        let normalizedTarget = baseURL.map { opencodeBaseURL($0) }
        if let data = try? Data(contentsOf: URL(fileURLWithPath: Self.opencodeConfigPath)),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let providers = obj["provider"] as? [String: Any] {
            // 三路命中:精确 providerID(3)> 同 baseURL(2)> 旧版 KeyDrop 聚合键(1);高 level 先填
            let levelOf: (String, Any) -> Int = { key, raw in
                if key == providerID { return 3 }
                if let target = normalizedTarget,
                   let pd = raw as? [String: Any],
                   let opts = pd["options"] as? [String: Any],
                   let base = opts["baseURL"] as? String,
                   base == target { return 2 }
                if key == "KeyDrop" { return 1 }
                return 0
            }
            let sorted = providers.sorted { levelOf($0.key, $0.value) > levelOf($1.key, $1.value) }
            for (key, raw) in sorted {
                guard levelOf(key, raw) > 0,
                      let pd = raw as? [String: Any],
                      let ms = pd["models"] as? [String: Any] else { continue }
                for (mk, mv) in ms {
                    if let name = (mv as? [String: Any])?["name"] as? String, !name.isEmpty,
                       existing[mk] == nil {
                        existing[mk] = name
                    }
                }
            }
        }
        var out: [String: Any] = [:]
        for m in models {
            let name = existing[m] ?? Self.suffixedModelID(m)
            out[m] = ["name": name]
        }
        return out
    }

    private func opencodeSettingsConfig(_ p: ParsedKey, modelDict: [String: Any]) throws -> String {
        let options: [String: Any] = [
            "baseURL": opencodeBaseURL(p.url ?? ""),
            "apiKey": p.key ?? "",
            "setCacheKey": true
        ]
        return try jsonString([
            "npm": "@ai-sdk/openai-compatible",
            "options": options,
            "models": modelDict
        ])
    }

    private func codexSettingsConfig(_ p: ParsedKey, models: [String], wireApi: String = "responses") throws -> String {
        try jsonString([
            "auth": ["OPENAI_API_KEY": p.key ?? ""],
            "config": codexConfigToml(p, models: models, wireApi: wireApi)
        ])
    }

    /// TOML 双引号字符串转义(模型名/key 可能含引号或反斜杠)
    static func tomlQuote(_ s: String) -> String {
        let e = s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(e)\""
    }

    private func codexConfigToml(_ p: ParsedKey, models: [String], wireApi: String = "responses") throws -> String {
        let url = codexBaseURL(p.url ?? "")
        let model = models.first(where: { !$0.isEmpty })
            ?? (p.model?.isEmpty == false ? p.model : nil)
            ?? "gpt-5.6-sol"
        let path = Self.codexConfigPath
        if FileManager.default.fileExists(atPath: path),
           let content = try? String(contentsOfFile: path, encoding: .utf8) {
            var out: [String] = []
            var section = ""
            var customLines: [String]? = nil
            var hadCustom = false
            var hasAuthLine = false
            var modelSet = false
            var providerSet = false
            for ln in content.components(separatedBy: "\n") {
                let trimmed = ln.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                    if section == "model_providers.custom", let cl = customLines {
                        out.append(contentsOf: cl)
                        if !hasAuthLine { out.append("requires_openai_auth = true") }
                    }
                    customLines = nil
                    section = String(trimmed.dropFirst().dropLast())
                    if section == "model_providers.custom" {
                        customLines = []
                        hasAuthLine = false
                        hadCustom = true
                    }
                    out.append(ln)
                    continue
                }
                if section == "model_providers.custom" {
                    let key = trimmed.split(separator: "=", maxSplits: 1).first.map(String.init)?
                        .trimmingCharacters(in: .whitespaces) ?? ""
                    switch key {
                    case "base_url": customLines?.append("base_url = \(Self.tomlQuote(url))")
                    case "wire_api": customLines?.append("wire_api = \(Self.tomlQuote(wireApi))")
                    case "name": customLines?.append("name = \"custom\"")
                    case "env_key": break
                    case "requires_openai_auth": customLines?.append("requires_openai_auth = true"); hasAuthLine = true
                    case "experimental_bearer_token": customLines?.append("experimental_bearer_token = \(Self.tomlQuote(p.key ?? ""))")
                    default: customLines?.append(ln)
                    }
                    continue
                }
                if section == "" {
                    if trimmed.hasPrefix("model_provider") {
                        out.append("model_provider = \"custom\"")
                        providerSet = true
                        continue
                    }
                    if trimmed.hasPrefix("model = ") {
                        out.append("model = \(Self.tomlQuote(model))")
                        modelSet = true
                        continue
                    }
                    if trimmed.hasPrefix("model_catalog_json") {
                        continue
                    }
                }
                out.append(ln)
            }
            if section == "model_providers.custom", let cl = customLines {
                out.append(contentsOf: cl)
                if !hasAuthLine { out.append("requires_openai_auth = true") }
            }
            if !providerSet {
                out.insert("model_provider = \"custom\"", at: 0)
            }
            if !modelSet {
                out.insert("model = \(Self.tomlQuote(model))", at: providerSet ? 1 : 0)
            }
            if !hadCustom {
                out.append("")
                out.append("[model_providers.custom]")
                out.append("name = \"custom\"")
                out.append("wire_api = \(Self.tomlQuote(wireApi))")
                out.append("requires_openai_auth = true")
                out.append("base_url = \(Self.tomlQuote(url))")
                out.append("experimental_bearer_token = \(Self.tomlQuote(p.key ?? ""))")
            }
            return out.joined(separator: "\n")
        }
        return [
            "model_provider = \"custom\"",
            "model = \(Self.tomlQuote(model))",
            "model_reasoning_effort = \"high\"",
            "",
            "[model_providers.custom]",
            "name = \"custom\"",
            "wire_api = \(Self.tomlQuote(wireApi))",
            "requires_openai_auth = true",
            "base_url = \(Self.tomlQuote(url))",
            "experimental_bearer_token = \(Self.tomlQuote(p.key ?? ""))"
        ].joined(separator: "\n")
    }

    func mergeCodexConfig(_ p: ParsedKey, models: [String], wireApi: String = "responses") throws {
        let cfgPath = Self.codexConfigPath
        if FileManager.default.fileExists(atPath: cfgPath) {
            _ = try? FileManager.default.removeItem(atPath: cfgPath + ".bak")
            try? FileManager.default.copyItem(atPath: cfgPath, toPath: cfgPath + ".bak")
        }
        let written = try codexConfigToml(p, models: models, wireApi: wireApi)
        try writeText(written, to: cfgPath)
        if let back = try? String(contentsOfFile: cfgPath, encoding: .utf8) {
            // 回读比对必须用与写入一致的规范化值(codexBaseURL 补 /v1、tomlQuote 转义),
            // 否则 URL 不带 /v1 时必然误报「回读不一致」
            let key = p.key ?? ""
            let url = codexBaseURL(p.url ?? "")
            var issues: [String] = []
            if !back.contains("base_url = \(Self.tomlQuote(url))") { issues.append("base_url 回读不一致") }
            if !back.contains("experimental_bearer_token = \(Self.tomlQuote(key))") { issues.append("token 回读不一致") }
            let model = models.first(where: { !$0.isEmpty }) ?? (p.model?.isEmpty == false ? p.model : nil)
            if let m = model, !back.contains("model = \(Self.tomlQuote(m))") { issues.append("model 回读不一致") }
            if !issues.isEmpty {
                // 不再 throw:调用方(add)此刻 DB 事务已 COMMIT,throw 会制造
                // 「DB 说成功、外层报失败」的分裂状态。重写一次 + warn,让结果收敛。
                try writeText(written, to: cfgPath)
                AppLog.warn("codex config 回读校验失败(\(issues.joined(separator: ", "))),已重写;请检查 \(cfgPath)")
            }
        }
        let authPath = Self.codexAuthPath
        if FileManager.default.fileExists(atPath: authPath) {
            _ = try? FileManager.default.removeItem(atPath: authPath + ".bak")
            try? FileManager.default.copyItem(atPath: authPath, toPath: authPath + ".bak")
        }
        try writeJSON(["OPENAI_API_KEY": p.key ?? ""], to: authPath)
    }

    private func restoreCodexConfig() throws {
        let cfgPath = Self.codexConfigPath
        let bakPath = cfgPath + ".bak"
        if FileManager.default.fileExists(atPath: bakPath) {
            _ = try? FileManager.default.removeItem(atPath: cfgPath)
            try FileManager.default.moveItem(atPath: bakPath, toPath: cfgPath)
        }
        let authPath = Self.codexAuthPath
        let authBak = authPath + ".bak"
        if FileManager.default.fileExists(atPath: authBak) {
            _ = try? FileManager.default.removeItem(atPath: authPath)
            try FileManager.default.moveItem(atPath: authBak, toPath: authPath)
        }
    }

    private func writeText(_ s: String, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let tmp = url.appendingPathExtension("keydrop-tmp")
        try? FileManager.default.removeItem(at: tmp)
        try s.write(to: tmp, atomically: true, encoding: .utf8)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }

    /// 全局唯一的模型显示名: kimi-k3-<8位随机>。id 不动,名字唯一,opencode /model 直接搜名字即定位
    static func suffixedModelID(_ m: String) -> String {
        let rnd = String(UUID().uuidString.filter { $0.isHexDigit }.prefix(8))
        return "\(m)-\(rnd)"
    }

    /// 复制用:模型在 opencode 里实际存的显示名;不在 opencode 里则回退 模型-条目ID前8位(稳定)
    public static func copyModelName(for entry: HistoryEntry, model: String) -> String {
        let path = opencodeConfigPath
        if FileManager.default.fileExists(atPath: path),
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let providers = obj["provider"] as? [String: Any] {
            if let key = opencodeProviderKey(for: entry, model: model),
               let pd = providers[key] as? [String: Any],
               let models = pd["models"] as? [String: Any],
               let me = models[model] as? [String: Any],
               let name = me["name"] as? String {
                return name
            }
            // 兼容旧版固定 KeyDrop provider key
            if let pd = providers["KeyDrop"] as? [String: Any],
               let models = pd["models"] as? [String: Any],
               let me = models[model] as? [String: Any],
               let name = me["name"] as? String {
                return name
            }
        }
        return "\(model)-\(entry.id.prefix(8))"
    }

    /// 找出该条目对应的模型在 opencode.json 中实际归属的 provider key
    static func opencodeProviderKey(for entry: HistoryEntry, model: String) -> String? {
        let path = opencodeConfigPath
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providers = obj["provider"] as? [String: Any] else {
            return nil
        }
        if entry.targets.contains(where: { $0.hasPrefix("ccswitch-opencode") || $0.hasPrefix("ccswitch-codex") }),
           let pid = entry.ccProviderID,
           providers[pid] != nil {
            return pid
        }
        let entryHost = URL(string: entry.url ?? "")?.host?.lowercased()
        guard let entryHost else { return nil }
        for (key, raw) in providers {
            guard let pd = raw as? [String: Any],
                  let opts = pd["options"] as? [String: Any],
                  let base = opts["baseURL"] as? String,
                  let baseHost = URL(string: base)?.host?.lowercased(),
                  baseHost == entryHost else { continue }
            return key
        }
        return nil
    }

    static var opencodeConfigPath: String {
        ProcessInfo.processInfo.environment["KEYDROP_OPENCODE_CONFIG"]
            ?? (NSHomeDirectory() + "/.config/opencode/opencode.json")
    }

    private func codexBaseURL(_ url: String) -> String {
        let u = url.hasSuffix("/") ? String(url.dropLast()) : url
        if u.hasSuffix("/v1") || u.hasSuffix("/api") { return u }
        return u + "/v1"
    }

    private func opencodeBaseURL(_ url: String) -> String {
        let u = url.hasSuffix("/") ? String(url.dropLast()) : url
        if u.hasSuffix("/v1") || u.hasSuffix("/api") { return u }
        return u + "/v1"
    }

    /// endpoint 去重比较用:去尾斜杠,/chat/completions 归一到 /v1
    private func normalizeEndpointURL(_ url: String) -> String {
        let u = url.hasSuffix("/") ? String(url.dropLast()) : url
        if u.hasSuffix("/chat/completions") { return String(u.dropLast("/chat/completions".count)) + "/v1" }
        if u.hasSuffix("/v1") || u.hasSuffix("/api") { return u }
        return u + "/v1"
    }

    func mergeOpencodeProvider(_ p: ParsedKey, providerID: String, modelDict: [String: Any], firstModel: String?) throws {
        let path = Self.opencodeConfigPath
        // flock 包住「读→改→写」:CLI 与菜单栏并发写 opencode.json 时,
        // 后写者会用旧读出的全文覆盖掉先写者刚写入的 provider 条目
        try FileLock.withLock(FileLock.lockPath(for: path)) {
            try mergeOpencodeProviderLocked(p, providerID: providerID, path: path, modelDict: modelDict, firstModel: firstModel)
        }
    }

    private func mergeOpencodeProviderLocked(_ p: ParsedKey, providerID: String, path: String, modelDict: [String: Any], firstModel: String?) throws {
        if FileManager.default.fileExists(atPath: path) {
            _ = try? FileManager.default.removeItem(atPath: path + ".bak")
            try? FileManager.default.copyItem(atPath: path, toPath: path + ".bak")
        }
        var obj = try loadJSONForWrite(path)
        var providers = (obj["provider"] as? [String: Any]) ?? [:]
        var pd: [String: Any] = [
            "npm": "@ai-sdk/openai-compatible",
            "options": [
                "baseURL": opencodeBaseURL(p.url ?? ""),
                "apiKey": p.key ?? "",
                "setCacheKey": true
            ]
        ]
        if !modelDict.isEmpty {
            pd["models"] = modelDict
        }
        providers[providerID] = pd
        providers.removeValue(forKey: "KeyDrop")
        obj["provider"] = providers
        if let first = firstModel {
            obj["model"] = "\(providerID)/\(first)"
        }
        try writeJSON(obj, to: path)
    }

    // MARK: - self-heal

    public func repairMissingProvider(entry: HistoryEntry) throws -> Bool {
        guard let pid = entry.ccProviderID, entry.status == "active",
              entry.targets.contains(where: { $0.hasPrefix("ccswitch") }),
              let key = entry.key, !key.isEmpty,
              let url = entry.url, !url.isEmpty
        else { return false }
        let appType = entry.targets.first(where: { $0.hasPrefix("ccswitch-") })
            .map { String($0.dropFirst("ccswitch-".count)) } ?? "claude"
        try Self.ensureDB()
        let db = try DB(path: Self.dbPath)
        let existing = try db.scalar("SELECT 1 FROM providers WHERE id=? AND app_type=?", [pid, appType])
        if existing != nil { return false }

        var p = ParsedKey()
        p.key = key
        p.url = url
        p.model = entry.model
        p.name = entry.name
        let models = entry.models ?? (entry.model.map { [$0] } ?? [])
        let name = (entry.name?.isEmpty == false ? entry.name! : defaultName(for: url))
        let wireApi = "responses"

        let opencodeDict = opencodeModelDict(providerID: pid, baseURL: url, models: models)

        let settingsConfig: String
        if appType == "opencode" {
            settingsConfig = try opencodeSettingsConfig(p, modelDict: opencodeDict)
        } else if appType == "codex" {
            settingsConfig = try codexSettingsConfig(p, models: models, wireApi: wireApi)
        } else {
            settingsConfig = try jsonString(["env": claudeEnv(for: p, models: models)])
        }
        let currentID = readSwitchSettings()?[currentKey(appType)] as? String
        var promote = false
        if let cid = currentID, !cid.isEmpty {
            let alive = try db.scalar("SELECT 1 FROM providers WHERE id=? AND app_type=?", [cid, appType])
            promote = (alive == nil)
        }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        // 网络探测只对 codex 有意义(apiFormat 只写入 codex 的 meta);
        // 不加守卫时 self-heal 批量修复 claude/opencode 条目会逐个发网络请求,
        // 离线场景下每个都要等超时,整个修复流程卡死数分钟
        let apiFormat = appType == "codex"
            ? (APITester.supportsResponsesAPI(base: url, key: key, proxy: nil) ? "openai_responses" : "openai_chat")
            : "openai_responses"
        let meta = appType == "codex"
            ? "{\"commonConfigEnabled\":false,\"endpointAutoSelect\":true,\"apiFormat\":\"\(apiFormat)\"}"
            : "{}"
        try db.run(
            "INSERT INTO providers (id, app_type, name, settings_config, created_at, meta, is_current) VALUES (?,?,?,?,?,?,?)",
            [pid, appType, name, settingsConfig, now, meta, promote ? 1 : 0]
        )
        // endpoint 行与 add() 对齐:cc-switch 界面展示 URL、后续按 URL 去重都依赖它
        try db.run(
            "INSERT INTO provider_endpoints (provider_id, app_type, url, added_at) VALUES (?, ?, ?, ?)",
            [pid, appType, appType == "opencode" ? opencodeBaseURL(url) : url, now]
        )
        if promote {
            try updateSwitchSettings(pid, for: appType)
        }
        return true
    }

    // MARK: - remove

    func remove(providerID: String, renamedFrom: String?, renamedTo: String?, appType: String = "claude") throws -> String {
        try Self.ensureDB()
        let db = try DB(path: Self.dbPath)
        // COMMIT 之后任何附属文件(settings/opencode.json/codex备份)写入失败都只降级为
        // 警告附在返回消息里,不再 throw:此刻事务已提交、DB 已删干净,
        // 抛错会让调用方(Core.delete)误判"删除失败",制造历史↔DB 账目不一致。
        var warnings: [String] = []
        func warn(_ e: Error) { warnings.append(e.localizedDescription) }
        try db.exec("BEGIN IMMEDIATE")
        do {
            if appType == "opencode" || appType == "codex" {
                let wasCurrent = (try db.scalar(
                    "SELECT is_current FROM providers WHERE id = ? AND app_type = ?",
                    [providerID, appType]
                )) == "1"
                try db.run("DELETE FROM provider_endpoints WHERE provider_id = ?", [providerID])
                try db.run("DELETE FROM providers WHERE id = ? AND app_type = ?", [providerID, appType])
                if wasCurrent {
                    guard let fb = try db.scalar(
                        "SELECT id FROM providers WHERE app_type = ? ORDER BY created_at DESC LIMIT 1",
                        [appType]
                    ) else {
                        try db.exec("COMMIT")
                        do { try updateSwitchSettings(nil, for: appType) } catch { warn(error) }
                        do { try clearOpencodeProvider(id: providerID) } catch { warn(error) }
                        if appType == "codex" { try? restoreCodexConfig() }
                        return joinDeleteMsg("已删除,并清除当前设置", warnings)
                    }
                    try db.run("UPDATE providers SET is_current = 0 WHERE app_type = ?", [appType])
                    try db.run("UPDATE providers SET is_current = 1 WHERE id = ? AND app_type = ?", [fb, appType])
                    try db.exec("COMMIT")
                    do { try updateSwitchSettings(fb, for: appType) } catch { warn(error) }
                    do { try clearOpencodeProvider(id: providerID) } catch { warn(error) }
                    if appType == "codex" { try? restoreCodexConfig() }
                    return joinDeleteMsg("已删除,回退到最近 provider(\(fb.prefix(8))…)", warnings)
                }
                try db.exec("COMMIT")
                do { try clearOpencodeProvider(id: providerID) } catch { warn(error) }
                if appType == "codex" { try? restoreCodexConfig() }
                return joinDeleteMsg("已删除", warnings)
            }

            // Claude 分支:历史 renamedFrom/renamedTo 机制已废弃(参见 add() 注释),
            // 即便调用方传了值也忽略,统一走「最近创建的同 app_type provider 兜底恢复」。
            _ = renamedFrom
            _ = renamedTo

            let wasCurrent = (try db.scalar(
                "SELECT is_current FROM providers WHERE id = ? AND app_type = 'claude'",
                [providerID]
            )) == "1"
            try db.run("DELETE FROM provider_endpoints WHERE provider_id = ?", [providerID])
            try db.run("DELETE FROM providers WHERE id = ? AND app_type = 'claude'", [providerID])

            if wasCurrent {
                let fallback = try db.scalar(
                    "SELECT id FROM providers WHERE app_type = 'claude' ORDER BY created_at DESC LIMIT 1",
                    []
                )
                if let fb = fallback {
                    try db.run("UPDATE providers SET is_current = 0 WHERE app_type = 'claude'")
                    try db.run("UPDATE providers SET is_current = 1 WHERE id = ? AND app_type = 'claude'", [fb])
                    try db.exec("COMMIT")
                    do { try updateSwitchSettings(fb, for: "claude") } catch { warn(error) }
                    restoreLiveEnv(providerID: fb, db: db)
                    return joinDeleteMsg("已删除,回退到最近 provider(\(fb.prefix(8))…)", warnings)
                }
            }
            try db.exec("COMMIT")
            if wasCurrent {
                do {
                    try updateSwitchSettings(nil, for: "claude")
                    try clearLiveEnv()
                } catch {
                    warn(error)
                }
                return joinDeleteMsg("已删除", warnings)
            }
            return joinDeleteMsg("已删除", warnings)
        } catch {
            try? db.exec("ROLLBACK")
            throw error
        }
    }

    /// 拼接删除结果消息与 COMMIT 后产生的降级警告
    private func joinDeleteMsg(_ base: String, _ warnings: [String]) -> String {
        guard !warnings.isEmpty else { return base }
        return base + "\n⚠ " + warnings.joined(separator: "; ")
    }

    /// 兜底删除:仅凭 provider ID 删除(不依赖历史 targets 标记)
    func removeProviderByID(_ providerID: String) throws -> [String] {
        try Self.ensureDB()
        let db = try DB(path: Self.dbPath)
        let rows = try db.query("SELECT DISTINCT app_type FROM providers WHERE id = ?", [providerID])
        var out: [String] = []
        for r in rows {
            guard let at = r[0] else { continue }
            let msg = try remove(providerID: providerID, renamedFrom: nil, renamedTo: nil, appType: at)
            out.append("\(at): \(msg)")
        }
        return out
    }

    /// 兜底删除:按 URL 主机名匹配 settings_config / website_url 里的 provider 并删除
    func removeByHost(_ urlString: String) throws -> [String] {
        try Self.ensureDB()
        let db = try DB(path: Self.dbPath)
        guard let host = URL(string: urlString)?.host?.lowercased() else { return [] }
        let rows = try db.query(
            "SELECT id, app_type, name, settings_config, website_url FROM providers", []
        )
        var out: [String] = []
        for r in rows {
            guard let id = r[0], let at = r[1] else { continue }
            let name = r[2] ?? ""
            let cfg = r[3] ?? ""
            let web = r[4] ?? ""
            if hosts(in: cfg).contains(host) || hosts(in: web).contains(host) {
                let msg = try remove(providerID: id, renamedFrom: nil, renamedTo: nil, appType: at)
                out.append("\(name.isEmpty ? String(id.prefix(8)) : name)[\(at)]: \(msg)")
            }
        }
        return out
    }

    private func hosts(in s: String) -> Set<String> {
        guard let re = try? NSRegularExpression(pattern: #"https?://([^/\s"']+)"#) else { return [] }
        let ns = s as NSString
        var out = Set<String>()
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let raw = ns.substring(with: m.range(at: 1))
            let host = raw.components(separatedBy: ":").first?.lowercased() ?? raw.lowercased()
            out.insert(host)
        }
        return out
    }

    private func restoreLiveEnv(providerID: String, db: DB) {
        if let claude = readClaudeSettings() {
            let token = ((claude["env"] as? [String: Any])?["ANTHROPIC_AUTH_TOKEN"] as? String) ?? ""
            guard token != "PROXY_MANAGED" else { return }
        } else { return }
        guard let cfgStr = try? db.scalar(
            "SELECT settings_config FROM providers WHERE id = ? AND app_type = 'claude'",
            [providerID]
        ) ?? nil,
            let data = cfgStr.data(using: .utf8),
            let cfg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let envObject = cfg["env"] as? [String: Any]
        else { return }
        let env = envObject.compactMapValues { $0 as? String }
        do {
            try mergeEnvIntoClaudeSettings(env)
        } catch {
            Logger.warn("Claude settings 恢复失败: \(error.localizedDescription)")
        }
    }

    // MARK: - helpers

    /// 检查 cc-switch 中是否仍存在该 provider(ID + app_type)。
    /// DB 不可用时返回 true(保守:不误标孤儿)。
    public func providerExists(id: String, appType: String) -> Bool {
        guard FileManager.default.fileExists(atPath: Self.dbPath),
              let db = try? DB(path: Self.dbPath)
        else { return true }
        let found = try? db.scalar(
            "SELECT 1 FROM providers WHERE id = ? AND app_type = ?",
            [id, appType]
        )
        return found != nil
    }

    /// 刷新模型后同步 cc-switch:总是更新 DB settings_config(切换回该 provider 时用新列表),
    /// 仅当该 provider 是当前激活时同步真实配置文件,避免覆盖其他 provider 的环境。
    public func syncModelsAfterRefresh(
        _ p: ParsedKey, providerID: String, appType: String, models: [String], proxy: String? = nil
    ) throws {
        guard FileManager.default.fileExists(atPath: Self.dbPath) else { return }
        let db = try DB(path: Self.dbPath)
        let isCurrent = (try? db.scalar(
            "SELECT is_current FROM providers WHERE id = ? AND app_type = ?",
            [providerID, appType]
        )) == "1"
        let wireApi = "responses"

        let opencodeDict = opencodeModelDict(providerID: providerID, baseURL: p.url, models: models)

        let settingsConfig: String
        if appType == "opencode" {
            settingsConfig = try opencodeSettingsConfig(p, modelDict: opencodeDict)
        } else if appType == "codex" {
            settingsConfig = try codexSettingsConfig(p, models: models, wireApi: wireApi)
        } else {
            settingsConfig = try jsonString(["env": claudeEnv(for: p, models: models)])
        }
        try db.run(
            "UPDATE providers SET settings_config = ? WHERE id = ? AND app_type = ?",
            [settingsConfig, providerID, appType]
        )

        // opencode.json 是共享文件(多 provider 共存),更新非当前 provider 的条目也安全;
        // codex/claude 是单文件单 provider,只有当前激活时才同步,避免覆盖其他 provider 的环境
        if appType == "opencode" {
            try mergeOpencodeProvider(p, providerID: providerID, modelDict: opencodeDict, firstModel: models.first)
            return
        }
        guard isCurrent else { return }
        switch appType {
        case "codex":
            let proxied = (try? String(contentsOfFile: Self.codexConfigPath, encoding: .utf8))
                .flatMap { c -> Bool in
                    let custom = c.components(separatedBy: "[model_providers.custom]").dropFirst().first ?? ""
                    return custom.contains("PROXY_MANAGED") || custom.contains("127.0.0.1:15721")
                } ?? false
            if !proxied {
                try mergeCodexConfig(p, models: models, wireApi: wireApi)
            }
        default:
            try mergeEnvIntoClaudeSettings(claudeEnv(for: p, models: models))
        }
    }

    public func providerExists(_ id: String, appType: String) -> Bool {
        providerExists(id: id, appType: appType)
    }

    static public func ccSwitchRunning() -> Bool {
        if ProcessInfo.processInfo.environment["KEYDROP_FAKE_CC_RUNNING"] == "1" { return true }
        if ProcessInfo.processInfo.environment["KEYDROP_FAKE_CC_RUNNING"] == "0" { return false }
        return NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.ccswitch.desktop"
        }
    }

    private static func ensureDB() throws {
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw WriterError.file(
                "cc-switch 数据库不存在: \(dbPath)\n"
                + "提示: 先安装并运行 cc-switch,或设置环境变量 KEYDROP_CC_DB 指向数据库。"
            )
        }
    }

    func defaultName(for url: String) -> String {
        let host = URL(string: url)?.host ?? url
        let df = DateFormatter()
        df.dateFormat = "MMdd-HHmm"
        return "\(host)-\(df.string(from: Date()))"
    }

    public func readSwitchSettings() -> [String: Any]? {
        readJSON(Self.switchSettingsPath)
    }

    public func readClaudeSettings() -> [String: Any]? {
        readJSON(Self.claudeSettingsPath)
    }

    private func updateSwitchSettings(_ id: String?, for appType: String) throws {
        try FileLock.withLock(FileLock.lockPath(for: Self.switchSettingsPath)) {
            var obj = try loadJSONForWrite(Self.switchSettingsPath)
            let key = currentKey(appType)
            if let id { obj[key] = id } else { obj.removeValue(forKey: key) }
            try writeJSON(obj, to: Self.switchSettingsPath)
        }
    }

    private func mergeEnvIntoClaudeSettings(_ env: [String: String]) throws {
        try FileLock.withLock(FileLock.lockPath(for: Self.claudeSettingsPath)) {
            try mergeEnvIntoClaudeSettingsLocked(env)
        }
    }

    private func mergeEnvIntoClaudeSettingsLocked(_ env: [String: String]) throws {
        var obj = try loadJSONForWrite(Self.claudeSettingsPath)
        var existing = (obj["env"] as? [String: Any]) ?? [:]
        let anthropicKeys = env.keys
        for k in Array(existing.keys)
        where k.hasPrefix("ANTHROPIC_") || k == "CLAUDE_CODE_SUBAGENT_MODEL"
            || k == "HTTPS_PROXY" || k == "HTTP_PROXY" || k == "ALL_PROXY" || k == "NO_PROXY" {
            if !anthropicKeys.contains(k) { existing.removeValue(forKey: k) }
        }
        for (k, v) in env { existing[k] = v }
        obj["env"] = existing
        try writeJSON(obj, to: Self.claudeSettingsPath)
    }

    private func clearOpencodeProvider() throws {
        let path = Self.opencodeConfigPath
        guard FileManager.default.fileExists(atPath: path) else { return }
        var obj = try loadJSONForWrite(path)
        var providers = (obj["provider"] as? [String: Any]) ?? [:]
        providers.removeValue(forKey: "KeyDrop")
        // 兼容旧版单一 KeyDrop key;也清掉以 UUID 命名的孤立项需由 remove 路径处理
        obj["provider"] = providers
        if let model = obj["model"] as? String, model.hasPrefix("KeyDrop/") {
            obj.removeValue(forKey: "model")
        }
        try writeJSON(obj, to: path)
    }

    private func clearOpencodeProvider(id: String) throws {
        let path = Self.opencodeConfigPath
        guard FileManager.default.fileExists(atPath: path) else { return }
        try FileLock.withLock(FileLock.lockPath(for: path)) {
            try clearOpencodeProviderLocked(id: id, path: path)
        }
    }

    private func clearOpencodeProviderLocked(id: String, path: String) throws {
        var obj = try loadJSONForWrite(path)
        var providers = (obj["provider"] as? [String: Any]) ?? [:]
        providers.removeValue(forKey: id)
        providers.removeValue(forKey: "KeyDrop")
        obj["provider"] = providers
        if let model = obj["model"] as? String,
           model.hasPrefix("\(id)/") || model.hasPrefix("KeyDrop/") {
            obj.removeValue(forKey: "model")
        }
        try writeJSON(obj, to: path)
    }

    private func clearLiveEnv() throws {
        guard FileManager.default.fileExists(atPath: Self.claudeSettingsPath) else { return }
        try FileLock.withLock(FileLock.lockPath(for: Self.claudeSettingsPath)) {
            try clearLiveEnvLocked()
        }
    }

    private func clearLiveEnvLocked() throws {
        var obj = try loadJSONForWrite(Self.claudeSettingsPath)
        let token = ((obj["env"] as? [String: Any])?["ANTHROPIC_AUTH_TOKEN"] as? String) ?? ""
        guard token != "PROXY_MANAGED" else { return }
        var existing = (obj["env"] as? [String: Any]) ?? [:]
        for key in Array(existing.keys)
        where key.hasPrefix("ANTHROPIC_") || key == "CLAUDE_CODE_SUBAGENT_MODEL"
            || key == "HTTPS_PROXY" || key == "HTTP_PROXY" || key == "ALL_PROXY" || key == "NO_PROXY" {
            existing.removeValue(forKey: key)
        }
        if existing.isEmpty { obj.removeValue(forKey: "env") }
        else { obj["env"] = existing }
        try writeJSON(obj, to: Self.claudeSettingsPath)
    }

    func readJSON(_ path: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func loadJSONForWrite(_ path: String) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: path) else { return [:] }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            throw WriterError.json("无法读取 \(path)")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WriterError.json("根节点不是对象: \(path)")
        }
        return obj
    }

    private func writeJSON(_ obj: [String: Any], to path: String) throws {
        let data = try JSONSerialization.data(
            withJSONObject: obj,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let tmp = url.appendingPathExtension("keydrop-tmp")
        try? FileManager.default.removeItem(at: tmp)
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }

    private func jsonString(_ obj: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

public enum Logger {
    static public func warn(_ s: String) { write(s) }
    static public func info(_ s: String) { write(s) }
    private static func write(_ s: String) {
        let data = (s + "\n").data(using: .utf8) ?? Data()
        FileHandle.standardError.write(data)
    }
}
