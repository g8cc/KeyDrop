import Foundation
import KeyDropCore

/// Real HTTP fixtures: protocol paths and request bodies matter, not just status codes.
final class CompletenessProbeServer {
    let listener: TCPServer
    let responsesOnly: Bool
    let catalog: Bool
    let response: String
    let limitedKeys: Set<String>
    private let lock = NSLock()
    private var paths: [String] = []
    private var chatKeys: [String] = []
    var base: String { "http://127.0.0.1:\(listener.port)/v1" }
    static let model = "gpt-responses-fixture"
    static let validResponse = #"{"object":"response","status":"completed","error":null,"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"fixture ok"}]}]}"#

    init(responsesOnly: Bool = true, catalog: Bool = true, response: String = validResponse, limitedKeys: Set<String> = []) throws {
        listener = try TCPServer()
        self.responsesOnly = responsesOnly; self.catalog = catalog; self.response = response
        self.limitedKeys = limitedKeys
        let listener = listener
        Thread.detachNewThread { [weak self] in
            while let client = listener.accept() {
                Thread.detachNewThread { [weak self] in self?.handle(client) }
            }
        }
    }

    func count(_ path: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return paths.filter { $0 == path }.count
    }

    func countKey(_ key: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return chatKeys.filter { $0 == key }.count
    }

    private func handle(_ client: SocketClient) {
        defer { client.close() }
        guard let request = client.readRequest() else { return }
        let first = request.components(separatedBy: "\r\n").first?.split(separator: " ") ?? []
        guard first.count >= 2 else { return }
        let method = String(first[0]), path = String(first[1])
        lock.lock(); paths.append(path); lock.unlock()
        var status = 404, body = #"{"error":{"message":"route not found"}}"#, extraHeaders = ""
        if method == "GET", path == "/v1/models", catalog {
            status = 200; body = "{\"data\":[{\"id\":\"\(Self.model)\"}]}"
        } else if method == "POST", path == "/v1/responses" || (!responsesOnly && path == "/v1/chat/completions") {
            let authorization = request.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("authorization:") } ?? ""
            let key = authorization.components(separatedBy: " ").last ?? ""
            lock.lock(); chatKeys.append(key); lock.unlock()
            var payload = request.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
            let header = request.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") } ?? ""
            let length = Int(header.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
            if payload.utf8.count < length { payload += client.readBody(toLength: length - payload.utf8.count) }
            let object = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] ?? [:]
            if limitedKeys.contains(key) {
                status = 429; body = #"{"error":{"message":"rate limit reached"}}"#
                extraHeaders = "Retry-After: 86400\r\n"
            } else if path == "/v1/responses", object["input"] == nil || object["messages"] != nil || object["max_tokens"] != nil {
                status = 400; body = #"{"error":{"message":"Responses needs input and max_output_tokens"}}"#
            } else {
                status = 200; body = response
            }
        }
        client.write("HTTP/1.1 \(status) Fixture\r\n\(extraHeaders)Content-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)")
    }
}

enum CompletenessTests {
    static func run(_ h: Harness) {
        h.runSuite("Completeness.Responses discovery and persisted protocol") { t in
            let env = try TestEnv("completeness-responses"); defer { env.cleanup() }
            let server = try CompletenessProbeServer()
            let parsed = try Parser.parse(server.base + "/responses\nsk-responses-fixture111111")
            t.equal(parsed.url, server.base, "完整 Responses 地址应归一到版本根路径")
            let result = APITester.test(url: server.base, key: "sk-responses-fixture", timeout: 2)
            t.expect(result.ok && !result.reachabilityOnly, "Responses-only 目录必须能完成真实模型验证")
            t.equal(result.style, "responses", "持久化实际成功协议")
            t.equal(result.workingModels, [CompletenessProbeServer.model], "保留真实模型采样")
            let before = server.count("/v1/chat/completions")
            let known = APITester.test(url: server.base, key: "sk-responses-fixture", timeout: 2,
                                      preferredModel: CompletenessProbeServer.model, styleHint: "responses")
            t.expect(known.ok && known.style == "responses", "后续巡检沿用 Responses")
            t.equal(server.count("/v1/chat/completions"), before, "已知协议不重复试错")
            t.expect(APITester.testModelChat(base: server.base, key: "sk-responses-fixture",
                                            model: CompletenessProbeServer.model, timeout: 2, styleHint: "responses").ok,
                     "显式模型验证使用 Responses 请求体")
            let command = APITester.curlCommand(url: server.base, key: "placeholder", model: CompletenessProbeServer.model, styleHint: "responses")
            t.contains(command, "/responses", "复制命令对应保存协议")
            t.contains(command, "\"input\"", "复制命令包含 Responses 请求体")
        }
        h.runSuite("Completeness.Responses import without catalog lifecycle") { t in
            let env = try TestEnv("completeness-responses-pipeline"); defer { env.cleanup() }
            let upstream = try CompletenessProbeServer(catalog: false)
            let magpie = try MockHTTPServer(mode: .magpie)
            Prefs.shared.magpieWebLink = "http://127.0.0.1:\(magpie.port)/?k=fixture"
            let core = Core()
            let added = try core.add(raw: upstream.base + "/responses\nsk-responses-lifecycle111111", ccOverride: false,
                                     grokOverride: false, cpaOverride: false, dshOverride: false, magpieOverride: true,
                                     models: [CompletenessProbeServer.model])
            t.expect(added.ok, "无目录但显式模型可用时导入成功")
            t.equal(core.history.find(idPrefix: added.entry.id)?.apiStyle, "responses", "账本保存 Responses")
            t.equal(magpie.magpieProviders.first?["responses"] as? String, upstream.base, "Magpie 使用实际协议")
            _ = try core.editEntry(entryIDPrefix: added.entry.id, models: [CompletenessProbeServer.model])
            _ = try core.refreshModels(entryIDPrefix: added.entry.id)
            t.expect(core.history.find(idPrefix: added.entry.id)?.healthColor.ok == true, "编辑和刷新保持真实可用")
            _ = try core.delete(entryIDPrefix: added.entry.id)
            t.equal(magpie.magpieProviders.count, 0, "删除闭环")
        }
        h.runSuite("Completeness.Responses content and terminal failures") { t in
            let env = try TestEnv("completeness-responses-content"); defer { env.cleanup() }
            let delta = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"ok\"}\n\n"
            let cases: [(String, Bool)] = [
                (CompletenessProbeServer.validResponse, true),
                (delta + "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"error\":null}}\n\n", true),
                (#"{"object":"response","status":"completed","output":[]}"#, false),
                (#"{"object":"response","status":"failed","error":{"message":"bad"},"output":[]}"#, false),
                (delta + "data: {\"type\":\"response.failed\",\"response\":{\"status\":\"failed\",\"error\":{\"message\":\"bad\"}}}\n\n", false),
                (delta, false),
                ("data: {\"type\":\"response.created\",\"response\":{\"status\":\"in_progress\"}}\n\n", false)
            ]
            for (body, expected) in cases {
                let server = try CompletenessProbeServer(response: body)
                let result = APITester.testModelChat(base: server.base, key: "sk-response-validation", model: CompletenessProbeServer.model,
                                                    timeout: 2, styleHint: "responses")
                t.equal(result.ok, expected, "成功依赖有效输出且无后续错误")
            }
        }
        h.runSuite("Completeness.rotated credentials invalidate old model evidence") { t in
            let env = try TestEnv("completeness-rotation-evidence"); defer { env.cleanup() }
            let upstream = try CompletenessProbeServer(responsesOnly: false,
                response: #"{"choices":[{"message":{"content":"fixture ok"}}]}"#)
            let core = Core()
            var record = HistoryTests.entry("rotation-evidence", ts: 1)
            record.url = upstream.base; record.targets = []
            record.key = "sk-evidence-old111111"
            record.models = (0..<5).map { "gpt-evidence-\($0)" }; record.model = record.models?.first
            record.health = "ok"; record.healthAt = 1
            record.modelProbeLog = Dictionary(uniqueKeysWithValues: record.models!.map { ($0, [ProbePoint(t: 1, ms: 1, ok: true)]) })
            try core.history.append(record)
            _ = try core.editEntry(entryIDPrefix: record.id, key: "sk-evidence-new222222")
            let saved = core.history.find(idPrefix: record.id)!
            t.equal(saved.modelStatus.passed, 4, "新 key 只验证四个模型，不能复用第五个的旧成功")
            t.equal(saved.modelStatus.untested, 1, "未轮到的模型回到待验证")
            t.expect(!saved.healthColor.ok, "配置变化后的旧绿格不能证明当前全部可用")
            t.equal(saved.modelProbeLog?["gpt-evidence-4"]?.first?.t, 1, "历史轨迹仍保留")
        }
        h.runSuite("Completeness.Magpie destination switch preserves ownership") { t in
            let env = try TestEnv("completeness-magpie-destination"); defer { env.cleanup() }
            let first = try MockHTTPServer(mode: .magpie)
            let second = try MockHTTPServer(mode: .magpie)
            Prefs.shared.magpieWebLink = "http://127.0.0.1:\(first.port)/?k=first"
            let core = Core()
            let added = try core.add(raw: "https://destination.test/v1\nsk-destination-fixture11111", ccOverride: false,
                                     grokOverride: false, cpaOverride: false, dshOverride: false, magpieOverride: true,
                                     models: ["gpt-fixture"], force: true)
            Prefs.shared.magpieWebLink = "http://127.0.0.1:\(second.port)/?k=second"
            do { _ = try core.syncTarget(entryIDPrefix: added.entry.id, target: "magpie"); t.expect(false, "目标切换不能静默改绑") } catch { }
            do { _ = try core.delete(entryIDPrefix: added.entry.id); t.expect(false, "不能把另一个实例中的不存在当删除成功") } catch { }
            t.equal(first.magpieProviders.count, 1, "原实例产物仍可追踪")
            t.equal(second.magpieProviders.count, 0, "不误写另一个实例")
            t.expect(core.history.find(idPrefix: added.entry.id)?.targets.contains("magpie") == true, "保留原清理责任")
            let replay = core.replayArtifacts().joined(separator: "\n")
            t.contains(replay, "实例已切换", "重放不能绕开实例绑定")
            t.equal(second.magpieProviders.count, 0, "重放也不误写另一个实例")
            Prefs.shared.magpieWebLink = "http://127.0.0.1:\(first.port)/?k=new-login-key"
            _ = try core.syncTarget(entryIDPrefix: added.entry.id, target: "magpie")
            _ = try core.delete(entryIDPrefix: added.entry.id)
            t.equal(first.magpieProviders.count, 0, "恢复原实例后仍能删除，换管理 key 不误判实例")
        }
        h.runSuite("Completeness.Magpie saved config survives CLI failure") { t in
            let env = try TestEnv("completeness-magpie-postwrite"); defer { env.cleanup() }
            env.write("magpie-cli", #"""
            #!/usr/bin/python3
            import os,sys,json,pathlib
            p=pathlib.Path(os.environ['XDG_CONFIG_HOME'])/'magpie'/'providers.json'
            p.parent.mkdir(parents=True,exist_ok=True)
            d=json.loads(p.read_text()) if p.exists() else {'providers':[]}
            rows=d['providers'] or []
            if sys.argv[2]=='rm':
                d['providers']=[r for r in rows if r['id']!=sys.argv[3]]
            else:
                values=dict(v.split('=',1) for v in sys.argv[4:])
                if sys.argv[2]=='add':
                    row={'name':sys.argv[3]}; rows.append(row)
                else: row=next(r for r in rows if r['id']==sys.argv[3])
                row.update(values);row['models']=values['models'].split(',');d['providers']=rows
            p.write_text(json.dumps(d))
            sys.exit(7)
            """#)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: env.dir + "/magpie-cli")
            let core = Core()
            let added = try core.add(raw: "https://postwrite.test/v1\nsk-postwrite-fixture111111", ccOverride: false,
                                     grokOverride: false, cpaOverride: false, dshOverride: false, magpieOverride: true,
                                     models: ["gpt-fixture"], force: true)
            t.expect(added.ok, "退出码失败但完整读回成功，应记账而不是留下孤儿")
            t.expect(core.history.find(idPrefix: added.entry.id)?.targets.contains("magpie") == true, "已写入产物有可追踪的账本归属")
            if added.ok {
                _ = try core.delete(entryIDPrefix: added.entry.id)
                t.equal(core.history.find(idPrefix: added.entry.id)?.status, "deleted", "已删除但退出码失败，以读回为准")
            }
        }
        h.runSuite("Completeness.Magpie sync failure excludes available and retry repairs") { t in
            let env = try TestEnv("completeness-magpie-sync-error"); defer { env.cleanup() }
            let upstream = try CompletenessProbeServer()
            let magpie = try MockHTTPServer(mode: .magpie)
            Prefs.shared.magpieWebLink = "http://127.0.0.1:\(magpie.port)/?k=fixture"
            let core = Core()
            let added = try core.add(raw: upstream.base + "\nsk-sync-error-fixture11111", ccOverride: false,
                                     grokOverride: false, cpaOverride: false, dshOverride: false, magpieOverride: true,
                                     models: [CompletenessProbeServer.model])
            magpie.magpieFailSave = true
            _ = try core.editEntry(entryIDPrefix: added.entry.id, key: "sk-sync-error-rotated2222")
            let saved = core.history.find(idPrefix: added.entry.id)!
            t.expect(!saved.healthColor.ok, "上游通过但目标同步失败不能显示为可用")
            t.contains(saved.availability.label, "同步失败", "明确说明失败环节")
            magpie.magpieFailSave = false
            _ = try core.syncTarget(entryIDPrefix: added.entry.id, target: "magpie")
            t.equal(magpie.magpieProviders.first?["key"] as? String, "sk-sync-error-rotated2222", "重试补齐真实配置")
            t.expect(core.history.find(idPrefix: added.entry.id)?.healthColor.ok == true, "修复后解除同步失败状态")
            magpie.magpieFailSave = true
            do { _ = try core.syncTarget(entryIDPrefix: added.entry.id, target: "magpie"); t.expect(false, "单目标失败应抛出") } catch { }
            t.expect(core.history.find(idPrefix: added.entry.id)?.healthColor.ok == false, "单目标同步也持久化失败状态")
        }
        h.runSuite("Completeness.Magpie edit ledger failure restores prior config") { t in
            let env = try TestEnv("completeness-magpie-edit-rollback"); defer { env.cleanup() }
            let magpie = try MockHTTPServer(mode: .magpie)
            Prefs.shared.magpieWebLink = "http://127.0.0.1:\(magpie.port)/?k=fixture"
            let core = Core()
            let added = try core.add(raw: "https://rollback.test/v1\nsk-edit-rollback-fixture1111", ccOverride: false,
                                     grokOverride: false, cpaOverride: false, dshOverride: false, magpieOverride: true,
                                     models: ["gpt-old-fixture"], force: true)
            magpie.magpieAfterSave = { env.write("home/history.json", "broken history") }
            do {
                _ = try core.editEntry(entryIDPrefix: added.entry.id, models: ["gpt-new-fixture"], verify: false)
                t.expect(false, "账本写失败不能返回成功")
            } catch { }
            t.equal(magpie.magpieProviders.first?["models"] as? [String], ["gpt-old-fixture"], "账本保存失败恢复外部原模型")
            t.equal(env.read("home/history.json"), "broken history", "保留损坏账本现场")
        }
        h.runSuite("Completeness.CPA model routing cannot certify whole credential pool") { t in
            var record = HistoryTests.entry("pool-scope", ts: 1)
            record.format = "cpa-multikey"; record.key = nil
            record.poolKeys = ["sk-first-fixture", "sk-second-fixture"]
            record.models = ["gpt-fixture"]; record.model = "gpt-fixture"
            record.targets = ["cpa"]; record.health = "ok"; record.healthAt = 1
            record.viaCPAOk = true; record.viaCPAAt = 1
            record.modelProbeLog = ["gpt-fixture": [ProbePoint(t: 1, ms: 1, ok: true, cpa: true)]]
            t.expect(!record.healthColor.ok, "只实测首个凭据不能把整个池标为通过")
            t.contains(record.availability.label, "凭据", "列表直接说明验证粒度")
        }
        h.runSuite("Completeness.pool rotates through every credential and recovers") { t in
            let env = try TestEnv("completeness-pool-rotation"); defer { env.cleanup() }
            let upstream = try MockHTTPServer(mode: .selectiveAuth)
            let core = Core()
            var record = HistoryTests.entry("pool-round-robin", ts: 1)
            record.url = "http://127.0.0.1:\(upstream.port)/v1"
            record.format = "cpa-multikey"; record.key = nil
            record.poolKeys = ["sk-pool-good111", "sk-pool-invalid222", "sk-pool-good333"]
            record.models = ["gpt-5.6-sol"]; record.model = record.models?.first
            record.targets = []; record.healthAt = nil
            try core.history.append(record)
            func scan() throws -> HistoryEntry {
                let done = DispatchSemaphore(value: 0)
                core.scanHealth(staleAfter: 0) { _ in done.signal() }
                t.expect(done.wait(timeout: .now() + 25) == .success, "池扫描完成")
                return core.history.find(idPrefix: record.id)!
            }
            _ = try scan()
            var saved = try scan()
            t.equal(saved.credentialStatus.passed, 2, "首个有效 key 之外也实际验证第三个")
            t.equal(saved.credentialStatus.failed, 1, "无效池成员被记录")
            t.expect(!saved.healthColor.ok, "部分有效不能整池标绿")
            saved.poolKeys = ["sk-pool-good111", "sk-pool-good222", "sk-pool-good333"]
            try core.history.update(saved)
            _ = try scan()
            saved = try scan()
            t.equal(saved.credentialStatus.passed, 3, "更换失效成员后逐轮恢复")
            t.expect(saved.healthColor.ok, "整池和模型均实测通过后可进入可用区")
            let loaded = HistoryStore().find(idPrefix: record.id)!
            t.equal(loaded.credentialStatus.passed, 3, "重启后保留验证范围")
        }
        h.runSuite("Completeness.pool cooldown keeps other credentials rotating without fake samples") { t in
            let env = try TestEnv("completeness-pool-cooldown"); defer { env.cleanup() }
            for mode in 0..<3 {
                let manual = mode != 0
                let keys = ["sk-cooled-primary", "sk-cooled-secondary", "sk-healthy-third"]
                let upstream = try CompletenessProbeServer(catalog: mode != 2, limitedKeys: Set(keys.prefix(2)))
                let core = Core()
                var record = HistoryTests.entry("pool-cooldown-\(mode)", ts: 1)
                record.url = upstream.base; record.apiStyle = "responses"
                record.format = "cpa-multikey"; record.key = nil; record.poolKeys = keys
                record.models = [CompletenessProbeServer.model]; record.model = record.models?.first
                record.targets = []; record.healthAt = nil
                try core.history.append(record)
                func scan() {
                    if manual { _ = try? core.refreshModels(entryIDPrefix: record.id, pickModels: mode == 2 ? { $0 } : nil) }
                    else {
                        let done = DispatchSemaphore(value: 0)
                        core.scanHealth(staleAfter: 0) { _ in done.signal() }
                        t.expect(done.wait(timeout: .now() + 25) == .success, "池扫描完成")
                    }
                }
                scan()
                let first = core.history.find(idPrefix: record.id)!
                scan(); scan(); scan()
                let saved = HistoryStore().find(idPrefix: record.id)!
                t.equal(saved.credentialStatus.passed, 1, "主密钥冷却时仍验证第三个成员")
                t.equal(saved.credentialStatus.failed, 2, "保留真实限流失败")
                t.equal(saved.credentialStatus.untested, 0, "冷却不能饿死其他成员")
                t.equal(upstream.countKey(keys[0]), 1, "主密钥尊重冷却不重复请求")
                t.equal(upstream.countKey(keys[1]), 1, "次密钥冷却不阻止继续轮换")
                t.expect(upstream.countKey(keys[2]) >= 2, "已覆盖后仍能越过冷却成员继续轮询")
                t.equal(saved.healthAt, first.healthAt, "仅更新池证据不伪造主密钥验证时间")
                t.equal(saved.probeLog?.count, first.probeLog?.count, "冷却跳过不追加总览采样")
                t.equal(saved.modelProbeLog?.values.first?.count, first.modelProbeLog?.values.first?.count, "冷却跳过不追加模型采样")
            }
        }
        h.runSuite("Completeness.pool evidence survives stale health and edit snapshots") { t in
            let env = try TestEnv("completeness-pool-evidence-merge"); defer { env.cleanup() }
            let store = HistoryStore()
            var record = HistoryTests.entry("pool-evidence-merge", ts: 1)
            record.format = "cpa-multikey"; record.key = nil
            record.poolKeys = ["sk-merge-first", "sk-merge-second"]
            record.models = ["gpt-fixture"]; record.model = "gpt-fixture"
            record.targets = []; record.health = "ok"; record.healthAt = 1
            let secondID = HistoryEntry.credentialID(record.poolKeys![1])
            func point(_ time: TimeInterval, _ ok: Bool) -> ProbePoint {
                record.scopedProbePoints(["gpt-fixture": ProbePoint(t: time, ms: 1, ok: ok)])["gpt-fixture"]!
            }
            record.poolProbeLog = [secondID: ["gpt-fixture": point(1, true)]]
            try store.append(record)
            var newer = record
            newer.poolProbeLog = [secondID: ["gpt-fixture": point(3, false)]]
            try store.mergePoolEvidence([newer])
            try store.mergeHealth([record], at: 2)
            t.equal(store.find(idPrefix: record.id)?.poolProbeLog?[secondID]?["gpt-fixture"]?.t, 3, "旧健康扫描不能覆盖更新的池采样")
            t.equal(store.find(idPrefix: record.id)?.credentialStatus.failed, 1, "新失败不可被旧成功洗绿")
            var staleEdit = record
            staleEdit.note = "edited after scan"
            try store.update(staleEdit)
            t.equal(store.find(idPrefix: record.id)?.poolProbeLog?[secondID]?["gpt-fixture"]?.t, 3, "旧编辑快照保留最新池采样")
            t.equal(store.find(idPrefix: record.id)?.note, staleEdit.note, "普通编辑仍然保存")
            var external = newer
            external.poolProbeLog = [secondID: ["gpt-fixture": point(4, false)]]
            try HistoryStore().mergePoolEvidence([external])
            try store.update(staleEdit)
            t.equal(HistoryStore().find(idPrefix: record.id)?.poolProbeLog?[secondID]?["gpt-fixture"]?.t, 4, "跨进程编辑也保留最新池采样")
        }
        h.runSuite("Completeness.discovered protocol invalidates legacy evidence") { t in
            let env = try TestEnv("completeness-protocol-evidence"); defer { env.cleanup() }
            let store = HistoryStore()
            var record = HistoryTests.entry("protocol-evidence", ts: 1)
            record.models = ["gpt-a", "gpt-b"]; record.model = "gpt-a"
            record.targets = []; record.apiStyle = "openai"; record.health = "ok"; record.healthAt = 1
            record.modelProbeLog = ["gpt-a": [ProbePoint(t: 1, ms: 1, ok: true)], "gpt-b": [ProbePoint(t: 1, ms: 1, ok: true)]]
            try store.append(record)
            var scanned = record
            scanned.apiStyle = "responses"
            scanned.modelProbeLog = scanned.scopedProbePoints(["gpt-a": ProbePoint(t: 2, ms: 1, ok: true)]).mapValues { [$0] }
            try store.mergeHealth([scanned], at: 2)
            let saved = store.find(idPrefix: record.id)!
            t.equal(saved.modelStatus.passed, 1, "新协议只证明本轮真实验证的模型")
            t.equal(saved.modelStatus.untested, 1, "旧协议无范围采样不能继续证明未测模型")
            t.expect(!saved.healthColor.ok, "协议变化后不能以旧证据标绿")
            var stale = record
            stale.health = "dead"; stale.healthDetail = "stale result"
            try store.mergeHealth([stale], at: 3, testedConfigurations: [record.id: record.probeConfigurationID])
            t.equal(store.find(idPrefix: record.id)?.apiStyle, "responses", "旧协议扫描不能回滚当前协议")
            t.equal(store.find(idPrefix: record.id)?.healthAt, 2, "被测配置变化后丢弃过时结果")
        }
        h.runSuite("Completeness.feed cannot copy remote green state to changed local config") { t in
            let env = try TestEnv("completeness-feed-evidence"); defer { env.cleanup() }
            let core = Core()
            var local = HistoryTests.entry("feed-evidence", ts: 1)
            local.targets = []; local.key = "sk-feed-old111111"
            local.models = ["gpt-fixture"]; local.model = "gpt-fixture"
            local.health = "ok"; local.healthAt = 1
            local.modelProbeLog = ["gpt-fixture": [ProbePoint(t: 1, ms: 1, ok: true)]]
            try core.history.append(local)
            var remote = local
            remote.key = "sk-feed-new222222"; remote.updatedAt = Date().timeIntervalSince1970 + 100
            remote.healthAt = remote.updatedAt
            remote.modelProbeLog = ["gpt-fixture": [ProbePoint(t: remote.updatedAt!, ms: 1, ok: true, cpa: true)]]
            let payload = LedgerPayload(schemaVersion: LedgerCrypto.currentSchemaVersion, exportedAt: remote.updatedAt!,
                                        appVersion: "test", entries: [remote], switches: nil)
            let data = try LedgerCrypto.seal(JSONEncoder().encode(payload), passphrase: "feed-evidence-passphrase")
            _ = try core.importLedger(data, passphrase: "feed-evidence-passphrase", mode: .feed)
            let saved = core.history.find(idPrefix: local.id)!
            t.equal(saved.key, remote.key, "订阅内容已更新")
            t.expect(!saved.healthColor.ok, "远端成功不能证明本机新配置可用")
            t.equal(saved.modelStatus.untested, 1, "旧凭据采样不再证明新凭据")
            t.equal(saved.modelProbeLog?["gpt-fixture"]?.first?.t, 1, "本机历史轨迹保留")
        }
    }
}
