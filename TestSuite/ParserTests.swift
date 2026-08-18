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

            // base16/hex 编码 key + 裸域名(无协议)→ 补 https://,hex 解码,域名不当模型
            let hex = try! Parser.parseWithFallback(
                "s.0v0.club\n736b2d37353065346233383939666266636437376661653663646261356539643564386461643661356337643862623832623238613433666534343335616665626164"
            )
            t.equal(hex.key, "sk-750e4b3899fbfcd77fae6cdba5e9d5d8dad6a5c7d8bb82b28a43fe4435afebad", "hex 解码 key")
            t.equal(hex.url, "https://s.0v0.club", "裸域名补 https://")
            t.expect((hex.models ?? []).isEmpty, "裸域名不进模型")

            // 裸域名 key+模型 混合行(域名与模型并存)
            let bare = try! Parser.parseWithFallback("sk-abc123def456ghi789jkl api.b.ai deepseek-v4-flash")
            t.equal(bare.url, "https://api.b.ai", "裸域名 URL 识别")
            t.equal(bare.model, "deepseek-v4-flash", "模型不被域名干扰")

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
