import Foundation
import KeyDropCore

/// Deliberately mismatched routes: a successful HTTP status must not select the wrong wire protocol.
final class ProtocolRegressionServer {
    let listener: TCPServer
    let chatStatus: Int
    let chatBody: String
    let responsesBody: String
    let chatRetryAfter: String?
    var unversionedChatStatus: Int? = nil
    var unversionedChatBody: String? = nil
    var unversionedChatRetryAfter: String? = nil
    private let lock = NSLock()
    private var paths: [String] = []
    var base: String { "http://127.0.0.1:\(listener.port)/v1" }
    var root: String { "http://127.0.0.1:\(listener.port)" }
    static let model = "gpt-protocol-fixture"
    static let chat = #"{"choices":[{"message":{"content":"fixture ok"}}]}"#
    static let responses = #"{"object":"response","status":"completed","error":null,"output":[{"type":"message","content":[{"type":"output_text","text":"fixture ok"}]}]}"#
    init(chatStatus: Int = 403, chatBody: String = #"{"error":{"message":"This route is not enabled"}}"#,
         responsesBody: String = responses, chatRetryAfter: String? = nil,
         unversionedChatStatus: Int? = nil, unversionedChatBody: String? = nil,
         unversionedChatRetryAfter: String? = nil) throws {
        listener = try TCPServer(); self.chatStatus = chatStatus
        self.chatBody = chatBody; self.responsesBody = responsesBody; self.chatRetryAfter = chatRetryAfter
        self.unversionedChatStatus = unversionedChatStatus; self.unversionedChatBody = unversionedChatBody
        self.unversionedChatRetryAfter = unversionedChatRetryAfter
        let listener = listener
        Thread.detachNewThread { [weak self] in
            while let client = listener.accept() {
                Thread.detachNewThread { [weak self] in self?.handle(client) }
            }
        }
    }
    func count(_ path: String) -> Int {
        lock.lock(); defer { lock.unlock() }; return paths.filter { $0 == path }.count
    }
    private func handle(_ client: SocketClient) {
        defer { client.close() }
        guard let request = client.readRequest() else { return }
        let first = request.components(separatedBy: "\r\n").first?.split(separator: " ") ?? []
        guard first.count >= 2 else { return }
        let method = String(first[0]), path = String(first[1])
        lock.lock(); paths.append(path); lock.unlock()
        var status = 404, body = #"{"error":{"message":"route not found"}}"#
        if method == "GET", path == "/v1/models" || path == "/models" {
            status = 200; body = "{\"data\":[{\"id\":\"\(Self.model)\"}]}"
        } else if method == "POST", path == "/chat/completions" {
            status = unversionedChatStatus ?? 404
            body = unversionedChatBody ?? #"{\"error\":{\"message\":\"route not found\"}}"#
        } else if method == "POST", path == "/v1/chat/completions" {
            status = chatStatus; body = chatBody
        } else if method == "POST", path == "/v1/responses" {
            status = 200; body = responsesBody
        }
        let retryAfter = path == "/chat/completions" ? unversionedChatRetryAfter : chatRetryAfter
        let retryHeader = method == "POST" && (path == "/v1/chat/completions" || path == "/chat/completions")
            ? retryAfter.map { "Retry-After: \($0)\r\n" } ?? "" : ""
        client.write("HTTP/1.1 \(status) Fixture\r\nContent-Type: application/json\r\n\(retryHeader)Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)")
    }
}

enum ProtocolRegressionTests {
    static func run(_ h: Harness) {
        h.runSuite("ProtocolRegression.selected endpoint hint survives every parser format") { t in
            let env = try TestEnv("protocol-parser-hints"); defer { env.cleanup() }
            let key = "sk-protocol-parser111111"
            let urls = [("responses", "responses"), ("messages", "anthropic"), ("chat/completions", "openai")]
            for (endpoint, style) in urls {
                let url = "https://protocol.example/v1/" + endpoint
                let inputs = [
                    url + "\n" + key,
                    "URL: " + url + "\nAPI Key: " + key,
                    "{\"base_url\":\"" + url + "\",\"api_key\":\"" + key + "\"}",
                    "curl '" + url + "' -H 'Authorization: Bearer " + key + "'",
                    "curl --url '" + url + "' -H 'Authorization: Bearer " + key + "'",
                    url + "/?mode=fixture#fragment\n" + key,
                    Data((url + "\n" + key).utf8).base64EncodedString()
                ]
                for input in inputs {
                    let parsed = try Parser.parse(input)
                    t.equal(parsed.url, "https://protocol.example/v1", "endpoint normalization remains stable")
                    t.equal(parsed.apiStyle, style, "selected endpoint protocol survives parsing")
                }
            }
            let selected = try Parser.parse("{\"base_url\":\"https://preferred.example/v1\",\"url\":\"https://other.example/v1/responses\",\"api_key\":\"" + key + "\"}")
            t.equal(selected.apiStyle, nil, "an unselected URL cannot supply the protocol")
        }
        h.runSuite("ProtocolRegression.forced import and repeated import retain endpoint protocol") { t in
            let env = try TestEnv("protocol-force-hints"); defer { env.cleanup() }
            let server = try ProtocolRegressionServer()
            let magpie = try MockHTTPServer(mode: .magpie)
            Prefs.shared.magpieWebLink = "http://127.0.0.1:\(magpie.port)/?k=fixture"
            let core = Core(), key = "sk-protocol-force111111"
            let first = try core.add(raw: server.base + "/responses\n" + key, ccOverride: false,
                grokOverride: false, cpaOverride: false, dshOverride: false, magpieOverride: true,
                models: [ProtocolRegressionServer.model], force: true)
            t.equal(first.entry.apiStyle, "responses", "force skips probe while preserving explicit protocol")
            let second = try core.add(raw: server.base + "\n" + key, ccOverride: false,
                grokOverride: false, cpaOverride: false, dshOverride: false, magpieOverride: true,
                models: [ProtocolRegressionServer.model])
            t.expect(second.ok, "same provider reimport reuses known working protocol")
            t.equal(second.entry.apiStyle, "responses", "reimport protocol remains Responses")
            let changed = try core.add(raw: "https://other-protocol.example/v1\n" + key, ccOverride: false,
                grokOverride: false, cpaOverride: false, dshOverride: false, magpieOverride: true,
                models: [ProtocolRegressionServer.model], force: true)
            t.equal(changed.entry.apiStyle, nil, "forced URL change cannot inherit another host's protocol")
        }
        h.runSuite("ProtocolRegression.direct probe and copied command respect explicit endpoint") { t in
            let env = try TestEnv("protocol-direct-hints"); defer { env.cleanup() }
            let server = try ProtocolRegressionServer()
            let result = APITester.test(url: server.base + "/responses", key: "sk-protocol-direct111111", timeout: 2,
                                       preferredModel: ProtocolRegressionServer.model)
            t.expect(result.ok && result.style == "responses", "direct APITester calls preserve endpoint")
            let model = APITester.testModelChat(base: server.base + "/responses", key: "sk-protocol-direct222222",
                model: ProtocolRegressionServer.model, timeout: 2)
            t.expect(model.ok && model.style == "responses", "explicit model probe preserves endpoint")
            let command = APITester.curlCommand(url: server.base + "/responses", key: "placeholder", model: ProtocolRegressionServer.model)
            t.contains(command, "/responses", "copy command retains explicit endpoint")
            t.contains(command, "\"input\"", "copy command uses matching request body")
        }
        h.runSuite("ProtocolRegression.explicit Responses import avoids unrelated auth rejection") { t in
            let env = try TestEnv("protocol-explicit-responses"); defer { env.cleanup() }
            let server = try ProtocolRegressionServer()
            let magpie = try MockHTTPServer(mode: .magpie)
            Prefs.shared.magpieWebLink = "http://127.0.0.1:\(magpie.port)/?k=fixture"
            let core = Core()
            let result = try core.add(raw: server.base + "/responses\nsk-protocol-explicit111111", ccOverride: false,
                grokOverride: false, cpaOverride: false, dshOverride: false, magpieOverride: true,
                models: [ProtocolRegressionServer.model])
            t.expect(result.ok, "explicit working Responses route imports")
            t.equal(result.entry.apiStyle, "responses", "actual protocol is saved")
            t.equal(server.count("/v1/chat/completions"), 0, "explicit route must not try forbidden chat route")
        }
        h.runSuite("ProtocolRegression.rate limit cooldown is isolated by protocol route") { t in
            let env = try TestEnv("protocol-route-cooldown"); defer { env.cleanup() }
            let server = try ProtocolRegressionServer(chatStatus: 429,
                chatBody: #"{"error":{"message":"rate limited"}}"#, chatRetryAfter: "86400")
            let key = "sk-protocol-cooldown111111"
            let chat = APITester.test(url: server.base, key: key, timeout: 2,
                preferredModel: ProtocolRegressionServer.model, styleHint: "openai")
            t.expect(!chat.ok && chat.detail.contains("429"), "first Chat request records the server rate limit")
            t.equal(server.count("/v1/chat/completions"), 1, "first Chat probe reaches its route")

            let repeatedChat = APITester.test(url: server.base, key: key, timeout: 2,
                preferredModel: ProtocolRegressionServer.model, styleHint: "openai")
            t.expect(repeatedChat.skippedForCooldown, "same Chat route is skipped during Retry-After")
            t.equal(server.count("/v1/chat/completions"), 1, "cached Chat cooldown avoids another request")

            let responses = APITester.test(url: server.base, key: key, timeout: 2,
                preferredModel: ProtocolRegressionServer.model, styleHint: "responses")
            t.expect(responses.ok, "Responses remains probeable while Chat is rate limited")
            t.equal(responses.style, "responses", "Responses success keeps its own protocol")
            t.equal(server.count("/v1/responses"), 1, "Responses route is actually requested")
        }
        h.runSuite("ProtocolRegression.unversioned Chat aliases share cooldown") { t in
            let env = try TestEnv("protocol-unversioned-cooldown"); defer { env.cleanup() }
            let server = try ProtocolRegressionServer(chatStatus: 200,
                unversionedChatStatus: 429, unversionedChatBody: #"{\"error\":{\"message\":\"rate limited\"}}"#,
                unversionedChatRetryAfter: "86400")
            let key = "sk-protocol-unversioned111111"
            let first = APITester.test(url: server.root, key: key, timeout: 2,
                preferredModel: ProtocolRegressionServer.model, styleHint: "openai")
            t.expect(!first.ok && first.detail.contains("429"), "unversioned Chat mount rate limit is recorded")
            t.equal(server.count("/chat/completions"), 1, "first equivalent mount is attempted")
            t.equal(server.count("/v1/chat/completions"), 0, "rate limit prevents fallback to equivalent mount")

            let second = APITester.test(url: server.root, key: key, timeout: 2,
                preferredModel: ProtocolRegressionServer.model, styleHint: "openai")
            t.expect(second.skippedForCooldown, "cooldown suppresses both equivalent Chat mounts")
            t.equal(server.count("/chat/completions"), 1, "unversioned route is not retried")
            t.equal(server.count("/v1/chat/completions"), 0, "versioned alias does not bypass cooldown")
        }
        h.runSuite("ProtocolRegression.wrong success envelope cannot select chat") { t in
            let env = try TestEnv("protocol-wrong-envelope"); defer { env.cleanup() }
            let server = try ProtocolRegressionServer(chatStatus: 200, chatBody: ProtocolRegressionServer.responses)
            let result = APITester.test(url: server.base, key: "sk-protocol-envelope111111", timeout: 2,
                                       preferredModel: ProtocolRegressionServer.model)
            t.expect(result.ok, "valid Responses route remains usable")
            t.equal(result.style, "responses", "Responses payload at chat route must not select Chat Completions")
            t.expect(server.count("/v1/responses") > 0, "selected Responses route must have been exercised")
        }
        h.runSuite("ProtocolRegression.wrong success envelope cannot select Responses") { t in
            let env = try TestEnv("protocol-wrong-responses-envelope"); defer { env.cleanup() }
            let server = try ProtocolRegressionServer(chatStatus: 200, chatBody: ProtocolRegressionServer.chat,
                                                       responsesBody: ProtocolRegressionServer.chat)
            let result = APITester.testModelChat(base: server.base, key: "sk-protocol-envelope222222",
                model: ProtocolRegressionServer.model, timeout: 2, styleHint: "responses")
            t.expect(result.ok, "valid chat fallback remains usable")
            t.equal(result.style, "openai", "chat envelope at Responses route must not select Responses")
        }
    }
}
