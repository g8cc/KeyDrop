import Foundation

public enum LLMParser {

    struct LLMResult {
        let url: String?
        let key: String?
        let model: String?
        let name: String?
        let raw: String
    }

    public static var enabled: Bool {
        ProcessInfo.processInfo.environment["KEYDROP_LLM_PARSE"] != "0"
    }
    public static var endpoint: String {
        ProcessInfo.processInfo.environment["KEYDROP_LLM_ENDPOINT"] ?? "http://127.0.0.1:8317/v1"
    }
    public static var model: String {
        ProcessInfo.processInfo.environment["KEYDROP_LLM_MODEL"] ?? "shangtang"
    }
    public static var apiKey: String {
        if let k = ProcessInfo.processInfo.environment["KEYDROP_LLM_KEY"], !k.isEmpty {
            return k
        }
        return clientKeyFromConfig()
    }

    public static func configSummary() -> String {
        guard enabled else { return "LLM 解析: 已禁用 (KEYDROP_LLM_PARSE=0)" }
        let key = apiKey
        let keyMasked = key.count > 8 ? String(key.prefix(6)) + "…" : (key.isEmpty ? "(未配置)" : "***")
        var s = "LLM 解析: \(endpoint) model=\(model) key=\(keyMasked)"
        if key.isEmpty { s += " ⚠ 未找到客户端 key(config.yaml 无 api-keys 或 KEYDROP_LLM_KEY 未设)" }
        return s
    }

    public static func clientKeyFromConfig() -> String {
        guard let cfg = CPAWriter.locateConfig(),
              let content = try? String(contentsOfFile: cfg, encoding: .utf8)
        else { return "" }
        var inSection = false
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = String(line)
            let trimmed = l.trimmingCharacters(in: .whitespaces)
            if !l.hasPrefix(" ") && !l.hasPrefix("\t") {
                if trimmed == "api-keys:" {
                    inSection = true
                    continue
                }
                if inSection { break }
            }
            if inSection, trimmed.hasPrefix("- ") {
                let key = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if !key.isEmpty { return key }
            }
        }
        return ""
    }

    private static let systemPrompt = """
    你是 API key 提取器。从用户粘贴的杂乱文本(可能是聊天记录、配置片段、中文描述、网页截图文字)中提取信息:
    1. url: API base URL,http(s):// 开头,可能省略协议(补 https://),可能带 /v1 路径,去掉末尾斜杠。若给出的是完整接口路径(/chat/completions、/v1/chat/completions、/messages、/models),要去掉该路径只保留 base URL(例如 https://x.com/v1/chat/completions → https://x.com/v1);
    2. key: API key。可能明文(sk-/ak-/eyJ 开头或 20+ 字符令牌),也可能 base64 编码(以 c2st/YWst 等开头,需解码),还可能被空格/换行/标点拆成多段(去掉非 key 字符后按原顺序拼接还原);
    3. model: 模型名,多个取第一个;
    4. name: 站点名/别名,可选。
    忽略闲聊、说明、疑问句、无关内容。
    只输出一个 JSON 对象,不要任何其他文字,格式:{"name": string|null, "url": string|null, "model": string|null, "key": string|null}
    """

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 20
        return URLSession(configuration: c)
    }()

    static func extract(from raw: String, timeout: TimeInterval = 15) -> LLMResult? {
        guard enabled, !apiKey.isEmpty,
              let url = URL(string: endpoint + "/chat/completions")
        else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": raw]
            ],
            "max_tokens": 800,
            "temperature": 0
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        var result: LLMResult?
        let sem = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { data, _, error in
            defer { sem.signal() }
            guard let data, error == nil,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = obj["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let msg = first["message"] as? [String: Any],
                  let content = msg["content"] as? String
            else { return }
            result = validate(content: content)
        }
        task.resume()
        _ = sem.wait(timeout: .now() + timeout)
        task.cancel()
        return result
    }

    private static func validate(content: String) -> LLMResult? {
        guard let start = content.firstIndex(of: "{"),
              let end = content.lastIndex(of: "}"),
              start < end
        else { return nil }
        let jsonText = String(content[start...end])
        guard let data = jsonText.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let rawKey = (obj["key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawURL = (obj["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = (obj["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (obj["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        var key: String? = nil
        if let r = rawKey, !r.isEmpty {
            if Parser.looksLikeKey(r) {
                key = r
            } else if let decoded = Parser.decodeKeyIfBase64(r), Parser.looksLikeKey(decoded) {
                key = decoded
            }
        }
        guard let k = key else { return nil }

        var url: String? = nil
        if let u = rawURL, !u.isEmpty {
            url = Parser.normalizeURL(u)
        }
        return LLMResult(
            url: url,
            key: k,
            model: (model?.isEmpty == false) ? model : nil,
            name: (name?.isEmpty == false) ? name : nil,
            raw: content
        )
    }
}
