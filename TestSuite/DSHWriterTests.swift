import Foundation
import KeyDropCore

enum DSHWriterTests {
    static func run(_ h: Harness) {
        h.runSuite("DSHWriter") { t in
            // baseURL 规范化
            t.equal(DSHWriter.normalizeBaseURL("https://relay-test.example.com"), "https://relay-test.example.com/v1", "无 /v1 补齐")
            t.equal(DSHWriter.normalizeBaseURL("https://relay-test.example.com/"), "https://relay-test.example.com/v1", "尾斜杠处理")
            t.equal(DSHWriter.normalizeBaseURL("https://x.com/v1"), "https://x.com/v1", "/v1 保持")
            t.equal(DSHWriter.normalizeBaseURL("https://x.com/v1/"), "https://x.com/v1", "/v1/ 去尾斜杠")
            t.equal(DSHWriter.normalizeBaseURL("https://x.com/api"), "https://x.com/api", "/api 保持")
            t.equal(DSHWriter.normalizeBaseURL("https://x.com/chat/completions"), "https://x.com/chat/completions", "/chat/completions 保持")
            // 已含版本段不得再拼 /v1(火山 ark/智谱/gemini 真实 baseURL)
            t.equal(DSHWriter.normalizeBaseURL("https://ark.cn-beijing.volces.com/api/v3"),
                    "https://ark.cn-beijing.volces.com/api/v3", "/api/v3 保持")
            t.equal(DSHWriter.normalizeBaseURL("https://open.bigmodel.cn/api/paas/v4"),
                    "https://open.bigmodel.cn/api/paas/v4", "/api/paas/v4 保持")
            t.equal(DSHWriter.normalizeBaseURL("https://generativelanguage.googleapis.com/v1beta/openai/"),
                    "https://generativelanguage.googleapis.com/v1beta/openai", "/v1beta/openai 保持(仅去尾斜杠)")
            t.equal(DSHWriter.normalizeBaseURL("https://api.deepseek.com"), "https://api.deepseek.com/v1", "无路径仍补 /v1")

            // YAML 标量:# / % / : 开头必须转引号,否则会被当注释/报错
            t.expect(DSHWriter.yamlScalar("#1model").hasPrefix("\""), "# 开头转引号")
            t.expect(DSHWriter.yamlScalar("%dirmodel").hasPrefix("\""), "% 开头转引号")
            t.expect(DSHWriter.yamlScalar(":x").hasPrefix("\""), ": 开头转引号")
            t.equal(DSHWriter.yamlScalar("deepseek-v4-flash"), "deepseek-v4-flash", "普通模型名裸写")

            // routeKey / env 命名
            t.equal(DSHWriter.routeKey(providerID: "0219dfa3-311a-4df3-943b-1ee73e186941"), "keydrop-0219dfa3", "routeKey")
            t.equal(DSHWriter.envName(providerID: "0219dfa3-311a-4df3-943b-1ee73e186941"), "KEYDROP_0219DFA3_API_KEY", "envName")

            // deepseek 模型判定
            t.expect(DSHWriter.isDeepseekModel("deepseek-v4-flash"), "deepseek 判定 true")
            t.expect(!DSHWriter.isDeepseekModel("gpt-4o"), "非 deepseek 判定 false")

            // 写入:settings.yaml + credentials
            let env = try! TestEnv("dsh-write")
            defer { env.cleanup() }
            let route = try! DSHWriter.add(
                providerID: "0219dfa3-311a-4df3-943b-1ee73e186941",
                key: "sk-secret-key-123456",
                url: "https://relay-test.example.com",
                models: ["deepseek-v4-flash-free"]
            )
            t.equal(route, "keydrop-0219dfa3", "返回 route")
            let settings = env.read("dsh.yaml")
            t.contains(settings, "keydrop-0219dfa3:", "provider 块写入")
            t.contains(settings, "baseURL: https://relay-test.example.com/v1", "baseURL 规范化写入")
            t.contains(settings, "apiKeyEnv: KEYDROP_0219DFA3_API_KEY", "env 引用")
            t.contains(settings, "- id: deepseek-v4-flash-free", "模型写入")
            let creds = env.read("dsh-creds.yaml")
            // dsh 的凭据格式:顶层仅 version/refs,凭据必须缩进嵌在 refs 内
            // (顶层裸写会被 dsh 解析器拒绝 → 启动崩溃,2026-09-25 07FA1C9C 事故)
            t.contains(creds, "version: 1\nrefs:\n  KEYDROP_0219DFA3_API_KEY: sk-secret-key-123456",
                       "凭证写入:骨架 + refs 内缩进")

            // 幂等:再次 add 不重复块
            _ = try! DSHWriter.add(
                providerID: "0219dfa3-311a-4df3-943b-1ee73e186941",
                key: "sk-secret-key-123456",
                url: "https://relay-test.example.com",
                models: ["deepseek-v4-flash-free", "deepseek-v4-pro-free"]
            )
            let again = env.read("dsh.yaml")
            let count = again.components(separatedBy: "keydrop-0219dfa3:").count - 1
            t.equal(count, 1, "幂等:同 provider 单块")
            t.contains(again, "- id: deepseek-v4-pro-free", "新模型合并")

            // remove 清理
            try! DSHWriter.remove(providerID: "0219dfa3-311a-4df3-943b-1ee73e186941")
            let after = env.read("dsh.yaml")
            t.expect(!after.contains("keydrop-0219dfa3"), "remove 删块")
            t.expect(!env.read("dsh-creds.yaml").contains("KEYDROP_0219DFA3_API_KEY"), "remove 删凭证")

            // 既有 provider 共存:不影响其他块
            env.write("dsh.yaml", "llm-pi-ai:\n  providers:\n    cpa:\n      apiKeyEnv: CPA_API_KEY\n      baseURL: http://localhost:8317/v1\n")
            _ = try! DSHWriter.add(
                providerID: "ab12cd34-1111-2222-3333-444455556666",
                key: "sk-other-key",
                url: "https://api.deepseek.com",
                models: ["deepseek-v4-flash"]
            )
            let coexist = env.read("dsh.yaml")
            t.contains(coexist, "cpa:", "原块保留")
            t.contains(coexist, "keydrop-ab12cd34:", "新块追加")

            // 读失败(非 UTF-8)必须抛错,绝不能当空文件整体覆盖 → 清空其它 provider
            let env2 = try! TestEnv("dsh-readfail")
            defer { env2.cleanup() }
            let badSettings = env2.dir + "/dsh.yaml"
            let badCreds = env2.dir + "/dsh-creds.yaml"
            let original = Data([0x6c, 0x6c, 0x6d, 0x2d, 0x70, 0x69, 0x2d, 0x61, 0x69, 0x3a, 0xFF, 0xFE])
            try! original.write(to: URL(fileURLWithPath: badSettings))
            try! Data([0xFF, 0xFE, 0x00]).write(to: URL(fileURLWithPath: badCreds))
            var threw = false
            do {
                _ = try DSHWriter.add(providerID: "deadbeef-1111-2222-3333-444455556666",
                                      key: "sk-x", url: "https://x.com", models: ["deepseek-v4-flash"])
            } catch { threw = true }
            t.expect(threw, "读失败时抛错,拒绝覆盖")
            t.expect(try! Data(contentsOf: URL(fileURLWithPath: badSettings)) == original,
                     "读失败时 settings 内容不变(未被清空)")
            t.expect(try! Data(contentsOf: URL(fileURLWithPath: badCreds)) == Data([0xFF, 0xFE, 0x00]),
                     "读失败时 credentials 内容不变")
        }

        // MARK: - refs 结构回归:凭据必须缩进嵌在 refs 内,顶格裸写会让 dsh 启动即崩
        // 2026-09-25 事故:KEYDROP_07FA1C9C_API_KEY 被顶层裸写(文件被外部手工缩进修复,
        // 但写入方不感知 refs 的话,下次 upsert 找不到缩进行会再追加顶格重复行 → 复崩)
        h.runSuite("DSHWriter.refs 结构回归") { t in
            // ① 事故文件形态:多行标量条目结尾 + 顶格遗留行
            let env = try! TestEnv("dsh-refs-incident")
            defer { env.cleanup() }
            env.write("dsh-creds.yaml", """
            version: 1
            refs:
              DEEPSEEK_API_KEY: sk-existing
              WORKBUDDY_ACCOUNT_X: '{ "a": "openid
                profile offline",
                "b": 1 }'

            KEYDROP_07FA1C9C_API_KEY: sk-legacy-top
            """)
            _ = try! DSHWriter.add(
                providerID: "07fa1c9c-1111-2222-3333-444455556666",
                key: "sk-healed",
                url: "https://sub.tidalrelay.com",
                models: ["deepseek-v4-flash"]
            )
            let healed = env.read("dsh-creds.yaml")
            t.expect(!healed.contains("\nKEYDROP_07FA1C9C_API_KEY:"), "[事故] 顶格遗留行已清除")
            t.contains(healed, "\n  KEYDROP_07FA1C9C_API_KEY: sk-healed", "[事故] 凭据缩进收敛进 refs")
            t.contains(healed, "sk-existing", "[事故] 他人凭据保留")
            t.contains(healed, "WORKBUDDY_ACCOUNT_X", "[事故] 多行标量条目保留")
            // 插入位置必须在多行标量整个条目之后(块末尾),不得切断标量
            let scalarEnd = healed.range(of: "\"b\": 1 }")
            let newEntry = healed.range(of: "\n  KEYDROP_07FA1C9C_API_KEY:")
            t.expect(scalarEnd != nil && newEntry != nil && scalarEnd!.upperBound < newEntry!.lowerBound,
                     "[事故] 插入在多行标量之后(块末尾)")

            // ② 缩进行原位更新:不产生重复、不出现顶格行、旧值无残留
            _ = try! DSHWriter.add(
                providerID: "07fa1c9c-1111-2222-3333-444455556666",
                key: "sk-rotated",
                url: "https://sub.tidalrelay.com",
                models: ["deepseek-v4-flash"]
            )
            let updated = env.read("dsh-creds.yaml")
            t.equal(updated.components(separatedBy: "KEYDROP_07FA1C9C_API_KEY").count - 1, 1,
                    "[更新] 单一出现(无重复追加)")
            t.contains(updated, "\n  KEYDROP_07FA1C9C_API_KEY: sk-rotated", "[更新] 值已换新且保持缩进")
            t.expect(!updated.contains("sk-healed"), "[更新] 旧值无残留")
            t.expect(!updated.contains("\nKEYDROP_07FA1C9C_API_KEY:"), "[更新] 无顶格行")

            // ③ remove 清缩进行;他人凭据不受影响
            try! DSHWriter.remove(providerID: "07fa1c9c-1111-2222-3333-444455556666")
            let afterDel = env.read("dsh-creds.yaml")
            t.expect(!afterDel.contains("KEYDROP_07FA1C9C_API_KEY"), "[删除] 缩进行已清")
            t.contains(afterDel, "DEEPSEEK_API_KEY: sk-existing", "[删除] 他人凭据保留")

            // ④ 只剩自己一条时删空 → refs 收敛为显式空映射(裸 refs: 会被读成 null)
            let env2 = try! TestEnv("dsh-refs-empty")
            defer { env2.cleanup() }
            env2.write("dsh-creds.yaml", "version: 1\nrefs:\n  KEYDROP_BBB22222_API_KEY: sk-only\n")
            _ = try! DSHWriter.add(
                providerID: "bbb22222-1111-2222-3333-444455556666",
                key: "sk-next",
                url: "https://b.com",
                models: ["deepseek-v4-flash"]
            )
            try! DSHWriter.remove(providerID: "bbb22222-1111-2222-3333-444455556666")
            let emptied = env2.read("dsh-creds.yaml")
            t.contains(emptied, "refs: {}", "[删空] refs 收敛为显式空映射")
            t.expect(!emptied.contains("KEYDROP_BBB22222"), "[删空] 凭据已清")
            t.contains(emptied, "version: 1", "[删空] 骨架保留")
        }
    }
}
