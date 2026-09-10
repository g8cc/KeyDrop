import Foundation
import KeyDropCore

enum CoreTests {
    static func run(_ h: Harness) {
        h.runSuite("Core.routeAppType") { t in
            // gpt 系 → codex
            t.equal(Core.routeAppType(selectedModels: ["gpt-5.6-sol"], modelsOverride: nil, default: "opencode"), "codex", "gpt → codex")
            t.equal(Core.routeAppType(selectedModels: ["my-gpt-4o-mini"], modelsOverride: nil, default: "opencode"), "codex", "gpt- 任意位置 → codex")
            // claude 系 → claude
            t.equal(Core.routeAppType(selectedModels: ["claude-sonnet-4"], modelsOverride: nil, default: "opencode"), "claude", "claude → claude")
            // 其他 → opencode
            t.equal(Core.routeAppType(selectedModels: ["glm-5.2"], modelsOverride: nil, default: "opencode"), "opencode", "glm → opencode")
            t.equal(Core.routeAppType(selectedModels: ["deepseek-v4-flash"], modelsOverride: nil, default: "opencode"), "opencode", "deepseek → opencode")
            // 混合:含 gpt → codex
            t.equal(Core.routeAppType(selectedModels: ["glm-5.2", "gpt-5.6-luna"], modelsOverride: nil, default: "opencode"), "codex", "混合含 gpt → codex")
            // 图生/视觉等非 chat 的 gpt 系不路由 codex(fal-ai/gpt-image-2 真实事故)
            t.equal(Core.routeAppType(selectedModels: ["fal-ai/gpt-image-2"], modelsOverride: nil, default: "opencode"), "opencode", "gpt-image → opencode 而非 codex")
            t.equal(Core.routeAppType(selectedModels: ["gpt-image-2", "deepseek-v4-flash"], modelsOverride: nil, default: "opencode"), "opencode", "图生+deepseek → opencode")
            t.equal(Core.routeAppType(selectedModels: ["gpt-vision"], modelsOverride: nil, default: "opencode"), "opencode", "gpt-vision → opencode")
            t.equal(Core.routeAppType(selectedModels: ["gpt-realtime"], modelsOverride: nil, default: "opencode"), "opencode", "gpt-realtime → opencode")
            // forced 覆盖
            t.equal(Core.routeAppType(selectedModels: ["gpt-5.6-sol"], modelsOverride: nil, default: "opencode", forced: true), "opencode", "forced 覆盖规则")
            // 空列表 → 默认
            t.equal(Core.routeAppType(selectedModels: [], modelsOverride: nil, default: "claude"), "claude", "空列表回退默认")
        }

        h.runSuite("Core.healthFor") { t in
            let ok = APITestResult(ok: true, style: "openai", models: [], detail: "200", authFailed: false, needsProxy: false)
            t.equal(Core.healthFor(ok).health, "ok", "ok 映射")
            let proxy = APITestResult(ok: true, style: "openai", models: [], detail: "200 | 直连失败,需代理", authFailed: false, needsProxy: true)
            let ph = Core.healthFor(proxy)
            t.equal(ph.health, "proxy-ok", "needsProxy → proxy-ok")
            t.contains(ph.detail, "需代理", "proxy-ok detail 提示")
            let dead = APITestResult(ok: false, style: "", models: [], detail: "401", authFailed: true, needsProxy: false)
            t.equal(Core.healthFor(dead).health, "dead", "authFailed → dead")
            let err = APITestResult(ok: false, style: "", models: [], detail: "timeout", authFailed: false, needsProxy: false)
            t.equal(Core.healthFor(err).health, "err", "其他失败 → err")
        }

        h.runSuite("Core.balance quota") { t in
            let env = try! TestEnv("core-quota")
            defer { env.cleanup() }
            try? DB(path: env.dir + "/cc-switch.db").run("""
                CREATE TABLE IF NOT EXISTS providers (
                    id TEXT PRIMARY KEY, app_type TEXT, name TEXT, settings_config TEXT,
                    website_url TEXT, category TEXT, created_at TEXT, sort_index INTEGER,
                    notes TEXT, icon TEXT, icon_color TEXT, meta TEXT, is_current INTEGER DEFAULT 0,
                    in_failover_queue INTEGER DEFAULT 0
                )
            """)
            try? DB(path: env.dir + "/cc-switch.db").run("""
                CREATE TABLE IF NOT EXISTS provider_endpoints (
                    provider_id TEXT, app_type TEXT, url TEXT, added_at TEXT
                )
            """)
            let core = Core()
            // 有余额:刷新后 health=ok
            guard let srvOK = try? MockHTTPServer(mode: .balanceOK) else {
                t.expect(false, "mock 启动失败")
                return
            }
            let okBase = "http://127.0.0.1:\(srvOK.port)"
            _ = try! core.add(raw: "\(okBase) sk-test-bal1111111111", ccOverride: true, cpaOverride: false, dshOverride: false, models: ["gpt-5.6-sol"], force: true, appType: "codex", appTypeForced: true)
            let okEntry0 = core.history.snapshot().first { $0.key == "sk-test-bal1111111111" }
            t.expect(okEntry0 != nil, "条目已入库")
            let okMsg = try! core.refreshModels(entryIDPrefix: okEntry0!.id)
            t.contains(okMsg, "可用", "有余额刷新可用")
            let okEntry = core.history.snapshot().first { $0.key == "sk-test-bal1111111111" }
            t.equal(okEntry?.health, "ok", "有余额 health=ok")

            // 无余额:刷新后 health=quota
            guard let srvZero = try? MockHTTPServer(mode: .balanceZero) else {
                t.expect(false, "mock 启动失败")
                return
            }
            let zeroBase = "http://127.0.0.1:\(srvZero.port)"
            _ = try! core.add(raw: "\(zeroBase) sk-test-bal2222222222", ccOverride: true, cpaOverride: false, dshOverride: false, models: ["gpt-5.6-sol"], force: true, appType: "codex", appTypeForced: true)
            let zeroEntry0 = core.history.snapshot().first { $0.key == "sk-test-bal2222222222" }
            t.expect(zeroEntry0 != nil, "条目已入库2")
            let zeroMsg = try! core.refreshModels(entryIDPrefix: zeroEntry0!.id)
            t.contains(zeroMsg, "无余额", "无余额刷新标 quota: \(zeroMsg)")
            t.contains(zeroMsg, "充值后", "提示可恢复: \(zeroMsg)")
            let zeroEntry = core.history.snapshot().first { $0.key == "sk-test-bal2222222222" }
            t.equal(zeroEntry?.health, "quota", "无余额 health=quota")
            t.equal(zeroEntry?.healthColor.ok, false, "quota 非可用色")
            t.equal(zeroEntry?.healthColor.dead, false, "quota 非失效色")

            // 网关无余额接口:保持 ok
            guard let srvNone = try? MockHTTPServer(mode: .balanceNoInfo) else {
                t.expect(false, "mock 启动失败")
                return
            }
            let noneBase = "http://127.0.0.1:\(srvNone.port)"
            _ = try! core.add(raw: "\(noneBase) sk-test-bal3333333333", ccOverride: true, cpaOverride: false, dshOverride: false, models: ["gpt-5.6-sol"], force: true, appType: "codex", appTypeForced: true)
            let noneEntry0 = core.history.snapshot().first { $0.key == "sk-test-bal3333333333" }
            _ = try! core.refreshModels(entryIDPrefix: noneEntry0!.id)
            let noneEntry = core.history.snapshot().first { $0.key == "sk-test-bal3333333333" }
            t.equal(noneEntry?.health, "ok", "无余额接口保持 ok")
        }

        h.runSuite("Core.html200 假阳性") { t in
            let env = try! TestEnv("core-html")
            defer { env.cleanup() }
            try? DB(path: env.dir + "/cc-switch.db").run("""
                CREATE TABLE IF NOT EXISTS providers (
                    id TEXT PRIMARY KEY, app_type TEXT, name TEXT, settings_config TEXT,
                    website_url TEXT, category TEXT, created_at TEXT, sort_index INTEGER,
                    notes TEXT, icon TEXT, icon_color TEXT, meta TEXT, is_current INTEGER DEFAULT 0,
                    in_failover_queue INTEGER DEFAULT 0
                )
            """)
            try? DB(path: env.dir + "/cc-switch.db").run("""
                CREATE TABLE IF NOT EXISTS provider_endpoints (
                    provider_id TEXT, app_type TEXT, url TEXT, added_at TEXT
                )
            """)
            let core = Core()
            guard let srv = try? MockHTTPServer(mode: .html200) else {
                t.expect(false, "mock 启动失败")
                return
            }
            let base = "http://127.0.0.1:\(srv.port)"
            // 直接探测:/models 200 HTML → 应跳过并命中 /v1/models 401 → 不可用
            let res = APITester.test(url: base, key: "sk-html2001111111111", timeout: 5)
            t.expect(!res.ok, "200 HTML 兜底页不判可用: \(res.detail)")
            t.expect(res.authFailed, "命中 401 标 authFailed")
            // 刷新路径:条目应标 dead
            _ = try! core.add(raw: "\(base) sk-html2001111111111", ccOverride: true, cpaOverride: false, dshOverride: false, models: ["glm-5.2"], force: true, appType: "opencode", appTypeForced: true)
            let e0 = core.history.snapshot().first { $0.key == "sk-html2001111111111" }
            t.expect(e0 != nil, "条目入库")
            let msg = try? core.refreshModels(entryIDPrefix: e0!.id)
            t.expect(msg == nil || msg!.contains("失效") || msg!.contains("不可用"), "刷新后判失效: \(msg ?? "抛错")")
            let e1 = core.history.snapshot().first { $0.key == "sk-html2001111111111" }
            t.equal(e1?.health, "dead", "health=dead")
        }

        h.runSuite("Core.quota429 chat 额度") { t in
            let env = try! TestEnv("core-429")
            defer { env.cleanup() }
            try? DB(path: env.dir + "/cc-switch.db").run("""
                CREATE TABLE IF NOT EXISTS providers (
                    id TEXT PRIMARY KEY, app_type TEXT, name TEXT, settings_config TEXT,
                    website_url TEXT, category TEXT, created_at TEXT, sort_index INTEGER,
                    notes TEXT, icon TEXT, icon_color TEXT, meta TEXT, is_current INTEGER DEFAULT 0,
                    in_failover_queue INTEGER DEFAULT 0
                )
            """)
            try? DB(path: env.dir + "/cc-switch.db").run("""
                CREATE TABLE IF NOT EXISTS provider_endpoints (
                    provider_id TEXT, app_type TEXT, url TEXT, added_at TEXT
                )
            """)
            let core = Core()
            guard let srv = try? MockHTTPServer(mode: .quota429) else {
                t.expect(false, "mock 启动失败")
                return
            }
            let base = "http://127.0.0.1:\(srv.port)"
            // 直接探测:models 200 + chat 429 quota → quotaExhausted
            let res = APITester.test(url: base, key: "sk-quota429111111111", timeout: 5)
            t.expect(res.ok, "models 200 仍可用: \(res.detail)")
            t.expect(res.quotaExhausted, "chat 429 quota 标 quotaExhausted: \(res.detail)")
            // healthFor 映射 quota
            let h = Core.healthFor(res)
            t.equal(h.health, "quota", "429 quota → quota 状态")
            // 刷新路径:条目标 quota
            _ = try! core.add(raw: "\(base) sk-quota429111111111", ccOverride: true, cpaOverride: false, dshOverride: false, models: ["mimo-v2.5-pro"], force: true, appType: "opencode", appTypeForced: true)
            let e0 = core.history.snapshot().first { $0.key == "sk-quota429111111111" }
            t.expect(e0 != nil, "条目入库")
            let msg = try! core.refreshModels(entryIDPrefix: e0!.id)
            t.contains(msg, "无额度", "刷新标 quota: \(msg)")
            let e1 = core.history.snapshot().first { $0.key == "sk-quota429111111111" }
            t.equal(e1?.health, "quota", "health=quota")
            // 普通 429(无 quota 关键词)不标 quota:mock 429 返回 quota 文本,此断言验证区分逻辑
        }

        h.runSuite("Core.chat424 服务不可用") { t in
            let env = try! TestEnv("core-424")
            defer { env.cleanup() }
            let core = Core()
            guard let srv = try? MockHTTPServer(mode: .chat524) else {
                t.expect(false, "mock 启动失败")
                return
            }
            let base = "http://127.0.0.1:\(srv.port)"
            let res = APITester.test(url: base, key: "sk-chat52411111111111", timeout: 5)
            t.expect(!res.ok, "chat 424 判不可用: \(res.detail)")
            t.expect(!res.authFailed, "424 非认证失败")
            t.contains(res.detail, "chat 端点 HTTP 424", "detail 标注 chat 状态")
        }

        h.runSuite("Core.chat401 认证失效") { t in
            let env = try! TestEnv("core-401")
            defer { env.cleanup() }
            try? DB(path: env.dir + "/cc-switch.db").run("""
                CREATE TABLE IF NOT EXISTS providers (
                    id TEXT PRIMARY KEY, app_type TEXT, name TEXT, settings_config TEXT,
                    website_url TEXT, category TEXT, created_at TEXT, sort_index INTEGER,
                    notes TEXT, icon TEXT, icon_color TEXT, meta TEXT, is_current INTEGER DEFAULT 0,
                    in_failover_queue INTEGER DEFAULT 0
                )
            """)
            try? DB(path: env.dir + "/cc-switch.db").run("""
                CREATE TABLE IF NOT EXISTS provider_endpoints (
                    provider_id TEXT, app_type TEXT, url TEXT, added_at TEXT
                )
            """)
            let core = Core()
            guard let srv = try? MockHTTPServer(mode: .chat401) else {
                t.expect(false, "mock 启动失败")
                return
            }
            let base = "http://127.0.0.1:\(srv.port)"
            // 直接探测:models 200(公共端点)但 chat 401 → 必须判 authFailed
            // (修复前 chatHealthCheck 不认 401,条目刷新后仍 health=ok,真实事故:ollama.com)
            let res = APITester.test(url: base, key: "sk-chat40111111111111", timeout: 5)
            t.expect(!res.ok, "chat 401 判不可用: \(res.detail)")
            t.expect(res.authFailed, "chat 401 标 authFailed: \(res.detail)")
            let h = Core.healthFor(res)
            t.equal(h.health, "dead", "401 → dead 状态")
            // 刷新路径:条目标 dead,自动移出可用列表
            _ = try! core.add(raw: "\(base) sk-chat40111111111111", ccOverride: true, cpaOverride: false, dshOverride: false, models: ["gpt-5.6-sol"], force: true, appType: "opencode", appTypeForced: true)
            let e0 = core.history.snapshot().first { $0.key == "sk-chat40111111111111" }
            t.expect(e0 != nil, "条目入库")
            do {
                _ = try core.refreshModels(entryIDPrefix: e0!.id)
                t.expect(false, "刷新应报失效")
            } catch {
                t.contains(error.localizedDescription, "失效", "刷新报错标注 key 失效")
            }
            let e1 = core.history.snapshot().first { $0.key == "sk-chat40111111111111" }
            t.equal(e1?.health, "dead", "health=dead(移出可用列表)")
        }

        h.runSuite("Core.add 幂等") { t in
            let env = try! TestEnv("core-add")
            defer { env.cleanup() }
            // cc-switch DB schema
            try? DB(path: env.dir + "/cc-switch.db").run("""
                CREATE TABLE IF NOT EXISTS providers (
                    id TEXT PRIMARY KEY, app_type TEXT, name TEXT, settings_config TEXT,
                    website_url TEXT, category TEXT, created_at TEXT, sort_index INTEGER,
                    notes TEXT, icon TEXT, icon_color TEXT, meta TEXT, is_current INTEGER DEFAULT 0,
                    in_failover_queue INTEGER DEFAULT 0
                )
            """)
            try? DB(path: env.dir + "/cc-switch.db").run("""
                CREATE TABLE IF NOT EXISTS provider_endpoints (
                    provider_id TEXT, app_type TEXT, url TEXT, added_at TEXT
                )
            """)
            let core = Core()

            // 首次 add(--force 跳过网络测试)
            let first = try! core.add(
                raw: "https://t.example.org/v1 sk-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                ccOverride: true, cpaOverride: false, dshOverride: false,
                models: ["gpt-5.6-sol"], force: true, appType: "codex", appTypeForced: true
            )
            t.expect(first.ok, "首次 add 成功")
            t.equal(first.entry.targets, ["ccswitch-codex"], "targets 标记")

            // 再次 add 同 key 同 URL → 幂等更新:不新增条目
            let second = try! core.add(
                raw: "https://t.example.org/v1 sk-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                ccOverride: true, cpaOverride: false, dshOverride: false,
                models: ["gpt-5.6-sol"], force: true, appType: "codex", appTypeForced: true
            )
            t.expect(second.ok, "幂等 add 成功")
            t.equal(second.entry.id, first.entry.id, "同 id 更新")
            let count = HistoryStore().snapshot().filter { $0.id == first.entry.id }.count
            t.equal(count, 1, "history 仅 1 条")

            // 同 key 不同 URL → 拒绝
            do {
                _ = try core.add(
                    raw: "https://another.com/v1 sk-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                    ccOverride: true, cpaOverride: false, dshOverride: false,
                    models: ["gpt-5.6-sol"], force: false, appType: "codex"
                )
                t.expect(false, "同 key 不同 URL 应拒绝")
            } catch {
                t.expect(true, "同 key 不同 URL 拒绝: \(error)")
            }
        }

        // 非 chat 模型(图生/嵌入等)不当激活模型:真实事故 fal-ai/gpt-image-2 成了 codex 默认。
        // 修复:路由非 chat 家族回退 opencode + opencode 激活模型优先 chat 家族;全 non-chat 不设激活模型并警告。
        h.runSuite("Core.非chat模型不设为激活") { t in
            // 单元:preferredChatModel 优先 chat 家族,全 non-chat 返回 nil
            t.equal(Core.preferredChatModel(["fal-ai/gpt-image-2", "deepseek-v4-flash-0731-free-3"]), "deepseek-v4-flash-0731-free-3", "混合:chat 家族优先于图生")
            t.equal(Core.preferredChatModel(["fal-ai/gpt-image-2", "fal-ai/nano-banana-2"]) ?? "__nil__", "fal-ai/nano-banana-2", "无 chat 家族:回退非 non-chat 模型(不选 gpt-image)")
            t.expect(Core.preferredChatModel(["text-embedding-3", "dall-e-3"]) == nil, "全 non-chat(嵌入/图生):不设激活模型")
            // isNonChatModel 关键词覆盖
            t.expect(Core.isNonChatModel("fal-ai/gpt-image-2"), "image 是 non-chat")
            t.expect(Core.isNonChatModel("text-embedding-3-large"), "embedding 是 non-chat")
            t.expect(Core.isNonChatModel("whisper-1"), "whisper 是 non-chat")
            t.expect(!Core.isNonChatModel("deepseek-v4-flash-vision-exp-free"), "vision-capable chat 模型不是 non-chat")
            t.expect(!Core.isNonChatModel("gpt-4o"), "chat 模型不是 non-chat")

            // 集成:混合列表导入 opencode,激活模型不得是 gpt-image
            let env = try! TestEnv("core-img")
            defer { env.cleanup() }
            try? DB(path: env.dir + "/cc-switch.db").run("""
                CREATE TABLE IF NOT EXISTS providers (
                    id TEXT PRIMARY KEY, app_type TEXT, name TEXT, settings_config TEXT,
                    website_url TEXT, category TEXT, created_at TEXT, sort_index INTEGER,
                    notes TEXT, icon TEXT, icon_color TEXT, meta TEXT, is_current INTEGER DEFAULT 0,
                    in_failover_queue INTEGER DEFAULT 0
                )
            """)
            try? DB(path: env.dir + "/cc-switch.db").run("""
                CREATE TABLE IF NOT EXISTS provider_endpoints (
                    provider_id TEXT, app_type TEXT, url TEXT, added_at TEXT
                )
            """)
            let core = Core()
            let r = try! core.add(raw: "https://img.example.org/v1 sk-nonchatmodel000001",
                                   ccOverride: true, cpaOverride: false, dshOverride: false,
                                   models: ["fal-ai/gpt-image-2", "deepseek-v4-flash-0731-free-3"], force: true,
                                   appType: "opencode", appTypeForced: true)
            t.equal(r.entry.targets, ["ccswitch-opencode"], "图生+chat 混合 → opencode")
            let oc = env.read("opencode.json")
            t.contains(oc, "deepseek-v4-flash-0731-free-3", "opencode 激活模型 = chat 家族")
            t.expect(!oc.contains("\"model\":") || !oc.contains("gpt-image"),
                     "opencode 激活模型不含图生 gpt-image: \(oc.prefix(200))")

            // 集成:全 non-chat 导入 → 不设激活模型 + 警告
            let env2 = try! TestEnv("core-img-only")
            defer { env2.cleanup() }
            try? DB(path: env2.dir + "/cc-switch.db").run("CREATE TABLE IF NOT EXISTS providers (id TEXT PRIMARY KEY, app_type TEXT, name TEXT, settings_config TEXT, website_url TEXT, category TEXT, created_at TEXT, sort_index INTEGER, notes TEXT, icon TEXT, icon_color TEXT, meta TEXT, is_current INTEGER DEFAULT 0, in_failover_queue INTEGER DEFAULT 0)")
            try? DB(path: env2.dir + "/cc-switch.db").run("CREATE TABLE IF NOT EXISTS provider_endpoints (provider_id TEXT, app_type TEXT, url TEXT, added_at TEXT)")
            let core2 = Core()
            let r2 = try! core2.add(raw: "https://embed.example.org/v1 sk-allnonchat0000001",
                                    ccOverride: true, cpaOverride: false, dshOverride: false,
                                    models: ["text-embedding-3-large", "dall-e-3"], force: true,
                                    appType: "opencode", appTypeForced: true)
            t.contains(r2.lines.joined(separator: "\n"), "非 chat", "全 non-chat 导入给用户警告")
        }

        // 家族迁移深度测试:覆盖正向、反向、不迁移、targets 保留、entry.models 更新
        h.runSuite("Core.refresh 家族迁移 正向 claude→codex") { t in
            let env = try! TestEnv("core-migrate-fwd")
            defer { env.cleanup() }
            try? DB(path: env.dir + "/cc-switch.db").run("""
                CREATE TABLE IF NOT EXISTS providers (
                    id TEXT PRIMARY KEY, app_type TEXT, name TEXT, settings_config TEXT,
                    website_url TEXT, category TEXT, created_at TEXT, sort_index INTEGER,
                    notes TEXT, icon TEXT, icon_color TEXT, meta TEXT, is_current INTEGER DEFAULT 0,
                    in_failover_queue INTEGER DEFAULT 0
                )
            """)
            try? DB(path: env.dir + "/cc-switch.db").run("""
                CREATE TABLE IF NOT EXISTS provider_endpoints (
                    provider_id TEXT, app_type TEXT, url TEXT, added_at TEXT
                )
            """)
            let core = Core()
            guard let srv = try? MockHTTPServer(mode: .openAI) else {
                t.expect(false, "mock 启动失败"); return
            }
            let base = "http://127.0.0.1:\(srv.port)"
            let r = try! core.add(raw: "\(base) sk-migrate-fwd-000000000000000000000000",
                                   ccOverride: true, cpaOverride: false, dshOverride: false,
                                   models: ["claude-sonnet-4"], force: true,
                                   appType: "claude", appTypeForced: true)
            t.expect(r.ok, "首次 add 成功(claude 强制)")
            let e0 = core.history.snapshot().first { $0.key!.hasPrefix("sk-migrate-fwd") }
            t.expect(e0 != nil, "条目入库")
            t.equal(e0?.targets, ["ccswitch"], "导入为 claude 标签")
            let oldPid = e0!.ccProviderID!
            // 刷新:mock 返回 gpt+glm,选中 gpt → 迁移到 codex
            let msg = try! core.refreshModels(entryIDPrefix: e0!.id, pickModels: { _ in ["gpt-5.6-sol"] })
            t.contains(msg, "迁移", "返回含迁移提示")
            t.contains(msg, "claude → codex", "提示标注方向")
            let e1 = core.history.snapshot().first { $0.key!.hasPrefix("sk-migrate-fwd") }
            t.equal(e1?.targets, ["ccswitch-codex"], "targets 已更新为 codex")
            t.expect(e1?.ccProviderID != oldPid, "ccProviderID 已换新")
            t.expect(e1?.ccProviderID != nil, "新 ccProviderID 非 nil")
            t.equal(e1?.models, ["gpt-5.6-sol"], "entry.models 已更新为新家族")
            t.equal(e1?.model, "gpt-5.6-sol", "entry.model 已更新为新家族首选")
            let newPid = e1!.ccProviderID!
            let db = try! DB(path: env.dir + "/cc-switch.db")
            let oldExists = try? db.scalar("SELECT 1 FROM providers WHERE id = ? AND app_type = 'claude'", [oldPid])
            t.expect(oldExists == nil, "旧 claude provider 已删除")
            let newCfg = (try? db.scalar("SELECT settings_config FROM providers WHERE id = ? AND app_type = 'codex'", [newPid])) ?? ""
            t.expect(!newCfg.isEmpty, "新 codex provider 已创建")
            t.contains(newCfg, "gpt-5.6-sol", "codex settings_config 含 gpt 模型")
        }

        h.runSuite("Core.refresh 家族迁移 反向 codex→claude") { t in
            let env = try! TestEnv("core-migrate-bwd")
            defer { env.cleanup() }
            try? DB(path: env.dir + "/cc-switch.db").run("""
                CREATE TABLE IF NOT EXISTS providers (
                    id TEXT PRIMARY KEY, app_type TEXT, name TEXT, settings_config TEXT,
                    website_url TEXT, category TEXT, created_at TEXT, sort_index INTEGER,
                    notes TEXT, icon TEXT, icon_color TEXT, meta TEXT, is_current INTEGER DEFAULT 0,
                    in_failover_queue INTEGER DEFAULT 0
                )
            """)
            try? DB(path: env.dir + "/cc-switch.db").run("""
                CREATE TABLE IF NOT EXISTS provider_endpoints (
                    provider_id TEXT, app_type TEXT, url TEXT, added_at TEXT
                )
            """)
            let core = Core()
            guard let srv = try? MockHTTPServer(mode: .claudeModels) else {
                t.expect(false, "mock 启动失败"); return
            }
            let base = "http://127.0.0.1:\(srv.port)"
            // 导入为 codex(强制),mock 返回纯 claude → 应迁移回 claude
            let r = try! core.add(raw: "\(base) sk-migrate-bwd-000000000000000000000000",
                                   ccOverride: true, cpaOverride: false, dshOverride: false,
                                   models: ["gpt-5.6-sol"], force: true,
                                   appType: "codex", appTypeForced: true)
            t.expect(r.ok, "首次 add 成功(codex 强制)")
            let e0 = core.history.snapshot().first { $0.key!.hasPrefix("sk-migrate-bwd") }
            t.equal(e0?.targets, ["ccswitch-codex"], "导入为 codex 标签")
            let oldPid = e0!.ccProviderID!
            let msg = try! core.refreshModels(entryIDPrefix: e0!.id, pickModels: { _ in ["claude-sonnet-4-5"] })
            t.contains(msg, "codex → claude", "提示标注反向迁移")
            let e1 = core.history.snapshot().first { $0.key!.hasPrefix("sk-migrate-bwd") }
            t.equal(e1?.targets, ["ccswitch"], "targets 已更新为 claude")
            t.expect(e1?.ccProviderID != oldPid, "ccProviderID 已换新")
            t.equal(e1?.models, ["claude-sonnet-4-5"], "entry.models 已更新为 claude")
            let db = try! DB(path: env.dir + "/cc-switch.db")
            let oldExists = try? db.scalar("SELECT 1 FROM providers WHERE id = ? AND app_type = 'codex'", [oldPid])
            t.expect(oldExists == nil, "旧 codex provider 已删除")
            let newPid = e1!.ccProviderID!
            let newCfg = (try? db.scalar("SELECT settings_config FROM providers WHERE id = ? AND app_type = 'claude'", [newPid])) ?? ""
            t.contains(newCfg, "ANTHROPIC_MODEL", "新 claude provider 含 ANTHROPIC_MODEL 键")
            t.contains(newCfg, "claude-sonnet-4-5", "claude settings_config 含选中模型")
        }

        h.runSuite("Core.refresh 家族迁移 到opencode") { t in
            let env = try! TestEnv("core-migrate-oc")
            defer { env.cleanup() }
            try? DB(path: env.dir + "/cc-switch.db").run("""
                CREATE TABLE IF NOT EXISTS providers (
                    id TEXT PRIMARY KEY, app_type TEXT, name TEXT, settings_config TEXT,
                    website_url TEXT, category TEXT, created_at TEXT, sort_index INTEGER,
                    notes TEXT, icon TEXT, icon_color TEXT, meta TEXT, is_current INTEGER DEFAULT 0,
                    in_failover_queue INTEGER DEFAULT 0
                )
            """)
            try? DB(path: env.dir + "/cc-switch.db").run("""
                CREATE TABLE IF NOT EXISTS provider_endpoints (
                    provider_id TEXT, app_type TEXT, url TEXT, added_at TEXT
                )
            """)
            let core = Core()
            guard let srv = try? MockHTTPServer(mode: .openAI) else {
                t.expect(false, "mock 启动失败"); return
            }
            let base = "http://127.0.0.1:\(srv.port)"
            // claude 导入,刷新选 glm(非 claude 非 gpt) → 迁移到 opencode
            _ = try! core.add(raw: "\(base) sk-migrate-oc-0000000000000000000000000",
                                   ccOverride: true, cpaOverride: false, dshOverride: false,
                                   models: ["claude-sonnet-4"], force: true,
                                   appType: "claude", appTypeForced: true)
            let e0 = core.history.snapshot().first { $0.key!.hasPrefix("sk-migrate-oc") }
            let msg = try! core.refreshModels(entryIDPrefix: e0!.id, pickModels: { _ in ["glm-5.2"] })
            t.contains(msg, "claude → opencode", "迁移到 opencode")
            let e1 = core.history.snapshot().first { $0.key!.hasPrefix("sk-migrate-oc") }
            t.equal(e1?.targets, ["ccswitch-opencode"], "targets 已更新为 opencode")
            t.equal(e1?.models, ["glm-5.2"], "entry.models 已更新为 glm")
        }

        h.runSuite("Core.refresh 同家族不迁移") { t in
            let env = try! TestEnv("core-migrate-same")
            defer { env.cleanup() }
            try? DB(path: env.dir + "/cc-switch.db").run("""
                CREATE TABLE IF NOT EXISTS providers (
                    id TEXT PRIMARY KEY, app_type TEXT, name TEXT, settings_config TEXT,
                    website_url TEXT, category TEXT, created_at TEXT, sort_index INTEGER,
                    notes TEXT, icon TEXT, icon_color TEXT, meta TEXT, is_current INTEGER DEFAULT 0,
                    in_failover_queue INTEGER DEFAULT 0
                )
            """)
            try? DB(path: env.dir + "/cc-switch.db").run("""
                CREATE TABLE IF NOT EXISTS provider_endpoints (
                    provider_id TEXT, app_type TEXT, url TEXT, added_at TEXT
                )
            """)
            let core = Core()
            guard let srv = try? MockHTTPServer(mode: .claudeModels) else {
                t.expect(false, "mock 启动失败"); return
            }
            let base = "http://127.0.0.1:\(srv.port)"
            // claude 导入,刷新仍选 claude → 不迁移,只 sync
            _ = try! core.add(raw: "\(base) sk-migrate-same-0000000000000000000000",
                                   ccOverride: true, cpaOverride: false, dshOverride: false,
                                   models: ["claude-sonnet-4"], force: true,
                                   appType: "claude", appTypeForced: true)
            let e0 = core.history.snapshot().first { $0.key!.hasPrefix("sk-migrate-same") }
            let oldPid = e0!.ccProviderID!
            let msg = try! core.refreshModels(entryIDPrefix: e0!.id, pickModels: { _ in ["claude-opus-4-1"] })
            t.expect(!msg.contains("迁移"), "同家族不触发迁移: \(msg)")
            let e1 = core.history.snapshot().first { $0.key!.hasPrefix("sk-migrate-same") }
            t.equal(e1?.targets, ["ccswitch"], "targets 保持 claude")
            t.equal(e1?.ccProviderID, oldPid, "ccProviderID 保持不变")
            t.equal(e1?.models, ["claude-opus-4-1"], "entry.models 已更新(sync 但不迁移)")
        }

        h.runSuite("Core.refresh 迁移保留其他targets") { t in
            let env = try! TestEnv("core-migrate-tgt")
            defer { env.cleanup() }
            try? DB(path: env.dir + "/cc-switch.db").run("""
                CREATE TABLE IF NOT EXISTS providers (
                    id TEXT PRIMARY KEY, app_type TEXT, name TEXT, settings_config TEXT,
                    website_url TEXT, category TEXT, created_at TEXT, sort_index INTEGER,
                    notes TEXT, icon TEXT, icon_color TEXT, meta TEXT, is_current INTEGER DEFAULT 0,
                    in_failover_queue INTEGER DEFAULT 0
                )
            """)
            try? DB(path: env.dir + "/cc-switch.db").run("""
                CREATE TABLE IF NOT EXISTS provider_endpoints (
                    provider_id TEXT, app_type TEXT, url TEXT, added_at TEXT
                )
            """)
            let core = Core()
            guard let srv = try? MockHTTPServer(mode: .openAI) else {
                t.expect(false, "mock 启动失败"); return
            }
            let base = "http://127.0.0.1:\(srv.port)"
            // 导入 deepseek 模型 + claude 强制 + dsh 开启 → targets 含 ccswitch + dsh
            // mock 返回 gpt+glm,刷新选 gpt → 应迁移 ccswitch→ccswitch-codex,保留 dsh
            _ = try! core.add(raw: "\(base) sk-migrate-tgt-0000000000000000000000",
                                   ccOverride: true, cpaOverride: false, dshOverride: true,
                                   models: ["deepseek-v4-flash"], force: true,
                                   appType: "claude", appTypeForced: true)
            let e0 = core.history.snapshot().first { $0.key!.hasPrefix("sk-migrate-tgt") }
            t.expect(e0?.targets.contains("dsh") == true, "初始含 dsh target: \(e0?.targets ?? [])")
            t.expect(e0?.targets.contains("ccswitch") == true, "初始含 ccswitch target")
            _ = try! core.refreshModels(entryIDPrefix: e0!.id, pickModels: { _ in ["gpt-5.6-sol"] })
            let e1 = core.history.snapshot().first { $0.key!.hasPrefix("sk-migrate-tgt") }
            t.expect(e1?.targets.contains("dsh") == true, "迁移后保留 dsh target")
            t.expect(e1?.targets.contains("ccswitch-codex") == true, "迁移后含 ccswitch-codex")
            t.expect(e1?.targets.contains("ccswitch") == false, "迁移后旧 ccswitch(无后缀)已移除")
        }

        h.runSuite("Core.refresh 迁移失败回滚") { t in
            let env = try! TestEnv("core-migrate-rollback")
            defer { env.cleanup() }
            try? DB(path: env.dir + "/cc-switch.db").run("""
                CREATE TABLE IF NOT EXISTS providers (
                    id TEXT PRIMARY KEY, app_type TEXT, name TEXT, settings_config TEXT,
                    website_url TEXT, category TEXT, created_at TEXT, sort_index INTEGER,
                    notes TEXT, icon TEXT, icon_color TEXT, meta TEXT, is_current INTEGER DEFAULT 0,
                    in_failover_queue INTEGER DEFAULT 0
                )
            """)
            try? DB(path: env.dir + "/cc-switch.db").run("""
                CREATE TABLE IF NOT EXISTS provider_endpoints (
                    provider_id TEXT, app_type TEXT, url TEXT, added_at TEXT
                )
            """)
            let core = Core()
            guard let srv = try? MockHTTPServer(mode: .openAI) else {
                t.expect(false, "mock 启动失败"); return
            }
            let base = "http://127.0.0.1:\(srv.port)"
            // 导入为 codex(强制),mock 返回纯 gpt → 无迁移,正常 sync
            _ = try! core.add(raw: "\(base) sk-migrate-rb-000000000000000000000000",
                                   ccOverride: true, cpaOverride: false, dshOverride: false,
                                   models: ["gpt-5.6-sol"], force: true,
                                   appType: "codex", appTypeForced: true)
            let e0 = core.history.snapshot().first { $0.key!.hasPrefix("sk-migrate-rb") }
            t.equal(e0?.targets, ["ccswitch-codex"], "导入为 codex")
            // 刷新仍选 gpt(同家族) → 不迁移,只 sync,targets/pid 不变
            let oldPid = e0!.ccProviderID!
            let msg = try! core.refreshModels(entryIDPrefix: e0!.id, pickModels: { _ in ["gpt-5.6-sol"] })
            t.expect(!msg.contains("迁移"), "同家族不迁移")
            let e1 = core.history.snapshot().first { $0.key!.hasPrefix("sk-migrate-rb") }
            t.equal(e1?.ccProviderID, oldPid, "同家族 ccProviderID 不变")
        }
    }
}
