import Foundation
import KeyDropCore

enum GrokBuildWriterTests {
    static func run(_ h: Harness) {
        h.runSuite("GrokBuildWriter") { t in
            let env = try! TestEnv("grok-writer")
            defer { env.cleanup() }
            let writer = GrokBuildWriter(configPath: env.dir + "/grok.toml")
            _ = try! writer.sync(
                baseURL: "https://grok.example.org/v1/",
                key: "sk-grok-writer-1111111111",
                models: ["grok-4.6", "xai/grok-video"],
                removing: []
            )
            let first = env.read("grok.toml")
            t.contains(first, "base_url = \"https://grok.example.org/v1\"", "URL 去尾斜杠")
            t.contains(first, "api_backend = \"chat_completions\"", "写入 API backend")
            t.contains(first, "[model.\"xai/grok-video\"]", "模型 ID 中的斜杠安全写入")

            _ = try! writer.sync(
                baseURL: "https://grok.example.org/v1",
                key: "sk-grok-writer-1111111111",
                models: ["grok-4.6"],
                removing: ["xai/grok-video"]
            )
            let second = env.read("grok.toml")
            t.expect(!second.contains("xai/grok-video"), "同步移除旧模型")
            t.expect(second.components(separatedBy: "[model.\"grok-4.6\"]").count - 1 == 1, "同模型只保留一个段")

            let sameModel = """
            [model."grok-4.6"]
            model = "grok-4.6"
            base_url = "https://other.example.org/v1"
            api_key = "sk-other-2222222222"
            """
            try! sameModel.write(toFile: writer.configPath, atomically: true, encoding: .utf8)
            let result = try! writer.remove(
                baseURL: "https://grok.example.org/v1",
                key: "sk-grok-writer-1111111111",
                models: ["grok-4.6"]
            )
            t.contains(result, "未找到", "不同 URL/key 不误删同名模型")
            t.contains(env.read("grok.toml"), "sk-other-2222222222", "保留其他 provider 的同名模型")

            // 回归:remove 返回文案的数字曾被写成字面量 "(removed)"(缺 \() 插值)
            let twoModels = """
            [model."grok-4.6"]
            model = "grok-4.6"
            base_url = "https://grok.example.org/v1"
            api_key = "sk-grok-writer-1111111111"
            [model."grok-mini"]
            model = "grok-mini"
            base_url = "https://grok.example.org/v1"
            api_key = "sk-grok-writer-1111111111"
            """
            try! twoModels.write(toFile: writer.configPath, atomically: true, encoding: .utf8)
            let removedMsg = try! writer.remove(
                baseURL: "https://grok.example.org/v1",
                key: "sk-grok-writer-1111111111",
                models: ["grok-4.6", "grok-mini"]
            )
            t.contains(removedMsg, "移除 2 个模型", "remove 文案带真实数量: \(removedMsg)")
            t.expect(!removedMsg.contains("(removed)"), "无字面量占位残留")

            // 回归:同模型不同 key 曾按 table id 定位直接覆盖 api_key(凭据劫持)。
            // 现在:第二把 key 以「模型#key尾4」table id 共存,各凭据互不覆盖
            let coexistEnv = try! TestEnv("grok-coexist")
            defer { coexistEnv.cleanup() }
            let w2 = GrokBuildWriter(configPath: coexistEnv.dir + "/grok.toml")
            _ = try! w2.sync(baseURL: "https://relay.example.org/v1", key: "sk-grok-key-one-111111111",
                             models: ["grok-4.6"], removing: [])
            let coexistMsg = try! w2.sync(baseURL: "https://relay.example.org/v1", key: "sk-grok-key-two-222222222",
                                          models: ["grok-4.6"], removing: [])
            t.contains(coexistMsg, "#尾号", "共存时消息说明后缀: \(coexistMsg)")
            let co = coexistEnv.read("grok.toml")
            t.contains(co, "api_key = \"sk-grok-key-one-111111111\"", "第一把 key 的凭据未被覆盖")
            t.contains(co, "[model.\"grok-4.6\"]", "第一把 key 保留原名 table")
            t.contains(co, "[model.\"grok-4.6#2222\"]", "第二把 key 用 #尾号 table 共存")
            // 删除第一把:按内容定位,只删自己的段
            _ = try! w2.remove(baseURL: "https://relay.example.org/v1", key: "sk-grok-key-one-111111111",
                               models: ["grok-4.6"])
            let afterDel = coexistEnv.read("grok.toml")
            t.expect(!afterDel.contains("sk-grok-key-one-111111111"), "第一把 key 的段已删")
            t.contains(afterDel, "sk-grok-key-two-222222222", "第二把 key 的段不受影响")

            // 同 key 改 URL 重导入:原地更新 base_url,不产生重复段
            _ = try! w2.sync(baseURL: "https://relay2.example.org/v1", key: "sk-grok-key-two-222222222",
                             models: ["grok-4.6"], removing: [])
            let urlFixed = coexistEnv.read("grok.toml")
            t.contains(urlFixed, "base_url = \"https://relay2.example.org/v1\"", "base_url 原地更新")
            t.equal(urlFixed.components(separatedBy: "[model.").count - 1, 1, "同 key 重导入不产生重复段")
        }
    }
}
