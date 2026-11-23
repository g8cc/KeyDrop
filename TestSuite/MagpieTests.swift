import Foundation
import KeyDropCore

enum MagpieTests {
    static func run(_ h: Harness) {
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
