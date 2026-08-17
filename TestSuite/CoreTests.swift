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
