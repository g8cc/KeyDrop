import Foundation

/// CPA 管理 API 客户端(/v0/management/*)。
///
/// 设计:在 KeyDrop 里配置管理密钥(Prefs.cpaManagementKey)后,对 CPA 的全部读写
/// 走 HTTP 管理 API,完全不触碰 CPA 数据目录文件——若目录在 ~/Documents 下,
/// 根治 macOS 反复弹「文稿」授权的问题(真实事故:每次导入/扫描/代理池绑定都触发 TCC)。
/// 未配置密钥时自动回退原有文件直写模式,行为与历史版本完全一致(双轨)。
///
/// 端点语义(源自 CLIProxyAPI internal/api/handlers/management):
/// - GET  /v0/management/config.yaml          → 原始 YAML 文本(保留注释)
/// - PUT  /v0/management/config.yaml          → 完整 YAML 正文;服务端校验+落盘+热重载
/// - GET  /v0/management/auth-files           → {"files":[{"name":...},...]}
/// - GET  /v0/management/auth-files/download?name=x.json → 该凭据文件原始字节
/// - PATCH /v0/management/auth-files/fields   → {"name":"x.json","proxy_url":"..."}(空串=清除)
public enum CPAAPIError: Error, LocalizedError {
    case noKey
    case http(Int, String)

    public var errorDescription: String? {
        switch self {
        case .noKey:
            return "未配置 CPA 管理密钥(右键 CPA 标签 → CPA 管理 API)"
        case .http(let code, let msg):
            return "CPA 管理 API HTTP \(code): \(msg)"
        }
    }
}

public enum CPAAPI {
    /// API 模式开关:管理密钥非空即启用
    public static var apiMode: Bool {
        !(Prefs.shared.cpaManagementKey ?? "").isEmpty
    }

    /// 专用会话:ephemeral(不落盘缓存 cookie/凭据)+ 空代理字典 ——
    /// 管理 API 打的是本机回环,走系统代理设置既没必要也可能被代理拦掉。
    /// 显式超时兜底:request 里还有一层信号量等待,双保险。
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 30
        c.connectionProxyDictionary = [:]
        return URLSession(configuration: c)
    }()

    static var baseURL: URL {
        let fallback = "http://127.0.0.1:8317"
        let raw = Prefs.shared.cpaAPIBase ?? ""
        let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: candidate.isEmpty ? fallback : candidate),
              let scheme = components.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              let url = components.url else {
            return URL(string: fallback)!
        }
        return url
    }

    /// 统一同步请求入口;返回 (状态码, 响应体)。
    /// 调用方都在后台线程/CLI,信号量同步安全。
    @discardableResult
    public static func request(_ method: String, _ path: String, query: [String: String] = [:],
                               body: Data? = nil, contentType: String = "application/json") throws -> (Int, Data) {
        guard let key = Prefs.shared.cpaManagementKey, !key.isEmpty else {
            throw CPAAPIError.noKey
        }
        guard var comp = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false),
              let scheme = comp.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              comp.host?.isEmpty == false else {
            throw CPAAPIError.http(0, "管理 API 地址无效")
        }
        if !query.isEmpty {
            comp.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let requestURL = comp.url else {
            throw CPAAPIError.http(0, "管理 API 地址无效")
        }
        var req = URLRequest(url: requestURL)
        req.httpMethod = method
        req.timeoutInterval = 20
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = body
            req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        var payload = Data()
        var code = 0
        var taskError: Error?
        let sem = DispatchSemaphore(value: 0)
        let lock = NSLock()
        let task = session.dataTask(with: req) { d, r, e in
            lock.lock()
            if let e { taskError = e } else {
                code = (r as? HTTPURLResponse)?.statusCode ?? 0
                payload = d ?? Data()
            }
            lock.unlock()
            sem.signal()
        }
        task.resume()
        // 必须带超时等待:URLRequest.timeoutInterval 只覆盖「已建立连接后的传输」,
        // CPA 若 TCP 可连但永不回包(卡死/半死),裸 sem.wait() 会让整个导入/扫描
        // 永久挂住 —— 菜单栏应用表现为点了没反应、只能强杀。
        if sem.wait(timeout: .now() + 30) == .timedOut {
            task.cancel()
            // cancel 后回调仍会到达一次,同步等它收尾,关闭「回调悬空晚写」窗口
            _ = sem.wait(timeout: .now() + 5)
            throw CPAAPIError.http(0, "管理 API 无响应(30s 超时),请检查 CPA 是否卡住")
        }
        lock.lock(); defer { lock.unlock() }
        if let taskError { throw taskError }
        return (code, payload)
    }

    // MARK: - config.yaml 双轨 IO

    /// 读 CPA 配置文本。API 模式走 GET(保留注释原文);文件模式读本地文件。
    public static func readConfigText(path: String) throws -> String {
        if apiMode {
            let (code, data) = try request("GET", "v0/management/config.yaml")
            guard code == 200, let text = String(data: data, encoding: .utf8) else {
                throw CPAAPIError.http(code, String(data: data, encoding: .utf8) ?? "")
            }
            return text
        }
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    /// 写 CPA 配置文本。API 模式 PUT 完整正文(CPA 服务端校验+落盘+热重载,
    /// 本地 python 校验/备份回滚由服务端语义取代);文件模式走原有原地写入。
    public static func writeConfigText(_ text: String, path: String) throws {
        if apiMode {
            guard let body = text.data(using: .utf8) else {
                throw WriterError.file("CPA 配置无法编码为 UTF-8")
            }
            let (code, data) = try request("PUT", "v0/management/config.yaml", body: body,
                                           contentType: "text/yaml")
            guard code == 200 else {
                throw CPAAPIError.http(code, String(data: data, encoding: .utf8) ?? "")
            }
            return
        }
        try String(text).write(toFile: path, atomically: false, encoding: .utf8)
    }

    // MARK: - auth 文件(代理池)

    /// 列出全部凭据文件名。响应形如 {"observed_at":...,"files":[{"name":"x.json",...},...]}
    public static func listAuthFileNames() throws -> [String] {
        let (code, data) = try request("GET", "v0/management/auth-files")
        guard code == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = obj["files"] as? [[String: Any]] else {
            throw CPAAPIError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        return files.compactMap { $0["name"] as? String }
    }

    /// 取单个凭据文件原始字节(响应即文件内容本身)
    public static func authFileData(fileName: String) throws -> Data {
        let (code, data) = try request("GET", "v0/management/auth-files/download",
                                       query: ["name": fileName])
        guard code == 200 else {
            throw CPAAPIError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    /// 修改凭据文件字段。proxy_url 传空串 = 清除(回落全局代理)。
    public static func patchAuthFile(name: String, fields: [String: String]) throws {
        var obj: [String: Any] = ["name": name]
        for (k, v) in fields { obj[k] = v }
        let body = try JSONSerialization.data(withJSONObject: obj)
        let (code, data) = try request("PATCH", "v0/management/auth-files/fields", body: body)
        guard code == 200 else {
            throw CPAAPIError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
    }
}
