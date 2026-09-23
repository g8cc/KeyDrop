import Foundation
import KeyDropCore

/// 极简 HTTP 服务:固定 200 JSON 响应 / 或 404;支持作为 HTTP 代理转发
final class MockHTTPServer {
    private let listener: TCPServer
    var port: Int { listener.port }

    enum Mode {
        case openAI    // 200 {"data":[{id}]}
        case notFound  // 404 空
        case gateway404 // GET 全 404;POST /chat/completions → 404 + JSON error(网关可达,模型校验)
        case balanceOK    // /models 200 + /auth/key limit>usage(有余额)
        case balanceZero  // /models 200 + /auth/key usage>=limit(无余额)
        case balanceNoInfo // /models 200,余额接口 404
        case html200     // /models → 200 HTML 兜底页(假阳性);/v1/models → 401
        case quota429    // /models → 200;POST chat → 429 quota exhausted
        case chat401     // /models → 200(公共端点);POST chat → 401(认证失败/key 失效)
        case chat524     // /models → 200;POST chat → 424 服务不可用
        case manyModels  // /models → 200,8 个模型(触发 >5 选择器路径)
        case chatOK      // /models → 200 空列表;POST chat → 200(网关无模型列表但 chat 可用)
        case claudeModels // /models → 200,纯 claude 系(测 codex→claude 反向迁移)
        case nonChatModels // /models → 200,图生在前 + chat 家族在后(测激活模型不落图生)
        case dottedModels // /models → 200,7 个 stepfun 式模型(5 个含点、会被 looksLikeModel 域名规则误杀)
        case selectiveAuth // Authorization 含 invalid 的 key 返回 401,其余正常
        case selectiveModelQuota // /models 返回 4 模型(1 个 *-free + 3 限流);chat 仅 free 模型 200,其余 429 quota
        case cpaMgmt  // CPA 管理 API:config.yaml GET/PUT + auth-files 列表/下载/字段 PATCH(真实事故 v1.4.13)
    }
    // cpaMgmt 状态:跨线程访问,统一走锁
    let mgmtLock = NSLock()
    var cpaYAML = "# cpa-mgmt-sentinel\nport: 8317\n"
    var cpaPutBody = ""
    var cpaPatchBody = ""
    var cpaPatchName = ""
    var cpaAuthHeader = ""
    var cpaAuthFiles: [String: String] = [
        "acc-a.json": "{\"type\":\"xai\",\"email\":\"a@x.com\",\"proxy_url\":\"\"}"
    ]
    let mode: Mode

    init(mode: Mode = .openAI, proxy: Bool = false) throws {
        self.mode = mode
        listener = try TCPServer()
        Thread.detachNewThread { [weak self] in
            self?.serveLoop()
        }
    }

    private func serveLoop() {
        while true {
            guard let client = listener.accept() else { break }
            Thread.detachNewThread { [weak self] in
                self?.handle(client)
            }
        }
    }

    private func handle(_ client: SocketClient) {
        guard var req = client.readRequest() else { return }
        let headerOnly = req
        let line = headerOnly.components(separatedBy: "\r\n").first ?? ""
        let parts = line.components(separatedBy: " ")
        guard parts.count >= 2 else { return }
        let method = parts[0]
        let target = parts[1]
        // 仅 selectiveModelQuota 的 chat POST 需要 body 里的 model 字段来区分响应。
        // 其它模式一律不读 body → 行为与旧 mock 完全一致,不会因等待 body 而死锁。
        // readUntil 收满 \r\n\r\n 即返回,但 URLSession 常把 header+body 一并送达,
        // 所以先判断分隔符之后是否已有 >= content-length 的字节,已有就不再 recv
        // (否则 readBody 会对着已发完的流死等满 SO_RCVTIMEO,4 模型 × 3s 拖死测试)。
        if mode == .cpaMgmt {
            handleCPAMgmt(client, req, method, target)
            return
        }
        if mode == .selectiveModelQuota, method == "POST", target.contains("/chat/completions"),
           let r = headerOnly.lowercased().range(of: "content-length:"),
           let n = Int(headerOnly.lowercased()[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(while: { $0.isNumber })), n > 0 {
            var bodySoFar = ""
            if let sep = headerOnly.range(of: "\r\n\r\n") {
                bodySoFar = String(headerOnly[sep.upperBound...])
            }
            let have = bodySoFar.utf8.count
            req = have >= n ? headerOnly : headerOnly + client.readBody(toLength: n - have)
        }
        let authorization = req.components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("authorization:") } ?? ""
        let apiKey = req.components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("x-api-key:") } ?? ""
        // Both OpenAI and Anthropic probes carry the same credential in
        // different headers; selectiveAuth must model invalid credentials for
        // either protocol so a fallback probe cannot mask a 401.
        let invalidKey = authorization.contains("invalid") || apiKey.contains("invalid")
        // POST body 里的 model 字段(selectiveModelQuota 按模型区分响应):
        // JSON 形如 "model":"xxx",用捕获组直接取引号内值
        var requestedModel = ""
        if let re = try? NSRegularExpression(pattern: "\"model\"\\s*:\\s*\"([^\"]*)\""),
           let m = re.firstMatch(in: req, range: NSRange(req.startIndex..., in: req)), m.numberOfRanges >= 2,
           let gr = Range(m.range(at: 1), in: req) {
            requestedModel = String(req[gr])
        }

        if method == "GET" && target.hasPrefix("http://") {
            // HTTP 代理模式:绝对 URI,转发到目标
            if let url = URL(string: target), let host = url.host {
                let port = url.port ?? (url.scheme == "https" ? 443 : 80)
                let upstream = "\(host):\(port)"
                let path = url.path.isEmpty ? "/" : url.path
                let fwd = "GET \(path) HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n\r\n"
                if let sock = TCPServer.connect(host: upstream) {
                    sock.write(fwd)
                    let resp = sock.readResponse()
                    client.write(resp)
                    sock.close()
                } else {
                    client.write("HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n")
                }
            } else {
                client.write("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n")
            }
            client.close()
            return
        }

        var body = ""
        if mode == .selectiveModelQuota {
            if method == "GET", target.hasSuffix("/models") {
                // 4 个模型:仅 z-ai/glm-5.3-free 可用,composer/grok-4.5/grok-4.6 按模型限流
                body = "{\"data\":[" + [
                    "{\"id\":\"composer-2.5\",\"object\":\"model\"}",
                    "{\"id\":\"grok-4.5\",\"object\":\"model\"}",
                    "{\"id\":\"grok-4.6\",\"object\":\"model\"}",
                    "{\"id\":\"z-ai/glm-5.3-free\",\"object\":\"model\"}"
                ].joined(separator: ",") + "]}"
            } else if target.contains("/chat/completions") {
                if requestedModel.contains("free") {
                    body = "{\"id\":\"c\",\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"ok\"}}]}"
                } else {
                    body = "{\"error\":{\"code\":\"429\",\"message\":\"quota exhausted\"}}"
                }
            }
        } else if mode == .selectiveAuth && invalidKey {
            body = "{\"error\":{\"message\":\"Unauthorized\"}}"
        } else if mode == .selectiveAuth {
            body = "{\"data\":[{\"id\":\"grok-4.6\",\"object\":\"model\"}]}"
        } else if mode == .openAI {
            body = "{\"data\":[{\"id\":\"gpt-5.6-sol\",\"object\":\"model\"},{\"id\":\"glm-5.2\",\"object\":\"model\"}]}"
        } else if mode == .gateway404, method == "POST" {
            body = "{\"error\":{\"code\":\"UnsupportedModel\",\"message\":\"model does not support the agent plan feature\"}}"
        } else if mode == .balanceOK {
            if target.hasSuffix("/auth/key") {
                body = "{\"data\":{\"label\":\"t\",\"limit\":10,\"usage\":2}}"
            } else {
                body = "{\"data\":[{\"id\":\"gpt-5.6-sol\",\"object\":\"model\"}]}"
            }
        } else if mode == .balanceZero {
            if target.hasSuffix("/auth/key") {
                body = "{\"data\":{\"label\":\"t\",\"limit\":5,\"usage\":5}}"
            } else {
                body = "{\"data\":[{\"id\":\"gpt-5.6-sol\",\"object\":\"model\"}]}"
            }
        } else if mode == .balanceNoInfo {
            body = "{\"data\":[{\"id\":\"gpt-5.6-sol\",\"object\":\"model\"}]}"
        } else if mode == .html200 {
            if target.hasSuffix("/models") && !target.hasSuffix("/v1/models") {
                body = "<!doctype html><html><body>app</body></html>"
            } else if target.hasSuffix("/v1/models") {
                body = "{\"error\":{\"message\":\"Invalid token\"}}"
            }
        } else if mode == .quota429 {
            if target.hasSuffix("/models") {
                body = "{\"data\":[{\"id\":\"mimo-v2.5-pro\",\"object\":\"model\"}]}"
            } else if target.contains("/chat/completions") {
                body = "{\"error\":{\"code\":\"429\",\"message\":\"quota exhausted\",\"type\":\"limitation\"}}"
            }
        } else if mode == .chat401 {
            if target.hasSuffix("/models") {
                body = "{\"data\":[{\"id\":\"gpt-5.6-sol\",\"object\":\"model\"}]}"
            } else if target.contains("/chat/completions") {
                body = "{\"error\":{\"message\":\"Unauthorized\",\"type\":\"api_error\"}}"
            }
        } else if mode == .chat524 {
            if target.hasSuffix("/models") {
                body = "{\"data\":[{\"id\":\"gpt-5.6-sol\",\"object\":\"model\"}]}"
            } else if target.contains("/chat/completions") || target.contains("/responses") {
                body = "{\"error\":{\"message\":\"Service temporarily unavailable\",\"type\":\"api_error\"}}"
            }
        } else if mode == .manyModels {
            if target.hasSuffix("/models") {
                let items = (1...8).map { n in "{\"id\":\"model-\(n)-sample\",\"object\":\"model\"}" }
                body = "{\"data\":[" + items.joined(separator: ",") + "]}"
            }
        } else if mode == .chatOK {
            if target.hasSuffix("/models") {
                body = "{\"data\":[]}"
            } else if target.contains("/chat/completions") {
                body = "{\"id\":\"chatcmpl-1\",\"object\":\"chat.completion\",\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"ok\"}}]}"
            }
        } else if mode == .claudeModels {
            body = "{\"data\":[{\"id\":\"claude-sonnet-4-5\",\"object\":\"model\"},{\"id\":\"claude-opus-4-1\",\"object\":\"model\"}]}"
        } else if mode == .nonChatModels {
            body = "{\"data\":[{\"id\":\"dall-e-3\",\"object\":\"model\"},{\"id\":\"deepseek-v4-flash-0731\",\"object\":\"model\"}]}"
        } else if mode == .dottedModels {
            if target.hasSuffix("/models") {
                // 复刻 stepfun step_plan 真实返回:非白名单家族(step-*)+点分命名的
                // 新版模型名,旧的 looksLikeModel 过滤会把 5 个点分名当域名误杀
                let ids = ["step-3.7-flash", "stepaudio-2.5-tts", "stepaudio-2.5-asr",
                           "step-image-edit-2", "step-3.5-flash-2603", "step-3.5-flash", "step-5-preview"]
                body = "{\"data\":[" + ids.map { "{\"id\":\"\($0)\",\"object\":\"model\"}" }.joined(separator: ",") + "]}"
            } else if target.contains("/chat/completions") {
                body = "{\"id\":\"chatcmpl-1\",\"object\":\"chat.completion\",\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"ok\"}}]}"
            }
        }
        let status: String
        if mode == .selectiveModelQuota, target.contains("/chat/completions"), !requestedModel.contains("free") {
            status = "429 Too Many Requests"
        } else if mode == .selectiveAuth && invalidKey {
            status = "401 Unauthorized"
        } else if mode == .html200 && target.hasSuffix("/v1/models") {
            status = "401 Unauthorized"
        } else if mode == .quota429 && target.contains("/chat/completions") {
            status = "429 Too Many Requests"
        } else if mode == .chat401 && target.contains("/chat/completions") {
            status = "401 Unauthorized"
        } else if mode == .chat524 && (target.contains("/chat/completions") || target.contains("/responses")) {
            status = "424 Failed Dependency"
        } else if mode == .openAI || mode == .balanceOK || mode == .balanceZero || mode == .balanceNoInfo || mode == .quota429 || mode == .chat401 || mode == .manyModels || mode == .chatOK || mode == .claudeModels || mode == .nonChatModels || mode == .dottedModels || mode == .selectiveAuth || mode == .selectiveModelQuota || (mode == .chat524 && target.hasSuffix("/models")) {
            status = "200 OK"
        } else {
            status = "404 Not Found"
        }
        let resp = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        client.write(resp)
        client.close()
    }

    // MARK: - CPA 管理 API mock

    private func respond(_ client: SocketClient, _ code: Int, _ reason: String, _ body: String, contentType: String = "application/json") {
        let resp = "HTTP/1.1 \(code) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        client.write(resp)
        client.close()
    }

    private func handleCPAMgmt(_ client: SocketClient, _ req: String, _ method: String, _ target: String) {
        mgmtLock.lock()
        defer { mgmtLock.unlock() }
        cpaAuthHeader = req.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("authorization:") } ?? ""
        guard cpaAuthHeader.lowercased().hasPrefix("authorization: bearer test-key") else {
            respond(client, 401, "Unauthorized", "{\"error\":\"bad key\"}")
            return
        }
        // 读 body(PUT/PATCH):URLSession 常把 header+body 一并送达,先看分隔符后已有多少
        var bodyStr = ""
        if method == "PUT" || method == "PATCH" {
            if let sep = req.range(of: "\r\n\r\n") {
                bodyStr = String(req[sep.upperBound...])
            }
            if let r = req.lowercased().range(of: "content-length:"),
               let n = Int(req.lowercased()[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                   .prefix(while: { $0.isNumber })), n > 0, bodyStr.utf8.count < n {
                bodyStr += client.readBody(toLength: n - bodyStr.utf8.count)
            }
        }
        let path = target.split(separator: "?").first.map(String.init) ?? target
        switch (method, path) {
        case ("GET", "/v0/management/config.yaml"):
            let yaml = cpaYAML
            mgmtLock.unlock()
            respond(client, 200, "OK", yaml, contentType: "text/yaml")
            mgmtLock.lock()
        case ("PUT", "/v0/management/config.yaml"):
            cpaPutBody = bodyStr
            cpaYAML = bodyStr
            respond(client, 200, "OK", "{\"ok\":true}")
        case ("GET", "/v0/management/auth-files"):
            let items = cpaAuthFiles.keys.sorted().map { "{\"name\":\"\($0)\"}" }
            respond(client, 200, "OK", "{\"files\":[\(items.joined(separator: ","))]}")
        case ("GET", "/v0/management/auth-files/download"):
            if let q = target.range(of: "name=") {
                let name = target[q.upperBound...].removingPercentEncoding ?? ""
                if let data = cpaAuthFiles[name] {
                    respond(client, 200, "OK", data)
                    return
                }
            }
            respond(client, 404, "Not Found", "{\"error\":\"no file\"}")
        case ("PATCH", "/v0/management/auth-files/fields"):
            cpaPatchBody = bodyStr
            if let obj = try? JSONSerialization.jsonObject(with: Data(bodyStr.utf8)) as? [String: Any],
               let name = obj["name"] as? String, cpaAuthFiles[name] != nil {
                cpaPatchName = name
                if let pu = obj["proxy_url"] as? String,
                   var fileObj = try? JSONSerialization.jsonObject(with: Data(cpaAuthFiles[name]!.utf8)) as? [String: Any] {
                    fileObj["proxy_url"] = pu
                    cpaAuthFiles[name] = String(data: try! JSONSerialization.data(withJSONObject: fileObj), encoding: .utf8)
                }
                respond(client, 200, "OK", "{\"ok\":true}")
            } else {
                respond(client, 404, "Not Found", "{\"error\":\"auth file not found\"}")
            }
        default:
            respond(client, 404, "Not Found", "{}")
        }
    }
}

final class TCPServer {
    var port: Int = 0
    private var fd: Int32 = -1

    init() throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        var opt: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        listen(fd, 16)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        var bound = sockaddr_in()
        withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        port = Int(bound.sin_port.bigEndian)
    }

    func accept() -> SocketClient? {
        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let c = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.accept(fd, $0, &len)
            }
        }
        guard c >= 0 else { return nil }
        return SocketClient(fd: c)
    }

    static func connect(host: String) -> SocketClient? {
        guard let sock = SocketClient.createTCP() else { return nil }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t((host.split(separator: ":").last.flatMap { UInt16($0) } ?? 0).bigEndian)
        addr.sin_addr.s_addr = inet_addr(String(host.split(separator: ":").first ?? ""))
        let rc = withUnsafePointer(to: &addr, {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        })
        if rc != 0 {
            Darwin.close(sock)
            return nil
        }
        return SocketClient(fd: sock)
    }
}

final class SocketClient {
    private var fd: Int32
    init(fd: Int32) { self.fd = fd }
    static func createTCP() -> Int32? {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        return s >= 0 ? s : nil
    }
    func write(_ s: String) {
        s.withCString { _ = Darwin.send(fd, $0, strlen($0), 0) }
    }
    func readRequest() -> String? {
        readUntil("\r\n\r\n")
    }
    // 仅供 selectiveModelQuota 用:读满 POST body 拿 model 字段。
    // 带 SO_RCVTIMEO 兜底,绝不因对端不再发数据而死等(URLSession 可能已把 body
    // 和 header 分包、或根本不等 body)。其他 mode 的 mock 不调用它,行为不变。
    func readBody(toLength want: Int) -> String {
        var tv = timeval(tv_sec: 0, tv_usec: __darwin_suseconds_t(300 * 10_000)) // 3s
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        defer {
            var off = timeval(tv_sec: 0, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &off, socklen_t(MemoryLayout<timeval>.size))
        }
        var got = ""
        var buf = [UInt8](repeating: 0, count: 1024)
        while got.utf8.count < want {
            let n = Darwin.recv(fd, &buf, min(buf.count, want - got.utf8.count), 0)
            if n <= 0 { break }   // 超时/关闭都退出,不死等
            got += String(decoding: buf[0..<n], as: UTF8.self)
        }
        return got
    }
    func readResponse() -> String {
        readUntil("\r\n\r\n") ?? ""
    }
    func readUntil(_ marker: String) -> String? {
        var buf = [UInt8](repeating: 0, count: 4096)
        var acc = ""
        while true {
            let n = Darwin.recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            acc += String(decoding: buf[0..<n], as: UTF8.self)
            if acc.contains(marker) { break }
        }
        return acc.isEmpty ? nil : acc
    }
    func close() { Darwin.close(fd) }
}

enum APITesterTests {
    static func run(_ h: Harness) {
        h.runSuite("APITester.探测轮换") { t in
            // 轮换语义:激活模型置顶,从未测过 > 最久未测,每轮仍只 4 个
            let models = ["m1", "m2", "m3", "m4", "m5", "m6", "m7", "m8"]
            let now: TimeInterval = 1_000_000
            // 首轮(无历史):等价于原逻辑,不轮换
            let r0 = APITester.chatProbeOrder(models, preferred: "m3")
            t.equal(r0.count, 4, "[首轮] 仍只测 4 个")
            t.equal(r0.first, "m3", "[首轮] 激活模型置顶")

            // 三轮后:m1-m6 已有记录(时间递增),m7/m8 从未测过
            let times: [String: TimeInterval] = [
                "m1": now - 300, "m2": now - 200, "m3": now - 100,
                "m4": now - 500, "m5": now - 400, "m6": now - 250,
            ]
            let r1 = APITester.chatProbeOrder(models, preferred: "m3", modelProbeTimes: times)
            t.equal(r1.count, 4, "[轮换] 仍只测 4 个")
            t.equal(r1.first, "m3", "[轮换] 激活模型始终置顶")
            t.equal(Set(r1.suffix(3)), ["m7", "m8", "m4"], "[轮换] 从未测过优先,已测的最久未测优先(m4 最老)")

            // 全部测过一轮后:纯按最久未测轮换
            let times2 = Dictionary(uniqueKeysWithValues: models.map { ($0, now - 100) })
            let r2 = APITester.chatProbeOrder(models, preferred: "m3", modelProbeTimes: times2)
            t.equal(r2.first, "m3", "[全测过] 激活模型置顶")
            t.expect(!r2.suffix(3).contains("m3"), "[全测过] 激活模型不重复占槽")

            // 模型数 ≤4:不进入轮换分支,全量探测(原有行为)
            let small = ["a", "b", "c", "d"]
            let r3 = APITester.chatProbeOrder(small, preferred: "c", modelProbeTimes: ["a": now])
            t.equal(Set(r3), Set(small), "[≤4] 全量探测")
        }

        h.runSuite("APITester.导入模型优先") { t in
            // 真实事故(dc403556, 2026-09-23):用户只导入 3 个模型,探测却拿站点全量
            // 113 个模型轮换,两个导入的 GLM 排在 110 个未选模型后迟迟测不到,监控
            // 一直灰格;而中转站面板“看着是好的”。回归:导入模型必须排在目录发现之前
            let catalog = (["moonshotai/kimi-k3", "z-ai/glm-5.3-flash", "z-ai/glm-5.3"]
                           + (1...110).map { "other-\($0)" })
            let imported = ["moonshotai/kimi-k3", "z-ai/glm-5.3-flash", "z-ai/glm-5.3"]
            let now: TimeInterval = 1_000_000

            // 首轮(无历史):pref=kimi 置顶,两个 GLM 紧随其后,不得被目录模型挤掉
            let r0 = APITester.chatProbeOrder(catalog, preferred: "moonshotai/kimi-k3",
                                              importedModels: imported)
            t.equal(r0.first, "moonshotai/kimi-k3", "[首轮] 激活模型置顶")
            t.equal(Array(r0.suffix(3).prefix(2)), ["z-ai/glm-5.3-flash", "z-ai/glm-5.3"],
                    "[首轮] 导入模型占据 2、3 槽,优先于 110 个目录模型")
            t.expect(r0.count == 4 && r0[3].hasPrefix("other-"), "[首轮] 第 4 槽留给目录发现")

            // 轮换轮(有历史):GLM 仍未测 → 仍最优先;已测的目录模型不得插队
            let times = Dictionary(uniqueKeysWithValues: (1...110).map { ("other-\($0)", now - TimeInterval($0)) })
            let r1 = APITester.chatProbeOrder(catalog, preferred: "moonshotai/kimi-k3",
                                              modelProbeTimes: times, importedModels: imported)
            t.equal(Array(r1.prefix(3)), ["moonshotai/kimi-k3", "z-ai/glm-5.3-flash", "z-ai/glm-5.3"],
                    "[轮换] 从未测的导入模型压过 110 个从未测目录模型")

            // GLM 已测后:不再重复占槽,槽位让给目录轮换
            var times2 = times
            times2["z-ai/glm-5.3-flash"] = now - 10
            times2["z-ai/glm-5.3"] = now - 10
            let r2 = APITester.chatProbeOrder(catalog, preferred: "moonshotai/kimi-k3",
                                              modelProbeTimes: times2, importedModels: imported)
            t.expect(!r2.contains("z-ai/glm-5.3-flash") && !r2.contains("z-ai/glm-5.3"),
                    "[已测] 导入模型不重复占槽,目录轮换继续")

            // 站点列表里已下架的导入模型:不探测(站点列表为准),也不占槽
            let off = ["moonshotai/kimi-k3", "z-ai/glm-5.3", "removed-model"]
            let r3 = APITester.chatProbeOrder(catalog, preferred: "moonshotai/kimi-k3",
                                              importedModels: off)
            t.expect(!r3.contains("removed-model"), "[下架] 已下架的导入模型不探测")
            t.equal(r3[1], "z-ai/glm-5.3", "[下架] 在架导入模型仍优先")
        }

        h.runSuite("APITester") { t in
            guard let server = try? MockHTTPServer() else {
                t.expect(false, "mock server 启动失败")
                return
            }
            let base = "http://127.0.0.1:\(server.port)/v1"

            // 直连成功
            let ok = APITester.test(url: base, key: "sk-test-123", timeout: 5)
            t.expect(ok.ok, "直连可用: \(ok.detail)")
            t.expect(!ok.needsProxy, "直连成功不算 needsProxy")
            t.equal(ok.models, ["gpt-5.6-sol", "glm-5.2"], "模型列表解析")

            // 404 空 → 直连失败
            guard let bad = try? MockHTTPServer(mode: .notFound) else {
                t.expect(false, "mock 404 服务器失败")
                return
            }
            let fail = APITester.test(url: "http://127.0.0.1:\(bad.port)/v1", key: "sk-test-123", timeout: 5)
            t.expect(!fail.ok, "404 服务器判失败")

            // testModelChat:第一候选 404(路径不对)应继续试下一候选(/v1)→ 200
            let mc = APITester.testModelChat(base: "http://127.0.0.1:\(server.port)", key: "sk-test-123", model: "gpt-5.6-sol", timeout: 5)
            t.expect(mc.ok, "chat 候选 404 后命中 /v1: \(mc.detail)")

            // 404 + JSON error body(网关可达,模型校验类)→ 判定可用(ark plan 网关真实行为)
            if let gw = try? MockHTTPServer(mode: .gateway404) {
                let g = APITester.test(url: "http://127.0.0.1:\(gw.port)/api/plan/v3", key: "ark-test-123", timeout: 5)
                t.expect(g.ok, "404+JSON error 网关判可用: \(g.detail)")
            } else {
                t.expect(false, "mock gateway404 失败")
            }

            // 不可达地址 + 无代理 → 失败
            let unreachable = APITester.test(url: "http://10.255.255.1:9/v1", key: "sk-test-123", timeout: 3, proxy: nil)
            t.expect(!unreachable.ok, "不可达且无代理 → 失败")

            // 不可达地址 + 代理指向 mock(可转发) → needsProxy=true
            if let proxyServer = try? MockHTTPServer(proxy: true) {
                let via = APITester.test(
                    url: "http://10.255.255.1:9/v1", key: "sk-test-123", timeout: 3,
                    proxy: "http://127.0.0.1:\(proxyServer.port)"
                )
                t.expect(via.ok, "经代理可用: \(via.detail)")
                t.expect(via.needsProxy, "直连失败代理成功 → needsProxy 标记")
                t.contains(via.detail, "需代理", "detail 标注需代理")
            } else {
                t.expect(false, "mock proxy 失败")
            }

            // 不可达 + 假代理 → 仍失败
            let deadProxy = APITester.test(
                url: "http://10.255.255.1:9/v1", key: "sk-test-123", timeout: 3,
                proxy: "http://127.0.0.1:1"
            )
            t.expect(!deadProxy.ok, "代理也不可用 → 失败")

            // proxyDictionary:socks5 必须走 SOCKS 键(曾按 HTTP 代理建 session,
            // 对 SOCKS 端口发 CONNECT → 每 key 误判 err/dead → 小时级扫描清库)
            if let d = APITester.proxyDictionary(for: "socks5://127.0.0.1:7890") {
                t.expect(d[kCFNetworkProxiesSOCKSEnable as String] != nil, "socks5 用 SOCKS 键")
                t.expect(d[kCFNetworkProxiesHTTPEnable as String] == nil, "socks5 不得塞 HTTP 键")
            } else { t.expect(false, "socks5:// 应解析出字典") }
            // 裸 host:port 补全为 http 代理(曾 URL(string:) 返回 nil 静默回落直连)
            if let d = APITester.proxyDictionary(for: "127.0.0.1:7890") {
                t.expect(d[kCFNetworkProxiesHTTPEnable as String] != nil, "裸 host:port 按 http 代理")
            } else { t.expect(false, "裸 host:port 应解析出字典") }
            // 标准 http 代理键齐全,host/port 正确
            if let d = APITester.proxyDictionary(for: "http://127.0.0.1:7890") {
                t.equal(d[kCFNetworkProxiesHTTPProxy as String] as? String, "127.0.0.1", "http 代理 host")
                t.equal(d[kCFNetworkProxiesHTTPPort as String] as? Int, 7890, "http 代理 port")
            } else { t.expect(false, "http:// 应解析出字典") }
            // 空/无法识别 → nil(直连,而非用错字典把探测全打挂)
            t.expect(APITester.proxyDictionary(for: "") == nil, "空代理 = 直连")
            t.expect(APITester.proxyDictionary(for: "not a proxy") == nil, "非法形态 = 直连")
        }
    }
}
