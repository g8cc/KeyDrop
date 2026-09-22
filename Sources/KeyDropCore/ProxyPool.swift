import Foundation

/// CPA OAuth 账号 × 代理池自动绑定。
///
/// 背景(真实事故形态):CPA 每个 OAuth 凭证可带独立 proxy_url(Auth.ProxyURL,
/// 覆盖全局 proxy-url),但 CPA 本体没有任何代理池/自动绑定能力,账号一多只能
/// 逐个在管理界面里填。而「大量账号共享同一出口 IP」正是 grok 降智风控的典型
/// 触发形态;账号与出口 IP 稳定绑定(粘性)才是正确形态。KeyDrop 在 CPA 外面
/// 做这套编排:读代理列表 → 并发测连通 → 粘性分配 → 写回 auth 文件。
///
/// 设计原则:
/// 1. 粘性:账号已绑定且代理存活 → 原样保留,绝不洗牌(换 IP 本身就是风控事件)
/// 2. 替换:已绑代理死亡 → 从备用池按序取一个存活的顶上
/// 3. 文件即真相:绑定状态就存在 auth json 的 proxy_url 字段里,不另设绑定仓库,
///    CPA 热重载后立即生效,KeyDrop 重复运行天然幂等
/// 4. Docker:loopback 代理改写为 host.docker.internal(容器内可达),复用 CPAWriter 规则
public enum ProxyPool {

    // MARK: - 数据模型

    public struct PoolAccount: Equatable {
        public let path: String        // auth json 宿主机绝对路径
        public let fileName: String
        public let accountID: String   // email/name/sub,兜底文件名
        public let type: String        // "xai" 等,对应 json 的 type 字段
        public let disabled: Bool
        public let existingProxy: String?

        public init(path: String, fileName: String, accountID: String, type: String,
                    disabled: Bool, existingProxy: String?) {
            self.path = path
            self.fileName = fileName
            self.accountID = accountID
            self.type = type
            self.disabled = disabled
            self.existingProxy = existingProxy
        }
    }

    public struct PoolProxy: Equatable {
        public let url: String
        public var status: Status
        public var latencyMs: Double
        public enum Status: String { case untested, alive, dead }

        public init(url: String, status: Status, latencyMs: Double) {
            self.url = url
            self.status = status
            self.latencyMs = latencyMs
        }
    }

    /// untouched = 无代理可分且无旧绑定,文件完全不动(继续走全局 proxy-url)
    public enum PoolAction: String {
        case kept, assigned, replaced, cleared, untouched
    }

    public struct PoolBinding: Equatable {
        public let accountID: String
        public let fileName: String
        public let oldProxy: String?
        public let newProxy: String?
        public let action: PoolAction
        public let note: String

        public init(accountID: String, fileName: String, oldProxy: String?,
                    newProxy: String?, action: PoolAction, note: String) {
            self.accountID = accountID
            self.fileName = fileName
            self.oldProxy = oldProxy
            self.newProxy = newProxy
            self.action = action
            self.note = note
        }
    }

    // MARK: - 代理列表解析

    /// 解析代理列表文本:每行一条;# 开头为注释;裸 host:port 补 http://;
    /// 支持 http/https/socks5/socks5h/socks4;按首次出现去重。
    public static func loadProxyList(_ text: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if !line.contains("://") { line = "http://" + line }
            guard let comps = URLComponents(string: line), comps.host != nil, comps.host != "" else { continue }
            guard seen.insert(line).inserted else { continue }
            out.append(line)
        }
        return out
    }

    // MARK: - 账号扫描

    /// 扫描 auth-dir 下所有 *.json 凭证文件。types 为 nil 时不筛类型。
    /// 损坏的 json 跳过并记日志,不让一个坏文件废掉整批。
    public static func scanAccounts(authDir: String, types: Set<String>? = nil) -> [PoolAccount] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: authDir) else { return [] }
        var out: [PoolAccount] = []
        for f in files.sorted() where f.hasSuffix(".json") {
            let path = (authDir as NSString).appendingPathComponent(f)
            guard let data = fm.contents(atPath: path),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                AppLog.error("代理池: 无法解析 \(f),已跳过")
                continue
            }
            let type = obj["type"] as? String ?? ""
            if let types, !types.contains(type) { continue }
            let email = obj["email"] as? String
            let name = obj["name"] as? String
            let sub = obj["sub"] as? String
            let id = [email, name, sub].compactMap { $0 }.first { !$0.isEmpty } ?? (f as NSString).deletingPathExtension
            let proxy = [obj["proxy_url"], obj["proxy-url"]].compactMap { $0 as? String }.first { !$0.isEmpty }
            out.append(PoolAccount(
                path: path,
                fileName: f,
                accountID: id,
                type: type,
                disabled: obj["disabled"] as? Bool ?? false,
                existingProxy: proxy
            ))
        }
        return out
    }

    /// auth-dir 的默认位置:CPA config.yaml 同级的 auth-dir 目录(docker 挂载源)。
    public static func defaultAuthDir() -> String? {
        guard let cfg = CPAWriter.locateConfig() else { return nil }
        let dir = ((cfg as NSString).deletingLastPathComponent as NSString).appendingPathComponent("auth-dir")
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) && isDir.boolValue ? dir : nil
    }

    /// 未绑定独立代理的活跃账号(纯读,供巡检提醒用;禁用账号不算,用户手动停的不替他做主)。
    public static func unboundAccounts(authDir: String, types: Set<String>? = nil) -> [PoolAccount] {
        scanAccounts(authDir: authDir, types: types).filter { !$0.disabled && $0.existingProxy == nil }
    }

    // MARK: - 粘性绑定计划(纯函数,供单测)

    /// 返回 (绑定计划, 剩余备用代理)。
    ///
    /// 规则:
    /// - 既有绑定且代理存活 → kept(粘性,不动文件)
    /// - 既有绑定不在本次池内 → kept(视为用户在池外手动管理的代理,strictPoolOnly 才接管)
    /// - 既有绑定死亡 → replaced(从备用队列取下一个存活的)
    /// - 无绑定 → assigned(同理)
    /// - 备用耗尽:有死亡旧绑定的 cleared(删字段回落全局代理),无绑定的 untouched
    /// - 存活代理按列表顺序分配,保证确定性
    public static func planBinding(accounts: [PoolAccount], proxies: [PoolProxy], strictPoolOnly: Bool = false) -> (bindings: [PoolBinding], spares: [String]) {
        // 同 URL 多次出现时以首次状态为准;status 表与 alive 列表必须同源,
        // 否则会出现“status 说死了、alive 队列里又排上它”的自相矛盾分配
        var firstStatus: [String: PoolProxy.Status] = [:]
        var aliveOrder: [String] = []
        for p in proxies where firstStatus[p.url] == nil {
            firstStatus[p.url] = p.status
            if p.status == .alive { aliveOrder.append(p.url) }
        }
        let status = firstStatus
        let alive = aliveOrder
        var used = Set<String>()
        var bindings: [PoolBinding] = []
        var needProxy: [PoolAccount] = []

        for acc in accounts {
            guard let old = acc.existingProxy else {
                needProxy.append(acc)
                continue
            }
            let st = status[old] ?? .untested
            if st == .alive {
                bindings.append(PoolBinding(accountID: acc.accountID, fileName: acc.fileName,
                                            oldProxy: old, newProxy: old, action: .kept,
                                            note: "原绑定存活,粘性保留"))
                used.insert(old)
            } else if st == .untested && !strictPoolOnly {
                bindings.append(PoolBinding(accountID: acc.accountID, fileName: acc.fileName,
                                            oldProxy: old, newProxy: old, action: .kept,
                                            note: "代理不在本次池内,视为手动管理,保留原值"))
            } else {
                needProxy.append(acc)
            }
        }

        var queue = alive.filter { !used.contains($0) }
        for acc in needProxy {
            if !queue.isEmpty {
                let next = queue.removeFirst()
                let assigned = acc.existingProxy == nil
                bindings.append(PoolBinding(accountID: acc.accountID, fileName: acc.fileName,
                                            oldProxy: acc.existingProxy, newProxy: next,
                                            action: assigned ? .assigned : .replaced,
                                            note: assigned ? "新绑定" : "原代理不可用,已替换"))
            } else if let old = acc.existingProxy {
                bindings.append(PoolBinding(accountID: acc.accountID, fileName: acc.fileName,
                                            oldProxy: old, newProxy: nil, action: .cleared,
                                            note: "代理耗尽且原绑定不可用,删除字段回落全局代理"))
            } else {
                bindings.append(PoolBinding(accountID: acc.accountID, fileName: acc.fileName,
                                            oldProxy: nil, newProxy: nil, action: .untouched,
                                            note: "代理耗尽,继续走全局代理"))
            }
        }
        return (bindings, queue)
    }

    // MARK: - 写回 auth 文件

    /// 把 assigned/replaced/cleared 落到 auth json。kept/untouched 不写(粘性 = 零改动)。
    /// 返回实际写入的文件数。loopback 代理按 docker 部署形态改写(复用 CPAWriter 规则)。
    @discardableResult
    public static func apply(bindings: [PoolBinding], accounts: [PoolAccount], configContent: String) throws -> Int {
        let paths = Dictionary(accounts.map { ($0.fileName, $0.path) }, uniquingKeysWith: { a, _ in a })
        let fm = FileManager.default
        var written = 0
        for b in bindings {
            guard b.action == .assigned || b.action == .replaced || b.action == .cleared,
                  let path = paths[b.fileName] else { continue }
            guard let data = fm.contents(atPath: path),
                  var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                AppLog.error("代理池: 写入失败,无法解析 \(b.fileName)")
                continue
            }
            obj.removeValue(forKey: "proxy_url")
            obj.removeValue(forKey: "proxy-url")
            if let p = b.newProxy {
                obj["proxy_url"] = CPAWriter.rewriteProxyForDocker(p, configContent: configContent) ?? p
            }
            let out = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted])
            try out.write(to: URL(fileURLWithPath: path))
            written += 1
        }
        return written
    }

    // MARK: - 并发连通性检查

    /// 用系统 curl 并发测代理(统一支持 http/socks5/socks5h,Swift 原生 API 对 socks 支持不可靠)。
    /// 判活:收到任意 HTTP 状态码(403/429 也算,只证明出口可达目标站点);
    /// 407 = 代理要求认证(配错)按死亡计;超时/连接失败/解析失败 = 死亡。
    /// update 回调在检查线程上被调用,用于 CLI 进度点。
    public static func checkProxies(_ urls: [String], target: String, timeout: TimeInterval,
                                    concurrency: Int = 64, update: ((PoolProxy) -> Void)? = nil) -> [PoolProxy] {
        guard !urls.isEmpty else { return [] }
        let lock = NSLock()
        var results: [String: PoolProxy] = [:]
        let gate = DispatchSemaphore(value: max(1, concurrency))
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "keydrop.proxypool.check", attributes: .concurrent)

        for url in urls {
            group.enter()
            queue.async {
                defer { group.leave() }
                gate.wait()
                defer { gate.signal() }
                let result = probeOne(url: url, target: target, timeout: timeout)
                lock.lock()
                results[url] = result
                lock.unlock()
                update?(result)
            }
        }
        group.wait()
        // 按入参顺序返回,保证分配确定性
        return urls.compactMap { results[$0] }
    }

    public static func probeOne(url: String, target: String, timeout: TimeInterval) -> PoolProxy {
        let t = String(format: "%.0f", timeout)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        p.arguments = [
            "-x", url,
            "-sS", "-o", "/dev/null",
            "-m", t, "--connect-timeout", t,
            "-w", "%{http_code} %{time_total}",
            target
        ]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do {
            try p.run()
        } catch {
            return PoolProxy(url: url, status: .dead, latencyMs: 0)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(data: data, encoding: .utf8) ?? ""
        let parts = out.split(separator: " ")
        let code = parts.first.map(String.init) ?? "000"
        let latency = Double(parts.count > 1 ? parts[1] : "") ?? 0
        let alive = p.terminationStatus == 0 && code != "000" && code != "407"
        return PoolProxy(url: url, status: alive ? .alive : .dead, latencyMs: latency * 1000)
    }
}
