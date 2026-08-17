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

    /// Appends (or updates) a provider route and its credential.
    public static func add(providerID: String, key: String, url: String, models: [String]) throws -> String {
        let route = routeKey(providerID: providerID)
        let env = envName(providerID: providerID)

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
        try settings.write(toFile: settingsPath, atomically: true, encoding: .utf8)
        try creds.write(toFile: credentialsPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credentialsPath)
        return route
    }

    /// Removes the provider route and its credential.
    public static func remove(providerID: String) throws {
        let route = routeKey(providerID: providerID)
        let env = envName(providerID: providerID)

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
        b += "      baseURL: \(normalizeBaseURL(url))\n"
        b += "      models:\n"
        for m in models {
            b += "        - id: \(m)\n"
            b += "          name: \(m)\n"
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
        let line = "\(env): \(value)"
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