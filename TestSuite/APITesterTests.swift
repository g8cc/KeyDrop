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
    }
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
        guard let req = client.readRequest() else { return }
        let line = req.components(separatedBy: "\r\n").first ?? ""
        let parts = line.components(separatedBy: " ")
        guard parts.count >= 2 else { return }
        let method = parts[0]
        let target = parts[1]

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
        if mode == .openAI {
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
        }
        let status: String
        if mode == .html200 && target.hasSuffix("/v1/models") {
            status = "401 Unauthorized"
        } else if mode == .openAI || mode == .balanceOK || mode == .balanceZero || mode == .balanceNoInfo {
            status = "200 OK"
        } else {
            status = "404 Not Found"
        }
        let resp = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        client.write(resp)
        client.close()
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
        }
    }
}
