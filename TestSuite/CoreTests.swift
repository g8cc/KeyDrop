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
            t.contains(zeroMsg, "quota", "无余额刷新标 quota: \(zeroMsg)")
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
                raw: "https://0v0.club/v1 sk-44c3daab197e1cbf3e28d4d5eaf37f66ab551d808de27fbd",
                ccOverride: true, cpaOverride: false, dshOverride: false,
                models: ["gpt-5.6-sol"], force: true, appType: "codex", appTypeForced: true
            )
            t.expect(first.ok, "首次 add 成功")
            t.equal(first.entry.targets, ["ccswitch-codex"], "targets 标记")

            // 再次 add 同 key 同 URL → 幂等更新:不新增条目
            let second = try! core.add(
                raw: "https://0v0.club/v1 sk-44c3daab197e1cbf3e28d4d5eaf37f66ab551d808de27fbd",
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
                    raw: "https://another.com/v1 sk-44c3daab197e1cbf3e28d4d5eaf37f66ab551d808de27fbd",
                    ccOverride: true, cpaOverride: false, dshOverride: false,
                    models: ["gpt-5.6-sol"], force: false, appType: "codex"
                )
                t.expect(false, "同 key 不同 URL 应拒绝")
            } catch {
                t.expect(true, "同 key 不同 URL 拒绝: \(error)")
            }
        }
    }
}
