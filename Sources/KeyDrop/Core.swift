import Foundation

struct AddOutcome {
    let entry: HistoryEntry
    let lines: [String]
    let ok: Bool
}

final class Core {
    static let shared = Core()

    static var defaultAppType: String {
        ProcessInfo.processInfo.environment["KEYDROP_APP"] ?? "opencode"
    }

    let cc = CCSwitchWriter()
    let history = HistoryStore.shared
    let prefs = Prefs.shared

    func add(
        raw: String,
        ccOverride: Bool? = nil,
        cpaOverride: Bool? = nil,
        dshOverride: Bool? = nil,
        models: [String]? = nil,
        force: Bool = false,
        appType: String = Core.defaultAppType,
        proxy: String? = nil,
        pickModels: (([String]) -> [String])? = nil
    ) throws -> AddOutcome {
        AppLog.info("add 开始(force=\(force))")
        defer { AppLog.info("add 结束") }
        let proxyURL: String? = {
            if let proxy, !proxy.isEmpty { return proxy }
            let p = prefs.proxy
            return p.isEmpty ? nil : p
        }()
        let rawLines = raw.split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let proxyCount = rawLines.filter { Parser.isProxyURL($0) }.count
        let clashOnly = proxyCount > 0 && proxyCount * 2 >= rawLines.count

        if clashOnly {
            var proxies: [ClashProxy] = []
            for l in rawLines {
                if let p = Parser.parseProxyURL(l), !p.server.isEmpty, p.port > 0, !p.uuid.isEmpty {
                    proxies.append(p)
                }
            }
            guard !proxies.isEmpty else { throw ParseError.io("未识别到有效的代理节点") }
            let msg = try ClashWriter.add(proxies: proxies)
            let entry = HistoryEntry(
                id: UUID().uuidString.lowercased(),
                ts: Date().timeIntervalSince1970,
                raw: raw,
                format: "clash",
                name: nil,
                url: nil,
                model: nil,
                key: nil,
                keyMasked: "\(proxies.count) 个节点",
                targets: ["clash"],
                ccProviderID: nil,
                ccRenamedFrom: nil,
                ccRenamedTo: nil,
                cpaConfigPath: nil,
                status: "active"
            )
            try history.append(entry)
            try prefs.save()
            return AddOutcome(entry: entry, lines: [msg], ok: true)
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            if !trimmed.contains("\n") {
                if let proxies = try? Self.fetchSubscriptionProxies(url: trimmed), !proxies.isEmpty {
                    let msg = try ClashWriter.add(proxies: proxies)
                    let entry = HistoryEntry(
                        id: UUID().uuidString.lowercased(),
                        ts: Date().timeIntervalSince1970, raw: raw, format: "clash-sub",
                        name: nil, url: nil, model: nil, key: nil,
                        keyMasked: "\(proxies.count) 个节点",
                        targets: ["clash"], ccProviderID: nil,
                        ccRenamedFrom: nil, ccRenamedTo: nil, cpaConfigPath: nil, status: "active"
                    )
                    try history.append(entry)
                    try prefs.save()
                    return AddOutcome(entry: entry, lines: [msg], ok: true)
                }
            }
        }

        var parsed = try Parser.parseWithFallback(raw)

        var notes: [String] = []
        if parsed.url == nil {
            if let last = history.lastURL() {
                parsed.url = last
                notes.append("URL 复用上次: \(last)")
            } else {
                throw ParseError.noURL
            }
        }
        guard let url = parsed.url else { throw ParseError.noURL }
        guard let key = parsed.key, !key.isEmpty else {
            throw ParseError.noKeyFound("解析未得到 key。")
        }

        if !force, let dup = history.findActiveByKey(key) {
            throw ParseError.duplicate(
                id: dup.id,
                message: "该 API key 已存在(\(dup.id) · \(dup.summary)),未重复导入。"
                    + "如需覆盖请先删除旧记录,或 CLI 使用 --force。"
            )
        }

        let allKeys = Parser.extractAllKeys(raw)
        if allKeys.count > 1 {
            let useCPA = cpaOverride ?? prefs.useCPA
            guard useCPA else {
                throw ParseError.io("检测到 \(allKeys.count) 个 key,多 key 仅支持写入 CPA。请启用 CPA(--cpa) 或单独添加单个 key。")
            }
            guard let cfg = prefs.resolvedCPAConfig() else {
                throw ParseError.io("检测到多 key,需要写入 CPA 但未找到 config.yaml")
            }
            prefs.cpaConfigPath = cfg
            let msg = try CPAWriter(configPath: cfg).addMulti(baseURL: url, keys: allKeys, proxy: proxyURL)
            let entry = HistoryEntry(
                id: UUID().uuidString.lowercased(),
                ts: Date().timeIntervalSince1970,
                raw: raw,
                format: "cpa-multikey",
                name: parsed.name,
                url: url,
                model: parsed.model,
                key: nil,
                keyMasked: "\(allKeys.count) 个 key",
                targets: ["cpa"],
                ccProviderID: nil,
                ccRenamedFrom: nil,
                ccRenamedTo: nil,
                cpaConfigPath: cfg,
                status: "active"
            )
            try history.append(entry)
            try prefs.save()
            return AddOutcome(entry: entry, lines: [msg], ok: true)
        }

        let name = parsed.name?.isEmpty == false ? parsed.name! : cc.defaultName(for: url)
        parsed.name = name

        var selectedModels: [String] = []
        var addHealth: (health: String, detail: String)? = nil
        if !force {
            let test = APITester.test(url: url, key: key, proxy: proxyURL)
            if !test.ok {
                throw ParseError.io("测试失败,未写入。\(test.detail)\n(确认真实或 --force 跳过测试)")
            }
            addHealth = Self.healthFor(test)
            notes.append("测试: \(test.detail)")
            if let m = models, !m.isEmpty {
                selectedModels = m
            } else if test.models.isEmpty {
                let pastedModels = parsed.models ?? (parsed.model.map { [$0] } ?? [])
                if !pastedModels.isEmpty {
                    var tried: [String] = []
                    var lastFail = ""
                    for m in pastedModels {
                        tried.append(m)
                        let check = APITester.testModelChat(base: url, key: key, model: m, proxy: proxyURL)
                        if check.ok {
                            selectedModels = [m]
                            notes.append("模型验证通过: \(m)(贴入 \(tried.count) 个,逐一验证)")
                            break
                        }
                        lastFail = "\(m) → \(check.detail)"
                    }
                    if selectedModels.isEmpty {
                        throw ParseError.io("贴入的 \(tried.count) 个模型均验证失败: \(tried.joined(separator: ", "))。最后失败: \(lastFail)")
                    }
            } else if let picker = pickModels {
                let picked = picker([])
                if picked.isEmpty {
                    throw ParseError.io("已取消选择模型")
                }
                var tried: [String] = []
                var lastFail = ""
                for m in picked {
                    tried.append(m)
                    let check = APITester.testModelChat(base: url, key: key, model: m, proxy: proxyURL)
                    if check.ok {
                        selectedModels = [m]
                        notes.append("模型验证通过: \(m)(输入 \(tried.count) 个,逐一验证)")
                        break
                    }
                    lastFail = "\(m) → \(check.detail)"
                }
                if selectedModels.isEmpty {
                    throw ParseError.io("输入的 \(tried.count) 个模型均验证失败: \(tried.joined(separator: ", "))。最后失败: \(lastFail)")
                }
            }
            } else if test.models.count <= 5 {
                selectedModels = test.models
                notes.append("可用模型仅 \(test.models.count) 个,已全部导入")
            } else if let picker = pickModels {
                let picked = picker(test.models)
                if picked.isEmpty {
                    throw ParseError.io("已取消选择模型")
                }
                selectedModels = picked
            } else if let pm = parsed.model, !pm.isEmpty {
                selectedModels = [pm]
            } else {
                selectedModels = test.models
            }
        } else if let m = models, !m.isEmpty {
            selectedModels = m
        } else if let pm = parsed.model, !pm.isEmpty {
            selectedModels = [pm]
        }
        selectedModels = selectedModels.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        // 用户手动输入的模型名放宽校验;自动探测的仍走 looksLikeModel
        if models == nil {
            let strict = selectedModels.filter { Parser.looksLikeModel($0) }
            if !strict.isEmpty || pickModels == nil {
                selectedModels = strict.isEmpty ? selectedModels : strict
            }
        }
        parsed.model = selectedModels.first

        let resolvedAppType = Self.routeAppType(selectedModels: selectedModels, modelsOverride: models, default: appType)
        if resolvedAppType != appType {
            notes.append("按所选模型导入到 \(resolvedAppType)")
        }

        let useCC = ccOverride ?? prefs.useCC
        let useCPA = cpaOverride ?? prefs.useCPA
        let useDSH = dshOverride ?? prefs.useDSH

        var entry = HistoryEntry(
            id: UUID().uuidString.lowercased(),
            ts: Date().timeIntervalSince1970,
            raw: raw,
            format: parsed.format,
            name: name,
            url: url,
            model: parsed.model,
            models: selectedModels.isEmpty ? nil : selectedModels,
            key: parsed.key,
            keyMasked: parsed.keyMasked,
            targets: [],
            ccProviderID: nil,
            ccRenamedFrom: nil,
            ccRenamedTo: nil,
            cpaConfigPath: nil,
            status: "active",
            health: addHealth?.health,
            healthDetail: addHealth?.detail,
            healthAt: addHealth == nil ? nil : Date().timeIntervalSince1970
        )

        var lines: [String] = []
        lines.append("解析: \(parsed.format) → key=\(parsed.keyMasked)" + (parsed.model.map { " model=\($0)" } ?? ""))
        if selectedModels.count > 1 {
            let shown = selectedModels.prefix(3).joined(separator: ", ")
            let more = selectedModels.count > 3 ? " 等\(selectedModels.count)个" : ""
            lines.append("模型: \(shown)\(more)")
        }

        var anyOK = false
        var anyTarget = false

        if useCC {
            anyTarget = true
            do {
                let r = try cc.add(parsed, appType: resolvedAppType, models: selectedModels, proxy: proxyURL)
                entry.targets.append(resolvedAppType == "claude" ? "ccswitch" : "ccswitch-\(resolvedAppType)")
                entry.ccProviderID = r.providerID
                entry.ccRenamedFrom = r.renamedFrom
                entry.ccRenamedTo = r.renamedTo
                anyOK = true
                let appLabel = resolvedAppType == "claude" ? "Claude Code" : resolvedAppType
                lines.append("✓ cc-switch: 已添加 provider「\(r.providerName)」到 \(appLabel) 并激活")
                if r.renamedFrom != nil {
                    lines.append("  热激活: 原 provider 已暂存,删除本条时自动还原")
                }
                if r.directMode {
                    lines.append("  直写模式: 已更新配置文件,重开会话生效")
                } else if r.proxyMode {
                    lines.append("  代理模式: cc-switch 本地代理已热切换,立即可用,无需重启")
                } else {
                    lines.append("  已写入 cc-switch 数据库,请确认 cc-switch 正在运行")
                }
                for warning in r.warnings {
                    lines.append("  ⚠ \(warning)")
                }
            } catch {
                lines.append("✗ cc-switch 失败: \(error.localizedDescription)")
            }
        }

        if useCPA {
            anyTarget = true
            if let cfg = prefs.resolvedCPAConfig() {
                prefs.cpaConfigPath = cfg
                do {
                    let msg = try CPAWriter(configPath: cfg).add(parsed, proxy: proxyURL)
                    entry.targets.append("cpa")
                    entry.cpaConfigPath = cfg
                    anyOK = true
                    lines.append("✓ CPA: \(msg)")
                } catch {
                    lines.append("✗ CPA 失败: \(error.localizedDescription)")
                }
            } else {
                lines.append("✗ CPA: 未找到 config.yaml,跳过")
            }
        }

        if useDSH {
            let hasDeepseek = selectedModels.contains(where: DSHWriter.isDeepseekModel)
                || (parsed.model.map(DSHWriter.isDeepseekModel) ?? false)
            if hasDeepseek {
                anyTarget = true
                if let url = parsed.url, let key = parsed.key {
                    do {
                        let route = try DSHWriter.add(
                            providerID: entry.id, key: key, url: url, models: selectedModels
                        )
                        entry.targets.append("dsh")
                        anyOK = true
                        lines.append("✓ DeepSeek Harness: 已添加 provider「\(route)」")
                    } catch {
                        lines.append("✗ DeepSeek Harness 失败: \(error.localizedDescription)")
                    }
                } else {
                    lines.append("✗ DeepSeek Harness: 缺少 URL 或 key")
                }
            } else {
                lines.append("– DeepSeek Harness: 所选模型无 deepseek,跳过")
            }
        }

        if !anyTarget {
            throw ParseError.io("没有选中的目标(cc-switch / CPA)")
        }

        entry.status = anyOK ? "active" : "error"
        entry.note = notes.isEmpty ? nil : notes.joined(separator: "; ")
        lines.append(contentsOf: notes)

        if anyOK {
            do {
                try history.append(entry)
                try prefs.save()
            } catch {
                lines.append("⚠ 历史/偏好保存失败: \(error.localizedDescription)")
                lines.append("  (cc-switch 已写入,但 KeyDrop 历史缺失,删除时无法自动还原)")
            }
        }

        return AddOutcome(entry: entry, lines: lines, ok: anyOK)
    }

    static func healthFor(_ test: APITestResult) -> (health: String, detail: String) {
        if test.ok { return ("ok", test.detail) }
        if test.authFailed { return ("dead", test.detail) }
        return ("err", test.detail)
    }

    private func proxyForHealth() -> String? {
        let p = prefs.proxy
        return p.isEmpty ? nil : p
    }

    func scanHealth(staleAfter: TimeInterval = 1800, completion: (([String]) -> Void)? = nil) {
        let synced = reconcileWithCCSwitch()
        if !synced.isEmpty {
            AppLog.info("health 扫描前对账: " + synced.joined(separator: "; "))
        }
        let now = Date().timeIntervalSince1970
        var targets: [HistoryEntry] = []
        for e in history.snapshot() where e.status == "active" && e.key != nil && e.url != nil {
            if let at = e.healthAt, now - at < staleAfter { continue }
            targets.append(e)
        }
        guard !targets.isEmpty else {
            completion?([])
            return
        }
        var out: [String] = []
        let outLock = NSLock()
        let sem = DispatchSemaphore(value: 4)
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)
        for e in targets {
            sem.wait()
            group.enter()
            queue.async {
                defer { sem.signal(); group.leave() }
                let test = APITester.test(url: e.url!, key: e.key!, timeout: 10, proxy: self.proxyForHealth())
                let (h, d) = Self.healthFor(test)
                var updated = e
                updated.health = h
                updated.healthDetail = d
                updated.healthAt = now
                try? self.history.update(updated)
                if h != "ok" {
                    outLock.lock()
                    out.append("\(e.id.prefix(8)) \(h == "dead" ? "key 失效" : "异常"): \(d.prefix(80))")
                    outLock.unlock()
                }
            }
        }
        group.notify(queue: .main) {
            completion?(out)
        }
    }

    /// 对账 cc-switch:history 中 active 且带 ccswitch 目标,但 provider 已在
    /// cc-switch 中被删除的条目。
    /// - key 失效(401/403) → 同步标记为删除(用户在 cc-switch 侧清理了失效 key)
    /// - key 可用 → 标记 ccMissing,保留记录,由用户手动重新导入(避免自动复活循环)
    func reconcileWithCCSwitch() -> [String] {
        var out: [String] = []
        for e in history.snapshot()
        where e.status == "active"
            && e.targets.contains(where: { $0.hasPrefix("ccswitch") })
            && e.ccProviderID != nil {
            let appType = e.targets.first(where: { $0.hasPrefix("ccswitch-") })
                .map { String($0.dropFirst("ccswitch-".count)) } ?? "claude"
            guard let pid = e.ccProviderID, !cc.providerExists(id: pid, appType: appType)
            else { continue }
            guard let url = e.url, let key = e.key, !key.isEmpty else { continue }
            let test = APITester.test(url: url, key: key, timeout: 10, proxy: proxyForHealth())
            var updated = e
            if test.authFailed {
                updated.targets.removeAll { $0.hasPrefix("ccswitch") }
                if updated.targets.isEmpty { updated.status = "deleted" }
                updated.note = ([updated.note].compactMap { $0 }
                    + ["cc-switch provider 已被删除且 key 失效,KeyDrop 已同步标记"]).joined(separator: "; ")
                out.append("同步: 标记「\(e.name ?? String(e.id.prefix(8)))」为已删除(cc-switch 中 provider 不存在,key 失效)")
            } else {
                updated.ccMissing = true
                updated.note = ([updated.note].compactMap { $0 }
                    + ["cc-switch provider 缺失,key 仍可用,可手动重新导入"]).joined(separator: "; ")
                out.append("同步: 「\(e.name ?? String(e.id.prefix(8)))」provider 缺失但可用,已标记可重新导入")
            }
            updated.health = test.authFailed ? "dead" : (test.ok ? "ok" : "err")
            updated.healthDetail = test.detail
            updated.healthAt = Date().timeIntervalSince1970
            try? history.update(updated)
        }
        return out
    }

    /// 手动重新导入:把 ccMissing 的 provider 重新写入 cc-switch
    func reimportToCC(entryIDPrefix: String) throws -> String {
        guard var entry = history.find(idPrefix: entryIDPrefix) else {
            throw ParseError.io("历史记录中找不到: \(entryIDPrefix)")
        }
        guard entry.status == "active" else {
            throw ParseError.io("该记录已删除,无法重新导入")
        }
        guard entry.ccMissing == true else {
            throw ParseError.io("该记录在 cc-switch 中仍存在,无需重新导入")
        }
        guard try cc.repairMissingProvider(entry: entry) else {
            throw ParseError.io("重新导入失败:provider 已存在或缺少 key/url")
        }
        entry.ccMissing = nil
        let cleanedNote = (entry.note ?? "")
            .components(separatedBy: "; ")
            .filter { !$0.contains("provider 缺失,key 仍可用") && !$0.contains("可手动重新导入") }
            .filter { !$0.isEmpty }
        entry.note = (cleanedNote + ["已手动重新导入 cc-switch"]).joined(separator: "; ")
        try history.update(entry)
        let appType = entry.targets.first(where: { $0.hasPrefix("ccswitch-") })
            .map { String($0.dropFirst("ccswitch-".count)) } ?? "claude"
        return "✓ 已重新导入 cc-switch(\(appType)): \(entry.name ?? String(entry.id.prefix(8)))"
    }

    func selfHeal() -> [String] {
        reconcileWithCCSwitch()
    }

    func testEntry(entryIDPrefix: String) throws -> String {
        guard let entry = history.find(idPrefix: entryIDPrefix) else {
            throw ParseError.io("历史记录中找不到: \(entryIDPrefix)")
        }
        guard let url = entry.url, let key = entry.key, !key.isEmpty else {
            throw ParseError.io("该记录缺少 URL 或 key,无法测试")
        }
        let test = APITester.test(url: url, key: key, proxy: proxyForHealth())
        if test.ok {
            if var found = history.find(idPrefix: entryIDPrefix) {
                found.health = "ok"
                found.healthDetail = test.detail
                found.healthAt = Date().timeIntervalSince1970
                try? history.update(found)
            }
            return "✓ 可用: \(test.detail) (\(test.models.count) 个模型)"
        }
        if var found = history.find(idPrefix: entryIDPrefix) {
            let h = Self.healthFor(test)
            found.health = h.health
            found.healthDetail = h.detail
            found.healthAt = Date().timeIntervalSince1970
            try? history.update(found)
        }
        return "✗ 不可用: \(test.detail)"
    }

    static func parseClashProxies(raw: String) -> [ClashProxy] {
        raw.split(whereSeparator: { $0.isNewline })
            .map(String.init)
            .compactMap { Parser.parseProxyURL($0) }
            .filter { !$0.server.isEmpty && $0.port > 0 && !$0.uuid.isEmpty }
    }

    static func routeAppType(selectedModels: [String], modelsOverride: [String]?, default appType: String) -> String {
        func isGptModel(_ m: String) -> Bool {
            let l = m.lowercased()
            if l.contains("gpt-") || l.contains("/gpt") || l == "gpt" { return true }
            if l.hasPrefix("gpt") && (l.count == 3 || l.dropFirst(3).first == "-" || l.dropFirst(3).first == ".") { return true }
            return false
        }
        func isClaudeModel(_ m: String) -> Bool {
            let l = m.lowercased()
            return l.contains("claude") || l.contains("sonnet") || l.contains("opus") || l.contains("haiku") || l.contains("fable")
        }
        let list = (modelsOverride?.isEmpty == false ? modelsOverride! : selectedModels)
        if list.isEmpty { return appType }
        if list.contains(where: { isClaudeModel($0) }) { return "claude" }
        if list.contains(where: { isGptModel($0) }) { return "codex" }
        return "opencode"
    }

    static func fetchSubscriptionProxies(url: String) throws -> [ClashProxy] {
        guard let u = URL(string: url),
              let scheme = u.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              u.host?.isEmpty == false
        else { throw ParseError.io("无效的订阅 URL") }
        let sem = DispatchSemaphore(value: 0)
        var data: Data?
        var respError: Error?
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        config.httpMaximumConnectionsPerHost = 1
        let session = URLSession(configuration: config)
        let task = session.dataTask(with: u) { d, _, e in
            data = d
            respError = e
            sem.signal()
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 20)
        if let e = respError { throw ParseError.io("订阅请求失败: \(e.localizedDescription)") }
        guard let d = data, !d.isEmpty else { throw ParseError.io("订阅链接无响应(超时或不可达)") }
        guard d.count <= 5_000_000 else { throw ParseError.io("订阅内容过大(>5MB),已拒绝") }

        let text: String
        if let s = String(data: d, encoding: .utf8) {
            text = s
        } else if let s = String(data: d, encoding: .ascii) {
            text = s
        } else {
            throw ParseError.io("订阅内容无法识别(非 UTF-8/ASCII 文本)")
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let decoded: String
        if Parser.isPureBase64(trimmed) || Parser.isPureBase64(String(trimmed.filter { !$0.isWhitespace })) {
            let clean = trimmed.filter { !$0.isWhitespace }
            if let d2 = Parser.base64DecodeLoose(clean), let s = String(data: d2, encoding: .utf8) {
                decoded = s
            } else {
                decoded = trimmed
            }
        } else {
            decoded = trimmed
        }

        let proxies = decoded.split(whereSeparator: { $0.isNewline })
            .map(String.init)
            .compactMap { Parser.parseProxyURL($0) }
            .filter { !$0.server.isEmpty && $0.port > 0 && !$0.uuid.isEmpty }
        return proxies
    }

    static func addClashProxies(_ proxies: [ClashProxy]) throws -> String {
        try ClashWriter.add(proxies: proxies)
    }

    func refreshModels(
        entryIDPrefix: String,
        pickModels: (([String]) -> [String])? = nil
    ) throws -> String {
        guard var entry = history.find(idPrefix: entryIDPrefix) else {
            throw ParseError.io("历史记录中找不到: \(entryIDPrefix)")
        }
        guard let url = entry.url, let key = entry.key, !key.isEmpty else {
            throw ParseError.io("该记录缺少 URL 或 key,无法重新测试")
        }
        let test = APITester.test(url: url, key: key, proxy: proxyForHealth())
        guard test.ok else {
            let h = Self.healthFor(test)
            entry.health = h.health
            entry.healthDetail = h.detail
            entry.healthAt = Date().timeIntervalSince1970
            try? history.update(entry)
            throw ParseError.io("✗ 不可用: \(test.detail)")
        }
        entry.health = "ok"
        entry.healthDetail = test.detail
        entry.healthAt = Date().timeIntervalSince1970
        let currentModels = Set(entry.models ?? (entry.model.map { [$0] } ?? []))
        let testModels = test.models.filter { Parser.looksLikeModel($0) }
        if testModels.isEmpty {
            try? history.update(entry)
            let keep = currentModels.isEmpty ? "无" : currentModels.joined(separator: ", ")
            return "✓ 可用: \(test.detail) (端点无模型列表,保留已有模型: \(keep))"
        }
        let modelsChanged = currentModels != Set(testModels)

        if !modelsChanged {
            try? history.update(entry)
            return "✓ 可用: \(test.detail) (\(test.models.count) 个模型,无变化)"
        }

        var filtered: [String] = []
        if let picker = pickModels {
            let sel = picker(testModels)
            if sel.isEmpty { throw ParseError.io("已取消选择模型") }
            // 刷新时保留用户勾选/手输,不因启发式误杀
            filtered = sel.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        } else {
            filtered = testModels
        }
        guard !filtered.isEmpty else {
            throw ParseError.io("测试通过但未识别到模型,无法刷新")
        }
        entry.models = filtered
        entry.model = filtered.first

        if entry.targets.contains(where: { $0.hasPrefix("ccswitch") }),
           let pid = entry.ccProviderID {
            let appType = entry.targets.first(where: { $0.hasPrefix("ccswitch-") })
                .map { String($0.dropFirst("ccswitch-".count)) } ?? "claude"
            var p = ParsedKey()
            p.url = url
            p.key = key
            p.model = filtered.first
            try cc.syncModelsAfterRefresh(p, providerID: pid, appType: appType, models: filtered)
        }

        if entry.targets.contains("dsh") {
            _ = try DSHWriter.add(providerID: entry.id, key: key, url: url, models: filtered)
        }
        try history.update(entry)
        return "✓ 可用: \(test.detail) (\(test.models.count) 个模型,已更新 \(filtered.count) 个)"
    }

    /// 编辑条目:改模型列表/名称,重新验证模型并同步所有目标(cc-switch/dsh)
    func editEntry(
        entryIDPrefix: String,
        models: [String]? = nil,
        name: String? = nil,
        verify: Bool = true
    ) throws -> String {
        guard var entry = history.find(idPrefix: entryIDPrefix)
            ?? history.findActiveByRaw(entryIDPrefix)
        else {
            throw ParseError.io("历史记录中找不到: \(entryIDPrefix)")
        }
        guard let url = entry.url, let key = entry.key, !key.isEmpty else {
            throw ParseError.io("该记录缺少 URL 或 key,无法编辑")
        }

        var lines: [String] = []
        var newModels = entry.models ?? (entry.model.map { [$0] } ?? [])

        if let models, !models.isEmpty {
            var verified: [String] = []
            var failures: [String] = []
            for m in models {
                if verify {
                    let check = APITester.testModelChat(base: url, key: key, model: m, proxy: proxyForHealth())
                    if check.ok {
                        verified.append(m)
                    } else {
                        failures.append("\(m) → \(check.detail)")
                    }
                } else {
                    verified.append(m)
                }
            }
            if verified.isEmpty {
                throw ParseError.io("模型均验证失败: \(failures.joined(separator: "; "))\n(确认模型名大小写,或 --no-verify 强制)")
            }
            if !failures.isEmpty {
                lines.append("⚠ 以下模型验证失败,已跳过: \(failures.joined(separator: "; "))")
            }
            newModels = verified
            entry.models = verified
            entry.model = verified.first
            lines.append("✓ 模型已更新: \(verified.joined(separator: ", "))")
        }
        if let name, !name.isEmpty {
            entry.name = name
            lines.append("✓ 名称已更新: \(name)")
        }

        if newModels.isEmpty && name == nil {
            return "无变更"
        }

        // 同步 cc-switch
        if entry.targets.contains(where: { $0.hasPrefix("ccswitch") }),
           let pid = entry.ccProviderID {
            let appType = entry.targets.first(where: { $0.hasPrefix("ccswitch-") })
                .map { String($0.dropFirst("ccswitch-".count)) } ?? "claude"
            var p = ParsedKey()
            p.url = url
            p.key = key
            p.model = newModels.first
            do {
                try cc.syncModelsAfterRefresh(p, providerID: pid, appType: appType, models: newModels)
                lines.append("✓ cc-switch: 已同步模型")
            } catch {
                lines.append("⚠ cc-switch 同步失败: \(error.localizedDescription)")
            }
        }

        // 同步 dsh
        if entry.targets.contains("dsh") {
            do {
                _ = try DSHWriter.add(providerID: entry.id, key: key, url: url, models: newModels)
                lines.append("✓ DeepSeek Harness: 已同步模型")
            } catch {
                lines.append("⚠ DeepSeek Harness 同步失败: \(error.localizedDescription)")
            }
        }

        try history.update(entry)
        return lines.joined(separator: "\n")
    }

    func activateCPA(entryIDPrefix: String) throws -> String {
        guard var entry = history.find(idPrefix: entryIDPrefix)
            ?? history.findActiveByRaw(entryIDPrefix)
        else {
            throw ParseError.io("历史记录中找不到: \(entryIDPrefix)")
        }
        guard entry.targets.contains("cpa") else {
            throw ParseError.io("该记录不是 CPA 类型")
        }
        guard let ep = CPAWriter.endpointInfo() else {
            throw ParseError.io("无法读取 CPA 端点或客户端 key,请确认 CPA 正在运行且配置了 api-keys")
        }

        let models = entry.models ?? (entry.model.map { [$0] } ?? [])
        let appType = Self.routeAppType(selectedModels: models, modelsOverride: nil, default: "claude")

        var p = ParsedKey()
        p.url = ep.baseURL
        p.key = ep.clientKey
        p.model = models.first
        p.name = "CPA-\(ep.baseURL)"

        let r = try cc.add(p, appType: appType, models: models, proxy: proxyForHealth())
        entry.targets = entry.targets.filter { !$0.hasPrefix("ccswitch") }
        entry.targets.append(appType == "claude" ? "ccswitch" : "ccswitch-\(appType)")
        entry.ccProviderID = r.providerID
        entry.ccRenamedFrom = r.renamedFrom
        entry.ccRenamedTo = r.renamedTo
        try history.update(entry)

        let appLabel = appType == "claude" ? "Claude Code" : appType
        var msg = "✓ CPA 端点(\(ep.baseURL))已写入 cc-switch → \(appLabel) 并激活"
        if r.directMode { msg += "\n  直写模式: 已更新配置文件,重开会话生效" }
        else if r.proxyMode { msg += "\n  代理模式: 热切换,立即可用" }
        for w in r.warnings { msg += "\n  ⚠ \(w)" }
        return msg
    }

    func delete(entryIDPrefix: String) throws -> String {
        guard var entry = history.find(idPrefix: entryIDPrefix)
            ?? history.findActiveByRaw(entryIDPrefix)
        else {
            throw ParseError.io("历史记录中找不到: \(entryIDPrefix)")
        }
        guard entry.status == "active" else {
            return "该记录已删除"
        }

        var lines: [String] = []
        var failures: [String] = []
        var remaining = entry.targets

        if entry.targets.contains("cpa") {
            if let cfg = entry.cpaConfigPath, let key = extractKey(entry) {
                do {
                    let msg = try CPAWriter(configPath: cfg).remove(apiKey: key)
                    lines.append("✓ CPA: \(msg)")
                    remaining.removeAll { $0 == "cpa" }
                } catch {
                    failures.append("CPA: \(error.localizedDescription)")
                }
            } else if entry.cpaConfigPath == nil {
                failures.append("CPA: 历史记录缺少配置路径")
            } else {
                failures.append("CPA: 无法从历史记录恢复原始 key,未删除")
            }
        }

        if entry.targets.contains("clash") {
            remaining.removeAll { $0 == "clash" }
            lines.append("✓ Clash: 已从列表移除")
        }

        if entry.targets.contains(where: { $0.hasPrefix("ccswitch") }) {
            if let pid = entry.ccProviderID {
                let appType = entry.targets.first(where: { $0.hasPrefix("ccswitch-") })
                    .map { String($0.dropFirst("ccswitch-".count)) } ?? "claude"
                do {
                    let msg = try cc.remove(
                        providerID: pid,
                        renamedFrom: entry.ccRenamedFrom,
                        renamedTo: entry.ccRenamedTo,
                        appType: appType
                    )
                    lines.append("✓ cc-switch: \(msg)")
                    remaining.removeAll { $0.hasPrefix("ccswitch") }
                } catch {
                    // 主路径失败时按 ID 兜底,绝不按 host 误删其他 provider
                    do {
                        let msgs = try cc.removeProviderByID(pid)
                        if msgs.isEmpty {
                            failures.append("cc-switch: \(error.localizedDescription)")
                        } else {
                            lines.append("✓ cc-switch(兜底): \(msgs.joined(separator: ", "))")
                            remaining.removeAll { $0.hasPrefix("ccswitch") }
                        }
                    } catch {
                        failures.append("cc-switch: \(error.localizedDescription)")
                    }
                }
            } else {
                failures.append("cc-switch: 历史记录缺少 provider ID")
            }
        }

        if entry.targets.contains("dsh") {
            do {
                try DSHWriter.remove(providerID: entry.id)
                lines.append("✓ DeepSeek Harness: 已移除 provider「\(DSHWriter.routeKey(providerID: entry.id))」")
                remaining.removeAll { $0 == "dsh" }
            } catch {
                failures.append("DeepSeek Harness: \(error.localizedDescription)")
            }
        }

        entry.targets = remaining
        entry.status = remaining.isEmpty ? "deleted" : "active"
        if !failures.isEmpty {
            entry.note = ([entry.note].compactMap { $0 } + failures).joined(separator: "; ")
        }
        do {
            try history.update(entry)
        } catch {
            lines.append("⚠ 历史状态保存失败: \(error.localizedDescription)(实际删除已生效)")
        }
        if !failures.isEmpty {
            throw ParseError.io((lines + failures.map { "✗ \($0)" }).joined(separator: "\n"))
        }
        return lines.isEmpty ? "已删除" : lines.joined(separator: "\n")
    }

    private func extractKey(_ e: HistoryEntry) -> String? {
        if let key = e.key, !key.isEmpty { return key }
        if let parsed = try? Parser.parse(e.raw) { return parsed.key }
        return nil
    }

    func list(limit: Int = 20) -> String {
        var out: [String] = []
        for e in history.snapshot().prefix(limit) {
            let mark = e.status == "active" ? "●" : "○"
            out.append("\(mark) \(e.id.prefix(8)) \(e.timeStr) \(e.summary) [\(e.targets.joined(separator: "+"))]")
        }
        return out.isEmpty ? "(无历史记录)" : out.joined(separator: "\n")
    }
}
