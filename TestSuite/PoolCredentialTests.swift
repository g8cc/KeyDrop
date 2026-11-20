import Foundation
import KeyDropCore

enum PoolCredentialTests {
    static func run(_ h: Harness) {
        h.runSuite("PoolAudit.failed CPA rotation retains original pool ownership") { t in
            let env = try TestEnv("pool-audit-failed-cpa-rotation")
            defer { env.cleanup() }
            let server = try MockHTTPServer()
            let base = "http://127.0.0.1:\(server.port)/v1"
            var record = HistoryTests.entry("pool-failed-cpa-rotation", ts: 1)
            record.format = "cpa-multikey"
            record.key = nil
            record.poolKeys = ["sk-failed-original1111", "sk-failed-retained2222"]
            record.url = base
            record.targets = ["cpa"]
            record.cpaConfigPath = env.dir + "/missing-config.yaml"
            let core = Core()
            try core.history.append(record)
            do {
                _ = try core.editEntry(entryIDPrefix: record.id, key: "sk-failed-replacement3333", verify: false)
                t.expect(false, "CPA 未更新时不能确认 key 已轮换")
            } catch {
                t.expect(true, "CPA 轮换失败向调用方报错")
            }
            let saved = core.history.find(idPrefix: record.id)!
            t.equal(saved.poolKeys, record.poolKeys, "失败后仍完整认领旧池")
            t.expect(saved.key == nil, "失败后不写入未经同步的新 key")
        }
        h.runSuite("PoolAudit.credential source authority and legacy rotation recovery") { t in
            var entry = HistoryTests.entry("pool-source-authority", ts: 1)
            entry.format = "cpa-multikey"
            entry.key = nil
            entry.raw = "https://fixture.example/v1\nsk-original-source1111\nsk-retained-source2222"
            t.equal(entry.credentialKeys, ["sk-original-source1111", "sk-retained-source2222"], "旧池按原顺序恢复")
            entry.poolKeys = []
            t.equal(entry.credentialKeys, [], "显式空池不恢复 raw 内已拒绝凭据")
            entry.poolKeys = [" sk-retained-source2222 ", "", "sk-retained-source2222"]
            t.equal(entry.credentialKeys, ["sk-retained-source2222"], "显式池清理空白/重复，不恢复 raw")
            entry.poolKeys = ["sk-original-source1111", "sk-retained-source2222"]
            entry.key = "sk-replacement-source3333"
            t.equal(entry.credentialKeys, ["sk-replacement-source3333", "sk-retained-source2222"], "兼容旧轮换造成的单 key 与池并存")
            entry.poolKeys = nil
            t.equal(entry.credentialKeys, ["sk-replacement-source3333", "sk-retained-source2222"], "旧 raw 池的轮换也不复活旧首 key")
            entry.format = "text"
            t.equal(entry.credentialKeys, ["sk-replacement-source3333"], "普通单凭据不从原文扩大认领")
        }
        h.runSuite("PoolAudit.legacy pool rotation normalizes ledger") { t in
            let env = try TestEnv("pool-audit-legacy-rotation")
            defer { env.cleanup() }
            let server = try MockHTTPServer()
            let base = "http://127.0.0.1:\(server.port)/v1"
            let first = "sk-legacy-first-fixture1111", second = "sk-legacy-second-fixture2222"
            let replacement = "sk-legacy-replacement-fixture3333"
            let core = Core()
            var record = HistoryTests.entry("pool-audit-legacy-rotate", ts: 1)
            record.format = "cpa-multikey"
            record.key = nil
            record.raw = ([base, first, second]).joined(separator: "\n")
            record.url = base
            record.models = ["gpt-test"]
            record.model = "gpt-test"
            record.targets = ["cpa"]
            record.cpaConfigPath = env.dir + "/cpa-config.yaml"
            env.write("cpa-config.yaml", "port: 8317\nopenai-compatibility:\n  - name: legacy\n    base-url: \(base)\n    api-key-entries:\n      - api-key: \(first)\n      - api-key: \(second)\n")
            try core.history.append(record)
            _ = try core.editEntry(entryIDPrefix: record.id, key: replacement, verify: false)
            let saved = core.history.find(idPrefix: record.id)!
            t.expect(saved.key == nil, "legacy 轮换不退化为单 key")
            t.equal(saved.poolKeys, [replacement, second], "legacy 轮换后持久化完整新池")
            env.write("cpa-config.yaml", "port: 8317\n")
            _ = core.replayArtifacts()
            let rebuilt = env.read("cpa-config.yaml")
            t.expect(rebuilt.contains(replacement) && rebuilt.contains(second) && !rebuilt.contains(first), "重放准确恢复当前池")
            _ = try core.delete(entryIDPrefix: record.id)
            let deleted = env.read("cpa-config.yaml")
            t.expect(!deleted.contains(replacement) && !deleted.contains(second), "删除清理完整重放池")
        }
        h.runSuite("PoolAudit.add refuses pool overwrite and partial overlap") { t in
            let env = try TestEnv("pool-audit-add-overlap")
            defer { env.cleanup() }
            let core = Core()
            let first = "sk-add-first-fixture1111", second = "sk-add-second-fixture2222"
            let fresh = "sk-add-fresh-fixture3333", base = "http://127.0.0.1:9/v1"
            var record = HistoryTests.entry("pool-audit-add-existing", ts: 1)
            record.format = "cpa-multikey"
            record.key = nil
            record.poolKeys = [first, second]
            record.url = base
            record.targets = ["cpa"]
            record.cpaConfigPath = env.dir + "/cpa-config.yaml"
            try core.history.append(record)
            let initialConfig = "port: 8317\n"
            env.write("cpa-config.yaml", initialConfig)
            for raw in ["\(base)\n\(second)", "\(base)\n\(fresh)\n\(second)", "\(base)\n\(first)\n\(second)"] {
                do {
                    _ = try core.add(raw: raw, ccOverride: false, cpaOverride: true, dshOverride: false, force: true)
                    t.expect(false, "重复池凭据应在探测写入前拒绝")
                } catch {
                    t.expect(error is ParseError, "返回可显示的凭据重复错误")
                }
            }
            let saved = core.history.find(idPrefix: record.id)!
            t.expect(saved.key == nil && saved.poolKeys == [first, second], "单 key 重导入不能覆盖完整池")
            t.equal(env.read("cpa-config.yaml"), initialConfig, "拒绝重叠时不触碰配置")
        }
        h.runSuite("PoolAudit.concurrent import owns only one credential set") { t in
            let env = try TestEnv("pool-audit-raced-add")
            defer { env.cleanup() }
            let server = try MockHTTPServer()
            let base = "http://127.0.0.1:\(server.port)/v1"
            let first = "sk-raced-first-fixture1111", second = "sk-raced-second-fixture2222"
            env.write("cpa-config.yaml", "port: 8317\n")
            let core = Core()
            var winner = HistoryTests.entry("pool-audit-raced-winner", ts: 1)
            winner.key = nil
            winner.poolKeys = [second]
            winner.format = "cpa-multikey"
            winner.url = base
            winner.targets = ["cpa"]
            winner.cpaConfigPath = env.dir + "/cpa-config.yaml"
            var injected = false
            do {
                _ = try core.add(raw: "\(base)\n\(first)\n\(second)", ccOverride: false, cpaOverride: true, dshOverride: false, force: true) { models in
                    do { try HistoryStore().append(winner); injected = true }
                    catch { t.expect(false, "注入另一进程账本失败: \(error)") }
                    return models
                }
                t.expect(false, "原子去重拦截探测期间新增的池认领")
            } catch {
                t.expect(error is ParseError, "并发重叠报告重复凭据")
            }
            t.expect(injected, "竞争注入发生于探测后写入前")
            let saved = core.history.find(idPrefix: winner.id)!
            t.equal(saved.poolKeys, [second], "既有池不能被新导入覆盖")
            let config = env.read("cpa-config.yaml")
            t.expect(config.contains(second) && !config.contains(first), "回滚未认领成员并保留胜出者凭据")
            t.equal(core.history.snapshot().filter { $0.status == "active" && $0.credentialKeys.contains(second) }.count, 1,
                    "只有一个记录认领相同凭据")
        }
        h.runSuite("PoolAudit.feed tombstones precede same-batch new identities") { t in
            for reversed in [false, true] {
                let env = try TestEnv("pool-audit-feed-order-\(reversed)")
                defer { env.cleanup() }
                let core = Core()
                var local = HistoryTests.entry("pool-feed-order-\(reversed)", ts: 1)
                local.key = nil
                local.poolKeys = ["sk-order-fixture-\(reversed)-1111"]
                local.format = "cpa-multikey"
                local.targets = []
                try core.history.append(local)
                var tombstone = local
                tombstone.status = "deleted"
                tombstone.deletedAt = Date().timeIntervalSince1970
                var incoming = local
                incoming.id = "pool-feed-new-\(reversed)"
                let entries = reversed ? [incoming, tombstone] : [tombstone, incoming]
                let payload = LedgerPayload(schemaVersion: 1, exportedAt: Date().timeIntervalSince1970,
                                            appVersion: "fixture", entries: entries, switches: nil)
                let encrypted = try LedgerCrypto.seal(JSONEncoder().encode(payload), passphrase: "fixture-passphrase")
                _ = try core.importLedger(encrypted, passphrase: "fixture-passphrase", mode: .feed)
                t.equal(core.history.find(idPrefix: local.id)?.status, "deleted", "原记录接收墓碑")
                t.expect(core.history.find(idPrefix: incoming.id) == nil, "同批新 ID 不受顺序影响恢复 key")
            }
        }
        h.runSuite("PoolAudit.rotation preserves ownership of all pool keys") { t in
            let env = try TestEnv("pool-audit-rotation")
            defer { env.cleanup() }
            let server = try MockHTTPServer()
            let base = "http://127.0.0.1:\(server.port)/v1"
            let first = "sk-first-pool-fixture1111"
            let second = "sk-second-pool-fixture2222"
            let replacement = "sk-replacement-pool-fixture3333"
            env.write("cpa-config.yaml", """
            port: 8317
            openai-compatibility:
              - name: fixture-pool
                base-url: \(base)
                api-key-entries:
                  - api-key: \(first)
                  - api-key: \(second)
                models:
                  - name: gpt-test
                    alias: gpt-test
            """)
            let core = Core()
            var record = HistoryTests.entry("pool-audit-rotate", ts: 1)
            record.format = "cpa-multikey"
            record.key = nil
            record.poolKeys = [first, second]
            record.raw = ([base, first, second]).joined(separator: "\n")
            record.url = base
            record.models = ["gpt-test"]
            record.model = "gpt-test"
            record.targets = ["cpa"]
            record.cpaConfigPath = env.dir + "/cpa-config.yaml"
            try core.history.append(record)
            _ = try core.editEntry(entryIDPrefix: record.id, key: replacement, verify: false)
            let saved = core.history.find(idPrefix: record.id)!
            t.expect(saved.key == nil && saved.poolKeys == [replacement, second],
                     "轮换池首 key 后账本仍完整认领剩余凭据")
            t.expect(env.read("cpa-config.yaml").contains(replacement) && env.read("cpa-config.yaml").contains(second),
                     "CPA 池保留替换 key 和第二把 key")
            _ = try core.delete(entryIDPrefix: record.id)
            t.expect(!env.read("cpa-config.yaml").contains(second), "删除已轮换的池记录不能遗留第二把 key")
            t.expect(!env.read("cpa-config.yaml").contains(replacement), "新 key 已删除")
        }
        h.runSuite("PoolAudit.tombstones block pooled credentials under new ids") { t in
            for mode in [LedgerImportMode.migrate, .feed] {
                for incomingPool in [false, true] {
                    let env = try TestEnv("pool-audit-tombstone-\(mode)-\(incomingPool)")
                    defer { env.cleanup() }
                    env.write("cpa-config.yaml", "port: 8317\n")
                    let core = Core()
                    let suffix = "\(mode)-\(incomingPool)"
                    let blocked = "sk-deleted-pool-fixture-\(suffix)-1111"
                    var tombstone = HistoryTests.entry("deleted-pool-\(suffix)", ts: 1)
                    tombstone.format = "cpa-multikey"
                    tombstone.key = nil
                    tombstone.poolKeys = [blocked]
                    tombstone.raw = "https://pool.example/v1\n\(blocked)"
                    tombstone.url = "https://pool.example/v1"
                    tombstone.status = "deleted"
                    tombstone.targets = []
                    tombstone.deletedAt = Date().timeIntervalSince1970
                    try core.history.append(tombstone)
                    var incoming = tombstone
                    incoming.id = "incoming-pool-\(suffix)"
                    incoming.status = "active"
                    incoming.deletedAt = nil
                    incoming.targets = ["cpa"]
                    incoming.models = ["fixture-model"]
                    incoming.model = "fixture-model"
                    if !incomingPool {
                        incoming.key = blocked
                        incoming.poolKeys = nil
                        incoming.format = "text"
                    }
                    let payload = LedgerPayload(schemaVersion: 1, exportedAt: Date().timeIntervalSince1970,
                                                appVersion: "fixture", entries: [incoming], switches: nil)
                    let encrypted = try LedgerCrypto.seal(JSONEncoder().encode(payload), passphrase: "fixture-passphrase")
                    _ = try core.importLedger(encrypted, passphrase: "fixture-passphrase", mode: mode)
                    t.expect(core.history.find(idPrefix: incoming.id) == nil,
                             "\(mode) 墓碑拦截同凭据新 ID，incomingPool=\(incomingPool)")
                    _ = core.replayArtifacts()
                    t.expect(!env.read("cpa-config.yaml").contains(blocked),
                             "\(mode) 重放不得恢复墓碑内的 pool key，incomingPool=\(incomingPool)")
                }
            }
        }
        h.runSuite("PoolAudit.history duplicate protection covers pool members") { t in
            let env = try TestEnv("pool-audit-history-dedup")
            defer { env.cleanup() }
            let store = HistoryStore()
            let first = "sk-duplicate-pool-fixture1111"
            var pooled = HistoryTests.entry("existing-pool", ts: 1)
            pooled.key = nil
            pooled.poolKeys = [first]
            pooled.format = "cpa-multikey"
            try store.append(pooled)
            t.equal(store.findActiveByKey(first)?.id, pooled.id, "单凭据查询能找到池内凭据")
            var single = HistoryTests.entry("incoming-single", ts: 2)
            single.key = first
            let duplicate = try store.appendDedupByKey(single)
            t.equal(duplicate?.id, pooled.id, "原子去重覆盖池内凭据")
            t.equal(store.snapshot().count, 1, "同一凭据只认领一次")
        }
    }
}
