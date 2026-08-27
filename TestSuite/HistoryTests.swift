import Foundation
import KeyDropCore

enum HistoryTests {
    static func entry(_ id: String, ts: TimeInterval) -> HistoryEntry {
        HistoryEntry(
            id: id, ts: ts, raw: "sk-\(id)", format: "test", name: "p-\(id)",
            url: "https://x.com/v1", model: nil, models: nil, key: "sk-\(id)",
            keyMasked: "sk-…\(id)", targets: ["ccswitch-opencode"], ccProviderID: nil,
            ccRenamedFrom: nil, ccRenamedTo: nil, cpaConfigPath: nil,
            status: "active", note: nil, health: "ok", healthDetail: nil, healthAt: nil
        )
    }

    static func run(_ h: Harness) {
        h.runSuite("History") { t in
            let env = try! TestEnv("hist")
            defer { env.cleanup() }
            let hist = HistoryStore()

            // append / snapshot / find
            try! hist.append(entry("aaaaaaaa-1111-2222-3333-444444444444", ts: 100))
            try! hist.append(entry("bbbbbbbb-1111-2222-3333-444444444444", ts: 200))
            t.equal(hist.snapshot().count, 2, "append 2 条")
            t.equal(hist.find(idPrefix: "aaaa")?.id, "aaaaaaaa-1111-2222-3333-444444444444", "前缀查找")
            t.expect(hist.find(idPrefix: "zzzz") == nil, "无匹配返回 nil")
            t.equal(hist.lastURL(), "https://x.com/v1", "lastURL")

            // update 修改字段
            var e = hist.find(idPrefix: "aaaa")!
            e.health = "dead"
            e.healthDetail = "401"
            try! hist.update(e)
            t.equal(hist.find(idPrefix: "aaaa")?.health, "dead", "update 生效")

            // findActiveByKey
            t.expect(hist.findActiveByKey("sk-bbbbbbbb-1111-2222-3333-444444444444") != nil, "按 key 找 active")
            var inact = hist.find(idPrefix: "bbbb")!
            inact.status = "error"
            try! hist.update(inact)
            t.expect(hist.findActiveByKey("sk-bbbbbbbb-1111-2222-3333-444444444444") == nil, "非 active 不命中")

            // ---- 批量更新 updateAll(健康扫描路径):多条一次落盘,未命中 id 静默跳过 ----
            var a1 = hist.find(idPrefix: "aaaa")!
            a1.health = "ok"
            let missing = entry("ffffffff-1111-2222-3333-444444444444", ts: 999)  // 不在库内
            try! hist.updateAll([a1, missing])
            t.equal(hist.find(idPrefix: "aaaa")?.health, "ok", "updateAll 命中更新")
            t.expect(hist.find(idPrefix: "ffff") == nil, "updateAll 未命中静默跳过")
            // 落盘后跨实例可见(证明确实持久化了一次)
            let histForUpdate = HistoryStore()
            t.equal(histForUpdate.find(idPrefix: "aaaa")?.health, "ok", "updateAll 已落盘")

            // ---- 竞态场景:CLI(另一进程)删除后 app 内存过期 ----
            // 模拟:app 内存里仍有 aaaa;文件已被 CLI 删除 aaaa 并新增 cccc
            var appMem = hist.find(idPrefix: "aaaa")!
            try! hist.save()  // 此刻文件=内存=[aaaa(dead), bbbb(error)]
            // 另一个"进程"直接改文件:删 aaaa,加 cccc
            struct W: Codable { var items: [HistoryEntry] }
            let fileItems = try! JSONDecoder().decode(W.self, from: Data(contentsOf: URL(fileURLWithPath: env.dir + "/home/history.json")))
            let cliItems = fileItems.items.filter { $0.id.hasPrefix("aaaa") == false } + [entry("cccccccc-1111-2222-3333-444444444444", ts: 300)]
            let data = try! JSONEncoder().encode(W(items: cliItems))
            try! data.write(to: URL(fileURLWithPath: env.dir + "/home/history.json"))
            // app 内存未感知,仍含 aaaa;app 再次 save
            _ = appMem
            try! hist.append(entry("dddddddd-1111-2222-3333-444444444444", ts: 400))
            // 期望:CLI 删除的 aaaa 不复活,CLI 新增的 cccc 保留,app 新增的 dddd 在
            let after = hist.snapshot()
            t.expect(!after.contains { $0.id.hasPrefix("aaaa") }, "CLI 删除不复活(竞态修复)")
            t.expect(after.contains { $0.id.hasPrefix("cccc") }, "CLI 新增保留")
            t.expect(after.contains { $0.id.hasPrefix("dddd") }, "app 新增保留")
            t.expect(after.contains { $0.id.hasPrefix("bbbb") }, "共存的旧条目保留")
            t.expect(after.first?.id.hasPrefix("dddd") == true, "按 ts 降序")

            // ---- 回归:常驻 app 感知 CLI 外部写入(mtime 变化触发重载) ----
            // 旧逻辑 snapshot 只读内存,CLI 新增条目要等 app 自己 save 才出现
            let live = HistoryStore()  // 新实例=模拟运行中的 app,加载当前文件(不含 eeee)
            t.expect(!live.snapshot().contains { $0.id.hasPrefix("eeee") }, "初始无 eeee")
            struct W2: Codable { var items: [HistoryEntry] }
            let cur = try! JSONDecoder().decode(W2.self, from: Data(contentsOf: URL(fileURLWithPath: env.dir + "/home/history.json")))
            let extData = try! JSONEncoder().encode(W2(items: cur.items + [entry("eeeeeeee-1111-2222-3333-444444444444", ts: 500)]))
            try! extData.write(to: URL(fileURLWithPath: env.dir + "/home/history.json"))
            t.expect(live.snapshot().contains { $0.id.hasPrefix("eeee") }, "外部写入后 snapshot 立即可见(mtime 重载)")
        }
    }
}
