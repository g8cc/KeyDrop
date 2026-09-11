import Foundation
import KeyDropCore

enum ParserTests {
    static func run(_ h: Harness) {
        h.runSuite("Parser") { t in
            // 纯 key
            t.equal(try! Parser.parseWithFallback("sk-abc123def456ghi789jkl").key, "sk-abc123def456ghi789jkl", "纯 key 解析")

            // key + URL(两种顺序)
            let a = try! Parser.parseWithFallback("https://api-relay-test.example.com/v1 sk-OhbVrpoiVgRV5IfLBcbfnoGMbJmTPSIAoCLrZ3aWZkSBvrjn")
            t.equal(a.key!, "sk-OhbVrpoiVgRV5IfLBcbfnoGMbJmTPSIAoCLrZ3aWZkSBvrjn", "key+URL 解析")
            t.equal(a.url!, "https://api-relay-test.example.com/v1", "key+URL 提取 url")

            let b = try! Parser.parseWithFallback("sk-OhbVrpoiVgRV5IfLBcbfnoGMbJmTPSIAoCLrZ3aWZkSBvrjn https://x.com/v1")
            t.equal(b.url!, "https://x.com/v1", "URL 在 key 后")

            // 单行多个冒号字段:URL 的冒号不能把后面的 key 字段吞掉,
            // base64 key 仍需走统一解码路径
            let labeled = try! Parser.parseWithFallback(
                "baseurl: https://sub.tidalrelay.com/ key:c2stOThiMTZiOTFjMjQ0ZDlkOThmMTExZDA0NDUyM2MxN2NkNTI5NjRiMzEwYTg3NWVhYmY3MzAxNjM4Zjc3NGM3NA=="
            )
            t.equal(labeled.url, "https://sub.tidalrelay.com", "单行 baseurl 字段提取并去尾斜杠")
            t.equal(labeled.key, "sk-98b16b91c244d9d98f111d044523c17cd52964b310a875eabf7301638f774c74", "单行 key 字段 base64 解码")

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
                "sub.relay-test.example.com\n736b2d30313233343536373839616263646566303132333435363738396162636465663031323334353637383961626364656630313233343536373839616263646566"
            )
            t.equal(hex.key, "sk-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "hex 解码 key")
            t.equal(hex.url, "https://sub.relay-test.example.com", "裸域名补 https://")
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
                "curl -sS 'https://api-relay-test.example.com/v1/chat/completions' -H 'Authorization: Bearer sk-OhbVrpoiVgRV5IfLBcbfnoGMbJmTPSIAoCLrZ3aWZkSBvrjn' -d '{\"model\":\"deepseek-v4-flash-free\"}'"
            )
            t.equal(curl.key, "sk-OhbVrpoiVgRV5IfLBcbfnoGMbJmTPSIAoCLrZ3aWZkSBvrjn", "curl 提取 key")
            t.equal(curl.url, "https://api-relay-test.example.com/v1", "curl 提取 base URL")

            // KEY= 环境变量格式
            let env = try! Parser.parseWithFallback("KEY=sk-abc123def456ghi789jkl")
            t.equal(env.key, "sk-abc123def456ghi789jkl", "KEY= 格式")

            // extractAllKeys 多 key
            let keys = Parser.extractAllKeys("sk-aaa111222333444555 sk-bbb222333444555 sk-ccc222333444555")
            t.equal(keys.count, 3, "提取全部 key")

            // 回归:nvapi-(NVIDIA)等厂商前缀不在旧白名单(cwk-/sk-/ak-/pk-)里,
            // 批量 nvapi key 提取为 0,多 key CPA 导入路径不触发,只导入第一把
            let nv = Parser.extractAllKeys(
                "https://integrate.api.nvidia.com/v1\nnvapi-aaa111bbb222ccc333ddd111\nnvapi-eee444fff555ggg666hhh222"
            )
            t.equal(nv.count, 2, "nvapi 批量提取")

            // URL/裸域名不计入 key(28+ 字符域名串会过 looksLikeKey 通用分支,需 URL 优先排除)
            let dom = Parser.extractAllKeys(
                "https://host-a.example.net api.integrate.example-nvidia.com sk-abc123def456ghi789jkl"
            )
            t.equal(dom.count, 1, "URL/裸域名不算 key")

            // 只贴 key 不贴 URL:nvapi 官方 URL fallback
            let nvParsed = try! Parser.parseWithFallback(
                "nvapi-aaa111bbb222ccc333ddd111\nnvapi-eee444fff555ggg666hhh222"
            )
            t.equal(nvParsed.url, "https://integrate.api.nvidia.com/v1", "nvapi 官方 URL fallback")

            // CJK 修复:中文段不误入模型
            let cjk = try! Parser.parseWithFallback("sk-abc123def456ghi789jkl 500rmb 随便")
            t.expect((cjk.models ?? []).allSatisfy { !$0.contains("rmb") && !$0.contains("随便") }, "CJK/rmb 不进模型")

            // 回归:全角冒号粘连(标签：URL 无空格)。scnet 事故——
            // normalizeFullWidth 转半角后「工具:https://x」整块 token,
            // 旧逻辑把剥冒号后的 URL 串误判为 key,真 URL 丢失
            let glued = try! Parser.parseWithFallback(
                "兼容 OpenAI 接口协议工具：https://api.scnet.cn/api/llm/v1\n\n兼容 Anthropic 接口协议工具：https://api.scnet.cn/api/llm/anthropic\n\nAPI Key：sk-tp-MzgxLTExNTc0NzY1NTIyLTE3ODcwMjk2NzkxNTg="
            )
            t.equal(glued.url, "https://api.scnet.cn/api/llm/v1", "粘连全角冒号:URL 正确提取")
            t.equal(glued.key, "sk-tp-MzgxLTExNTc0NzY1NTIyLTE3ODcwMjk2NzkxNTg=", "粘连全角冒号:key 不被 URL 污染")

            // 回归:多家协议混提不猜官方 URL(旧逻辑看到「OpenAI」字样就指向 api.openai.com)
            let mixed = try! Parser.parse("兼容 OpenAI 与 Anthropic 接口 sk-abc123def456ghi789jkl")
            t.expect(mixed.url == nil || !(mixed.url!.contains("api.openai.com")), "多 provider 混提不误指 openai 官方")

            // 单一 provider 提及仍走官方 fallback(deepseek 场景不受影响)
            let singleHit = try! Parser.parseWithFallback("sk-x1234567890abcdef deepseek 官方")
            t.equal(singleHit.url, "https://api.deepseek.com", "单 provider 保留官方 fallback")
        }
    }
}
