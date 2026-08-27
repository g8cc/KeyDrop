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

    /// openai-completions 语义要求 baseURL 以 /v1 结尾(不带 /v1 的网关会被兜底到网页首页)
    public static func normalizeBaseURL(_ url: String) -> String {
        let u = url.hasSuffix("/") ? String(url.dropLast()) : url
        if u.hasSuffix("/v1") || u.hasSuffix("/api") || u.hasSuffix("/chat/completions") { return u }
        return u + "/v1"
    }

    /// 写入前对现有文件做 .keydrop-bak 备份,手写 YAML 行解析一旦写坏可手动恢复
    /// (与 CPAWriter/config.yaml.keydrop-bak、CCSwitchWriter *.bak 的习惯一致)
    private static func backupFile(_ path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        let bak = path + ".keydrop-bak"
        try? FileManager.default.removeItem(atPath: bak)
        try? FileManager.default.copyItem(atPath: path, toPath: bak)
    }

    /// Appends (or updates) a provider route and its credential.
    public static func add(providerID: String, key: String, url: String, models: [String]) throws -> String {
        let route = routeKey(providerID: providerID)
        let env = envName(providerID: providerID)

        backupFile(settingsPath)
        backupFile(credentialsPath)
        var settings = (try? String(contentsOfFile: settingsPath, encoding: .utf8)) ?? ""
        var creds = (try? String(contentsOfFile: credentialsPath, encoding: .utf8)) ?? ""

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
        }
    }

    /// YAML 标量:普通 URL/模型名/key 保持裸写(兼容既有格式与消费方),
    /// 含空格、引号、#、冒号结尾等会破坏 YAML 解析的形态时转双引号
    public static func yamlScalar(_ s: String) -> String {
        if !s.isEmpty,
           s.range(of: #"^[A-Za-z0-9_\-./:%#=]+$"#, options: .regularExpression) != nil,
           !s.hasPrefix("-"), !s.hasPrefix("?"),
           !s.contains(": "), !s.hasSuffix(":") {
            return s
        }
        let e = s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(e)\""
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

    private static func upsertCredential(_ text: inout String, env: String, value: String) throws {
        let line = "\(env): \(yamlScalar(value))"
        let lines = text.components(separatedBy: "\n")
        var replaced = false
        var out: [String] = []
        for l in lines {
            if l.hasPrefix("\(env):") || l.hasPrefix("\(env): ") {
                out.append(line)
                replaced = true
            } else {
                out.append(l)
            }
        }
        if !replaced {
            if !text.isEmpty, !text.hasSuffix("\n") { out.append("") }
            out.append(line)
        }
        text = out.joined(separator: "\n")
    }

    private static func removeCredential(_ text: inout String, env: String) {
        let lines = text.components(separatedBy: "\n")
        text = lines.filter { !($0.hasPrefix("\(env):") || $0.hasPrefix("\(env): ")) }
            .joined(separator: "\n")
    }
}