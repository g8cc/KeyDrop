import Foundation
import KeyDropCore

enum MagpieTests {
    static func run(_ h: Harness) {
        h.runSuite("Magpie.Audit.重复导入账本失败不能报告成功") { t in
            let env = try TestEnv("magpie-audit-duplicate"); defer { env.cleanup() }
            let server = try MockHTTPServer(mode: .magpie)
            server.magpiePublicShape = true
            Prefs.shared.magpieWebLink = "http://127.0.0.1:\(server.port)/?k=test"
            let core = Core()
            let raw = "https://repeat.test/v1\nsk-repeat-fixture111111"
            func add(_ model: String) throws -> AddOutcome {
                try core.add(raw: raw, ccOverride: false, grokOverride: false, cpaOverride: false,
                             dshOverride: false, magpieOverride: true, models: [model], force: true)
            }
            let original = try add("gpt-old")
            server.magpieAfterSave = { env.write("home/history.json", "broken ledger") }
            let result = try add("gpt-new")
            t.expect(!result.ok, "已回滚的重复导入不得显示成功")
            t.equal(result.entry.models, ["gpt-old"], "返回仍生效的原记录")
            t.equal(server.magpieProviders.first?["models"] as? [String], ["gpt-old"], "原配置恢复")
            t.equal(core.history.find(idPrefix: original.entry.id)?.models, ["gpt-old"], "内存账本保留原模型")
            t.equal(env.read("home/history.json"), "broken ledger", "损坏文件保留")
        }

        h.runSuite("Magpie.Audit.远端密钥轮换独立核验") { t in
            let env = try TestEnv("magpie-audit-key"); defer { env.cleanup() }
            let server = try MockHTTPServer(mode: .magpie)
            server.magpiePublicShape = true
            Prefs.shared.magpieWebLink = "http://127.0.0.1:\(server.port)/?k=test"
            let id = "12345678-aaaa-bbbb-cccc-dddddddddddd"
            let base = "https://relay.test/v1"
            let original = "sk-x-original-same", replacement = "sk-x-replaced-same"
            _ = try MagpieWriter.sync(providerID: id, baseURL: base, key: original, models: ["gpt-a"])
            server.magpieIgnoreSave = true
            do {
                _ = try MagpieWriter.sync(providerID: id, baseURL: base, key: replacement, models: ["gpt-a"])
                t.expect(false, "前后掩码一样但实际未换 key，不得报告成功")
            } catch { t.contains(error.localizedDescription, "未确认", "读回报告配置不符") }
            t.equal(server.magpieProviders.first?["key"] as? String, original, "未覆盖原密钥")
            t.expect(server.magpieSeen.contains("POST /api/provider/key HTTP/1.1"), "通过独立接口核验实际密钥")
            server.magpieIgnoreSave = false
            _ = try MagpieWriter.sync(providerID: id, baseURL: base, key: replacement, models: ["gpt-a"])
            t.equal(server.magpieProviders.first?["key"] as? String, replacement, "实际轮换后可以成功")
        }

        h.runSuite("Magpie.Audit.偏好保存失败保留已提交导入") { t in
            let env = try TestEnv("magpie-audit-prefs"); defer { env.cleanup() }
            let server = try MockHTTPServer(mode: .magpie)
            Prefs.shared.magpieWebLink = "http://127.0.0.1:\(server.port)/?k=test"
            try FileManager.default.createDirectory(atPath: env.dir + "/home/prefs.json.keydrop-lock", withIntermediateDirectories: true)
            let core = Core()
            let result = try core.add(raw: "https://prefs.test/v1\nsk-magpie-prefs-fixture", ccOverride: false,
                                      grokOverride: false, cpaOverride: false, dshOverride: false, magpieOverride: true,
                                      models: ["gpt-fixture"], force: true)
            t.expect(result.ok, "偏好保存失败不撤销已经提交的目标与账本")
            t.equal(core.history.find(idPrefix: result.entry.id)?.models, ["gpt-fixture"], "导入账本仍然保存")
            t.equal(server.magpieProviders.count, 1, "已提交 provider 不回滚")
            t.expect(result.lines.contains { $0.contains("偏好保存失败") }, "提示独立的偏好保存错误")
        }

        h.runSuite("Magpie.Audit.旧记录新增目标账本失败清理产物") { t in
            let env = try TestEnv("magpie-audit-add-target"); defer { env.cleanup() }
            let server = try MockHTTPServer(mode: .magpie)
            server.magpiePublicShape = true
            Prefs.shared.magpieWebLink = "http://127.0.0.1:\(server.port)/?k=test"
            let core = Core()
            let raw = "https://target.test/v1\nsk-add-target-fixture111111"
            var original = HistoryTests.entry("abcdef12-aaaa-bbbb-cccc-dddddddddddd", ts: 1)
            original.raw = raw; original.key = "sk-add-target-fixture111111"
            original.url = "https://target.test/v1"; original.models = ["gpt-old"]; original.targets = []
            try core.history.append(original)
            server.magpieAfterSave = { env.write("home/history.json", "broken ledger") }
            let result = try core.add(raw: raw, ccOverride: false, grokOverride: false, cpaOverride: false,
                                      dshOverride: false, magpieOverride: true, models: ["gpt-new"], force: true)
            t.expect(!result.ok, "账本失败不得报告新增目标成功")
            t.equal(server.magpieProviders.count, 0, "新目标回滚，不留下无人认领的 provider")
            t.equal(core.history.find(idPrefix: original.id)?.targets, [], "原账本保留未绑定状态")
        }

        h.runSuite("Magpie.Audit.订阅缺少凭据时保留原归属") { t in
            let env = try TestEnv("magpie-audit-feed"); defer { env.cleanup() }
            let server = try MockHTTPServer(mode: .magpie)
            Prefs.shared.magpieWebLink = "http://127.0.0.1:\(server.port)/?k=test"
            let core = Core()
            let original = try core.add(raw: "https://feed.test/v1\nsk-feed-fixture111111", ccOverride: false,
                                        grokOverride: false, cpaOverride: false, dshOverride: false, magpieOverride: true,
                                        models: ["gpt-feed"], force: true).entry
            var incoming = original
            incoming.raw = ""; incoming.key = nil; incoming.poolKeys = []
            incoming.updatedAt = Date().timeIntervalSince1970 + 30
            incoming.magpieDestinationID = "remote-machine-marker"
            let payload = LedgerPayload(schemaVersion: LedgerCrypto.currentSchemaVersion, exportedAt: incoming.updatedAt!,
                                        appVersion: "test", entries: [incoming], switches: nil)
            let sealed = try LedgerCrypto.seal(JSONEncoder().encode(payload), passphrase: "feed-test-passphrase")
            do {
                _ = try core.importLedger(sealed, passphrase: "feed-test-passphrase", mode: .feed)
                t.expect(false, "不能接收缺少目标凭据的订阅")
            } catch { t.contains(error.localizedDescription, "Magpie", "说明无法更新的目标") }
            let saved = core.history.find(idPrefix: original.id)!
            t.equal(saved.key, original.key, "原记录保留重试所需的 key")
            t.equal(saved.magpieDestinationID, original.magpieDestinationID, "不能复制远端实例绑定")
        }
        h.runSuite("Magpie.Web 协议、真实响应与幂等") { t in
            let env = try TestEnv("magpie-web"); defer { env.cleanup() }
            let server = try MockHTTPServer(mode: .magpie)
            server.magpiePublicShape = true
            server.magpieExpectedKey = "key+with&reserved=chars"
            Prefs.shared.magpieWebLink = "http://127.0.0.1:\(server.port)/?k=key%2Bwith%26reserved%3Dchars"
            let id = "12345678-aaaa-bbbb-cccc-dddddddddddd"
            server.magpieProviders = [["id": "user-owned", "name": MagpieWriter.providerName(providerID: id, baseURL: "https://relay.test"),
                                      "key": "private", "models": ["keep"]]]
            _ = try MagpieWriter.sync(providerID: id, baseURL: "https://relay.test/api/v1/messages", key: "sk-first",
                                      models: ["claude-test"], apiStyle: "anthropic")
            t.equal(server.magpieProviders.count, 2, "同名用户行不覆盖")
            var saved = server.magpieProviders.last!
            t.equal(saved["id"] as? String, "keydrop-" + id, "完整 ID，避免 8 位前缀碰撞")
            t.equal(saved["anthropic"] as? String, "https://relay.test/api", "原生 Messages 根路径")
            t.equal(saved["chat"] as? String, "", "不虚报 Chat 能力")
            t.equal(saved["baseAPI"] as? String, "anthropic", "编辑器协议正确")
            saved["headers"] = ["X-User": "keep"]
            saved["fallback"] = ["user-owned/keep"]
            server.magpieProviders[1] = saved
            _ = try MagpieWriter.sync(providerID: id, baseURL: "https://relay.test/v1/responses", key: "sk-rotated",
                                      models: ["gpt-test"], apiStyle: "responses")
            saved = server.magpieProviders.last!
            t.equal(server.magpieProviders.count, 2, "更新仍为一条托管记录")
            t.equal(saved["key"] as? String, "sk-rotated", "轮换 key")
            t.equal(saved["responses"] as? String, "https://relay.test/v1", "Responses 挂载路径")
            t.equal(saved["anthropic"] as? String, "", "旧协议已清除")
            t.equal(saved["headers"] as? [String: String], ["X-User": "keep"], "保留附加 header")
            t.equal(saved["fallback"] as? [String], ["user-owned/keep"], "保留回退路由")
            t.expect(saved["balanceToken"] == nil, "不把展示对象回传为凭据")
            // 同前缀的另一条记录也独立维护。
            let other = "12345678-bbbb-cccc-dddd-eeeeeeeeeeee"
            _ = try MagpieWriter.sync(providerID: other, baseURL: "https://relay.test", key: "sk-other", models: ["glm-5.2"])
            t.equal(server.magpieProviders.count, 3, "同前缀 ID 不互相覆盖")
            server.magpieProviders[1]["name"] = "用户重命名"
            _ = try MagpieWriter.remove(providerID: id)
            t.equal(server.magpieProviders.count, 2, "重命名后仍可准确删除")
            t.expect(server.magpieProviders.contains { $0["id"] as? String == "user-owned" }, "保留同名用户 provider")
        }

        h.runSuite("Magpie.只导入 Magpie、编辑、刷新、重放与删除") { t in
            let env = try TestEnv("magpie-core"); defer { env.cleanup() }
            let server = try MockHTTPServer(mode: .magpie)
            let upstream = try MockHTTPServer(mode: .openAI, chatResponse: #"{"choices":[{"message":{"role":"assistant","content":"ok"}}]}"#)
            Prefs.shared.magpieWebLink = "http://127.0.0.1:\(server.port)/?k=test-key"
            Prefs.shared.useMagpie = true
            let core = Core()
            let raw = "http://127.0.0.1:\(upstream.port)/v1\nsk-magpie-pipeline111111"
            let first = try core.add(raw: raw, ccOverride: false, grokOverride: false, cpaOverride: false,
                                     dshOverride: false, models: ["glm-5.2"], force: true)
            t.expect(first.ok, "仅选 Magpie 也能导入")
            t.equal(first.entry.targets, ["magpie"], "账本目标完整")
            let again = try core.add(raw: raw, ccOverride: false, grokOverride: false, cpaOverride: false,
                                     dshOverride: false, magpieOverride: true, models: ["glm-5.2"], force: true)
            t.equal(again.entry.id, first.entry.id, "重复导入复用账本 ID")
            t.equal(server.magpieProviders.count, 1, "重复导入不增 provider")
            _ = try core.editEntry(entryIDPrefix: first.entry.id, models: ["gpt-5.6-sol"],
                                   key: "sk-magpie-rotated222222", verify: false)
            t.equal(server.magpieProviders.first?["key"] as? String, "sk-magpie-rotated222222", "编辑更新 Magpie key")
            t.equal(server.magpieProviders.first?["models"] as? [String], ["gpt-5.6-sol"], "编辑更新 Magpie 模型")
            _ = try core.refreshModels(entryIDPrefix: first.entry.id) { _ in ["glm-5.2", "gpt-5.6-sol"] }
            t.equal(Set(server.magpieProviders.first?["models"] as? [String] ?? []), Set(["glm-5.2", "gpt-5.6-sol"]), "刷新同步新选择")
            let count = server.magpieSaveCount
            _ = try core.refreshModels(entryIDPrefix: first.entry.id)
            t.equal(server.magpieSaveCount, count + 1, "模型无变化也可修复外部配置")
            server.magpieProviders = []
            _ = core.replayArtifacts()
            t.equal(server.magpieProviders.count, 1, "重放恢复 Magpie")
            _ = try core.delete(entryIDPrefix: first.entry.id)
            t.equal(server.magpieProviders.count, 0, "删除外部记录")
            t.equal(core.history.find(idPrefix: first.entry.id)?.status, "deleted", "账本同步删除")
        }

        h.runSuite("Magpie.失败不能假成功或丢失删除责任") { t in
            let env = try TestEnv("magpie-errors"); defer { env.cleanup() }
            let server = try MockHTTPServer(mode: .magpie)
            Prefs.shared.magpieWebLink = "http://127.0.0.1:\(server.port)/?k=good"
            server.magpieExpectedKey = "good"
            server.magpieFailSave = true
            let core = Core()
            let raw = "https://relay.test/v1\nsk-magpie-failure11111"
            let bad = try core.add(raw: raw, ccOverride: false, grokOverride: false, cpaOverride: false,
                                   dshOverride: false, magpieOverride: true, models: ["glm-5.2"], force: true)
            t.expect(!bad.ok && !bad.entry.targets.contains("magpie"), "写失败不得标已同步")
            t.expect(!core.history.snapshot().contains { $0.id == bad.entry.id }, "失败不进入账本")
            server.magpieFailSave = false
            let good = try core.add(raw: raw, ccOverride: false, grokOverride: false, cpaOverride: false,
                                    dshOverride: false, magpieOverride: true, models: ["glm-5.2"], force: true)
            server.magpieIgnoreSave = true
            do {
                _ = try MagpieWriter.sync(providerID: good.entry.id, baseURL: "https://relay.test/v1", key: "same", models: ["different"])
                t.expect(false, "HTTP 200 未实际更新应拒绝")
            } catch { t.contains(error.localizedDescription, "未确认", "核验发现假成功") }
            server.magpieIgnoreDelete = true
            do { _ = try core.delete(entryIDPrefix: good.entry.id) } catch { }
            t.expect(core.history.find(idPrefix: good.entry.id)?.targets.contains("magpie") == true, "未实际删除保留归属")
            Prefs.shared.magpieWebLink = "http://127.0.0.1:\(server.port)/?k=wrong"
            do {
                _ = try MagpieWriter.remove(providerID: good.entry.id)
                t.expect(false, "坏 key 不能复用旧 cookie")
            } catch { t.contains(error.localizedDescription, "登录失败", "凭据失效准确报错") }
            Prefs.shared.magpieWebLink = nil
            do { _ = try MagpieWriter.remove(providerID: good.entry.id); t.expect(false, "缺失连接不能静默当已删除") }
            catch { t.contains(error.localizedDescription, "未找到本机 Magpie") }
        }

        h.runSuite("Magpie.Web 保存后读回失败安全补偿并保留未决归属") { t in
            do {
                let env = try TestEnv("magpie-readback-compensate"); defer { env.cleanup() }
                let server = try MockHTTPServer(mode: .magpie)
                Prefs.shared.magpieWebLink = "http://127.0.0.1:\(server.port)/?k=test"
                server.magpieFailProviderListsAfterSave = 1
                let core = Core()
                let clean = try core.add(raw: "https://relay.test/v1\nsk-magpie-readback-clean", ccOverride: false,
                                         grokOverride: false, cpaOverride: false, dshOverride: false,
                                         magpieOverride: true, models: ["glm-5.2"], force: true)
                t.expect(!clean.ok, "读回失败不能报告导入成功")
                t.equal(server.magpieProviders.count, 0, "凭据与模型精确匹配后安全补偿删除新 provider")
                t.expect(core.history.find(idPrefix: clean.entry.id) == nil, "已确认删除后无需创建清理账本")

                let env2 = try TestEnv("magpie-readback-pending"); defer { env2.cleanup() }
                let server2 = try MockHTTPServer(mode: .magpie)
                Prefs.shared.magpieWebLink = "http://127.0.0.1:\(server2.port)/?k=test"
                server2.magpieFailProviderListsAfterSave = 2
                let core2 = Core()
                let pending = try core2.add(raw: "https://relay.test/v1\nsk-magpie-readback-pending", ccOverride: false,
                                            grokOverride: false, cpaOverride: false, dshOverride: false,
                                            magpieOverride: true, models: ["glm-5.2"], force: true)
                t.expect(!pending.ok, "未确认补偿不能报告可用")
                t.equal(pending.entry.status, "active", "未决 provider 保持可恢复的账本状态")
                t.expect(pending.entry.targets.contains("magpie"), "返回结果保留 Magpie 清理责任")
                let saved = core2.history.find(idPrefix: pending.entry.id)
                t.expect(saved?.targets.contains("magpie") == true, "账本持久化 Magpie 归属")
                t.expect(saved?.targetSyncErrors?["magpie"] != nil, "账本持久化同步错误")
                t.expect(saved?.status == "active", "未决 provider 保留同步与删除入口")
                t.equal(server2.magpieProviders.count, 1, "模拟远端保存成功但清理确认失败")

                server2.magpieFailProviderListsAfterSave = 1
                do {
                    _ = try MagpieWriter.sync(providerID: pending.entry.id, baseURL: "https://relay.test/v1",
                                              key: "sk-magpie-updated-state", models: ["gpt-5.6-sol"],
                                              expectedDestinationID: pending.entry.magpieDestinationID)
                    t.expect(false, "已有 provider 读回失败必须报告未确认")
                } catch let failure as MagpieWriter.SyncFailure {
                    t.expect(failure.providerMayExist, "更新失败保留 provider 归属")
                } catch { t.expect(false, "更新失败应携带残留状态: \(error.localizedDescription)") }
                t.equal(server2.magpieProviders.count, 1, "已有 provider 更新失败不得删除")
                t.equal(server2.magpieDeleteCount, 0, "已有 provider 更新路径不执行补偿删除")
                server2.magpieFailProviderListsAfterSave = 0
                _ = try core2.syncTarget(entryIDPrefix: pending.entry.id, target: "magpie")
                t.expect(core2.history.find(idPrefix: pending.entry.id)?.targetSyncErrors?["magpie"] == nil,
                         "公共重试入口可修复未决 provider")
                _ = try core2.delete(entryIDPrefix: pending.entry.id)
                t.equal(server2.magpieProviders.count, 0, "公共删除入口可清理未决 provider")

                let env3 = try TestEnv("magpie-sync-target-pending"); defer { env3.cleanup() }
                let server3 = try MockHTTPServer(mode: .magpie)
                Prefs.shared.magpieWebLink = "http://127.0.0.1:\(server3.port)/?k=test"
                let core3 = Core()
                let seeded = try core3.add(raw: "https://relay.test/v1\nsk-magpie-sync-target", ccOverride: false,
                                           grokOverride: false, cpaOverride: false, dshOverride: false,
                                           magpieOverride: true, models: ["glm-5.2"], force: true)
                _ = try MagpieWriter.remove(providerID: seeded.entry.id,
                                            expectedDestinationID: seeded.entry.magpieDestinationID)
                var detached = core3.history.find(idPrefix: seeded.entry.id)!
                detached.targets.removeAll { $0 == "magpie" }
                detached.magpieDestinationID = nil
                detached.targetSyncErrors = nil
                try core3.history.update(detached)
                server3.magpieFailProviderListsAfterSave = 2
                do { _ = try core3.syncTarget(entryIDPrefix: seeded.entry.id, target: "magpie"); t.expect(false, "同步失败应抛出") }
                catch { t.contains(error.localizedDescription, "无法确认", "syncTarget 暴露未决补偿错误") }
                let targetSaved = core3.history.find(idPrefix: seeded.entry.id)
                t.expect(targetSaved?.targets.contains("magpie") == true, "syncTarget 失败仍记录清理责任")
                t.expect(targetSaved?.targetSyncErrors?["magpie"] != nil, "syncTarget 持久化同步错误")
                t.equal(server3.magpieProviders.count, 1, "syncTarget 注入保存后读回和补偿读回双失败")
            } catch { t.expect(false, "回归用例执行失败: \(error.localizedDescription)") }
        }

        h.runSuite("Magpie.本机 CLI 参数、核验与隔离") { t in
            let env = try TestEnv("magpie-cli"); defer { env.cleanup() }
            // 模拟官方 CLI 的参数边界；网络/真实 Magpie 另有本机端到端验证。
            env.write("magpie-cli", #"""
            #!/usr/bin/python3
            import os,sys,json,pathlib
            p=pathlib.Path(os.environ['XDG_CONFIG_HOME'])/'magpie'/'providers.json'
            p.parent.mkdir(parents=True,exist_ok=True)
            d=json.loads(p.read_text()) if p.exists() else {'providers':[],'sentinel':'keep'}
            rows=d['providers'] or []
            action=sys.argv[2]
            if action=='rm':
                rows=[r for r in rows if r['id']!=sys.argv[3]]
            else:
                values=dict(v.split('=',1) for v in sys.argv[4:])
                if action=='add':
                    row={'name':sys.argv[3]};rows.append(row)
                else: row=next(r for r in rows if r['id']==sys.argv[3])
                row.update(values);row['models']=values['models'].split(',')
            d['providers']=rows;p.write_text(json.dumps(d))
            """#)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: env.dir + "/magpie-cli")
            let id = "abcdef12-aaaa-bbbb-cccc-dddddddddddd"
            let secret = "sk-test&literal=$(do-not-run)"
            _ = try MagpieWriter.sync(providerID: id, baseURL: "https://relay.test/v1", key: secret, models: ["org/deepseek-v4"])
            let path = env.dir + "/config/magpie/providers.json"
            func read() throws -> [String: Any] { try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any] }
            var d = try read()
            var rows = d["providers"] as! [[String: Any]]
            t.equal(rows.first?["key"] as? String, secret, "key 作为独立参数，不经过 shell")
            rows[0]["headers"] = ["X-User": "keep"]
            d["providers"] = rows
            try JSONSerialization.data(withJSONObject: d).write(to: URL(fileURLWithPath: path))
            _ = try MagpieWriter.sync(providerID: id, baseURL: "https://relay.test", key: "sk-next", models: ["claude-test"], apiStyle: "anthropic")
            d = try read(); rows = d["providers"] as! [[String: Any]]
            t.equal(rows.count, 1, "CLI 幂等更新")
            t.equal(rows.first?["headers"] as? [String: String], ["X-User": "keep"], "CLI set 保留用户附加字段")
            t.equal(rows.first?["anthropic"] as? String, "https://relay.test", "CLI 原生协议")
            _ = try MagpieWriter.remove(providerID: id)
            d = try read()
            t.equal((d["providers"] as? [[String: Any]])?.count, 0, "CLI 删除读回验证")
            t.equal(d["sentinel"] as? String, "keep", "不覆盖配置其他字段")
            try Data("invalid JSON".utf8).write(to: URL(fileURLWithPath: path))
            do { _ = try MagpieWriter.sync(providerID: id, baseURL: "https://relay.test", key: "sk-next", models: ["glm-5.2"]); t.expect(false, "损坏文件拒绝写入") }
            catch { t.contains(error.localizedDescription, "无法读取") }
        }

        h.runSuite("Magpie.账本写失败回滚新产物") { t in
            let env = try TestEnv("magpie-rollback"); defer { env.cleanup() }
            let server = try MockHTTPServer(mode: .magpie)
            Prefs.shared.magpieWebLink = "http://127.0.0.1:\(server.port)/?k=test"
            // history.json 是目录，强制账本保存失败；Magpie API 本身仍可用。
            try FileManager.default.createDirectory(atPath: env.dir + "/home/history.json", withIntermediateDirectories: true)
            let outcome = try Core().add(raw: "https://rollback.test/v1\nsk-magpie-rollback11111", ccOverride: false,
                                         grokOverride: false, cpaOverride: false, dshOverride: false,
                                         magpieOverride: true, models: ["glm-5.2"], force: true)
            t.expect(!outcome.ok, "无法登记的导入不能报告成功")
            t.equal(server.magpieProviders.count, 0, "新建产物已回滚")
            t.expect(!outcome.entry.targets.contains("magpie"), "已回滚目标不保留成功标记")
        }

        h.runSuite("Magpie.订阅更新与墓碑传播") { t in
            let env = try TestEnv("magpie-feed"); defer { env.cleanup() }
            let server = try MockHTTPServer(mode: .magpie)
            Prefs.shared.magpieWebLink = "http://127.0.0.1:\(server.port)/?k=test"
            let core = Core()
            let added = try core.add(raw: "https://feed.test/v1\nsk-magpie-feed111111", ccOverride: false,
                                     grokOverride: false, cpaOverride: false, dshOverride: false,
                                     magpieOverride: true, models: ["glm-5.2"], force: true)
            var incoming = added.entry
            incoming.key = "sk-magpie-feed222222"
            incoming.models = ["claude-test"]; incoming.model = "claude-test"
            incoming.url = "https://feed-new.test/v1/messages"; incoming.apiStyle = "anthropic"
            incoming.targets = [] // 维护者没有本机的 Magpie 目标。
            incoming.updatedAt = Date().timeIntervalSince1970 + 60
            func feed(_ entry: HistoryEntry) throws {
                let payload = LedgerPayload(schemaVersion: LedgerCrypto.currentSchemaVersion,
                                            exportedAt: Date().timeIntervalSince1970, appVersion: "test", entries: [entry], switches: nil)
                let file = try LedgerCrypto.seal(JSONEncoder().encode(payload), passphrase: "magpie-feed-passphrase")
                _ = try core.importLedger(file, passphrase: "magpie-feed-passphrase", mode: .feed)
            }
            try feed(incoming)
            t.equal(server.magpieProviders.first?["key"] as? String, incoming.key, "订阅换 key 同步 Magpie")
            t.equal(server.magpieProviders.first?["models"] as? [String], ["claude-test"], "订阅更新模型")
            t.equal(server.magpieProviders.first?["anthropic"] as? String, "https://feed-new.test", "订阅更新地址和协议")
            t.expect(core.history.find(idPrefix: incoming.id)?.targets.contains("magpie") == true, "维护本机所有权")
            incoming.status = "deleted"; incoming.deletedAt = incoming.updatedAt
            try feed(incoming)
            t.equal(server.magpieProviders.count, 0, "远端墓碑清理本机 Magpie")
            t.equal(core.history.find(idPrefix: incoming.id)?.status, "deleted", "墓碑落盘")
        }

        h.runSuite("Magpie.偏好与旧账本兼容") { t in
            let env = try TestEnv("magpie-prefs"); defer { env.cleanup() }
            let prefs = Prefs.shared
            t.expect(!prefs.useMagpie, "默认关闭，旧用户导入不新增目标")
            prefs.useMagpie = true
            try prefs.save()
            let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: env.dir + "/home/prefs.json"))) as! [String: Any]
            t.equal(obj["useMagpie"] as? Bool, true, "持久化开关")
            let old = Data(#"{"useCC":true,"useGrok":false,"useCPA":false,"useDSH":false,"cpaResident":false}"#.utf8)
            let snapshot = try JSONDecoder().decode(LedgerPayload.SwitchSnapshot.self, from: old)
            t.expect(snapshot.useMagpie == nil, "旧账本缺少新字段仍可解码")
            let core = Core()
            let sealed = try core.exportLedger(passphrase: "magpie-test-passphrase")
            let payload = try JSONDecoder().decode(LedgerPayload.self, from: LedgerCrypto.open(sealed, passphrase: "magpie-test-passphrase"))
            t.equal(payload.switches?.useMagpie, true, "新账本携带开关")
            prefs.useMagpie = false
            _ = try core.importLedger(sealed, passphrase: "magpie-test-passphrase")
            t.expect(prefs.useMagpie, "迁移还原开关")
            t.expect(MagpieWriter.parseWebLink("https://example.test/?k=ok") != nil, "有效 Web 链接")
            t.expect(MagpieWriter.parseWebLink("file:///tmp/?k=key") == nil, "拒绝非 HTTP")
            t.expect(MagpieWriter.parseWebLink("http://host/") == nil, "Web 链接缺 key 不接受")
        }
    }
}
