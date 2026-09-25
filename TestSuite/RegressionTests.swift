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
        h.runSuite("Regression.余额接口报0不误判可用key") { t in
            // 真实反馈(dc403556):new.xinjianya.top 余额接口报 0,但 chat 实测
            // 6 轮全绿(kimi-k3/nemotron 等都能通)—— 幂等更新走 refreshModels
            // 被余额接口判进无额度区,周期扫描又捞回可用区,两路径来回横跳。
            // 修复:余额接口只在「本轮无任何 chat 实测通过」时才有发言权
            guard let srv = try? MockHTTPServer(mode: .balanceZero) else {
                t.expect(false, "mock 启动失败"); return
            }
            let base = "http://127.0.0.1:\(srv.port)/v1"
            let env = try! TestEnv("reg-balance-zero")
            defer { env.cleanup() }
            env.write("cpa-config.yaml", "port: 18317\n")
            let core = Core()
            let first = try! core.add(raw: base + " sk-balancezero-0001",
                                      ccOverride: false, cpaOverride: true, dshOverride: false, force: false)
            t.equal(first.entry.health, "ok", "导入时 chat 实测通过 → 可用")
            // 幂等更新走 refreshModels:余额接口报 0,但 chat 实测有模型通过 → 以实测为准
            _ = try! core.refreshModels(entryIDPrefix: first.entry.id)
            let e = core.history.find(idPrefix: first.entry.id)!
            t.equal(e.health, "ok", "余额接口报 0 但 chat 可用 → 仍判可用(修复前判 quota)")
            t.contains(e.healthDetail ?? "", "以实测为准", "详情留痕余额脱节: \(e.healthDetail ?? "")")
        }

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

        // MARK: - CPA 生图渠道(image: true + 独立条目,与文本条目零交叉)

        // 场景 1:已有文本聚合条目,image-add 新建独立 -image 条目并打 image: true,
        // 文本条目原样不动、生图模型绝不灌进文本 entryModels
        h.runSuite("Regression.CPA 生图独立条目") { t in
            let env = try! TestEnv("reg-cpa-img-new")
            defer { env.cleanup() }
            env.write("cpa-config.yaml",
"""
port: 18317

openai-compatibility:
  - name: 127.0.0.1:9999
    base-url: "http://127.0.0.1:9999/v1"
    models:
      - name: gpt-5.2
        alias: gpt-5.2
    api-key-entries:
      - api-key: sk-text-111111
""")
            let w = CPAWriter(configPath: env.dir + "/cpa-config.yaml")
            do {
                let msg = try w.addImageChannel(baseURL: "http://127.0.0.1:9999/v1",
                                                key: "sk-img-aaaa222", models: ["gpt-image-1"])
                t.contains(msg, "127.0.0.1:9999-image", "报告独立条目名")
            } catch {
                t.expect(false, "写入失败: \(error.localizedDescription)")
            }
            let cfg = env.read("cpa-config.yaml")
            // name 含冒号,yamlScalar 会加引号
            t.contains(cfg, "\"127.0.0.1:9999-image\"", "生图独立条目已建")
            t.contains(cfg, "sk-img-aaaa222", "生图 key 写入")
            t.contains(cfg, "image: true", "模型带 image 标记")
            // 文本条目完好无损
            t.contains(cfg, "- name: gpt-5.2", "文本模型保留")
            t.contains(cfg, "sk-text-111111", "文本 key 保留")
            // 交叉污染检查:文本条目的精选模型读回只有 gpt-5.2,绝无 gpt-image-1
            t.equal(w.entryModels(baseURL: "http://127.0.0.1:9999/v1"), ["gpt-5.2"],
                    "文本 entryModels 不被生图模型污染")
            // YAML 合法 + 无重复键
            let y = Process()
            y.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            y.arguments = ["-c",
                "import yaml\n"
                + "d=yaml.safe_load(open('\(env.dir)/cpa-config.yaml'))\n"
                + "names=[e['name'] for e in d['openai-compatibility']]\n"
                + "assert len(names)==len(set(names)), 'duplicate entry name'\n"
                + "img=[e for e in d['openai-compatibility'] if e['name'].endswith('-image')][0]\n"
                + "assert any(m.get('image') is True for m in img['models']), 'image flag missing'\n"
                + "txt=[e for e in d['openai-compatibility'] if not e['name'].endswith('-image')][0]\n"
                + "assert all(not m.get('image') for m in txt['models']), 'text entry image-flagged'"]
            let ePipe = Pipe(); y.standardError = ePipe; y.standardOutput = Pipe()
            try? y.run(); y.waitUntilExit()
            let errData = ePipe.fileHandleForReading.readDataToEndOfFile()
            t.expect(y.terminationStatus == 0,
                     "YAML 语义校验: " + (String(data: errData, encoding: .utf8) ?? ""))
        }

        // 场景 2:幂等 —— 同 key 同模型导两次不重复;再加第二把 key 进轮询池
        h.runSuite("Regression.CPA 生图重复导入幂等") { t in
            let env = try! TestEnv("reg-cpa-img-idem")
            defer { env.cleanup() }
            env.write("cpa-config.yaml", "port: 18317\n")
            let w = CPAWriter(configPath: env.dir + "/cpa-config.yaml")
            _ = try? w.addImageChannel(baseURL: "https://img.example.org/v1", key: "sk-first0000000", models: ["flux-schnell"])
            _ = try? w.addImageChannel(baseURL: "https://img.example.org/v1", key: "sk-first0000000", models: ["flux-schnell"])
            // 同端点加第二把 key(轮询池)+ 第二个模型
            _ = try? w.addImageChannel(baseURL: "https://img.example.org/v1", key: "sk-second11111", models: ["dall-e-3"])
            let cfg = env.read("cpa-config.yaml")
            t.equal(cfg.components(separatedBy: "- name: img.example.org-image").count - 1, 1, "仍是一个生图条目")
            t.equal(cfg.components(separatedBy: "sk-first0000000").count - 1, 1, "重复 key 不重复写入")
            t.contains(cfg, "sk-second11111", "第二把 key 进池")
            t.equal(cfg.components(separatedBy: "image: true").count - 1, 2, "两个模型各一个 image 标记")
            t.contains(cfg, "- name: flux-schnell", "模型一写入")
            t.contains(cfg, "- name: dall-e-3", "模型二写入")
        }

        // 场景 3:全新 config(连 openai-compatibility 段都没有)→ 建段建条目
        h.runSuite("Regression.CPA 生图建段") { t in
            let env = try! TestEnv("reg-cpa-img-section")
            defer { env.cleanup() }
            env.write("cpa-config.yaml", "port: 8317\napi-keys:\n  - sk-client0000000\n")
            let w = CPAWriter(configPath: env.dir + "/cpa-config.yaml")
            _ = try? w.addImageChannel(baseURL: "https://new.example.org/v1", key: "sk-new00000000", models: ["gpt-image-1"])
            let cfg = env.read("cpa-config.yaml")
            t.contains(cfg, "openai-compatibility:", "缺失时段自动创建")
            t.contains(cfg, "- name: new.example.org-image", "条目写入")
            t.contains(cfg, "image: true", "标记写入")
            t.contains(cfg, "api-keys:", "既有顶层段保留")
            let y = Process()
            y.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            y.arguments = ["-c", "import yaml; yaml.safe_load(open('\(env.dir)/cpa-config.yaml'))"]
            try? y.run(); y.waitUntilExit()
            t.expect(y.terminationStatus == 0, "建段后 YAML 合法")
        }

        // 场景 4:ImageChannel via 字段向后兼容 —— 旧渠道文件(无 via)解码得到 direct
        h.runSuite("Regression.生图渠道 via 兼容") { t in
            let env = try! TestEnv("reg-img-via")
            defer { env.cleanup() }
            // 模拟旧版格式:无 via 键
            try! Data("{\"url\":\"https://a/v1\",\"key\":\"sk-abcdef123456\",\"model\":\"m\",\"keyMasked\":\"sk-abc…3456\"}".utf8)
                .write(to: URL(fileURLWithPath: env.dir + "/image-channel.json"))
            setenv("KEYDROP_IMAGE_CHANNEL", env.dir + "/image-channel.json", 1)
            let old = ImageChannelStore.load()
            t.equal(old?.via, "direct", "旧文件无 via 字段回退 direct")
            t.equal(old?.url, "https://a/v1", "旧字段照常读出")
            // 新格式 round-trip
            try! ImageChannelStore.save(ImageChannel(url: "http://127.0.0.1:8317/v1", key: "sk-clientkey12345", model: "gpt-image-1", via: "cpa"))
            let rt = ImageChannelStore.load()
            t.equal(rt?.via, "cpa", "via=cpa round-trip")
        }

        // 真实事故:CPA 在 Docker 里,用户传 --proxy http://127.0.0.1:7890,KeyDrop 原样写进
        // config;容器内 127.0.0.1 指容器自身,代理失效,导入的 Cloudflare 网关 key 全打不通。
        // 修复:检测到 docker 部署时,loopback host 改写为 host.docker.internal
        h.runSuite("Regression.CPA docker 代理改写") { t in
            defer { unsetenv("KEYDROP_CPA_DOCKER") }
            let dockerCfg = "port: 8317\nxai-api-key:\n  - api-key: k\n    proxy-url: \"http://host.docker.internal:7890\"\n"
            let localCfg = "port: 8317\nopenai-compatibility:\n  - name: a\n    base-url: x\n"
            // A: docker config + loopback → 改写(scheme/端口保留)
            t.equal(CPAWriter.rewriteProxyForDocker("http://127.0.0.1:7890", configContent: dockerCfg),
                    "http://host.docker.internal:7890", "127.0.0.1 → host.docker.internal")
            t.equal(CPAWriter.rewriteProxyForDocker("http://localhost:7890", configContent: dockerCfg),
                    "http://host.docker.internal:7890", "localhost 同样改写")
            t.equal(CPAWriter.rewriteProxyForDocker("socks5://127.0.0.1:1080", configContent: dockerCfg),
                    "socks5://host.docker.internal:1080", "socks5 scheme 保留")
            // B: 非 docker config + loopback → 不动(宿主机 CPA 直连代理是对的)
            t.equal(CPAWriter.rewriteProxyForDocker("http://127.0.0.1:7890", configContent: localCfg),
                    "http://127.0.0.1:7890", "非 docker 部署不改写")
            // C: docker + 非 loopback → 不动(已经是可路由地址)
            t.equal(CPAWriter.rewriteProxyForDocker("http://10.0.0.5:7890", configContent: dockerCfg),
                    "http://10.0.0.5:7890", "非回环地址不动")
            // D: 空/nil → 原样
            t.expect(CPAWriter.rewriteProxyForDocker(nil, configContent: dockerCfg) == nil, "nil 代理原样")
            t.equal(CPAWriter.rewriteProxyForDocker("", configContent: dockerCfg), "", "空串原样")
            // E: 显式 KEYDROP_CPA_DOCKER=0 覆盖(宿主机 CPA 但 config 里有 docker 字样)
            setenv("KEYDROP_CPA_DOCKER", "0", 1)
            t.equal(CPAWriter.rewriteProxyForDocker("http://127.0.0.1:7890", configContent: dockerCfg),
                    "http://127.0.0.1:7890", "env=0 强制不改写")
            // F: 显式 =1 强制改写(全新 config 还没 docker 痕迹)
            setenv("KEYDROP_CPA_DOCKER", "1", 1)
            t.equal(CPAWriter.rewriteProxyForDocker("http://127.0.0.1:7890", configContent: localCfg),
                    "http://host.docker.internal:7890", "env=1 强制改写")
            unsetenv("KEYDROP_CPA_DOCKER")
        }

        // 写入路径联动:docker config 下 image-add 传 loopback 代理,落盘必须是 host.docker.internal
        h.runSuite("Regression.CPA docker 代理落盘") { t in
            let env = try! TestEnv("reg-cpa-docker-proxy")
            defer { env.cleanup() }
            env.write("cpa-config.yaml",
"""
port: 18317

openai-compatibility:
  - name: cloudfare-groq
    base-url: https://gateway.ai.cloudflare.com/x
    proxy-url: "http://host.docker.internal:7890"
    api-key-entries:
      - api-key: gsk-x
""")
            let w = CPAWriter(configPath: env.dir + "/cpa-config.yaml")
            _ = try? w.addImageChannel(baseURL: "https://cf-gated.example.org/v1", key: "sk-cfkey000000",
                                       models: ["gpt-image-2"], proxy: "http://127.0.0.1:7890")
            let cfg = env.read("cpa-config.yaml")
            t.contains(cfg, "- name: cf-gated.example.org-image", "生图条目写入")
            // yamlScalar 对含冒号的 URL 加引号,落盘形如 proxy-url: "http://host.docker.internal:7890"
            t.contains(cfg, "proxy-url: \"http://host.docker.internal:7890\"",
                       "新条目代理改写为 host.docker.internal")
            t.expect(!cfg.contains("http://127.0.0.1:7890"),
                     "不得写入容器不可达的 127.0.0.1 代理")
            let y = Process()
            y.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            y.arguments = ["-c", "import yaml; yaml.safe_load(open('\(env.dir)/cpa-config.yaml'))"]
            try? y.run(); y.waitUntilExit()
            t.expect(y.terminationStatus == 0, "改写后 YAML 合法")
        }

        // 迁移决策:单 key 导入从 claude-api-key 平铺段改走 openai-compatibility 聚合段
        // —— collectCuratedModels(cpa-sync 常驻入口的模型来源)只读聚合段,平铺段条目
        // 对它隐形,下次同步会丢模型。本测试锁定单 key 必须落聚合段。
        h.runSuite("Regression.单 key CPA 落聚合段") { t in
            let env = try! TestEnv("reg-cpa-single-agg")
            defer { env.cleanup() }
            env.write("cpa-config.yaml", "port: 18317\napi-keys:\n  - sk-client000000000\n")
            let core = Core()
            let outcome = try! core.add(
                raw: "https://single.example.org/v1 sk-singleagg111111",
                ccOverride: false, cpaOverride: true, dshOverride: false,
                models: ["glm-5.2", "qwen3-max"], force: true)
            t.expect(outcome.ok, "单 key CPA 导入成功")
            let cfg = env.read("cpa-config.yaml")
            // 聚合段特征:- name + api-key-entries
            t.contains(cfg, "openai-compatibility:", "段头存在")
            t.contains(cfg, "- name: single.example.org", "聚合条目 name=host")
            t.contains(cfg, "api-key-entries:", "走 api-key-entries 聚合结构")
            t.contains(cfg, "sk-singleagg111111", "key 写入")
            t.contains(cfg, "- name: glm-5.2", "模型 1 写入条目 models")
            t.contains(cfg, "- name: qwen3-max", "模型 2 写入条目 models")
            // 关键负断言:不得再写 claude-api-key 平铺段
            t.expect(!cfg.contains("claude-api-key:"), "绝不写平铺段(修复前单 key 全进平铺段)")
            // entryModels 读回 = 本次 models(cpa-sync 同源可见)
            let w = CPAWriter(configPath: env.dir + "/cpa-config.yaml")
            t.equal(w.entryModels(baseURL: "https://single.example.org/v1"), ["glm-5.2", "qwen3-max"],
                    "cpa-sync 视角模型可见(平铺段时代此读恒空)")
            // 删除闭环:聚合段条目随 key 清零整体移除
            _ = try! core.delete(entryIDPrefix: outcome.entry.id)
            let after = env.read("cpa-config.yaml")
            t.expect(!after.contains("sk-singleagg111111"), "删除清掉聚合段 key")
            t.expect(!after.contains("single.example.org"), "条目整条移除不留空 api-key-entries")
        }

        // 单 key 与多 key 同端点 → 合入同一聚合条目轮询池(平铺时代两条链路互不可见)
        h.runSuite("Regression.单 key 多 key 同端点合池") { t in
            let env = try! TestEnv("reg-cpa-single-merge")
            defer { env.cleanup() }
            env.write("cpa-config.yaml", "port: 18317\n")
            let core = Core()
            _ = try! core.add(raw: "https://pool.example.org/v1 sk-pool-single0001",
                              ccOverride: false, cpaOverride: true, dshOverride: false,
                              models: ["glm-5.2"], force: true)
            _ = try! core.add(raw: "https://pool.example.org/v1 sk-pool-multi00002 sk-pool-multi00003",
                              ccOverride: false, cpaOverride: true, dshOverride: false, force: true)
            let cfg = env.read("cpa-config.yaml")
            t.contains(cfg, "sk-pool-single0001", "单 key 在池")
            t.contains(cfg, "sk-pool-multi00002", "多 key 1 在池")
            t.contains(cfg, "sk-pool-multi00003", "多 key 2 在池")
            t.equal(cfg.components(separatedBy: "- name: pool.example.org").count - 1, 1,
                    "同端点仅一个聚合条目")
            t.equal(cfg.components(separatedBy: "api-key-entries:").count - 1, 1, "仅一份 key 池")
            // 精选保护仍然成立:条目 models 只有单 key 导入时的 glm-5.2
            let w = CPAWriter(configPath: env.dir + "/cpa-config.yaml")
            t.equal(w.entryModels(baseURL: "https://pool.example.org/v1"), ["glm-5.2"],
                    "多 key 导入不得追加探测模型(精选保护跨单/多 key 一致)")
        }
        // 真实事故(2026-09):删除 codex provider 时 restoreCodexConfig() 把 config.toml.bak
        // (滚动全局快照,冻结着早已删除网关 hiyo 的配置)move 回 live;cc-switch 运行中
        // watch live 把它回写进内存 current 的 DB 行 —— 先后污染 de5.net 行与 seekai.cc 行。
        // 修复:回退后 live = 回退目标自己的 DB 配置;cc-switch 运行中不碰 live;非 current
        // 删除不碰 live。.bak 仅作写坏时的人工恢复手段,代码不再自动消费。
        h.runSuite("Regression.删除回退不复活陈旧 live") { t in
            let staleBak = "model = \"gpt-5.6-luna\"\n[model_providers.custom]\nname = \"custom\"\nbase_url = \"https://free.hiyo.top/v1\"\n"
            // 走真实用户路径:core.add 两个 codex provider(后导入者为 current),伪造陈旧 .bak
            func seed(_ name: String) -> (TestEnv, Core, String, String) {
                let env = try! TestEnv(name)
                try! CCSwitchWriterTests.createSchema(env)
                let core = Core()
                let a = try! core.add(raw: "https://a-del.example.com/v1 sk-adel0000000001",
                                      ccOverride: true, cpaOverride: false, dshOverride: false,
                                      models: ["gpt-5.5"], force: true, appType: "codex", appTypeForced: true)
                let b = try! core.add(raw: "https://b-del.example.com/v1 sk-bdel0000000002",
                                      ccOverride: true, cpaOverride: false, dshOverride: false,
                                      models: ["gpt-5.6"], force: true, appType: "codex", appTypeForced: true)
                env.write("codex.toml.bak", staleBak)   // 事故现场:陈旧快照就位
                return (env, core, a.entry.id, b.entry.id)
            }
            // 场景 A:cc-switch 运行中(TestEnv 默认 FAKE=1)删除 current → live 逐字节不动
            do {
                let (env, core, _, idB) = seed("reg-del-live-running")
                defer { env.cleanup() }
                let liveBefore = env.read("codex.toml")
                _ = try! core.delete(entryIDPrefix: idB)
                t.equal(env.read("codex.toml"), liveBefore, "运行中: live 文件逐字节未动")
                t.equal(env.read("codex.toml.bak"), staleBak, ".bak 未被消费(move 语义已移除)")
            }
            // 场景 B:cc-switch 未运行删除 current → live = 回退目标 A 的配置,而非 .bak 内容
            do {
                let (env, core, idA, idB) = seed("reg-del-live-offline")
                defer { env.cleanup() }
                setenv("KEYDROP_FAKE_CC_RUNNING", "0", 1)
                defer { setenv("KEYDROP_FAKE_CC_RUNNING", "1", 1) }
                _ = try! core.delete(entryIDPrefix: idB)
                let live = env.read("codex.toml")
                t.contains(live, "a-del.example.com", "live 恢复为回退目标 A 的 URL")
                t.contains(live, "sk-adel0000000001", "live 恢复为回退目标 A 的 key")
                t.expect(!live.contains("free.hiyo.top"), "陈旧 .bak 内容不得复活")
                t.contains(env.read("codex-auth.json"), "sk-adel0000000001", "auth.json 同步为 A 的 key")
            }
            // 场景 C:删除非 current → live 与 current 均不动
            do {
                let (env, core, idA, _) = seed("reg-del-live-noncurrent")
                defer { env.cleanup() }
                let liveBefore = env.read("codex.toml")
                _ = try! core.delete(entryIDPrefix: idA)
                t.equal(env.read("codex.toml"), liveBefore, "非 current 删除: live 不动")
                let cur = try! DB(path: env.dir + "/cc-switch.db").scalar(
                    "SELECT settings_config FROM providers WHERE app_type='codex' AND is_current=1")
                t.contains(cur ?? "", "b-del.example.com", "current 行配置未被 .bak 污染")
            }
        }

        // 回归:对账路径(ccMissing 条目)必须写探测点。曾因只更新 health 不写
        // probeLog,对账条目 healthAt 每轮刷新,scanHealth 永远视为「刚测过」而跳过,
        // mergeHealth 永不执行 → 监控图永久空白(真实事故 20d64797:可用区 ok,监控零数据)
        h.runSuite("Regression.对账路径喂监控时间轴") { t in
            let env = try! TestEnv("reg-recon-probe")
            defer { env.cleanup() }
            // providerExists 在 DB 文件缺失时保守返回 true(防误删),必须先建空库
            try! CCSwitchWriterTests.createSchema(env)
            guard let srv = try? MockHTTPServer(mode: .openAI) else {
                t.expect(false, "mock 启动失败"); return
            }
            let core = Core()
            // cc-switch 库为空(TestEnv 隔离)→ providerExists 必然 false → 走对账分支;
            // healthAt 设为当前:模拟「刚被对账刷新」,scanHealth 自身必然跳过它,
            // probeLog 里的点只能来自对账路径 —— 修复前此用例必挂
            try! core.history.append(HistoryEntry(
                id: "recon-probe-0001-2222-3333-444444444444", ts: Date().timeIntervalSince1970,
                raw: "x", format: "multiline", name: "recon", url: "http://127.0.0.1:\(srv.port)/v1",
                model: "model-a", models: ["model-a"], key: "sk-recon00000001", keyMasked: "sk-r…",
                targets: ["ccswitch-codex"], ccProviderID: "recon-probe-0001-2222-3333-444444444444",
                ccRenamedFrom: nil, ccRenamedTo: nil, cpaConfigPath: nil, status: "active",
                note: nil, health: "ok", healthDetail: "seeded", healthAt: Date().timeIntervalSince1970
            ))
            let done = DispatchSemaphore(value: 0)
            core.scanHealth(staleAfter: 3600) { _ in done.signal() }
            _ = done.wait(timeout: .now() + 60)
            let e = core.history.find(idPrefix: "recon-probe")!
            t.expect(e.ccMissing == true, "provider 缺失已标记 ccMissing")
            t.expect((e.probeLog ?? []).isEmpty == false, "对账测试结果必须写入 probeLog(修复前为空)")
            t.equal(e.health, "ok", "mock 探测通过")
            // 第二轮对账:provider 仍缺失会再次命中,备注不得每轮重复追加
            let done2 = DispatchSemaphore(value: 0)
            core.scanHealth(staleAfter: 3600) { _ in done2.signal() }
            _ = done2.wait(timeout: .now() + 60)
            let e2 = core.history.find(idPrefix: "recon-probe")!
            t.equal((e2.note ?? "").components(separatedBy: "可手动重新导入").count - 1, 1,
                    "ccMissing 备注只追加一次: \(e2.note ?? "")")
        }

        // 实战监控 v1:延迟测量 / 失败防抖 / CPA 链路探测
        // 真实反馈:界面显示可用但用起来不行。断点:① 探测非流式 max_tokens=1 太浅;
        // ② 单次失败立即降级(抖动误杀),反之无失败记忆;③ 健康测试直连上游,
        // 用户实际走 CPA(8317)—— 上游 OK ≠ CPA 链路 OK(路由/容器/代理都可能断)
        h.runSuite("Regression.实战监控") { t in
            func entry(_ id: String, _ url: String, _ key: String, _ model: String, targets: [String]) -> HistoryEntry {
                HistoryEntry(
                    id: id, ts: Date().timeIntervalSince1970, raw: url + " " + key,
                    format: "multiline", name: id.prefix(8).description, url: url, model: model,
                    models: [model], key: key, keyMasked: "sk-t…", targets: targets,
                    ccProviderID: nil, ccRenamedFrom: nil, ccRenamedTo: nil,
                    cpaConfigPath: nil, status: "active"
                )
            }
            // 场景 1:延迟测量 —— chat 200 探测必须带回延迟
            do {
                let env = try! TestEnv("reg-mon-latency")
                defer { env.cleanup() }
                guard let srv = try? MockHTTPServer(mode: .openAI) else {
                    t.expect(false, "mock 启动失败"); return
                }
                let core = Core()
                try! core.history.append(entry("mon-latency-0001", "http://127.0.0.1:\(srv.port)/v1", "sk-lat0000000001", "model-a", targets: []))
                let done = DispatchSemaphore(value: 0)
                core.scanHealth(staleAfter: 0) { _ in done.signal() }
                _ = done.wait(timeout: .now() + 60)
                let e = core.history.find(idPrefix: "mon-latency")!
                t.expect(e.latencyMs != nil && e.latencyMs! > 0, "chat 探测延迟已记录: \(e.latencyMs ?? -1)")
                t.equal(e.health, "ok", "探测通过")
                t.expect(e.failStreak == 0, "成功清零防抖计数")
            }
            // 场景 2:CPA 链路探测 —— 带 cpa 目标的条目额外经 CPA 探测激活模型
            do {
                let env = try! TestEnv("reg-mon-cpa")
                defer { env.cleanup() }
                let cpaMock = try! MockHTTPServer(mode: .openAI)   // 模拟 8317:chat 200
                env.write("cpa-config.yaml", "port: \(cpaMock.port)\napi-keys:\n  - sk-cpaclient999\n")
                setenv("KEYDROP_LLM_KEY", "sk-cpaclient999", 1)
                defer { unsetenv("KEYDROP_LLM_KEY") }
                guard let upstream = try? MockHTTPServer(mode: .openAI) else {
                    t.expect(false, "upstream mock 启动失败"); return
                }
                let core = Core()
                try! core.history.append(entry("mon-cpa-0002", "http://127.0.0.1:\(upstream.port)/v1", "sk-up00000000001", "model-a", targets: ["cpa"]))
                let done = DispatchSemaphore(value: 0)
                core.scanHealth(staleAfter: 0) { _ in done.signal() }
                _ = done.wait(timeout: .now() + 90)
                let e = core.history.find(idPrefix: "mon-cpa")!
                t.equal(e.viaCPAOk, true, "CPA 链路探测通过(经 8317 模拟端点)")
                t.expect(e.viaCPAAt != nil, "CPA 链路探测时间已记录")
                t.expect(e.healthDetail?.contains("CPA 链路") != true, "链路通过不标注警告")
            }
            // 场景 3:CPA 链路失败 —— 上游 OK 但 CPA 调不通 → 详情标注,不直接降级
            do {
                let env = try! TestEnv("reg-mon-cpabad")
                defer { env.cleanup() }
                let cpaMock = try! MockHTTPServer(mode: .chat524)   // 模拟 8317:chat 424
                env.write("cpa-config.yaml", "port: \(cpaMock.port)\napi-keys:\n  - sk-cpaclient999\n")
                setenv("KEYDROP_LLM_KEY", "sk-cpaclient999", 1)
                defer { unsetenv("KEYDROP_LLM_KEY") }
                guard let upstream = try? MockHTTPServer(mode: .openAI) else {
                    t.expect(false, "upstream mock 启动失败"); return
                }
                let core = Core()
                try! core.history.append(entry("mon-cpabad-3", "http://127.0.0.1:\(upstream.port)/v1", "sk-up00000000002", "model-a", targets: ["cpa"]))
                let done = DispatchSemaphore(value: 0)
                core.scanHealth(staleAfter: 0) { _ in done.signal() }
                _ = done.wait(timeout: .now() + 90)
                let e = core.history.find(idPrefix: "mon-cpabad")!
                t.equal(e.viaCPAOk, false, "CPA 链路失败被记录")
                t.contains(e.healthDetail ?? "", "CPA 链路探测失败", "详情标注链路异常")
                t.equal(e.health, "ok", "上游可用 → 仍判可用(链路问题不误杀 key)")
            }
            // 场景 4:失败防抖 —— 首败保留 ok,连续两败才降级
            do {
                let env = try! TestEnv("reg-mon-debounce")
                defer { env.cleanup() }
                guard let bad = try? MockHTTPServer(mode: .chat524) else {
                    t.expect(false, "mock 启动失败"); return
                }
                let core = Core()
                try! core.history.append(entry("mon-deb-0004", "http://127.0.0.1:\(bad.port)/v1", "sk-deb0000000001", "model-a", targets: []))
                let done = DispatchSemaphore(value: 0)
                core.scanHealth(staleAfter: 0) { _ in done.signal() }
                _ = done.wait(timeout: .now() + 60)
                var e = core.history.find(idPrefix: "mon-deb")!
                t.equal(e.health, "ok", "首败保留可用(防抖)")
                t.equal(e.failStreak, 1, "首败计 streak=1")
                core.scanHealth(staleAfter: 0) { _ in done.signal() }
                _ = done.wait(timeout: .now() + 60)
                e = core.history.find(idPrefix: "mon-deb")!
                t.equal(e.failStreak, 2, "连续失败累计")
                t.equal(e.health, "err", "连续 2 次失败 → 降级 err")
            }
            // 场景 4b:key 死掉期间模型条不能冻结成灰 —— 防抖后仍判失败的轮次,
            // 所有模型都记红格(真实反馈:key 挂了,模型条却一直灰,看起来像「还没轮到测」)
            do {
                let env = try! TestEnv("reg-mon-deadmodels")
                defer { env.cleanup() }
                guard let bad = try? MockHTTPServer(mode: .chat401) else {   // /models 200, chat 401
                    t.expect(false, "mock 启动失败"); return
                }
                let core = Core()
                try! core.history.append(entry("mon-deadm-005", "http://127.0.0.1:\(bad.port)/v1", "sk-dm00000000001", "model-a",
                                               targets: []))
                // 手动预填两个模型,模拟多模型条目
                if var e = core.history.find(idPrefix: "mon-deadm") {
                    e.models = ["model-a", "model-b"]
                    try! core.history.update(e)
                }
                let done = DispatchSemaphore(value: 0)
                core.scanHealth(staleAfter: 0) { _ in done.signal() }   // 首败:防抖,不记红
                _ = done.wait(timeout: .now() + 60)
                var e = core.history.find(idPrefix: "mon-deadm")!
                t.equal(e.health, "ok", "[死 key] 首败防抖保留可用")
                t.expect(e.modelProbeLog?["model-b"] == nil, "[死 key] 首败不染红模型条")
                core.scanHealth(staleAfter: 0) { _ in done.signal() }   // 连续 2 败:降级 + 全模型记红
                _ = done.wait(timeout: .now() + 60)
                e = core.history.find(idPrefix: "mon-deadm")!
                t.equal(e.health, "dead", "[死 key] 连败降级 dead")
                t.expect(e.modelProbeLog?["model-a"]?.last?.ok == false, "[死 key] 模型 a 记红格")
                t.expect(e.modelProbeLog?["model-b"]?.last?.ok == false, "[死 key] 模型 b 也记红格(不冻结)")
            }
            // 场景 4c:配置模型全红但 key 级 ok → 分区口径必须以用户配置为准
            // 真实反馈(ed0d76a6):只配了 glm-5.3-flash(连续 429),网关上未配置的
            // nemotron 能通 → key 级判 ok → 躺在可用区,对用户却是纯坏消息
            do {
                func mk(_ id: String, models: [String]?, model: String?, log: [String: [Bool]]) -> HistoryEntry {
                    var e = entry(id, "http://x/v1", "sk-x", model ?? "m", targets: [])
                    e.models = models
                    let now = Date().timeIntervalSince1970
                    e.modelProbeLog = log.mapValues { $0.map { ProbePoint(t: now, ms: nil, ok: $0) } }
                    return e
                }
                // 配置的 glm 全红 + 未配置的 nemotron 绿 → 判「全限流」
                let a = mk("lim-a-0001", models: ["glm-5.3-flash"], model: "glm-5.3-flash",
                           log: ["glm-5.3-flash": [false, false], "nemotron": [true]])
                t.expect(a.allConfiguredModelsLimited, "配置模型全红 + key 级 ok → 全限流")
                // 配置模型有绿 → 不算
                let b = mk("lim-b-0002", models: ["glm-5.3-flash", "nemotron"], model: nil,
                           log: ["glm-5.3-flash": [false], "nemotron": [true]])
                t.expect(!b.allConfiguredModelsLimited, "配置模型之一可用 → 不算全限流")
                // 未采集的配置模型不算数(轮换中,不误伤)
                let c = mk("lim-c-0003", models: ["glm-5.3-flash", "new-model"], model: nil,
                           log: ["glm-5.3-flash": [false]])
                t.expect(!c.allConfiguredModelsLimited, "有配置模型尚未采集 → 不判全限流")
                // 无模型列表(chat-only 网关)不判
                let d = mk("lim-d-0004", models: nil, model: nil, log: [:])
                t.expect(!d.allConfiguredModelsLimited, "无模型列表 → 永不判全限流")
            }
            // 场景 5:探测模型以用户激活模型置顶(new-api TestModel 思路)
            let order = APITester.chatProbeOrder(
                ["m-free-1", "deepseek-v4-pro", "gpt-5.6-sol", "kimi-k3", "qwen-max", "glm-5.2"],
                preferred: "qwen-max")
            t.equal(order.first, "qwen-max", "激活模型探测置顶")
            t.expect(order.count == 4, "仍只探 4 个模型")
            t.expect(!order.contains("qwen-max") || order.first == "qwen-max", "无重复")
            t.equal(APITester.chatProbeOrder(["a", "b"], preferred: "not-in-list").first, "a",
                    "激活模型不在列表时回落原序")
            // 场景 6:探测历史滚动存档 —— 扫描/手动重测都入档,上限 30 点
            do {
                let env = try! TestEnv("reg-mon-history")
                defer { env.cleanup() }
                guard let srv = try? MockHTTPServer(mode: .openAI) else {
                    t.expect(false, "mock 启动失败"); return
                }
                let core = Core()
                try! core.history.append(entry("mon-hist-0005", "http://127.0.0.1:\(srv.port)/v1", "sk-hist00000001", "model-a", targets: []))
                let done = DispatchSemaphore(value: 0)
                core.scanHealth(staleAfter: 0) { _ in done.signal() }
                _ = done.wait(timeout: .now() + 60)
                core.scanHealth(staleAfter: 0) { _ in done.signal() }
                _ = done.wait(timeout: .now() + 60)
                var e = core.history.find(idPrefix: "mon-hist")!
                t.equal(e.probeLog?.count, 2, "两轮扫描产生两个探测点: \(e.probeLog?.count ?? -1)")
                t.expect(e.probeLog?.allSatisfy { $0.ok } == true, "点结果为通过")
                // 手动重测(refreshModels)同样入档
                _ = try! core.refreshModels(entryIDPrefix: "mon-hist")
                e = core.history.find(idPrefix: "mon-hist")!
                t.equal(e.probeLog?.count, 3, "手动重测也产生探测点")
                // 30 点滚动截断
                for i in 0..<35 {
                    try? core.history.appendProbePoint(id: e.id, ok: i % 3 != 0, ms: 500, cpa: nil,
                                                       at: Date().timeIntervalSince1970)
                }
                e = core.history.find(idPrefix: "mon-hist")!
                t.equal(e.probeLog?.count, 30, "滚动截断保留最近 30 点: \(e.probeLog?.count ?? -1)")
            }
            // 场景 7:模型级记账 —— working/quota 模型各自有独立轨迹(用户确认的粒度)
            do {
                let env = try! TestEnv("reg-mon-model")
                defer { env.cleanup() }
                guard let srv = try? MockHTTPServer(mode: .selectiveModelQuota) else {
                    t.expect(false, "mock 启动失败"); return   // 1 个 free 可用 + 3 个 429
                }
                let core = Core()
                try! core.history.append(entry("mon-model-006", "http://127.0.0.1:\(srv.port)/v1", "sk-mdl000000001",
                                               "z-ai/glm-5.3-free", targets: []))
                let done = DispatchSemaphore(value: 0)
                core.scanHealth(staleAfter: 0) { _ in done.signal() }
                _ = done.wait(timeout: .now() + 90)
                let e = core.history.find(idPrefix: "mon-model")!
                let mlog = e.modelProbeLog ?? [:]
                t.expect(mlog["z-ai/glm-5.3-free"]?.last?.ok == true, "可用模型轨迹 ok: \(mlog.keys)")
                t.equal(mlog["z-ai/glm-5.3-free"]?.count, 1, "可用模型 1 点")
                let quota = mlog.filter { $0.value.last?.ok == false }.map { $0.key }
                t.equal(quota.count, 3, "3 个限流模型各自记失败: \(quota)")
                t.expect(mlog["z-ai/glm-5.3-free"]?.first?.ms != nil, "可用模型带延迟")
                // 二轮扫描 → 轨迹增长(增量合并)
                core.scanHealth(staleAfter: 0) { _ in done.signal() }
                _ = done.wait(timeout: .now() + 90)
                let e2 = core.history.find(idPrefix: "mon-model")!
                t.equal(e2.modelProbeLog?["z-ai/glm-5.3-free"]?.count, 2, "二轮扫描轨迹增长(增量合并不覆盖)")
            }
        }

        h.runSuite("Regression.自动探测本机代理") { t in
            // 用户确认:本机代理常开。设置未填时,直连失败应自动找本机代理补测,
            // 连通后把代理写入设置(用户手填的永远优先,不覆盖)
            Core.resetProxyProbeForTest()
            let oldProxy = Prefs.shared.proxy
            defer {
                Prefs.shared.proxy = oldProxy
                try? Prefs.shared.save()
                Core.autoProxyCandidates = [
                    "http://127.0.0.1:7890", "http://127.0.0.1:7891", "http://127.0.0.1:1087",
                    "http://127.0.0.1:6152", "http://127.0.0.1:10808", "http://127.0.0.1:8118",
                ]
                Core.resetProxyProbeForTest()
            }

            // ① 候选里没有在监听的端口 → 探测返回 nil
            Prefs.shared.proxy = ""
            Core.autoProxyCandidates = ["http://127.0.0.1:1", "http://127.0.0.1:2"]
            t.expect(Core.detectLocalProxy(force: true) == nil, "无在监听候选 → 不瞎猜代理")

            // ② 候选端口在监听(MockHTTPServer 当代理靶子)→ 探测命中
            guard let srv = try? MockHTTPServer(mode: .openAI) else {
                t.expect(false, "mock 启动失败"); return
            }
            Core.autoProxyCandidates = ["http://127.0.0.1:\(srv.port)"]
            let hit = Core.detectLocalProxy(force: true)
            t.equal(hit, "http://127.0.0.1:\(srv.port)", "探测命中在监听的候选端口")

            // ③ 代理连通后写入设置;手填的不被覆盖
            let core = Core()
            core.noteProxyWorked(needsProxy: true, used: hit)
            t.equal(Prefs.shared.proxy, hit, "连通后自动写入设置(可在设置中修改)")
            core.noteProxyWorked(needsProxy: true, used: "http://127.0.0.1:9999")
            t.equal(Prefs.shared.proxy, hit, "已有值(或手填)时不覆盖")
            // 直连成功(needsProxy=false)不写
            Prefs.shared.proxy = ""
            core.noteProxyWorked(needsProxy: false, used: hit)
            t.equal(Prefs.shared.proxy, "", "直连成功不需要代理,不写")
        }
    }
}
