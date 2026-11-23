import Foundation
import CryptoKit
import Darwin

/// 本机通过官方 CLI 写入，由 Magpie 自己加锁并通知网关；显式 Web 链接使用管理 API。
public enum MagpieWriter {
    public struct Config {
        public let baseURL: String
        public let webKey: String
    }

    public static func parseWebLink(_ raw: String) -> Config? {
        guard var c = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(c.scheme?.lowercased() ?? ""),
              c.host?.isEmpty == false, c.user == nil, c.password == nil,
              let key = c.queryItems?.first(where: { $0.name == "k" })?.value, !key.isEmpty else { return nil }
        c.query = nil; c.fragment = nil
        while c.path.hasSuffix("/") { c.path.removeLast() }
        guard let base = c.url?.absoluteString else { return nil }
        return Config(baseURL: base, webKey: key)
    }

    public static func configured() -> Config? { parseWebLink(Prefs.shared.magpieWebLink ?? "") }

    public static func localExecutable() -> String? {
        let env = ProcessInfo.processInfo.environment
        let candidates: [String]
        // 显式覆盖即使不存在也不能回落到本机安装（测试隔离）。
        if let override = env["KEYDROP_MAGPIE_BIN"] { candidates = [override] }
        else {
            candidates = ["/Applications/magpie.app/Contents/MacOS/magpie",
                          NSHomeDirectory() + "/Applications/magpie.app/Contents/MacOS/magpie",
                          "/opt/homebrew/bin/magpie", "/usr/local/bin/magpie"]
                + (env["PATH"] ?? "").split(separator: ":").map { String($0) + "/magpie" }
        }
        return candidates.first { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static var configRoot: String {
        let env = ProcessInfo.processInfo.environment
        return env["KEYDROP_MAGPIE_CONFIG_HOME"] ?? env["XDG_CONFIG_HOME"] ?? NSHomeDirectory() + "/.config"
    }

    private static func localProviders() throws -> [[String: Any]] {
        let path = configRoot + "/magpie/providers.json"
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj.keys.contains("providers") else { throw WriterError.file("providers 字段缺失") }
            if obj["providers"] is NSNull { return [] }
            guard let rows = obj["providers"] as? [[String: Any]] else { throw WriterError.file("providers 格式错误") }
            return rows
        } catch { throw WriterError.file("Magpie providers.json 无法读取，已停止写入: \(error.localizedDescription)") }
    }

    private static func runCLI(_ executable: String, _ args: [String], secret: String = "") throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["XDG_CONFIG_HOME"] = configRoot
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = pipe
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        // 持续排空，避免 CLI 输出填满管道。只留有限的错误信息，不记录命令参数。
        let readDone = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var output = Data()
        DispatchQueue.global(qos: .utility).async {
            while true {
                let data = pipe.fileHandleForReading.availableData
                if data.isEmpty { break }
                lock.lock()
                if output.count < 8192 { output.append(data.prefix(8192 - output.count)) }
                lock.unlock()
            }
            readDone.signal()
        }
        if done.wait(timeout: .now() + 25) == .timedOut {
            process.terminate()
            if done.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = done.wait(timeout: .now() + 2)
            }
            throw WriterError.file("Magpie 命令超时，请确认状态后重试（重复导入会更新原记录）")
        }
        _ = readDone.wait(timeout: .now() + 2)
        if process.terminationStatus != 0 {
            lock.lock(); let data = output; lock.unlock()
            var message = String(data: data, encoding: .utf8) ?? ""
            if !secret.isEmpty { message = message.replacingOccurrences(of: secret, with: "<已隐藏>") }
            throw WriterError.file("Magpie 命令失败(\(process.terminationStatus)): \(message.prefix(600))")
        }
    }

    /// 独立会话避免沿用旧 key 的 cookie；禁止重定向携带管理凭据或 provider key。
    private final class WebClient: NSObject, URLSessionTaskDelegate {
        let config: Config
        var cookie: String?
        lazy var session: URLSession = {
            let c = URLSessionConfiguration.ephemeral
            c.httpShouldSetCookies = false
            c.timeoutIntervalForRequest = 15; c.timeoutIntervalForResource = 25
            return URLSession(configuration: c, delegate: self, delegateQueue: nil)
        }()
        init(_ config: Config) { self.config = config }
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }

        func login() throws {
            var c = URLComponents(string: config.baseURL + "/")!
            c.queryItems = [URLQueryItem(name: "k", value: config.webKey)]
            let result = NetSync.run(session: session, url: c.url!, timeout: 15)
            guard let response = result.response as? HTTPURLResponse,
                  [200, 302, 303].contains(response.statusCode) else {
                throw WriterError.file("Magpie 登录失败，请确认 Web 管理页已开启且链接有效")
            }
            var headers: [String: String] = [:]
            for (key, value) in response.allHeaderFields { headers[String(describing: key)] = String(describing: value) }
            let values = HTTPCookie.cookies(withResponseHeaderFields: headers, for: c.url!)
            guard !values.isEmpty else {
                throw WriterError.file("Magpie 未返回登录凭证；请填写 Web 管理链接，不能使用模型网关地址")
            }
            cookie = values.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        }

        func request(_ path: String, body: [String: Any]? = nil) throws -> [String: Any] {
            var req = URLRequest(url: URL(string: config.baseURL + path)!)
            req.httpMethod = body == nil ? "GET" : "POST"
            req.setValue(cookie, forHTTPHeaderField: "Cookie")
            if let body {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
            let result = NetSync.run(session: session, request: req, timeout: 15)
            guard NetSync.statusCode(result) == 200 else {
                throw WriterError.file("Magpie 请求失败(HTTP \(NetSync.statusCode(result)))，请检查 Web 链接及管理页状态")
            }
            guard let data = result.data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], obj["error"] == nil else {
                throw WriterError.file("Magpie 返回无效响应(\(path))")
            }
            return obj
        }
        func providers() throws -> [[String: Any]] {
            let obj = try request("/api/providers")
            if obj["providers"] is NSNull { return [] }
            guard let rows = obj["providers"] as? [[String: Any]] else { throw WriterError.file("Magpie 响应缺 providers 列表") }
            return rows
        }
    }

    public static func providerName(providerID: String, baseURL: String) -> String {
        let host = (URL(string: baseURL)?.host ?? "unknown").lowercased()
        return "KeyDrop-\(String(providerID.prefix(8)))-\(host)"
    }

    private static func owned(_ rows: [[String: Any]], providerID: String) throws -> [String: Any]? {
        let id = "keydrop-" + providerID.lowercased()
        if let row = rows.first(where: { $0["id"] as? String == id }) { return row }
        // 兼容旧 writer 的短 ID，绝不仅靠显示名认领用户的 provider。
        let legacy = rows.filter {
            $0["id"] as? String == "keydrop-" + providerID.prefix(8).lowercased()
                && ($0["name"] as? String ?? "").hasPrefix("KeyDrop-\(providerID.prefix(8))-")
        }
        if legacy.count > 1 { throw WriterError.file("Magpie 旧记录存在冲突，请先检查重复 provider") }
        return legacy.first
    }

    /// 只声明识别出的协议，其他客户端协议由 Magpie 转换。
    private static func endpoints(_ baseURL: String, apiStyle: String?) throws -> [String: String] {
        guard var c = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(c.scheme?.lowercased() ?? ""), c.host?.isEmpty == false,
              c.query == nil, c.fragment == nil, c.user == nil, c.password == nil else {
            throw WriterError.file("Magpie 上游地址无效")
        }
        var path = c.path
        while path.hasSuffix("/") { path.removeLast() }
        let style = apiStyle ?? (path.hasSuffix("/messages") ? "anthropic" : path.hasSuffix("/responses") ? "responses" : "openai")
        for suffix in ["/chat/completions", "/responses", "/messages", "/models"] where path.hasSuffix(suffix) {
            path = String(path.dropLast(suffix.count)); break
        }
        let version = path.range(of: "/v[0-9]+(beta[0-9]*)?$", options: .regularExpression)
        let field: String
        if style == "anthropic" {
            field = "anthropic"
            if let version { path = String(path[..<version.lowerBound]) }
        } else {
            field = style == "responses" ? "responses" : "chat"
            if version == nil { path += "/v1" }
        }
        c.path = path
        guard let url = c.url?.absoluteString else { throw WriterError.file("Magpie 上游地址无效") }
        return ["chat": field == "chat" ? url : "", "responses": field == "responses" ? url : "",
                "anthropic": field == "anthropic" ? url : "", "baseAPI": field]
    }

    private static func withDestination<T>(_ body: (WebClient?, String?) throws -> T) throws -> T {
        let link = (Prefs.shared.magpieWebLink ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let cfg = link.isEmpty ? nil : parseWebLink(link)
        if !link.isEmpty && cfg == nil { throw WriterError.file("Magpie Web 链接无效，请粘贴含 ?k= 的完整链接或清空以使用本机") }
        let executable = cfg == nil ? localExecutable() : nil
        guard cfg != nil || executable != nil else {
            throw WriterError.file("未找到本机 Magpie，请安装 Magpie，或在「Magpie 设置」填写 Web 管理链接")
        }
        let home = ProcessInfo.processInfo.environment["KEYDROP_HOME"] ?? NSHomeDirectory() + "/.keydrop"
        let destination = cfg?.baseURL ?? configRoot
        let hash = SHA256.hash(data: Data(destination.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return try FileLock.withLock(home + "/magpie-\(hash).lock") {
            let web = cfg.map(WebClient.init)
            defer { web?.session.invalidateAndCancel() }
            try web?.login()
            return try body(web, executable)
        }
    }

    public static func sync(providerID: String, baseURL: String, key: String,
                            models: [String], apiStyle: String? = nil) throws -> String {
        guard providerID.range(of: "^[a-zA-Z0-9-]+$", options: .regularExpression) != nil,
              !key.isEmpty, !models.isEmpty,
              models.allSatisfy({ !$0.isEmpty && !$0.contains(",") && !$0.contains("\n") }) else {
            throw WriterError.file("Magpie 导入需要有效的记录 ID、key 和模型列表")
        }
        let endpoints = try endpoints(baseURL, apiStyle: apiStyle)
        return try withDestination { web, executable in
            let rows = try web?.providers() ?? localProviders()
            let existing = try owned(rows, providerID: providerID)
            let id = existing?["id"] as? String ?? "keydrop-" + providerID.lowercased()
            let name = providerName(providerID: providerID, baseURL: baseURL)
            if let web {
                // 列表中的 key/balanceToken 是展示对象，不能原样回传给要求字符串的 save。
                let editable = Set(["headers", "fallback", "icon", "catalog", "website", "keysUrl",
                                    "balanceURL", "balancePath", "balanceMethod", "modelsURL", "searches",
                                    "pinUpstream", "unredacted", "passUserAgent", "unlisted", "contexts",
                                    "extraBody", "replyHeaders", "routing", "affinity", "sink"])
                var payload = (existing ?? [:]).filter { editable.contains($0.key) }
                for (field, value) in endpoints { payload[field] = value }
                payload["id"] = id; payload["name"] = name; payload["key"] = key
                payload["models"] = models; payload["keyProtocol"] = ""
                _ = try web.request("/api/provider/save", body: payload)
                guard let saved = try web.providers().first(where: { $0["id"] as? String == id }),
                      Set(saved["chosen"] as? [String] ?? saved["models"] as? [String] ?? []) == Set(models),
                      ["chat", "responses", "anthropic"].allSatisfy({ (saved[$0] as? String ?? "") == endpoints[$0] }) else {
                    throw WriterError.file("Magpie 写入未确认，请检查 Magpie 界面")
                }
            } else if let executable {
                var args = existing == nil ? ["provider", "add", name, "id=" + id] : ["provider", "set", id, "name=" + name]
                args += ["key=" + key, "models=" + models.joined(separator: ",")]
                args += ["chat", "responses", "anthropic"].map { $0 + "=" + endpoints[$0]! }
                try runCLI(executable, args, secret: key)
                guard let saved = try localProviders().first(where: { $0["id"] as? String == id }),
                      saved["key"] as? String == key,
                      Set(saved["models"] as? [String] ?? []) == Set(models),
                      ["chat", "responses", "anthropic"].allSatisfy({ (saved[$0] as? String ?? "") == endpoints[$0] }) else {
                    throw WriterError.file("Magpie 写入后核验失败，请检查 Magpie 的 provider 配置")
                }
            }
            return "已\(existing == nil ? "新建" : "更新") provider「\(name)」(\(models.count) 个模型)"
        }
    }

    public static func remove(providerID: String) throws -> String {
        try withDestination { web, executable in
            let rows = try web?.providers() ?? localProviders()
            guard let target = try owned(rows, providerID: providerID), let id = target["id"] as? String else { return "" }
            if let web { _ = try web.request("/api/provider/delete", body: ["id": id]) }
            else if let executable { try runCLI(executable, ["provider", "rm", id]) }
            let remaining = try web?.providers() ?? localProviders()
            guard !remaining.contains(where: { $0["id"] as? String == id }) else { throw WriterError.file("Magpie 删除未确认，请重试") }
            return "已移除「\(target["name"] as? String ?? id)」"
        }
    }
}
