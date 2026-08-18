import Foundation

public struct APITestResult {
    public let ok: Bool
    public let style: String
    public let models: [String]
    public let detail: String
    public let authFailed: Bool
    public let needsProxy: Bool
    public init(ok: Bool, style: String, models: [String], detail: String, authFailed: Bool, needsProxy: Bool) {
        self.ok = ok
        self.style = style
        self.models = models
        self.detail = detail
        self.authFailed = authFailed
        self.needsProxy = needsProxy
    }
}

extension APITestResult {
    init(ok: Bool, style: String, models: [String], detail: String, authFailed: Bool) {
        self.init(ok: ok, style: style, models: models, detail: detail, authFailed: authFailed, needsProxy: false)
    }
}

public enum APITester {

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 12
        c.timeoutIntervalForResource = 20
        c.httpMaximumConnectionsPerHost = 2
        // 空字典覆盖系统代理设置 → 真直连测试(真实环境判定)
        c.connectionProxyDictionary = [:]
        return URLSession(configuration: c)
    }()

    /// 代理非空时创建带 connectionProxyDictionary 的独立 session;否则复用默认
    private static func session(for proxy: String?) -> URLSession {
        guard let proxy, !proxy.isEmpty, let url = URL(string: proxy) else { return session }
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 12
        c.timeoutIntervalForResource = 20
        c.httpMaximumConnectionsPerHost = 2
        c.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable: true,
            kCFNetworkProxiesHTTPProxy: url.host ?? "",
            kCFNetworkProxiesHTTPPort: url.port ?? (url.scheme == "https" ? 443 : 80),
            kCFNetworkProxiesHTTPSEnable: true,
            kCFNetworkProxiesHTTPSProxy: url.host ?? "",
            kCFNetworkProxiesHTTPSPort: url.port ?? (url.scheme == "https" ? 443 : 80),
        ]
        return URLSession(configuration: c)
    }

    public static func test(url: String, key: String, timeout: TimeInterval = 12, proxy: String? = nil) -> APITestResult {
        // 先按真实环境(直连)测试;直连失败仅当配置了代理时才补测代理,并标记需代理
        let direct = testOnce(url: url, key: key, timeout: timeout, proxy: nil)
        if direct.ok || direct.authFailed {
            return direct
        }
        let p = proxy?.trimmingCharacters(in: .whitespaces)
        if p == nil || p!.isEmpty {
            return direct
        }
        let via = testOnce(url: url, key: key, timeout: timeout, proxy: p)
        if via.ok {
            return APITestResult(ok: true, style: via.style, models: via.models,
                                 detail: via.detail + " | 直连失败,需代理,经代理验证通过",
                                 authFailed: false, needsProxy: true)
        }
        return via
    }

    private static func testOnce(url: String, key: String, timeout: TimeInterval = 12, proxy: String? = nil) -> APITestResult {
        let base = url.hasSuffix("/") ? String(url.dropLast()) : url
        let candidates = endpointCandidates(base)
        let s = session(for: proxy)

        var lastErr = "无"
        var style = ""
        var authFailed = false
        for ep in candidates {
            guard let u = URL(string: ep) else { continue }
            var req = URLRequest(url: u)
            req.httpMethod = "GET"
            req.timeoutInterval = timeout
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

            let sem = DispatchSemaphore(value: 0)
            var status = 0
            var models: [String] = []
            let task = s.dataTask(with: req) { data, resp, _ in
                defer { sem.signal() }
                status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard let data else { return }
                if status == 200,
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let arr = obj["data"] as? [[String: Any]] {
                    for m in arr {
                        if let id = m["id"] as? String, !id.isEmpty { models.append(id) }
                    }
                }
            }
            task.resume()
            if sem.wait(timeout: .now() + timeout) == .timedOut {
                task.cancel()
            }

            if status == 401 || status == 403 { authFailed = true }
            if status == 200 {
                style = "openai"
                return APITestResult(ok: true, style: style, models: models,
                                     detail: "GET \(ep) → 200" + (models.isEmpty ? " (列表为空)" : ", \(models.count) 个模型"),
                                     authFailed: false)
            }
            lastErr = "GET \(ep) → \(status == 0 ? "超时/无响应" : "HTTP \(status)")"
        }

        let anthropic = anthropicTest(base: base, key: key, timeout: timeout, proxy: proxy)
        if anthropic.0 {
            return APITestResult(ok: true, style: "anthropic", models: [],
                                 detail: "\(anthropic.2) (Anthropic 兼容认证通过)",
                                 authFailed: false)
        }
        authFailed = authFailed || anthropic.1
        lastErr += "; \(anthropic.2)"

        let chat = openaiChatTest(base: base, key: key, timeout: timeout, proxy: proxy)
        if chat.0 {
            return APITestResult(ok: true, style: "openai", models: [],
                                 detail: chat.2,
                                 authFailed: false)
        }
        authFailed = authFailed || chat.1
        lastErr += "; \(chat.2)"
        return APITestResult(ok: false, style: style, models: [], detail: lastErr, authFailed: authFailed)
    }

    private static func openaiChatTest(base: String, key: String, timeout: TimeInterval, proxy: String? = nil) -> (Bool, Bool, String) {
        let hasV1 = base.hasSuffix("/v1") || base.hasSuffix("/api/v1")
        let chatPaths = hasV1 ? ["/chat/completions"] : ["/chat/completions", "/v1/chat/completions"]
        let s = session(for: proxy)
        var lastDesc = ""
        for path in chatPaths {
            guard let u = URL(string: base + path) else { continue }
            var req = URLRequest(url: u)
            req.httpMethod = "POST"
            req.timeoutInterval = timeout
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            req.httpBody = try? JSONSerialization.data(withJSONObject: [
                "model": "test",
                "max_tokens": 1,
                "messages": [["role": "user", "content": "ping"]]
            ])
            let sem = DispatchSemaphore(value: 0)
            var status = 0
            var body = ""
            let task = s.dataTask(with: req) { data, resp, _ in
                defer { sem.signal() }
                status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if let d = data { body = String(data: d, encoding: .utf8) ?? "" }
            }
            task.resume()
            if sem.wait(timeout: .now() + timeout) == .timedOut {
                task.cancel()
            }
            let ok = status == 400
                || (status == 200 && isJSONBody(body))
                || (status == 404 && isGatewayErrorBody(body))
            if ok {
                return (true, false, "POST \(base)\(path) → HTTP \(status)(网关可达)")
            }
            lastDesc = "POST \(base)\(path) → HTTP \(status == 0 ? "超时" : "\(status)")" + (body.isEmpty ? "" : " \(body.prefix(100))")
        }
        return (false, lastDesc.contains("401") || lastDesc.contains("403"), lastDesc)
    }

    private static func isJSONBody(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("{") || t.hasPrefix("[")
    }

    /// 404 + 结构化 JSON error(code/message)→ 网关可达但模型校验失败
    /// (ark plan 网关真实形态:无 /models、无 /v1,仅 POST /chat/completions 有效)
    private static func isGatewayErrorBody(_ s: String) -> Bool {
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let err = obj["error"] as? [String: Any] else { return false }
        return err["code"] != nil || err["message"] != nil
    }

    private static func endpointCandidates(_ base: String) -> [String] {
        let hasV1 = base.hasSuffix("/v1") || base.hasSuffix("/api/v1")
        if hasV1 {
            return ["\(base)/models"]
        }
        return ["\(base)/models", "\(base)/v1/models"]
    }

    private static func anthropicTest(base: String, key: String, timeout: TimeInterval, proxy: String? = nil) -> (Bool, Bool, String) {
        let hasV1 = base.hasSuffix("/v1") || base.hasSuffix("/api/v1")
        let messagesPath = hasV1 ? "\(base)/messages" : "\(base)/v1/messages"
        let s = session(for: proxy)
        guard let u = URL(string: messagesPath) else { return (false, false, "URL 非法") }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": "claude-3-5-sonnet-20241022",
            "max_tokens": 1,
            "messages": [["role": "user", "content": "ping"]]
        ])

        let sem = DispatchSemaphore(value: 0)
        var status = 0
        var body = ""
        let task = s.dataTask(with: req) { data, resp, _ in
            defer { sem.signal() }
            status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if let d = data { body = String(data: d, encoding: .utf8) ?? "" }
        }
        task.resume()
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            task.cancel()
        }
        let ok = status == 400 || (status == 200 && isJSONBody(body))
        return (ok, status == 401 || status == 403,
                "POST \(messagesPath) → HTTP \(status == 0 ? "超时" : "\(status)")" + (body.isEmpty ? "" : " \(body.prefix(100))"))
    }

    /// 生成一条可直接粘贴运行的 curl(优先 chat,其次 models 探测)
    static public func curlCommand(
        url: String,
        key: String,
        model: String? = nil,
        styleHint: String? = nil
    ) -> String {
        let base = url.hasSuffix("/") ? String(url.dropLast()) : url
        let anthropic = (styleHint?.lowercased().contains("anthropic") == true)
            || (model?.lowercased().contains("claude") == true)
            || (model?.lowercased().contains("sonnet") == true)
            || (model?.lowercased().contains("opus") == true)
            || (model?.lowercased().contains("haiku") == true)

        let hasV1 = base.hasSuffix("/v1") || base.hasSuffix("/api/v1")

        if anthropic {
            let m = (model?.isEmpty == false) ? model! : "claude-3-5-sonnet-20241022"
            let endpoint = hasV1 ? "\(base)/messages" : "\(base)/v1/messages"
            let body = "{\"model\":\(jsonString(m)),\"max_tokens\":32,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}"
            return [
                "curl -sS \(shQuote(endpoint)) \\",
                "  -H \(shQuote("Content-Type: application/json")) \\",
                "  -H \(shQuote("x-api-key: \(key)")) \\",
                "  -H \(shQuote("anthropic-version: 2023-06-01")) \\",
                "  -d \(shQuote(body))"
            ].joined(separator: "\n")
        }

        if let model, !model.isEmpty {
            let chatURL = hasV1 ? "\(base)/chat/completions" : "\(base)/v1/chat/completions"
            let body = "{\"model\":\(jsonString(model)),\"max_tokens\":32,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}"
            return [
                "curl -sS \(shQuote(chatURL)) \\",
                "  -H \(shQuote("Content-Type: application/json")) \\",
                "  -H \(shQuote("Authorization: Bearer \(key)")) \\",
                "  -d \(shQuote(body))"
            ].joined(separator: "\n")
        }

        let modelsPath = hasV1 ? "\(base)/models" : "\(base)/v1/models"
        return [
            "curl -sS \(shQuote(modelsPath)) \\",
            "  -H \(shQuote("Authorization: Bearer \(key)"))"
        ].joined(separator: "\n")
    }

    static func testModelChat(base: String, key: String, model: String, timeout: TimeInterval = 12, proxy: String? = nil) -> (ok: Bool, detail: String) {
        let hasV1 = base.hasSuffix("/v1") || base.hasSuffix("/api/v1")
        let chatPaths = hasV1 ? ["/chat/completions"] : ["/chat/completions", "/v1/chat/completions"]
        let s = session(for: proxy)
        for path in chatPaths {
            guard let u = URL(string: base + path) else { continue }
            var req = URLRequest(url: u)
            req.httpMethod = "POST"
            req.timeoutInterval = timeout
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            req.httpBody = try? JSONSerialization.data(withJSONObject: [
                "model": model,
                "max_tokens": 1,
                "messages": [["role": "user", "content": "ping"]]
            ])
            let sem = DispatchSemaphore(value: 0)
            var status = 0
            var body = ""
            let task = s.dataTask(with: req) { data, resp, _ in
                defer { sem.signal() }
                status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if let d = data { body = String(data: d, encoding: .utf8) ?? "" }
            }
            task.resume()
            if sem.wait(timeout: .now() + timeout) == .timedOut {
                task.cancel()
            }
            if status == 200 {
                return (true, "POST \(base)\(path) → 200")
            }
            if status != 0 {
                return (false, "POST \(base)\(path) → HTTP \(status)" + (body.isEmpty ? "" : " \(body.prefix(80))"))
            }
        }
        return (false, "模型验证请求超时/无响应")
    }

    /// 探测网关是否支持 OpenAI Responses API(供 codex wire_api 选择)
    /// 2xx/401/403 → 端点存在(支持);404/405/501 → 不支持;网络错误 → 保守返回 true(保持默认)
    static func supportsResponsesAPI(base: String, key: String, timeout: TimeInterval = 8, proxy: String? = nil) -> Bool {
        let hasV1 = base.hasSuffix("/v1") || base.hasSuffix("/api/v1")
        let path = hasV1 ? "/responses" : "/v1/responses"
        guard let u = URL(string: base + path) else { return true }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": "gpt-4.1-mini",
            "input": "ping",
            "max_output_tokens": 1
        ])
        let s = session(for: proxy)
        let sem = DispatchSemaphore(value: 0)
        var status = 0
        let task = s.dataTask(with: req) { data, resp, _ in
            defer { sem.signal() }
            status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        }
        task.resume()
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            task.cancel()
            return true
        }
        if status == 0 { return true }
        return status != 404 && status != 405 && status != 501
    }

    private static func shQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func jsonString(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
