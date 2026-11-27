import Foundation
import CryptoKit

public struct APITestResult {
    public let ok: Bool
    public let style: String
    public let models: [String]
    public let detail: String
    public let authFailed: Bool
    public let needsProxy: Bool
    /// chat 端点返回 429/402 且明确 quota exhausted(额度耗尽,非临时限流)
    public let quotaExhausted: Bool
    /// chat 端点确认不可用(429 限流无 quota 词 / 402 / 424 / 5xx)→ 移出可用列表
    public let chatDegraded: Bool
    /// 多模型探测中返回实际聊天内容的模型
    public let workingModels: [String]
    /// 多模型探测中确认额度耗尽的模型(逐个 429/402 + quota 词)。
    /// key 级判定不再被单个模型的 429 绑架:任一模型可用即 key 可用,
    /// 限流模型交给调用方排除/提示(真实事故:免费模型可用但首选模型 429,整 key 误入额度区)
    public let quotaModels: [String]
    /// 本轮实际探测失败的模型;不包含因冷却而跳过的模型。
    public let failedModels: [String]
    /// 首个可用模型的 chat 探测端到端延迟(毫秒)。实战监控用:慢网关也是"可用",
    /// 延迟让用户对体感有预期
    public let latencyMs: Double?
    /// 每个已探测模型的独立延迟(模型级监控:new-api 渠道×模型粒度)
    public let modelLatencies: [String: Double]?
    /// 失败属于「暂时性网络层」(超时/不可达/离线):健康扫描对此防抖保留可用;
    /// false = 服务端明确拒绝(401/403/429/5xx 等),第一次失败即应降级
    public let transientFailure: Bool
    public let reachabilityOnly: Bool
    public let skippedForCooldown: Bool
    public init(ok: Bool, style: String, models: [String], detail: String, authFailed: Bool, needsProxy: Bool = false, quotaExhausted: Bool = false, chatDegraded: Bool = false, workingModels: [String] = [], quotaModels: [String] = [], failedModels: [String] = [], latencyMs: Double? = nil, modelLatencies: [String: Double]? = nil, transientFailure: Bool = false, reachabilityOnly: Bool = false, skippedForCooldown: Bool = false) {
        self.ok = ok
        self.style = style
        self.models = models
        self.detail = detail
        self.authFailed = authFailed
        self.needsProxy = needsProxy
        self.quotaExhausted = quotaExhausted
        self.chatDegraded = chatDegraded
        self.workingModels = workingModels
        self.quotaModels = quotaModels
        self.failedModels = failedModels
        self.latencyMs = latencyMs
        self.modelLatencies = modelLatencies
        self.transientFailure = transientFailure
        self.reachabilityOnly = reachabilityOnly
        self.skippedForCooldown = skippedForCooldown
    }

    /// 只将真实请求的结果转成监控点;冷却/仅目录可达不会制造模型结果。
    public func modelProbePoints(at time: TimeInterval) -> [String: ProbePoint] {
        guard !skippedForCooldown else { return [:] }
        var points: [String: ProbePoint] = [:]
        for model in workingModels { points[model] = ProbePoint(t: time, ms: modelLatencies?[model], ok: true) }
        for model in quotaModels + failedModels { points[model] = ProbePoint(t: time, ms: modelLatencies?[model], ok: false) }
        return points
    }
}

extension APITestResult {
    init(ok: Bool, style: String, models: [String], detail: String, authFailed: Bool) {
        self.init(ok: ok, style: style, models: models, detail: detail, authFailed: authFailed, needsProxy: false)
    }
}

public enum BalanceStatus: Equatable {
    case unknown  // 网关无余额接口,无法判断
    case ok       // 明确有余额
    case zero     // 明确无余额/配额耗尽
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

    /// 代理 session 缓存:每次新建 URLSession 会常驻内部线程/队列且从不 invalidate,
    /// 健康扫描每小时跑一次会持续泄漏;按代理地址缓存后整个进程只保留有限几个
    private static let proxySessionLock = NSLock()
    private static var proxySessions: [String: URLSession] = [:]

    /// 解析代理字符串为 connectionProxyDictionary;nil = 视为直连。
    /// 修三类输入误配置(真实事故:用户填 socks5:// 或裸 host:port):
    /// - socks5:// 填了却按 HTTP 代理建 session → 每次探测对 SOCKS 端口发 HTTP CONNECT,
    ///   握手必败 → 所有 key 被误标 err/dead,小时级扫描还可能连带 clearDead 删掉
    /// - 裸 `127.0.0.1:7890` URL(string:) 返回 nil → 静默回落直连,用户以为走了代理
    /// 纯函数便于测试;scheme 缺省按 http 代理补全
    public static func proxyDictionary(for raw: String) -> [String: Any]? {
        let p = raw.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return nil }
        let spec: String
        let isSocks: Bool
        if p.lowercased().hasPrefix("socks5://") || p.lowercased().hasPrefix("socks5h://") {
            spec = p; isSocks = true
        } else if p.lowercased().hasPrefix("http://") || p.lowercased().hasPrefix("https://") {
            spec = p; isSocks = false
        } else if p.range(of: #"^[A-Za-z0-9.\-]+:\d+$"#, options: .regularExpression) != nil {
            spec = "http://" + p; isSocks = false   // 裸 host:port 按 http 代理补全
        } else {
            return nil   // 无法识别的形态:直连,而不是用错字典把探测全打挂
        }
        guard let url = URL(string: spec), let host = url.host, !host.isEmpty else { return nil }
        // 端口必须显式校验:URL(string:) 对 "http://h:99999" 照样解析成功(port=99999),
        // 而 CFNetwork 拿到越界端口的行为是未定义的 —— 可能静默直连或整个会话报错,
        // 用户看到的是「所有 key 突然全挂」却查不出原因。越界一律视为配置错误。
        let scheme = url.scheme?.lowercased() ?? ""
        let port = url.port ?? (isSocks ? 1080 : (scheme == "https" ? 443 : 80))
        guard port > 0, port <= 65535 else { return nil }
        if isSocks {
            return [
                kCFNetworkProxiesSOCKSEnable as String: true,
                kCFNetworkProxiesSOCKSProxy as String: host,
                kCFNetworkProxiesSOCKSPort as String: port,
            ]
        }
        return [
            kCFNetworkProxiesHTTPEnable as String: true,
            kCFNetworkProxiesHTTPProxy as String: host,
            kCFNetworkProxiesHTTPPort as String: port,
            kCFNetworkProxiesHTTPSEnable as String: true,
            kCFNetworkProxiesHTTPSProxy as String: host,
            kCFNetworkProxiesHTTPSPort as String: port,
        ]
    }

    /// 代理非空时创建带 connectionProxyDictionary 的 session;否则复用默认。
    /// 创建也在锁内:URLSession(configuration:) 构造很轻(不动网络),锁外 check-then-create
    /// 会让两个线程同时 miss 各建一个,被弃用的那个永不 invalidate → 常驻泄漏。
    static func session(for proxy: String?) -> URLSession {
        let p = proxy?.trimmingCharacters(in: .whitespaces) ?? ""
        guard let dict = proxyDictionary(for: p) else { return session }
        proxySessionLock.lock()
        defer { proxySessionLock.unlock() }
        if let cached = proxySessions[p] { return cached }
        // 缓存上限:用户反复修改代理输入框会产生多个不同地址;超上限清空重来
        if proxySessions.count >= 8 {
            let evicted = proxySessions
            proxySessions.removeAll()
            // 逐出的 session 必须最终 invalidate,否则内部队列/连接池常驻(泄漏);
            // 但不能立即 invalidate:同一线程可能刚从缓存拿到 session 还没发请求。
            // 延迟 60s 再失效,给在途调用留出窗口,泄漏上限仍是 8 个 session 的存活期
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 60) {
                evicted.values.forEach { $0.finishTasksAndInvalidate() }
            }
        }
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 12
        c.timeoutIntervalForResource = 20
        c.httpMaximumConnectionsPerHost = 2
        c.connectionProxyDictionary = dict
        let s = URLSession(configuration: c)
        proxySessions[p] = s
        return s
    }

    /// 余额探测:优先 OpenRouter /auth/key(limit/usage),其次 new-api 系 billing 组合
    /// 拿不到明确数据返回 .unknown(不影响可用判定)
    public static func checkBalance(url: String, key: String, timeout: TimeInterval = 10, proxy: String? = nil) -> BalanceStatus {
        let base = url.hasSuffix("/") ? String(url.dropLast()) : url
        if let st = authKeyBalance(base: base, key: key, timeout: timeout, proxy: proxy) { return st }
        if let st = newAPIBillingBalance(base: base, key: key, timeout: timeout, proxy: proxy) { return st }
        return .unknown
    }

    /// GET /auth/key (OpenRouter 兼容): {"data":{"limit":N,"usage":M}}
    private static func authKeyBalance(base: String, key: String, timeout: TimeInterval, proxy: String?) -> BalanceStatus? {
        guard let u = URL(string: base + "/auth/key") else { return nil }
        var req = URLRequest(url: u)
        req.httpMethod = "GET"
        req.timeoutInterval = timeout
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let o = NetSync.run(session: session(for: proxy), request: req, timeout: timeout)
        let status = NetSync.statusCode(o)
        let obj = (try? JSONSerialization.jsonObject(with: o.data ?? Data()) as? [String: Any])
        guard status == 200, let data = obj?["data"] as? [String: Any],
              let limit = data["limit"] as? Double, limit > 0,
              let usage = data["usage"] as? Double else { return nil }
        return usage >= limit ? .zero : .ok
    }

    /// new-api 系: GET /dashboard/billing/subscription(hard_limit_usd) + /dashboard/billing/usage(total_usage)
    private static func newAPIBillingBalance(base: String, key: String, timeout: TimeInterval, proxy: String?) -> BalanceStatus? {
        let s = session(for: proxy)
        func fetch(_ path: String) -> Double? {
            guard let u = URL(string: base + path) else { return nil }
            var req = URLRequest(url: u)
            req.httpMethod = "GET"
            req.timeoutInterval = timeout
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            // 必须传 request 而不是 url:传 url 会丢掉刚设置的 Authorization 头,
            // 请求以无认证发出 → 401 → 余额查询永远失败
            let o = NetSync.run(session: s, request: req, timeout: timeout)
            let obj = try? JSONSerialization.jsonObject(with: o.data ?? Data()) as? [String: Any]
            return NetSync.statusCode(o) == 200 ? (obj?["total_usage"] as? Double ?? obj?["hard_limit_usd"] as? Double) : nil
        }
        // subscription 返回 hard_limit_usd;usage 返回 total_usage;两个都拿到才算数
        guard let u = URL(string: base + "/dashboard/billing/subscription") else { return nil }
        var req = URLRequest(url: u)
        req.httpMethod = "GET"
        req.timeoutInterval = timeout
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let o = NetSync.run(session: s, request: req, timeout: timeout)
        let hardLimit = (try? JSONSerialization.jsonObject(with: o.data ?? Data()) as? [String: Any])?["hard_limit_usd"] as? Double
        guard NetSync.statusCode(o) == 200, let limit = hardLimit else { return nil }
        guard let usage = fetch("/dashboard/billing/usage") else { return nil }
        // 单位不一致:hard_limit_usd 是美元,total_usage 沿用 OpenAI 旧 billing 口径是「美分」
        // (new-api/one-api 均返回 amount*100)。直接比较会把「$100 额度用了 $5」算成
        // 500 >= 100 → 误判无余额
        return usage / 100 >= limit ? .zero : .ok
    }

    /// - Parameter preferredModel: 用户实际激活的模型(new-api TestModel 思路),探测时优先验证它
    /// - Parameter modelProbeTimes: 模型 → 上次被探测的时间戳(监控轮换用)。nil=不轮换
    /// - Parameter probePool: chat 探测池。nil=沿用站点 /models 目录;非 nil 时**只探这份**
    ///   (监控传用户勾选的模型,站点目录里的其它模型与本次监控无关)
    /// - Parameter knownNeedsProxy: 上轮已判定「直连必被地域/合规封锁、经代理可用」。
    ///   为 true 时本轮先走代理,不再白打一次注定 403 的直连;代理侧仍不通才回退直连复核
    public static func test(url: String, key: String, timeout: TimeInterval = 12, proxy: String? = nil, preferredModel: String? = nil, modelProbeTimes: [String: TimeInterval]? = nil, importedModels: [String]? = nil, probePool: [String]? = nil, knownNeedsProxy: Bool = false, styleHint: String? = nil) -> APITestResult {
        let p = proxy?.trimmingCharacters(in: .whitespaces)
        if knownNeedsProxy, let p, !p.isEmpty {
            let via = testOnce(url: url, key: key, timeout: timeout, proxy: p, preferredModel: preferredModel, modelProbeTimes: modelProbeTimes, importedModels: importedModels, probePool: probePool, styleHint: styleHint)
            if via.skippedForCooldown { return via }
            if via.ok {
                return APITestResult(ok: true, style: via.style, models: via.models,
                                     detail: via.detail + " | 需代理(本轮跳过直连)",
                                     authFailed: false, needsProxy: true,
                                     quotaExhausted: via.quotaExhausted, chatDegraded: via.chatDegraded,
                                     workingModels: via.workingModels, quotaModels: via.quotaModels, failedModels: via.failedModels,
                                     latencyMs: via.latencyMs, modelLatencies: via.modelLatencies,
                                     transientFailure: false, reachabilityOnly: via.reachabilityOnly)
            }
            // 代理侧也不通才回退直连一次:可能是本机代理挂了,也可能是地区限制解除
            // (或 key 真失效)。直连恢复可用就不再标 needsProxy,下轮回到常规路径
            let direct = testOnce(url: url, key: key, timeout: timeout, proxy: nil, preferredModel: preferredModel, modelProbeTimes: modelProbeTimes, importedModels: importedModels, probePool: probePool, styleHint: styleHint)
            if direct.ok { return direct }
            if direct.authFailed, !via.authFailed { return direct }
            // 两侧都失败:暂时性 = 两侧都暂时(一侧被明确拒绝就不是网络问题)
            return APITestResult(ok: false, style: via.style, models: via.models,
                                 detail: via.detail, authFailed: via.authFailed,
                                 needsProxy: true, quotaExhausted: via.quotaExhausted,
                                 chatDegraded: via.chatDegraded, workingModels: via.workingModels,
                                 quotaModels: via.quotaModels, failedModels: via.failedModels, latencyMs: via.latencyMs,
                                 modelLatencies: via.modelLatencies,
                                 transientFailure: via.transientFailure && direct.transientFailure)
        }
        // 先按真实环境(直连)测试;直连失败且配置了代理时补测代理,并标记需代理
        let direct = testOnce(url: url, key: key, timeout: timeout, proxy: nil, preferredModel: preferredModel, modelProbeTimes: modelProbeTimes, importedModels: importedModels, probePool: probePool, styleHint: styleHint)
        if direct.ok || direct.skippedForCooldown { return direct }
        if p == nil || p!.isEmpty {
            return direct
        }
        // 这里曾额外用 `|| direct.authFailed` 短路:直连被判「key 失效」就不补测代理。
        // 但区域/合规封锁返回的正是 JSON 403(真实事故:tokenharbor
        // 「API access from your region is not available」),key 有效、经代理 200,
        // 短路把这类 key 直接判死,用户配好的代理一次都没用上
        let via = testOnce(url: url, key: key, timeout: timeout, proxy: p, preferredModel: preferredModel, modelProbeTimes: modelProbeTimes, importedModels: importedModels, probePool: probePool, styleHint: styleHint)
        if via.ok {
            // 必须透传探测明细:只拷 ok/models/detail 会把 workingModels/quotaModels/延迟/
            // quotaExhausted 全部丢掉 → 需代理的 key 导入时限流模型不被排除、监控图无延迟、
            // 无额度被误判为可用
            return APITestResult(ok: true, style: via.style, models: via.models,
                                 detail: via.detail + " | 直连失败,需代理,经代理验证通过",
                                 authFailed: false, needsProxy: true,
                                 quotaExhausted: via.quotaExhausted, chatDegraded: via.chatDegraded,
                                 workingModels: via.workingModels, quotaModels: via.quotaModels, failedModels: via.failedModels,
                                 latencyMs: via.latencyMs, modelLatencies: via.modelLatencies,
                                 reachabilityOnly: via.reachabilityOnly)
        }
        // 两路都失败:直连拿到了 key 级结论(401/403)而代理侧只是连不通
        // (超时/无响应)→ 保留直连结论,别把代理故障说成 key 失效
        if direct.authFailed, !via.authFailed { return direct }
        return via
    }

    private static func testOnce(url: String, key: String, timeout: TimeInterval = 12, proxy: String? = nil, preferredModel: String? = nil, modelProbeTimes: [String: TimeInterval]? = nil, importedModels: [String]? = nil, probePool: [String]? = nil, styleHint: String? = nil) -> APITestResult {
        let base = Parser.normalizeURL(url) ?? url
        let styleHint = styleHint ?? Parser.apiStyle(for: url)
        let candidates = endpointCandidates(base)
        let s = session(for: proxy)

        var lastErr = "无"
        let style = ""
        var authFailed = false
        // 暂时性网络层失败标记(超时/不可达):健康扫描防抖判定依据。
        // 服务端明确应答(HTTP 任意状态)反证网络层可达 → 非暂时性
        var sawTransient = false
        // 目录可选；显式模型应始终用自己的请求验证，不能借用占位模型结果。
        func probeChatModels(_ models: [String], catalogDetail: String, catalogAuthFailed: Bool = false) -> APITestResult {
            var lastErr = "无"
            var style = ["anthropic", "responses"].contains(styleHint ?? "") ? styleHint! : "openai"
            // models 200 后补测 chat 端点(用渠道真实模型,伪模型 test 会被网关先以 400 拒绝):
            // chat 探测多模型(上限 4,free 字样模型优先):单个模型 429 不代表整 key 无额度。
            // 任一模型返回聊天内容 → key 可用;探测过的模型全部 quota → 才判无额度;
            // 401/403 仅在没有任何可用模型时才判 key 失效(见下方 gatedModels 注释)。
            // 真实事故:4 模型中首选 composer 429、
            // glm-5.3-free 可用,旧逻辑只试第一个,整 key 误入额度区看不到
            let probeOrder: [String]
            if let pool = probePool, !pool.isEmpty {
                probeOrder = configuredProbeOrder(pool, preferred: preferredModel,
                                                  modelProbeTimes: modelProbeTimes)
            } else {
                probeOrder = chatProbeOrder(models, preferred: preferredModel,
                                            modelProbeTimes: modelProbeTimes,
                                            importedModels: importedModels)
            }
            var working: [String] = []
            var quotaModels: [String] = []
            var failedModels: [String] = []
            var degradedModel: (String, Int)? = nil
            var authModel: (String, Int)? = nil
            var gatedModels: [String] = []
            var firstWorkingLatency: Double? = nil
            var skippedCount = 0
            var cooldownDetail: String?
            var modelLatencies: [String: Double] = [:]
            for probe in probeOrder {
                let chat = chatHealthCheck(base: base, key: key, timeout: timeout, proxy: proxy, model: probe, style: style)
                if let detectedStyle = chat.style { style = detectedStyle }
                if chat.skippedForCooldown {
                    skippedCount += 1
                    cooldownDetail = chat.detail
                    continue
                }
                if let st = chat.authStatus {
                    // 401/403 曾经一律判「key 失效」短路。真实事故(vyceai, 2026-09-23):
                    // 站点按模型限权 —— 同一把 key,deepseek-v4.1 chat 200,而
                    // qwen3.8-flash 403;首选模型已探活时,403 只说明该模型不对这把
                    // key 开放,不是 key 死了。有可用模型就继续,403 只记账
                    if authModel == nil { authModel = (probe, st) }
                    gatedModels.append(probe)
                    failedModels.append(probe)
                    // 403 可能只限制当前模型，继续验证其余模型才能判断整把 key。
                    if st == 401 && working.isEmpty { break }
                    continue
                }
                if let ms = chat.latencyMs { modelLatencies[probe] = ms }
                if chat.quota != nil { quotaModels.append(probe); continue }
                if let st = chat.degraded {
                    failedModels.append(probe)
                    if degradedModel == nil { degradedModel = (probe, st) }
                    if let detail = chat.detail { lastErr = detail }
                    continue
                }
                if chat.networkError {
                    failedModels.append(probe)
                    // 全部 chat 路径超时/无响应:模型不可达,绝不能计入 working
                    // (归入 degraded,与 5xx「服务不可用」同向)
                    if degradedModel == nil { degradedModel = (probe, 0) }
                    continue
                }
                if chat.invalidResponse {
                    failedModels.append(probe)
                    // 显式配置的模型已实际请求失败，不能退化成仅目录可达。
                    if (probePool ?? []).contains(probe) || preferredModel == probe {
                        if degradedModel == nil { degradedModel = (probe, chat.invalidStatus ?? 0) }
                        lastErr = chat.detail ?? "没有收到有效对话内容"
                    }
                    continue
                }
                if let ms = chat.latencyMs {
                    working.append(probe)
                    if firstWorkingLatency == nil { firstWorkingLatency = ms }
                }
            }
            if skippedCount > 0, skippedCount == probeOrder.count {
                return APITestResult(ok: false, style: style, models: models,
                                     detail: cooldownDetail ?? "服务端限流冷却中",
                                     authFailed: false, skippedForCooldown: true)
            }
            let realModels = Set(models + (probePool ?? []) + (preferredModel.map { [$0] } ?? []))
            let reportedFailures = failedModels.filter { realModels.contains($0) }
            if let (m, st) = authModel, working.isEmpty {
                return APITestResult(ok: false, style: style, models: models,
                                     detail: "\(catalogDetail), 但 chat 端点 HTTP \(st)(\(m) 认证失败/key 失效)",
                                     authFailed: true, quotaModels: quotaModels.filter { realModels.contains($0) },
                                     failedModels: reportedFailures, modelLatencies: modelLatencies)
            }
            // models 为空时探测用的是占位 "test",不得混进返回模型列表;有真实模型才重排
            let hasRealModels = !models.isEmpty
            if !working.isEmpty {
                let q = quotaModels.isEmpty ? "" : ",其中 \(quotaModels.count) 个模型限流(\(quotaModels.prefix(3).joined(separator: "、"))\(quotaModels.count > 3 ? " 等" : ""))"
                let g = gatedModels.isEmpty ? "" : ",\(gatedModels.count) 个模型本 key 无权限(\(gatedModels.prefix(2).joined(separator: "、"))\(gatedModels.count > 2 ? " 等" : ""))"
                let probedModels = Set(working + quotaModels)
                let catalog = Set(models)
                let reordered = hasRealModels
                    ? (working.filter { catalog.contains($0) } + models.filter { !probedModels.contains($0) } + quotaModels.filter { catalog.contains($0) })
                    : models
                return APITestResult(ok: true, style: style, models: reordered,
                                     detail: "\(catalogDetail)" + (hasRealModels ? ", \(models.count) 个模型" : "") + q + g,
                                     authFailed: false,
                                     workingModels: working.filter { realModels.contains($0) },
                                     quotaModels: quotaModels.filter { realModels.contains($0) }, failedModels: reportedFailures,
                                     latencyMs: firstWorkingLatency,
                                     modelLatencies: modelLatencies.isEmpty ? nil : modelLatencies)
            }
            if let (m, st) = degradedModel {
                let stDesc = st == 0 ? "超时/无响应" : "HTTP \(st)"
                return APITestResult(ok: false, style: style, models: models,
                                     detail: "\(catalogDetail), 但 chat 端点 \(stDesc)(\(m) 服务不可用/限流)" + (lastErr == "无" ? "" : " | \(lastErr)"),
                                     authFailed: catalogAuthFailed, quotaModels: quotaModels.filter { realModels.contains($0) },
                                     failedModels: reportedFailures, modelLatencies: modelLatencies,
                                     transientFailure: !catalogAuthFailed && failedModels.count > 0 && modelLatencies.isEmpty && st == 0)
            }
            if !quotaModels.isEmpty, !realModels.isEmpty {
                return APITestResult(ok: true, style: style, models: models,
                                     detail: "\(catalogDetail), 但探测的 \(quotaModels.count) 个模型均 quota exhausted(无额度)",
                                     authFailed: false, quotaExhausted: true, quotaModels: quotaModels.filter { realModels.contains($0) },
                                     failedModels: reportedFailures, modelLatencies: modelLatencies)
            }
            return APITestResult(ok: true, style: style, models: models,
                                 detail: "\(catalogDetail)，未验证对话模型",
                                 authFailed: false, failedModels: reportedFailures, reachabilityOnly: true)
        }

        for ep in candidates {
            guard let u = URL(string: ep) else { continue }
            var req = URLRequest(url: u)
            req.httpMethod = "GET"
            req.timeoutInterval = timeout
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

            let o = NetSync.run(session: s, request: req, timeout: timeout)
            let status = NetSync.statusCode(o)
            // 不可达(DNS/拒连/离线/TLS)→ 备用候选必同败,不再等满第二个超时
            if status == 0, NetSync.isUnreachable(o) { break }
            let data = o.data
            let body = String(data: data ?? Data(), encoding: .utf8) ?? ""
            let isJSON = isJSONBody(body)
            var models: [String] = []
            if status == 200, isJSON,
               let obj = try? JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any],
               let arr = obj["data"] as? [[String: Any]] {
                for m in arr {
                    if let id = m["id"] as? String, !id.isEmpty { models.append(id) }
                }
            }

            // 401/403 需区分「认证失败」与「CF 盾拦截」:盾页是 HTML(如 Cloudflare 挑战页),
            // key 本身可能有效、经代理可达;误标 authFailed 会短路后续代理补测(真实事故:某中转站多代理链)
            // 区域封锁 403 同理——它是 JSON,但说的是所在地而非 key
            let clientRestricted = isClientRestrictedBody(body)
            if (status == 401 || status == 403) && !isHTMLBody(body) && !isGeoBlockBody(body) && !clientRestricted {
                authFailed = true
            }
            if status == 200 {
                // 200 但非 JSON(SPA/前端兜底页,任何 key 都 200)→ 不是 API 端点,继续下一候选
                guard isJSON else {
                    lastErr = "GET \(ep) → 200 但非 JSON(疑似前端兜底页)"
                    continue
                }
                return probeChatModels(models, catalogDetail: "GET \(ep) → 200")
            }
            if status == 0 { sawTransient = true }
            let restrictionNote = clientRestricted ? "（渠道策略限制探测客户端，key 状态未知）" : ""
            lastErr = "GET \(ep) → \(status == 0 ? "超时/无响应" : "HTTP \(status)")\(restrictionNote)"
        }

        if probePool?.isEmpty == false || preferredModel?.isEmpty == false {
            return probeChatModels([], catalogDetail: "模型目录不可用\(authFailed ? "（认证被拒绝）" : "")，使用已配置模型",
                                   catalogAuthFailed: authFailed)
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
                                 authFailed: false, reachabilityOnly: !chat.3)
        }
        authFailed = authFailed || chat.1
        lastErr += "; \(chat.2)"
        // 服务端明确拒绝(401/403)或任何 HTTP 应答都不是「暂时性」;纯网络层失败才是
        return APITestResult(ok: false, style: style, models: [], detail: lastErr,
                             authFailed: authFailed, transientFailure: sawTransient && !authFailed)
    }

    /// chat 探测模型采样:preferredModel(用户实际激活的模型)置顶 —— 显示可用
    /// 但用户用某个特定模型失败是高频反馈,探测必须优先覆盖它(new-api TestModel 思路);
    /// 其次用户显式导入的模型(真实事故 dc403556 反馈:只导入 3 个模型,探测却拿站
    /// 点全量 113 个模型轮换,两个导入的 GLM 排在 110 个未选模型后面迟迟测不到);
    /// 再次 free/试用字样(免费档最可能通,真实中转站常按模型限额),其余保序;
    /// 上限 4 个 —— 模型少全试不加压,模型多也只花 4 次请求
    public static func chatProbeOrder(_ models: [String], preferred: String? = nil, modelProbeTimes: [String: TimeInterval]? = nil, importedModels: [String]? = nil) -> [String] {
        let capped = models.isEmpty ? ["test"] : models
        let pref = preferred.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        // 导入模型提升优先级:去重、且只保留站点当前列表里仍存在的(站方下架后不再探,
        // 与「站点列表为准」一致);激活模型若同时在导入列表里,它已由 pref 置顶,不重复占槽
        var importedInList: [String] = []
        if let importedModels, !importedModels.isEmpty {
            let seen = Set(importedModels)
            importedInList = capped.filter { seen.contains($0) && pref?.caseInsensitiveCompare($0) != .orderedSame }
        }
        // 激活模型在目录中的原拼写(大小写不敏感匹配):因大小写差异漏探过;
        // 不在目录里则不置顶(站点列表为准,与 ≤4 分支及回归约定一致)
        let pinned: String? = pref.flatMap { p in capped.first { $0.caseInsensitiveCompare(p) == .orderedSame } }
        // 轮换语义:每轮仍只测 4 个(额度/时延下限),但激活模型置顶后,其余槽位按
        // 「从未测过 > 最久未测」轮换 —— 否则第 5 个以后的模型永远轮不到,灰格永不填
        // (真实反馈:模型条一直没进度,用户以为模型坏了)。N 个模型 ≈ ⌈(N-1)/3⌉ 轮全覆盖
        if let times = modelProbeTimes, !times.isEmpty, capped.count > 4 {
            var rest = capped
            if let pinned { rest.removeAll { $0 == pinned } }
            rest = rest.filter { !importedInList.contains($0) }
            let freeFirst = rest.filter { $0.lowercased().contains("free") }
            let others = rest.filter { !$0.lowercased().contains("free") }
            let pool = importedInList + freeFirst + others
            let neverProbed = pool.filter { times[$0] == nil }
            let probed = pool.filter { times[$0] != nil }
                .sorted { (times[$0] ?? 0) < (times[$1] ?? 0) }   // 最久未测优先
            var order: [String] = []
            if let pinned { order.append(pinned) }
            order.append(contentsOf: (neverProbed + probed).prefix(4 - order.count))
            return order
        }
        // preferred 绝对置顶(free 优先规则不得覆盖它),导入模型次之,其余按 free 优先排序
        if let pinned {
            let rest2 = capped.filter { $0 != pinned }
            let importedRest = rest2.filter { importedInList.contains($0) }
            let others = rest2.filter { !importedInList.contains($0) }
            let freeFirst = others.filter { $0.lowercased().contains("free") }
            let rest3 = others.filter { !$0.lowercased().contains("free") }
            return Array(([pinned] + importedRest + freeFirst + rest3).prefix(4))
        }
        let importedOnly = capped.filter { importedInList.contains($0) }
        let rest = capped.filter { !importedInList.contains($0) }
        let freeFirst = rest.filter { $0.lowercased().contains("free") }
        let others = rest.filter { !$0.lowercased().contains("free") }
        return Array((importedOnly + freeFirst + others).prefix(4))
    }

    /// 监控探测池 = 用户勾选的模型,站点 /models 目录里的其余模型一律不探。
    /// 真实反馈(tokenharbor): 目录 68 个模型,勾选的 2 个里非激活那个排在一串
    /// 「从未测过」的目录模型后面,13 小时才补到一格;而监控真正要回答的是
    /// 「我在用的模型现在还好不好」。上限仍 4 次请求:激活模型置顶,其余按
    /// 「从未测过 > 最久未测」在勾选范围内轮换,勾得多也不会加压
    public static func configuredProbeOrder(_ pool: [String], preferred: String?, modelProbeTimes: [String: TimeInterval]?) -> [String] {
        var seen = Set<String>()
        let uniq = pool.filter { seen.insert($0).inserted }
        let trimmed = preferred?.trimmingCharacters(in: .whitespaces)
        let pinned = (trimmed?.isEmpty == false) ? trimmed : nil
        var order: [String] = []
        if let pinned { order.append(pinned) }   // 激活模型即便不在勾选列表里也要测
        let rest = uniq.filter { $0 != pinned }
        let slots = 4 - order.count
        if let times = modelProbeTimes, !times.isEmpty, rest.count > slots {
            let never = rest.filter { times[$0] == nil }
            let probed = rest.filter { times[$0] != nil }
                .sorted { (times[$0] ?? 0) < (times[$1] ?? 0) }
            order.append(contentsOf: (never + probed).prefix(slots))
        } else {
            order.append(contentsOf: rest.prefix(slots))
        }
        return order
    }

    /// POST chat 健康检查结果
    private struct ChatProbeOutcome {
        var style: String?
        var detail: String?
        var quota: Int?
        var degraded: Int?
        var authStatus: Int?
        var latencyMs: Double?
        /// 所有 chat 路径都拿不到 HTTP 状态(超时/连接失败):chat 端点不可达。
        /// 不得当成「模型可用」—— /models 200 但 chat 挂死的网关,旧逻辑整 key 判 ok,
        /// 与 5xx 判 degraded(移出可用列表)方向完全相反
        var networkError = false
        var skippedForCooldown = false
        var invalidResponse = false
        var invalidStatus: Int?
    }

    private static let cooldownLock = NSLock()
    private static var cooldowns: [String: (until: Date, outcome: ChatProbeOutcome)] = [:]

    // 使用摘要做索引，不在缓存中保留凭据；按协议路由、模型和代理隔离，避免
    // OpenAI Chat 的限流阻止 Responses/Anthropic 探测。
    private static func cooldownID(base: String, route: String, style: String, key: String, proxy: String?, model: String) -> String {
        let data = (try? JSONEncoder().encode([base, route, style, key, proxy ?? "", model])) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func retryDelay(_ response: URLResponse?) -> TimeInterval? {
        guard let value = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = Double(value), seconds.isFinite, seconds > 0 { return min(seconds, 86400) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value), date > Date() else { return nil }
        return min(date.timeIntervalSinceNow, 86400)
    }

    /// - quota: 429/402 且 body 明确额度耗尽关键词
    /// - degraded: 429 限流(无 quota 词)/402/424/5xx → 服务不可用
    /// - authStatus: 401/403(非 HTML 盾页)→ 认证失败/key 失效。/models 常是公共端点(无 key 也 200),
    ///   只有 chat 探测能发现 key 失效;遗漏会让无额度/失效 key 的条目刷新后仍判 ok(真实事故:ollama.com
    ///   /models 200 但 chat 401,条目一直 health=ok 不被自动移出)
    private static func chatHealthCheck(base: String, key: String, timeout: TimeInterval, proxy: String?, model: String, style: String = "openai", canFallback: Bool = true, stream: Bool = true, useCooldown: Bool = true) -> ChatProbeOutcome {
        let base = Parser.normalizeURL(base) ?? base
        let hasVersion = base.range(of: #"/v[0-9]+(?:beta[0-9]*)?$"#, options: .regularExpression) != nil
        let native = style == "anthropic"
        let suffix = native ? "/messages" : (style == "responses" ? "/responses" : "/chat/completions")
        let chatPaths = hasVersion ? [suffix] : [suffix, "/v1" + suffix]
        // A base without an explicit version exposes two equivalent mounts. A
        // rate limit on either mount applies to the same upstream operation;
        // using one scope prevents a later retry from bypassing the cooldown by
        // switching between `/chat/...` and `/v1/chat/...`. Keep versioned bases
        // keyed by their concrete route and preserve protocol isolation below.
        let cooldownRoute = chatPaths.count > 1 ? "__mount-family__" : base + (chatPaths.first ?? suffix)
        let s = session(for: proxy)
        var sawNetworkError = false
        var lastFailure: String?
        var lastStatus: Int?
        var cooldownSkippedCount = 0
        var cooldownOutcome: (until: Date, outcome: ChatProbeOutcome)?
        for path in chatPaths {
            guard let u = URL(string: base + path) else { continue }
            let cooldownKey = cooldownID(base: base, route: cooldownRoute, style: style, key: key, proxy: proxy, model: model)
            if useCooldown {
                cooldownLock.lock()
                let cached = cooldowns[cooldownKey]
                if let cached, cached.until <= Date() { cooldowns.removeValue(forKey: cooldownKey) }
                cooldownLock.unlock()
                if let cached, cached.until > Date() {
                    cooldownSkippedCount += 1
                    cooldownOutcome = cached
                    continue
                }
            }
            var req = URLRequest(url: u)
            req.httpMethod = "POST"
            req.timeoutInterval = timeout
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            if native {
                req.setValue(key, forHTTPHeaderField: "x-api-key")
                req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            }
            // stream:true 按真实使用形态探测:非流式 OK 但流式转换坏的中转站会被识别。
            // 判定兼容两种响应:SSE(data: 行)与普通 JSON —— 宽松以兼容各网关形态
            let payload: [String: Any] = style == "responses"
                ? ["model": model, "input": "ping", "max_output_tokens": 16, "stream": stream, "store": false]
                : ["model": model, "max_tokens": 1, "stream": stream, "messages": [["role": "user", "content": "ping"]]]
            req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
            let started = Date()
            let o = NetSync.run(session: s, request: req, timeout: timeout)
            let latencyMs = Date().timeIntervalSince(started) * 1000
            let status = NetSync.statusCode(o)
            let body = String(data: o.data ?? Data(), encoding: .utf8) ?? ""
            if status != 0 {
                lastStatus = status
                lastFailure = "HTTP \(status)：" + (status == 200 ? "没有有效对话内容" : "模型请求未通过")
            }
            // HTML 盾页(CF 挑战/basic-auth realm)≠ 认证失败,与 /models 探测口径一致:
            // /models 已返回 JSON 200 证明 key 有效,chat 撞盾页不得判 authFailed,
            // 否则 reconcile 会把活 key 当死 key 删除401/403 + JSON 才判认证失败,HTML 盾页同等豁免
            if (status == 401 || status == 403), isClientRestrictedBody(body) {
                return ChatProbeOutcome(style: style,
                                        detail: "HTTP \(status)：渠道策略限制探测客户端，key 状态未知",
                                        degraded: status)
            }
            if (status == 401 || status == 403) && !isHTMLBody(body) && !isGeoBlockBody(body) {
                return ChatProbeOutcome(style: style, detail: lastFailure, authStatus: status)
            }
            if native, status == 400 { return ChatProbeOutcome(style: "anthropic", degraded: status) }
            if status == 404 || status == 405 { continue }
            if status == 403 { continue }   // 盾页/地域封锁:跳过本候选,不误判 authFailed
            if status == 0 {
                if NetSync.isUnreachable(o) { return ChatProbeOutcome(networkError: true) }
                sawNetworkError = true
                continue
            }
            if status == 429 || status == 402 {
                let low = body.lowercased()
                if low.contains("quota") || low.contains("exhausted") || low.contains("balance") || low.contains("insufficient") {
                    return ChatProbeOutcome(style: style, detail: lastFailure, quota: status)
                }
                let delay = retryDelay(o.response)
                let result = ChatProbeOutcome(style: style,
                                              detail: delay.map { "服务端限流，暂停重复探测约 \(Int(ceil($0))) 秒" }, degraded: status)
                if useCooldown, let delay {
                    cooldownLock.lock()
                    cooldowns = cooldowns.filter { $0.value.until > Date() }
                    if cooldowns.count >= 512 { cooldowns.removeAll(keepingCapacity: true) }
                    cooldowns[cooldownKey] = (Date().addingTimeInterval(delay), result)
                    cooldownLock.unlock()
                }
                return result
            }
            if status == 424 || (500...599).contains(status) {
                return ChatProbeOutcome(style: style, detail: lastFailure, degraded: status)
            }
            if status == 200 {
                // 200 + 非 HTML 响应体才计可用与延迟:流式网关回 SSE(data: 行),
                // 普通网关回 JSON;空体/前端兜底页不算
                if isSuccessfulChatBody(body, style: style) {
                    return ChatProbeOutcome(style: style, detail: "POST \(base)\(path) → 200", latencyMs: latencyMs)
                }
                continue
            }
        }
        if useCooldown, cooldownSkippedCount == chatPaths.count, let cooldownOutcome {
            var result = cooldownOutcome.outcome
            result.skippedForCooldown = true
            result.detail = "服务端限流，暂停重复探测约 \(Int(ceil(cooldownOutcome.until.timeIntervalSinceNow))) 秒"
            return result
        }
        // 目录形状不能决定协议；仅路由缺失或无效响应允许试其他协议，认证/限流不绕过。
        if canFallback, !sawNetworkError {
            var alternatives = ["openai"]
            if native || Core.isClaudeModel(model) { alternatives.append("anthropic") }
            alternatives.append("responses")
            for candidate in alternatives where candidate != style {
                let result = chatHealthCheck(base: base, key: key, timeout: timeout, proxy: proxy, model: model,
                                             style: candidate, canFallback: false, stream: stream, useCooldown: useCooldown)
                if !result.invalidResponse { return result }
            }
        }
        return ChatProbeOutcome(style: style, detail: lastFailure,
                                networkError: sawNetworkError, invalidResponse: !sawNetworkError,
                                invalidStatus: lastStatus)
    }

    private static func openaiChatTest(base: String, key: String, timeout: TimeInterval, proxy: String? = nil) -> (Bool, Bool, String, Bool) {
        let hasV1 = base.hasSuffix("/v1") || base.hasSuffix("/api/v1")
        let chatPaths = hasV1 ? ["/chat/completions"] : ["/chat/completions", "/v1/chat/completions"]
        let s = session(for: proxy)
        var lastDesc = ""
        var authFailed = false
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
            let o = NetSync.run(session: s, request: req, timeout: timeout)
            let status = NetSync.statusCode(o)
            let body = String(data: o.data ?? Data(), encoding: .utf8) ?? ""
            if status == 0, NetSync.isUnreachable(o) {
                lastDesc = "POST \(base)\(path) → 连接不可达"
                break
            }
            let verified = status == 200 && isSuccessfulChatBody(body, style: "openai")
            let ok = verified || status == 400 || (status == 404 && isGatewayErrorBody(body))
            if ok {
                return (true, false, "POST \(base)\(path) → HTTP \(status)(网关可达)", verified)
            }
            // HTML 盾页(CF 挑战)/区域封锁 ≠ 认证失败,不计入 authFailed
            let clientRestricted = isClientRestrictedBody(body)
            if (status == 401 || status == 403) && !isHTMLBody(body) && !isGeoBlockBody(body) && !clientRestricted { authFailed = true }
            let restrictionNote = clientRestricted ? "（渠道策略限制探测客户端，key 状态未知）" : ""
            lastDesc = "POST \(base)\(path) → HTTP \(status == 0 ? "超时" : "\(status)")\(restrictionNote)" + (body.isEmpty ? "" : " \(body.prefix(100))")
        }
        return (false, authFailed, lastDesc, false)
    }

    static func isHTMLBody(_ s: String) -> Bool {
        s.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<")
    }

    /// 区域/合规封锁类 403(「API access from your region is not available」、
    /// US sanctions / export controls 等)。它描述的是客户端所在地,不是这把 key:
    /// 计成 authFailed 会让无代理环境把活 key 判死、健康扫描自动移出
    private static func isGeoBlockBody(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        return s.range(
            of: "(access from your (region|country)|region(s)? (is|are) not available|not available in your (region|country)|under [a-z ]{0,24}sanction|sanctions|export controls?|geo[- ]?blocked|regional(ly)? (unavailable|blocked|restricted))",
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    /// A provider may deny the probe client while allowing a particular CLI or
    /// agent. Treat only explicit client-policy wording as inconclusive; never
    /// imitate a client identity to get around that policy.
    private static func isClientRestrictedBody(_ s: String) -> Bool {
        let low = s.lowercased().replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        let explicitMarkers = [
            "unsupported client", "client is not supported", "client not supported",
            "unsupported user agent", "user agent is required", "user agent required",
            "user agent not supported", "user agent is not supported", "invalid user agent",
            "expected user agent", "must use user agent",
            "codex cli only", "only codex cli", "only for codex", "codex only",
            "cli only", "official cli required", "official client required",
            "client identity is required", "client must be codex", "must use codex",
            "only clients using codex", "only to codex cli", "restricted to codex cli",
            "codex cli is required", "codex cli required", "must use codex cli",
            "cli is required", "cli required", "must use the cli"
        ]
        if explicitMarkers.contains(where: { low.contains($0) }) { return true }
        return false
    }

    /// HTTP 成功码仍可能携带空体、错误 JSON 或前端兜底页。
    private static func isSuccessfulChatBody(_ body: String, style: String) -> Bool {
        func object(_ text: Substring) -> [String: Any]? {
            try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        }
        func isError(_ obj: [String: Any]) -> Bool {
            if let error = obj["error"], !(error is NSNull) { return true }
            if ["error", "response.failed", "response.cancelled"].contains(obj["type"] as? String ?? "") { return true }
            if ["failed", "cancelled"].contains(obj["status"] as? String ?? "") { return true }
            if let response = obj["response"] as? [String: Any] { return isError(response) }
            return false
        }
        func hasText(_ value: Any?) -> Bool {
            (value as? String)?.isEmpty == false
        }
        func hasContentBlock(_ block: [String: Any]) -> Bool {
            switch block["type"] as? String {
            case "text", "text_delta", "output_text": return hasText(block["text"])
            case "refusal": return hasText(block["refusal"])
            case "thinking", "thinking_delta": return hasText(block["thinking"])
            case "tool_use": return hasText(block["name"])
            case "input_json_delta": return hasText(block["partial_json"])
            default: return false
            }
        }
        func hasOutput(_ message: [String: Any]) -> Bool {
            if hasText(message["content"]) || hasText(message["reasoning_content"]) || hasText(message["refusal"]) {
                return true
            }
            if let blocks = message["content"] as? [[String: Any]], blocks.contains(where: hasContentBlock) {
                return true
            }
            if let calls = message["tool_calls"] as? [[String: Any]] {
                return calls.contains { call in
                    guard let function = call["function"] as? [String: Any] else { return false }
                    return hasText(function["name"]) || hasText(function["arguments"])
                }
            }
            return false
        }
        func isResponses(_ obj: [String: Any]) -> Bool {
            obj["object"] as? String == "response" || (obj["type"] as? String)?.hasPrefix("response.") == true
        }
        func isChat(_ obj: [String: Any]) -> Bool {
            // Responses uses a different endpoint and request body. Accepting its
            // envelope on a Chat route would persist a protocol clients cannot use.
            guard (style == "responses") == isResponses(obj) else { return false }
            if obj["object"] as? String == "response", let output = obj["output"] as? [[String: Any]] {
                return output.contains { item in
                    hasOutput(item) || (item["type"] as? String == "function_call" && hasText(item["name"]))
                }
            }
            if let choices = obj["choices"] as? [[String: Any]],
               choices.contains(where: { choice in
                   let message = choice["message"] as? [String: Any] ?? choice["delta"] as? [String: Any] ?? [:]
                   return hasOutput(message)
               }) {
                return true
            }
            switch obj["type"] as? String {
            case "response.output_text.delta", "response.refusal.delta", "response.reasoning_summary_text.delta", "response.reasoning_text.delta", "response.function_call_arguments.delta":
                return hasText(obj["delta"])
            case "response.output_item.added", "response.output_item.done":
                let item = obj["item"] as? [String: Any] ?? [:]
                return hasOutput(item) || (item["type"] as? String == "function_call" && hasText(item["name"]))
            case "response.completed":
                return isChat(obj["response"] as? [String: Any] ?? [:])
            case "message": return hasOutput(obj)
            case "message_start": return hasOutput(obj["message"] as? [String: Any] ?? [:])
            case "content_block_start": return hasContentBlock(obj["content_block"] as? [String: Any] ?? [:])
            case "content_block_delta": return hasContentBlock(obj["delta"] as? [String: Any] ?? [:])
            default: return false
            }
        }
        if let obj = object(body[...]) { return !isError(obj) && isChat(obj) }
        var hasChat = false
        var responsesStream = false
        var responsesCompleted = false
        for line in body.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("data:"), let obj = object(line.dropFirst(5)) else { continue }
            if isError(obj) { return false }
            let type = obj["type"] as? String ?? ""
            if type.hasPrefix("response.") {
                guard style == "responses" else { return false }
                responsesStream = true
            }
            if type == "response.completed" { responsesCompleted = true }
            if type == "response.incomplete",
               let response = obj["response"] as? [String: Any],
               let detail = response["incomplete_details"] as? [String: Any],
               detail["reason"] as? String == "max_output_tokens" { responsesCompleted = true }
            if isChat(obj) { hasChat = true }
        }
        return hasChat && (!responsesStream || responsesCompleted)
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

        let o = NetSync.run(session: s, request: req, timeout: timeout)
        let status = NetSync.statusCode(o)
        let body = String(data: o.data ?? Data(), encoding: .utf8) ?? ""
        let ok = status == 200 && isSuccessfulChatBody(body, style: "anthropic")
        // HTML 盾页(CF 挑战)/区域封锁 ≠ 认证失败
        let clientRestricted = isClientRestrictedBody(body)
        let authFail = (status == 401 || (status == 403 && !isHTMLBody(body) && !isGeoBlockBody(body))) && !clientRestricted
        return (ok, authFail,
                "POST \(messagesPath) → HTTP \(status == 0 ? "超时" : "\(status)")" + (clientRestricted ? "（渠道策略限制探测客户端，key 状态未知）" : "") + (body.isEmpty ? "" : " \(body.prefix(100))"))
    }

    /// 生成一条可直接粘贴运行的 curl(优先 chat,其次 models 探测)
    static public func curlCommand(
        url: String,
        key: String,
        model: String? = nil,
        styleHint: String? = nil
    ) -> String {
        let base = Parser.normalizeURL(url) ?? url
        let styleHint = styleHint ?? Parser.apiStyle(for: url)
        let anthropic = styleHint == "anthropic" || (styleHint == nil && model.map(Core.isClaudeModel) == true)

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
            let path = styleHint == "responses" ? "/responses" : "/chat/completions"
            let chatURL = hasV1 ? base + path : base + "/v1" + path
            let body = styleHint == "responses"
                ? "{\"model\":\(jsonString(model)),\"input\":\"hi\",\"max_output_tokens\":32,\"store\":false}"
                : "{\"model\":\(jsonString(model)),\"max_tokens\":32,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}"
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

    public static func testModelChat(base: String, key: String, model: String, timeout: TimeInterval = 12, proxy: String? = nil, styleHint: String? = nil) -> (ok: Bool, detail: String, style: String) {
        let styleHint = styleHint ?? Parser.apiStyle(for: base)
        let style = ["anthropic", "responses"].contains(styleHint ?? "") ? styleHint! : "openai"
        let result = chatHealthCheck(base: base, key: key, timeout: timeout, proxy: proxy, model: model,
                                     style: style, stream: false, useCooldown: false)
        return (result.latencyMs != nil,
                result.detail ?? "模型验证失败：端点不支持或请求超时/无响应",
                result.style ?? style)
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
        let o = NetSync.run(session: s, request: req, timeout: timeout)
        if o.error != nil && NetSync.statusCode(o) == 0 { return true }
        let status = NetSync.statusCode(o)
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
