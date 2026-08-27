import Foundation

/// 生图渠道(OpenAI 兼容 /v1/images/generations)探测与调用
public enum ImageAPI {

    public struct Probe {
        public let supported: Bool
        public let models: [String]
        public let detail: String
        public init(supported: Bool, models: [String], detail: String) {
            self.supported = supported
            self.models = models
            self.detail = detail
        }
    }

    /// session 缓存:调用方每个请求都设了 URLRequest.timeoutInterval,
    /// session 级默认值不参与判定,可安全按代理复用,避免反复创建泄漏
    private static let sessionLock = NSLock()
    private static var sessionCache: [String: URLSession] = [:]

    private static func session(timeout: TimeInterval, proxy: String?) -> URLSession {
        let p = proxy?.trimmingCharacters(in: .whitespaces) ?? ""
        sessionLock.lock()
        defer { sessionLock.unlock() }
        if let cached = sessionCache[p] { return cached }
        // 上限保护:同 APITester.session(for:)
        if sessionCache.count >= 8 { sessionCache.removeAll() }
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = timeout
        c.timeoutIntervalForResource = timeout + 10
        c.httpMaximumConnectionsPerHost = 2
        if !p.isEmpty, let url = URL(string: p) {
            c.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable: true,
                kCFNetworkProxiesHTTPProxy: url.host ?? "",
                kCFNetworkProxiesHTTPPort: url.port ?? (url.scheme == "https" ? 443 : 80),
                kCFNetworkProxiesHTTPSEnable: true,
                kCFNetworkProxiesHTTPSProxy: url.host ?? "",
                kCFNetworkProxiesHTTPSPort: url.port ?? (url.scheme == "https" ? 443 : 80),
            ]
        } else {
            c.connectionProxyDictionary = [:]
        }
        let s = URLSession(configuration: c)
        sessionCache[p] = s
        return s
    }

    private static func base(_ url: String) -> String {
        let u = url.hasSuffix("/") ? String(url.dropLast()) : url
        return u
    }

    /// 探测渠道是否支持生图:空 body POST generations 端点
    /// 400/422/200/403(权限类) = 端点在;404/405 = 无生图能力
    public static func probe(baseURL: String, key: String, timeout: TimeInterval = 10, proxy: String? = nil) -> Probe {
        let b = base(baseURL)
        // URL 含空格等非法字符时 URL(string:) 为 nil,不能强解
        guard let probeURL = URL(string: b + "/images/generations") else {
            return Probe(supported: false, models: [], detail: "URL 非法: \(b)")
        }
        var req = URLRequest(url: probeURL)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = Data("{}".utf8)

        var supported = false
        let o = NetSync.run(session: session(timeout: timeout, proxy: proxy), request: req, timeout: timeout + 5)
        // 与旧实现一致:有 error 视作网络不可达(-1),否则取 HTTP 状态码
        let status = o.error != nil ? -1 : NetSync.statusCode(o)
        switch NetSync.statusCode(o) {
        case 400, 422:
            supported = true
        case 200:
            supported = true
        case 403:
            supported = true
        default:
            supported = false
        }

        var models: [String] = []
        if supported || status == 403 {
            models = fetchModels(baseURL: b, key: key, timeout: timeout, proxy: proxy)
        }
        let detail: String
        switch status {
        case 200: detail = "生图端点正常"
        case 400, 422: detail = "生图端点存在(空请求被拒)"
        case 401: detail = "key 无效(401)"
        case 403: detail = "端点存在,但当前 key 无权访问模型"
        case 404, 405: detail = "该网关无生图端点(/images/generations)"
        case -1: detail = "网络不可达"
        default: detail = "HTTP \(status)"
        }
        return Probe(supported: supported, models: models, detail: detail)
    }

    private static func fetchModels(baseURL: String, key: String, timeout: TimeInterval, proxy: String?) -> [String] {
        guard let u = URL(string: baseURL + "/models") else { return [] }
        var req = URLRequest(url: u)
        req.timeoutInterval = timeout
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let o = NetSync.run(session: session(timeout: timeout, proxy: proxy), request: req, timeout: timeout + 5)
        guard let data = o.data,
              let http = o.response as? HTTPURLResponse, http.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["data"] as? [[String: Any]] else { return [] }
        return arr.compactMap { $0["id"] as? String }
    }

    /// 生成图片:返回保存到本地的文件路径;失败抛错
    public static func generate(
        baseURL: String, key: String, prompt: String, model: String,
        size: String = "1024x1024", timeout: TimeInterval = 120, proxy: String? = nil
    ) throws -> String {
        let b = base(baseURL)
        let body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "n": 1,
            "size": size,
        ]
        guard let reqURL = URL(string: b + "/images/generations") else {
            throw NSError(domain: "ImageAPI", code: -4, userInfo: [NSLocalizedDescriptionKey: "URL 非法: \(b)"])
        }
        var req = URLRequest(url: reqURL)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let o = NetSync.run(session: session(timeout: timeout, proxy: proxy), request: req, timeout: timeout + 10)
        // 结果处理与旧回调体一致,只是从闭包改为同步执行(竞态已由 NetSync 内部消除)
        let img: Data = try awaitDecode(o, timeout: timeout)

        let dir = (ProcessInfo.processInfo.environment["KEYDROP_IMAGES_DIR"]
            ?? (NSHomeDirectory() + "/.keydrop/images"))
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let name = "img-\(Int(Date().timeIntervalSince1970)).png"
        let path = dir + "/" + name
        try img.write(to: URL(fileURLWithPath: path))
        return path
    }

    /// 把生图接口响应解码成图片数据;错误码/文案保持旧行为
    private static func awaitDecode(_ o: NetSync.Outcome, timeout: TimeInterval) throws -> Data {
        if let err = o.error {
            // 超时强制取消的回调在这里到达:给用户可读的超时文案,而非生硬的 "cancelled"
            if (err as? URLError)?.code == .cancelled {
                throw NSError(domain: "ImageAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: "生成请求超时"])
            }
            throw err
        }
        guard let respData = o.data, let http = o.response as? HTTPURLResponse else {
            throw NSError(domain: "ImageAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: "无响应"])
        }
        guard http.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let items = obj["data"] as? [[String: Any]], let first = items.first else {
            let msg = (try? JSONSerialization.jsonObject(with: respData) as? [String: Any])?["error"] as? [String: Any]
            let m = (msg?["message"] as? String) ?? "HTTP \(http.statusCode)"
            throw NSError(domain: "ImageAPI", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: m])
        }
        if let b64 = first["b64_json"] as? String, let d = Data(base64Encoded: b64) {
            return d
        }
        if let urlStr = first["url"] as? String, let url = URL(string: urlStr) {
            if let d = try? Data(contentsOf: url) { return d }
            throw NSError(domain: "ImageAPI", code: -2, userInfo: [NSLocalizedDescriptionKey: "图片 URL 下载失败"])
        }
        throw NSError(domain: "ImageAPI", code: -3, userInfo: [NSLocalizedDescriptionKey: "响应无图片数据"])
    }
}