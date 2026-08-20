import Foundation
import KeyDropCore

/// 生图 mock:POST /images/generations → 400(端点在) 或 404(端点不存在)
final class ImageMockServer {
    private let listener: TCPServer
    var port: Int { listener.port }
    let supportsImage: Bool

    init(supportsImage: Bool) throws {
        self.supportsImage = supportsImage
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
        let target = parts.count >= 2 ? parts[1] : "/"

        let status: String
        var body = ""
        if target == "/images/generations" {
            if supportsImage {
                status = "400 Bad Request"
                body = "{\"error\":{\"message\":\"prompt is required\"}}"
            } else {
                status = "404 Not Found"
            }
        } else if target == "/models" {
            status = "200 OK"
            body = "{\"data\":[{\"id\":\"flux-schnell\"},{\"id\":\"imagen-3\"}]}"
        } else {
            status = "404 Not Found"
        }
        let resp = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        client.write(resp)
        client.close()
    }
}

enum ImageAPITests {
    static func run(_ h: Harness) {
        h.runSuite("ImageAPI") { t in
            guard let okServer = try? ImageMockServer(supportsImage: true) else {
                t.expect(false, "mock 启动失败")
                return
            }
            let base = "http://127.0.0.1:\(okServer.port)"

            let p = ImageAPI.probe(baseURL: base, key: "sk-test-123", timeout: 5)
            t.expect(p.supported, "生图端点存在(400 空请求): \(p.detail)")
            t.expect(p.models.contains("flux-schnell"), "模型列表拉取")

            guard let noServer = try? ImageMockServer(supportsImage: false) else {
                t.expect(false, "mock 启动失败")
                return
            }
            let p2 = ImageAPI.probe(baseURL: "http://127.0.0.1:\(noServer.port)", key: "sk-test-123", timeout: 5)
            t.expect(!p2.supported, "无生图端点(404): \(p2.detail)")

            // 不可达 → 不支持
            let p3 = ImageAPI.probe(baseURL: "http://10.255.255.1:9", key: "sk-test-123", timeout: 3, proxy: nil)
            t.expect(!p3.supported, "不可达判不支持")

            // ImageChannelStore 存取
            let env = try! TestEnv("img-store")
            defer { env.cleanup() }
            let ch = ImageChannel(url: "https://api.example.com/v1", key: "sk-abcdef1234567890", model: "flux-schnell")
            try! ImageChannelStore.save(ch)
            let loaded = ImageChannelStore.load()
            t.expect(loaded != nil, "渠道可读回")
            t.equal(loaded?.url, "https://api.example.com/v1", "url 读回")
            t.equal(loaded?.key, "sk-abcdef1234567890", "key 读回")
            t.equal(loaded?.keyMasked, "sk-abc…7890", "key 掩码")

            // MCP 配置写入(claude + codex,隔离路径)
            setenv("KEYDROP_MCP_COMMAND", "/tmp/fake-keydrop mcp-image", 1)
            let existed = try! ImageMCPWriter.writeAll()
            t.equal(existed["claude"], false, "claude 首次写入")
            t.equal(existed["codex"], false, "codex 首次写入")
            let claude = env.read("claude.json")
            t.contains(claude, "keydrop-image", "claude mcpServers 写入")
            let claudeObj = try! JSONSerialization.jsonObject(with: Data(claude.utf8)) as? [String: Any]
            let server = (claudeObj?["mcpServers"] as? [String: Any])?["keydrop-image"] as? [String: Any]
            t.equal(server?["command"] as? String, "/tmp/fake-keydrop", "claude 命令写入")
            t.equal(server?["args"] as? [String], ["mcp-image"], "claude args 写入")
            let codex = env.read("codex.toml")
            t.contains(codex, "[mcp_servers.keydrop-image]", "codex mcp 段写入")
            t.contains(codex, "mcp-image", "codex args 写入")
            let opencode = env.read("opencode.json")
            t.contains(opencode, "keydrop-image", "opencode mcp 段写入")
            let ocObj = try! JSONSerialization.jsonObject(with: Data(opencode.utf8)) as? [String: Any]
            let ocServer = ((ocObj?["mcp"] as? [String: Any])?["keydrop-image"] as? [String: Any])
            t.equal(ocServer?["type"] as? String, "local", "opencode type")
            t.equal(ocServer?["command"] as? [String], ["/tmp/fake-keydrop", "mcp-image"], "opencode command")
            t.equal(ocServer?["enabled"] as? Bool, true, "opencode enabled")
            let existed2 = try! ImageMCPWriter.writeAll()
            t.equal(existed2["claude"], true, "claude 二次写入已存在")
            t.equal(existed2["codex"], true, "codex 二次写入已存在")
            t.equal(existed2["opencode"], true, "opencode 二次写入已存在")
            let claude2 = env.read("claude.json")
            t.expect(claude2.components(separatedBy: "keydrop-image").count == 2, "claude 不重复写入")
        }
    }
}