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

            // 回归:同 URL 不同 key 必须共存。旧去重只按 URL 匹配,第二个 key 的导入
            // 会 DELETE 旧 provider 重建 → 旧凭据被静默覆盖,历史旧 entry 变孤儿
            // (真实事故:同一中转站两把 key,后导入的把先导入的覆盖,cc-switch 只剩一个)
            let env5 = try! TestEnv("cc-key-coexist")
            defer { env5.cleanup() }
            try! createSchema(env5)
            let w5 = CCSwitchWriter()
            var keyA = ParsedKey()
            keyA.key = "sk-coexist-a-11111111"
            keyA.url = "https://coexist.example.org/v1"
            let ra = try! w5.add(keyA, appType: "opencode", models: ["glm-5.2"], proxy: nil)
            var keyB = ParsedKey()
            keyB.key = "sk-coexist-b-22222222"
            keyB.url = "https://coexist.example.org/v1"
            let rb = try! w5.add(keyB, appType: "opencode", models: ["glm-5.2"], proxy: nil)
            t.expect(ra.providerID != rb.providerID, "不同 key 得到独立 provider")
            let db5 = try! DB(path: env5.dir + "/cc-switch.db")
            let cnt5 = try! db5.scalar("SELECT count(*) FROM providers WHERE app_type='opencode'")
            t.equal(cnt5, "2", "同 URL 两把 key 的 provider 共存(修复前被覆盖只剩 1)")
            let cfgA = try! db5.scalar("SELECT settings_config FROM providers WHERE id=?", [ra.providerID]) ?? ""
            t.contains(cfgA, "sk-coexist-a-11111111", "第一把 key 的配置完好")
            let cfgB = try! db5.scalar("SELECT settings_config FROM providers WHERE id=?", [rb.providerID]) ?? ""
            t.contains(cfgB, "sk-coexist-b-22222222", "第二把 key 的配置已写入")
            // 同 URL 同 key 仍是幂等替换,不无限累积
            _ = try! w5.add(keyB, appType: "opencode", models: ["glm-5.2"], proxy: nil)
            let cnt6 = try! db5.scalar("SELECT count(*) FROM providers WHERE app_type='opencode'")
            t.equal(cnt6, "2", "同 key 同 URL 幂等替换不累积")

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

        // CPA 常驻入口:被动 upsert,不抢激活、幂等、模型原地更新
        h.runSuite("CCSwitchWriter.CPA 常驻入口") { t in
            let env = try! TestEnv("cc-resident")
            defer { env.cleanup() }
            try! createSchema(env)
            let w = CCSwitchWriter()
            // 用户真实激活的 provider:常驻同步绝不能碰它的 is_current
            var user = ParsedKey()
            user.key = "sk-user-active-111111"
            user.url = "https://user.example.org/v1"
            let ur = try! w.add(user, appType: "opencode", models: ["glm-5.2"], proxy: nil)
            let db = try! DB(path: env.dir + "/cc-switch.db")

            let cpaURL = "http://127.0.0.1:8317"
            let msg1 = try! w.syncCPAResident(appType: "opencode", baseURL: cpaURL,
                                              clientKey: "sk-cpa-client-0001", models: ["m-a", "m-b"])
            t.contains(msg1, "已新建", "首次:新建被动入口: \(msg1)")
            let cnt1 = try! db.scalar("SELECT count(*) FROM providers WHERE app_type='opencode'")
            t.equal(cnt1, "2", "用户 provider + 常驻入口共存")
            let residentID = try! db.scalar(
                "SELECT id FROM providers WHERE app_type='opencode' AND id != ?", [ur.providerID])!
            let cur = try! db.scalar("SELECT is_current FROM providers WHERE id=?", [residentID])
            t.equal(cur, "0", "常驻入口不抢激活(is_current=0)")
            let userCur = try! db.scalar("SELECT is_current FROM providers WHERE id=?", [ur.providerID])
            t.equal(userCur, "1", "用户 provider 激活态不受影响")

            // 再次同步同端点:原地更新模型,不重复建条目
            let msg2 = try! w.syncCPAResident(appType: "opencode", baseURL: cpaURL,
                                              clientKey: "sk-cpa-client-0001", models: ["m-a", "m-b", "m-c"])
            t.contains(msg2, "已更新", "二次:原地更新: \(msg2)")
            let cnt2 = try! db.scalar("SELECT count(*) FROM providers WHERE app_type='opencode'")
            t.equal(cnt2, "2", "重复同步不累积条目(修复前会删建或重复)")
            let cfg = try! db.scalar("SELECT settings_config FROM providers WHERE id=?", [residentID]) ?? ""
            t.contains(cfg, "m-c", "新模型已并入常驻入口")
            t.contains(cfg, "sk-cpa-client-0001", "客户端 key 写入")

            // 同 URL 不同 clientKey:不同凭据视为不同入口,新建而非覆盖(复用共存判定)
            _ = try! w.syncCPAResident(appType: "opencode", baseURL: cpaURL,
                                       clientKey: "sk-cpa-client-0002", models: ["z-a"])
            let cnt3 = try! db.scalar("SELECT count(*) FROM providers WHERE app_type='opencode'")
            t.equal(cnt3, "3", "不同客户端 key 独立共存")

            // 空模型列表:视为 CPA 未响应,跳过不清空既有列表
            let msg4 = try! w.syncCPAResident(appType: "opencode", baseURL: cpaURL,
                                              clientKey: "sk-cpa-client-0001", models: [])
            t.contains(msg4, "跳过", "空列表跳过: \(msg4)")
            let cfg4 = try! db.scalar("SELECT settings_config FROM providers WHERE id=?", [residentID]) ?? ""
            t.contains(cfg4, "m-c", "跳过不清空既有模型")

            // claude 类型凭据匹配走 env.ANTHROPIC_AUTH_TOKEN 分支
            _ = try! w.syncCPAResident(appType: "claude", baseURL: cpaURL,
                                       clientKey: "sk-cpa-client-0001", models: ["m-a"])
            let msg5 = try! w.syncCPAResident(appType: "claude", baseURL: cpaURL,
                                              clientKey: "sk-cpa-client-0001", models: ["m-a", "m-x"])
            t.contains(msg5, "已更新", "claude 类型按 env token 二次匹配原地更新: \(msg5)")
            let claudeCnt = try! db.scalar("SELECT count(*) FROM providers WHERE app_type='claude'")
            t.equal(claudeCnt, "1", "claude 常驻入口不重复建")

            // removeCPAResident:迁移清理 claude/codex 的既有 CPA 行;幂等;按端点+key 精确
            let rm1 = try! w.removeCPAResident(appType: "claude", baseURL: cpaURL, clientKey: "sk-cpa-client-0001")
            t.contains(rm1, "已移除", "claude CPA 行被移除: \(rm1)")
            let claudeCnt2 = try! db.scalar("SELECT count(*) FROM providers WHERE app_type='claude'")
            t.equal(claudeCnt2, "0", "claude CPA 行清零")
            let rm2 = try! w.removeCPAResident(appType: "claude", baseURL: cpaURL, clientKey: "sk-cpa-client-0001")
            t.equal(rm2, "", "再次移除幂等返回空")
            // opencode 移除会连带清 opencode.json 里的 provider 条目(clearOpencodeProvider)
            let rm3 = try! w.removeCPAResident(appType: "opencode", baseURL: cpaURL, clientKey: "sk-cpa-client-0001")
            t.contains(rm3, "已移除", "opencode CPA 行移除: \(rm3)")
            // 不同端点/不同 key 不互删:opencode 还剩 0002 那条与用户 provider
            let ocLeft = try! db.scalar("SELECT count(*) FROM providers WHERE app_type='opencode'")
            t.expect(ocLeft == "2", "仅删匹配端点+key 的行(剩 0002 与用户 provider,实际 \(ocLeft ?? "?"))")
        }

        // cc-switch 原生类型(pi/openclaw/hermes):托管行可更新,用户手写行绝不覆盖
        h.runSuite("CCSwitchWriter.CPA 常驻-原生类型安全") { t in
            let env = try! TestEnv("cc-native-safe")
            defer { env.cleanup() }
            try! createSchema(env)
            let w = CCSwitchWriter()
            let db = try! DB(path: env.dir + "/cc-switch.db")
            let url = "http://127.0.0.1:8317"

            // 1) 无既有行 → 建 KeyDrop 托管行(固定 id keydrop-cpa-pi)
            let r1 = try! w.syncCPAResidentNative(appType: "pi", baseURL: url,
                                                  clientKey: "sk-n-1", models: ["m-a"])
            t.contains(r1, "已新建(KeyDrop 托管", "首次新建托管行: \(r1)")
            let hostedID = CCSwitchWriter.cpaResidentID(appType: "pi")
            t.expect((try! db.scalar("SELECT count(*) FROM providers WHERE app_type='pi' AND id='\(hostedID)'")) == "1", "托管行使用固定 id")

            // 2) 再次同步(模型变化)→ 托管行原地更新,不另建
            let r2 = try! w.syncCPAResidentNative(appType: "pi", baseURL: url,
                                                  clientKey: "sk-n-1", models: ["m-a", "m-b"])
            t.contains(r2, "已更新", "托管行二次同步原地更新: \(r2)")
            t.equal(try! db.scalar("SELECT count(*) FROM providers WHERE app_type='pi'"), "1", "托管行不累积")
            let cfg = try! db.scalar("SELECT settings_config FROM providers WHERE app_type='pi'") ?? ""
            t.contains(cfg, "m-b", "新模型并入托管行")

            // 3) 用户手写同端点行 → 既不覆盖也不另建托管行
            let env2 = try! TestEnv("cc-native-user")
            defer { env2.cleanup() }
            try! createSchema(env2)
            let w2 = CCSwitchWriter()
            let db2 = try! DB(path: env2.dir + "/cc-switch.db")
            // 模拟用户手写:直接插一条 openclaw 行,baseUrl 相同但 id 非托管
            try! db2.run(
                "INSERT INTO providers (id,app_type,name,settings_config,is_current) VALUES ('mycpa','openclaw','cpa',?,0)",
                [#"{"baseUrl":"http://localhost:8317/v1","apiKey":"sk-user-x","api":"openai-completions","models":[{"id":"shangtang","name":"shangtang"}]}"#]
            )
            let r3 = try! w2.syncCPAResidentNative(appType: "openclaw", baseURL: url,
                                                   clientKey: "sk-user-x", models: ["zzz-new"])
            t.contains(r3, "不覆盖也不另建", "检测到用户手写行不覆盖: \(r3)")
            t.equal(try! db2.scalar("SELECT count(*) FROM providers WHERE app_type='openclaw'"), "1", "不另建托管行")
            let keep = try! db2.scalar("SELECT settings_config FROM providers WHERE app_type='openclaw'") ?? ""
            t.contains(keep, "shangtang", "用户手写的 shangtang 模型保留(曾被整行覆盖过)")
            t.expect(!keep.contains("zzz-new"), "未把新模型塞进用户行")
            // localhost 与 127.0.0.1 归一:同一端点即认定为用户手写
        }
    }
}
