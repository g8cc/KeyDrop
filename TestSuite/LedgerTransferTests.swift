import Foundation
import KeyDropCore

/// 账本迁移:加密导出/导入 + 产物重放
/// 设计:只同步账本(源),产物(cc-switch/CPA/DSH/Grok)在新机器由
/// replayArtifacts 按各条目的 targets 重放 —— 账本是源,产物是派生。
enum LedgerTransferTests {
    static func run(_ h: Harness) {
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

            // 本机删除 r1(墓碑)→ 拉取不得复活(同 id 已存在跳过,保持已删除)
            if var e = core.history.find(idPrefix: r1.entry.id) {
                e.status = "deleted"
                e.deletedAt = Date().timeIntervalSince1970
                e.targets = []
                try! core.history.update(e)
            }
            let pullMsg = try! core.webdavPull(replay: false)
            t.contains(pullMsg, "已存在跳过 1 条", "[墓碑] 本机已删除的同 id 条目不复活")
            let still = core.history.find(idPrefix: r1.entry.id)
            t.equal(still?.status, "deleted", "[墓碑] 保持已删除")
        }
    }
}
