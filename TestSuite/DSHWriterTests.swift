import Foundation
import KeyDropCore

enum DSHWriterTests {
    static func run(_ h: Harness) {
        h.runSuite("DSHWriter") { t in
            // baseURL 规范化
            t.equal(DSHWriter.normalizeBaseURL("https://ergouapi.co"), "https://ergouapi.co/v1", "无 /v1 补齐")
            t.equal(DSHWriter.normalizeBaseURL("https://ergouapi.co/"), "https://ergouapi.co/v1", "尾斜杠处理")
            t.equal(DSHWriter.normalizeBaseURL("https://x.com/v1"), "https://x.com/v1", "/v1 保持")
            t.equal(DSHWriter.normalizeBaseURL("https://x.com/v1/"), "https://x.com/v1", "/v1/ 去尾斜杠")
            t.equal(DSHWriter.normalizeBaseURL("https://x.com/api"), "https://x.com/api", "/api 保持")
            t.equal(DSHWriter.normalizeBaseURL("https://x.com/chat/completions"), "https://x.com/chat/completions", "/chat/completions 保持")

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
                url: "https://ergouapi.co",
                models: ["deepseek-v4-flash-free"]
            )
            t.equal(route, "keydrop-0219dfa3", "返回 route")
            let settings = env.read("dsh.yaml")
            t.contains(settings, "keydrop-0219dfa3:", "provider 块写入")
            t.contains(settings, "baseURL: https://ergouapi.co/v1", "baseURL 规范化写入")
            t.contains(settings, "apiKeyEnv: KEYDROP_0219DFA3_API_KEY", "env 引用")
            t.contains(settings, "- id: deepseek-v4-flash-free", "模型写入")
            let creds = env.read("dsh-creds.yaml")
            t.contains(creds, "KEYDROP_0219DFA3_API_KEY: sk-secret-key-123456", "凭证写入")

            // 幂等:再次 add 不重复块
            _ = try! DSHWriter.add(
                providerID: "0219dfa3-311a-4df3-943b-1ee73e186941",
                key: "sk-secret-key-123456",
                url: "https://ergouapi.co",
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
        }
    }
}
