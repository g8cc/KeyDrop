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

            // 模型名含引号/反斜杠:TOML 必须转义且校验通过
            var p2 = ParsedKey()
            p2.key = "sk-abcdef123456"
            p2.url = "https://gwy.example.org"
            let weird = "qwen3\"quote\\slash"
            let r2 = try! w.add(p2, appType: "codex", models: [weird], proxy: nil)
            t.expect(r2.warnings.first { $0.contains("回读不一致") } == nil,
                     "特殊字符模型不误报回读失败: \(r2.warnings)")
            let cfg = env.read("codex.toml")
            t.contains(cfg, "model = \"qwen3\\\"quote\\\\slash\"", "模型名 TOML 转义写入")
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
    }
}
