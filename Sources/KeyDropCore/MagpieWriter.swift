import Foundation
import CryptoKit
import Darwin

/// 本机通过官方 CLI 写入，由 Magpie 自己加锁并通知网关；显式 Web 链接使用管理 API。
public enum MagpieWriter {
    /// A write may have reached Magpie even when its acknowledgement/readback failed.
    /// Callers use this metadata to retain deletion responsibility without claiming success.
    public struct SyncFailure: LocalizedError {
        public let message: String
        public let providerMayExist: Bool
        public let destinationID: String?
        public var errorDescription: String? { message }

        fileprivate init(message: String, providerMayExist: Bool, destinationID: String?) {
            self.message = message
            self.providerMayExist = providerMayExist
            self.destinationID = destinationID
        }
    }

    public struct Config {
        public let baseURL: String
        public let webKey: String
    }

    public struct ProviderState {
        let baseURL: String
        let key: String
        let models: [String]
        let apiStyle: String?
    }

    private static func matches(_ row: [String: Any], _ state: ProviderState, web: WebClient? = nil) throws -> Bool {
        let urls = try endpoints(state.baseURL, apiStyle: state.apiStyle)
        let selected = row["chosen"] as? [String] ?? row["models"] as? [String] ?? []
        guard Set(selected) == Set(state.models),
              ["chat", "responses", "anthropic"].allSatisfy({ (row[$0] as? String ?? "") == urls[$0] }) else { return false }
        // 列表里的掩码不能验证密钥轮换，也不能用于决定是否覆盖另一个写入者。
        if let web, let id = row["id"] as? String {
            return try web.providerKey(id: id) == state.key
        }
        return row["key"] as? String == state.key
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
        func providerKey(id: String) throws -> String {
            let obj = try request("/api/provider/key", body: ["id": id])
            guard let key = obj["key"] as? String else {
                throw WriterError.file("Magpie 未返回可核验的 provider 凭据")
            }
            return key
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

    /// Compensate a failed first-time Web write only after proving the row still has
    /// the exact URL, secret, and model set KeyDrop attempted to create. A changed or
    /// unverifiable row is left untouched and reported as potentially present. Magpie's
    /// Web API only deletes by ID, not by an expected-state condition, so another client
    /// can still update the row between this readback and delete; the destination lock
    /// serializes KeyDrop writers, but that external race cannot be made atomic here.
    private static func compensateWebCreate(_ web: WebClient, id: String, state: ProviderState) -> Bool {
        do {
            guard let row = try web.providers().first(where: { $0["id"] as? String == id }) else { return true }
            guard try matches(row, state, web: web) else { return false }
            _ = try web.request("/api/provider/delete", body: ["id": id])
            return try !web.providers().contains(where: { $0["id"] as? String == id })
        } catch {
            return false
        }
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

    /// 本地配置根或远端管理地址的摘要；不包含管理凭据，换登录 key 不改变实例归属。
    public static func destinationID() throws -> String {
        let link = (Prefs.shared.magpieWebLink ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return try destinationID(link: link)
    }

    private static func destinationID(link: String) throws -> String {
        let destination: String
        if link.isEmpty {
            destination = "local:" + URL(fileURLWithPath: configRoot).standardizedFileURL.resolvingSymlinksInPath().path
        } else {
            guard let config = parseWebLink(link) else { throw WriterError.file("Magpie Web 链接无效") }
            destination = "web:" + config.baseURL
        }
        return SHA256.hash(data: Data(destination.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func withDestination<T>(expected: String? = nil, _ body: (WebClient?, String?) throws -> T) throws -> T {
        let link = (Prefs.shared.magpieWebLink ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let expected, try destinationID(link: link) != expected {
            throw WriterError.file("Magpie 实例已切换，此记录仍绑定原实例。请恢复原 Magpie 设置后重试；原配置的清理责任已保留")
        }
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
                            models: [String], apiStyle: String? = nil, expectedDestinationID: String? = nil,
                            onlyIfMatches: ProviderState? = nil) throws -> String {
        guard providerID.range(of: "^[a-zA-Z0-9-]+$", options: .regularExpression) != nil,
              !key.isEmpty, !models.isEmpty,
              models.allSatisfy({ !$0.isEmpty && !$0.contains(",") && !$0.contains("\n") }) else {
            throw WriterError.file("Magpie 导入需要有效的记录 ID、key 和模型列表")
        }
        let endpoints = try endpoints(baseURL, apiStyle: apiStyle)
        return try withDestination(expected: expectedDestinationID) { web, executable in
            let rows = try web?.providers() ?? localProviders()
            let existing = try owned(rows, providerID: providerID)
            if let onlyIfMatches {
                guard let existing, try matches(existing, onlyIfMatches, web: web) else {
                    throw WriterError.file("Magpie 配置已被其他写入方修改或无法确认凭据，已停止回滚，请检查后重试")
                }
            }
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
                let desired = ProviderState(baseURL: baseURL, key: key, models: models, apiStyle: apiStyle)
                do {
                    _ = try web.request("/api/provider/save", body: payload)
                    guard let saved = try web.providers().first(where: { $0["id"] as? String == id }),
                          try matches(saved, desired, web: web) else {
                        throw WriterError.file("Magpie 写入未确认，请检查 Magpie 界面")
                    }
                } catch {
                    if existing == nil {
                        let removed = compensateWebCreate(web, id: id, state: desired)
                        let detail = removed
                            ? "\(error.localizedDescription)；新建 provider 已安全回滚"
                            : "\(error.localizedDescription)；新建 provider 状态无法确认，已保留清理责任"
                        throw SyncFailure(message: detail, providerMayExist: !removed,
                                          destinationID: expectedDestinationID ?? (try? destinationID()))
                    }
                    // An update can have committed before its acknowledgement failed.
                    // Preserve ownership and never delete/restore over the existing row here.
                    throw SyncFailure(message: error.localizedDescription, providerMayExist: true,
                                      destinationID: expectedDestinationID ?? (try? destinationID()))
                }
            } else if let executable {
                var args = existing == nil ? ["provider", "add", name, "id=" + id] : ["provider", "set", id, "name=" + name]
                args += ["key=" + key, "models=" + models.joined(separator: ",")]
                args += ["chat", "responses", "anthropic"].map { $0 + "=" + endpoints[$0]! }
                // 命令可能先落盘、后在通知网关阶段失败。读回完整字段后再决定结果。
                var commandError: Error?
                do { try runCLI(executable, args, secret: key) } catch { commandError = error }
                let saved: [String: Any]?
                do { saved = try localProviders().first(where: { $0["id"] as? String == id }) }
                catch {
                    throw SyncFailure(message: commandError?.localizedDescription ?? error.localizedDescription,
                                      providerMayExist: true,
                                      destinationID: expectedDestinationID ?? (try? destinationID()))
                }
                guard let saved else {
                    throw commandError ?? WriterError.file("Magpie 写入后核验失败，请检查 Magpie 的 provider 配置")
                }
                let stateMatches = saved["key"] as? String == key
                    && Set(saved["models"] as? [String] ?? []) == Set(models)
                    && ["chat", "responses", "anthropic"].allSatisfy({ (saved[$0] as? String ?? "") == endpoints[$0] })
                guard stateMatches else {
                    throw SyncFailure(message: commandError?.localizedDescription
                                      ?? "Magpie 写入后核验失败，请检查 Magpie 的 provider 配置",
                                      providerMayExist: true,
                                      destinationID: expectedDestinationID ?? (try? destinationID()))
                }
            }
            return "已\(existing == nil ? "新建" : "更新") provider「\(name)」(\(models.count) 个模型)"
        }
    }

    public static func remove(providerID: String, expectedDestinationID: String? = nil,
                              onlyIfMatches: ProviderState? = nil) throws -> String {
        try withDestination(expected: expectedDestinationID) { web, executable in
            let rows = try web?.providers() ?? localProviders()
            guard let target = try owned(rows, providerID: providerID), let id = target["id"] as? String else { return "" }
            if let onlyIfMatches, try !matches(target, onlyIfMatches, web: web) {
                throw WriterError.file("Magpie 配置已被其他写入方修改，已停止回滚，请检查后重试")
            }
            var commandError: Error?
            do {
                if let web { _ = try web.request("/api/provider/delete", body: ["id": id]) }
                else if let executable { try runCLI(executable, ["provider", "rm", id]) }
            } catch { commandError = error }
            let remaining = try web?.providers() ?? localProviders()
            guard !remaining.contains(where: { $0["id"] as? String == id }) else {
                throw commandError ?? WriterError.file("Magpie 删除未确认，请重试")
            }
            return "已移除「\(target["name"] as? String ?? id)」"
        }
    }
}
