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
        h.runSuite("History.protocol compatibility") { t in
            let env = try TestEnv("hist-protocol")
            defer { env.cleanup() }
            var e = entry("protocol", ts: 1)
            let legacy = try JSONDecoder().decode(HistoryEntry.self, from: JSONEncoder().encode(e))
            t.expect(legacy.apiStyle == nil, "旧账本缺少协议字段仍可读取")
            e.apiStyle = "anthropic"
            let store = HistoryStore()
            try store.append(e)
            t.equal(HistoryStore().snapshot().first?.apiStyle, "anthropic", "协议跨实例保存")
            e.apiStyle = "openai"
            try store.mergeHealth([e], at: 2)
            t.equal(HistoryStore().snapshot().first?.apiStyle, "openai", "巡检更新协议")
        }
        h.runSuite("History.sections mutually exclusive") { t in
            var dead = entry("dead", ts: 3)
            dead.health = "dead"
            dead.models = ["m"]
            dead.modelProbeLog = ["m": [ProbePoint(t: 1, ms: nil, ok: false)]]
            var quota = dead
            quota.id = "quota"; quota.health = "ok"; quota.ts = 2
            var good = entry("good", ts: 1)
            good.healthAt = 1
            let sections = HistorySections([good, quota, dead])
            t.equal(sections.dead.map(\.id), ["dead"], "死 key 归待删除区")
            t.equal(sections.quota.map(\.id), ["quota"], "全红模型仅进额度区")
            t.equal(sections.available.map(\.id), ["good"], "可用区互斥")
            t.equal(sections.okCount, 1, "横幅统计一致")
            let searched = HistorySections([good, quota, dead], query: "P-GOOD\tx.com")
            t.equal(searched.available.map(\.id), ["good"], "大小写与空白分词")
            t.equal(searched.okCount, 1, "全局统计不受搜索影响")
            t.expect(HistorySections([good], limit: 0).available.isEmpty, "零限制")
        }

        h.runSuite("History.first external creation") { t in
            let env = try TestEnv("hist-first-create")
            defer { env.cleanup() }
            let reader = HistoryStore()
            let writer = HistoryStore()
            try writer.append(entry("first-external", ts: 1))
            t.equal(reader.snapshot().first?.id, "first-external", "读取首次由 CLI 创建的文件")
        }

        h.runSuite("History.probe append preserves external changes") { t in
            let env = try TestEnv("hist-probe-external")
            defer { env.cleanup() }
            let app = HistoryStore()
            try app.append(entry("external-probe", ts: 1))
            let cli = HistoryStore()
            var edited = cli.snapshot()[0]
            edited.note = "CLI note"
            edited.models = ["new-model"]
            try cli.update(edited)
            try cli.appendProbePoint(id: edited.id, ok: true, ms: 10, cpa: nil, at: 10)
            try app.appendProbePoint(id: edited.id, ok: false, ms: nil, cpa: nil, at: 11)
            let saved = HistoryStore().snapshot()[0]
            t.equal(saved.note, "CLI note", "追加 key 探测保留外部备注")
            t.equal(saved.models, ["new-model"], "追加 key 探测保留外部模型")
            t.equal(saved.probeLog?.map(\.t), [10, 11], "合并两个实例追加的 key 探测点")
            try cli.appendModelProbePoints(id: edited.id, points: ["m": ProbePoint(t: 12, ms: 1, ok: true)])
            try app.appendModelProbePoints(id: edited.id, points: ["m": ProbePoint(t: 13, ms: 1, ok: false)])
            let modelSaved = HistoryStore().snapshot()[0]
            t.equal(modelSaved.modelProbeLog?["m"]?.map(\.t), [12, 13], "合并两个实例追加的模型探测点")
            t.equal(modelSaved.note, "CLI note", "追加模型探测保留外部备注")
        }

        h.runSuite("History.probe timestamps persist") { t in
            let env = try TestEnv("hist-probe-time")
            defer { env.cleanup() }
            let store = HistoryStore()
            var e = entry("probe", ts: 1)
            try store.append(e)
            e = store.snapshot()[0]
            e.updatedAt = 1
            try store.updateAll([e])
            try store.appendProbePoint(id: e.id, ok: true, ms: 1, cpa: nil, at: 100)
            t.expect((HistoryStore().snapshot()[0].updatedAt ?? 0) > 1, "探测时间在落盘前更新")
            e = store.snapshot()[0]
            e.updatedAt = 1
            try store.updateAll([e])
            try store.appendModelProbePoints(id: e.id, points: ["m": ProbePoint(t: 101, ms: 2, ok: true)])
            t.expect((HistoryStore().snapshot()[0].updatedAt ?? 0) > 1, "模型探测时间在落盘前更新")
        }

        h.runSuite("History.health preserves external edits") { t in
            let env = try TestEnv("hist-health-external")
            defer { env.cleanup() }
            let store = HistoryStore()
            try store.append(entry("health-external", ts: 1))
            var pending = store.snapshot()[0]
            let cli = HistoryStore()
            var edited = cli.snapshot()[0]
            edited.note = "CLI 新备注"
            edited.models = ["new-model"]
            edited.status = "deleted"
            try cli.update(edited)
            pending.health = "dead"
            try store.mergeHealth([pending], at: 200)
            let saved = HistoryStore().snapshot()[0]
            t.equal(saved.note, "CLI 新备注", "扫描不得回滚外部备注")
            t.equal(saved.models, ["new-model"], "扫描不得回滚外部模型")
            t.equal(saved.status, "deleted", "扫描不得复活已删除条目")
            edited.status = "active"
            try cli.update(edited)
            try store.mergeHealth([pending], at: 201)
            let active = HistoryStore().snapshot()[0]
            t.equal(active.note, "CLI 新备注", "活跃条目也保留外部备注")
            t.equal(active.models, ["new-model"], "活跃条目也保留外部模型")
            t.equal(active.health, "dead", "合并新的探测结果")
        }

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

        h.runSuite("History.applyCap 不裁 active 孤儿") { t in
            // 回归:旧实现 prefix(500) 无差别丢最旧,会把仍持有 cc-switch/CPA/Grok 产物的
            // active 条目裁掉 → 外部产物瞬间无人认领(删不掉、对账不认领的孤儿)。
            // 构造 501 条:500 active(带 target)+ 1 deleted(最旧)。
            var items: [HistoryEntry] = []
            for i in 0..<500 {
                var e = entry(String(format: "act-%03d-1111-2222-333344444444", i), ts: TimeInterval(1000 + i))
                e.targets = ["ccswitch-opencode"]
                items.append(e)
            }
            var dead = entry("del-000-1111-2222-333344444444", ts: 1)   // 最旧且 deleted
            dead.status = "deleted"
            dead.targets = []
            items.append(dead)
            items.sort { $0.ts > $1.ts }
            let capped = HistoryStore.applyCap(items)
            t.equal(capped.count, 500, "501→500 裁掉一条")
            t.expect(!capped.contains { $0.id.hasPrefix("del-000") }, "优先裁 deleted 条目,active 全保")
            t.expect(capped.allSatisfy { $0.status == "active" }, "500 条全为 active")
            // 结果必须仍按 ts 降序(不破坏 list/snapshot/UI 顺序)
            t.expect(capped.first!.id.hasPrefix("act-499"), "保序:最新在首")
            t.expect(capped.last!.ts < capped.first!.ts, "ts 严格降序未被 active 优先打乱")
            // 全 active 超限时软超限(不制造孤儿),而不是硬裁到 500
            var allActive: [HistoryEntry] = []
            for i in 0..<505 {
                var e = entry(String(format: "aa-%04d-1111-2222-333344444444", i), ts: TimeInterval(2000 + i))
                e.targets = ["cpa"]
                allActive.append(e)
            }
            allActive.sort { $0.ts > $1.ts }
            let soft = HistoryStore.applyCap(allActive)
            t.equal(soft.count, 505, "全 active 时宁可软超限也不裁(不制造孤儿)")
        }
    }
}
