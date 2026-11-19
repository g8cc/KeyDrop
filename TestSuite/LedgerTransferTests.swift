import Foundation
import KeyDropCore

/// 账本迁移:加密导出/导入 + 产物重放
/// 设计:只同步账本(源),产物(cc-switch/CPA/DSH/Grok)在新机器由
/// replayArtifacts 按各条目的 targets 重放 —— 账本是源,产物是派生。
enum LedgerTransferTests {
    static func run(_ h: Harness) {
        h.runSuite("LedgerTransfer.feed retains omitted model selections") { t in
            let env = try TestEnv("ledger-feed-omitted-models")
            defer { env.cleanup() }
            let core = Core()
            var record = HistoryTests.entry("feed-omitted-models", ts: 1)
            record.models = ["grok-fixture"]
            record.model = "grok-fixture"
            record.targets = ["grok"]
            record.grokConfigPath = env.dir + "/grok.toml"
            _ = try GrokBuildWriter(configPath: record.grokConfigPath)
                .add(baseURL: record.url!, key: record.key!, models: record.models!)
            try core.history.append(record)
            var remote = record
            remote.models = nil
            remote.model = nil
            remote.name = "New name"
            remote.updatedAt = Date().timeIntervalSince1970 + 100
            let payload = LedgerPayload(schemaVersion: 1, exportedAt: remote.updatedAt!, appVersion: "legacy",
                                        entries: [remote], switches: nil)
            let encrypted = try LedgerCrypto.seal(JSONEncoder().encode(payload), passphrase: "fixture-passphrase")
            _ = try core.importLedger(encrypted, passphrase: "fixture-passphrase", mode: .feed)
            let saved = core.history.find(idPrefix: record.id)
            t.equal(saved?.models, record.models, "未提供模型字段时账本保留实际同步的模型列表")
            t.equal(saved?.model, record.model, "默认模型与配置一致")
            _ = try core.delete(entryIDPrefix: record.id)
            t.expect(!env.read("grok.toml").contains(record.key!), "删除仍可清理所绑定的模型")
        }
        h.runSuite("LedgerTransfer.pool credentials affect sync fingerprint") { t in
            var first = HistoryTests.entry("pool-fingerprint", ts: 1)
            first.key = nil
            first.format = "cpa-multikey"
            first.raw = "https://pool.example/v1\nsk-pool-original-fixture1111"
            var second = first
            second.raw = "https://pool.example/v1\nsk-pool-rotated-fixture2222"
            t.expect(LedgerCrypto.ledgerFingerprint([first]) != LedgerCrypto.ledgerFingerprint([second]),
                     "只有多 key 凭据改变也必须触发自动同步")
            first.poolKeys = ["sk-pool-original-fixture1111"]
            second = first
            second.poolKeys = ["sk-pool-rotated-fixture2222"]
            t.expect(LedgerCrypto.ledgerFingerprint([first]) != LedgerCrypto.ledgerFingerprint([second]),
                     "显式凭据池变化参与同步指纹")
        }
        h.runSuite("LedgerTransfer.replay does not resurrect rejected pool keys") { t in
            let env = try TestEnv("ledger-replay-filtered-pool")
            defer { env.cleanup() }
            let server = try MockHTTPServer(mode: .selectiveAuth)
            let base = "http://127.0.0.1:\(server.port)/v1"
            let accepted = "sk-accepted-pool-fixture1111"
            let rejected = "sk-invalid-pool-fixture2222"
            env.write("cpa-config.yaml", "port: 8317\n")
            Prefs.shared.cpaResident = false
            let core = Core()
            let outcome = try core.add(raw: "\(base)\n\(accepted)\n\(rejected)", ccOverride: false,
                                       grokOverride: false, cpaOverride: true, dshOverride: false,
                                       models: ["gpt-5.6-sol"], force: true)
            t.expect(!env.read("cpa-config.yaml").contains(rejected), "导入时已剔除认证失败的 key")
            _ = core.replayArtifacts()
            t.expect(!env.read("cpa-config.yaml").contains(rejected), "产物重放不得复活已剔除的 key")
            t.equal(core.history.find(idPrefix: outcome.entry.id)?.keyMasked, "1 个 key", "账本数量与实际接受的 key 一致")
            let saved = core.history.find(idPrefix: outcome.entry.id)!
            t.equal(saved.poolKeys, [accepted], "实际接受的凭据持久化到独立字段")
            let decoded = try JSONDecoder().decode(HistoryEntry.self, from: JSONEncoder().encode(saved))
            t.equal(decoded.poolKeys, [accepted], "导出后仍保留筛选结果")
            var legacy = saved
            legacy.poolKeys = nil
            try core.history.updateAll([legacy])
            _ = core.replayArtifacts()
            t.expect(!env.read("cpa-config.yaml").contains(rejected), "旧账本重放重新认证，不复活被拒绝的 key")
            t.equal(core.history.find(idPrefix: saved.id)?.poolKeys, [accepted], "旧账本重放后保存认证结果")
            let requests = server.countRequests("/v1/models")
            _ = core.replayArtifacts()
            t.equal(server.countRequests("/v1/models"), requests, "已有接受列表的重放不重复探测")
        }
        h.runSuite("LedgerTransfer.legacy replay keeps curated models") { t in
            for (index, mode) in [MockHTTPServer.Mode.selectiveAuth, .chat524].enumerated() {
                let env = try TestEnv("ledger-replay-legacy-models-\(index)")
                defer { env.cleanup() }
                let server = try MockHTTPServer(mode: mode)
                let base = "http://127.0.0.1:\(server.port)/v1"
                env.write("cpa-config.yaml", "port: 8317\n")
                Prefs.shared.cpaResident = false
                let core = Core()
                var record = HistoryTests.entry("legacy-curated-models-\(index)", ts: 1)
                record.format = "cpa-multikey"
                record.url = base
                record.raw = "\(base)\nsk-curated-pool-fixture1111\nsk-curated-pool-fixture2222"
                record.key = nil
                record.models = ["fixture-curated-model"]
                record.model = record.models?.first
                record.targets = ["cpa"]
                try core.history.append(record)
                _ = core.replayArtifacts()
                t.contains(env.read("cpa-config.yaml"), "fixture-curated-model",
                           "单模型探测或暂时网关故障时仍恢复账本中的模型选择")
                t.equal(core.history.find(idPrefix: record.id)?.poolKeys?.count, 2,
                        "非认证错误不丢弃原有凭据池")
            }
        }
        h.runSuite("LedgerTransfer.feed filters legacy key pools") { t in
            for scenario in 0..<3 {
                let hasModels = scenario == 0
                let env = try TestEnv("ledger-feed-legacy-pool-\(scenario)")
                defer { env.cleanup() }
                let server = try MockHTTPServer(mode: scenario == 2 ? .openAI : .selectiveAuth)
                let base = "http://127.0.0.1:\(server.port)/v1"
                let oldKey = "sk-previous-pool-fixture1111"
                let accepted = "sk-accepted-pool-fixture2222"
                let rejected = "sk-invalid-pool-fixture3333"
                let expectedKeys = scenario == 2 ? [accepted, "sk-second-pool-fixture4444"] : [accepted]
                env.write("cpa-config.yaml", "port: 8317\n")
                Prefs.shared.cpaResident = false
                let core = Core()
                var record = HistoryTests.entry("feed-legacy-pool-\(scenario)", ts: 1)
                record.format = "cpa-multikey"
                record.url = base
                record.raw = "\(base)\n\(oldKey)"
                record.key = nil
                record.poolKeys = [oldKey]
                record.models = hasModels ? ["fixture-selected-model"] : nil
                record.model = record.models?.first
                record.targets = ["cpa"]
                record.cpaConfigPath = env.dir + "/cpa-config.yaml"
                let modelYAML = hasModels ? "    models:\n      - name: fixture-selected-model\n        alias: \"\"\n" : ""
                env.write("cpa-config.yaml", """
                port: 8317
                openai-compatibility:
                  - name: pool
                    base-url: \(base)
                    api-key-entries:
                      - api-key: \(oldKey)
                """ + "\n" + modelYAML)
                try core.history.append(record)
                var remote = record
                remote.poolKeys = nil
                remote.raw = ([base] + (scenario == 2 ? expectedKeys : [rejected, accepted])).joined(separator: "\n")
                remote.updatedAt = Date().timeIntervalSince1970 + 100
                let payload = LedgerPayload(schemaVersion: 1, exportedAt: remote.updatedAt!,
                                            appVersion: "legacy", entries: [remote], switches: nil)
                let encrypted = try LedgerCrypto.seal(JSONEncoder().encode(payload), passphrase: "fixture-passphrase")
                _ = try core.importLedger(encrypted, passphrase: "fixture-passphrase", mode: .feed)
                let config = env.read("cpa-config.yaml")
                t.expect(config.contains(accepted) && !config.contains(rejected) && !config.contains(oldKey),
                         "旧版 feed 筛除无效凭据并删除已轮换的旧 key")
                let saved = core.history.find(idPrefix: record.id)!
                t.equal(saved.poolKeys, expectedKeys, "旧版 feed 保存已接受的凭据池")
                t.equal(core.extractKey(saved), accepted, "重测从已接受凭据池取 key，跳过 raw 中的首个失效 key")
                t.equal(saved.keyMasked, "\(expectedKeys.count) 个 key", "同步后的显示数量与实际凭据池一致")
                t.expect(!(saved.models ?? []).isEmpty && (saved.models ?? []).allSatisfy { config.contains($0) },
                         "既有选择或本次探测到的模型与账本一致")
            }
        }
        h.runSuite("LedgerTransfer.compaction clears persisted pool credentials") { t in
            let env = try TestEnv("ledger-compact-pool")
            defer { env.cleanup() }
            let core = Core()
            var deleted = HistoryTests.entry("deleted-pool", ts: 1)
            deleted.key = nil
            deleted.raw = "archived"
            deleted.format = "cpa-multikey"
            deleted.poolKeys = ["sk-deleted-pool-fixture1111"]
            deleted.status = "deleted"
            deleted.deletedAt = Date().timeIntervalSince1970 - 40 * 24 * 3600
            try core.history.append(deleted)
            var active = deleted
            active.id = "active-pool"
            active.status = "active"
            active.deletedAt = nil
            try core.history.append(active)
            _ = core.compactLedger()
            let saved = HistoryStore().find(idPrefix: deleted.id)!
            t.expect(saved.poolKeys == nil && core.extractKey(saved) == nil, "审计桩清除凭据池，不留下可恢复 key")
            t.equal(HistoryStore().find(idPrefix: active.id)?.poolKeys, active.poolKeys, "活跃凭据池保持完整")
        }
        h.runSuite("LedgerTransfer.CPA deletion stays within provider") { t in
            let env = try TestEnv("ledger-delete-shared-cpa-key")
            defer { env.cleanup() }
            let core = Core()
            env.write("cpa-config.yaml", """
            port: 8317
            claude-api-key:
              - api-key: sk-shared-fixture1111
                base-url: https://a.example/v1
              - api-key: sk-shared-fixture1111
                base-url: https://b.example/v1
            openai-compatibility:
              - name: a
                base-url: https://a.example/v1
                api-key-entries:
                  - api-key: sk-shared-fixture1111
              - name: b
                base-url: https://b.example/v1
                api-key-entries:
                  - api-key: sk-shared-fixture1111
            """)
            var record = HistoryTests.entry("delete-shared-cpa-key", ts: 1)
            record.url = "https://a.example/v1/"
            record.key = "sk-shared-fixture1111"
            record.targets = ["cpa"]
            record.cpaConfigPath = env.dir + "/cpa-config.yaml"
            try core.history.append(record)
            _ = try core.delete(entryIDPrefix: record.id)
            let config = env.read("cpa-config.yaml")
            t.expect(!config.contains("https://a.example/v1"), "清理目标地址的所有配置副本")
            t.equal(config.components(separatedBy: "https://b.example/v1").count - 1, 2, "保留相同 key 在其他地址的配置")
            t.equal(config.components(separatedBy: "sk-shared-fixture1111").count - 1, 2, "其他 provider 凭据不被误删")
        }
        h.runSuite("LedgerTransfer.feed retries CPA credential updates") { t in
            let env = try TestEnv("ledger-feed-cpa-retry")
            defer { env.cleanup() }
            let core = Core()
            var record = HistoryTests.entry("feed-cpa-only", ts: 1)
            record.targets = ["cpa"]
            record.key = "sk-feed-old-fixture1111"
            record.models = ["old-model"]
            record.cpaConfigPath = env.dir + "/cpa-config.yaml"
            env.write("cpa-config.yaml", """
            port: 8317
            openai-compatibility:
              - name: x.com
                base-url: https://x.com/v1
                api-key-entries:
                  - api-key: sk-feed-old-fixture1111
                models:
                  - name: old-model
                    alias: ""
            """)
            try core.history.append(record)
            let previousConfig = env.read("cpa-config.yaml")
            var remote = record
            remote.key = "sk-feed-new-fixture2222"
            remote.models = ["new-model"]
            remote.updatedAt = Date().timeIntervalSince1970 + 100
            remote.targets = [] // This target belongs to the receiving machine.
            let payload = LedgerPayload(schemaVersion: 1, exportedAt: remote.updatedAt!, appVersion: "test",
                                        entries: [remote], switches: nil)
            let encrypted = try LedgerCrypto.seal(JSONEncoder().encode(payload), passphrase: "passphrase-fixture")
            try FileManager.default.removeItem(atPath: record.cpaConfigPath!)
            try FileManager.default.createDirectory(atPath: record.cpaConfigPath!, withIntermediateDirectories: false)
            do {
                _ = try core.importLedger(encrypted, passphrase: "passphrase-fixture", mode: .feed)
                t.expect(false, "配置更新失败时同步必须返回失败")
            } catch {
                t.expect(true, "同步报告配置不可写")
            }
            t.equal(core.history.find(idPrefix: record.id)?.key, record.key, "失败时保留可重试的本机凭据")
            try FileManager.default.removeItem(atPath: record.cpaConfigPath!)
            env.write("cpa-config.yaml", previousConfig)
            _ = try core.importLedger(encrypted, passphrase: "passphrase-fixture", mode: .feed)
            let config = env.read("cpa-config.yaml")
            t.expect(!config.contains(record.key!) && config.contains(remote.key!), "CPA 独立目标更新 key 并清理旧 key")
            t.expect(config.contains("new-model") && !config.contains("old-model"), "同步目标模型与远端一致")
            t.equal(core.history.find(idPrefix: record.id)?.key, remote.key, "重试成功后保存新凭据")
        }
        h.runSuite("LedgerTransfer.replay saves bindings without DSH") { t in
            let env = try TestEnv("ledger-replay-no-dsh")
            defer { env.cleanup() }
            try CCSwitchWriterTests.createSchema(env)
            setenv("DSH_HOME", env.dir + "/absent-dsh", 1)
            defer { setenv("DSH_HOME", env.dir, 1) }
            let core = Core()
            var record = HistoryTests.entry("replay-without-dsh", ts: 1)
            record.models = ["deepseek-test"]
            record.targets = ["ccswitch-opencode", "dsh"]
            try core.history.append(record)
            let report = core.replayArtifacts().joined(separator: "\n")
            t.contains(report, "DSH: 本机未安装", "报告跳过未安装的 DSH")
            t.expect(core.history.find(idPrefix: record.id)?.ccProviderID != nil, "保存本轮已创建的 cc-switch 绑定")
            let again = core.replayArtifacts().joined(separator: "\n")
            t.contains(again, "cc-switch: 本机已有", "重试使用已保存的产物绑定")
        }

        h.runSuite("LedgerTransfer.feed preserves CPA key pools") { t in
            let env = try TestEnv("ledger-feed-cpa-key-pool")
            defer { env.cleanup() }
            let core = Core()
            let oldKey = "sk-pool-old-fixture1111"
            let retainedKey = "sk-pool-retained-fixture2222"
            let newKey = "sk-pool-new-fixture3333"
            var record = HistoryTests.entry("feed-cpa-key-pool", ts: 1)
            record.format = "cpa-multikey"
            record.url = "https://pool.example/v1"
            record.raw = "\(record.url!)\n\(oldKey)\n\(retainedKey)"
            record.poolKeys = [oldKey, retainedKey]
            record.key = nil
            record.models = ["old-model"]
            record.targets = ["cpa"]
            record.cpaConfigPath = env.dir + "/cpa-config.yaml"
            env.write("cpa-config.yaml", """
            port: 8317
            openai-compatibility:
              - name: pool
                base-url: https://pool.example/v1
                api-key-entries:
                  - api-key: \(oldKey)
                  - api-key: \(retainedKey)
                models:
                  - name: old-model
                    alias: ""
            """)
            try core.history.append(record)
            var remote = record
            remote.url = "https://pool.example/v1/"
            remote.raw = "\(remote.url!)\n\(retainedKey)\n\(newKey)"
            remote.poolKeys = [retainedKey, newKey]
            remote.models = ["new-model"]
            remote.updatedAt = Date().timeIntervalSince1970 + 100
            let payload = LedgerPayload(schemaVersion: 1, exportedAt: remote.updatedAt!, appVersion: "test",
                                        entries: [remote], switches: nil)
            let encrypted = try LedgerCrypto.seal(JSONEncoder().encode(payload), passphrase: "pool-passphrase")
            for _ in 0..<2 {
                _ = try core.importLedger(encrypted, passphrase: "pool-passphrase", mode: .feed)
            }
            let config = env.read("cpa-config.yaml")
            t.expect(!config.contains(oldKey), "删除多 key 池中已移除的凭据")
            t.equal(config.components(separatedBy: retainedKey).count - 1, 1, "等价地址保留已有 key，重复同步不重复追加")
            t.equal(config.components(separatedBy: newKey).count - 1, 1, "补入新 key，重复同步不重复追加")
            t.expect(config.contains("new-model") && !config.contains("old-model"), "多 key 池同步新模型")
            t.equal(core.history.find(idPrefix: record.id)?.raw, remote.raw, "成功后保存可恢复完整 key 池的源数据")
        }

        h.runSuite("LedgerTransfer.feed keeps Grok equivalent endpoints") { t in
            let env = try TestEnv("ledger-feed-grok-equivalent-url")
            defer { env.cleanup() }
            let core = Core()
            var record = HistoryTests.entry("feed-grok-equivalent-url", ts: 1)
            record.url = "https://grok.example/v1"
            record.models = ["grok-fixture"]
            record.targets = ["grok"]
            record.grokConfigPath = env.dir + "/grok.toml"
            _ = try GrokBuildWriter(configPath: record.grokConfigPath)
                .add(baseURL: record.url!, key: record.key!, models: record.models!)
            try core.history.append(record)
            var remote = record
            remote.url = record.url! + "/"
            remote.models = nil
            remote.model = "grok-fixture"
            remote.targets = []
            remote.updatedAt = Date().timeIntervalSince1970 + 100
            let payload = LedgerPayload(schemaVersion: 1, exportedAt: remote.updatedAt!, appVersion: "test",
                                        entries: [remote], switches: nil)
            let encrypted = try LedgerCrypto.seal(JSONEncoder().encode(payload), passphrase: "grok-passphrase")
            for _ in 0..<2 {
                _ = try core.importLedger(encrypted, passphrase: "grok-passphrase", mode: .feed)
            }
            let config = env.read("grok.toml")
            t.equal(config.components(separatedBy: "[model.").count - 1, 1, "地址仅尾斜杠变化不误删刚更新的模型表")
            t.contains(config, record.key!, "远端单 model 字段仍能更新本机 Grok 绑定")
        }

        h.runSuite("LedgerTransfer.replay restores CPA key pools") { t in
            let env = try TestEnv("ledger-replay-cpa-key-pool")
            defer { env.cleanup() }
            let core = Core()
            var record = HistoryTests.entry("replay-cpa-key-pool", ts: 1)
            record.format = "cpa-multikey"
            record.key = nil
            record.raw = "https://pool.example/v1\nsk-replay-pool-fixture1111\nsk-replay-pool-fixture2222"
            record.poolKeys = ["sk-replay-pool-fixture1111", "sk-replay-pool-fixture2222"]
            record.url = "https://pool.example/v1"
            record.model = "pool-model"
            record.models = nil
            record.targets = ["cpa"]
            record.cpaConfigPath = nil
            env.write("cpa-config.yaml", "port: 8317\n")
            try core.history.append(record)
            let report = core.replayArtifacts().joined(separator: "\n")
            let config = env.read("cpa-config.yaml")
            t.contains(report, "CPA:", "多 key 账本参与产物重放")
            t.contains(config, "sk-replay-pool-fixture1111", "重放第一把 key")
            t.contains(config, "sk-replay-pool-fixture2222", "重放第二把 key")
            t.contains(config, "pool-model", "兼容单 model 的旧账本")
            t.equal(core.history.find(idPrefix: record.id)?.cpaConfigPath, env.dir + "/cpa-config.yaml", "重放成功保存本机 CPA 绑定")
        }

        h.runSuite("LedgerTransfer.Grok key rotation cleans old credentials") { t in
            for migrate in [false, true] {
                let env = try TestEnv("ledger-grok-rotation-\(migrate)")
                defer { env.cleanup() }
                try CCSwitchWriterTests.createSchema(env)
                let server = try MockHTTPServer()
                let core = Core()
                let base = "http://127.0.0.1:\(server.port)/v1"
                let original = try core.add(raw: "\(base)\nsk-grok-old-fixture1111", ccOverride: false,
                                            grokOverride: true, cpaOverride: false, dshOverride: false,
                                            models: ["grok-4.6"], force: true)
                _ = try core.editEntry(entryIDPrefix: original.entry.id,
                                       models: migrate ? ["deepseek-test"] : nil,
                                       key: "sk-grok-new-fixture2222", verify: false)
                let config = env.read("grok-config.toml")
                t.expect(!config.contains("sk-grok-old-fixture1111"), "换 key 时清理旧 Grok 凭据")
                let saved = core.history.find(idPrefix: original.entry.id)
                t.equal(saved?.key, "sk-grok-new-fixture2222", "账本保存已验证的新凭据")
                if migrate {
                    t.expect(saved?.targets.contains("grok") == false && !config.contains("[model."), "迁移后清理旧 Grok 模型")
                } else {
                    t.equal(config.components(separatedBy: "[model.").count - 1, 1, "原地轮换不生成重复模型表")
                }
            }
        }
        h.runSuite("LedgerTransfer.加解密回环") { t in
            let payload = LedgerPayload(
                schemaVersion: LedgerCrypto.currentSchemaVersion,
                exportedAt: 12345, appVersion: "test",
                entries: [], switches: nil)
            let data = try! JSONEncoder().encode(payload)
            let sealed = try! LedgerCrypto.seal(data, passphrase: "passphrase-12345")
            let opened = try! LedgerCrypto.open(sealed, passphrase: "passphrase-12345")
            t.equal(opened, data, "加解密回环一致")
            t.expect((try? LedgerCrypto.open(sealed, passphrase: "wrong-pass-1")) == nil, "错误口令解密失败")
            t.expect((try? LedgerCrypto.seal(data, passphrase: "short")) == nil, "短口令拒绝")
        }

        h.runSuite("LedgerTransfer.schema 拒绝") { t in
            let env = try! TestEnv("ltx-schema")
            defer { env.cleanup() }
            try! CCSwitchWriterTests.createSchema(env)
            let core = Core()
            let payload = LedgerPayload(
                schemaVersion: LedgerCrypto.currentSchemaVersion + 99,
                exportedAt: 1, appVersion: "future", entries: [], switches: nil)
            let sealed = try! LedgerCrypto.seal(try! JSONEncoder().encode(payload), passphrase: "passphrase-12345")
            do {
                _ = try core.importLedger(sealed, passphrase: "passphrase-12345")
                t.expect(false, "[schema] 应拒绝比自己新的版本")
            } catch {
                t.contains(error.localizedDescription, "先升级", "[schema] 拒绝并提示升级")
            }
        }

        h.runSuite("LedgerTransfer.双机迁移与重放") { t in
            // 确定性设计:不经过 coreA/coreB 两条导入链(同进程共享 HistoryStore 单例,
            // 同 key 会互相污染)—— 导出文件直接构造载荷(等价机器 A 的密文),
            // 机器 B 预置条目用直接 append(显式 id,绕开 add() 的同 key 去重)。
            let env = try! TestEnv("ltx-b")
            defer { env.cleanup() }
            try! CCSwitchWriterTests.createSchema(env)
            env.write("cpa-config.yaml", "")
            setenv("KEYDROP_CPA_CONFIG", env.dir + "/cpa-config.yaml", 1)
            defer { setenv("KEYDROP_CPA_CONFIG", "", 1) }
            let core = Core()

            // 预置:本机已有同 key 条目(模拟用户在 B 机手动加过一把同 key)
            var seeded = HistoryEntry(
                id: "dddddddd-1111-2222-3333-444455556666", ts: 1, raw: "seed", format: "multiline",
                name: "本机手加", url: "https://seed.example.com/v1", model: nil,
                models: ["kimi-k3"], key: "sk-K2222222222222", keyMasked: "sk-K2…2222",
                targets: [], ccProviderID: nil, ccRenamedFrom: nil, ccRenamedTo: nil,
                cpaConfigPath: nil, status: "active")
            try! core.history.append(seeded)
            // 本机墓碑:曾导入过 K3 后删除(拉取不得复活这把 key)
            var tomb = HistoryEntry(
                id: "cccccccc-1111-2222-3333-444455556666", ts: 2, raw: "raw-tomb", format: "multiline",
                name: "已删除的 K3", url: "https://tomb.example.com/v1", model: nil,
                models: ["kimi-k3"], key: "sk-K3333333333333", keyMasked: "sk-K3…3333",
                targets: [], ccProviderID: nil, ccRenamedFrom: nil, ccRenamedTo: nil,
                cpaConfigPath: nil, status: "deleted")
            tomb.deletedAt = Date().timeIntervalSince1970
            try! core.history.append(tomb)

            // 机器 A 的导出载荷:e1(claude+ccswitch,全新)、e2(opencode+cpa,与预置同 key)
            let e1 = HistoryEntry(
                id: "eeeeeeee-1111-2222-3333-444455556666", ts: 100, raw: "raw-e1", format: "multiline",
                name: "e1-claude", url: "https://a.example.com/v1", model: "claude-sonnet-4-5",
                models: ["claude-sonnet-4-5"], key: "sk-K1111111111111", keyMasked: "sk-K1…1111",
                targets: ["ccswitch"], ccProviderID: nil, ccRenamedFrom: nil, ccRenamedTo: nil,
                cpaConfigPath: nil, status: "active")
            let e2 = HistoryEntry(
                id: "ffffffff-1111-2222-3333-444455556666", ts: 101, raw: "raw-e2", format: "multiline",
                name: "e2-opencode", url: "https://b.example.com/v1", model: "kimi-k3",
                models: ["kimi-k3"], key: "sk-K2222222222222", keyMasked: "sk-K2…2222",
                targets: ["cpa"], ccProviderID: nil, ccRenamedFrom: nil, ccRenamedTo: nil,
                cpaConfigPath: nil, status: "active")
            let e3 = HistoryEntry(
                id: "e3e3e3e3-1111-2222-3333-444455556666", ts: 102, raw: "raw-e3", format: "multiline",
                name: "e3-opencode", url: "https://c.example.com/v1", model: "kimi-k3",
                models: ["kimi-k3"], key: "sk-K3333333333333", keyMasked: "sk-K3…3333",
                targets: ["cpa"], ccProviderID: nil, ccRenamedFrom: nil, ccRenamedTo: nil,
                cpaConfigPath: nil, status: "active")
            let payload = LedgerPayload(
                schemaVersion: LedgerCrypto.currentSchemaVersion,
                exportedAt: Date().timeIntervalSince1970, appVersion: "test",
                entries: [e1, e2, e3],
                switches: .init(useCC: true, useGrok: true, useCPA: true, useDSH: true, cpaResident: true))
            let sealed = try! LedgerCrypto.seal(try! JSONEncoder().encode(payload), passphrase: "passphrase-12345")

            let report = try! core.importLedger(sealed, passphrase: "passphrase-12345")
            t.contains(report, "新增 1 条", "[导入] e1 补入")
            t.contains(report, "同 key 跳过 1 条", "[导入] e2 同 key 跳过")
            t.contains(report, "已删除跳过 1 条", "[导入/墓碑] 本地墓碑 K3 不搬运(载荷无已删条目)")
            t.expect(core.history.find(idPrefix: "e3e3e3e3") == nil, "[墓碑] K3 不复活入账本")
            let e1in = core.history.find(idPrefix: "eeeeeeee")
            let e1v = t.notNil(e1in, "[导入] e1 已入账本")
            if let e1v {
                t.equal(e1v.key, "sk-K1111111111111", "[导入] key 随账本迁移")
                t.equal(e1v.ccProviderID, nil, "[导入] 来源机器的产物绑定已清除")
            }
            // 目标开关按导出值应用
            t.equal(core.prefs.useCPA, true, "[导入] 开关已应用")

            // 产物重放:e1 → 本机 cc-switch 建 claude 行;幂等二次重放跳过
            let lines = core.replayArtifacts()
            t.contains(lines.joined(separator: "\n"), "已重放", "[重放] 播报")
            let row = try! DB(path: env.dir + "/cc-switch.db").scalar(
                "SELECT settings_config FROM providers WHERE settings_config LIKE '%sk-K1111111111111%'") ?? ""
            t.contains(row, "claude-sonnet-4-5", "[重放] 本机 cc-switch 行已重建")
            let e1row = core.history.find(idPrefix: "eeeeeeee")
            t.notNil(e1row?.ccProviderID, "[重放] 绑定本机 provider id")

            let lines2 = core.replayArtifacts()
            t.expect(!lines2.joined(separator: "\n").contains("已重放"), "[幂等] 二次重放全部跳过")
            t.contains(lines2.joined(separator: "\n"), "本机已有", "[幂等] 跳过原因可见")
        }

        h.runSuite("WebDAV.缺字段报错指明缺什么") { t in
            let env = try! TestEnv("webdav-missing")
            defer { env.cleanup() }
            let core = Core()
            Prefs.shared.webdavURL = "https://dav.example.com/dav/keydrop"
            Prefs.shared.webdavUser = "user@example.com"
            // 密码留空,只配其余三项
            defer {
                Prefs.shared.webdavURL = nil
                Prefs.shared.webdavUser = nil
                Prefs.shared.webdavPass = nil
                Prefs.shared.webdavExportPass = nil
            }
            do {
                _ = try core.webdavPush()
                t.expect(false, "缺密码应报错")
            } catch {
                t.contains(error.localizedDescription, "密码", "报错指明缺密码")
            }
        }

        h.runSuite("LedgerTransfer.remote tombstone clears DSH") { t in
            let env = try TestEnv("ledger-remote-tombstone-dsh")
            defer { env.cleanup() }
            let core = Core()
            let result = try core.addDSHOnly(raw: "https://example.com/v1\nsk-fixture-tombstone\n模型: deepseek-test")
            var remote = result.entry
            remote.status = "deleted"
            try core.history.update(result.entry)
            remote.deletedAt = 10 // A subsequent local health/ledger update is newer.
            let payload = LedgerPayload(schemaVersion: 1, exportedAt: 20, appVersion: "test",
                                        entries: [remote], switches: nil)
            let encrypted = try LedgerCrypto.seal(JSONEncoder().encode(payload), passphrase: "passphrase-fixture")
            let resultText = try core.importLedger(encrypted, passphrase: "passphrase-fixture", mode: .feed)
            t.contains(resultText, "墓碑传播 1 条", "有删除时间的远端墓碑可应用")
            t.equal(core.history.find(idPrefix: remote.id)?.status, "deleted", "账本标记删除")
            t.expect(!env.read("dsh-creds.yaml").contains("sk-fixture-tombstone"), "使用完整删除链路清理 DSH")
        }
        h.runSuite("WebDAV.地址校验") { t in
            let env = try TestEnv("webdav-reject-invalid")
            defer { env.cleanup() }
            Prefs.shared.webdavUser = "fixture"
            Prefs.shared.webdavPass = "fixture"
            Prefs.shared.webdavExportPass = "passphrase-fixture"
            for address in ["ftp://example.com/", "https:/missing-host", "https://example.com/dav?query=1"] {
                Prefs.shared.webdavURL = address
                for pull in [false, true] {
                    do {
                        _ = try pull ? Core().webdavPull(replay: false) : Core().webdavPush()
                        t.expect(false, "非法地址必须返回错误")
                    } catch {
                        t.contains(error.localizedDescription, "URL 无效", "非法地址给出诊断")
                    }
                }
            }
        }
        h.runSuite("WebDAV.推送拉取回环") { t in
            guard let server = try? MockHTTPServer(mode: .webdav) else {
                t.expect(false, "mock 启动失败")
                return
            }
            let env = try! TestEnv("webdav-sync")
            defer { env.cleanup() }
            try! CCSwitchWriterTests.createSchema(env)
            let core = Core()
            let r1 = try! core.add(raw: "https://a.example.com/v1 sk-K7777777777777",
                                   ccOverride: true, cpaOverride: false, dshOverride: false,
                                   models: ["claude-sonnet-4-5"], force: true,
                                   appType: "claude", appTypeForced: true)
            Prefs.shared.webdavURL = "http://127.0.0.1:\(server.port)/dav/keydrop"
            Prefs.shared.webdavUser = "user"
            Prefs.shared.webdavPass = "pass"
            Prefs.shared.webdavExportPass = "passphrase-12345"
            defer {
                Prefs.shared.webdavURL = nil
                Prefs.shared.webdavUser = nil
                Prefs.shared.webdavPass = nil
                Prefs.shared.webdavExportPass = nil
            }

            let pushMsg = try! core.webdavPush()
            t.contains(pushMsg, "已推送", "[推送] 播报")
            server.mgmtLock.lock()
            let storedCount = server.davStore.count
            let storedBody = server.davStore["/dav/keydrop/KeyDrop-ledger.keydrop"] ?? Data()
            server.mgmtLock.unlock()
            t.equal(storedCount, 1, "[推送] 远端存了一份快照")
            t.expect(storedBody.contains("sk-K7777777777777".data(using: .utf8)!) == false,
                     "[推送] 远端是密文(不含明文 key)")

            // 第二台设备更新远端版本，本机不得覆盖。
            server.mgmtLock.lock()
            server.davRevision += 1
            server.mgmtLock.unlock()
            do {
                _ = try core.webdavPush()
                t.expect(false, "过期 ETag 不能覆盖远端")
            } catch {
                t.contains(error.localizedDescription, "先拉取", "给出恢复步骤")
            }
            server.mgmtLock.lock()
            let pushesAfterConflict = server.davPushCount
            server.mgmtLock.unlock()
            t.equal(pushesAfterConflict, 1, "冲突推送不写入")
            _ = try core.webdavPull(replay: false)
            let retry = try core.webdavPush()
            t.contains(retry, "已推送", "拉取新版本后可推送")

            // 本机删除 r1(墓碑)→ 拉取不得复活(同 id 已存在跳过,保持已删除)
            if var e = core.history.find(idPrefix: r1.entry.id) {
                e.status = "deleted"
                e.deletedAt = Date().timeIntervalSince1970
                e.targets = []
                try! core.history.update(e)
            }
            let pullMsg = try! core.webdavPull(replay: false)
            t.contains(pullMsg, "本机较新保留 1 条", "[墓碑] 本机删除的 key 不复活(较新保留)")
            let still = core.history.find(idPrefix: r1.entry.id)
            t.equal(still?.status, "deleted", "[墓碑] 保持已删除")
        }
    }
}
