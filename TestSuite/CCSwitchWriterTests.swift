import Foundation
import KeyDropCore

enum CCSwitchWriterTests {
    /// 建最小 cc-switch DB schema(对齐真实表结构)
    static func createSchema(_ env: TestEnv) throws {
        let db = try DB(path: env.dir + "/cc-switch.db")
        try db.run("""
            CREATE TABLE IF NOT EXISTS providers (
                id TEXT PRIMARY KEY, app_type TEXT, name TEXT, settings_config TEXT,
                website_url TEXT, category TEXT, created_at TEXT, sort_index INTEGER,
                notes TEXT, icon TEXT, icon_color TEXT, meta TEXT, is_current INTEGER DEFAULT 0,
                in_failover_queue INTEGER DEFAULT 0
            )
        """)
        try db.run("""
            CREATE TABLE IF NOT EXISTS provider_endpoints (
                provider_id TEXT, app_type TEXT, url TEXT, added_at TEXT
            )
        """)
        try db.run("""
            CREATE TABLE IF NOT EXISTS provider_health (
                provider_id TEXT PRIMARY KEY, app_type TEXT, is_healthy INTEGER,
                fail_count INTEGER, last_checked_at TEXT, last_error TEXT, last_success_at TEXT
            )
        """)
    }

    static func run(_ h: Harness) {
        h.runSuite("CCSwitchWriter") { t in
            let env = try! TestEnv("cc")
            defer { env.cleanup() }
            try! createSchema(env)
            let writer = CCSwitchWriter()

            // meta 含 apiFormat(codex chat-only)
            var parsed = ParsedKey()
            parsed.key = "sk-abcdef123456"
            parsed.url = "https://0v0.club/v1"
            let r = try! writer.add(parsed, appType: "codex", models: ["gpt-5.6-sol"], proxy: nil)
            t.expect(r.providerID != nil, "add 返回 providerID")
            let db = try! DB(path: env.dir + "/cc-switch.db")
            let meta = try! db.scalar("SELECT meta FROM providers WHERE id=?", [r.providerID])
            t.contains(meta ?? "", "apiFormat", "meta 含 apiFormat")
            t.contains(meta ?? "", "commonConfigEnabled", "meta 对齐 cc-switch 结构")
            t.contains(meta ?? "", "endpointAutoSelect", "meta 对齐 cc-switch 结构")

            // is_current=1 + 其他 codex provider 归零
            let cur = try! db.scalar("SELECT is_current FROM providers WHERE id=?", [r.providerID])
            t.equal(cur, "1", "新 provider 激活")

            // endpoint 写入
            let ep = try! db.scalar("SELECT url FROM provider_endpoints WHERE provider_id=?", [r.providerID])
            t.equal(ep, "https://0v0.club/v1", "endpoint 记录原始 url")

            // 重复 add(同 URL)→ 去重更新:provider 数不变,is_current 转移
            let r2 = try! writer.add(parsed, appType: "codex", models: ["gpt-5.6-sol"], proxy: nil)
            t.expect(r2.providerID != r.providerID, "去重后新建(删旧建新)")
            let cnt = try! db.scalar("SELECT count(*) FROM providers WHERE app_type='codex'")
            t.equal(cnt, "1", "同 URL 不重复:剩 1 个")

            // URL 规范化差异:无 /v1 也能去重
            var parsedNoV1 = ParsedKey()
            parsedNoV1.key = "sk-abcdef123456"
            parsedNoV1.url = "https://0v0.club"
            _ = try! writer.add(parsedNoV1, appType: "codex", models: ["gpt-5.6-sol"], proxy: nil)
            let cnt2 = try! db.scalar("SELECT count(*) FROM providers WHERE app_type='codex'")
            t.equal(cnt2, "1", "0v0.club 与 0v0.club/v1 视为同 URL")

            // 直写 codex config:token 行必须写入且覆盖旧残留(防张冠李戴回归)
            let env2 = try! TestEnv("cc-token")
            defer { env2.cleanup() }
            try! createSchema(env2)
            // 预置旧 token 残留(cc-switch 直写遗留 bug 场景)
            env2.write("codex.toml", """
            model_provider = "custom"
            model = "old-model"
            [model_providers.custom]
            name = "custom"
            wire_api = "responses"
            requires_openai_auth = true
            base_url = "https://old-gateway/v1"
            experimental_bearer_token = "sk-STALE-TOKEN"
            """)
            let w2 = CCSwitchWriter()
            var p2 = ParsedKey()
            p2.key = "sk-abcdef123456"
            p2.url = "https://0v0.club"
            _ = try! w2.add(p2, appType: "codex", models: ["gpt-5.6-sol"], proxy: nil)
            let cfg = env2.read("codex.toml")
            t.contains(cfg, "experimental_bearer_token = \"sk-abcdef123456\"", "旧 token 被新 key 覆盖")
            t.contains(cfg, "base_url = \"https://0v0.club/v1\"", "base_url 补 /v1 写入")
            t.contains(cfg, "model = \"gpt-5.6-sol\"", "model 写入")
            t.expect(!cfg.contains("sk-STALE-TOKEN"), "无旧 token 残留")

            // 热切换 rename:provider_endpoints.provider_id 必须同步(防孤儿)
            let env3 = try! TestEnv("cc-rename")
            defer { env3.cleanup() }
            try! createSchema(env3)
            let w3 = CCSwitchWriter()
            var p3 = ParsedKey()
            p3.key = "sk-abcdef123456"
            p3.url = "https://0v0.club"
            let r3 = try! w3.add(p3, appType: "codex", models: ["gpt-5.6-sol"], proxy: nil)
            let db3 = try! DB(path: env3.dir + "/cc-switch.db")
            let epBefore = try! db3.scalar("SELECT provider_id FROM provider_endpoints WHERE provider_id=?", [r3.providerID])
            t.equal(epBefore, r3.providerID, "endpoint 归属新 provider")
            // cc-switch settings 标记当前激活 codex → 再导入触发 rename
            env3.write("settings.json", "{\"currentProviderCodex\": \"\(r3.providerID ?? "")\"}")
            let dbc = try! DB(path: env3.dir + "/cc-switch.db")
            let curId = try! dbc.scalar("SELECT id FROM providers WHERE app_type='codex'")
            var p3b = ParsedKey()
            p3b.key = "sk-other-key-789"
            p3b.url = "http://127.0.0.1:9"
            _ = try! w3.add(p3b, appType: "codex", models: ["gpt-5.6-sol"], proxy: nil)
            let curAfter = try! dbc.scalar("SELECT id FROM providers WHERE app_type='codex' AND is_current=1")
            t.expect(curAfter != curId, "热切换触发 rename(新 id 激活)")
            let retiredId = try! dbc.scalar("SELECT id FROM providers WHERE app_type='codex' AND is_current=0")
            t.expect(retiredId != nil && retiredId != curId, "存在被 rename 的暂存身份")
            let epAfter = try! dbc.scalar("SELECT provider_id FROM provider_endpoints WHERE url='https://0v0.club'")
            t.equal(epAfter, retiredId, "rename 后 endpoint 跟随新 id(暂存身份),无孤儿")
            let orphan = try! dbc.scalar("SELECT count(*) FROM provider_endpoints WHERE provider_id=?", [curId ?? ""])
            t.equal(orphan, "0", "原 id 下无孤儿 endpoint")

            // repairMissingProvider:不崩,补 provider
            var healed = try! writer.repairMissingProvider(entry: HistoryEntry(
                id: "repair1-1111-2222-3333-444444444444", ts: 1, raw: "x", format: "test",
                name: "repair", url: "https://0v0.club/v1", model: nil, models: ["gpt-5.6-sol"],
                key: "sk-abcdef123456", keyMasked: "sk-…", targets: ["ccswitch-codex"],
                ccProviderID: "repair1-1111-2222-3333-444444444444", ccRenamedFrom: nil,
                ccRenamedTo: nil, cpaConfigPath: nil, status: "active", note: nil,
                health: nil, healthDetail: nil, healthAt: nil
            ))
            t.expect(healed, "repair 返回结果")
        }
    }
}
