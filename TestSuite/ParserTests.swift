import Foundation
import KeyDropCore

enum ParserTests {
    static func run(_ h: Harness) {
        h.runSuite("Parser") { t in
            // 纯 key
            t.equal(try! Parser.parseWithFallback("sk-abc123def456ghi789jkl").key, "sk-abc123def456ghi789jkl", "纯 key 解析")

            // key + URL(两种顺序)
            let a = try! Parser.parseWithFallback("https://ergouapi.co/v1 sk-m3YNmlNFMI4nwmJMI3YSSH4a40xG2AkqrXKNRwd0nhUdBZrl")
            t.equal(a.key!, "sk-m3YNmlNFMI4nwmJMI3YSSH4a40xG2AkqrXKNRwd0nhUdBZrl", "key+URL 解析")
            t.equal(a.url!, "https://ergouapi.co/v1", "key+URL 提取 url")

            let b = try! Parser.parseWithFallback("sk-m3YNmlNFMI4nwmJMI3YSSH4a40xG2AkqrXKNRwd0nhUdBZrl https://x.com/v1")
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

            // curl 命令
            let curl = try! Parser.parseWithFallback(
                "curl -sS 'https://ergouapi.co/v1/chat/completions' -H 'Authorization: Bearer sk-m3YNmlNFMI4nwmJMI3YSSH4a40xG2AkqrXKNRwd0nhUdBZrl' -d '{\"model\":\"deepseek-v4-flash-free\"}'"
            )
            t.equal(curl.key, "sk-m3YNmlNFMI4nwmJMI3YSSH4a40xG2AkqrXKNRwd0nhUdBZrl", "curl 提取 key")
            t.equal(curl.url, "https://ergouapi.co/v1", "curl 提取 base URL")

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
