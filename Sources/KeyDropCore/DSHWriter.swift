import Foundation

/// Writes providers into DeepSeek Harness (`$DSH_HOME/settings.yaml`) and API
/// keys into `$DSH_HOME/.credentials.yaml`. Route keys are `keydrop-<id prefix>`
/// so entries stay trackable from KeyDrop history.
public enum DSHWriter {
    static var dshHome: String {
        ProcessInfo.processInfo.environment["DSH_HOME"]
            ?? (NSHomeDirectory() + "/.dsh")
    }
    static var settingsPath: String {
        ProcessInfo.processInfo.environment["KEYDROP_DSH_SETTINGS"]
            ?? (dshHome + "/settings.yaml")
    }
    static var credentialsPath: String {
        ProcessInfo.processInfo.environment["KEYDROP_DSH_CREDENTIALS"]
            ?? (dshHome + "/.credentials.yaml")
    }

    public static func routeKey(providerID: String) -> String {
        "keydrop-" + String(providerID.prefix(8))
    }
    public static func envName(providerID: String) -> String {
        "KEYDROP_" + String(providerID.prefix(8)).uppercased() + "_API_KEY"
    }

    public static func isDeepseekModel(_ m: String) -> Bool {
        m.lowercased().contains("deepseek")
    }

    /// openai-completions 语义要求 baseURL 以 /v1 结尾(不带 /v1 的网关会被兜底到网页首页)。
    /// 但已经带版本段的地址不能再追加:/api/v3(火山 ark)、/api/paas/v4(智谱)、
    /// /v1beta/openai(gemini) 这类拼上 /v1 会变成不存在的路径,DSH 请求 404。
    public static func normalizeBaseURL(_ url: String) -> String {
        let u = url.hasSuffix("/") ? String(url.dropLast()) : url
        if u.hasSuffix("/chat/completions") { return u }
        let path = URL(string: u)?.path ?? ""
        // 路径里已含 /v<数字> 版本段(含 v1beta)或 /api 结尾 → 视为完整 baseURL
        if path.range(of: #"/v[0-9]"#, options: .regularExpression) != nil { return u }
        if path.hasSuffix("/api") { return u }
        return u + "/v1"
    }

    /// 写入前对现有文件做 .keydrop-bak 备份,手写 YAML 行解析一旦写坏可手动恢复
    /// (与 CPAWriter/config.yaml.keydrop-bak、CCSwitchWriter *.bak 的习惯一致)
    private static func backupFile(_ path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        let bak = path + ".keydrop-bak"
        try? FileManager.default.removeItem(atPath: bak)
        do { try FileManager.default.copyItem(atPath: path, toPath: bak) }
        catch { AppLog.warn("DSH 备份失败(\(path)): \(error.localizedDescription)") }
    }

    /// 读取已存在文件:不存在返回空串;存在但读取/解码失败则抛错。
    /// 不能用 `try? String(...) ?? ""` —— 那会把「读失败」当成「空文件」,
    /// 随后的整体覆盖写会清空文件里其它 provider 的配置与明文 key。
    private static func readExisting(_ path: String) throws -> String {
        guard FileManager.default.fileExists(atPath: path) else { return "" }
        do { return try String(contentsOfFile: path, encoding: .utf8) }
        catch { throw WriterError.file("读取失败,拒绝覆盖: \(path)(\(error.localizedDescription))") }
    }

    /// Appends (or updates) a provider route and its credential.
    public static func add(providerID: String, key: String, url: String, models: [String]) throws -> String {
        // flock 串行化两个文件的读改写:CLI 与 app 并发时后写者会抹掉前写者的 route,
        // add/remove 交错还会留下「settings 有引用、creds 已删」的半成品
        try FileLock.withLock(FileLock.lockPath(for: settingsPath)) {
            try addLocked(providerID: providerID, key: key, url: url, models: models)
        }
    }

    private static func addLocked(providerID: String, key: String, url: String, models: [String]) throws -> String {
        let route = routeKey(providerID: providerID)
        let env = envName(providerID: providerID)

        backupFile(settingsPath)
        backupFile(credentialsPath)
        var settings = try readExisting(settingsPath)
        var creds = try readExisting(credentialsPath)

        removeRoute(&settings, route: route)
        removeCredential(&creds, env: env)
        try upsertSettings(&settings, route: route, env: env, url: url, models: models)
        try upsertCredential(&creds, env: env, value: key)

        try FileManager.default.createDirectory(
            atPath: URL(fileURLWithPath: settingsPath).deletingLastPathComponent().path,
            withIntermediateDirectories: true
        )
        // 写入顺序:creds(被引用方)先写,settings(引用方)后写。
        // 反过来时 settings 写成功而 creds 失败会留下引用不存在 env 的半成品,DSH 启动报错;
        // creds 先写失败则 settings 未动,多一个未被引用的 env 无害。
        try creds.write(toFile: credentialsPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credentialsPath)
        try settings.write(toFile: settingsPath, atomically: true, encoding: .utf8)
        return route
    }

    /// Removes the provider route and its credential.
    public static func remove(providerID: String) throws {
        try FileLock.withLock(FileLock.lockPath(for: settingsPath)) {
            try removeLocked(providerID: providerID)
        }
    }

    private static func removeLocked(providerID: String) throws {
        let route = routeKey(providerID: providerID)
        let env = envName(providerID: providerID)

        backupFile(settingsPath)
        backupFile(credentialsPath)
        if FileManager.default.fileExists(atPath: settingsPath),
           var settings = try? String(contentsOfFile: settingsPath, encoding: .utf8) {
            removeRoute(&settings, route: route)
            try settings.write(toFile: settingsPath, atomically: true, encoding: .utf8)
        }
        if FileManager.default.fileExists(atPath: credentialsPath),
           var creds = try? String(contentsOfFile: credentialsPath, encoding: .utf8) {
            removeCredential(&creds, env: env)
            try creds.write(toFile: credentialsPath, atomically: true, encoding: .utf8)
            // 原子写=临时文件+rename,新文件继承 umask(通常 0644),会把 add 时设置的
            // 0600 重置成全员可读 —— 凭证文件里还有其他 provider 的明文 key,必须重设权限
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credentialsPath)
        }
    }

    /// YAML 标量:普通 URL/模型名/key 保持裸写(兼容既有格式与消费方),
    /// 含空格、引号、#、冒号结尾等会破坏 YAML 解析的形态时转双引号
    public static func yamlScalar(_ s: String) -> String {
        if !s.isEmpty,
           s.range(of: #"^[A-Za-z0-9_\-./:%#=]+$"#, options: .regularExpression) != nil,
           !s.hasPrefix("-"), !s.hasPrefix("?"),
           !s.hasPrefix("#"), !s.hasPrefix("%"), !s.hasPrefix(":"),
           !s.contains(": "), !s.hasSuffix(":") {
            return s
        }
        let e = s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(e)\""
    }

    /// 扫描 settings.yaml,返回所有指向该端点(localhost/127.0.0.1 与尾 /v1 归一)的 route 名。
    /// 调用方据此区分:存在非 keydrop- 前缀的匹配 route = 用户手配,常驻同步不覆盖;
    /// 只有 KeyDrop 自己写的 route → 允许原地更新模型列表
    public static func routesForEndpoint(baseURL: String) -> [String] {
        guard FileManager.default.fileExists(atPath: settingsPath),
              let text = try? String(contentsOfFile: settingsPath, encoding: .utf8)
        else { return [] }
        let u = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        let target = (u.hasSuffix("/v1") ? u : u + "/v1")
            .replacingOccurrences(of: "://127.0.0.1", with: "://localhost")
        let lines = text.components(separatedBy: "\n")
        var out: [String] = []
        var curRoute = ""
        for line in lines {
            // route 名行:恰好 4 空格缩进 + "name:";其属性 baseURL: 6 空格缩进
            if line.hasPrefix("    "), !line.hasPrefix("      ") {
                let t = line.trimmingCharacters(in: .whitespaces)
                curRoute = t.hasSuffix(":") ? String(t.dropLast()) : ""
                continue
            }
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("baseURL:"), !curRoute.isEmpty else { continue }
            let raw = t.dropFirst("baseURL:".count).trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            let norm = (raw.hasSuffix("/v1") ? raw : raw + "/v1")
                .replacingOccurrences(of: "://127.0.0.1", with: "://localhost")
            if norm == target { out.append(curRoute) }
        }
        return out
    }

    public static func installed() -> Bool {
        FileManager.default.fileExists(atPath: dshHome)
    }

    // MARK: - settings.yaml

    private static func upsertSettings(
        _ text: inout String, route: String, env: String, url: String, models: [String]
    ) throws {
        let blockLines = providerBlock(route: route, env: env, url: url, models: models)
            .components(separatedBy: "\n")
        var lines = text.components(separatedBy: "\n")

        if let pi = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "llm-pi-ai:" }) {
            var p: Int? = nil
            var j = pi + 1
            while j < lines.count {
                let l = lines[j]
                if l.isEmpty { j += 1; continue }
                if !l.hasPrefix(" ") { break }
                if l.trimmingCharacters(in: .whitespaces) == "providers:" { p = j }
                j += 1
            }
            if let p {
                var q = p + 1
                while q < lines.count {
                    let l = lines[q]
                    if l.isEmpty { q += 1; continue }
                    if l.hasPrefix("    ") { q += 1; continue }
                    break
                }
                lines.insert(contentsOf: blockLines + [""], at: q)
            } else {
                var q = pi + 1
                while q < lines.count, lines[q].hasPrefix(" ") || lines[q].isEmpty { q += 1 }
                lines.insert(contentsOf: ["  providers:"] + blockLines + [""], at: q)
            }
        } else {
            if !text.isEmpty, !text.hasSuffix("\n") { lines.append("") }
            lines.append(contentsOf: ["llm-pi-ai:", "  providers:"] + blockLines)
        }
        text = lines.joined(separator: "\n")
    }

    private static func providerBlock(route: String, env: String, url: String, models: [String]) -> String {
        var b = "    \(route):\n"
        b += "      apiKeyEnv: \(env)\n"
        b += "      api: openai-completions\n"
        b += "      baseURL: \(yamlScalar(normalizeBaseURL(url)))\n"
        b += "      models:\n"
        for m in models {
            b += "        - id: \(yamlScalar(m))\n"
            b += "          name: \(yamlScalar(m))\n"
        }
        return b
    }

    private static func removeRoute(_ text: inout String, route: String) {
        let lines = text.components(separatedBy: "\n")
        var out: [String] = []
        var skipping = false
        for line in lines {
            if line.hasPrefix("    \(route):") {
                skipping = true
                continue
            }
            if skipping {
                if line.hasPrefix("      ") || line.isEmpty {
                    continue
                }
                skipping = false
            }
            out.append(line)
        }
        text = out.joined(separator: "\n")
    }

    // MARK: - credentials

    /// .credentials.yaml 结构(dsh 的格式):顶层仅 version/refs,凭据必须以 2 空格缩进
    /// 嵌在 refs: 映射内 —— dsh 解析器拒绝未知顶层键,顶层裸写会让 dsh 启动即崩。
    /// (2026-09-25 事故:KEYDROP_07FA1C9C_API_KEY 被顶层裸写;外部只手工缩进了文件,
    /// 写入方若不感知 refs,下一次 upsert 找不到缩进行会再追加一条顶格重复行 → 复崩)
    /// 行为:
    /// - 已有该 env 缩进行 → 原位更新(不动其他条目,含多行标量);
    /// - 顶格遗留行(旧版 bug 产物)→ 顺带清除,凭据统一收敛进 refs;
    /// - 无该 env → 插到 refs 块末尾(下一个顶层键之前/EOF)。块边界按「第一个顶格
    ///   非空行」判定,多行标量的续行(更深缩进)不会误判成边界 → 绝不插进标量中间;
    /// - 空文件/新建 → 落 version:1 + refs: 骨架;非空但无 refs 段(外来文件)→
    ///   末尾补一段 refs 块,不改动既有内容。
    private static func upsertCredential(_ text: inout String, env: String, value: String) throws {
        let entry = "  \(env): \(yamlScalar(value))"
        var lines = text.components(separatedBy: "\n")

        var replaced = false
        var cleaned: [String] = []
        for l in lines {
            if l.hasPrefix("  \(env):") {
                // 只留一份:重复行(历史遗留)一并去重
                if !replaced { cleaned.append(entry); replaced = true }
            } else if l.hasPrefix("\(env):") {
                continue  // 顶格遗留:不保留任何顶格形态
            } else {
                cleaned.append(l)
            }
        }
        lines = cleaned

        if !replaced {
            guard let refsIdx = lines.firstIndex(where: { $0.hasPrefix("refs:") }) else {
                if lines.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                    lines = ["version: 1", "refs:", entry]
                } else {
                    while lines.last?.isEmpty == true { lines.removeLast() }
                    lines.append("refs:")
                    lines.append(entry)
                }
                text = lines.joined(separator: "\n")
                return
            }
            if lines[refsIdx] == "refs: {}" { lines[refsIdx] = "refs:" }
            let blockEnd = lines[(refsIdx + 1)...].firstIndex {
                !$0.isEmpty && !$0.hasPrefix(" ")
            } ?? lines.count
            lines.insert(entry, at: blockEnd)
        }
        text = lines.joined(separator: "\n")
    }

    /// 删除该 env 的凭据行:同时匹配 refs 内缩进行与顶格遗留行(冒号收尾保证
    /// 不会误命中更长 env 名)。refs 块删空时收敛为显式空映射 `refs: {}` ——
    /// 裸 `refs:` 会被 YAML 读成 null,撞 dsh 的映射类型 schema 风险更高。
    private static func removeCredential(_ text: inout String, env: String) {
        var lines = text.components(separatedBy: "\n")
        lines.removeAll { $0.hasPrefix("  \(env):") || $0.hasPrefix("\(env):") }
        if let refsIdx = lines.firstIndex(where: { $0 == "refs:" }) {
            let blockEnd = lines[(refsIdx + 1)...].firstIndex {
                !$0.isEmpty && !$0.hasPrefix(" ")
            } ?? lines.count
            let hasEntry = lines[(refsIdx + 1)..<blockEnd].contains { !$0.isEmpty }
            if !hasEntry { lines[refsIdx] = "refs: {}" }
        }
        text = lines.joined(separator: "\n")
    }
}