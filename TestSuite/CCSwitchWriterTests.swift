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
            parsed.url = "https://gwy.example.org/v1"
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
            let firstSort = try! db.scalar("SELECT sort_index FROM providers WHERE id=?", [r.providerID])
            t.equal(firstSort, "0", "新 provider 排序置顶")

            // endpoint 写入
            let ep = try! db.scalar("SELECT url FROM provider_endpoints WHERE provider_id=?", [r.providerID])
            t.equal(ep, "https://gwy.example.org/v1", "endpoint 记录原始 url")

            // 重复 add(同 URL)→ 去重更新:provider 数不变,is_current 转移
            let r2 = try! writer.add(parsed, appType: "codex", models: ["gpt-5.6-sol"], proxy: nil)
            t.expect(r2.providerID != r.providerID, "去重后新建(删旧建新)")
            let cnt = try! db.scalar("SELECT count(*) FROM providers WHERE app_type='codex'")
            t.equal(cnt, "1", "同 URL 不重复:剩 1 个")

            // URL 规范化差异:无 /v1 也能去重
            var parsedNoV1 = ParsedKey()
            parsedNoV1.key = "sk-abcdef123456"
            parsedNoV1.url = "https://gwy.example.org"
            _ = try! writer.add(parsedNoV1, appType: "codex", models: ["gpt-5.6-sol"], proxy: nil)
            let cnt2 = try! db.scalar("SELECT count(*) FROM providers WHERE app_type='codex'")
            t.equal(cnt2, "1", "gwy.example.org 与 gwy.example.org/v1 视为同 URL")

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
            p2.url = "https://gwy.example.org"
            _ = try! w2.add(p2, appType: "codex", models: ["gpt-5.6-sol"], proxy: nil)
            let cfg = env2.read("codex.toml")
            t.contains(cfg, "experimental_bearer_token = \"sk-abcdef123456\"", "旧 token 被新 key 覆盖")
            t.contains(cfg, "base_url = \"https://gwy.example.org/v1\"", "base_url 补 /v1 写入")
            t.contains(cfg, "model = \"gpt-5.6-sol\"", "model 写入")
            t.expect(!cfg.contains("sk-STALE-TOKEN"), "无旧 token 残留")

            // 热切换:旧 provider id 不再被 mutate(cc-switch 进程缓存 id,突变导致认知错位)
            let env3 = try! TestEnv("cc-rename")
            defer { env3.cleanup() }
            try! createSchema(env3)
            let w3 = CCSwitchWriter()
            var p3 = ParsedKey()
            p3.key = "sk-abcdef123456"
            p3.url = "https://gwy.example.org"
            let r3 = try! w3.add(p3, appType: "codex", models: ["gpt-5.6-sol"], proxy: nil)
            let db3 = try! DB(path: env3.dir + "/cc-switch.db")
            let epBefore = try! db3.scalar("SELECT provider_id FROM provider_endpoints WHERE provider_id=?", [r3.providerID])
            t.equal(epBefore, r3.providerID, "endpoint 归属新 provider")
            // cc-switch settings 标记当前激活 codex → 再导入另一个 provider
            env3.write("settings.json", "{\"currentProviderCodex\": \"\(r3.providerID ?? "")\"}")
            let dbc = try! DB(path: env3.dir + "/cc-switch.db")
            let curId = try! dbc.scalar("SELECT id FROM providers WHERE app_type='codex'")
            var p3b = ParsedKey()
            p3b.key = "sk-other-key-789"
            p3b.url = "http://127.0.0.1:9"
            _ = try! w3.add(p3b, appType: "codex", models: ["gpt-5.6-sol"], proxy: nil)
            let curAfter = try! dbc.scalar("SELECT id FROM providers WHERE app_type='codex' AND is_current=1")
            t.expect(curAfter != curId, "新 provider 激活")
            // 旧 provider id 保持不变(无 rename),只是 is_current=0
            t.equal(curId, r3.providerID, "旧 provider id 不被 mutate")
            let oldCurrent = try! dbc.scalar("SELECT is_current FROM providers WHERE app_type='codex' AND id=?", [r3.providerID])
            t.equal(oldCurrent, "0", "旧 provider 降为非激活")
            // endpoint 归属不变,无孤儿
            let epAfter = try! dbc.scalar("SELECT provider_id FROM provider_endpoints WHERE url='https://gwy.example.org'")
            t.equal(epAfter, r3.providerID, "endpoint 归属保持,无孤儿")

            // 新导入必须位于列表首位,不能只靠 is_current 激活:
            // cc-switch 对 NULL sort_index 使用 999999 兜底,旧实现会把最新 provider 放到末尾。
            let env4 = try! TestEnv("cc-sort")
            defer { env4.cleanup() }
            try! createSchema(env4)
            let w4 = CCSwitchWriter()
            var old = ParsedKey()
            old.key = "sk-sort-old-111111"
            old.url = "https://old.example.org/v1"
            _ = try! w4.add(old, appType: "opencode", models: ["glm-5.2"], proxy: nil)
            var newest = ParsedKey()
            newest.key = "sk-sort-new-222222"
            newest.url = "https://new.example.org/v1"
            let newestResult = try! w4.add(newest, appType: "opencode", models: ["glm-5.2"], proxy: nil)
            let firstBySort = try! DB(path: env4.dir + "/cc-switch.db").scalar(
                "SELECT id FROM providers WHERE app_type='opencode' ORDER BY COALESCE(sort_index, 999999), created_at ASC, id ASC LIMIT 1"
            )
            t.equal(firstBySort, newestResult.providerID, "连续导入时最新 provider 位于列表顶部")
            let oldSort = try! DB(path: env4.dir + "/cc-switch.db").scalar(
                "SELECT sort_index FROM providers WHERE name LIKE 'old.example.org%'"
            )
            t.equal(oldSort, "1", "旧 provider 顺序整体后移")

            // repairMissingProvider:不崩,补 provider
            var healed = try! writer.repairMissingProvider(entry: HistoryEntry(
                id: "repair1-1111-2222-3333-444444444444", ts: 1, raw: "x", format: "test",
                name: "repair", url: "https://gwy.example.org/v1", model: nil, models: ["gpt-5.6-sol"],
                key: "sk-abcdef123456", keyMasked: "sk-…", targets: ["ccswitch-codex"],
                ccProviderID: "repair1-1111-2222-3333-444444444444", ccRenamedFrom: nil,
                ccRenamedTo: nil, cpaConfigPath: nil, status: "active", note: nil,
                health: nil, healthDetail: nil, healthAt: nil
            ))
            t.expect(healed, "repair 返回结果")

            // 回归:opencode 双写一致性(DB settings_config 与 opencode.json 模型显示名必须一致,
            // 否则用户搜 opencode.json 里的名字搜不到 cc-switch 条目。bug 来源:opencodeSettingsConfig
            // 与 mergeOpencodeProvider 各自随机后缀。修复:共用 opencodeModelDict)
            let envSync = try! TestEnv("cc-sync")
            defer { envSync.cleanup() }
            try! createSchema(envSync)
            let ws = CCSwitchWriter()
            var ps = ParsedKey()
            ps.key = "sk-sync-test-001"
            ps.url = "https://sync.test/v1"
            let rs = try! ws.add(ps, appType: "opencode", models: ["grok-4.6", "deepseek-v4-flash"], proxy: nil)
            // re-add / refresh 会去重重建换 pid,快照里动态查当前 providerID
            func currentPID() -> String {
                let raw = envSync.read("opencode.json")
                let cfg = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
                let provs = (cfg["provider"] as? [String: Any]) ?? [:]
                // 排除已退役的非激活条目;真实场景只有一个 opencode provider
                for (k, v) in provs {
                    if k == "KeyDrop" { continue }
                    if let pd = v as? [String: Any],
                       let opts = pd["options"] as? [String: Any],
                       let base = opts["baseURL"] as? String,
                       base.contains("sync.test") {
                        return k
                    }
                }
                return rs.providerID
            }
            // 抓首次双写后的 name
            func snapshot() -> [String: String] {
                let pid = currentPID()
                let dbNames: [String: String] = {
                    let raw = try! DB(path: envSync.dir + "/cc-switch.db").scalar(
                        "SELECT settings_config FROM providers WHERE id=?", [pid]) ?? "{}"
                    let cfg = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
                    let ms = (cfg["models"] as? [String: Any]) ?? [:]
                    var out: [String: String] = [:]
                    for (k, v) in ms {
                        if let n = (v as? [String: Any])?["name"] as? String { out[k] = n }
                    }
                    return out
                }()
                let ocNames: [String: String] = {
                    let raw = envSync.read("opencode.json")
                    let cfg = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
                    let provs = (cfg["provider"] as? [String: Any]) ?? [:]
                    let pd = (provs[pid] as? [String: Any]) ?? [:]
                    let ms = (pd["models"] as? [String: Any]) ?? [:]
                    var out: [String: String] = [:]
                    for (k, v) in ms {
                        if let n = (v as? [String: Any])?["name"] as? String { out[k] = n }
                    }
                    return out
                }()
                return ["db.grok": dbNames["grok-4.6"] ?? "<nil>",
                         "oc.grok": ocNames["grok-4.6"] ?? "<nil>",
                         "db.deepseek": dbNames["deepseek-v4-flash"] ?? "<nil>",
                         "oc.deepseek": ocNames["deepseek-v4-flash"] ?? "<nil>"]
            }
            let s1 = snapshot()
            t.equal(s1["db.grok"], s1["oc.grok"], "grok-4.6 DB 与 opencode.json 同名(首次导入)")
            t.equal(s1["db.deepseek"], s1["oc.deepseek"], "deepseek DB 与 opencode.json 同名(首次导入)")
            // 再次导入(同 URL 去重新建):应保留 opencode.json 既有 name,不随机
            _ = try! ws.add(ps, appType: "opencode", models: ["grok-4.6", "deepseek-v4-flash"], proxy: nil)
            let s2 = snapshot()
            t.equal(s2["db.grok"], s1["db.grok"], "再次导入:grok-4.6 name 保留不变(幂等)")
            t.equal(s2["db.deepseek"], s1["db.deepseek"], "再次导入:deepseek name 保留不变(幂等)")
            t.equal(s2["oc.grok"], s1["oc.grok"], "再次导入:opencode.json grok 不变")
            t.equal(s2["db.grok"], s2["oc.grok"], "再次导入:DB 与 opencode.json 仍同名")
            // syncModelsAfterRefresh:刷新路径也必须保持一致
            var pRefresh = ParsedKey()
            pRefresh.key = "sk-sync-test-001"
            pRefresh.url = "https://sync.test/v1"
            try! ws.syncModelsAfterRefresh(pRefresh, providerID: currentPID(), appType: "opencode",
                                           models: ["grok-4.6", "deepseek-v4-flash"])
            let s3 = snapshot()
            t.equal(s3["db.grok"], s1["db.grok"], "refresh 后:grok-4.6 name 保留")
            t.equal(s3["db.grok"], s3["oc.grok"], "refresh 后:DB 与 opencode.json 同名")
        }
    }
}
