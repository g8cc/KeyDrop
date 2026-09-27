import Foundation

/// 生图渠道(OpenAI 兼容 /v1/images/generations)探测与调用
public enum ImageAPI {

    private static let maxPromptBytes = 64_000
    private static let maxKeyBytes = 4_096
    private static let maxImageBytes = 50_000_000

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
        // 缓存 key 必须包含 timeout:URLRequest.timeoutInterval 只覆盖 request 超时,
        // 不覆盖 session 的 timeoutIntervalForResource。若只按 proxy 复用,
        // probe(10s,resource=20s) 建的 session 会被 generate(120s) 命中,
        // 慢生图会在 ~20s 被资源超时切断。
        let key = "\(p)|\(timeout)"
        sessionLock.lock()
        defer { sessionLock.unlock() }
        if let cached = sessionCache[key] { return cached }
        // 上限保护:同 APITester.session(for:)
        if sessionCache.count >= 8 {
            let evicted = sessionCache
            sessionCache.removeAll()
            // 同 APITester:逐出延迟 invalidate,给刚拿到 session 的调用方留窗口
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 60) {
                evicted.values.forEach { $0.finishTasksAndInvalidate() }
            }
        }
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = timeout
        c.timeoutIntervalForResource = timeout + 10
        c.httpMaximumConnectionsPerHost = 2
        // 复用 APITester.proxyDictionary:它处理 socks5/socks5h、裸 host:port 补全、
        // 端口越界拒绝三类输入。此处旧实现只认 http(s) 且把 socks5:// 当 HTTP 代理
        // 建会话(SOCKS 端口上发 HTTP CONNECT,握手必败),用户填了代理反而全挂。
        // 无法识别的形态回落直连(空字典),与探测口径一致。
        if let dict = APITester.proxyDictionary(for: p) {
            c.connectionProxyDictionary = dict
        } else {
            c.connectionProxyDictionary = [:]
        }
        let s = URLSession(configuration: c)
        sessionCache[key] = s
        return s
    }

    private static func base(_ url: String) -> String {
        url.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression)
    }

    private static func endpointURLs(baseURL: String, path: String) -> [URL] {
        let b = base(baseURL)
        guard var components = URLComponents(string: b),
              let scheme = components.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.fragment == nil else { return [] }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalizedBasePath = basePath.isEmpty ? "" : "/\(basePath)"
        func makeURL(_ suffix: String) -> URL? {
            components.path = normalizedBasePath + suffix
            return components.url
        }
        let first = makeURL(path)
        let hasVersion = components.path.split(separator: "/").contains {
            $0.range(of: #"^v[0-9]"#, options: .regularExpression) != nil
        }
        let second = hasVersion ? nil : makeURL("/v1" + path)
        return [first, second].compactMap { $0 }
    }

    private static func validateRequest(prompt: String, model: String, size: String) throws {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              prompt.utf8.count <= maxPromptBytes else {
            throw NSError(domain: "ImageAPI", code: -5,
                          userInfo: [NSLocalizedDescriptionKey: "prompt 不能为空且不能超过 64KB"])
        }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              model.utf8.count <= 256 else {
            throw NSError(domain: "ImageAPI", code: -5,
                          userInfo: [NSLocalizedDescriptionKey: "model 不能为空且不能超过 256 字节"])
        }
        if size != "auto" {
            guard let match = size.range(of: #"^(\d{1,5})x(\d{1,5})$"#, options: .regularExpression) else {
                throw NSError(domain: "ImageAPI", code: -5,
                              userInfo: [NSLocalizedDescriptionKey: "size 格式无效,应为 1024x1024 或 auto"])
            }
            let parts = size[match].split(separator: "x")
            guard parts.count == 2,
                  let width = Int(parts[0]), let height = Int(parts[1]),
                  width > 0, height > 0, width <= 8192, height <= 8192 else {
                throw NSError(domain: "ImageAPI", code: -5,
                              userInfo: [NSLocalizedDescriptionKey: "size 最大支持 8192x8192"])
            }
        }
    }

    private static func validateKey(_ key: String) throws {
        guard !key.isEmpty, key.utf8.count <= maxKeyBytes else {
            throw NSError(domain: "ImageAPI", code: -5,
                          userInfo: [NSLocalizedDescriptionKey: "key 不能为空且不能超过 4KB"])
        }
    }

    private final class LimitedCollector: NSObject, URLSessionDataDelegate {
        private let maxBytes: Int
        private let lock = NSLock()
        private let done = DispatchSemaphore(value: 0)
        private var buffer = Data()
        private var response: URLResponse?
        private var error: Error?

        init(maxBytes: Int) { self.maxBytes = maxBytes }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            lock.lock()
            self.response = response
            if response.expectedContentLength > Int64(maxBytes) {
                error = NSError(domain: "ImageAPI", code: -6,
                                userInfo: [NSLocalizedDescriptionKey: "响应体过大,已拒绝下载"])
                lock.unlock()
                completionHandler(.cancel)
                dataTask.cancel()
                return
            }
            lock.unlock()
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.lock()
            if buffer.count > maxBytes - data.count {
                error = NSError(domain: "ImageAPI", code: -6,
                                userInfo: [NSLocalizedDescriptionKey: "响应体过大,已拒绝下载"])
                lock.unlock()
                dataTask.cancel()
                return
            }
            buffer.append(data)
            lock.unlock()
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock()
            if self.error == nil { self.error = error }
            lock.unlock()
            done.signal()
        }

        func wait(timeout: TimeInterval, task: URLSessionDataTask) -> NetSync.Outcome {
            if done.wait(timeout: .now() + timeout) == .timedOut {
                task.cancel()
                _ = done.wait(timeout: .now() + 5)
                lock.lock()
                if error == nil {
                    error = NSError(domain: "ImageAPI", code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: "请求超时"])
                }
                lock.unlock()
            }
            lock.lock()
            defer { lock.unlock() }
            return NetSync.Outcome(data: buffer, response: response, error: error)
        }
    }

    private static func runLimited(request: URLRequest, timeout: TimeInterval,
                                   proxy: String?, maxBytes: Int) -> NetSync.Outcome {
        let collector = LimitedCollector(maxBytes: maxBytes)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout + 10
        config.httpMaximumConnectionsPerHost = 2
        config.connectionProxyDictionary = APITester.proxyDictionary(for: proxy ?? "") ?? [:]
        let session = URLSession(configuration: config, delegate: collector, delegateQueue: nil)
        let task = session.dataTask(with: request)
        task.resume()
        let result = collector.wait(timeout: timeout + 5, task: task)
        session.finishTasksAndInvalidate()
        return result
    }

    /// 探测渠道是否支持生图:空 body POST generations 端点
    /// 400/422/200/403(权限类) = 端点在;404/405 = 无生图能力
    public static func probe(baseURL: String, key: String, timeout: TimeInterval = 10, proxy: String? = nil) -> Probe {
        let b = base(baseURL)
        guard !key.isEmpty, key.utf8.count <= maxKeyBytes else {
            return Probe(supported: false, models: [], detail: "key 为空或超过 4KB")
        }
        let probeURLs = endpointURLs(baseURL: b, path: "/images/generations")
        guard !probeURLs.isEmpty else {
            return Probe(supported: false, models: [], detail: "URL 非法: \(b)")
        }
        var status = -1
        for probeURL in probeURLs {
            var req = URLRequest(url: probeURL)
            req.httpMethod = "POST"
            req.timeoutInterval = timeout
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            req.httpBody = Data("{}".utf8)
            let o = NetSync.run(session: session(timeout: timeout, proxy: proxy), request: req, timeout: timeout + 5)
            status = o.error != nil ? -1 : NetSync.statusCode(o)
            if ![404, 405].contains(status) { break }
        }
        let supported = [200, 400, 403, 422].contains(status)

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
        for u in endpointURLs(baseURL: baseURL, path: "/models") {
            var req = URLRequest(url: u)
            req.timeoutInterval = timeout
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            let o = NetSync.run(session: session(timeout: timeout, proxy: proxy), request: req, timeout: timeout + 5)
            guard let data = o.data,
                  let http = o.response as? HTTPURLResponse, http.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = obj["data"] as? [[String: Any]] else {
                if [404, 405].contains(NetSync.statusCode(o)) { continue }
                return []
            }
            return arr.compactMap { $0["id"] as? String }
        }
        return []
    }

    /// 生成图片:返回保存到本地的文件路径;失败抛错
    public static func generate(
        baseURL: String, key: String, prompt: String, model: String,
        size: String = "1024x1024", timeout: TimeInterval = 120, proxy: String? = nil
    ) throws -> String {
        let b = base(baseURL)
        try validateKey(key)
        try validateRequest(prompt: prompt, model: model, size: size)
        let body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "n": 1,
            "size": size,
        ]
        let requestURLs = endpointURLs(baseURL: b, path: "/images/generations")
        guard !requestURLs.isEmpty else {
            throw NSError(domain: "ImageAPI", code: -4, userInfo: [NSLocalizedDescriptionKey: "URL 非法: \(b)"])
        }
        let payload = try JSONSerialization.data(withJSONObject: body)
        var o = NetSync.Outcome(data: nil, response: nil, error: nil)
        for requestURL in requestURLs {
            var req = URLRequest(url: requestURL)
            req.httpMethod = "POST"
            req.timeoutInterval = timeout
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            req.httpBody = payload
            o = runLimited(request: req, timeout: timeout, proxy: proxy, maxBytes: maxImageBytes + 10_000_000)
            let status = NetSync.statusCode(o)
            if o.error != nil || ![404, 405].contains(status) { break }
        }
        // 结果处理与旧回调体一致,只是从闭包改为同步执行(竞态已由 NetSync 内部消除)
        let img: Data = try awaitDecode(o, timeout: timeout, proxy: proxy)

        let configuredDir = ProcessInfo.processInfo.environment["KEYDROP_IMAGES_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let dir = (configuredDir?.isEmpty == false ? configuredDir! : nil)
            ?? (NSHomeDirectory() + "/.keydrop/images")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // 秒级时间戳同秒会互相覆盖;并保证扩展名与实际图片格式一致
        let name = "img-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6).lowercased()).\(imageExtension(img))"
        let path = dir + "/" + name
        try img.write(to: URL(fileURLWithPath: path), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        return path
    }

    /// 按文件头判断图片格式,避免把 JPEG/WebP 存成 .png 打不开
    private static func imageExtension(_ d: Data) -> String {
        guard d.count >= 12 else { return "png" }
        if d[0] == 0x89, d[1] == 0x50, d[2] == 0x4E, d[3] == 0x47 { return "png" }
        if d[0] == 0xFF, d[1] == 0xD8 { return "jpg" }
        if String(data: d[8..<12], encoding: .ascii) == "WEBP" { return "webp" }
        if String(data: d[0..<3], encoding: .ascii) == "GIF" { return "gif" }
        return "png"
    }

    /// 把生图接口响应解码成图片数据;错误码/文案保持旧行为
    private static func awaitDecode(_ o: NetSync.Outcome, timeout: TimeInterval, proxy: String?) throws -> Data {
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
        if let b64 = first["b64_json"] as? String {
            // base64 解码内存峰值 ≈ 2× 数据量,超 30MB 的响应直接拒绝,防恶意响应撑爆内存
            guard b64.utf8.count <= 30_000_000,
                  let d = Data(base64Encoded: b64), !d.isEmpty else {
                throw NSError(domain: "ImageAPI", code: -4,
                              userInfo: [NSLocalizedDescriptionKey: "图片 base64 数据无效或过大"])
            }
            return d
        }
        if let urlStr = first["url"] as? String,
           let url = URL(string: urlStr),
           let scheme = url.scheme?.lowercased(),
           (scheme == "http" || scheme == "https"),
           url.host?.isEmpty == false {
            // Data(contentsOf:) 对 http 请求不可取消且无大小上限,挂起的服务端会
            // 卡住远超预期时长 —— 改走 NetSync 复用带超时的会话。
            // 必须传原代理,否则代理环境下图片下载必失败;并校验 200,
            // 否则 404/403 的错误页会被当成图片存成 .png
            let request = URLRequest(url: url)
            let o = runLimited(request: request, timeout: 30, proxy: proxy, maxBytes: maxImageBytes)
            let st = NetSync.statusCode(o)
            guard o.error == nil, st == 200, let d = o.data, !d.isEmpty, d.count <= maxImageBytes else {
                throw NSError(domain: "ImageAPI", code: -2,
                              userInfo: [NSLocalizedDescriptionKey: "图片 URL 下载失败(HTTP \(st == 0 ? "超时" : "\(st)"))"])
            }
            return d
        }
        throw NSError(domain: "ImageAPI", code: -3, userInfo: [NSLocalizedDescriptionKey: "响应无图片数据"])
    }
}
