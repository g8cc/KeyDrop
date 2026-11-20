import Foundation
import KeyDropCore

private final class MonitoringHTTPServer {
    let listener: TCPServer
    let partial: Bool
    let cooldown: Bool
    let missingCatalog: Bool
    private let lock = NSLock()
    private var requestedModels: [String] = []
    func requestCount(for model: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return requestedModels.filter { $0 == model }.count
    }
    var port: Int { listener.port }
    var base: String { "http://127.0.0.1:\(port)/v1" }
    static let models = ["gpt-monitor-ok", "gpt-monitor-denied", "gpt-monitor-failed"]

    init(partial: Bool = true, cooldown: Bool = false, missingCatalog: Bool = false) throws {
        listener = try TCPServer()
        self.partial = partial
        self.cooldown = cooldown
        self.missingCatalog = missingCatalog
        let listener = listener
        Thread.detachNewThread { [weak self] in
            while let client = listener.accept() {
                Thread.detachNewThread { [weak self] in self?.handle(client) }
            }
        }
    }

    private func handle(_ client: SocketClient) {
        defer { client.close() }
        guard let request = client.readRequest() else { return }
        let first = request.components(separatedBy: "\r\n").first ?? ""
        var status = 404
        var body = #"{"error":{"message":"not found"}}"#
        if first.hasPrefix("GET "), first.contains("/models ") {
            status = 200
            let names = missingCatalog ? [] : Self.models
            body = String(data: try! JSONSerialization.data(withJSONObject: ["data": names.map { ["id": $0] }]), encoding: .utf8)!
        } else if first.hasPrefix("POST ") {
            var payload = request.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
            let header = request.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") } ?? ""
            let length = Int(header.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
            if payload.utf8.count < length { payload += client.readBody(toLength: length - payload.utf8.count) }
            let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
            let model = object?["model"] as? String
            if let model { lock.lock(); requestedModels.append(model); lock.unlock() }
            if partial, model == Self.models[0] || model == "gpt-monitor-new" || model == "test" {
                status = 200
                body = #"{"choices":[{"message":{"role":"assistant","content":"fixture ok"}}]}"#
            } else if partial, model == Self.models[1] {
                status = 403
                body = #"{"error":{"message":"model permission denied"}}"#
            } else if cooldown {
                status = 429
                body = #"{"error":{"message":"rate limited"}}"#
            } else {
                status = 503
                body = #"{"error":{"message":"upstream unavailable"}}"#
            }
        }
        let retry = status == 429 ? "Retry-After: 120\r\n" : ""
        client.write("HTTP/1.1 \(status) Fixture\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\(retry)Connection: close\r\n\r\n\(body)")
    }
}

enum MonitoringRegressionTests {
    private static func entry(_ id: String, server: MonitoringHTTPServer) -> HistoryEntry {
        var record = HistoryTests.entry(id, ts: 1)
        record.url = server.base
        record.models = MonitoringHTTPServer.models
        record.model = MonitoringHTTPServer.models[0]
        record.targets = []
        record.healthAt = 1
        record.modelProbeLog = Dictionary(uniqueKeysWithValues: MonitoringHTTPServer.models.map {
            ($0, [ProbePoint(t: 1, ms: 1, ok: true)])
        })
        return record
    }

    static func run(_ h: Harness) {
        h.runSuite("Monitoring.partial scan replaces stale green model points") { t in
            let env = try TestEnv("monitor-partial-scan")
            defer { env.cleanup() }
            let server = try MonitoringHTTPServer()
            let core = Core()
            let record = entry("monitor-partial-scan", server: server)
            try core.history.append(record)
            let done = DispatchSemaphore(value: 0)
            core.scanHealth(staleAfter: 0) { _ in done.signal() }
            t.expect(done.wait(timeout: .now() + 20) == .success, "扫描完成")
            let saved = core.history.find(idPrefix: record.id)!
            t.equal(saved.health, "ok", "局部模型失败不改变仍可用的 provider")
            t.equal(saved.modelProbeLog?[MonitoringHTTPServer.models[0]]?.last?.ok, true, "成功模型仍是绿色")
            for model in MonitoringHTTPServer.models.dropFirst() {
                t.equal(saved.modelProbeLog?[model]?.last?.ok, false, "\(model) 的明确失败不保留旧绿")
                t.equal(saved.modelProbeLog?[model]?.count, 2, "\(model) 新增真实探测点")
            }
        }
        h.runSuite("Monitoring.refresh failure records key and model timeline") { t in
            let env = try TestEnv("monitor-refresh-failure")
            defer { env.cleanup() }
            let server = try MonitoringHTTPServer(partial: false)
            let core = Core()
            let record = entry("monitor-refresh-failure", server: server)
            try core.history.append(record)
            do {
                _ = try core.refreshModels(entryIDPrefix: record.id)
                t.expect(false, "明确服务失败时重测报告失败")
            } catch { t.expect(true, "重测返回失败") }
            let saved = core.history.find(idPrefix: record.id)!
            t.expect((saved.healthAt ?? 0) > 1, "重测确实更新了健康时间")
            t.equal(saved.probeLog?.last?.ok, false, "失败重测写入 key 监控点")
            for model in MonitoringHTTPServer.models {
                t.equal(saved.modelProbeLog?[model]?.last?.ok, false, "失败重测更新 \(model) 的监控点")
            }
        }
        h.runSuite("Monitoring.reconciliation records model timeline before stale scan skips") { t in
            let env = try TestEnv("monitor-reconciliation")
            defer { env.cleanup() }
            try CCSwitchWriterTests.createSchema(env)
            let server = try MonitoringHTTPServer()
            let core = Core()
            var record = entry("monitor-reconciliation", server: server)
            record.targets = ["ccswitch-codex"]
            record.ccProviderID = "fixture-provider-not-present"
            record.modelProbeLog = nil
            record.healthAt = Date().timeIntervalSince1970
            try core.history.append(record)
            let done = DispatchSemaphore(value: 0)
            core.scanHealth(staleAfter: 3600) { _ in done.signal() }
            t.expect(done.wait(timeout: .now() + 20) == .success, "对账和扫描完成")
            let saved = core.history.find(idPrefix: record.id)!
            t.expect(saved.ccMissing == true, "确实经过 cc 对账")
            t.equal(saved.probeLog?.last?.ok, true, "对账 key 监控点存在")
            t.equal(saved.modelProbeLog?[MonitoringHTTPServer.models[0]]?.last?.ok, true, "对账成功模型写入首个监控点")
            for model in MonitoringHTTPServer.models.dropFirst() {
                t.equal(saved.modelProbeLog?[model]?.last?.ok, false, "对账失败模型写入首个监控点")
            }
        }
        h.runSuite("Monitoring.partial import records rejected model probes") { t in
            let env = try TestEnv("monitor-partial-import")
            defer { env.cleanup() }
            env.write("cpa-config.yaml", "port: 8317\n")
            Prefs.shared.cpaResident = false
            let server = try MonitoringHTTPServer()
            let core = Core()
            let result = try core.add(raw: "\(server.base)\nsk-monitor-import-fixture1111", ccOverride: false,
                                      grokOverride: false, cpaOverride: true, dshOverride: false,
                                      models: nil, force: false)
            let saved = core.history.find(idPrefix: result.entry.id)!
            t.equal(saved.modelProbeLog?[MonitoringHTTPServer.models[0]]?.last?.ok, true, "导入保留实际成功模型的监控点")
            for model in MonitoringHTTPServer.models.dropFirst() {
                t.equal(saved.modelProbeLog?[model]?.last?.ok, false, "导入不遗漏明确拒绝的模型")
            }
        }
        h.runSuite("Monitoring.proxy preserves individual model outcomes") { t in
            let env = try TestEnv("monitor-proxy")
            defer { env.cleanup() }
            let server = try MonitoringHTTPServer()
            let result = APITester.test(url: "http://127.0.0.1:1/v1", key: "sk-monitor-proxy-fixture",
                                        timeout: 2, proxy: "http://127.0.0.1:\(server.port)",
                                        probePool: MonitoringHTTPServer.models, knownNeedsProxy: true)
            t.expect(result.ok && result.needsProxy, "代理部分成功仍可用")
            t.equal(Set(result.failedModels), Set(MonitoringHTTPServer.models.dropFirst()), "代理不丢失拒绝和服务失败")
            let points = result.modelProbePoints(at: 12)
            t.equal(points[MonitoringHTTPServer.models[0]]?.ok, true, "代理成功模型为绿")
            t.equal(points[MonitoringHTTPServer.models[1]]?.ok, false, "代理拒绝模型为红")
            t.equal(points[MonitoringHTTPServer.models[2]]?.ok, false, "代理服务失败模型为红")
        }
        h.runSuite("Monitoring.empty catalog preserves explicit model identities") { t in
            let env = try TestEnv("monitor-empty-catalog")
            defer { env.cleanup() }
            let server = try MonitoringHTTPServer(missingCatalog: true)
            let result = APITester.test(url: server.base, key: "sk-monitor-empty-fixture", timeout: 2,
                                        probePool: MonitoringHTTPServer.models)
            t.expect(result.ok, "空目录不阻止已配置模型实测")
            t.equal(result.models, [], "服务目录保持为空")
            t.equal(result.workingModels, [MonitoringHTTPServer.models[0]], "配置模型的成功结果保留")
            t.equal(Set(result.failedModels), Set(MonitoringHTTPServer.models.dropFirst()), "配置模型的失败结果保留")
            t.equal(result.modelProbePoints(at: 13).count, 3, "空目录仍有三个真实模型监控点")
            let synthetic = APITester.test(url: server.base, key: "sk-monitor-placeholder-fixture", timeout: 2)
            t.expect(synthetic.ok, "占位请求本身通过")
            t.equal(synthetic.workingModels, [], "占位 test 不作为真实模型")
            t.equal(synthetic.modelProbePoints(at: 14), [:], "占位 test 不进入模型监控")
        }
        h.runSuite("Monitoring.configured probe does not pollute remote catalog") { t in
            let env = try TestEnv("monitor-catalog-identity")
            defer { env.cleanup() }
            let server = try MonitoringHTTPServer()
            let result = APITester.test(url: server.base, key: "sk-monitor-catalog-fixture", timeout: 2,
                                        probePool: ["gpt-monitor-new"])
            t.equal(result.workingModels, ["gpt-monitor-new"], "目录外手填模型有实际结果")
            t.equal(result.models, MonitoringHTTPServer.models, "远端目录不混入配置模型")
            t.equal(result.modelProbePoints(at: 15)["gpt-monitor-new"]?.ok, true, "目录外配置模型有监控点")
        }
        h.runSuite("Monitoring.refresh probes newly selected model") { t in
            let env = try TestEnv("monitor-refresh-selection")
            defer { env.cleanup() }
            let server = try MonitoringHTTPServer()
            let core = Core()
            var record = entry("monitor-refresh-selection", server: server)
            record.models = [MonitoringHTTPServer.models[0]]
            try core.history.append(record)
            let message = try core.refreshModels(entryIDPrefix: record.id, pickModels: { _ in ["gpt-monitor-new"] })
            let saved = core.history.find(idPrefix: record.id)!
            t.equal(saved.model, "gpt-monitor-new", "改选写入当前模型")
            t.expect(server.requestCount(for: "gpt-monitor-new") > 0, "实际请求了新模型")
            t.equal(saved.modelProbeLog?["gpt-monitor-new"]?.last?.ok, true, "新模型写入成功监控点")
            t.equal(saved.health, "ok", "新模型成功维持可用")
            t.contains(message, "改选", "返回新选择的验证结果")
        }
        h.runSuite("Monitoring.refresh selected failure cannot borrow catalog success") { t in
            let env = try TestEnv("monitor-refresh-selection-fail")
            defer { env.cleanup() }
            let server = try MonitoringHTTPServer()
            let core = Core()
            var record = entry("monitor-refresh-selection-fail", server: server)
            record.models = [MonitoringHTTPServer.models[0]]
            try core.history.append(record)
            let message = try core.refreshModels(entryIDPrefix: record.id, pickModels: { _ in ["gpt-monitor-new-failed"] })
            let saved = core.history.find(idPrefix: record.id)!
            t.equal(saved.model, "gpt-monitor-new-failed", "失败也保留用户选择")
            t.expect(server.requestCount(for: "gpt-monitor-new-failed") > 0, "实际请求了新模型")
            t.equal(saved.modelProbeLog?["gpt-monitor-new-failed"]?.last?.ok, false, "新模型失败写入红点")
            t.expect(saved.health != "ok", "目录中旧模型可用不能让新选择变绿")
            t.expect(!message.hasPrefix("✓ 可用"), "刷新结果不再声称新选择可用")
            t.equal(saved.probeLog?.last?.ok, false, "key 最近监控点对应新模型失败")
        }
        h.runSuite("Monitoring.refresh empty catalog probes configured model") { t in
            let env = try TestEnv("monitor-refresh-empty-catalog")
            defer { env.cleanup() }
            let server = try MonitoringHTTPServer(missingCatalog: true)
            let core = Core()
            var record = entry("monitor-refresh-empty-catalog", server: server)
            record.models = [MonitoringHTTPServer.models[0]]
            try core.history.append(record)
            _ = try core.refreshModels(entryIDPrefix: record.id)
            let saved = core.history.find(idPrefix: record.id)!
            t.equal(saved.models, [MonitoringHTTPServer.models[0]], "空目录保留配置")
            t.expect(server.requestCount(for: MonitoringHTTPServer.models[0]) > 0, "空目录探测实际配置模型")
            t.equal(server.requestCount(for: "test"), 0, "配置已知时不使用占位模型")
            t.equal(saved.modelProbeLog?[MonitoringHTTPServer.models[0]]?.count, 2, "空目录刷新增加真实模型记录")
        }
        h.runSuite("Monitoring.reconciliation probes explicit models outside catalog") { t in
            let env = try TestEnv("monitor-reconcile-explicit-model")
            defer { env.cleanup() }
            try CCSwitchWriterTests.createSchema(env)
            let server = try MonitoringHTTPServer(missingCatalog: true)
            let core = Core()
            var record = entry("monitor-reconcile-explicit-model", server: server)
            record.models = ["gpt-monitor-new"]
            record.model = "gpt-monitor-new"
            record.modelProbeLog = nil
            record.targets = ["ccswitch-codex"]
            record.ccProviderID = record.id
            try core.history.append(record)
            _ = core.reconcileWithCCSwitch()
            let saved = core.history.find(idPrefix: record.id)!
            t.expect(server.requestCount(for: "gpt-monitor-new") > 0, "对账实测已配置模型")
            t.equal(saved.modelProbeLog?["gpt-monitor-new"]?.last?.ok, true, "对账为目录外配置模型保存监控")
        }
        h.runSuite("Monitoring.pinned model outside pool preserves actual result") { t in
            let env = try TestEnv("monitor-pinned-model")
            defer { env.cleanup() }
            let server = try MonitoringHTTPServer()
            let result = APITester.test(url: server.base, key: "sk-monitor-pinned-fixture", timeout: 2,
                                       preferredModel: "gpt-monitor-new", probePool: [MonitoringHTTPServer.models[0]])
            t.expect(server.requestCount(for: "gpt-monitor-new") > 0, "首选模型实际已测试")
            t.equal(result.modelProbePoints(at: 20)["gpt-monitor-new"]?.ok, true, "首选模型不在目录/列表时也保存实测结果")
        }
        h.runSuite("Monitoring.cooldown skips do not create probe points") { t in
            let env = try TestEnv("monitor-cooldown")
            defer { env.cleanup() }
            let server = try MonitoringHTTPServer(partial: false, cooldown: true)
            let core = Core()
            let record = entry("monitor-cooldown", server: server)
            try core.history.append(record)
            do { _ = try core.refreshModels(entryIDPrefix: record.id) } catch {}
            let before = core.history.find(idPrefix: record.id)!
            do { _ = try core.refreshModels(entryIDPrefix: record.id) }
            catch { t.expect(true, "冷却中提前返回") }
            let after = core.history.find(idPrefix: record.id)!
            t.equal(after.healthAt, before.healthAt, "冷却不刷新探测时间")
            t.equal(after.probeLog, before.probeLog, "冷却不增加 key 探测点")
            t.equal(after.modelProbeLog, before.modelProbeLog, "冷却不增加模型探测点")
        }
    }
}
