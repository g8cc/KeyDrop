import Foundation
import KeyDropCore

enum ParserTests {
    static func run(_ h: Harness) {
        h.runSuite("Parser") { t in
            // 回归:京东云控制台样式「keybase64 : <base64>」—— 冒号两侧带空格。
            // 曾因只认无空格写法,标签 "keybase64" 被逐词切分漏进模型列表,
            // 后续用 "keybase64" 当模型名探测必然失败(真实事故:jdcloud 导入报错)
            do {
                let jd = try Parser.parse("""
                    https://modelservice.jdcloud.com/coding/openai/v1

                    keybase64 : cGstZmE3ZGUxM2ItZWQzYy00NmM4LThjNTQtMTUzOWVkMzQ4YjYy
                    """)
                t.equal(jd.key, "pk-fa7de13b-ed3c-46c8-8c54-1539ed348b62", "keybase64 标签行正确解码")
                t.expect(jd.models == nil || jd.models?.isEmpty == true, "标签不得漏进模型列表: \(jd.models ?? [])")
                t.expect(jd.model == nil, "model 不应是标签名")
                t.expect(jd.url?.contains("jdcloud") == true, "URL 识别")
            } catch {
                t.expect(false, "京东云样式解析失败: \(error)")
            }
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

            // 回归:家族词+数字的模型命名(qwen3.8-flash)曾被「带点像域名」规则误杀,
            // /models 返回 3 个模型导入后只剩 2 个(真实事故:s2api.top)
            t.expect(Parser.looksLikeModel("qwen3.8-flash"), "家族词+数字命名是模型")
            t.expect(Parser.looksLikeModel("gpt5.2-mini"), "gpt+数字命名是模型")
            t.expect(!Parser.looksLikeModel("sub.example.com"), "裸域名仍被排除")
            t.expect(!Parser.looksLikeModel("qwen.example.com"), "家族词开头的域名仍被排除")

            // 回归:looksLikeURL 曾把 qwen3.8-flash 判为裸域名,classify 里 URL 优先,
            // 手贴模型名被抢成 https://qwen3.8-flash 且模型丢失
            t.expect(!Parser.looksLikeURL("qwen3.8-flash"), "带点模型名不是 URL")
            t.expect(Parser.looksLikeURL("sub.example.com"), "真裸域名仍是 URL")

            // 回归:家族词已吃掉首位数字的「点分版本名」o3.5 / k2.5 —— 前缀判别不命中,
            // 曾被 looksLikeURL 当裸域名抢走、looksLikeModel 又排除,两头不认两头丢。
            // 通用判别:恰好一点 + 末段全数字(真域名末段 TLD 恒为字母)
            t.expect(!Parser.looksLikeURL("o3.5"), "o3.5 不是 URL")
            t.expect(Parser.looksLikeModel("o3.5"), "o3.5 是模型")
            t.expect(!Parser.looksLikeURL("k2.5"), "k2.5 不是 URL")
            t.expect(Parser.looksLikeModel("k2.5"), "k2.5 是模型")
            // IPv4 多段点分仍是 URL(末段数字判别只作用于「恰好一点」形态,不受多段影响)
            t.expect(Parser.looksLikeURL("1.2.3.4"), "IPv4 仍是 URL")
            // 真域名末段是字母(TLD),不会被误判成点分版本模型
            t.expect(Parser.looksLikeURL("qwen.ai"), "家族词+.ai 域名仍是 URL")
            let pastedDotted = try! Parser.parseWithFallback(
                "https://s2api.example.top sk-abc123def456ghi789jkl qwen3.8-flash"
            )
            t.equal(pastedDotted.url, "https://s2api.example.top", "手贴带点模型名时 URL 不被抢占")
            t.equal(pastedDotted.model, "qwen3.8-flash", "带点模型名正确进模型")

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

            // ── 正则缓存重构等价性 ──
            // range(of:options:.regularExpression) 每次调用都会重新编译正则,逐 token 的
            // 解析路径上是数万次编译。改成共享缓存后语义必须逐字不变,以下用两侧对照断言。
            let modelCases = [
                "qwen3.8-flash", "gpt5.2-mini", "o3.5", "k2.5", "glm-5.2",
                "sub.example.com", "qwen.example.com", "qwen.ai", "1.2.3.4",
                "deepseek-v4-flash", "claude-3-5-sonnet", "gpt-4o", "随便", "500rmb",
            ]
            for c in modelCases {
                // 重构后的实现必须与「原始字面量表达式」完全一致
                let legacy = legacyLooksLikeModel(c)
                t.equal(Parser.looksLikeModel(c), legacy, "looksLikeModel 重构等价: \(c)")
            }
            let urlCases = ["qwen3.8-flash", "sub.example.com", "o3.5", "k2.5", "1.2.3.4", "qwen.ai", "https://x.com"]
            for c in urlCases {
                t.equal(Parser.looksLikeURL(c), legacyLooksLikeURL(c), "looksLikeURL 重构等价: \(c)")
            }
            // looksLikeKey 是 internal,只能经公开入口间接验证:key 提取结果不受缓存重构影响
            t.equal(Parser.extractAllKeys("sk-abc123def456ghi789jkl").count, 1, "looksLikeKey 经公开入口:普通 key")
            t.equal(Parser.extractAllKeys("nvapi-aaa111bbb222ccc333ddd111").count, 1, "looksLikeKey 经公开入口:nvapi 前缀")
            // 家族词开头的长串无 sk- 类前缀 → 走通用分支被家族词排除(防模型名当 key)
            t.equal(Parser.extractAllKeys("claude-3-5-sonnet-abcdefghijklmnop").count, 0,
                    "looksLikeKey 经公开入口:家族词长串被排除")
            // 带显式厂商前缀的优先命中前缀分支,即使串里含家族词也照收(与重构前一致)
            t.equal(Parser.extractAllKeys("sk-claude-3-5-sonnet-abcdefghijklmnop").count, 1,
                    "looksLikeKey 经公开入口:显式 sk- 前缀优先于家族词排除")

            // 分隔符指令正则:旧实现 try! 编译,现在走缓存 + 可失败返回 nil
            do {
                let sep = try! Parser.parse("""
                    去除 diamond_suit 即可
                    https://api-relay-test.example.com/v1
                    sk-diamond_suitabc-diamond_suit123def456ghi789
                    """)
                t.equal(sep.key, "sk-abc-123def456ghi789", "分隔符指令:去分隔符重组 key")
                t.equal(sep.url, "https://api-relay-test.example.com/v1", "分隔符指令:URL 不受影响")
            }
        }
    }

    // MARK: - 重构对照实现(照抄重构前的字面量表达式,仅用于断言等价)

    private static func legacyLooksLikeModel(_ s: String) -> Bool {
        if s.contains(where: { $0.isWhitespace }) { return false }
        if s.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) { return false }
        if s.count < 2 || s.count > 80 { return false }
        guard s.contains(where: { $0.isLetter }) else { return false }
        if s.contains(where: { $0 == "$" || $0 == "！" || $0 == "？" || $0 == "!" || $0 == "?" }) { return false }
        let l = s.lowercased()
        if l.range(of: #"(rmb|usd|cny|yuan|元|块|钱包|余额)"#, options: .regularExpression) != nil { return false }
        if s.contains("."), s.range(of: #"^[a-z0-9][a-z0-9.-]*$"#, options: [.regularExpression, .caseInsensitive]) != nil,
           !legacyIsDotted(s.lowercased()),
           s.range(of: #"^(?:gpt|claude|gemini|glm|kimi|qwen|deepseek|grok|opus|sonnet|haiku|mistral|llama|minimax|mimo|longcat|codex|o[134])[-\d]"#, options: .regularExpression) == nil
        { return false }
        let families = "claude|gpt|gemini|glm|kimi|qwen|deepseek|grok|opus|sonnet|haiku|mistral|llama|minimax|mimo|longcat|codex|o[134]|k2"
        if l.range(of: families, options: .regularExpression) != nil { return true }
        if l.range(of: #"\d"#, options: .regularExpression) != nil { return true }
        if l.range(of: #"v\d"#, options: .regularExpression) != nil { return true }
        return false
    }

    private static func legacyLooksLikeURL(_ s: String) -> Bool {
        let l = String(s.unicodeScalars.filter {
            !(0x3400...0x9FFF).contains($0.value) && !(0xF900...0xFAFF).contains($0.value)
        }).lowercased()
        guard !l.contains(where: { $0.isWhitespace }) else { return false }
        if l.hasPrefix("https://") || l.hasPrefix("http://") {
            return URL(string: l)?.host?.isEmpty == false
        }
        guard l.range(of: #"^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$"#, options: .regularExpression) != nil,
              !l.contains(".."),
              !legacyIsDotted(l),
              l.range(of: #"^(?:gpt|claude|gemini|glm|kimi|qwen|deepseek|grok|opus|sonnet|haiku|mistral|llama|minimax|mimo|longcat|codex|o[134])[-\d]"#, options: .regularExpression) == nil
        else { return false }
        return URL(string: "https://" + l)?.host?.isEmpty == false
    }

    private static func legacyLooksLikeKey(_ s: String) -> Bool {
        let t = String(s.unicodeScalars.filter {
            !(0x3400...0x9FFF).contains($0.value) && !(0xF900...0xFAFF).contains($0.value)
        }).trimmingCharacters(in: .whitespaces)
        guard t.count >= 16, t.count <= 256 else { return false }
        guard t.range(of: #"^[\x21-\x7E]+$"#, options: .regularExpression) != nil else { return false }
        if t.contains(":") { return false }
        if t.range(of: #"^(sk|ak|key|pk|cr|sp|dk|bk|rk|fk|tk|xk|wk|zk|gk|vk|nk|mk|hk|csk|gsk|sk-or|sk-ant|sk_tr|cfut|nvapi|ms)[-_]"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        if t.count >= 28,
           t.range(of: #"^[A-Za-z0-9_\-./=]+$"#, options: .regularExpression) != nil,
           t.lowercased().range(of: #"(claude|gpt|gemini|glm|kimi|qwen|deepseek|grok|opus|sonnet|haiku|mistral|llama|minimax|mimo|longcat|codex)"#, options: .regularExpression) == nil {
            return true
        }
        return false
    }

    private static func legacyIsDotted(_ s: String) -> Bool {
        let segs = s.split(separator: ".", omittingEmptySubsequences: false)
        guard segs.count == 2, let last = segs.last, !last.isEmpty else { return false }
        guard last.allSatisfy({ $0.isNumber }) else { return false }
        return segs[0].contains(where: { $0.isLetter })
    }
}
