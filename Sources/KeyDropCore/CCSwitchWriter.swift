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
    // ══════════════ 写入层不变量(改动任何写入路径前先读这里)══════════════
    // ① 家族不变量:目标 app 与激活模型必须同家族。claude 配置只写 claude 系模型,
    //    codex 只写 gpt 系。模型列表经常跨家族(网关 /models 全量返回、refresh 整体
    //    替换),家族过滤必须收敛在写入层(claudeEnv / resolveCodexModel),
    //    不能依赖调用方传对。无同家族模型时:claude 省略模型键(回退默认),
    //    codex 保留原 model 行;全新 codex 模板不写 model 行。
    // ② 账本不变量:HistoryEntry.targets 的每个 tag 必须对应一个真实存在的外部产物,
    //    且 delete/reconcile 能凭 tag + ccProviderID 认领并清理它。
    //    外部写入失败时不得丢 tag(旧产物还在);回滚/清理成功时不得并 tag(产物已删)。
    // 场景测试:TestSuite/RegressionTests.swift(写入不变量矩阵 / 账本闭环 add→delete)。
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

        // 不要在 DB 事务前缓存运行态:cc-switch 可能恰好在导入期间启动。
        // Claude live 配置的最终写入点会再次检查当前运行态,避免竞态窗口把新 provider
        // 的环境写入 cc-switch 仍缓存的旧 current。
        let db = try DB(path: Self.dbPath)
        try db.exec("BEGIN IMMEDIATE")
        var dedupReplacedID: String? = nil
        do {
            if appType == "opencode" || appType == "codex" {
                let normURL = appType == "opencode" ? opencodeBaseURL(url) : normalizeEndpointURL(url)
                // endpoint url 可能带或不带 /v1/尾部斜杠,规范化后比较
                let candidates = try db.query(
                    "SELECT p.id, e.url, p.settings_config FROM providers p JOIN provider_endpoints e ON p.id=e.provider_id WHERE p.app_type=?",
                    [appType]
                )
                let sameURL = candidates.filter { row in
                    guard row.count > 1, let u = row[1] else { return false }
                    return normalizeEndpointURL(u) == normURL
                }
                // 同 URL 同 key 才是同一凭据的重复导入 → 删除重建(幂等)。
                // 同 URL 不同 key 是多凭据共存:绝不能删旧 provider,否则
                // ① 旧 key 的可用凭据被新导入静默覆盖,② 历史里旧 entry 的
                // ccProviderID 指向已删 provider,变成 delete/reconcile 认领不了的孤儿
                let existing = sameURL.first { row in
                    guard row.count > 2 else { return false }
                    return Self.providerAPIKey(from: row[2] ?? "", appType: appType) == key
                }
                if let id = existing?[0] {
                    try db.run("DELETE FROM provider_endpoints WHERE provider_id=?", [id])
                    try db.run("DELETE FROM providers WHERE id=?", [id])
                    dedupReplacedID = id
                }
            }
            // cc-switch sorts by COALESCE(sort_index, 999999), then created_at ASC.
            // NULL therefore goes to the end regardless of is_current. Shift the
            // existing explicit order in this transaction and reserve index 0 for
            // the newly imported provider.
            try db.run(
                "UPDATE providers SET sort_index = sort_index + 1 WHERE app_type = ? AND sort_index IS NOT NULL",
                [appType]
            )
            try db.run(
                """
                INSERT INTO providers
                (id, app_type, name, settings_config, website_url, category,
                 created_at, sort_index, notes, icon, icon_color, meta, is_current, in_failover_queue)
                VALUES (?, ?, ?, ?, NULL, NULL, ?, 0, NULL, NULL, NULL, ?, 1, 0)
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
                // opencode 的「激活默认模型」不得落到图生/嵌入等非 chat 模型上(真实事故:
                // fal-ai/gpt-image-2 + nano-banana 等被 first 当默认)。优先取 chat 家族,
                // 次取非 non-chat;全 non-chat 则不设激活模型并警告(models 字典仍写全列表供手选)
                let activeModel = Core.preferredChatModel(opencodeModels)
                do {
                    try mergeOpencodeProvider(p, providerID: id, modelDict: opencodeDict, firstModel: activeModel)
                    result.directMode = true
                } catch {
                    result.warnings.append("opencode.json 更新失败: \(error.localizedDescription)")
                }
                if activeModel == nil && !opencodeModels.isEmpty {
                    result.warnings.append("所选模型全部为非 chat 模型(图生/嵌入/语音等),未设置激活模型;请在 opencode /model 手动选择对话模型")
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

            // cc-switch 运行时,不直写 live ~/.claude/settings.json。
            // 事故:KeyDrop 写 live=新 provider env 时,cc-switch 的 in-memory current 还是旧 provider;
            // cc-switch 在自身事件(UI 切换/启动)会把当前 live 回写进 current 的 settings_config,
            // 导致旧 provider 的 settings_config 被新 provider 的整块 env 覆盖(url/key/models 全变,
            // endpoint/name 不动)→ 切回旧 provider 即用错配置(已发生多起)。
            // cc-switch 不监听外部 switch-settings / DB is_current 改动(实测 25s 无反应),
            // 所以 KeyDrop 无法靠改 switch-settings 让 cc-switch 应用新 current。
            // 留给 cc-switch 的 UI 切换去激活:DB 已置新 provider is_current=1、
            // switch-settings 的 currentProviderClaude 已更新,用户在 cc-switch 点新 provider 即正确应用。
            // 必须在真正写 live 前再次检查,不能使用 DB 事务开始前的旧快照。
            if Self.ccSwitchRunning() {
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
        // 模型键只接受 claude 系模型。模型列表在 add(网关 ≤5 个模型全量导入)和
        // refresh(网关 /models 全量列表整体替换)两个场景都会混入 gpt 等异家族模型,
        // 盲取 models.first 会把 gpt 写进 Claude Code(真实事故)。
        // 找不到 claude 系模型时省略模型键:Claude Code 回退自身默认模型,
        // 且 mergeEnvIntoClaudeSettings 会清掉不在新 env 里的旧 ANTHROPIC_* 键,不会留残值
        let claudeModel = models.first(where: { !$0.isEmpty && Core.isClaudeModel($0) })
            ?? p.model.flatMap { (!$0.isEmpty && Core.isClaudeModel($0)) ? $0 : nil }
        if let claudeModel {
            let modelKeys = [
                "ANTHROPIC_MODEL", "ANTHROPIC_REASONING_MODEL",
                "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL_NAME",
                "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL_NAME",
                "ANTHROPIC_DEFAULT_HAIKU_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME",
                "ANTHROPIC_DEFAULT_FABLE_MODEL", "ANTHROPIC_DEFAULT_FABLE_MODEL_NAME",
                "CLAUDE_CODE_SUBAGENT_MODEL"
            ]
            for k in modelKeys { env[k] = claudeModel }
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

    /// codex 激活模型:gpt 系优先。与 claudeEnv 同理,混合家族列表不得把
    /// claude 等异家族模型写成 codex 激活模型;nil 表示「不动模型行」
    static func resolveCodexModel(models: [String], parsedModel: String?) -> String? {
        models.first(where: { !$0.isEmpty && Core.isGptModel($0) })
            ?? parsedModel.flatMap { (!$0.isEmpty && Core.isGptModel($0)) ? $0 : nil }
    }

    private func codexConfigToml(_ p: ParsedKey, models: [String], wireApi: String = "responses") throws -> String {
        let url = codexBaseURL(p.url ?? "")
        let model = Self.resolveCodexModel(models: models, parsedModel: p.model)
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
                        if let m = model {
                            out.append("model = \(Self.tomlQuote(m))")
                        } else {
                            // 新列表无 gpt 系模型:保留原 model 行(旧 gpt 模型大概率仍可用),
                            // 绝不能把 claude 等异家族模型写进来
                            out.append(ln)
                        }
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
            if !modelSet, let m = model {
                out.insert("model = \(Self.tomlQuote(m))", at: providerSet ? 1 : 0)
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
        // 全新模板:model 行仅在有 gpt 系模型时写入,否则留给 codex 内置默认
        var fresh = ["model_provider = \"custom\""]
        if let m = model { fresh.append("model = \(Self.tomlQuote(m))") }
        fresh.append(contentsOf: [
            "model_reasoning_effort = \"high\"",
            "",
            "[model_providers.custom]",
            "name = \"custom\"",
            "wire_api = \(Self.tomlQuote(wireApi))",
            "requires_openai_auth = true",
            "base_url = \(Self.tomlQuote(url))",
            "experimental_bearer_token = \(Self.tomlQuote(p.key ?? ""))"
        ])
        return fresh.joined(separator: "\n")
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
            // 与 codexConfigToml 同一解析:无 gpt 系模型时 model 行被保留原样,跳过校验
            let model = Self.resolveCodexModel(models: models, parsedModel: p.model)
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

    /// 从 cc-switch providers.settings_config 提取该 provider 的 API key,
    /// 供「同 URL 不同 key 共存」去重判定。解析失败(用户手工改过的非常规结构)
    /// 返回 nil:与任何 key 都不相等 → 视为不同凭据 → 保留旧 provider,不误删
    static func providerAPIKey(from settingsConfig: String, appType: String) -> String? {
        guard let data = settingsConfig.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        switch appType {
        case "opencode":
            return (obj["options"] as? [String: Any])?["apiKey"] as? String
        case "codex":
            return (obj["auth"] as? [String: Any])?["OPENAI_API_KEY"] as? String
        default:
            let env = obj["env"] as? [String: Any]
            return env?["ANTHROPIC_AUTH_TOKEN"] as? String
        }
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
        // 事务包住两条 INSERT + 可选 demote:repair 此前是无事务裸写,provider 插成功、
        // endpoint 插失败会留下「无 endpoint 行的 provider」——URL 去重查不到它,
        // 且重试在 existing!=nil 处短路,永远补不上。
        // promote 时还必须像 add() 一样把他行 is_current 归零:settings 指针失效但
        // DB 里另一 provider 仍标 current 的场景下,不 demote 会造出双 current
        try db.exec("BEGIN IMMEDIATE")
        do {
            if promote {
                try db.run("UPDATE providers SET is_current = 0 WHERE app_type = ? AND id != ?", [appType, pid])
            }
            try db.run(
                "INSERT INTO providers (id, app_type, name, settings_config, created_at, meta, is_current) VALUES (?,?,?,?,?,?,?)",
                [pid, appType, name, settingsConfig, now, meta, promote ? 1 : 0]
            )
            // endpoint 行与 add() 对齐:cc-switch 界面展示 URL、后续按 URL 去重都依赖它
            try db.run(
                "INSERT INTO provider_endpoints (provider_id, app_type, url, added_at) VALUES (?, ?, ?, ?)",
                [pid, appType, appType == "opencode" ? opencodeBaseURL(url) : url, now]
            )
            try db.exec("COMMIT")
        } catch {
            try? db.exec("ROLLBACK")
            throw error
        }
        if promote {
            try updateSwitchSettings(pid, for: appType)
        }
        // opencode 是共享文件:add()/syncModelsAfterRefresh() 都双写 DB + opencode.json,
        // 重导入若只写 DB,opencode.json 里仍没有该 provider,opencode 看不到这条渠道。
        // 仅当确实重建了当前 provider 时才需要,和 add() 一样 best-effort(失败不阻断 reimport)。
        if appType == "opencode" {
            do {
                try mergeOpencodeProvider(p, providerID: pid, modelDict: opencodeDict, firstModel: Core.preferredChatModel(models))
            } catch {
                AppLog.warn("reimport opencode.json 写入失败: \(error.localizedDescription)")
            }
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
        // cc-switch 运行时由其独占 live,KeyDrop 不染指(同 add() 的事故修复理由)
        guard !Self.ccSwitchRunning() else { return }
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

    // MARK: - CPA 常驻入口(被动同步)

    /// 把 CPA 固定端点被动 upsert 到指定 app_type 的 cc-switch DB:
    /// 匹配「endpoint 规范化 URL + settings_config 内 key」的既有 provider → 原地更新
    /// settings_config(不重复建);没有则新建 is_current=0。
    /// 绝不:改 is_current / 动 switch settings / claude-codex 未激活时写 live 单文件
    /// (那两类是单 provider 环境,覆盖会把用户当前配置的网关悄悄换成 CPA)。
    /// opencode 是共享文件:未激活也同步 provider+models,用户在 /model 直接选新模型,
    /// firstModel 仅当该 provider 恰好当前激活时才设(不抢激活)。
    /// models 为空视为「CPA 未响应,未获取」,直接跳过,绝不把已有列表清空。
    @discardableResult
    public func syncCPAResident(appType: String, baseURL: String, clientKey: String, models: [String]) throws -> String {
        guard !models.isEmpty else { return "跳过(CPA 模型列表未获取)" }
        try Self.ensureDB()
        let db = try DB(path: Self.dbPath)
        let normURL = normalizeEndpointURL(baseURL)
        var p = ParsedKey()
        p.url = baseURL
        p.key = clientKey

        // 既有匹配:所有候选里找 URL+key 双一致的第一个
        let rows = try db.query(
            "SELECT p.id, e.url, p.settings_config FROM providers p JOIN provider_endpoints e ON p.id=e.provider_id WHERE p.app_type=?",
            [appType]
        )
        var existingID: String? = nil
        for row in rows {
            guard row.count > 2, let pid = row[0], let u = row[1],
                  normalizeEndpointURL(u) == normURL,
                  Self.providerAPIKey(from: row[2] ?? "", appType: appType) == clientKey
            else { continue }
            existingID = pid
            break
        }

        let id = existingID ?? UUID().uuidString.lowercased()
        let opencodeDict = opencodeModelDict(providerID: id, baseURL: baseURL, models: models)
        let settingsConfig: String
        if appType == "opencode" {
            settingsConfig = try opencodeSettingsConfig(p, modelDict: opencodeDict)
        } else if appType == "codex" {
            settingsConfig = try codexSettingsConfig(p, models: models, wireApi: "responses")
        } else {
            settingsConfig = try jsonString(["env": claudeEnv(for: p, models: models)])
        }

        if let existing = existingID {
            try db.run(
                "UPDATE providers SET settings_config = ? WHERE id = ? AND app_type = ?",
                [settingsConfig, existing, appType]
            )
            let isCurrent = (try? db.scalar(
                "SELECT is_current FROM providers WHERE id = ? AND app_type = ?",
                [existing, appType]
            )) == "1"
            if appType == "opencode" {
                try mergeOpencodeProvider(p, providerID: existing, modelDict: opencodeDict,
                                          firstModel: isCurrent ? Core.preferredChatModel(models) : nil)
            } else if isCurrent {
                try syncResidentLive(appType: appType, p: p, models: models)
            }
            return "已更新"
        }

        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let meta = appType == "codex"
            ? "{\"commonConfigEnabled\":false,\"endpointAutoSelect\":true,\"apiFormat\":\"openai_responses\"}"
            : "{}"
        try db.exec("BEGIN IMMEDIATE")
        do {
            // is_current=0:被动入口不抢激活;sort_index NULL:不打扰用户在 cc-switch 里的手动排序
            try db.run(
                "INSERT INTO providers (id, app_type, name, settings_config, created_at, meta, is_current) VALUES (?,?,?,?,?,?,0)",
                [id, appType, residentName(for: baseURL), settingsConfig, now, meta]
            )
            try db.run(
                "INSERT INTO provider_endpoints (provider_id, app_type, url, added_at) VALUES (?, ?, ?, ?)",
                [id, appType, appType == "opencode" ? opencodeBaseURL(baseURL) : baseURL, now]
            )
            try db.exec("COMMIT")
        } catch {
            try? db.exec("ROLLBACK")
            throw error
        }
        if appType == "opencode" {
            try mergeOpencodeProvider(p, providerID: id, modelDict: opencodeDict, firstModel: nil)
        }
        return "已新建(未激活)"
    }

    /// 被动入口恰好是当前激活 provider 时,新模型列表同步进 live 配置,
    /// 守卫口径与 syncModelsAfterRefresh 一致(代理托管态/ cc-switch 运行中不直写)
    private func syncResidentLive(appType: String, p: ParsedKey, models: [String]) throws {
        switch appType {
        case "codex":
            let proxied = (try? String(contentsOfFile: Self.codexConfigPath, encoding: .utf8))
                .flatMap { c -> Bool in
                    let custom = c.components(separatedBy: "[model_providers.custom]").dropFirst().first ?? ""
                    return custom.contains("PROXY_MANAGED") || custom.contains("127.0.0.1:15721")
                } ?? false
            if !proxied { try mergeCodexConfig(p, models: models, wireApi: "responses") }
        default:
            guard !Self.ccSwitchRunning() else { return }
            try mergeEnvIntoClaudeSettings(claudeEnv(for: p, models: models))
        }
    }

    private func residentName(for baseURL: String) -> String {
        let host = baseURL.replacingOccurrences(of: #"^https?://"#, with: "", options: .regularExpression)
        return "CPA·\(host)"
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
            try mergeOpencodeProvider(p, providerID: providerID, modelDict: opencodeDict, firstModel: Core.preferredChatModel(models))
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
            // 同 add():cc-switch 运行时不直写 live,避免其把 live 回写进陈旧 current 的
            // settings_config 造成腐败。仅 KeyDrop 独占 live(cc-switch 未运行)时才写。
            guard !Self.ccSwitchRunning() else { return }
            try mergeEnvIntoClaudeSettings(claudeEnv(for: p, models: models))
        }
    }

    public func providerExists(_ id: String, appType: String) -> Bool {
        providerExists(id: id, appType: appType)
    }

    static public func ccSwitchRunning() -> Bool {
        if ProcessInfo.processInfo.environment["KEYDROP_FAKE_CC_RUNNING"] == "1" { return true }
        if ProcessInfo.processInfo.environment["KEYDROP_FAKE_CC_RUNNING"] == "0" { return false }

        // 官方 macOS bundle id 是 com.ccswitch.desktop。不同安装渠道/旧版本可能只保留
        // 可执行文件名,所以同时按 bundle id、进程名和可执行文件名识别。
        // 这里宁可少写一次 live 配置,也不能在 cc-switch 已运行但未被精确识别时覆盖
        // 它正在管理的 Claude 配置,否则会触发旧 provider 的 settings_config 回写污染。
        return NSWorkspace.shared.runningApplications.contains { app in
            if app.bundleIdentifier == "com.ccswitch.desktop" { return true }
            let names = [app.localizedName, app.executableURL?.lastPathComponent]
                .compactMap { $0?.lowercased() }
            return names.contains { name in
                name == "cc-switch" || name == "cc switch" || name == "ccswitch"
            }
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
        // cc-switch 运行时由其独占 live,KeyDrop 不染指(同 add() 的事故修复理由)
        guard !Self.ccSwitchRunning() else { return }
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
