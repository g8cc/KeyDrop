import Foundation
import KeyDropCore

/// 2026-08 深度排查修复的回归测试
enum RegressionTests {
    static func run(_ h: Harness) {
        h.runSuite("Regression.codex 回读校验") { t in
            let env = try! TestEnv("reg-codex")
            defer { env.cleanup() }
            try! CCSwitchWriterTests.createSchema(env)
            let w = CCSwitchWriter()

            // URL 不带 /v1:写入补 /v1,回读校验必须用规范化值,不得误报「回读不一致」
            var p = ParsedKey()
            p.key = "sk-abcdef123456"
            p.url = "https://gwy.example.org"
            let r1 = try! w.add(p, appType: "codex", models: ["gpt-5.6-sol"], proxy: nil)
            t.expect(r1.warnings.first { $0.contains("回读不一致") } == nil,
                     "无 /v1 URL 不误报回读失败: \(r1.warnings)")
            t.contains(env.read("codex.toml"), "base_url = \"https://gwy.example.org/v1\"", "base_url 补 /v1")

            // 模型名含引号/反斜杠:TOML 必须转义且校验通过(用 gpt 系名,激活模型行才会写入)
            var p2 = ParsedKey()
            p2.key = "sk-abcdef123456"
            p2.url = "https://gwy.example.org"
            let weird = "gpt-4\"quote\\slash"
            let r2 = try! w.add(p2, appType: "codex", models: [weird], proxy: nil)
            t.expect(r2.warnings.first { $0.contains("回读不一致") } == nil,
                     "特殊字符模型不误报回读失败: \(r2.warnings)")
            let cfg = env.read("codex.toml")
            t.contains(cfg, "model = \"gpt-4\\\"quote\\\\slash\"", "模型名 TOML 转义写入")
            t.contains(cfg, "experimental_bearer_token = \"sk-abcdef123456\"", "token 写入")
        }

        h.runSuite("Regression.providerExists 合并") { t in
            let env = try! TestEnv("reg-pexists")
            defer { env.cleanup() }
            try! CCSwitchWriterTests.createSchema(env)
            let w = CCSwitchWriter()
            var p = ParsedKey()
            p.key = "sk-abcdef123456"
            p.url = "https://gwy.example.org/v1"
            let r = try! w.add(p, appType: "opencode", models: ["glm-5.2"], proxy: nil)
            // 两个历史重载调用形式都必须命中同一个查询
            t.expect(w.providerExists(id: r.providerID, appType: "opencode"), "带标签形式存在")
            t.expect(w.providerExists(r.providerID, appType: "opencode"), "无标签形式存在(委托同一实现)")
            t.expect(!w.providerExists(id: "nonexistent", appType: "opencode"), "不存在返回 false")
        }

        h.runSuite("Regression.repair 补 endpoint") { t in
            let env = try! TestEnv("reg-repair")
            defer { env.cleanup() }
            try! CCSwitchWriterTests.createSchema(env)
            let w = CCSwitchWriter()
            let pid = "repair9-1111-2222-3333-444444444444"
            let ok = try! w.repairMissingProvider(entry: HistoryEntry(
                id: pid, ts: 1, raw: "x", format: "test",
                name: "repair", url: "https://gwy.example.org/v1", model: nil, models: ["gpt-5.6-sol"],
                key: "sk-abcdef123456", keyMasked: "sk-…", targets: ["ccswitch-codex"],
                ccProviderID: pid, ccRenamedFrom: nil, ccRenamedTo: nil,
                cpaConfigPath: nil, status: "active", note: nil,
                health: nil, healthDetail: nil, healthAt: nil
            ))
            t.expect(ok, "repair 成功")
            let db = try! DB(path: env.dir + "/cc-switch.db")
            let cnt = try! db.scalar(
                "SELECT count(*) FROM provider_endpoints WHERE provider_id=?", [pid]
            )
            t.equal(cnt, "1", "repair 写入 endpoint 行(否则 cc-switch 无 URL 且去重失效)")
        }

        h.runSuite("Regression.history 并发保存") { t in
            let env = try! TestEnv("reg-conc")
            defer { env.cleanup() }
            let hist = HistoryStore()
            for i in 0..<24 {
                try! hist.append(HistoryTests.entry(
                    String(format: "conc%04d-1111-2222-3333-444444444444", i), ts: TimeInterval(1000 + i)
                ))
            }
            let ids = hist.snapshot().map(\.id)
            t.equal(ids.count, 24, "初始 24 条")
            // 模拟健康扫描:多线程并发 update+save,任何一次都不能丢
            let group = DispatchGroup()
            let queue = DispatchQueue.global(qos: .userInitiated)
            for (idx, id) in ids.enumerated() {
                group.enter()
                queue.async {
                    defer { group.leave() }
                    guard var e = hist.find(idPrefix: String(id.prefix(12))) else { return }
                    e.health = "dead-\(idx)"
                    try? hist.update(e)
                }
            }
            group.wait()
            let after = hist.snapshot()
            t.equal(after.count, 24, "并发后条目数不变")
            let lost = after.filter { !($0.health ?? "").hasPrefix("dead-") }
            t.equal(lost.count, 0, "并发 update 无丢失(修复前锁外写文件会互相覆盖): \(lost.map { String($0.id.prefix(4)) })")
        }

        h.runSuite("Regression.DSH YAML 引用") { t in
            t.equal(DSHWriter.yamlScalar("https://x.com/v1"), "https://x.com/v1", "普通 URL 裸写")
            t.equal(DSHWriter.yamlScalar("deepseek-v4-flash"), "deepseek-v4-flash", "普通模型裸写")
            t.equal(DSHWriter.yamlScalar("model with space"), "\"model with space\"", "含空格加引号")
            t.equal(DSHWriter.yamlScalar("a\"b"), "\"a\\\"b\"", "引号转义")
            t.equal(DSHWriter.yamlScalar("-leading"), "\"-leading\"", "前导减号加引号")
            t.equal(DSHWriter.yamlScalar("https://x.com:"), "\"https://x.com:\"", "尾冒号加引号")
            // 写入含特殊字符模型不破坏 YAML 结构
            let env = try! TestEnv("reg-dsh")
            defer { env.cleanup() }
            _ = try! DSHWriter.add(
                providerID: "ff00aa11-1111-2222-3333-444455556666",
                key: "sk-reg-dsh-key-000000000",
                url: "https://api.deepseek.com",
                models: ["deepseek v4 flash", "deepseek-v4-pro"]
            )
            let out = env.read("dsh.yaml")
            t.contains(out, "- id: \"deepseek v4 flash\"", "特殊模型名带引号")
            t.contains(out, "- id: deepseek-v4-pro", "普通模型名裸写")
            t.contains(out, "baseURL: https://api.deepseek.com/v1", "baseURL 裸写不变")
        }

        h.runSuite("Regression.代理 scheme 计数") { t in
            // socks5 在 isProxyURL 认可但无法解析:clashOnly 判定改用可解析行,二者必须区分
            t.expect(Parser.isProxyURL("socks5://127.0.0.1:1080"), "isProxyURL 认可 socks5")
            t.expect(Parser.parseProxyURL("socks5://127.0.0.1:1080") == nil, "socks5 不可解析")
            t.expect(Parser.parseProxyURL("vless://uuid@host:443#name") != nil, "vless 可解析")
            t.equal(Core.parseClashProxies(raw: "socks5://127.0.0.1:1080").count, 0, "socks5 不产出节点")
        }

        h.runSuite("Regression.标签词不当名称") { t in
            // 单行 token 化后「模型」独立成 token,修复前被 isNameLike 误判为条目名称
            let p = try! Parser.parseWithFallback("https://api-relay-test.example.com/v1 sk-labelcheck11111111 模型 gpt-5.6-sol")
            t.equal(p.model, "gpt-5.6-sol", "模型提取正确")
            t.expect(p.name != "模型", "标签词「模型」不作为名称: \(p.name ?? "nil")")
            t.expect(p.name == nil || p.name == "api-relay-test.example.com", "名称为空或回退 host: \(p.name ?? "nil")")
        }

        // ---- 模型家族错配(gpt 写进 Claude Code 真实事故) ----

        h.runSuite("Regression.claude 不吃异家族模型") { t in
            let env = try! TestEnv("reg-family-claude")
            defer { env.cleanup() }
            try! CCSwitchWriterTests.createSchema(env)
            let w = CCSwitchWriter()

            // 场景 A(add):混合列表被路由到 claude(claude 优先),激活模型必须是 claude 系
            var p = ParsedKey()
            p.key = "sk-familytest11111111"
            p.url = "https://gwy.example.org/v1"
            _ = try! w.add(p, appType: "claude", models: ["gpt-5.6-sol", "claude-sonnet-4-5"], proxy: nil)
            let claude = (try? DB(path: env.dir + "/cc-switch.db").scalar("SELECT settings_config FROM providers WHERE app_type='claude' LIMIT 1")) ?? "{}"
            t.contains(claude, "claude-sonnet-4-5", "ANTHROPIC_MODEL 为 claude 系")
            t.expect(!claude.contains("ANTHROPIC_MODEL\":\"gpt"), "gpt 不得写入 claude 配置: \(claude.prefix(200))")

            // 场景 C 对称(codex):混合列表路由到 codex,激活模型必须是 gpt 系
            let env2 = try! TestEnv("reg-family-codex")
            defer { env2.cleanup() }
            try! CCSwitchWriterTests.createSchema(env2)
            var p2 = ParsedKey()
            p2.key = "sk-familytest11111111"
            p2.url = "https://gwy.example.org/v1"
            _ = try! w.add(p2, appType: "codex", models: ["claude-sonnet-4-5", "gpt-5.6-sol"], proxy: nil)
            let codex = env2.read("codex.toml")
            t.contains(codex, "model = \"gpt-5.6-sol\"", "codex 激活模型为 gpt 系")
            t.expect(!codex.contains("model = \"claude"), "claude 模型不得成为 codex 激活模型")
        }

        h.runSuite("Regression.refresh 不把 gpt 刷进 claude") { t in
            let env = try! TestEnv("reg-family-refresh")
            defer { env.cleanup() }
            try! CCSwitchWriterTests.createSchema(env)
            let core = Core()
            guard let srv = try? MockHTTPServer(mode: .openAI) else {
                t.expect(false, "mock 启动失败")
                return
            }
            let base = "http://127.0.0.1:\(srv.port)"
            // claude 条目:激活模型 claude-sonnet-4
            _ = try! core.add(raw: "\(base) sk-refreshclaude111111", ccOverride: true, cpaOverride: false, dshOverride: false,
                              models: ["claude-sonnet-4"], force: true, appType: "claude", appTypeForced: true)
            let e0 = core.history.snapshot().first { $0.key == "sk-refreshclaude111111" }
            t.expect(e0 != nil, "条目入库")
            let dbPath = env.dir + "/cc-switch.db"
            let oldPid = e0!.ccProviderID!
            let claudeBefore = (try? DB(path: dbPath).scalar("SELECT settings_config FROM providers WHERE id=?", [oldPid])) ?? "{}"
            t.contains(claudeBefore, "ANTHROPIC_MODEL", "首次写入含模型键")
            t.expect(!claudeBefore.contains("gpt-5.6-sol"), "初始无 gpt")
            // 网关模型列表变为 gpt+glm(无 claude)——真实网关 /models 全量返回的常态。
            // 修复后:家族全变 → 迁移到 codex provider,旧 claude provider 删除,
            // 不再把 gpt 留在 claude 配置(原事故路径),也不留 claude 残壳无模型键。
            let refreshMsg = try! core.refreshModels(entryIDPrefix: e0!.id)
            t.contains(refreshMsg, "迁移", "refresh 返回含迁移提示")
            let e1 = core.history.snapshot().first { $0.key == "sk-refreshclaude111111" }
            t.equal(e1?.targets, ["ccswitch-codex"], "targets 已迁移到 codex")
            // 旧 claude provider 应已删除
            let claudeAfter = (try? DB(path: dbPath).scalar("SELECT settings_config FROM providers WHERE id=? AND app_type='claude'", [oldPid])) ?? "{}"
            t.expect(claudeAfter == "{}" || claudeAfter.isEmpty, "旧 claude provider 已删除,无残壳")
            // 新 codex provider 应存在且含 gpt
            let newPid = e1!.ccProviderID!
            t.expect(newPid != oldPid, "ccProviderID 已更新")
            let codexCfg = (try? DB(path: dbPath).scalar("SELECT settings_config FROM providers WHERE id=? AND app_type='codex'", [newPid])) ?? "{}"
            t.contains(codexCfg, "gpt-5.6-sol", "gpt 已写入新 codex provider")
        }

        h.runSuite("Regression.cc写入失败恢复旧标签") { t in
            // 需要 cc-switch「未运行」:本用例靠损坏 claude.json 触发 live 写入失败来验证旧标签恢复;
            // 修复后 cc-switch 运行时不写 live,损坏文件不会触发失败 → 用例失去意义。强制直连模式。
            setenv("KEYDROP_FAKE_CC_RUNNING", "0", 1)
            defer { setenv("KEYDROP_FAKE_CC_RUNNING", "1", 1) }
            let env = try! TestEnv("reg-orphantag")
            defer { env.cleanup() }
            try! CCSwitchWriterTests.createSchema(env)
            let core = Core()
            let raw = "https://gwy.example.org/v1 sk-orphantag111111111"

            // 首次导入成功:provider 入库,条目带 ccswitch 标签
            let first = try! core.add(raw: raw, ccOverride: true, cpaOverride: false, dshOverride: false,
                                      models: ["claude-sonnet-4"], force: true, appType: "claude", appTypeForced: true)
            t.expect(first.ok, "首次导入成功")
            let pid = first.entry.ccProviderID!
            t.equal(first.entry.targets, ["ccswitch"], "首次 targets")

            // 损坏 claude.json → 幂等路径的 syncModelsAfterRefresh 必然抛错
            try! "{{{".write(toFile: env.dir + "/claude.json", atomically: true, encoding: .utf8)
            // CPA 可写(让 anyOK=true、条目得以落盘)
            env.write("cpa-config.yaml", "port: 18317\n")
            let second = try! core.add(raw: raw, ccOverride: true, cpaOverride: true, dshOverride: false,
                                       force: true, appType: "claude", appTypeForced: true)
            t.contains(second.lines.first { $0.contains("cc-switch 失败") } ?? "", "失败",
                       "cc 写入确实失败: \(second.lines)")
            t.expect(second.ok, "CPA 成功 → 条目仍落盘")
            let e1 = core.history.find(idPrefix: first.entry.id)!
            // 修复点:cc 写入失败时旧 provider 仍在,旧标签必须保留,
            // 否则 delete/reconcile 不再认领 → cc-switch 孤儿 provider
            t.contains(e1.targets.joined(separator: ","), "ccswitch",
                       "cc 失败后旧 ccswitch 标签恢复: \(e1.targets)")
            t.equal(e1.ccProviderID, pid, "provider 指向保留")
            t.contains(e1.targets.joined(separator: ","), "cpa", "新写入的 cpa 标签在")
        }

        // ---- 不变量矩阵:目标 app × 模型列表形态(防家族错配复发)----
        // 任何写入层改动若破坏「claude 只吃 claude 系 / codex 只吃 gpt 系」,
        // 这个矩阵必有断言变红
        h.runSuite("Regression.写入不变量矩阵") { t in
            func freshEnv(_ name: String) -> TestEnv {
                let e = try! TestEnv(name)
                try! CCSwitchWriterTests.createSchema(e)
                return e
            }
            func parsed(_ key: String) -> ParsedKey {
                var p = ParsedKey()
                p.key = key
                p.url = "https://gwy.example.org/v1"
                return p
            }
            let w = CCSwitchWriter()

            // claude × 混合 → 激活模型取 claude 系
            let e1 = freshEnv("inv-claude-mixed")
            defer { e1.cleanup() }
            _ = try! w.add(parsed("sk-inv000000000001"), appType: "claude",
                           models: ["gpt-5.6-sol", "claude-sonnet-4-5", "glm-5.2"], proxy: nil)
            let c1 = (try? DB(path: e1.dir + "/cc-switch.db").scalar("SELECT settings_config FROM providers WHERE app_type='claude' LIMIT 1")) ?? "{}"
            t.contains(c1, "claude-sonnet-4-5", "[claude×混合] 激活模型 = claude 系")
            t.expect(!c1.contains("ANTHROPIC_MODEL\":\"gpt"), "[claude×混合] 无 gpt 模型键")

            // claude × 纯异家族 → 完全省略模型键(回退 Claude Code 默认,结构上不可能错配)
            let e2 = freshEnv("inv-claude-foreign")
            defer { e2.cleanup() }
            _ = try! w.add(parsed("sk-inv000000000002"), appType: "claude",
                           models: ["gpt-5.6-sol", "glm-5.2"], proxy: nil)
            let c2 = (try? DB(path: e2.dir + "/cc-switch.db").scalar("SELECT settings_config FROM providers WHERE app_type='claude' LIMIT 1")) ?? "{}"
            t.expect(!c2.contains("ANTHROPIC_MODEL"), "[claude×纯异家族] 无任何模型键: \(c2.prefix(160))")
            t.contains(c2, "ANTHROPIC_AUTH_TOKEN", "[claude×纯异家族] token 保留")

            // claude × 纯 claude → 正常写入
            let e3 = freshEnv("inv-claude-pure")
            defer { e3.cleanup() }
            _ = try! w.add(parsed("sk-inv000000000003"), appType: "claude",
                           models: ["claude-opus-4-1"], proxy: nil)
            let c3 = (try? DB(path: e3.dir + "/cc-switch.db").scalar("SELECT settings_config FROM providers WHERE app_type='claude' LIMIT 1")) ?? "{}"
            t.contains(c3, "claude-opus-4-1", "[claude×纯] 激活模型写入")

            // codex × 混合 → 激活模型取 gpt 系
            let e4 = freshEnv("inv-codex-mixed")
            defer { e4.cleanup() }
            _ = try! w.add(parsed("sk-inv000000000004"), appType: "codex",
                           models: ["claude-sonnet-4-5", "gpt-5.6-sol"], proxy: nil)
            let c4 = e4.read("codex.toml")
            t.contains(c4, "model = \"gpt-5.6-sol\"", "[codex×混合] 激活模型 = gpt 系")
            t.expect(!c4.contains("model = \"claude"), "[codex×混合] 无 claude 激活模型")

            // codex × 纯异家族 → 全新模板不写 model 行(codex 内置默认)
            let e5 = freshEnv("inv-codex-foreign")
            defer { e5.cleanup() }
            _ = try! w.add(parsed("sk-inv000000000005"), appType: "codex",
                           models: ["claude-sonnet-4-5"], proxy: nil)
            let c5 = e5.read("codex.toml")
            t.expect(!c5.contains("model = \""), "[codex×纯异家族] 无 model 行: \(c5.prefix(160))")
            t.contains(c5, "base_url = \"https://gwy.example.org/v1\"", "[codex×纯异家族] base_url 正常")

            // opencode × 多家族 → 全部模型都在(多家族桶,无激活模型约束)
            let e6 = freshEnv("inv-opencode-mixed")
            defer { e6.cleanup() }
            _ = try! w.add(parsed("sk-inv000000000006"), appType: "opencode",
                           models: ["glm-5.2", "deepseek-v4-pro", "kimi-k3"], proxy: nil)
            let c6 = e6.read("opencode.json")
            t.contains(c6, "glm-5.2", "[opencode×混合] 模型 1 在")
            t.contains(c6, "deepseek-v4-pro", "[opencode×混合] 模型 2 在")
            t.contains(c6, "kimi-k3", "[opencode×混合] 模型 3 在")
        }

        // ---- 账本闭环:成功导入的每个 tag 都必须可被 delete 认领并清理干净 ----
        // 这是「entry.targets ↔ 外部产物」不变量的全生命周期验证:
        // add(cc+cpa+dsh 全开) → 三方产物存在 → delete → 三方产物消失、条目闭环
        h.runSuite("Regression.账本闭环 add→delete") { t in
            let env = try! TestEnv("inv-ledger")
            defer { env.cleanup() }
            try! CCSwitchWriterTests.createSchema(env)
            env.write("cpa-config.yaml", "port: 18317\n")
            let core = Core()
            let outcome = try! core.add(
                raw: "https://gwy.example.org/v1 sk-ledgerclosure111111",
                ccOverride: true, cpaOverride: true, dshOverride: true,
                models: ["deepseek-v4-pro"], force: true,
                appType: "opencode", appTypeForced: true
            )
            t.expect(outcome.ok, "三目标导入成功: \(outcome.lines)")
            let e = outcome.entry
            let pid = e.ccProviderID ?? ""
            t.expect(pid.isEmpty == false, "有 provider 指向")
            let w = CCSwitchWriter()
            // add 后:每个 tag 对应真实产物
            t.expect(w.providerExists(id: pid, appType: "opencode"), "[add 后] cc provider 存在")
            t.contains(env.read("dsh.yaml"), DSHWriter.routeKey(providerID: e.id), "[add 后] dsh route 存在")
            t.contains(env.read("dsh-creds.yaml"), DSHWriter.envName(providerID: e.id), "[add 后] dsh 凭证存在")
            t.contains(env.read("cpa-config.yaml"), "sk-ledgerclosure111111", "[add 后] cpa key 存在")
            t.contains(env.read("opencode.json"), pid, "[add 后] opencode.json 条目存在")
            // delete 后:所有产物清理、条目闭环
            _ = try! core.delete(entryIDPrefix: e.id)
            t.expect(!w.providerExists(id: pid, appType: "opencode"), "[delete 后] cc provider 已删")
            t.expect(!env.read("dsh.yaml").contains(DSHWriter.routeKey(providerID: e.id)), "[delete 后] dsh route 已删")
            t.expect(!env.read("dsh-creds.yaml").contains(DSHWriter.envName(providerID: e.id)), "[delete 后] dsh 凭证已删")
            t.expect(!env.read("cpa-config.yaml").contains("sk-ledgerclosure111111"), "[delete 后] cpa key 已删")
            t.expect(!env.read("opencode.json").contains(pid), "[delete 后] opencode.json 已清")
            let after = core.history.find(idPrefix: e.id)!
            t.equal(after.status, "deleted", "[delete 后] 条目闭环")
            t.equal(after.targets.count, 0, "[delete 后] 无残留 tag")
        }

        h.runSuite("Regression.appendDedupByKey 跨进程查重") { t in
            let env = try! TestEnv("reg-dedup")
            defer { env.cleanup() }
            // 注意:同 key 才构成重复。entry() 助手的 key 随 id 变化,
            // 这里手动构造 id 不同但 key 相同的条目
            func e(_ id: String, ts: TimeInterval, key: String) -> HistoryEntry {
                var x = HistoryTests.entry(id, ts: ts)
                x.key = key
                return x
            }
            // 实例 A 插入条目并落盘;实例 B(模拟另一进程,内存不含它)
            // 再用不同 id 插入同 key:必须命中文件里的已有条目而不是建双条
            let a = HistoryStore()
            _ = try! a.appendDedupByKey(e("dedup0001-1111-2222-3333-444444444444", ts: 100, key: "sk-same-key-0001"))
            let b = HistoryStore()
            let dup = try! b.appendDedupByKey(e("dedup0002-1111-2222-3333-444444444444", ts: 200, key: "sk-same-key-0001"))
            t.expect(dup?.id.hasPrefix("dedup0001") == true, "同 key 命中另一进程的条目并返回它")
            t.equal(HistoryStore().snapshot().count, 1, "历史中不产生双条")
            // 不同 key 正常插入
            let ok = try! b.appendDedupByKey(e("dedup0003-1111-2222-3333-444444444444", ts: 300, key: "sk-same-key-0002"))
            t.expect(ok == nil, "不同 key 返回 nil 且插入")
            t.equal(HistoryStore().snapshot().count, 2, "不同 key 各建一条")
            // 非 active 条目不算重复
            var dead = HistoryTests.entry("dedup0001-1111-2222-3333-444444444444", ts: 100)
            dead.key = "sk-same-key-0001"
            dead.status = "deleted"
            try! b.update(dead)
            let revived = try! b.appendDedupByKey(e("dedup0004-1111-2222-3333-444444444444", ts: 400, key: "sk-same-key-0001"))
            t.expect(revived == nil, "同 key 但旧条目已删除:允许重建")
        }

        h.runSuite("Regression.clashFile 存取") { t in
            let env = try! TestEnv("reg-clashfile")
            defer { env.cleanup() }
            let hist = HistoryStore()
            var e = HistoryTests.entry("clash0aa1-1111-2222-3333-444444444444", ts: 100)
            e.clashFile = "KeyDrop-20250101-000000-abcd.yaml"
            try! hist.append(e)
            // 重新实例化 = 模拟 app 重启后从磁盘读回
            let again = HistoryStore().find(idPrefix: "clash0")
            t.equal(again?.clashFile, "KeyDrop-20250101-000000-abcd.yaml", "clashFile 落盘并可读回")
            // 旧格式历史(无 clashFile 字段)解码不报错
            let old = HistoryTests.entry("clash0bb2-1111-2222-3333-444444444444", ts: 200)
            try! hist.append(old)
            t.expect(HistoryStore().find(idPrefix: "clash0b")?.clashFile == nil, "无 clashFile 字段的旧条目兼容")
        }

        // ---- 第二轮深审修复 ----

        h.runSuite("Regression.refresh 失效不僵尸化") { t in
            let env = try! TestEnv("reg-dead")
            defer { env.cleanup() }
            try! CCSwitchWriterTests.createSchema(env)
            let core = Core()
            guard let srv = try? MockHTTPServer(mode: .html200) else {
                t.expect(false, "mock 启动失败")
                return
            }
            let base = "http://127.0.0.1:\(srv.port)"
            _ = try! core.add(raw: "\(base) sk-deadmark11111111111", ccOverride: true, cpaOverride: false, dshOverride: false,
                              models: ["glm-5.2"], force: true, appType: "opencode", appTypeForced: true)
            let e0 = core.history.snapshot().first { $0.key == "sk-deadmark11111111111" }
            t.expect(e0 != nil, "条目入库")
            do {
                _ = try core.refreshModels(entryIDPrefix: e0!.id)
                t.expect(false, "失效 key 的 refresh 应抛错")
            } catch {
                t.contains(error.localizedDescription, "已失效", "报错标注失效: \(error.localizedDescription)")
            }
            let e1 = core.history.snapshot().first { $0.key == "sk-deadmark11111111111" }
            t.equal(e1?.health, "dead", "health=dead")
            // 修复点:status 保持 active —— 否则条目从 UI 全部列表消失且 delete() 拒绝删除(僵尸)
            t.equal(e1?.status, "active", "status 保持 active(修复前为 dead → UI 不可见且删不掉)")
        }

        h.runSuite("Regression.activateCPA 幂等") { t in
            let env = try! TestEnv("reg-cpa-act")
            defer { env.cleanup() }
            try! CCSwitchWriterTests.createSchema(env)
            // CPA 端点信息走 env,不依赖本机真实 CPA
            setenv("KEYDROP_LLM_KEY", "sk-client-key-act-000000", 1)
            defer { setenv("KEYDROP_LLM_KEY", "", 1) }
            let core = Core()
            var e = HistoryTests.entry("cpaact001-1111-2222-3333-444444444444", ts: 100)
            e.targets = ["cpa"]
            e.models = ["glm-5.2"]
            try! core.history.append(e)
            _ = try! core.activateCPA(entryIDPrefix: e.id)
            let first = core.history.find(idPrefix: "cpaact")!
            t.expect(first.ccProviderID != nil, "首次激活写入 provider")
            let db = try! DB(path: env.dir + "/cc-switch.db")
            // 重复激活:claude/opencode 类型无 URL 去重,不清理旧 provider 会累积孤儿
            _ = try! core.activateCPA(entryIDPrefix: e.id)
            let cnt = try! db.scalar("SELECT count(*) FROM providers WHERE app_type='opencode'")
            t.equal(cnt, "1", "重复激活不累积孤儿 provider(修复前每次 +1)")
            let final = core.history.find(idPrefix: "cpaact")!
            t.expect(final.ccProviderID != nil, "再次激活后仍有 provider 指向")
        }

        h.runSuite("Regression.CPA 多 key 全链路") { t in
            let env = try! TestEnv("reg-cpa-multi")
            defer { env.cleanup() }
            let core = Core()
            // KEYDROP_CPA_CONFIG 由 TestEnv 指向临时目录(不存在),先建配置文件
            env.write("cpa-config.yaml", "port: 18317\n")
            guard let srv = try? MockHTTPServer(mode: .openAI) else {
                t.expect(false, "mock 启动失败")
                return
            }
            let base = "http://127.0.0.1:\(srv.port)/v1"
            let raw = "\(base) sk-multikeya111111111 sk-multikeyb222222222"
            let outcome = try! core.add(raw: raw, ccOverride: false, cpaOverride: true, dshOverride: false, force: true)
            t.expect(outcome.ok, "多 key 导入成功")
            t.equal(outcome.entry.format, "cpa-multikey", "format 标记 multikey")
            let cfg = env.read("cpa-config.yaml")
            t.contains(cfg, "sk-multikeya111111111", "key a 写入")
            t.contains(cfg, "sk-multikeyb222222222", "key b 写入")
            // 删除条目:必须把 raw 里的所有 key 都从 CPA 移除(修复前只删第一把)
            let msg = try! core.delete(entryIDPrefix: outcome.entry.id)
            t.contains(msg, "CPA", "删除走 CPA 清理: \(msg)")
            let after = env.read("cpa-config.yaml")
            t.expect(!after.contains("sk-multikeya111111111"), "key a 已移除")
            t.expect(!after.contains("sk-multikeyb222222222"), "key b 已移除(修复前残留)")
        }

        h.runSuite("Regression.CPA 多 key 自动剔除失效 key") { t in
            let env = try! TestEnv("reg-cpa-multi-prune")
            defer { env.cleanup() }
            let core = Core()
            env.write("cpa-config.yaml", "port: 18317\n")
            guard let srv = try? MockHTTPServer(mode: .selectiveAuth) else {
                t.expect(false, "mock 启动失败")
                return
            }
            let base = "http://127.0.0.1:\(srv.port)/v1"
            let raw = "\(base) sk-invalid-multi-1111111111 sk-valid-multi-2222222222"
            let outcome = try! core.add(raw: raw, ccOverride: false, cpaOverride: true, dshOverride: false, force: true)
            t.expect(outcome.ok, "有效 key 存在时多 key 导入成功")
            let cfg = env.read("cpa-config.yaml")
            t.contains(cfg, "sk-valid-multi-2222222222", "保留有效 key")
            t.expect(!cfg.contains("sk-invalid-multi-1111111111"), "自动剔除明确 401 的失效 key")
            t.contains(outcome.lines.joined(separator: "\n"), "自动剔除 1 个失效 key", "结果提示剔除数量")
        }

        // 真实事故(hashneuron):4 模型中首选 composer 429 quota、glm-5.3-free 可用,
        // 旧逻辑 chat 只探 models.first → 整 key 误判无额度进额度区,用户"导入成功但看不到"
        h.runSuite("Regression.部分模型限流不绑架整 key") { t in
            guard let srv = try? MockHTTPServer(mode: .selectiveModelQuota) else {
                t.expect(false, "mock 启动失败"); return
            }
            let base = "http://127.0.0.1:\(srv.port)/v1"
            // ① 探测层:key 可用、不误判 quota;free 模型排最前;3 个限流模型记录在案
            let res = APITester.test(url: base, key: "sk-partial-quota-111111", timeout: 5)
            t.expect(res.ok, "有 free 模型可用 → key 判可用: \(res.detail)")
            t.expect(!res.quotaExhausted, "部分限流不得判整 key 无额度")
            t.expect(!res.models.contains("test"), "占位 test 不混入模型列表")
            t.equal(res.models.first, "z-ai/glm-5.3-free", "free 模型排最前")
            t.equal(Set(res.quotaModels).count, 3, "3 个限流模型被逐个确认")
            t.equal(res.workingModels, ["z-ai/glm-5.3-free"], "free 模型确认可用")
            // ② GUI 导入(有选择器):部分限流 → 强制弹窗(哪怕 4≤5),用户挑中的才导入
            let env = try! TestEnv("reg-partial-gui")
            defer { env.cleanup() }
            env.write("cpa-config.yaml", "port: 18317\n")
            let core = Core()
            var pickerCalled = false
            let gui = try! core.add(
                raw: base + " sk-partial-quota-111111",
                ccOverride: false, cpaOverride: true, dshOverride: false, force: false
            ) { ms in
                pickerCalled = true
                return ms.filter { $0.contains("free") }   // 用户只挑免费模型
            }
            t.expect(pickerCalled, "部分限流时强制弹选择器(修复前 ≤5 自动全导无法选)")
            t.equal(gui.entry.models, ["z-ai/glm-5.3-free"], "只导入用户挑中的模型")
            t.equal(gui.entry.health, "ok", "key 落可用区而非额度区")
            // ③ CLI 导入(无选择器):自动排除限流模型
            let env2 = try! TestEnv("reg-partial-cli")
            defer { env2.cleanup() }
            env2.write("cpa-config.yaml", "port: 18317\n")
            let core2 = Core()
            let cli = try! core2.add(
                raw: base + " sk-partial-quota-222222",
                ccOverride: false, cpaOverride: true, dshOverride: false, force: false
            )
            t.equal(cli.entry.models, ["z-ai/glm-5.3-free"], "CLI 自动排除 3 个限流模型")
            t.contains(cli.lines.joined(separator: "\n"), "自动排除 3 个限流模型", "提示排除: \(cli.lines.joined(separator: " | ").prefix(120))")
        }

        h.runSuite("Regression.CPA nvapi 多 key 全链路") { t in
            let env = try! TestEnv("reg-cpa-nvapi")
            defer { env.cleanup() }
            let core = Core()
            env.write("cpa-config.yaml", "port: 18317\n")
            guard let srv = try? MockHTTPServer(mode: .openAI) else {
                t.expect(false, "mock 启动失败")
                return
            }
            let base = "http://127.0.0.1:\(srv.port)/v1"
            // 每行一把 key 的真实批量粘贴形态;nvapi- 前缀曾不在提取白名单,
            // 多 key 路径不触发,只有第一把被当单 key 导入
            let raw = "\(base)\nnvapi-aaa111bbb222ccc333ddd111\nnvapi-eee444fff555ggg666hhh222\nnvapi-ooo777ppp888qqq999rrr333"
            let outcome = try! core.add(raw: raw, ccOverride: false, cpaOverride: true, dshOverride: false, force: true)
            t.expect(outcome.ok, "nvapi 多 key 导入成功")
            t.equal(outcome.entry.format, "cpa-multikey", "format 标记 multikey")
            let cfg = env.read("cpa-config.yaml")
            t.contains(cfg, "nvapi-aaa111bbb222ccc333ddd111", "key 1 写入")
            t.contains(cfg, "nvapi-eee444fff555ggg666hhh222", "key 2 写入")
            t.contains(cfg, "nvapi-ooo777ppp888qqq999rrr333", "key 3 写入")
            // 回归:多 key 条目必须回传并保存探测模型。models 为空时
            // UI「打开应用」路由 default:"claude",nvapi 批量导入被误标成 Claude Code
            t.equal(outcome.entry.models, ["gpt-5.6-sol", "glm-5.2"], "多 key 条目保存探测到的模型")

            // 第二批同 host 导入:合并进既有聚合条目(大量 key 分次导入的常态)
            let raw2 = "\(base)\nnvapi-sss444ttt555uuu666vvv777\nnvapi-www888xxx999yyy000zzz111"
            let outcome2 = try! core.add(raw: raw2, ccOverride: false, cpaOverride: true, dshOverride: false, force: true)
            t.expect(outcome2.ok, "第二批导入成功")
            let cfg2 = env.read("cpa-config.yaml")
            t.contains(cfg2, "nvapi-aaa111bbb222ccc333ddd111", "第一批 key 保留")
            t.contains(cfg2, "nvapi-sss444ttt555uuu666vvv777", "第二批 key 合并写入")

            // 删除第二批条目:只移除自己的 key,第一批不受影响
            _ = try! core.delete(entryIDPrefix: outcome2.entry.id)
            let cfg3 = env.read("cpa-config.yaml")
            t.expect(!cfg3.contains("nvapi-sss444ttt555uuu666vvv777"), "第二批 key 已移除")
            t.expect(cfg3.contains("nvapi-aaa111bbb222ccc333ddd111"), "第一批 key 不受第二批删除影响")
            // 删除第一批条目:三把 key 全部清理
            _ = try! core.delete(entryIDPrefix: outcome.entry.id)
            let cfg4 = env.read("cpa-config.yaml")
            t.expect(!cfg4.contains("nvapi-aaa111bbb222ccc333ddd111"), "key 1 已移除")
            t.expect(!cfg4.contains("nvapi-eee444fff555ggg666hhh222"), "key 2 已移除")
            t.expect(!cfg4.contains("nvapi-ooo777ppp888qqq999rrr333"), "key 3 已移除")
        }

        h.runSuite("Regression.CPA 合并:models 段在前不丢 key") { t in
            let env = try! TestEnv("reg-cpa-order")
            defer { env.cleanup() }
            let core = Core()
            guard let srv = try? MockHTTPServer(mode: .openAI) else { t.expect(false, "mock 启动失败"); return }
            let host = "127.0.0.1"
            // 手写/CPA 工具回写的合法字段序:models: 排在 api-key-entries: 之前。
            // 修复前:merge 时先插 models 使行号位移,再用失效 range 扫 api-key-entries,
            // 新 key 静默丢弃却报告成功(账本谎报)。
            env.write("cpa-config.yaml",
"""
port: 18317

openai-compatibility:
  - name: \(host):\(srv.port)
    base-url: "http://\(host):\(srv.port)/v1"
    models:
      - name: zzz-existing
        alias: ""
    api-key-entries:
      - api-key: sk-ordered-existing-111111
""")
            let base = "http://\(host):\(srv.port)/v1"
            let outcome = try! core.add(raw: "\(base) sk-brand-new-key-222222 sk-another-new-333333",
                                        ccOverride: false, cpaOverride: true, dshOverride: false, force: true)
            t.expect(outcome.ok, "合并导入成功")
            let cfg = env.read("cpa-config.yaml")
            t.contains(cfg, "sk-brand-new-key-222222", "新 key 1 落盘(修复前静默丢失)")
            t.contains(cfg, "sk-another-new-333333", "新 key 2 落盘(修复前静默丢失)")
            t.contains(cfg, "sk-ordered-existing-111111", "既有 key 保留")
            // 新 key 必须缩进在 api-key-entries 之下,不能顶格损坏 YAML
            for ln in cfg.components(separatedBy: "\n") {
                if ln.contains("sk-brand-new-key-222222") {
                    t.expect(ln.hasPrefix("      - api-key:"), "新 key 正确缩进: \(ln)")
                }
            }
            // YAML 仍合法(顶格会触发校验回滚)
            let y = Process()
            y.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            y.arguments = ["-c", "import yaml,sys; yaml.safe_load(open('\(env.dir)/cpa-config.yaml'))"]
            try? y.run(); y.waitUntilExit()
            t.expect(y.terminationStatus == 0, "合并后 YAML 合法")
        }

        h.runSuite("Regression.CPA 删除:跨段 key 两处都清") { t in
            let env = try! TestEnv("reg-cpa-crossdel")
            defer { env.cleanup() }
            let core = Core()
            // 同一把 key 同时存在于平铺段与聚合段(先单 key 导入再多 key 导入的现实结果)。
            // 修复前:删平铺段就 pending.remove,聚合段副本存活却报告「已移除」→ 僵尸凭据
            env.write("cpa-config.yaml",
"""
port: 18317

claude-api-key:
  - api-key: sk-dual-home-999999
    base-url: https://dual.example.org/v1

openai-compatibility:
  - name: dual.example.org
    base-url: "https://dual.example.org/v1"
    api-key-entries:
      - api-key: sk-dual-home-999999
""")
            // 通过 Core.delete 走真实用户路径:构造一条指向该 key 的 cpa 历史条目,
            // delete() 会从 raw 提取 key 再调 CPAWriter.remove(apiKeys:)
            let seeded = HistoryEntry(
                id: "crossdel-1111-2222-3333-444444444444", ts: 1,
                raw: "https://dual.example.org/v1\nsk-dual-home-999999", format: "multiline",
                name: "dual", url: "https://dual.example.org/v1", model: nil, models: nil,
                key: "sk-dual-home-999999", keyMasked: "sk-d…", targets: ["cpa"],
                ccProviderID: nil, ccRenamedFrom: nil, ccRenamedTo: nil,
                cpaConfigPath: env.dir + "/cpa-config.yaml", status: "active"
            )
            try! core.history.append(seeded)
            let msg = try! core.delete(entryIDPrefix: "crossdel")
            let cfg = env.read("cpa-config.yaml")
            t.expect(!cfg.contains("sk-dual-home-999999"), "两段副本全部清除")
            t.contains(msg, "移除", "报告移除: \(msg)")
            // 聚合条目内 key 清空后整条目移除,不留空 api-key-entries:
            t.expect(!cfg.contains("api-key-entries"), "无残留空 api-key-entries 头")
            let y = Process()
            y.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            y.arguments = ["-c", "import yaml; yaml.safe_load(open('\(env.dir)/cpa-config.yaml'))"]
            try? y.run(); y.waitUntilExit()
            t.expect(y.terminationStatus == 0, "删除后 YAML 合法")
        }

        // 语义(用户明确要求):聚合条目已有 models 段 = 用户精选(如只留 SOTA 4 个),
        // 再次导入同端点只合并 key,绝不把探测到的其它模型追加进来。
        // 旧语义(合并追加模型)已废:它会把上游 catalog 的 80+ 模型灌进精选列表
        h.runSuite("Regression.CPA 多 key 合并保留精选模型") { t in
            let env = try! TestEnv("reg-cpa-nvmodels")
            defer { env.cleanup() }
            let core = Core()
            guard let srv = try? MockHTTPServer(mode: .manyModels) else {
                t.expect(false, "mock 启动失败"); return
            }
            let base = "http://127.0.0.1:\(srv.port)/v1"
            env.write("cpa-config.yaml",
"""
port: 18317

openai-compatibility:
  - name: 127.0.0.1:\(srv.port)
    base-url: "\(base)"
    models:
      - name: seedmodel1
        alias: ""
    api-key-entries:
      - api-key: nvapi-seed-1111111111
""")
            let outcome = try! core.add(
                raw: "\(base) nvapi-aaa111bbb222ccc333ddd111 nvapi-eee444fff555ggg666hhh222",
                ccOverride: false, cpaOverride: true, dshOverride: false, force: true)
            t.expect(outcome.ok, "合并导入成功")
            let cfg = env.read("cpa-config.yaml")
            t.contains(cfg, "nvapi-seed-1111111111", "既有 key 保留")
            t.contains(cfg, "nvapi-aaa111bbb222ccc333ddd111", "新 key 合并写入")
            t.contains(cfg, "seedmodel1", "精选模型保留")
            t.expect(!cfg.contains("model-1-sample"), "探测模型不得追加进精选列表")
            t.equal(cfg.components(separatedBy: "models:").count - 1, 1, "models 段唯一")
            t.equal(cfg.components(separatedBy: "  - name: 127.0.0.1:").count - 1, 1, "仍是一个聚合条目")
            // 历史条目 models 同步反映精选列表(与配置一致,UI/常驻入口同源)
            t.equal(outcome.entry.models, ["seedmodel1"], "历史 models=条目精选而非探测全量")
            t.contains(outcome.lines.joined(separator: "\n"), "保留条目现有 1 个模型", "提示保留精选: \(outcome.lines.joined(separator: " | "))")
        }

        // 场景 B:条目无 models(上次探测失败/新建空)→ 本次探测结果补写一次,不重复
        h.runSuite("Regression.CPA 合并模型不重复") { t in
            let env = try! TestEnv("reg-cpa-dedup-b")
            defer { env.cleanup() }
            let core2 = Core()
            guard let srv2 = try? MockHTTPServer(mode: .manyModels) else {
                t.expect(false, "mock 启动失败"); return
            }
            let base2 = "http://127.0.0.1:\(srv2.port)/v1"
            env.write("cpa-config.yaml",
"""
port: 18317

openai-compatibility:
  - name: 127.0.0.1:\(srv2.port)
    base-url: "\(base2)"
    api-key-entries:
      - api-key: nvapi-seed-cccccccc
""")
            let outD = try? core2.add(
                raw: "\(base2) nvapi-sss444ttt555uuu666vvv777 nvapi-www888xxx999yyy000zzz111",
                ccOverride: false, cpaOverride: true, dshOverride: false, force: true)
            t.expect(outD?.ok == true, "无 models 段的条目导入时补写探测模型成功(修复前重复键回滚)")
            let cfg2 = env.read("cpa-config.yaml")
            t.equal(cfg2.components(separatedBy: "models:").count - 1, 1, "models 段唯一(无重复键)")
            for n in 1...8 {
                t.equal(cfg2.components(separatedBy: "- name: model-\(n)-sample").count - 1, 1,
                        "模型 model-\(n)-sample 只出现一次")
            }
            t.contains(cfg2, "nvapi-sss444ttt555uuu666vvv777", "新 key 写入")
            t.contains(cfg2, "nvapi-seed-cccccccc", "既有 key 保留")
        }

        // 修复:同 key 同 URL 但模型家族变化的重导入,旧的跨 app_type provider 必须清理,
        // 否则 entry.targets 里的旧标签已被过滤,新标签只指向新 provider → 旧 provider 成孤儿。
        h.runSuite("Regression.改家族重导入清理旧 provider") { t in
            let env = try! TestEnv("reg-refamily")
            defer { env.cleanup() }
            try! CCSwitchWriterTests.createSchema(env)
            let core = Core()
            _ = try! core.add(raw: "https://gwy.example.org/v1 sk-famchange11111111",
                              ccOverride: true, cpaOverride: false, dshOverride: false,
                              models: ["claude-sonnet-4-5"], force: true, appType: "claude", appTypeForced: true)
            let e0 = core.history.snapshot().first { $0.key == "sk-famchange11111111" }!
            t.equal(e0.targets, ["ccswitch"], "首次为 claude")
            let oldPid = e0.ccProviderID!
            // 同 key 同 URL 用 gpt 模型重导入 → appType 变 codex
            _ = try! core.add(raw: "https://gwy.example.org/v1 sk-famchange11111111",
                              ccOverride: true, cpaOverride: false, dshOverride: false,
                              models: ["gpt-5.6-sol"], force: true, appType: "codex", appTypeForced: true)
            let db = try! DB(path: env.dir + "/cc-switch.db")
            let oldExists = try? db.scalar("SELECT 1 FROM providers WHERE id=?", [oldPid])
            t.expect(oldExists == nil, "旧 provider ID 已删除(修复前孤儿)")
            let claudeCount = Int((try? db.scalar("SELECT COUNT(*) FROM providers WHERE app_type='claude'")) ?? "0") ?? -1
            t.equal(claudeCount, 0, "claude provider 已清空")
            let codexCount = Int((try? db.scalar("SELECT COUNT(*) FROM providers WHERE app_type='codex'")) ?? "0") ?? -1
            t.equal(codexCount, 1, "新 codex provider 存在")
            let e1 = core.history.snapshot().first { $0.key == "sk-famchange11111111" }!
            t.equal(e1.targets, ["ccswitch-codex"], "targets 指向新 codex")
        }

        // 修复:opencode 的「激活默认模型」修复只在 add() 生效,刷新路径仍用 models.first,
        // 网关把图生模型排在前面时刷新后默认模型会回落到图生模型。
        h.runSuite("Regression.opencode 刷新激活模型不落图生") { t in
            let env = try! TestEnv("reg-oc-nonchat")
            defer { env.cleanup() }
            try! CCSwitchWriterTests.createSchema(env)
            let core = Core()
            guard let srv = try? MockHTTPServer(mode: .nonChatModels) else {
                t.expect(false, "mock 启动失败"); return
            }
            func activeModel() -> String? {
                guard let d = try? Data(contentsOf: URL(fileURLWithPath: env.dir + "/opencode.json")),
                      let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
                return o["model"] as? String
            }
            let base = "http://127.0.0.1:\(srv.port)/v1"
            let models = ["dall-e-3", "deepseek-v4-flash-0731"]
            _ = try! core.add(raw: "\(base) sk-ocnonchat111111111",
                              ccOverride: true, cpaOverride: false, dshOverride: false,
                              models: models, force: true, appType: "opencode", appTypeForced: true)
            let e0 = core.history.snapshot().first { $0.key == "sk-ocnonchat111111111" }!
            t.contains(activeModel() ?? "", "deepseek", "add 后激活模型为 chat 家族")
            // 刷新(模型无变化)→ 不得把图生模型写回默认。排序后 dall-e-3 在前,
            // 修复前 syncModelsAfterRefresh 取 models.first 就会落到 dall-e-3
            _ = try! core.refreshModels(entryIDPrefix: e0.id)
            let active = activeModel() ?? ""
            t.contains(active, "deepseek", "刷新后激活模型仍为 chat 家族: \(active)")
            t.expect(!active.contains("dall-e-3"), "刷新后激活模型不得为图生模型(修复前回落)")
        }

        // 修复:refresh 的「端点无模型列表」分支先落盘再迁移,迁移改动丢失,
        // 历史 ccProviderID 仍指向已删除的旧 provider。
        h.runSuite("Regression.refresh 空模型分支迁移落盘") { t in
            let env = try! TestEnv("reg-empty-migrate")
            defer { env.cleanup() }
            try! CCSwitchWriterTests.createSchema(env)
            let core = Core()
            guard let srv = try? MockHTTPServer(mode: .chatOK) else {
                t.expect(false, "mock 启动失败"); return
            }
            let base = "http://127.0.0.1:\(srv.port)/v1"
            // 历史遗留脏状态:claude provider 里存着 gpt 模型
            _ = try! core.add(raw: "\(base) sk-emptymigrate111111",
                              ccOverride: true, cpaOverride: false, dshOverride: false,
                              models: ["gpt-5.6-sol"], force: true, appType: "claude", appTypeForced: true)
            let e0 = core.history.snapshot().first { $0.key == "sk-emptymigrate111111" }!
            t.equal(e0.targets, ["ccswitch"], "初始为 claude")
            let oldPid = e0.ccProviderID!
            let msg = try! core.refreshModels(entryIDPrefix: e0.id)
            t.contains(msg, "迁移", "返回迁移提示")
            let e1 = core.history.snapshot().first { $0.key == "sk-emptymigrate111111" }!
            t.equal(e1.targets, ["ccswitch-codex"], "targets 已持久化为 codex(修复前丢失)")
            t.expect(e1.ccProviderID != oldPid, "ccProviderID 已换新并持久化")
            let db = try! DB(path: env.dir + "/cc-switch.db")
            let oldExists = try? db.scalar("SELECT 1 FROM providers WHERE id=?", [oldPid])
            t.expect(oldExists == nil, "旧 claude provider 已删除")
            let newCfg = (try? db.scalar("SELECT settings_config FROM providers WHERE id=? AND app_type='codex'", [e1.ccProviderID ?? ""])) ?? ""
            t.expect(!newCfg.isEmpty, "新 codex provider 已建立")
        }

        // 修复:reimport(repairMissingProvider)对 opencode 只写 DB,不写 opencode.json,
        // 与 add()/syncModelsAfterRefresh() 的双写不一致,opencode 看不到重建的渠道。
        h.runSuite("Regression.reimport opencode 双写 opencode.json") { t in
            let env = try! TestEnv("reg-oc-reimport")
            defer { env.cleanup() }
            try! CCSwitchWriterTests.createSchema(env)
            let writer = CCSwitchWriter()
            var p = ParsedKey()
            p.key = "sk-ocreimport111111"
            p.url = "https://oc.example.org/v1"
            p.model = "deepseek-v4-flash"
            let r = try! writer.add(p, appType: "opencode", models: ["deepseek-v4-flash"], proxy: nil)
            // 模拟 cc-switch 里 provider 被删除(reimport 的前提)
            let db = try! DB(path: env.dir + "/cc-switch.db")
            try! db.run("DELETE FROM providers WHERE id=?", [r.providerID])
            // 同时清空 opencode.json,模拟「缺失」
            env.write("opencode.json", "{}")
            let entry = HistoryEntry(
                id: UUID().uuidString.lowercased(), ts: Date().timeIntervalSince1970,
                raw: "\(p.url!)\n\(p.key!)", format: "multiline", name: "oc",
                url: p.url, model: p.model, models: ["deepseek-v4-flash"],
                key: p.key, keyMasked: "sk…", targets: ["ccswitch-opencode"],
                ccProviderID: r.providerID, ccRenamedFrom: nil, ccRenamedTo: nil,
                cpaConfigPath: nil, status: "active"
            )
            let repaired = try! writer.repairMissingProvider(entry: entry)
            t.expect(repaired, "provider 重建成功")
            let oc = env.read("opencode.json")
            t.contains(oc, r.providerID, "opencode.json 已写入重建的 provider(修复前只写 DB)")
            t.contains(oc, "deepseek-v4-flash", "opencode.json 含模型")
        }

        // 修复:SQLite 打开失败时已 close 一次,deinit 又 close 同一指针(UB);
        // 修复后应正常抛错且不二次 close。
        h.runSuite("Regression.DB 打开失败不二次释放") { t in
            do {
                _ = try DB(path: "/keydrop-nonexistent-\(UUID().uuidString)/db.sqlite")
                t.expect(false, "不存在的父目录应打开失败")
            } catch {
                t.expect(true, "打开失败正常抛错: \(error.localizedDescription)")
            }
        }

        // 修复:锁文件父目录不存在时 open 失败会静默退化为无锁;
        // 修复后自动创建父目录,首次写入也有锁保护。
        h.runSuite("Regression.FileLock 父目录自动创建") { t in
            let env = try! TestEnv("reg-filelock-parent")
            defer { env.cleanup() }
            let lockPath = env.dir + "/newdir/sub/data.json.keydrop-lock"
            try? FileLock.withLock(lockPath) { }
            t.expect(FileManager.default.fileExists(atPath: lockPath), "锁文件父目录自动创建")
        }

        // 修复:ClashWriter 曾对所有协议统一写 uuid:,trojan/hysteria2 在 mihomo 里因缺 password 失败。
        h.runSuite("Regression.Clash 凭据字段按协议") { t in
            let env = try! TestEnv("reg-clash-cred")
            defer { env.cleanup() }
            let trojan = ClashProxy(name: "tj", type: "trojan", server: "s.example.org", port: 443,
                                    uuid: "pw123", sni: "s.example.org")
            let vless = ClashProxy(name: "vl", type: "vless", server: "s.example.org", port: 443,
                                   uuid: "11111111-2222-3333-4444-555555555555", sni: "s.example.org")
            let (msg, file) = try! Core.addClashProxies([trojan, vless])
            t.expect(file != nil, "生成订阅文件: \(msg)")
            let yaml = (try? String(contentsOfFile: env.dir + "/clash-profiles/" + (file ?? ""), encoding: .utf8)) ?? ""
            t.contains(yaml, "type: trojan", "trojan 节点写入")
            t.contains(yaml, "password: \"pw123\"", "trojan 用 password 字段(修复前误写 uuid)")
            t.contains(yaml, "uuid: \"11111111", "vless 仍用 uuid 字段")
        }
    }
}
