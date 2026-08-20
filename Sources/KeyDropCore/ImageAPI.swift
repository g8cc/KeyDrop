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

    private static func session(timeout: TimeInterval, proxy: String?) -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = timeout
        c.timeoutIntervalForResource = timeout + 10
        c.httpMaximumConnectionsPerHost = 2
        if let proxy, !proxy.isEmpty, let url = URL(string: proxy) {
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
        return URLSession(configuration: c)
    }

    private static func base(_ url: String) -> String {
        let u = url.hasSuffix("/") ? String(url.dropLast()) : url
        return u
    }

    /// 探测渠道是否支持生图:空 body POST generations 端点
    /// 400/422/200/403(权限类) = 端点在;404/405 = 无生图能力
    public static func probe(baseURL: String, key: String, timeout: TimeInterval = 10, proxy: String? = nil) -> Probe {
        let b = base(baseURL)
        var req = URLRequest(url: URL(string: b + "/images/generations")!)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = Data("{}".utf8)

        var supported = false
        var status = 0
        let sem = DispatchSemaphore(value: 0)
        session(timeout: timeout, proxy: proxy).dataTask(with: req) { _, resp, err in
            if let err {
                status = -1
            } else if let http = resp as? HTTPURLResponse {
                status = http.statusCode
                switch http.statusCode {
                case 400, 422:
                    supported = true
                case 200:
                    supported = true
                case 401:
                    supported = false
                case 403:
                    supported = true
                case 404, 405:
                    supported = false
                default:
                    supported = false
                }
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 5)

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
        var req = URLRequest(url: URL(string: baseURL + "/models")!)
        req.timeoutInterval = timeout
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        var out: [String] = []
        let sem = DispatchSemaphore(value: 0)
        session(timeout: timeout, proxy: proxy).dataTask(with: req) { data, resp, _ in
            defer { sem.signal() }
            guard let data, let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = obj["data"] as? [[String: Any]] else { return }
            out = arr.compactMap { $0["id"] as? String }
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 5)
        return out
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
        var req = URLRequest(url: URL(string: b + "/images/generations")!)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        var result: Result<Data, Error> = .failure(NSError(domain: "ImageAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: "无响应"]))
        let sem = DispatchSemaphore(value: 0)
        session(timeout: timeout, proxy: proxy).dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if let err { result = .failure(err); return }
            guard let data, let http = resp as? HTTPURLResponse else { return }
            guard http.statusCode == 200, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = obj["data"] as? [[String: Any]], let first = items.first else {
                let msg = (try? JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any])?["error"] as? [String: Any]
                let m = (msg?["message"] as? String) ?? "HTTP \(http.statusCode)"
                result = .failure(NSError(domain: "ImageAPI", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: m]))
                return
            }
            if let b64 = first["b64_json"] as? String, let img = Data(base64Encoded: b64) {
                result = .success(img)
            } else if let urlStr = first["url"] as? String, let url = URL(string: urlStr) {
                let d = try? Data(contentsOf: url)
                if let d { result = .success(d) } else {
                    result = .failure(NSError(domain: "ImageAPI", code: -2, userInfo: [NSLocalizedDescriptionKey: "图片 URL 下载失败"]))
                }
            } else {
                result = .failure(NSError(domain: "ImageAPI", code: -3, userInfo: [NSLocalizedDescriptionKey: "响应无图片数据"]))
            }
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 10)

        let data = try result.get()
        let dir = (ProcessInfo.processInfo.environment["KEYDROP_IMAGES_DIR"]
            ?? (NSHomeDirectory() + "/.keydrop/images"))
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let name = "img-\(Int(Date().timeIntervalSince1970)).png"
        let path = dir + "/" + name
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }
}