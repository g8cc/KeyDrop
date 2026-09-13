import Foundation

public struct AddOutcome {
    public let entry: HistoryEntry
    public let lines: [String]
    public let ok: Bool
    public init(entry: HistoryEntry, lines: [String], ok: Bool) {
        self.entry = entry
        self.lines = lines
        self.ok = ok
    }
}

public final class Core {
    public static let shared = Core()
    public init() {}

    public static var defaultAppType: String {
        ProcessInfo.processInfo.environment["KEYDROP_APP"] ?? "opencode"
    }

    let cc = CCSwitchWriter()
    public let history = HistoryStore.shared
    public let prefs = Prefs.shared

    public func add(
        raw: String,
        ccOverride: Bool? = nil,
        grokOverride: Bool? = nil,
        cpaOverride: Bool? = nil,
        dshOverride: Bool? = nil,
        models: [String]? = nil,
        force: Bool = false,
        appType: String? = nil,
        appTypeForced: Bool = false,
        proxy: String? = nil,
        pickModels: (([String]) -> [String])? = nil
    ) throws -> AddOutcome {
        let appType = appType ?? Core.defaultAppType
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
        // 只统计能真正解析的代理行(如 socks5:// 会被 isProxyURL 认可但解析不了),
        // 否则混入不支持的协议会把正常 key 粘贴误判为 Clash 导入并报错
        let proxyCount = rawLines.filter { Parser.parseProxyURL($0) != nil }.count
        let clashOnly = proxyCount > 0 && proxyCount * 2 >= rawLines.count

        if clashOnly {
            var proxies: [ClashProxy] = []
            for l in rawLines {
                if let p = Parser.parseProxyURL(l), !p.server.isEmpty, p.port > 0, !p.uuid.isEmpty {
                    proxies.append(p)
                }
            }
            guard !proxies.isEmpty else { throw ParseError.io("未识别到有效的代理节点") }
            let (msg, clashFile) = try ClashWriter.add(proxies: proxies)
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
                status: "active",
                clashFile: clashFile
            )
            try history.append(entry)
            try prefs.save()
            return AddOutcome(entry: entry, lines: [msg], ok: true)
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var subFetchError: Error? = nil
        var subProxies: [ClashProxy]? = nil
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://"), !trimmed.contains("\n") {
            do {
                subProxies = try Self.fetchSubscriptionProxies(url: trimmed)
            } catch {
                // 拉取本身失败(超时/DNS/5MB 超限)不能被 try? 吞掉:
                // 否则后续解析失败的报错会是误导性的「解析未得到 key」。
                // 先记下,解析也失败时一并抛出
                subFetchError = error
            }
        }
        // ClashWriter.add 的错误(目录不可写等)必须直接抛给用户,
        // 不能被误归因为「订阅拉取失败」
        if let proxies = subProxies, !proxies.isEmpty {
            let (msg, clashFile) = try ClashWriter.add(proxies: proxies)
            let entry = HistoryEntry(
                id: UUID().uuidString.lowercased(),
                ts: Date().timeIntervalSince1970, raw: raw, format: "clash-sub",
                name: nil, url: nil, model: nil, key: nil,
                keyMasked: "\(proxies.count) 个节点",
                targets: ["clash"], ccProviderID: nil,
                ccRenamedFrom: nil, ccRenamedTo: nil, cpaConfigPath: nil, status: "active",
                clashFile: clashFile
            )
            try history.append(entry)
            try prefs.save()
            return AddOutcome(entry: entry, lines: [msg], ok: true)
        }

        var parsed: ParsedKey
        do {
            parsed = try Parser.parseWithFallback(raw)
        } catch {
            // 内容不是合法 key 且订阅拉取也失败过:把两个失败原因都告诉用户
            if let sub = subFetchError {
                throw ParseError.io("订阅拉取失败: \(sub.localizedDescription);内容解析失败: \(error.localizedDescription)")
            }
            throw error
        }

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

        var dup: HistoryEntry? = nil
        if let d = history.findActiveByKey(key) {
            if (d.url ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == url {
                dup = d
                notes.append("幂等更新: 同 key 同 URL 已存在(\(d.id.prefix(8))),将刷新该条目而非新建")
            } else if !force {
                throw ParseError.duplicate(
                    id: d.id,
                    message: "该 API key 已存在(\(d.id) · \(d.summary)),但 URL 不同(\(d.url ?? "") vs \(url))。"
                        + "如需覆盖请先删除旧记录,或 CLI 使用 --force。"
                )
            }
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
            let (msg, probedModels) = try CPAWriter(configPath: cfg).addMulti(baseURL: url, keys: allKeys, proxy: proxyURL)
            var multiLines = [msg]
            // 常驻模型来源 = 条目最终 models(已有精选时即精选列表);
            // 空(探测失败且无既有列表)传 nil 回退收集其它条目的精选
            multiLines.append(contentsOf: syncCPAResidentEntries(models: probedModels.isEmpty ? nil : probedModels))
            let entry = HistoryEntry(
                id: UUID().uuidString.lowercased(),
                ts: Date().timeIntervalSince1970,
                raw: raw,
                format: "cpa-multikey",
                name: parsed.name,
                url: url,
                model: probedModels.first ?? parsed.model,
                models: probedModels.isEmpty ? nil : probedModels,
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
            return AddOutcome(entry: entry, lines: multiLines, ok: true)
        }

        var name = parsed.name?.isEmpty == false ? parsed.name! : cc.defaultName(for: url)
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
                // 端点无模型列表:依次尝试贴入模型 / picker 手输
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

        let useGrok = grokOverride ?? prefs.useGrok
        let routedAppType = Self.routeAppType(selectedModels: selectedModels, modelsOverride: models, default: appType, forced: appTypeForced)
        // Grok Build is opt-out. If disabled, a pure Grok selection falls back to
        // OpenCode; a mixed Grok/non-Grok selection already routes to OpenCode.
        // 显式 --app grok 同样服从 --no-grok:routeAppType 的 forced 分支已保证只有
        // 纯 Grok 列表才路由 grok,若此处豁免,useGrok=false 时 grok 写入块与
        // cc 写入块(resolvedAppType != "grok" 才进)双双跳过 → 「没有选中的目标」死路
        let resolvedAppType = routedAppType == "grok" && !useGrok ? "opencode" : routedAppType
        if resolvedAppType != appType {
            notes.append("按所选模型导入到 \(resolvedAppType)")
        }

        let useCC = ccOverride ?? prefs.useCC
        let useCPA = cpaOverride ?? prefs.useCPA
        let useDSH = dshOverride ?? prefs.useDSH

        // 同 URL 不同 key 的兄弟条目:名字追加 key 尾号后缀区分。
        // 多把 key 共用一个网关是常态,不加后缀时 cc-switch 与 KeyDrop 历史
        // 会出现两个同名 provider,无法辨认哪把 key 对应哪个条目
        if useCC && resolvedAppType != "grok" {
            let appTag = resolvedAppType == "claude" ? "ccswitch" : "ccswitch-\(resolvedAppType)"
            let siblingExists = history.snapshot().contains { e in
                guard e.status == "active", e.id != dup?.id,
                      let k = e.key, k != key,
                      let u = e.url,
                      Parser.normalizeURL(u) == Parser.normalizeURL(url),
                      e.targets.contains(appTag) else { return false }
                return true
            }
            if siblingExists {
                name = "\(name)#\(key.suffix(4))"
                parsed.name = name
            }
        }

        var entry = HistoryEntry(
            id: dup?.id ?? UUID().uuidString.lowercased(),
            ts: dup?.ts ?? Date().timeIntervalSince1970,
            raw: raw,
            format: parsed.format,
            name: name,
            url: url,
            model: parsed.model,
            models: selectedModels.isEmpty ? nil : selectedModels,
            key: parsed.key,
            keyMasked: parsed.keyMasked,
            // 幂等更新保留旧条目的非 cc 目标(cpa/dsh/clash):即使本次对应开关关闭,
            // 这些目标在外部配置中仍然存在,删除时必须继续负责清理。
            // ccswitch 目标只在本次重新写入 cc 时才重建;本次开关关闭时必须保留,
            // 否则 cc-switch 里的旧 provider 变孤儿 —— delete/reconcile 都不再认领它
            targets: dup?.targets.filter {
                if $0.hasPrefix("ccswitch") { return !useCC || resolvedAppType == "grok" }
                // Keep the old Grok tag until the replacement target is written;
                // on a failed route change it must remain deletable/reconcilable.
                if $0 == "grok" { return true }
                return true
            } ?? [],
            ccProviderID: dup?.ccProviderID,
            ccRenamedFrom: dup?.ccRenamedFrom,
            ccRenamedTo: dup?.ccRenamedTo,
            cpaConfigPath: dup?.cpaConfigPath,
            grokConfigPath: dup?.grokConfigPath,
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

        if useCC && resolvedAppType != "grok" {
            anyTarget = true
            let appTag = resolvedAppType == "claude" ? "ccswitch" : "ccswitch-\(resolvedAppType)"
            do {
                if let dup, let pid = dup.ccProviderID, dup.targets.contains(appTag), cc.providerExists(pid, appType: resolvedAppType) {
                    // 幂等:provider 已存在,刷新 DB 配置与当前激活 provider 的配置文件
                    try cc.syncModelsAfterRefresh(parsed, providerID: pid, appType: resolvedAppType, models: selectedModels, proxy: proxyURL)
                    entry.ccProviderID = pid
                    entry.targets.append(appTag)
                    anyOK = true
                    let appLabel = resolvedAppType == "claude" ? "Claude Code" : resolvedAppType
                    lines.append("✓ cc-switch: 已更新已有 provider「\(dup.name ?? "")」到 \(appLabel)(幂等)")
                } else {
                    let r = try cc.add(parsed, appType: resolvedAppType, models: selectedModels, proxy: proxyURL)
                    entry.targets.append(appTag)
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
                    // 家族变化的重导入:entry.targets 初始化时已过滤掉旧 ccswitch 标签,
                    // 新标签只指向刚建的 provider。若不清理旧 app_type 的 provider,
                    // 它会变成无人认领的孤儿(delete/reconcile 都不再引用它)——违反账本不变量②。
                    // 顺序必须是「先建后删」:cc.add 失败时旧 provider 仍在,catch 恢复旧标签
                    // 不会指向已删产物;先删后建则在建失败时制造「标签指向不存在的产物」。
                    // 同 app_type 的重建/去重由 cc.add 内部处理,这里只管跨 app_type 的旧产物。
                    if let dup, let oldPid = dup.ccProviderID,
                       let oldTag = dup.targets.first(where: { $0.hasPrefix("ccswitch") }) {
                        let oldAppType = oldTag.hasPrefix("ccswitch-")
                            ? String(oldTag.dropFirst("ccswitch-".count)) : "claude"
                        if oldAppType != resolvedAppType, cc.providerExists(oldPid, appType: oldAppType) {
                            do {
                                _ = try cc.remove(providerID: oldPid, renamedFrom: dup.ccRenamedFrom,
                                                  renamedTo: dup.ccRenamedTo, appType: oldAppType)
                                lines.append("↺ 家族变化: 已移除旧 \(oldAppType) provider")
                            } catch {
                                lines.append("⚠ 旧 \(oldAppType) provider 清理失败(可能残留孤儿): \(error.localizedDescription)")
                            }
                        }
                    }
                }
            } catch {
                lines.append("✗ cc-switch 失败: \(error.localizedDescription)")
                // 写入失败 ≠ 旧 provider 消失:幂等路径 sync 失败、或路由变化后 cc.add 失败,
                // 旧 provider 仍在 cc-switch 里且 entry.ccProviderID 仍指向它。
                // 必须恢复旧 ccswitch 标签,否则 delete/reconcile 不再认领 → 孤儿 provider
                if let dup, let oldTag = dup.targets.first(where: { $0.hasPrefix("ccswitch") }),
                   !entry.targets.contains(oldTag) {
                    entry.targets.append(oldTag)
                }
            }
        }

        if useGrok && resolvedAppType == "grok" {
            anyTarget = true
            do {
                let writer = GrokBuildWriter(configPath: dup?.grokConfigPath)
                let msg = try writer.sync(
                    baseURL: url,
                    key: key,
                    models: selectedModels,
                    removing: dup?.models ?? (dup?.model.map { [$0] } ?? [])
                )
                entry.grokConfigPath = writer.configPath
                if !entry.targets.contains("grok") { entry.targets.append("grok") }
                anyOK = true
                lines.append("✓ Grok Build: \(msg)")

                // Route migrations are written first, then the old cc-switch
                // provider is removed so a failed new write remains recoverable.
                if let dup, let oldPID = dup.ccProviderID,
                   dup.targets.contains(where: { $0.hasPrefix("ccswitch") }) {
                    let oldAppType = dup.targets.first(where: { $0.hasPrefix("ccswitch-") })
                        .map { String($0.dropFirst("ccswitch-".count)) } ?? "claude"
                    if cc.providerExists(oldPID, appType: oldAppType) {
                        do {
                            _ = try cc.remove(providerID: oldPID, renamedFrom: dup.ccRenamedFrom,
                                              renamedTo: dup.ccRenamedTo, appType: oldAppType)
                            entry.targets.removeAll { $0.hasPrefix("ccswitch") }
                            entry.ccProviderID = nil
                            entry.ccRenamedFrom = nil
                            entry.ccRenamedTo = nil
                            lines.append("↺ 家族变化: 已移除旧 \(oldAppType) provider")
                        } catch {
                            lines.append("⚠ 旧 \(oldAppType) provider 清理失败(可能残留孤儿): \(error.localizedDescription)")
                        }
                    }
                }
            } catch {
                lines.append("✗ Grok Build 失败: \(error.localizedDescription)")
                if let dup, dup.targets.contains("grok"), !entry.targets.contains("grok") {
                    entry.targets.append("grok")
                }
            }
        }

        if useCPA {
            anyTarget = true
            if let cfg = prefs.resolvedCPAConfig() {
                prefs.cpaConfigPath = cfg
                do {
                    let msg = try CPAWriter(configPath: cfg).add(parsed, proxy: proxyURL)
                    if !entry.targets.contains("cpa") { entry.targets.append("cpa") }
                    entry.cpaConfigPath = cfg
                    anyOK = true
                    lines.append("✓ CPA: \(msg)")
                    // 单 key 走平铺段,其精选模型就是本次 selectedModels(用户为该网关挑的几个);
                    // 空则传 nil 回退收集其它 cpa 条目精选,绝不拉 CPA 聚合全量
                    lines.append(contentsOf: syncCPAResidentEntries(models: selectedModels.isEmpty ? nil : selectedModels))
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
                        if !entry.targets.contains("dsh") { entry.targets.append("dsh") }
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

        // Remove an old Grok route only after at least one replacement target
        // succeeded. This also covers CPA-only imports and --no-cc.
        if resolvedAppType != "grok", anyOK,
           let dup, dup.targets.contains("grok"),
           let oldURL = dup.url, let oldKey = dup.key,
           let oldPath = dup.grokConfigPath {
            do {
                _ = try GrokBuildWriter(configPath: oldPath).remove(
                    baseURL: oldURL,
                    key: oldKey,
                    models: dup.models ?? (dup.model.map { [$0] } ?? [])
                )
                entry.targets.removeAll { $0 == "grok" }
                lines.append("↺ 已移除旧 Grok Build 模型配置")
            } catch {
                lines.append("⚠ Grok Build 旧配置清理失败: \(error.localizedDescription)")
            }
        }

        if !anyTarget {
            throw ParseError.io("没有选中的目标(cc-switch / Grok Build / CPA)")
        }

        entry.status = anyOK ? "active" : "error"
        entry.note = notes.isEmpty ? nil : notes.joined(separator: "; ")
        lines.append(contentsOf: notes)

        if anyOK {
            do {
                if dup != nil {
                    try history.update(entry)
                } else if let survivor = try history.appendDedupByKey(entry) {
                    // 网络测试期间另一进程(CLI/app)刚导入了同一 key。
                    // 本进程也已经写了外部配置(cc-switch provider / DSH route),
                    // 直接丢掉本进程 entry 会把这些产物变孤儿(无人认领、删不掉):
                    // ① 回滚本进程刚写的重复外部配置(best-effort)
                    // ② 把本进程的其余目标记录(cpa/dsh/clash)并入 survivor 再落盘
                    var merged = survivor
                    let appType = entry.targets.first(where: { $0.hasPrefix("ccswitch-") })
                        .map { String($0.dropFirst("ccswitch-".count)) } ?? "claude"
                    var ccRolledBack = false
                    if entry.targets.contains(where: { $0.hasPrefix("ccswitch") }), let pid = entry.ccProviderID {
                        do {
                            _ = try cc.remove(providerID: pid, renamedFrom: entry.ccRenamedFrom,
                                              renamedTo: entry.ccRenamedTo, appType: appType)
                            ccRolledBack = true
                        } catch {
                            lines.append("⚠ 并发合并: 本进程刚写的 cc-switch provider(\(pid.prefix(8)))回滚失败,请手动清理: \(error.localizedDescription)")
                        }
                    }
                    var dshRolledBack = false
                    if entry.targets.contains("dsh") {
                        do { try DSHWriter.remove(providerID: entry.id); dshRolledBack = true }
                        catch { lines.append("⚠ 并发合并: 本进程刚写的 DSH route 回滚失败: \(error.localizedDescription)") }
                    }
                    // CPA 是聚合写入、Clash 是独立文件,无需回滚;把目标记录并入 survivor。
                    // 已成功回滚的外部配置对应的 tag 绝不能并入:tag 会指向已删除的
                    // provider/route,后续 delete 会按错误的 appType 清理 survivor 自己的产物
                    for t in entry.targets where !merged.targets.contains(t) {
                        if t.hasPrefix("ccswitch") && ccRolledBack { continue }
                        if t == "dsh" && dshRolledBack { continue }
                        merged.targets.append(t)
                    }
                    if merged.cpaConfigPath == nil { merged.cpaConfigPath = entry.cpaConfigPath }
                    if merged.grokConfigPath == nil { merged.grokConfigPath = entry.grokConfigPath }
                    try history.update(merged)
                    entry = merged
                    lines.append("↻ 检测到同 key 已被其他端导入,已合并到既有记录(\(survivor.id.prefix(8)))")
                }
                try prefs.save()
            } catch {
                lines.append("⚠ 历史/偏好保存失败: \(error.localizedDescription)")
                lines.append("  (cc-switch 已写入,但 KeyDrop 历史缺失,删除时无法自动还原)")
            }
        }

        return AddOutcome(entry: entry, lines: lines, ok: anyOK)
    }

    /// CPA 写入成功后的常驻入口同步:把 CPA 固定端点(http://host:port + CPA 客户端 key)
    /// 被动 upsert 进 cc-switch-opencode,模型来源=config 条目精选列表。
    /// claude / codex 对反代封杀严格,不放 CPA,并迁移清理历史误建的行。
    /// 全程 best-effort:CPA 没在跑/拉不到列表/cc-switch 缺失都只记一行提示,绝不让导入失败。
    /// 幂等:重复导入命中同一 provider 原地更新模型;绝不抢激活(用户当前用谁就用谁)。
    /// 公开供 CLI `cpa-sync` 手动触发(首次建立 / 改了 CPA 配置后立刻刷新)。
    /// 模型列表来源 = config 中该条目的精选 models,**绝不**用 CPA 聚合 /v1/models
    /// (真实反馈:聚合把 22 家上游混成 100+ 模型,用户只维护精选的 SOTA 几个)
    /// - Parameter override: 导入路径传本次条目最终模型;手动 cpa-sync 传 nil,
    ///   从历史里所有带 cpa 目标的条目收集精选列表
    @discardableResult
    public func syncCPAResidentEntries(models override: [String]? = nil) -> [String] {
        guard prefs.cpaResident,
              ProcessInfo.processInfo.environment["KEYDROP_CPA_RESIDENT"] != "0" else { return [] }
        guard let ep = CPAWriter.endpointInfo() else {
            return ["– CPA 常驻入口: 未找到 CPA 客户端 key(config.yaml 无 api-keys),跳过"]
        }
        let models = override ?? collectCuratedModels()
        guard !models.isEmpty else {
            return ["– CPA 常驻入口: 未发现精选模型列表(条目 models 为空),跳过;在 config.yaml 里选好模型后再 cpa-sync"]
        }
        var out: [String] = []
        // opencode 双写(DB + opencode.json),KeyDrop 唯一有原生文件写入器的 cc-switch 类型
        do {
            let r = try cc.syncCPAResident(appType: "opencode", baseURL: ep.baseURL,
                                           clientKey: ep.clientKey, models: models)
            out.append("✓ CPA 常驻(cc-switch-opencode): \(r)(\(models.count) 个精选模型)")
        } catch {
            out.append("⚠ CPA 常驻 cc-switch-opencode 同步失败: \(error.localizedDescription)")
        }
        // pi/openclaw/hermes:cc-switch 支持的直连 JSON 类型。仅在「该类型在 cc-switch 有 provider 行
        // = 用户在用」时写入(装了才导,没装不新建空类型)
        for appType in ["pi", "openclaw", "hermes"] {
            guard cc.typeInUse(appType) else { continue }
            do {
                let r = try cc.syncCPAResidentNative(appType: appType, baseURL: ep.baseURL,
                                                     clientKey: ep.clientKey, models: models)
                out.append("✓ CPA 常驻(cc-switch-\(appType)): \(r)")
            } catch {
                out.append("⚠ CPA 常驻 cc-switch-\(appType) 同步失败: \(error.localizedDescription)")
            }
        }
        // dsh:装了(~/.dsh)才考虑写。已有「用户手写」的非 KeyDrop route 指向该端点则不动;
        // 否则用固定 providerID 幂等写/更新 KeyDrop 自己的 route(第二次同步能刷新模型)。
        // providerID 只用字母,避免 envName 生成含连字符的非法 shell 变量名
        if DSHWriter.installed() {
            let dshRoutes = DSHWriter.routesForEndpoint(baseURL: ep.baseURL)
            let userOwned = dshRoutes.contains { !$0.hasPrefix("keydrop-") }
            if userOwned {
                out.append("✓ CPA 常驻(dsh): 已有你手写的该端点 route(\(dshRoutes.first ?? "")),未改动")
            } else {
                do {
                    _ = try DSHWriter.add(providerID: "cparesident", key: ep.clientKey,
                                          url: ep.baseURL, models: models)
                    out.append("✓ CPA 常驻(dsh): 已写入/更新 keydrop-cparesident(\(models.count) 个精选模型)")
                } catch {
                    out.append("⚠ CPA 常驻 dsh 同步失败: \(error.localizedDescription)")
                }
            }
        }
        // claude / codex 反代封杀严:不放,迁移清理历史误建行
        for appType in ["claude", "codex"] {
            do {
                let r = try cc.removeCPAResident(appType: appType, baseURL: ep.baseURL, clientKey: ep.clientKey)
                if !r.isEmpty { out.append("↺ \(r)") }
            } catch {
                out.append("⚠ cc-switch-\(appType) CPA 入口清理失败: \(error.localizedDescription)")
            }
        }
        return out
    }

    /// 手动同步的模型来源:遍历 active 历史中所有 CPA 条目,读其聚合条目当前精选 models 求并集
    private func collectCuratedModels() -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for e in history.snapshot() where e.status == "active" && e.targets.contains("cpa") {
            guard let cfg = e.cpaConfigPath, let url = e.url,
                  FileManager.default.fileExists(atPath: cfg) else { continue }
            for m in CPAWriter(configPath: cfg).entryModels(baseURL: url) where seen.insert(m).inserted {
                out.append(m)
            }
        }
        return out
    }

    public static func healthFor(_ test: APITestResult) -> (health: String, detail: String) {        if test.needsProxy {
            return ("proxy-ok", test.detail + " ⚠ 该网关直连不可用,需代理;无代理的工具(dsh 等)需自行配置 HTTPS_PROXY 才可用")
        }
        if test.quotaExhausted { return ("quota", test.detail) }
        if test.ok { return ("ok", test.detail) }
        if test.authFailed { return ("dead", test.detail) }
        return ("err", test.detail)
    }

    private func proxyForHealth() -> String? {
        let p = prefs.proxy
        return p.isEmpty ? nil : p
    }

    /// history.update 的统一入口:落盘失败(磁盘满/权限)必须留痕,
    /// 否则「已标记/已更新」的返回值与磁盘事实不一致且无迹可查
    private func historyUpdateLogged(_ e: HistoryEntry) {
        do { try history.update(e) } catch {
            AppLog.error("history.update 保存失败: \(error.localizedDescription)")
        }
    }

    public func scanHealth(staleAfter: TimeInterval = 1800, completion: (([String]) -> Void)? = nil) {
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
        var updatedEntries: [HistoryEntry] = []
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
                // 只收集不落盘;结束后 mergeHealth 一次性按字段合并保存(见 scanHealth 尾部)
                // 每条各 save 一次会把整份历史反复序列化写盘(O(N²) IO 放大)
                outLock.lock()
                updatedEntries.append(updated)
                if h != "ok" {
                    out.append("\(e.id.prefix(8)) \(h == "dead" ? "key 失效" : "异常"): \(d.prefix(80))")
                }
                outLock.unlock()
            }
        }
        // 不能固定回调到 main queue:无 runloop 的进程(纯 CLI)里 main queue 永不执行,
        // completion 会静默丢失;需要主线程的调用方自行 hop
        group.notify(queue: DispatchQueue.global(qos: .userInitiated)) {
            // mergeHealth 只写 health/healthDetail/healthAt 三个字段:
            // 测试期间条目可能被 CLI 或用户改过,整条覆盖会回滚那些并发修改
            do {
                try self.history.mergeHealth(updatedEntries, at: now)
            } catch {
                AppLog.error("scanHealth 保存失败: \(error.localizedDescription)")
            }
            completion?(out)
        }
    }

    /// 对账 cc-switch:history 中 active 且带 ccswitch 目标,但 provider 已在
    /// cc-switch 中被删除的条目。
    /// - key 失效(401/403) → 同步标记为删除(用户在 cc-switch 侧清理了失效 key)
    /// - key 可用 → 标记 ccMissing,保留记录,由用户手动重新导入(避免自动复活循环)
    func reconcileWithCCSwitch() -> [String] {
        var out: [String] = []
        let outLock = NSLock()
        let candidates = history.snapshot()
            .filter {
                $0.status == "active"
                    && $0.targets.contains(where: { $0.hasPrefix("ccswitch") })
                    && $0.ccProviderID != nil
            }
            .filter { e in
                guard let pid = e.ccProviderID else { return false }
                let appType = e.targets.first(where: { $0.hasPrefix("ccswitch-") })
                    .map { String($0.dropFirst("ccswitch-".count)) } ?? "claude"
                return !cc.providerExists(id: pid, appType: appType)
            }
            .filter { ($0.url ?? "").isEmpty == false && ($0.key ?? "").isEmpty == false }
        // 并发测试(上限 4):原先串行,每条超时 10s,离线时 N 条失联 key 要等 10N 秒
        let sem = DispatchSemaphore(value: 4)
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)
        for e in candidates {
            sem.wait()
            group.enter()
            queue.async {
                defer { sem.signal(); group.leave() }
                guard let url = e.url, let key = e.key, !key.isEmpty else { return }
                let test = APITester.test(url: url, key: key, timeout: 10, proxy: self.proxyForHealth())
                var updated = e
                if test.authFailed {
                    updated.targets.removeAll { $0.hasPrefix("ccswitch") }
                    if updated.targets.isEmpty { updated.status = "deleted" }
                    updated.note = ([updated.note].compactMap { $0 }
                        + ["cc-switch provider 已被删除且 key 失效,KeyDrop 已同步标记"]).joined(separator: "; ")
                } else {
                    updated.ccMissing = true
                    updated.note = ([updated.note].compactMap { $0 }
                        + ["cc-switch provider 缺失,key 仍可用,可手动重新导入"]).joined(separator: "; ")
                }
                updated.health = test.authFailed ? "dead" : (test.ok ? "ok" : "err")
                updated.healthDetail = test.detail
                updated.healthAt = Date().timeIntervalSince1970
                outLock.lock()
                if test.authFailed {
                    out.append("同步: 标记「\(e.name ?? String(e.id.prefix(8)))」为已删除(cc-switch 中 provider 不存在,key 失效)")
                } else {
                    out.append("同步: 「\(e.name ?? String(e.id.prefix(8)))」provider 缺失但可用,已标记可重新导入")
                }
                outLock.unlock()
                // 测完立刻落盘:不攒到最后批量写。批量写会把竞态窗口拉长到整轮扫描的时长,
                // 期间 CLI 删除的条目会被旧内存快照复活;立即写窗口只有毫秒级
                self.historyUpdateLogged(updated)
            }
        }
        // 等全部对账完成,保持「返回时对账已生效」的既有语义(逐条已在并发任务内即时落盘)
        group.wait()
        return out
    }

    /// 手动重新导入:把 ccMissing 的 provider 重新写入 cc-switch
    public func reimportToCC(entryIDPrefix: String) throws -> String {
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

    public func selfHeal() -> [String] {
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
        let h = Self.healthFor(test)
        if test.ok {
            if var found = history.find(idPrefix: entryIDPrefix) {
                found.health = h.health
                found.healthDetail = h.detail
                found.healthAt = Date().timeIntervalSince1970
                historyUpdateLogged(found)
            }
            return "✓ 可用: \(h.detail) (\(test.models.count) 个模型)"
        }
        if var found = history.find(idPrefix: entryIDPrefix) {
            found.health = h.health
            found.healthDetail = h.detail
            found.healthAt = Date().timeIntervalSince1970
            historyUpdateLogged(found)
        }
        return "✗ 不可用: \(test.detail)"
    }

    public static func parseClashProxies(raw: String) -> [ClashProxy] {
        raw.split(whereSeparator: { $0.isNewline })
            .map(String.init)
            .compactMap { Parser.parseProxyURL($0) }
            .filter { !$0.server.isEmpty && $0.port > 0 && !$0.uuid.isEmpty }
    }

    /// claude 系模型判定(sonnet/opus/haiku/fable 属 claude 家族)
    public static func isClaudeModel(_ m: String) -> Bool {
        let l = m.lowercased()
        return l.contains("claude") || l.contains("sonnet") || l.contains("opus") || l.contains("haiku") || l.contains("fable")
    }

    /// Grok Build family: accept ids such as `grok-4.6`, `grok-imagine-image`,
    /// and namespaced ids such as `xai/grok-video`, without matching words like
    /// `grokking` by accident.
    public static func isGrokModel(_ m: String) -> Bool {
        let l = m.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !l.isEmpty else { return false }
        return l.range(of: #"(?:^|[^a-z0-9])grok(?:$|[-._:/0-9])"#, options: .regularExpression) != nil
    }

    /// gpt 系模型判定(chat/responses 系 → codex)。
    /// 只认 gpt 后紧跟数字或 -oss 的家族(gpt-4o / gpt-5 / gpt-oss / openai/gpt-4.5 等);
    /// gpt-image / gpt-vision / gpt-realtime / gpt-ocr 等非 chat 模型不认。
    /// 真实事故:fal-ai/gpt-image-2 被子串 contains("gpt-") 误判为 gpt → 图生模型被导入 codex。
    public static func isGptModel(_ m: String) -> Bool {
        let l = m.lowercased()
        if l == "gpt" { return true }
        // 任意位置出现 gpt 家族:gpt 后必须紧跟数字(-/. 可省略)或 -oss;
        // 前一个字符必须非字母数字,避免 chatgpt 等词内子串误配
        return l.range(of: #"(?:^|[^a-z0-9])gpt[-.]?(?:oss|[0-9])"#, options: .regularExpression) != nil
    }

    public static func routeAppType(selectedModels: [String], modelsOverride: [String]?, default appType: String, forced: Bool = false) -> String {
        let list = (modelsOverride?.isEmpty == false ? modelsOverride! : selectedModels)
        if forced {
            // `--app grok` may select the Grok target explicitly, but it must
            // not override the safety rule for a mixed model selection.
            if appType == "grok" {
                return !list.isEmpty && list.allSatisfy(isGrokModel) ? "grok" : "opencode"
            }
            return appType
        }
        if list.isEmpty { return appType }
        if list.allSatisfy(isGrokModel) { return "grok" }
        // A mixed Grok list must stay in the general OpenCode route.
        if list.contains(where: isGrokModel) { return "opencode" }
        if list.contains(where: { isClaudeModel($0) }) { return "claude" }
        if list.contains(where: { isGptModel($0) }) { return "codex" }
        return "opencode"
    }

    /// 非 chat 模型判定:纯图生 / 视觉 / 嵌入 / 重排 / 语音 / OCR 等。
    /// 这类模型不能当编码/对话 agent 的激活模型,选中后会让 codex/opencode 拿图生模型当默认。
    /// 关键词边界用 (前导分隔或开头)+词尾,避免误伤 vision-capable chat 模型(如 "deepseek-v4-flash-vision",
    /// 它仍是对话模型,不含 image/embed 等纯非 chat 标记)。真实事故:fal-ai/gpt-image-2 被当 codex 默认模型。
    public static func isNonChatModel(_ m: String) -> Bool {
        let l = m.lowercased()
        return l.range(of: #"(?:^|[-/._])(image|dall|dalle|flux|sora|video|whisper|tts|embed|embedding|rerank|reranker|moderation|realtime|ocr|speech|audio)\b"#, options: .regularExpression) != nil
    }

    /// 已知 chat 家族(deepseek/qwen/kimi/glm/llama/mistral/minimax/mimo/longcat/grok/yi/phi 等)。
    /// 用于激活模型优先级:有 chat 家族时优先选它,而非 fal-ai/nano-banana 这类难判定的多模态。
    static func looksLikeChatFamily(_ m: String) -> Bool {
        let l = m.lowercased()
        return l.range(of: #"(?:deepseek|qwen|kimi|glm|llama|mistral|minimax|mimo|longcat|grok|\byi\b|phi|gemma|command|internlm|yi-|aquila)"#, options: .regularExpression) != nil
            || isClaudeModel(m) || isGptModel(m)
    }

    /// 激活模型优先选择:① 已知 chat 家族 ② 其他非 non-chat 模型;全 non-chat 返回 nil(不设激活模型)。
    /// 调用方:opencode 写入的 firstModel。模型列表本身不变(用户勾选的仍可写入 models 字典),
    /// 仅「激活默认」不应落到图生模型上。
    public static func preferredChatModel(_ models: [String]) -> String? {
        let chatFamily = models.first(where: { looksLikeChatFamily($0) && !isNonChatModel($0) })
        if let chatFamily { return chatFamily }
        return models.first(where: { !isNonChatModel($0) && !$0.isEmpty })
    }

    /// 订阅拉取专用 session:进程级单例。
    /// 旧实现每次调用 new 一个 URLSession 且从不 invalidate,session 内部队列/线程常驻;
    /// menu bar app 长驻,每次贴订阅链接泄一个,累积泄漏。
    private static let subscriptionSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        config.httpMaximumConnectionsPerHost = 1
        return URLSession(configuration: config)
    }()

    public static func fetchSubscriptionProxies(url: String) throws -> [ClashProxy] {
        guard let u = URL(string: url),
              let scheme = u.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              u.host?.isEmpty == false
        else { throw ParseError.io("无效的订阅 URL") }
        let o = NetSync.run(session: subscriptionSession, url: u, timeout: 20)
        if let e = o.error {
            if (e as? URLError)?.code == .cancelled {
                throw ParseError.io("订阅请求超时(20s)")
            }
            throw ParseError.io("订阅请求失败: \(e.localizedDescription)")
        }
        guard let d = o.data, !d.isEmpty else { throw ParseError.io("订阅链接无响应(超时或不可达)") }
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

    public static func addClashProxies(_ proxies: [ClashProxy]) throws -> (message: String, fileName: String?) {
        try ClashWriter.add(proxies: proxies)
    }

    public func refreshModels(
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
            // 只改 health 不动 status:status="dead" 会让条目从 UI 全部列表消失,
            // 且 delete() 只认 status=="active",记录变成删不掉的僵尸。
            // health="dead" + status="active" 会正常进入「待删除区」,与健康扫描路径一致
            entry.health = h.health
            entry.healthDetail = h.detail
            entry.healthAt = Date().timeIntervalSince1970
            historyUpdateLogged(entry)
            let deadMark = (test.authFailed || test.detail.contains("401") || test.detail.contains("403"))
                ? "(key 已失效,已移入待删除区)" : ""
            throw ParseError.io("✗ 不可用: \(test.detail)\(deadMark)")
        }
        // 额度状态:仅标记不提前返回——提前返回会让 quota 条目永远无法再选模型/更新列表
        var quotaNote: String? = nil
        if test.quotaExhausted {
            quotaNote = "无额度(chat 端点 429/402 quota exhausted)"
        } else if APITester.checkBalance(url: url, key: key, proxy: proxyForHealth()) == .zero {
            quotaNote = "无余额/配额耗尽(余额接口)"
        }
        entry.health = quotaNote != nil ? "quota" : "ok"
        entry.healthDetail = quotaNote ?? test.detail
        entry.healthAt = Date().timeIntervalSince1970
        let previousModels = entry.models ?? (entry.model.map { [$0] } ?? [])
        let currentModels = Set(previousModels)
        let testModels = test.models.filter { Parser.looksLikeModel($0) }

        // ccswitch 同步/迁移闭包:统一处理「家族不变 → 原地 sync」与「家族变化 → 迁移」。
        // 真实事故:claude 网关刷新后 /models 返回全 gpt,refresh 把 gpt 列表写入 claude provider,
        // claudeEnv 过滤掉非-claude 模型 → settings_config 只剩 url+token 无 ANTHROPIC_MODEL*,
        // Claude Code 回退默认模型打第三方 URL 必失败。修复:按刷新后模型重路由 appType,
        // 不匹配则删旧 provider 建新 provider,并更新 entry.targets/ccProviderID/models/model。
        // 返回需要附加到用户消息的 warning(若有);entry 可能被就地修改。
        func ccSyncOrMigrate(_ entry: inout HistoryEntry, models: [String]) -> String? {
            guard entry.targets.contains(where: { $0.hasPrefix("ccswitch") }),
                  let oldPid = entry.ccProviderID,
                  let url = entry.url, let key = entry.key, !key.isEmpty
            else { return nil }
            let oldTag = entry.targets.first(where: { $0.hasPrefix("ccswitch") }) ?? "ccswitch"
            let oldAppType = oldTag.hasPrefix("ccswitch-")
                ? String(oldTag.dropFirst("ccswitch-".count)) : "claude"
            let routedAppType = Self.routeAppType(
                selectedModels: [], modelsOverride: models, default: oldAppType, forced: false
            )
            // The Grok preference controls new imports. An existing Grok entry
            // remains in Grok Build while it is being refreshed.
            let newAppType = routedAppType
            if newAppType == "grok" {
                do {
                    let writer = GrokBuildWriter(configPath: entry.grokConfigPath)
                    let msg = try writer.sync(
                        baseURL: url,
                        key: key,
                        models: models,
                        removing: previousModels
                    )
                    entry.targets.append("grok")
                    entry.grokConfigPath = writer.configPath
                    entry.models = models
                    entry.model = models.first
                    // 旧 cc provider 删除成功才解除认领:try? 失败时 provider 仍活在
                    // cc-switch,若照旧摘掉 ccswitch 标签+pid,它就成 delete/reconcile
                    // 都不认领的孤儿(与 add() 的「删成功才摘牌」守卫口径一致)。
                    // 失败则 grok/cc 标签并存,后续 delete 会继续清 cc 侧
                    do {
                        _ = try cc.remove(providerID: oldPid, renamedFrom: entry.ccRenamedFrom,
                                          renamedTo: entry.ccRenamedTo, appType: oldAppType)
                        entry.targets.removeAll { $0.hasPrefix("ccswitch") }
                        entry.ccProviderID = nil
                        entry.ccRenamedFrom = nil
                        entry.ccRenamedTo = nil
                        return "已迁移: \(oldAppType) → Grok Build(\(msg))"
                    } catch {
                        return "已迁移 Grok Build(\(msg)),但旧 \(oldAppType) provider 清理失败,账本仍认领它可再删: \(error.localizedDescription)"
                    }
                } catch {
                    return "⚠ 迁移到 Grok Build 失败: \(error.localizedDescription)"
                }
            }
            // 家族不变:原地 sync models,不动 targets/pid
            if newAppType == oldAppType {
                var p = ParsedKey()
                p.url = url; p.key = key; p.model = models.first ?? entry.model
                do { try cc.syncModelsAfterRefresh(p, providerID: oldPid, appType: oldAppType, models: models, proxy: proxyForHealth()) }
                catch { return "⚠ cc-switch 同步失败: \(error.localizedDescription)" }
                return nil
            }
            // 家族变化:删旧建新。newTag 仅替换 ccswitch* 前缀,其他 targets(dsh/cpa/clash)原样保留
            let newTag = "ccswitch" + (newAppType == "claude" ? "" : "-\(newAppType)")
            var p = ParsedKey()
            p.url = url; p.key = key; p.model = models.first ?? entry.model
            _ = try? cc.remove(providerID: oldPid, renamedFrom: nil, renamedTo: nil, appType: oldAppType)
            do {
                let r = try cc.add(p, nameOverride: entry.name, appType: newAppType, models: models, proxy: proxyForHealth())
                entry.targets = entry.targets.filter { !$0.hasPrefix("ccswitch") } + [newTag]
                entry.ccProviderID = r.providerID
                entry.models = models
                entry.model = models.first
                return "已迁移: \(oldAppType) → \(newAppType)\(r.warnings.isEmpty ? "" : " (\(r.warnings.joined(separator: "; ")))")"
            } catch {
                // 迁移失败比 sync 失败严重:旧 provider 已删,新 provider 没建出来 → 该 entry 在 cc-switch 里孤儿。
                // 重建旧 app_type 的 provider 尽力补救(旧 pid 不可复用——remove 已删且 cc-switch 内存可能仍持有),
                // 把 entry 指回新建的回滚 provider 并提示 reimport。
                var p2 = ParsedKey()
                p2.url = url; p2.key = key; p2.model = models.first ?? entry.model
                if let rb = try? cc.add(p2, nameOverride: entry.name, appType: oldAppType, models: models, proxy: proxyForHealth()) {
                    entry.ccProviderID = rb.providerID
                }
                return "⚠ 迁移失败已回滚: \(error.localizedDescription);建议重新导入该 key"
            }
        }

        func grokSyncOrMigrate(_ entry: inout HistoryEntry, models: [String]) -> String? {
            guard entry.targets.contains("grok"),
                  let url = entry.url, let key = entry.key, !key.isEmpty else { return nil }
            let routedAppType = Self.routeAppType(
                selectedModels: [], modelsOverride: models, default: "grok", forced: false
            )
            // The Grok preference controls new imports. An existing Grok entry
            // remains in Grok Build while it is being refreshed.
            let newAppType = routedAppType
            if newAppType == "grok" {
                do {
                    let writer = GrokBuildWriter(configPath: entry.grokConfigPath)
                    let msg = try writer.sync(
                        baseURL: url,
                        key: key,
                        models: models,
                        removing: previousModels
                    )
                    entry.grokConfigPath = writer.configPath
                    entry.models = models
                    entry.model = models.first
                    return "Grok Build 已同步(\(msg))"
                } catch {
                    return "⚠ Grok Build 同步失败: \(error.localizedDescription)"
                }
            }

            var p = ParsedKey()
            p.url = url
            p.key = key
            p.model = models.first
            do {
                let r = try cc.add(p, nameOverride: entry.name,
                                   appType: newAppType, models: models, proxy: proxyForHealth())
                // 新 cc provider 已建;删旧 grok route 成功才摘 grok 牌。
                // 删除失败(锁/IO)时旧 [model.*] 表仍在,若照旧 removeAll("grok")
                // 会留下无人认领的 grok 段 —— 保留 grok 标签让 delete 继续负责清理
                entry.targets.append(newAppType == "claude" ? "ccswitch" : "ccswitch-\(newAppType)")
                entry.ccProviderID = r.providerID
                entry.ccRenamedFrom = r.renamedFrom
                entry.ccRenamedTo = r.renamedTo
                entry.models = models
                entry.model = models.first
                var grokNote = ""
                if let path = entry.grokConfigPath {
                    do {
                        _ = try GrokBuildWriter(configPath: path).remove(
                            baseURL: url, key: key,
                            models: entry.models ?? (entry.model.map { [$0] } ?? [])
                        )
                        entry.targets.removeAll { $0 == "grok" }
                    } catch {
                        grokNote = "(旧 grok 段清理失败,账本仍认领:\(error.localizedDescription))"
                    }
                } else {
                    entry.targets.removeAll { $0 == "grok" }
                }
                return "已迁移: Grok Build → \(newAppType)\(grokNote)"
            } catch {
                return "⚠ Grok Build → \(newAppType) 迁移失败: \(error.localizedDescription)"
            }
        }

        if testModels.isEmpty {
            // 端点无模型列表也同步: wire_api 探测(chat-only 网关)需保持 DB/config 新鲜
            let migrateNote = grokSyncOrMigrate(&entry, models: currentModels.sorted())
                ?? ccSyncOrMigrate(&entry, models: currentModels.sorted())
            // 必须在 ccSyncOrMigrate 之后再落盘:它可能就地修改 entry(targets/ccProviderID/models),
            // 提前落盘会把迁移结果丢掉,而旧 provider 已删 → 历史指向已删 provider 的孤儿态
            // (下面「模型无变化」分支即为此处的正确写法)
            try history.update(entry)
            let keep = currentModels.isEmpty ? "无" : currentModels.joined(separator: ", ")
            let q = quotaNote.map { "(\($0) — 充值后刷新自动恢复)" } ?? ""
            let m = migrateNote.map { "\n\($0)" } ?? ""
            return "✓ \(quotaNote != nil ? "端点可用但无额度" : "可用"): \(test.detail) (端点无模型列表,保留已有模型: \(keep))\(q)\(m)"
        }
        let modelsChanged = currentModels != Set(testModels)

        if !modelsChanged {
            historyUpdateLogged(entry)
            // 模型无变化也同步: wire_api 探测可能已变化(chat-only 网关)且 DB/config 需保持新鲜
            let migrateNote = grokSyncOrMigrate(&entry, models: currentModels.sorted())
                ?? ccSyncOrMigrate(&entry, models: currentModels.sorted())
            try history.update(entry)
            let q = quotaNote.map { " ⚠ \($0) — 充值后刷新自动恢复" } ?? ""
            let m = migrateNote.map { "\n\($0)" } ?? ""
            return "✓ 可用: \(test.detail) (\(test.models.count) 个模型,无变化)\(q)\(m)"
        }

        var filtered: [String] = []
        if let picker = pickModels {
            let sel = picker(testModels)
            if sel.isEmpty {
                // 取消选择也是一次有效测试结果,落盘 health 再抛,避免结果丢失
                historyUpdateLogged(entry)
                throw ParseError.io("已取消选择模型")
            }
            // 刷新时保留用户勾选/手输,不因启发式误杀
            filtered = sel.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        } else {
            filtered = testModels
        }
        guard !filtered.isEmpty else {
            historyUpdateLogged(entry)
            throw ParseError.io("测试通过但未识别到模型,无法刷新")
        }
        entry.models = filtered
        entry.model = filtered.first

        var syncWarn: String? = nil
        // 主分支:模型已变化,ccSyncOrMigrate 会按新模型列表决定原地 sync 还是迁移家族
        syncWarn = grokSyncOrMigrate(&entry, models: filtered)
            ?? ccSyncOrMigrate(&entry, models: filtered)

        if entry.targets.contains("dsh") {
            _ = try DSHWriter.add(providerID: entry.id, key: key, url: url, models: filtered)
        }
        try history.update(entry)
        let q = quotaNote.map { " ⚠ \($0) — 充值后刷新自动恢复" } ?? ""
        let w = syncWarn.map { "\n\($0)" } ?? ""
        return "✓ 可用: \(test.detail) (\(test.models.count) 个模型,已更新 \(filtered.count) 个)\(q)\(w)"
    }

    /// 编辑条目:改模型列表/名称,重新验证模型并同步所有目标(cc-switch/dsh)
    public func editEntry(
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
        let previousModels = entry.models ?? (entry.model.map { [$0] } ?? [])
        var newModels = previousModels

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

        let routedAppType = Self.routeAppType(
            selectedModels: [], modelsOverride: newModels,
            default: entry.targets.contains("grok") ? "grok" : "opencode"
        )
        // Editing an existing entry preserves its current target family. The
        // preference is an import switch, not a destructive migration switch.
        let desiredAppType = routedAppType

        // Editing can change a provider family. Keep Grok Build and cc-switch
        // mutually exclusive for the selected model set.
        if desiredAppType == "grok",
           entry.targets.contains(where: { $0.hasPrefix("ccswitch") }) {
            do {
                let writer = GrokBuildWriter(configPath: entry.grokConfigPath)
                let msg = try writer.sync(baseURL: url, key: key, models: newModels, removing: [])
                if let pid = entry.ccProviderID {
                    let oldTag = entry.targets.first(where: { $0.hasPrefix("ccswitch") }) ?? "ccswitch"
                    let oldApp = oldTag.hasPrefix("ccswitch-")
                        ? String(oldTag.dropFirst("ccswitch-".count)) : "claude"
                    _ = try? cc.remove(providerID: pid, renamedFrom: entry.ccRenamedFrom,
                                       renamedTo: entry.ccRenamedTo, appType: oldApp)
                }
                entry.targets.removeAll { $0.hasPrefix("ccswitch") }
                if !entry.targets.contains("grok") { entry.targets.append("grok") }
                entry.ccProviderID = nil
                entry.ccRenamedFrom = nil
                entry.ccRenamedTo = nil
                entry.grokConfigPath = writer.configPath
                lines.append("✓ Grok Build: \(msg)")
            } catch {
                lines.append("⚠ Grok Build 同步失败: \(error.localizedDescription)")
            }
        } else if desiredAppType == "grok", entry.targets.contains("grok") {
            do {
                let writer = GrokBuildWriter(configPath: entry.grokConfigPath)
                let msg = try writer.sync(
                    baseURL: url,
                    key: key,
                    models: newModels,
                    removing: previousModels
                )
                entry.grokConfigPath = writer.configPath
                lines.append("✓ Grok Build: \(msg)")
            } catch {
                lines.append("⚠ Grok Build 同步失败: \(error.localizedDescription)")
            }
        } else if desiredAppType != "grok", entry.targets.contains("grok") {
            var p = ParsedKey()
            p.url = url
            p.key = key
            p.model = newModels.first
            do {
                let r = try cc.add(p, nameOverride: entry.name,
                                   appType: desiredAppType, models: newModels, proxy: proxyForHealth())
                if let path = entry.grokConfigPath {
                    _ = try? GrokBuildWriter(configPath: path).remove(
                        baseURL: url, key: key,
                        models: previousModels
                    )
                }
                entry.targets.removeAll { $0 == "grok" }
                entry.targets.append(desiredAppType == "claude" ? "ccswitch" : "ccswitch-\(desiredAppType)")
                entry.ccProviderID = r.providerID
                entry.ccRenamedFrom = r.renamedFrom
                entry.ccRenamedTo = r.renamedTo
                lines.append("✓ 已迁移: Grok Build → \(desiredAppType)")
            } catch {
                lines.append("⚠ Grok Build → \(desiredAppType) 迁移失败: \(error.localizedDescription)")
            }
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
                try cc.syncModelsAfterRefresh(p, providerID: pid, appType: appType, models: newModels, proxy: proxyForHealth())
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

    public func activateCPA(entryIDPrefix: String) throws -> String {
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
        // CPA can aggregate multiple keys and Grok Build stores one key per
        // model table. A CPA activation therefore falls back to OpenCode for
        // pure Grok model lists instead of attempting an unsupported app type.
        // 空模型列表同样默认 opencode:未探测/多 key 条目误默认 claude 会把
        // CPA 端点激活到 Claude Code(nvapi 批量导入被显示为 claude 的事故面)
        let routedAppType = Self.routeAppType(selectedModels: models, modelsOverride: nil, default: "opencode")
        let appType = routedAppType == "grok" ? "opencode" : routedAppType

        var p = ParsedKey()
        p.url = ep.baseURL
        p.key = ep.clientKey
        p.model = models.first
        p.name = "CPA-\(ep.baseURL)"

        // 重复激活:先移除本条目上一次激活写入的 provider。
        // claude 类型没有 URL 去重,不清理的话每次激活都在 cc-switch 新建一个,
        // 旧 provider 变孤儿(无人认领、历史也不再指向它)
        if let oldPID = entry.ccProviderID,
           entry.targets.contains(where: { $0.hasPrefix("ccswitch") }) {
            let oldAppType = entry.targets.first(where: { $0.hasPrefix("ccswitch-") })
                .map { String($0.dropFirst("ccswitch-".count)) } ?? "claude"
            if cc.providerExists(id: oldPID, appType: oldAppType) {
                do {
                    _ = try cc.remove(providerID: oldPID, renamedFrom: entry.ccRenamedFrom,
                                      renamedTo: entry.ccRenamedTo, appType: oldAppType)
                } catch {
                    // 清理失败不阻断本次激活,只留痕
                    AppLog.warn("activateCPA 清理旧 provider 失败: \(error.localizedDescription)")
                }
            }
        }

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

    public func delete(entryIDPrefix: String) throws -> String {
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
            if let cfg = entry.cpaConfigPath,
               let keys = extractAllKeys(for: entry), !keys.isEmpty {
                do {
                    let msg = try CPAWriter(configPath: cfg).remove(apiKeys: keys)
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
            // 清理生成的订阅文件:只认 basename 且拼回 profiles 目录内,
            // 防止历史里的 clashFile 被篡改成任意路径
            var removedFile: String? = nil
            if let cf = entry.clashFile, !cf.isEmpty {
                let base = (cf as NSString).lastPathComponent
                // 防历史被篡改后误删任意文件:只允许安全文件名。
                // lastPathComponent 挡不住 "."/"..":配合目录递归删除,
                // ".." 能穿透到 profiles 的父目录(mihomo-party 整个目录)
                let safeName = base.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*\.yaml$"#, options: .regularExpression) != nil
                    && base != "." && base != ".."
                var isRegular = false
                if safeName {
                    let full = (ClashWriter.profilesDir as NSString).appendingPathComponent(base)
                    if full.hasPrefix(ClashWriter.profilesDir + "/"),
                       let attrs = try? FileManager.default.attributesOfItem(atPath: full),
                       let type = attrs[.type] as? FileAttributeType {
                        isRegular = (type == .typeRegular)
                    }
                    if isRegular, (try? FileManager.default.removeItem(atPath: full)) != nil {
                        removedFile = base
                    }
                }
            }
            if let f = removedFile {
                lines.append("✓ Clash: 已删除订阅文件 \(f)")
            } else {
                // 旧条目没有 clashFile、文件已不在、或删除失败:如实告知
                lines.append("✓ Clash: 已从 KeyDrop 目标列表移除(订阅 yaml 仍保留在 profiles 目录,可手动删除)")
            }
        }

        if entry.targets.contains("grok") {
            if let path = entry.grokConfigPath,
               let url = entry.url,
               let key = entry.key, !key.isEmpty {
                do {
                    let msg = try GrokBuildWriter(configPath: path).remove(
                        baseURL: url,
                        key: key,
                        models: entry.models ?? (entry.model.map { [$0] } ?? [])
                    )
                    lines.append("✓ Grok Build: \(msg)")
                    remaining.removeAll { $0 == "grok" }
                } catch {
                    failures.append("Grok Build: \(error.localizedDescription)")
                }
            } else {
                failures.append("Grok Build: 历史记录缺少配置路径、URL 或 key")
            }
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

    /// 取条目对应的所有 key:单 key 条目走 extractKey;多 key 条目(cpa-multikey)用 extractAllKeys 从 raw 提全。
    /// 返回 nil 表示无法恢复任何 key,调用方应跳过删除并报告失败。
    private func extractAllKeys(for e: HistoryEntry) -> [String]? {
        if let key = e.key, !key.isEmpty { return [key] }
        let fromRaw = Parser.extractAllKeys(e.raw)
        if fromRaw.isEmpty {
            return (try? Parser.parse(e.raw)).flatMap { $0.key.map { [$0] } }
        }
        return fromRaw
    }

    public func list(limit: Int = 20) -> String {
        var out: [String] = []
        for e in history.snapshot().prefix(limit) {
            let mark = e.status == "active" ? "●" : "○"
            out.append("\(mark) \(e.id.prefix(8)) \(e.timeStr) \(e.summary) [\(e.targets.joined(separator: "+"))]")
        }
        return out.isEmpty ? "(无历史记录)" : out.joined(separator: "\n")
    }
}
