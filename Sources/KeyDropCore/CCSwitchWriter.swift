import Foundation
import AppKit

public struct CCAddResult {
    public let providerID: String
    public let providerName: String
    var renamedFrom: String? = nil
    var renamedTo: String? = nil
    var directMode = false
    var proxyMode = false
    var warnings: [String] = []
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
        let supportsResponses = appType == "codex" ? APITester.supportsResponsesAPI(base: url, key: key, proxy: proxy) : true
        let apiFormat = supportsResponses ? "openai_responses" : "openai_chat"
        let meta = appType == "codex"
            ? "{\"commonConfigEnabled\":false,\"endpointAutoSelect\":true,\"apiFormat\":\"\(apiFormat)\"}"
            : "{}"

        let settingsConfig: String
        if appType == "opencode" {
            settingsConfig = try opencodeSettingsConfig(p, models: models)
        } else if appType == "codex" {
            settingsConfig = try codexSettingsConfig(p, models: models, wireApi: wireApi)
        } else {
            settingsConfig = try claudeSettingsConfig(p, models: models, proxy: proxy)
        }

        let diskCurrent = readSwitchSettings()?[currentKey(appType)] as? String
        let appRunning = Self.ccSwitchRunning()

        let db = try DB(path: Self.dbPath)
        try db.exec("BEGIN IMMEDIATE")
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

            var renamedFrom: String? = nil
            var renamedTo: String? = nil
            if appRunning, let cur = diskCurrent, cur != id {
                let retired = UUID().uuidString.lowercased()
                try db.run("UPDATE providers SET id = ? WHERE id = ? AND app_type = ?", [retired, cur, appType])
                renamedFrom = cur
                renamedTo = retired
            }
            try db.exec("COMMIT")

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
                    try mergeOpencodeProvider(p, providerID: id, models: models)
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

    private func opencodeSettingsConfig(_ p: ParsedKey, models: [String]) throws -> String {
        let options: [String: Any] = [
            "baseURL": opencodeBaseURL(p.url ?? ""),
            "apiKey": p.key ?? "",
            "setCacheKey": true
        ]
        var modelDict: [String: Any] = [:]
        let all = models.isEmpty ? (p.model.map { [$0] } ?? []) : models
        for m in all {
            modelDict[m] = ["name": Self.suffixedModelID(m)]
        }
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
                    case "base_url": customLines?.append("base_url = \"\(url)\"")
                    case "wire_api": customLines?.append("wire_api = \"\(wireApi)\"")
                    case "name": customLines?.append("name = \"custom\"")
                    case "env_key": break
                    case "requires_openai_auth": customLines?.append("requires_openai_auth = true"); hasAuthLine = true
                    case "experimental_bearer_token": customLines?.append("experimental_bearer_token = \"\(p.key ?? "")\"")
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
                        out.append("model = \"\(model)\"")
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
                out.insert("model = \"\(model)\"", at: providerSet ? 1 : 0)
            }
            if !hadCustom {
                out.append("")
                out.append("[model_providers.custom]")
                out.append("name = \"custom\"")
                out.append("wire_api = \"\(wireApi)\"")
                out.append("requires_openai_auth = true")
                out.append("base_url = \"\(url)\"")
                out.append("experimental_bearer_token = \"\(p.key ?? "")\"")
            }
            return out.joined(separator: "\n")
        }
        return [
            "model_provider = \"custom\"",
            "model = \"\(model)\"",
            "model_reasoning_effort = \"high\"",
            "",
            "[model_providers.custom]",
            "name = \"custom\"",
            "wire_api = \"\(wireApi)\"",
            "requires_openai_auth = true",
            "base_url = \"\(url)\"",
            "experimental_bearer_token = \"\(p.key ?? "")\""
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
            let key = p.key ?? ""
            let url = p.url ?? ""
            var issues: [String] = []
            if !back.contains("base_url = \"\(url)\"") { issues.append("base_url 回读不一致") }
            if !back.contains("experimental_bearer_token = \"\(key)\"") { issues.append("token 回读不一致") }
            let model = models.first(where: { !$0.isEmpty }) ?? (p.model?.isEmpty == false ? p.model : nil)
            if let m = model, !back.contains("model = \"\(m)\"") { issues.append("model 回读不一致") }
            if !issues.isEmpty {
                try writeText(written, to: cfgPath)
                throw ParseError.io("codex config 写入校验失败(\(issues.joined(separator: ", "))),已重写")
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

    func mergeOpencodeProvider(_ p: ParsedKey, providerID: String, models: [String]) throws {
        let path = Self.opencodeConfigPath
        if FileManager.default.fileExists(atPath: path) {
            _ = try? FileManager.default.removeItem(atPath: path + ".bak")
            try? FileManager.default.copyItem(atPath: path, toPath: path + ".bak")
        }
        var obj = try loadJSONForWrite(path)
        var providers = (obj["provider"] as? [String: Any]) ?? [:]
        // 尽量保留旧显示名,避免刷新后已复制的模型名失效
        let previousModels: [String: Any] = {
            if let existing = providers[providerID] as? [String: Any],
               let m = existing["models"] as? [String: Any] {
                return m
            }
            if let legacy = providers["KeyDrop"] as? [String: Any],
               let m = legacy["models"] as? [String: Any] {
                return m
            }
            return [:]
        }()
        var pd: [String: Any] = [
            "npm": "@ai-sdk/openai-compatible",
            "options": [
                "baseURL": opencodeBaseURL(p.url ?? ""),
                "apiKey": p.key ?? "",
                "setCacheKey": true
            ]
        ]
        let all = models.isEmpty ? (p.model.map { [$0] } ?? []) : models
        if !all.isEmpty {
            var modelDict: [String: Any] = [:]
            for m in all {
                if let old = previousModels[m] as? [String: Any],
                   let oldName = old["name"] as? String, !oldName.isEmpty {
                    modelDict[m] = ["name": oldName]
                } else {
                    modelDict[m] = ["name": Self.suffixedModelID(m)]
                }
            }
            pd["models"] = modelDict
        }
        providers[providerID] = pd
        providers.removeValue(forKey: "KeyDrop")
        obj["provider"] = providers
        if let first = all.first {
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

        let settingsConfig: String
        if appType == "opencode" {
            settingsConfig = try opencodeSettingsConfig(p, models: models)
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
        let apiFormat = APITester.supportsResponsesAPI(base: url, key: key, proxy: nil) ? "openai_responses" : "openai_chat"
        let meta = appType == "codex"
            ? "{\"commonConfigEnabled\":false,\"endpointAutoSelect\":true,\"apiFormat\":\"\(apiFormat)\"}"
            : "{}"
        try db.run(
            "INSERT INTO providers (id, app_type, name, settings_config, created_at, meta, is_current) VALUES (?,?,?,?,?,?,?)",
            [pid, appType, name, settingsConfig, now, meta, promote ? 1 : 0]
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
                        try updateSwitchSettings(nil, for: appType)
                        try clearOpencodeProvider(id: providerID)
                        if appType == "codex" { try? restoreCodexConfig() }
                        return "已删除,并清除当前设置"
                    }
                    try db.run("UPDATE providers SET is_current = 0 WHERE app_type = ?", [appType])
                    try db.run("UPDATE providers SET is_current = 1 WHERE id = ? AND app_type = ?", [fb, appType])
try db.exec("COMMIT")
                try updateSwitchSettings(fb, for: appType)
                try? clearOpencodeProvider(id: providerID)
                if appType == "codex" { try? restoreCodexConfig() }
                return "已删除,回退到最近 provider(\(fb.prefix(8))…)"
            }
            try db.exec("COMMIT")
            try? clearOpencodeProvider(id: providerID)
            if appType == "codex" { try? restoreCodexConfig() }
            return "已删除"
        }

            if let rf = renamedFrom, let rt = renamedTo {
                try db.run("DELETE FROM provider_endpoints WHERE provider_id = ?", [rf])
                try db.run("DELETE FROM provider_endpoints WHERE provider_id = ?", [providerID])
                try db.run("UPDATE providers SET id = ? WHERE id = ? AND app_type = 'claude'", [rf, rt])
                try db.run("DELETE FROM providers WHERE id = ? AND app_type = 'claude'", [providerID])
                try db.run("UPDATE providers SET is_current = 0 WHERE app_type = 'claude'")
                try db.run("UPDATE providers SET is_current = 1 WHERE id = ? AND app_type = 'claude'", [rf])
                try db.exec("COMMIT")
                var warning: String? = nil
                do {
                    try updateSwitchSettings(rf, for: "claude")
                } catch {
                    warning = "switch settings 更新失败: \(error.localizedDescription)"
                }
                restoreLiveEnv(providerID: rf, db: db)
                return warning.map { "已删除,并恢复原 provider(\(rf.prefix(8))…)\n⚠ \($0)" }
                    ?? "已删除,并恢复原 provider(\(rf.prefix(8))…)"
            }

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
                    var warning: String? = nil
                    do {
                        try updateSwitchSettings(fb, for: "claude")
                    } catch {
                        warning = "switch settings 更新失败: \(error.localizedDescription)"
                    }
                    restoreLiveEnv(providerID: fb, db: db)
                    return warning.map { "已删除,回退到最近 provider(\(fb.prefix(8))…)\n⚠ \($0)" }
                        ?? "已删除,回退到最近 provider(\(fb.prefix(8))…)"
                }
            }
            try db.exec("COMMIT")
            if wasCurrent {
                var warning: String? = nil
                do {
                    try updateSwitchSettings(nil, for: "claude")
                    try clearLiveEnv()
                } catch {
                    warning = "清理当前设置失败: \(error.localizedDescription)"
                }
                return warning.map { "已删除\n⚠ \($0)" } ?? "已删除"
            }
            return "已删除"
        } catch {
            try? db.exec("ROLLBACK")
            throw error
        }
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
    func providerExists(id: String, appType: String) -> Bool {
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
    func syncModelsAfterRefresh(
        _ p: ParsedKey, providerID: String, appType: String, models: [String], proxy: String? = nil
    ) throws {
        guard FileManager.default.fileExists(atPath: Self.dbPath) else { return }
        let db = try DB(path: Self.dbPath)
        let isCurrent = (try? db.scalar(
            "SELECT is_current FROM providers WHERE id = ? AND app_type = ?",
            [providerID, appType]
        )) == "1"
        let wireApi = "responses"

        let settingsConfig: String
        if appType == "opencode" {
            settingsConfig = try opencodeSettingsConfig(p, models: models)
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
            try mergeOpencodeProvider(p, providerID: providerID, models: models)
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

    func providerExists(_ id: String, appType: String) -> Bool {
        guard FileManager.default.fileExists(atPath: Self.dbPath) else { return false }
        let db = try? DB(path: Self.dbPath)
        return (try? db?.scalar("SELECT count(*) FROM providers WHERE id=? AND app_type=?", [id, appType])) == "1"
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
        var obj = try loadJSONForWrite(Self.switchSettingsPath)
        let key = currentKey(appType)
        if let id { obj[key] = id } else { obj.removeValue(forKey: key) }
        try writeJSON(obj, to: Self.switchSettingsPath)
    }

    private func mergeEnvIntoClaudeSettings(_ env: [String: String]) throws {
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
