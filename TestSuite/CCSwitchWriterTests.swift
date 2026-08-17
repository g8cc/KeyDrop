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
