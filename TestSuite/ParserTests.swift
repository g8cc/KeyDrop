import Foundation
import KeyDropCore

enum ParserTests {
    static func run(_ h: Harness) {
        h.runSuite("Parser") { t in
            // 纯 key
            t.equal(try! Parser.parseWithFallback("sk-abc123def456ghi789jkl").key, "sk-abc123def456ghi789jkl", "纯 key 解析")

            // key + URL(两种顺序)
            let a = try! Parser.parseWithFallback("https://relay-test.example.com/v1 SANITIZED-TEST-KEY-1")
            t.equal(a.key!, "SANITIZED-TEST-KEY-1", "key+URL 解析")
            t.equal(a.url!, "https://relay-test.example.com/v1", "key+URL 提取 url")

            let b = try! Parser.parseWithFallback("SANITIZED-TEST-KEY-1 https://x.com/v1")
            t.equal(b.url!, "https://x.com/v1", "URL 在 key 后")

            // 多行多 provider
            let multi = try! Parser.parseWithFallback(
                "https://a.com sk-aaa111222333444555\nhttps://b.com/v1 sk-bbb222333444555"
            )
            t.equal(multi.key!, "sk-aaa111222333444555", "multiline 取第一个 key")
            t.equal(multi.url!, "https://a.com", "multiline 取第一个 url")

            // 模型提取
            let withModel = try! Parser.parseWithFallback("sk-abc123def456ghi789jkl 模型 gpt-5.6-sol")
            t.equal(withModel.model, "gpt-5.6-sol", "中文+模型提取")

            // 无 URL:官方 fallback(由调用方 applyOfficialURLFallback 补)
            var noURL = try! Parser.parseWithFallback("sk-abc123def456ghi789jkl deepseek")
            t.equal(noURL.url, "https://api.deepseek.com", "deepseek 官方 fallback(parse 内部已补)")
            var gpt = try! Parser.parseWithFallback("sk-abc123def456ghi789jkl openai gpt-4o")
            t.equal(gpt.url, "https://api.openai.com/v1", "openai 官方 fallback")

            // base64
            let b64 = try! Parser.parseWithFallback("c2stYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFh")
            t.expect(b64.key != nil, "base64 可解析")

            // base16/hex 编码 key + 裸域名(无协议)→ 补 https://,hex 解码,域名不当模型
            let hex = try! Parser.parseWithFallback(
                "sub.gwy.example.org\n53414e4954495a45442d544553542d4b45592d33"
            )
            t.equal(hex.key, "SANITIZED-TEST-KEY-3", "hex 解码 key")
            t.equal(hex.url, "https://sub.gwy.example.org", "裸域名补 https://")
            t.expect((hex.models ?? []).isEmpty, "裸域名不进模型")

            // 带点模型名(glm-5.2)不被域名排除规则误杀
            let dotted = try! Parser.parseWithFallback("sk-abc123def456ghi789jkl https://host-a.example.net glm-5.2")
            t.equal(dotted.model, "glm-5.2", "带点模型名识别")
            t.equal(dotted.url, "https://host-a.example.net", "URL 不受影响")

            // 裸域名 key+模型 混合行(域名与模型并存)
            let bare = try! Parser.parseWithFallback("sk-abc123def456ghi789jkl api.b.ai deepseek-v4-flash")
            t.equal(bare.url, "https://api.b.ai", "裸域名 URL 识别")
            t.equal(bare.model, "deepseek-v4-flash", "模型不被域名干扰")

            // curl 命令
            let curl = try! Parser.parseWithFallback(
                "curl -sS 'https://relay-test.example.com/v1/chat/completions' -H 'Authorization: Bearer SANITIZED-TEST-KEY-1' -d '{\"model\":\"deepseek-v4-flash-free\"}'"
            )
            t.equal(curl.key, "SANITIZED-TEST-KEY-1", "curl 提取 key")
            t.equal(curl.url, "https://relay-test.example.com/v1", "curl 提取 base URL")

            // KEY= 环境变量格式
            let env = try! Parser.parseWithFallback("KEY=sk-abc123def456ghi789jkl")
            t.equal(env.key, "sk-abc123def456ghi789jkl", "KEY= 格式")

            // extractAllKeys 多 key
            let keys = Parser.extractAllKeys("sk-aaa111222333444555 sk-bbb222333444555 sk-ccc222333444555")
            t.equal(keys.count, 3, "提取全部 key")

            // CJK 修复:中文段不误入模型
            let cjk = try! Parser.parseWithFallback("sk-abc123def456ghi789jkl 500rmb 随便")
            t.expect((cjk.models ?? []).allSatisfy { !$0.contains("rmb") && !$0.contains("随便") }, "CJK/rmb 不进模型")
        }
    }
}
