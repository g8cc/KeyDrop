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

    /// 代理输入规范化(真实反馈:顶部代理框要手打一整串 URL 还显示不全)。
    /// "7890" → http://127.0.0.1:7890;"host:port" → http://host:port;
    /// 已带 scheme 原样保留。纯函数,供单测。
    public static func normalizeProxyInput(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return "" }
        if s.contains("://") { return s }
        if s.count <= 5, let port = Int(s), port > 0, port <= 65535 {
            return "http://127.0.0.1:\(s)"
        }
        if s.contains(":"),
           let comps = URLComponents(string: "http://" + s),
           comps.host != nil, comps.host?.isEmpty == false, comps.port != nil {
            return "http://" + s
        }
        return s
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
        magpieOverride: Bool? = nil,
        models: [String]? = nil,
        force: Bool = false,
        appType: String? = nil,
        appTypeForced: Bool = false,
        proxy: String? = nil,
        operation: ImportOperation? = nil,
        pickModels: (([String]) -> [String])? = nil
    ) throws -> AddOutcome {
        var stage = "parse"
        let choose: (([String]) -> [String])? = pickModels.map { picker in
            { options in
                if let operation {
                    do {
                        try operation.advance(to: .choosingModels)
                        try operation.checkCancellation()
                    }
                    catch { return [] }
                }
                let selection = picker(options)
                if !selection.isEmpty { try? operation?.advance(to: .verifying) }
                return selection
            }
        }
        do {
            let outcome = try ImportOperation.$current.withValue(operation) {
                try operation?.advance(to: .parsing)
                return try addImpl(raw: raw, ccOverride: ccOverride, grokOverride: grokOverride,
                                   cpaOverride: cpaOverride, dshOverride: dshOverride,
                                   magpieOverride: magpieOverride,
                                   models: models, force: force, appType: appType,
                                   appTypeForced: appTypeForced, proxy: proxy,
                                   pickModels: choose, stage: &stage)
            }
            for line in outcome.lines where line.contains("✗") || line.contains("失败") {
                ImportFailureLog.record(ParseError.io(line), stage: ImportFailureLog.stage(forLine: line))
            }
            return outcome
        } catch {
            try operation?.checkCancellation()
            ImportFailureLog.record(error, stage: stage)
            throw error
        }
    }

    /// Explicit import for credentials that must be exercised by the real DSH client.
    public func addDSHOnly(raw: String, models override: [String]? = nil, operation: ImportOperation? = nil) throws -> AddOutcome {
        try operation?.advance(to: .parsing)
        guard raw.utf8.count <= 1_000_000 else { throw ParseError.io("粘贴内容过大") }
        let parsed = try Parser.parse(raw)
        guard let url = parsed.url else { throw ParseError.noURL }
        guard let key = parsed.key, !key.isEmpty else { throw ParseError.noKeyFound("解析未得到 key。") }
        guard Set(Parser.extractAllKeys(raw) + [key]).count == 1 else {
            throw ParseError.io("DSH 专用导入每次只接受一个 API key")
        }
        var seen = Set<String>()
        let models = (override ?? parsed.models ?? parsed.model.map { [$0] } ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !Self.isNonChatModel($0) && seen.insert($0).inserted }
        guard !models.isEmpty else { throw ParseError.io("DSH 专用导入需要填写可用于对话的完整模型 ID") }

        let existing = history.findActiveByKey(key)
        if let existing, existing.isCredentialPool || existing.url != url || !Set(existing.targets).isSubset(of: ["dsh"]) {
            throw ParseError.duplicate(id: existing.id, message: "同一凭据已绑定其他地址或同步目标，请先处理旧记录")
        }
        var entry = existing ?? HistoryEntry(
            id: UUID().uuidString.lowercased(), ts: Date().timeIntervalSince1970,
            raw: raw, format: "dsh-only", name: parsed.name ?? cc.defaultName(for: url),
            url: url, model: models.first, models: models, key: key, keyMasked: parsed.keyMasked,
            targets: ["dsh"], ccProviderID: nil, ccRenamedFrom: nil, ccRenamedTo: nil,
            cpaConfigPath: nil, status: "active")
        entry.raw = raw
        entry.format = "dsh-only"
        entry.model = models.first
        entry.models = models
        entry.targets = ["dsh"]
        entry.health = nil
        entry.healthAt = nil
        entry.healthDetail = "DSH 专用 · 请在 DSH 内发起对话验证"
        entry.failStreak = nil
        entry.latencyMs = nil
        entry.apiStyle = nil
        try operation?.advance(to: .writing)
        let route = try DSHWriter.add(providerID: entry.id, key: key, url: url, models: models)
        do {
            if existing != nil {
                try history.update(entry)
            } else if let duplicate = try history.appendDedupByKey(entry) {
                throw ParseError.duplicate(id: duplicate.id, message: "另一进程已导入同一凭据，请重试")
            }
        } catch {
            if let existing, let previousModels = existing.models ?? existing.model.map({ [$0] }) {
                try? DSHWriter.add(providerID: entry.id, key: key, url: url, models: previousModels)
            } else {
                try? DSHWriter.remove(providerID: entry.id)
            }
            throw error
        }
        return AddOutcome(entry: entry, lines: [
            "✓ DeepSeek Harness: 已写入 \(route)（\(models.count) 个模型）",
            "DSH 专用 · 请在 DSH 内发起对话验证"
        ], ok: true)
    }

    private func addImpl(
        raw: String, ccOverride: Bool?, grokOverride: Bool?, cpaOverride: Bool?,
        dshOverride: Bool?, magpieOverride: Bool?, models: [String]?, force: Bool, appType: String?,
        appTypeForced: Bool, proxy: String?, pickModels: (([String]) -> [String])?,
        stage: inout String
    ) throws -> AddOutcome {
        let operation = ImportOperation.current
        let appType = appType ?? Core.defaultAppType
        AppLog.info("add 开始(force=\(force))")
        defer { AppLog.info("add 结束") }
        // 输入上限:raw 会被原样存进历史(JSON 落盘),而解析是逐行/逐 token 的
        // O(n) 甚至 O(n²) 扫描。粘贴几十 MB(误粘日志/二进制转文本)会让
        // 解析 + 历史序列化卡住整个应用,并把 ~/.keydrop 撑到不可用。
        // 正常粘贴内容(含 zip 路径、订阅 URL)都是 KB 级,1MB 已极宽松。
        let maxRawBytes = 1_000_000
        if raw.utf8.count > maxRawBytes {
            throw ParseError.io("粘贴内容过大(\(raw.utf8.count / 1000)KB > \(maxRawBytes / 1000)KB),已拒绝处理。请只粘贴 key 相关片段,或改用文件路径/zip 导入。")
        }
        let proxyURL: String? = {
            if let proxy, !proxy.isEmpty { return proxy }
            let p = prefs.proxy
            if !p.isEmpty { return p }
            // 用户确认本机代理常开:设置未填时自动探测本机代理,直连失败会自动补测
            guard ProcessInfo.processInfo.environment["KEYDROP_NO_AUTOPROXY"] != "1" else { return nil }
            return Core.detectLocalProxy()
        }()
        let rawLines = raw.split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // 只统计能真正解析的代理行(如 socks5:// 会被 isProxyURL 认可但解析不了),
        // 否则混入不支持的协议会把正常 key 粘贴误判为 Clash 导入并报错
        let proxyCount = rawLines.filter { Parser.parseProxyURL($0) != nil }.count
        let clashOnly = proxyCount > 0 && proxyCount * 2 >= rawLines.count

        if clashOnly {
            stage = "write_clash"
            var proxies: [ClashProxy] = []
            for l in rawLines {
                if let p = Parser.parseProxyURL(l), !p.server.isEmpty, p.port > 0, !p.uuid.isEmpty {
                    proxies.append(p)
                }
            }
            guard !proxies.isEmpty else { throw ParseError.io("未识别到有效的代理节点") }
            try operation?.advance(to: .writing)
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
            // prefs 落盘失败(磁盘满)不应让已成功的订阅导入整体报错进失败日志:
            // 与主路径同口径,降级为警告行
            var clashLines = [msg]
            do { try prefs.save() } catch { clashLines.append("⚠ 偏好保存失败: \(error.localizedDescription)") }
            return AddOutcome(entry: entry, lines: clashLines, ok: true)
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
            try operation?.advance(to: .writing)
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
            var subLines = [msg]
            do { try prefs.save() } catch { subLines.append("⚠ 偏好保存失败: \(error.localizedDescription)") }
            return AddOutcome(entry: entry, lines: subLines, ok: true)
        }

        try operation?.checkCancellation()
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
        var urlReusedNote: String? = nil   // 验证失败抛错时也必须能看到复用了谁(成功路径 notes 已含)
        if parsed.url == nil {
            // 防呆:输入里残留「像域名」的 token(解析器没认成 URL)时,静默复用上次
            // 记录几乎必然拿新 key 去测旧 URL(真实事故:tokenhub.icu/v1 漏判 →
            // 测 xiaoshengapi.top → 401,报错也看不出复用了谁)。明确报错让用户修正
            if let suspected = Parser.firstDomainLikeToken(raw) {
                throw ParseError.io(
                    "未找到可用 URL。输入中的「\(suspected)」疑似网址但未被识别为 URL"
                    + "(支持形态:https://host[/path]、裸域名 host[:端口][/路径])。"
                    + "请修正该行后重试;若确想复用上次记录,请删除该行。")
            }
            if let last = history.lastURL() {
                parsed.url = last
                urlReusedNote = "URL 复用上次: \(last)"
                notes.append(urlReusedNote!)
            } else {
                throw ParseError.noURL
            }
        }
        guard let url = parsed.url else { throw ParseError.noURL }
        guard let key = parsed.key, !key.isEmpty else {
            throw ParseError.noKeyFound("解析未得到 key。")
        }

        let allKeys = Parser.extractAllKeys(raw)
        // 池内成员不可再被单 key 导入覆盖；多 key 任一成员重叠也必须先处理旧记录。
        // 在写产物前检查整个集合，不能只查解析得到的第一把 key。
        if allKeys.count > 1 {
            let incomingKeys = Set(allKeys)
            if let existing = history.snapshot().first(where: {
                $0.status == "active" && !incomingKeys.isDisjoint(with: $0.credentialKeys)
            }) {
                throw ParseError.duplicate(id: existing.id, message: "部分凭据已属于既有记录，请编辑原记录或移除重复凭据后重试")
            }
        }
        var dup: HistoryEntry? = nil
        if let d = history.findActiveByKey(key) {
            if d.isCredentialPool {
                throw ParseError.duplicate(id: d.id, message: "该凭据属于多 key 池，请编辑原池；单 key 导入不能覆盖整个池")
            }
            if d.isDSHOnly {
                throw ParseError.duplicate(id: d.id, message: "这是 DSH 专用记录，请通过「仅导入 DSH」更新")
            }
            if (d.url ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == url {
                dup = d
                notes.append("幂等更新: 同 key 同 URL 已存在(\(d.id.prefix(8))),将刷新该条目而非新建")
            } else if !force {
                throw ParseError.duplicate(
                    id: d.id,
                    message: "该 API key 已存在(\(d.id) · \(d.summary)),但 URL 不同(\(d.url ?? "") vs \(url))。"
                        + "如需覆盖请先删除旧记录,或 CLI 使用 --force。"
                )
            } else {
                // --force 语义 = 覆盖:把旧条目当作 dup 走幂等更新链路(URL 换新、
                // 旧 provider 清理)。不能放任 dup 为 nil —— 那样最后 appendDedupByKey
                // 仍会按 key 命中旧条目,新 URL 被静默丢弃、刚写的 provider 被回滚
                dup = d
                notes.append("force 覆盖: 同 key 已存在(\(d.id.prefix(8))),URL \(d.url ?? "") → \(url)")
            }
        }

        if allKeys.count > 1 {
            stage = "multikey_cpa"
            let useCPA = cpaOverride ?? prefs.useCPA
            guard useCPA else {
                throw ParseError.io("检测到 \(allKeys.count) 个 key,多 key 仅支持写入 CPA。请启用 CPA(--cpa) 或单独添加单个 key。")
            }
            guard let cfg = prefs.resolvedCPAConfig() else {
                throw ParseError.io("检测到多 key,需要写入 CPA 但未找到 config.yaml")
            }
            try operation?.advance(to: .verifying)
            // 多 key 粘贴此前直接落「探测全量」(真实反馈:midjok.lol 1 URL + 2 key
            // 导入 26 个模型,含 audio/realtime/codex-auto-review,用户没得选)。
            // 显式 --model 优先,否则走与单 key 同一套勾选弹窗
            let explicitModels = (models ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let chooser: (([String]) -> [String])? = !explicitModels.isEmpty
                ? { _ in explicitModels }
                : pickModels
            let (msg, probedModels, acceptedKeys) = try CPAWriter(configPath: cfg)
                .addMulti(baseURL: url, keys: allKeys, proxy: proxyURL, pickModels: chooser)
            prefs.cpaConfigPath = cfg
            var multiLines = [msg]
            // 常驻模型来源 = 条目最终 models(已有精选时即精选列表);
            // 空(探测失败且无既有列表)传 nil 回退收集其它条目的精选
            multiLines.append(contentsOf: syncCPAResidentEntries(models: probedModels.isEmpty ? nil : probedModels))
            var entry = HistoryEntry(
                id: UUID().uuidString.lowercased(),
                ts: Date().timeIntervalSince1970,
                raw: raw,
                format: "cpa-multikey",
                name: parsed.name,
                url: url,
                model: probedModels.first ?? parsed.model,
                models: probedModels.isEmpty ? nil : probedModels,
                key: nil,
                keyMasked: "\(acceptedKeys.count) 个 key",
                targets: ["cpa"],
                ccProviderID: nil,
                ccRenamedFrom: nil,
                ccRenamedTo: nil,
                cpaConfigPath: cfg,
                status: "active"
            )
            entry.poolKeys = acceptedKeys
            do {
                if let existing = try history.appendDedupByKey(entry) {
                    throw ParseError.duplicate(id: existing.id, message: "探测期间另一进程已认领池内凭据，请移除重复凭据后重试")
                }
            } catch {
                // 网络探测期间可能有另一端导入。只回滚本次未被其他活跃记录认领的凭据，
                // 保留胜出者的 CPA key，不能留下无人负责清理的新池成员。
                let owned = Set(history.snapshot().filter {
                    $0.status == "active" && $0.targets.contains("cpa") &&
                        Parser.normalizeURL($0.url ?? "") == Parser.normalizeURL(url)
                }.flatMap(\.credentialKeys))
                let unclaimed = acceptedKeys.filter { !owned.contains($0) }
                if !unclaimed.isEmpty {
                    do { _ = try CPAWriter(configPath: cfg).remove(apiKeys: unclaimed, baseURL: url) }
                    catch let rollbackError {
                        throw ParseError.io("账本保存失败: \(error.localizedDescription);CPA 回滚失败: \(rollbackError.localizedDescription)")
                    }
                }
                throw error
            }
            do { try prefs.save() } catch { multiLines.append("⚠ 偏好保存失败: \(error.localizedDescription)") }
            return AddOutcome(entry: entry, lines: multiLines, ok: true)
        }

        var name = parsed.name?.isEmpty == false ? parsed.name! : cc.defaultName(for: url)
        stage = "verify"
        if !force { try operation?.advance(to: .verifying) }
        parsed.name = name

        let requestedModels = (models ?? parsed.models ?? parsed.model.map { [$0] } ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var requestedChatModels: [String] = []
        for model in requestedModels
        where !Core.isNonChatModel(model) && !requestedChatModels.contains(model) {
            requestedChatModels.append(model)
        }
        var selectedModels: [String] = []
        // 结果是否来自 picker(用户在弹窗里从真实 /models 列表勾选或手输)。
        // picker 结果不得再过 looksLikeModel 去噪(见下方 strict 过滤处注释)
        var pickedViaPicker = false
        // 已被真实 chat 请求验证可用的模型:同理不得再被 looksLikeModel 启发式误杀
        var chatVerifiedModels: Set<String> = []
        var addHealth: (health: String, detail: String)? = nil
        var probedNeedsProxy = false
        // 导入时的完整探测结果:落监控用的模型级探测点(此前只有刷新写点,
        // 新导入条目的模型在监控里全灰到第一次扫描/刷新)
        var probedTest: APITestResult? = nil
        var verifiedStyle: String?
        // A normalized root loses /responses or /messages. Retain the selected input's
        // protocol; only reuse prior evidence when the provider address is unchanged.
        let inputStyle = parsed.apiStyle ?? (dup?.url == url ? dup?.apiStyle : nil)
        if !force {
            // 必须带上解析出的模型做优先探测。真实事故(vyceai, 2026-09-23):粘贴块里
            // 带了模型 deepseek-v4.1,但这里没传 preferredModel,探测按站点目录轮换,
            // 第二个就撞上该站对部分模型按 key 限权(qwen3.8-flash 403),整次导入被误判
            // 失败;手测 deepseek-v4.1 chat 200 完全正常。v1.4.17 修了监控/重测/单条目
            // 三处调用,唯独漏了导入这条路径。
            let test = APITester.test(url: url, key: key, proxy: proxyURL,
                                      preferredModel: requestedChatModels.first ?? parsed.model,
                                      importedModels: requestedChatModels.isEmpty ? parsed.models : requestedChatModels,
                                      styleHint: inputStyle)
            probedTest = test
            try operation?.checkCancellation()
            let hasProxy = proxyURL?.isEmpty == false
            var explicitSelectedModels: [String]? = nil
            var explicitCanRescue = false
            var explicitNeedsProxy = false
            var pastedModelsFailed = false
            if !requestedModels.isEmpty {
                if requestedChatModels.isEmpty {
                    explicitSelectedModels = requestedModels
                } else {
                    var verified: [String] = []
                    var failures: [String] = []
                    let alreadyWorking = Set(test.ok ? test.workingModels : [])
                    for model in requestedChatModels {
                        try operation?.checkCancellation()
                        // 探测阶段已 chat 验证过的模型不再重复打一遍(每个模型最多 2 路径×12s)
                        if alreadyWorking.contains(model) {
                            verified.append(model)
                            continue
                        }
                        // 已确认需代理的网关直连必然超时,先直连只会白等;
                        // 其余情况先直连:验证端点拿到代理就只走代理(无直连回退),
                        // 本机代理对回环 mock/内网目标会返 502,反而把验证搞挂(真实回归事故)
                        if !(test.needsProxy && hasProxy) {
                            let direct = APITester.testModelChat(base: url, key: key, model: model, styleHint: test.style)
                            if direct.ok {
                                verifiedStyle = direct.style
                                verified.append(model)
                                continue
                            }
                            if !hasProxy {
                                failures.append("\(model) → \(direct.detail)")
                                continue
                            }
                        }
                        let viaProxy = APITester.testModelChat(base: url, key: key, model: model, proxy: proxyURL, styleHint: test.style)
                        if viaProxy.ok {
                            verifiedStyle = viaProxy.style
                            verified.append(model)
                            explicitNeedsProxy = true
                            continue
                        }
                        failures.append("\(model) → \(viaProxy.detail)")
                    }
                    if verified.isEmpty {
                        let failText = failures.joined(separator: "; ")
                        // key 本身都不通:原测试失败原因(鉴权/网络)比模型验证更有信息量
                        if !test.ok {
                            throw ParseError.io("测试失败,未写入。\(test.detail)\n贴入模型验证也失败: \(failText)\(urlReusedNote.map { "\n(\($0))" } ?? "")\n(确认真实或 --force 跳过测试)")
                        }
                        // --model 显式指定:用户明确要这些模型,全挂就不能偷换成别的;
                        // 站点也没有模型目录时同样无可回落
                        if models != nil || test.models.isEmpty {
                            throw ParseError.io("贴入的 \(requestedChatModels.count) 个模型均验证失败: \(failText)")
                        }
                        // 仅来自粘贴文本的模型(可能是过期名/解析噪声),而 key 本身可用:
                        // 回落到按站点目录选模型的正常流程,不因一个旧模型名整次导入失败
                        pastedModelsFailed = true
                        notes.append("贴入模型均验证失败,改用站点模型目录(\(failures.prefix(2).joined(separator: "; "))\(failures.count > 2 ? " 等" : ""))")
                    } else {
                        explicitCanRescue = true
                        chatVerifiedModels = Set(verified)
                        explicitSelectedModels = requestedModels.filter {
                            !requestedChatModels.contains($0) || verified.contains($0)
                        }
                        if failures.isEmpty {
                            notes.append("模型验证通过: \(verified.count) 个全部可用")
                        } else {
                            notes.append("模型验证: \(verified.count) 个通过,\(failures.count) 个失败已跳过(\(failures.prefix(2).joined(separator: "; "))\(failures.count > 2 ? " 等" : ""))")
                        }
                    }
                }
            }
            try operation?.checkCancellation()
            if !test.ok && !explicitCanRescue {
                throw ParseError.io("测试失败,未写入。\(test.detail)\(urlReusedNote.map { "\n(\($0))" } ?? "")\n(确认真实或 --force 跳过测试)")
            }
            if test.ok && !(test.reachabilityOnly && explicitCanRescue) {
                addHealth = Self.healthFor(test)
            } else {
                let verified = explicitSelectedModels?.joined(separator: ", ") ?? ""
                addHealth = ("ok", "模型验证通过: \(verified)")
            }
            probedNeedsProxy = test.needsProxy || explicitNeedsProxy
            // 直连已通时不给模型验证传代理:验证端点拿到代理就直接用(无直连回退),
            // 本机代理对回环 mock/内网目标会返 502,反而把验证搞挂(真实回归事故)
            let verifyProxy = probedNeedsProxy ? proxyURL : nil
            notes.append("测试: \(test.detail)")
            if let explicitSelectedModels {
                selectedModels = explicitSelectedModels
            } else if let m = models, !m.isEmpty {
                selectedModels = m
            } else if test.models.isEmpty {
                if let picker = pickModels {
                    let picked = picker([])
                    if picked.isEmpty {
                        throw ParseError.io("已取消选择模型")
                    }
                    pickedViaPicker = true
                    // 端点无 /models 列表,模型名是用户手输的猜测值,逐一 chat 验证;
                    // 全部验证通过的都保留(用户明确勾选/输入了 N 个就应得到 N 个),
                    // 失败的只进提示,不再「第一个通过就 break」把其余的静默丢掉
                    var verified: [String] = []
                    var failures: [String] = []
                    for m in picked {
                        try operation?.checkCancellation()
                        let check = APITester.testModelChat(base: url, key: key, model: m, proxy: verifyProxy, styleHint: test.style)
                        if check.ok {
                            verifiedStyle = check.style
                            chatVerifiedModels.insert(m)
                            verified.append(m)
                        } else {
                            failures.append("\(m) → \(check.detail)")
                        }
                    }
                    if verified.isEmpty {
                        throw ParseError.io("输入的 \(picked.count) 个模型均验证失败: \(failures.joined(separator: "; "))")
                    }
                    selectedModels = verified
                    if failures.isEmpty {
                        notes.append("模型验证通过: \(verified.count) 个全部可用")
                    } else {
                        notes.append("模型验证: \(verified.count) 个通过,\(failures.count) 个失败已跳过(\(failures.prefix(2).joined(separator: "; "))\(failures.count > 2 ? " 等" : ""))")
                    }
                }
            } else if !test.workingModels.isEmpty, !test.quotaModels.isEmpty,
                      let picker = pickModels {
                // 部分模型限流(其余可用):key 是活的,但默认列表含限流项,
                // 强制弹窗让用户挑(哪怕 ≤5)。test.models 已按 working 优先、限流沉底排序,
                // 弹窗顶部即最可能可用的模型。真实事故:4 模型 1 免费可用 3 限流,
                // 旧逻辑 ≤5 自动全导,用户没法选
                let picked = picker(test.models)
                if picked.isEmpty { throw ParseError.io("已取消选择模型") }
                pickedViaPicker = true
                selectedModels = picked
                notes.append("部分模型限流(\(test.quotaModels.count) 个),已按你的选择导入 \(picked.count) 个")
            } else if !test.workingModels.isEmpty, !test.quotaModels.isEmpty {
                // CLI 无选择器:自动排除确认限流的模型(test.models 已按 working 优先重排)
                let q = Set(test.quotaModels)
                selectedModels = test.models.filter { !q.contains($0) }
                notes.append("自动排除 \(q.count) 个限流模型: \(test.quotaModels.prefix(3).joined(separator: "、"))\(q.count > 3 ? " 等" : "")")
            } else if let picker = pickModels {
                // 一律手选(用户明确要求):名义上的 SOTA 名单本身在变,而且里面不少是垃圾,
                // 所以哪怕只有 ≤5 个候选也不替用户拍板。CLI 没有选择器,才走下面的自动路径
                let picked = picker(test.models)
                if picked.isEmpty {
                    throw ParseError.io("已取消选择模型")
                }
                pickedViaPicker = true
                selectedModels = picked
            } else if test.models.count <= 5 {
                selectedModels = test.models
                notes.append("可用模型仅 \(test.models.count) 个,已全部导入")
            } else if !pastedModelsFailed, let pm = parsed.model, !pm.isEmpty {
                selectedModels = [pm]
            } else {
                // 贴入模型刚验证失败时不能再回落到它(会把已知不可用的模型写进配置)
                selectedModels = test.models
            }
        } else if let m = models, !m.isEmpty {
            selectedModels = m
        } else if let pm = parsed.model, !pm.isEmpty {
            selectedModels = [pm]
        }
        selectedModels = selectedModels.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        // looksLikeModel 只为「粘贴文本解析出的模型候选」去噪。picker 结果是用户从
        // /models JSON(data[].id)的真实模型 ID 里明确勾选(或手输)的,再过滤只会误伤:
        // step-3.7-flash / stepaudio-2.5-tts / step-3.5-flash 这类「非白名单家族+点分」
        // 新命名会被当域名整批杀掉,7 选 5 只剩无点的 step-image-edit-2(真实事故:
        // stepfun step_plan 网关)。刷新路径 refreshModels 早已「保留用户勾选/手输,
        // 不因启发式误杀」,此处对齐同一原则
        if models == nil, !pickedViaPicker {
            // 已 chat 验证可用的模型是实证,不参与启发式去噪
            let strict = selectedModels.filter { chatVerifiedModels.contains($0) || Parser.looksLikeModel($0) }
            if !strict.isEmpty {
                selectedModels = strict
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

        // 需代理网关导入 codex 的操作指引:Codex 的 config.toml 无 API 代理字段
        // (官方 config-reference,features.network_proxy 仅作用于沙箱命令),
        // 仅两条路 —— cc-switch 接管代理,或启动环境变量
        func proxyHintLine() -> String {
            let px = proxyURL?.isEmpty == false ? proxyURL! : (prefs.proxy.isEmpty ? "http://127.0.0.1:7890" : prefs.proxy)
            if CCSwitchWriter.ccSwitchRunning() {
                return "  ℹ 该网关需代理:Codex 配置不支持代理字段。可在 cc-switch「代理」面板开启 Codex 接管(出站走其已配置的全局上游代理),该 provider 即可直连被墙网关"
            }
            return "  ℹ 该网关需代理:Codex 配置不支持代理字段。启动 codex 前 export HTTPS_PROXY=\(px) HTTP_PROXY=\(px),或在 cc-switch「代理」面板开启 Codex 接管"
        }

        let useCC = ccOverride ?? prefs.useCC
        let useCPA = cpaOverride ?? prefs.useCPA
        let useDSH = dshOverride ?? prefs.useDSH
        let useMagpie = magpieOverride ?? prefs.useMagpie

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

        entry.apiStyle = verifiedStyle ?? (probedTest?.ok == true ? probedTest?.style : inputStyle)
        entry.magpieDestinationID = dup?.magpieDestinationID
        entry.targetSyncErrors = dup?.targetSyncErrors
        entry.legacyProbeInvalidated = dup?.legacyProbeInvalidated
        var lines: [String] = []
        lines.append("解析: \(parsed.format) → key=\(parsed.keyMasked)" + (parsed.model.map { " model=\($0)" } ?? ""))
        if selectedModels.count > 1 {
            let shown = selectedModels.prefix(3).joined(separator: ", ")
            let more = selectedModels.count > 3 ? " 等\(selectedModels.count)个" : ""
            lines.append("模型: \(shown)\(more)")
        }

        var anyOK = false
        stage = "write"
        try operation?.advance(to: .writing)
        noteProxyWorked(needsProxy: probedNeedsProxy, used: proxyURL)
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
                    if resolvedAppType == "codex", probedNeedsProxy {
                        lines.append(proxyHintLine())
                    }
                } else {
                    let r = try cc.add(parsed, appType: resolvedAppType, models: selectedModels, proxy: proxyURL)
                    entry.targets.append(appTag)
                    entry.ccProviderID = r.providerID
                    entry.ccRenamedFrom = r.renamedFrom
                    entry.ccRenamedTo = r.renamedTo
                    anyOK = true
                    let appLabel = resolvedAppType == "claude" ? "Claude Code" : resolvedAppType
                    if r.activationDeferred {
                        lines.append("✓ cc-switch: 已添加 provider「\(r.providerName)」到 \(appLabel)，保留当前 provider 未切换")
                    } else {
                        lines.append("✓ cc-switch: 已添加 provider「\(r.providerName)」到 \(appLabel) 并激活")
                    }
                    if resolvedAppType == "codex", probedNeedsProxy {
                        lines.append(proxyHintLine())
                    }
                    if r.renamedFrom != nil {
                        lines.append("  热激活: 原 provider 已暂存,删除本条时自动还原")
                    }
                    if r.activationDeferred {
                        lines.append("  运行时缓存: cc-switch 已运行，需在 cc-switch 界面手动切换或重启后切换")
                    } else if r.directMode {
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
                    // 单 key 与多 key 同路写 openai-compatibility 聚合段:
                    // collectCuratedModels(cpa-sync)只读聚合条目,平铺段条目对它隐形
                    let msg = try CPAWriter(configPath: cfg)
                        .addAggregated(baseURL: url, key: key, models: selectedModels, proxy: proxyURL)
                    if !entry.targets.contains("cpa") { entry.targets.append("cpa") }
                    entry.cpaConfigPath = cfg
                    anyOK = true
                    lines.append("✓ CPA: \(msg)")
                    // 常驻模型来源 = 条目最终 models(已有精选时即精选列表);
                    // 空传 nil 回退收集其它 cpa 条目的精选,绝不拉 CPA 聚合全量
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

        if useMagpie {
            anyTarget = true
            do {
                let msg = try syncMagpie(&entry)
                if !entry.targets.contains("magpie") { entry.targets.append("magpie") }
                anyOK = true
                lines.append("✓ Magpie: \(msg)")
            } catch {
                entry.targetSyncErrors = entry.targetSyncErrors ?? [:]
                entry.targetSyncErrors?["magpie"] = error.localizedDescription
                lines.append("✗ Magpie 失败: \(error.localizedDescription)")
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
            throw ParseError.io("没有选中的目标(cc-switch / Grok Build / CPA / DSH / Magpie)")
        }

        entry.status = anyOK ? "active" : "error"
        entry.note = notes.isEmpty ? nil : notes.joined(separator: "; ")
        lines.append(contentsOf: notes)

        var historySaved = false
        if anyOK {
            do {
                if let dup {
                    try saveAfterMagpie(entry, previous: dup)
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
                    var magpieMerged = false
                    if entry.targets.contains("magpie") {
                        // Magpie 的所有权绑定 entry.id，不能把另一 ID 的 tag 直接合并。
                        do {
                            _ = try MagpieWriter.remove(providerID: entry.id, expectedDestinationID: entry.magpieDestinationID)
                            // 单目标同步包含账本失败回滚，避免 survivor 下出现无人认领的配置。
                            _ = try syncTarget(entryIDPrefix: survivor.id, target: "magpie")
                            merged.magpieDestinationID = history.find(idPrefix: survivor.id)?.magpieDestinationID
                            magpieMerged = true
                        } catch {
                            lines.append("⚠ 并发合并: Magpie 同步失败，请对既有记录重新同步: \(error.localizedDescription)")
                        }
                    }
                    // CPA 是聚合写入、Clash 是独立文件,无需回滚;把目标记录并入 survivor。
                    // 已成功回滚的外部配置对应的 tag 绝不能并入:tag 会指向已删除的
                    // provider/route,后续 delete 会按错误的 appType 清理 survivor 自己的产物
                    for t in entry.targets where !merged.targets.contains(t) {
                        if t.hasPrefix("ccswitch") && ccRolledBack { continue }
                        if t == "dsh" && dshRolledBack { continue }
                        if t == "magpie" && !magpieMerged { continue }
                        merged.targets.append(t)
                    }
                    if merged.cpaConfigPath == nil { merged.cpaConfigPath = entry.cpaConfigPath }
                    if merged.grokConfigPath == nil { merged.grokConfigPath = entry.grokConfigPath }
                    try history.update(merged)
                    entry = merged
                    lines.append("↻ 检测到同 key 已被其他端导入,已合并到既有记录(\(survivor.id.prefix(8)))")
                }
                historySaved = true
            } catch {
                anyOK = false
                lines.append("✗ 历史保存失败，本次导入未完成: \(error.localizedDescription)")
                lines.append("  (目标配置可能已写入，请检查记录后重试)")
                if dup == nil, entry.targets.contains("magpie"), history.find(idPrefix: entry.id) == nil {
                    entry.status = "error"
                    do {
                        _ = try MagpieWriter.remove(providerID: entry.id, expectedDestinationID: entry.magpieDestinationID)
                        entry.targets.removeAll { $0 == "magpie" }
                    }
                    catch { lines.append("⚠ Magpie 回滚失败: \(error.localizedDescription)") }
                }
                if let dup { entry = history.find(idPrefix: dup.id) ?? dup }
            }
            if historySaved {
                do { try prefs.save() }
                catch { lines.append("⚠ 偏好保存失败（导入记录已保存）: \(error.localizedDescription)") }
            }
        }

        // 模型级探测点入档:导入时的探测/验证结果直接喂监控(此前只有刷新写点,
        // 新导入条目的模型在监控里全灰到第一次扫描/刷新)
        var importPoints: [String: ProbePoint] = [:]
        if let t = probedTest {
            importPoints = t.modelProbePoints(at: Date().timeIntervalSince1970)
        }
        for m in chatVerifiedModels where importPoints[m] == nil {
            // 显式要求且不在站点目录里的模型(逐个 chat 验证过的)也记 ok 点
            importPoints[m] = ProbePoint(t: Date().timeIntervalSince1970, ms: nil, ok: true)
        }
        if historySaved, !importPoints.isEmpty, entry.status == "active" {
            do {
                try history.appendModelProbePoints(id: entry.id, points: entry.scopedProbePoints(importPoints))
            } catch {
                AppLog.warn("模型探测点写入失败: \(error.localizedDescription)")
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
            // API 模式下对 stored 路径 stat 会触发 TCC「文稿」弹窗(路径在 Documents 时),
            // 且读取本身走管理 API 不需要文件存在 —— 跳过存在性检查
            guard let cfg = e.cpaConfigPath, let url = e.url,
                  CPAAPI.apiMode || FileManager.default.fileExists(atPath: cfg) else { continue }
            for m in CPAWriter(configPath: cfg).entryModels(baseURL: url) where seen.insert(m).inserted {
                out.append(m)
            }
        }
        return out
    }

    public static func healthFor(_ test: APITestResult) -> (health: String, detail: String) {
        if test.quotaExhausted { return ("quota", test.detail) }
        if test.reachabilityOnly { return ("reachable", test.detail + " · 对话模型尚未验证") }
        if test.needsProxy && test.ok {
            return ("proxy-ok", test.detail + " ⚠ 该网关直连不可用,需代理;无代理的工具(dsh 等)需自行配置 HTTPS_PROXY 才可用")
        }
        if test.ok { return ("ok", test.detail) }
        if test.authFailed { return ("dead", test.detail) }
        return ("err", test.detail)
    }

    /// 供 UI 层按需探针(真伪鉴定)读取当前代理口径
    public func proxyForHealthPublic() -> String? { proxyForHealth() }

    private func proxyForHealth() -> String? {
        let p = prefs.proxy
        if !p.isEmpty { return p }
        // 设置未填时自动探测本机代理(用户确认:本机代理常开)。测试环境隔离开关。
        // APITester.test 永远直连优先,传入探测结果在直连可用时零开销
        guard ProcessInfo.processInfo.environment["KEYDROP_NO_AUTOPROXY"] != "1" else { return nil }
        return Core.detectLocalProxy()
    }

    // MARK: - 本机代理自动探测

    /// 自动探测的候选端口(测试可注入)。覆盖常见本地代理混合端口
    public static var autoProxyCandidates = [
        "http://127.0.0.1:7890",    // mihomo-party / Clash Verge 混合端口
        "http://127.0.0.1:7891",    // Clash socks/http
        "http://127.0.0.1:1087",    // 老版 Clash http
        "http://127.0.0.1:6152",    // Surge
        "http://127.0.0.1:10808",   // v2rayN http
        "http://127.0.0.1:8118",    // Privoxy
    ]
    private static var cachedAutoProxy: String? = nil
    private static var lastProbeAt: TimeInterval = 0
    private static let probeLock = NSLock()

    /// 设置未填代理时的兼底:按候选端口 TCP 探测本机在监听的代理。
    /// 进程内缓存,15 分钟重探一次;结果在代理真正连通后由 noteProxyWorked 写入设置
    public static func detectLocalProxy(force: Bool = false) -> String? {
        probeLock.lock(); defer { probeLock.unlock() }
        let now = Date().timeIntervalSince1970
        if !force, lastProbeAt != 0, now - lastProbeAt < 900 { return cachedAutoProxy }
        lastProbeAt = now
        cachedAutoProxy = autoProxyCandidates.first { tcpReachable($0) }
        return cachedAutoProxy
    }

    /// 测试辅助:清空探测缓存
    public static func resetProxyProbeForTest() {
        probeLock.lock(); cachedAutoProxy = nil; lastProbeAt = 0; probeLock.unlock()
    }

    /// 代理候选:顶栏「代理」下拉里的一条(地址 + 在听状态)
    public struct ProxyCandidate: Identifiable, Equatable {
        public let url: String
        public let note: String
        public let alive: Bool
        public var id: String { url }
    }

    /// 候选端口的可读来源。认不出的端口只说「本地端口」,不假装知道是谁在监听
    public static func proxyCandidateNote(_ proxy: String) -> String {
        switch URL(string: proxy)?.port {
        case 7890, 7891: return "Clash Verge / mihomo"
        case 1087:  return "Clash 旧版"
        case 6152:  return "Surge"
        case 10808: return "v2rayN"
        case 8118:  return "Privoxy"
        default:    return "本地端口"
        }
    }

    /// 逐个 TCP 探测候选端口,给顶栏下拉展示:在听的排前面,同组保持候选原序。
    /// 单次探测 300ms 超时 × 6 个端口 ≈ 最坏 1.8s,调用方必须放后台队列
    public static func localProxyCandidates() -> [Core.ProxyCandidate] {
        let probed = autoProxyCandidates.enumerated().map { idx, url in
            (order: idx, item: ProxyCandidate(url: url, note: proxyCandidateNote(url),
                                              alive: tcpReachable(url)))
        }
        return probed.sorted { a, b in
            a.item.alive != b.item.alive ? a.item.alive : a.order < b.order
        }.map(\.item)
    }

    private static func tcpReachable(_ proxy: String) -> Bool {
        guard let url = URL(string: proxy), let host = url.host, let port = url.port else { return false }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let r = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if r == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, 300) > 0 else { return false }
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        return err == 0
    }

    /// 代理真正连通后(直连失败 + 经代理成功)把探测到的代理写入设置,
    /// 让它在设置里可见、可改;用户手填的永远优先,不动
    public func noteProxyWorked(needsProxy: Bool, used: String?) {
        guard needsProxy, prefs.proxy.isEmpty, let used, !used.isEmpty else { return }
        prefs.proxy = used
        AppLog.info("自动代理: 直连失败、经 \(used) 连通,已写入设置(可在设置中修改/清除)")
    }

    /// history.update 的统一入口:落盘失败(磁盘满/权限)必须留痕,
    /// 否则「已标记/已更新」的返回值与磁盘事实不一致且无迹可查
    private func historyUpdateLogged(_ e: HistoryEntry) {
        do { try history.update(e) } catch {
            AppLog.error("history.update 保存失败: \(error.localizedDescription)")
        }
    }

    /// 失败防抖分级决策(纯函数,供测试):
    /// - 成功 → 清零 streak,应用新健康
    /// - 暂时性网络失败(超时/不可达)+ 原本 ok + 首败 → 保留 ok(防抖),连败 ≥2 降级
    /// - 服务端明确拒绝(401/403/429/5xx,非暂时)→ 首败即降级。
    ///   真实反馈「监控全绿但访问完全不行」:一刀切防抖曾撑出最长 2 小时的全绿窗口
    public static func healthDebounce(test: APITestResult, previousHealth: String?, previousStreak: Int,
                               health: String?, detail: String) -> (health: String?, detail: String, streak: Int) {
        let streak = previousStreak + (test.ok ? 0 : 1)
        if test.ok { return (health, detail, 0) }
        let keepAvailable = test.transientFailure && previousHealth == "ok" && streak < 2
        if keepAvailable {
            return ("ok", "⚠ 本次网络探测失败，等待复测: \(detail.prefix(70))", streak)
        }
        return (health, detail, streak)
    }

    public func scanHealth(staleAfter: TimeInterval = 1800, completion: (([String]) -> Void)? = nil) {
        let synced = reconcileWithCCSwitch()
        if !synced.isEmpty {
            AppLog.info("health 扫描前对账: " + synced.joined(separator: "; "))
        }
        let now = Date().timeIntervalSince1970
        // extractKey 一次解析随目标携带:过滤与并发块各调一次曾是双倍开销,
        // 且 extractKey 对 raw 是路径/zip 的条目会重新读盘
        var targets: [(entry: HistoryEntry, key: String)] = []
        for e in history.snapshot() where e.status == "active" && e.url != nil && !e.isDSHOnly {
            guard let k = extractKey(e), !k.isEmpty else { continue }
            if let at = e.healthAt, now - at < staleAfter { continue }
            targets.append((e, k))
        }
        guard !targets.isEmpty else {
            completion?([])
            return
        }
        var out: [String] = []
        var updatedEntries: [HistoryEntry] = []
        var poolOnlyEntries: [HistoryEntry] = []
        let outLock = NSLock()
        let sem = DispatchSemaphore(value: 4)
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)
        for (e, entryKey) in targets {
            // 在进入并发闭包前解包:过滤条件已保证非 nil,但 e.url!/e.key! 是在
            // 后台线程里求值的强制解包 —— 一旦将来过滤条件放宽就是崩溃点。
            // 提前 guard 掉,让「不可能」变成安全跳过而不是 crash。
            guard let entryURL = e.url, !entryKey.isEmpty else { continue }
            sem.wait()
            group.enter()
            queue.async {
                defer { sem.signal(); group.leave() }
                let px = self.proxyForHealth()
                // 监控只测用户勾选的模型(激活模型置顶):站点目录里没勾的模型与本次
                // 监控无关,拿去轮换只会把我自己的模型挤到十几轮之后才补一格。
                // 发现新可用模型是「行内 ↻ 刷新」的活,不是巡检的活
                let probePool = e.configuredModels
                let test = APITester.test(url: entryURL, key: entryKey, timeout: 10,
                                          proxy: px, preferredModel: e.model,
                                          modelProbeTimes: e.modelProbeLog?.compactMapValues { $0.last?.t },
                                          importedModels: e.models,
                                          probePool: probePool.isEmpty ? nil : probePool,
                                          knownNeedsProxy: e.health == "proxy-ok", styleHint: e.apiStyle)
                if test.skippedForCooldown {
                    var updated = e
                    self.updatePoolProbe(for: &updated, primary: test, at: now, proxy: px)
                    outLock.lock()
                    poolOnlyEntries.append(updated)
                    outLock.unlock()
                    return
                }
                self.noteProxyWorked(needsProxy: test.needsProxy, used: px)
                let (h, d) = Self.healthFor(test)
                var updated = e
                if test.ok { updated.apiStyle = test.style }
                // 失败防抖分级(决策纯函数见 healthDebounce,供测试)
                let decision = Self.healthDebounce(test: test, previousHealth: e.health,
                                                   previousStreak: e.failStreak ?? 0,
                                                   health: h, detail: d)
                updated.failStreak = decision.streak
                updated.health = decision.health ?? updated.health
                updated.healthDetail = decision.detail
                updated.healthAt = now
                updated.latencyMs = test.ok ? test.latencyMs : e.latencyMs
                // 部分可用时也记录已确认失败的模型,防止旧绿格一直保留。
                let modelPoints = updated.scopedProbePoints(test.modelProbePoints(at: now))
                // 增量语义:每个模型包一层单点数组,mergeHealth 负责追加进完整轨迹并截 30
                // (与 probeLog 的 merge 模式一致,避免快照覆盖监控历史)
                if modelPoints.isEmpty {
                    updated.modelProbeLog = nil
                } else {
                    updated.modelProbeLog = modelPoints.mapValues { [$0] }
                }
                // CPA 链路监控:用户真实请求走 CPA(8317 轮询上游池),健康测试却直连上游
                // —— 上游 OK ≠ CPA 链路 OK(容器网络/路由/代理都可能断)。对带 cpa 目标的
                // 条目,用实际激活模型经 CPA 探测一次;失败在详情标注,不直接降级
                // (链路问题多为配置性,直连可用说明 key 本身没死)
                // 修复:生图/嵌入等 non-chat 模型跳过 CPA chat 探测 —— CPA 会以
                // "model only supported on /v1/images/generations" 拒绝,曾把
                // gpt-image-2 条目误标为链路异常(真实事故)。跳过 = 视为未测,
                // 不显示 CPA 徽章,不误报
                self.updatePoolProbe(for: &updated, primary: test, at: now, proxy: px)
                let cpaResults = self.updateCPAProbe(for: &updated, test: test, at: now)
                for (model, passed) in cpaResults {
                    // CPA 结果只附到该模型本轮实际请求的增量点上。
                    if var points = updated.modelProbeLog?[model], !points.isEmpty {
                        points[points.count - 1].cpa = passed
                        updated.modelProbeLog?[model] = points
                    }
                }
                // 只收集不落盘;结束后 mergeHealth 一次性按字段合并保存(见 scanHealth 尾部)
                // 每条各 save 一次会把整份历史反复序列化写盘(O(N²) IO 放大)
                outLock.lock()
                updatedEntries.append(updated)
                if updated.health != "ok" || (updated.viaCPAOk == false) {
                    out.append("\(e.id.prefix(8)) \(updated.health == "dead" ? "key 失效" : "异常"): \((updated.healthDetail ?? "").prefix(80))")
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
                let testedConfigurations = Dictionary(targets.map { ($0.entry.id, $0.entry.probeConfigurationID) },
                                                       uniquingKeysWith: { first, _ in first })
                try self.history.mergeHealth(updatedEntries, at: now, testedConfigurations: testedConfigurations)
                try self.history.mergePoolEvidence(poolOnlyEntries)
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
    /// 另含回写污染自愈:cc-switch 把陈旧 live 环境整块回写进 KeyDrop 托管 claude 行的
    /// 修复(见 repairClobberedClaudeRow;2026-09-25 sub.tidalrelay 事故)。
    public func reconcileWithCCSwitch() -> [String] {
        var out: [String] = []
        out.append(contentsOf: adoptOrphanImports())
        out.append(contentsOf: repairClobberedCCRows())
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
                let px = self.proxyForHealth()
                let test = APITester.test(url: url, key: key, timeout: 10, proxy: px,
                                          preferredModel: e.model, importedModels: e.models,
                                          probePool: e.configuredModels, styleHint: e.apiStyle)
                guard !test.skippedForCooldown else { return }
                self.noteProxyWorked(needsProxy: test.needsProxy, used: px)
                // 再确认目标仍缺失。用户可能在网络探测期间重新导入。
                let appType = e.targets.first { $0.hasPrefix("ccswitch-") }
                    .map { String($0.dropFirst("ccswitch-".count)) } ?? "claude"
                guard let pid = e.ccProviderID, !self.cc.providerExists(id: pid, appType: appType) else { return }
                let health = Self.healthFor(test)
                let note: String
                if test.authFailed {
                    note = "cc-switch provider 已被删除且 key 失效,KeyDrop 已同步标记"
                } else if health.health == "ok" || health.health == "proxy-ok" {
                    note = "cc-switch provider 缺失,key 仍可用,可手动重新导入"
                } else {
                    note = "cc-switch provider 缺失(探测失败,key 状态未知);恢复后可手动重新导入"
                }
                let now = Date().timeIntervalSince1970
                let point = test.reachabilityOnly ? nil : ProbePoint(
                    t: now, ms: test.latencyMs,
                    ok: health.health == "ok" || health.health == "proxy-ok")
                do {
                    guard try self.history.mergeCCReconciliation(tested: e, health: health.health,
                                                                  detail: health.detail, authFailed: test.authFailed,
                                                                  note: note, point: point,
                                                                  modelPoints: e.scopedProbePoints(test.modelProbePoints(at: now))) else { return }
                    if test.authFailed || e.ccMissing != true {
                        outLock.lock()
                        out.append("同步: 「\(e.name ?? String(e.id.prefix(8)))」\(note)")
                        outLock.unlock()
                    }
                } catch {
                    AppLog.error("对账落盘失败: \(error.localizedDescription)")
                }
            }
        }
        // 等全部对账完成,保持「返回时对账已生效」的既有语义(逐条已在并发任务内即时落盘)
        group.wait()
        return out
    }

    /// 孤儿收养(更新重启打断导入的兜底):cc.add 写入 provider 后、history.append
    /// 前被 kill 的毫秒级窗口会留下「产物在、账本无」的孤儿——删除/刷新/对账都不再
    /// 认领它。收养 = 凭 cc.add 写入的 meta 导入标记识别孤儿(常驻/用户手写行无标记,
    /// 永不触碰),从 provider 行重建账本条目:url/key 取自行内、模型取自标记、健康
    /// 直接置 ok(能建行说明导入时已通过可用性测试)。收养而非删除:配置是完好的,
    /// 删掉等于丢一把已验证的 key;收养后删除/刷新全部恢复可用。
    /// key 已在账本(换了 URL 的场景)时跳过并告警——绝不静默制造重复凭据。
    /// CPA/DSH 产物若在崩溃前已写入则保留(无害),重新导入一次(幂等)即可补齐 tag。
    private func adoptOrphanImports() -> [String] {
        var out: [String] = []
        let snapshot = history.snapshot()
        let claimed = Set(snapshot.compactMap { $0.ccProviderID })
        let knownKeys = Set(snapshot.compactMap { $0.key })
        let orphans: [CCSwitchWriter.CCOrphanImport]
        do {
            orphans = try cc.orphanImports(claimed: claimed)
        } catch {
            return ["⚠ 孤儿扫描失败: \(error.localizedDescription)"]
        }
        for o in orphans {
            let label = o.name ?? String(o.providerID.prefix(8))
            if knownKeys.contains(o.key) {
                out.append("⚠ 孤儿 provider「\(label)」的 key 已存在于账本(URL 不同),未收养,请人工处理")
                continue
            }
            let appTag = o.appType == "claude" ? "ccswitch" : "ccswitch-\(o.appType)"
            let keyMasked = o.key.count > 8
                ? String(o.key.prefix(6)) + "…" + String(o.key.suffix(4))
                : String(repeating: "*", count: max(o.key.count, 6))
            var entry = HistoryEntry(
                id: UUID().uuidString.lowercased(),
                ts: o.createdAt ?? Date().timeIntervalSince1970,
                raw: "orphan-adopt: \(o.appType) \(o.url)",
                format: "orphan-adopt",
                name: o.name,
                url: o.url,
                model: o.models.first,
                models: o.models.isEmpty ? nil : o.models,
                key: o.key,
                keyMasked: keyMasked,
                targets: [appTag],
                ccProviderID: o.providerID,
                ccRenamedFrom: nil,
                ccRenamedTo: nil,
                cpaConfigPath: nil,
                status: "active",
                clashFile: nil
            )
            entry.health = "ok"
            entry.healthDetail = "启动自愈: 收养自更新中断的孤儿 provider(导入时已通过可用性测试)"
            entry.healthAt = Date().timeIntervalSince1970
            entry.note = "孤儿收养: 更新重启打断了本次导入的记账,已从 provider 行重建条目;如需 CPA/DSH 通道,重新导入一次(幂等)即可补齐"
            do {
                try history.append(entry)
                out.append("自愈: 收养孤儿 provider「\(label)」(\(appTag)),已补记账本")
            } catch {
                out.append("⚠ 孤儿收养落盘失败(「\(label)」): \(error.localizedDescription)")
            }
        }
        return out
    }

    /// 回写污染自愈:遍历 active 且导入到 Claude Code 的条目,检测其 cc-switch 行是否
    /// 被「陈旧 loopback live 环境」整块回写覆盖(签名判定见 repairClobberedClaudeRow)。
    /// 纯本地 DB 读校验,无网络请求,不参与并发对账。未配置 CPA(无 clientKey 可比)
    /// 时签名不成立,整段跳过。
    private func repairClobberedCCRows() -> [String] {        guard let ep = CPAWriter.endpointInfo() else { return [] }
        var out: [String] = []
        for e in history.snapshot() where e.status == "active" && e.targets.contains("ccswitch") {
            guard let pid = e.ccProviderID, let url = e.url, let key = e.key, !key.isEmpty else { continue }
            let models = e.models ?? (e.model.map { [$0] } ?? [])
            do {
                let msg = try cc.repairClobberedClaudeRow(providerID: pid, url: url, key: key,
                                                          models: models, cpaClientKey: ep.clientKey)
                if !msg.isEmpty {
                    out.append("自愈: 「\(e.name ?? String(e.id.prefix(8)))」\(msg)")
                }
            } catch {
                out.append("⚠ 自愈失败(「\(e.name ?? String(e.id.prefix(8)))」): \(error.localizedDescription)")
            }
        }
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
        var out = compactLedger()
        out.append(contentsOf: reconcileWithCCSwitch())
        out.append(contentsOf: reconcileDSH())
        return out
    }

    /// 立即清理:摘除所有「账本认领但 settings.yaml 缺失」的 dsh 标。
    /// 用于一次性收敛积压(日常由 reconcileDSH 的 3 天阈值自动处理)。
    /// - Parameter keepLatest: 保留最近 N 个的 dsh 标(用户可能刚同步,别误摘)
    public func dshConverge(keepLatest: Int = 1) throws -> [String] {
        guard DSHWriter.installed() else { return [] }
        let managed = try DSHWriter.managedRoutes()
        let cordisRefs = try DSHWriter.cordisCredentialRefs()
        let claimed = history.snapshot().filter { $0.status == "active" && $0.targets.contains("dsh") }
        // 按updatedAt desc排序:最新的 keepLatest 个保留
        let sorted = claimed.sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
        var removed: [String] = []
        for (i, e) in sorted.enumerated() {
            let rk = DSHWriter.routeKey(providerID: e.id)
            let owned = managed.first(where: {
                DSHWriter.isOwnedRoute($0.name, providerID: e.id) && $0.env == DSHWriter.envName(providerID: e.id)
            })
            let ref = DSHWriter.envName(providerID: e.id)
            if owned != nil || (cordisRefs.contains(ref) && DSHWriter.hasCredential(env: ref)) { continue }
            if i < keepLatest { continue } // 最近的 N 个保留
            var converged = e
            converged.targets.removeAll { $0 == "dsh" }
            converged.dshMissingAt = nil
            try history.update(converged)
            removed.append(rk)
        }
        return removed
    }

    /// DSH 全生命周期对账(与 reconcileWithCCSwitch 同级的成熟度):
    /// ① 孤儿路由清理 —— 账本不再认领的 keydrop-*(连同凭据)移除
    /// ② 认领路由漂移修复 —— baseURL/models 与账本不一致 → 重写;凭据缺失 → 自愈
    /// ③ 认领路由缺失 —— 只报告不自动重建:用户在 DSH 界面手删的意图必须尊重,
    ///    重建走显式「同步到 DSH」(与 cc-switch 的 ccMissing 同一哲学)
    /// ④ Cordis 补丁层检测(只读)—— 第三方私有层里的残留 keydrop-* 点名警告
    /// 纯文件操作无网络;启动 selfHeal、每次同步到 DSH 时都会执行
    public func reconcileDSH() -> [String] {
        guard DSHWriter.installed() else { return [] }
        var out: [String] = []
        let claimed = history.snapshot().filter { $0.status == "active" && $0.targets.contains("dsh") }
        // 认领按 id8 基名家族判定:路由名可能是装饰名(keydrop-<id8>-host-模型)
        var claimedBases = Set(claimed.map { String($0.id.prefix(8)) })
        // CPA 常驻路由只在常驻开关开启时认领:关掉后交给孤儿清理回收路由+凭据
        if prefs.cpaResident {
            claimedBases.insert("cparesid")
        }

        do {
            let pruned = try DSHWriter.pruneOrphanRoutes(claimedBases: claimedBases)
            if !pruned.isEmpty {
                out.append("DSH 对账: 清理 \(pruned.count) 个孤儿路由(\(pruned.joined(separator: ", ")))")
            }
            let managed = try DSHWriter.managedRoutes()
            let cordisRefs = try DSHWriter.cordisCredentialRefs()
            var updated: [String] = []
            var missing: [String] = []
            var convergedTags: [String] = []
            for e in claimed {
                let rk = DSHWriter.routeKey(providerID: e.id)
                guard let url = e.url, let key = extractKey(e), !key.isEmpty else { continue }
                // 与 syncToDSH/syncTarget 同口径 trim:账本值带空白时,对账曾用
                // 未 trim 值判漂移并把脏数据回写目标应用(审计 2026-11-13)
                let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
                let models = (e.models ?? (e.model.map { [$0] } ?? []))
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                guard !models.isEmpty else { continue }
                // 家族查找:路由可能是旧的裸名,也可能是任一装饰名
                // 家族匹配 + env 校验:id8 碰撞时按凭据 env 区分归属
                guard let r = managed.first(where: {
                    DSHWriter.isOwnedRoute($0.name, providerID: e.id) && $0.env == DSHWriter.envName(providerID: e.id)
                }) else {
                    // DSH may consume settings.yaml during startup while keeping the live profile.
                    let ref = DSHWriter.envName(providerID: e.id)
                    if cordisRefs.contains(ref), DSHWriter.hasCredential(env: ref) {
                        if e.dshMissingAt != nil {
                            var present = e
                            present.dshMissingAt = nil
                            try history.update(present)
                        }
                        continue
                    }
                    // 缺失路由收敛:首次发现打 dshMissingAt 标;持续 ≥3 天 → 用户已放弃,
                    // 自动摘除 dsh 标(账本与 settings.yaml 现实收敛)。
                    // 用户重新「同步到 DSH」时路由回来,标自动清除
                    let now2 = Date().timeIntervalSince1970
                    if let marked = e.dshMissingAt, now2 - marked > 3 * 24 * 3600 {
                        var converged = e
                        converged.targets.removeAll { $0 == "dsh" }
                        converged.dshMissingAt = nil
                        converged.updatedAt = now2
                        do {
                            try history.update(converged)
                            convergedTags.append(rk)
                        } catch {
                            AppLog.warn("DSH 收敛: 摘除 \(rk) 的 dsh 标失败: \(error.localizedDescription)")
                        }
                    } else if e.dshMissingAt == nil {
                        var marked = e
                        marked.dshMissingAt = now2
                        try? history.update(marked)
                    }
                    missing.append(rk)
                    continue
                }
                // 与写入同源归一(sync 时 baseURL 过 normalizeBaseURL),否则必然误报漂移
                // 装饰名也算漂移:旧命名的路由在对账时自动改名,无需逐条重新同步
                let wantName = DSHWriter.displayRouteKey(providerID: e.id, url: trimmedURL, models: models)
                if r.name == wantName,
                   r.baseURL == DSHWriter.normalizeBaseURL(trimmedURL), r.models == models,
                   DSHWriter.hasCredential(env: r.env) { continue }
                // add 会摘旧装饰名挂新名:url/models 变化即改名
                _ = try DSHWriter.add(providerID: e.id, key: key, url: trimmedURL, models: models)
                updated.append(rk)
            }
            if !updated.isEmpty {
                out.append("DSH 对账: \(updated.count) 个路由与账本漂移,已重写(\(updated.joined(separator: ", ")))")
            }
            if !convergedTags.isEmpty {
                out.append("DSH 收敛: \(convergedTags.count) 个缺失 ≥3 天的路由已自动摘除 dsh 标(\(convergedTags.prefix(3).joined(separator: ", "))\(convergedTags.count > 3 ? " 等" : ""))")
            }
            if !missing.isEmpty {
                out.append("DSH 对账: \(missing.count) 个已同步路由在 settings.yaml 缺失(\(missing.prefix(3).joined(separator: ", "))\(missing.count > 3 ? " 等" : ""))——行内「同步到 DSH」可恢复;持续缺失 3 天自动摘除")
            }
            if !(updated.isEmpty && missing.isEmpty), DSHWriter.dshWebRunning() {
                out.append("⚠ DSH web 正在运行:以上变更需重启 DSH 后在 Jet Hub 可见(启动时才导入 settings.yaml)")
            }
        } catch {
            out.append("⚠ DSH 对账失败: \(error.localizedDescription)")
        }
        for (file, stale) in DSHWriter.patchLayerStaleRoutes(claimedBases: claimedBases) {
            out.append("⚠ DSH 补丁层残留: \(file) 里有 \(stale.count) 个账本不再认领的 keydrop-* 路由(\(stale.prefix(3).joined(separator: ", "))\(stale.count > 3 ? " 等" : ""))——Cordis 私有层,KeyDrop 不自动改写,请在 Cordis 中删除或手动清理")
        }
        return out
    }

    /// 账本压实(启动 self-heal 执行,离线安全):    /// ① note 归一 —— 按 "; " 分句去重 + 总长上限。历史 bug 实证:单条 note 同一句
    ///    「可手动重新导入」重复 655 遍(25KB),每轮对账全量重写白白放大 IO;
    /// ② 超期已删条目转审计桩 —— status=deleted 且删除超 30 天的条目,清除明文
    ///    key/raw/probeLog/note,保留 id/name/url/keyMasked/targets/时间戳供追溯。
    ///    审计=元数据永久留痕,敏感负载到期清除;单文件 JSON 格式不变,
    ///    CLI/文档排查清单等所有现有工具链不受影响。active 条目永不触碰。
    public func compactLedger() -> [String] {
        let cutoff = Date().timeIntervalSince1970 - 30 * 24 * 3600
        var out: [String] = []
        var purged = 0
        var normalized = 0
        var noteFixes: [HistoryEntry] = []   // 仅 note 归一(可能仍是 active)
        var stubs: [HistoryEntry] = []       // 转审计桩(必须整条替换)
        for var e in history.snapshot() {
            var dirty = false
            var didPurge = false
            // ① note 归一
            let n = Self.normalizedNote(e.note)
            if n != e.note { e.note = n; dirty = true; normalized += 1 }
            // ② 超期已删 → 审计桩(计龄:deletedAt 缺失的历史条目回退 healthAt/ts)
            if e.status == "deleted" {
                let age = e.deletedAt ?? e.healthAt ?? e.ts
                if age < cutoff, e.key != nil || e.poolKeys != nil || e.probeLog != nil || e.modelProbeLog != nil || e.poolProbeLog != nil
                    || e.raw != "archived" {
                    e.key = nil
                    e.poolKeys = nil
                    e.raw = "archived"
                    e.probeLog = nil
                    e.modelProbeLog = nil
                    e.poolProbeLog = nil
                    e.targetSyncErrors = nil
                    e.healthDetail = nil
                    e.latencyMs = nil
                    e.viaCPAOk = nil
                    e.viaCPAAt = nil
                    e.ccMissing = nil
                    e.note = "审计桩: 超期已删除条目,明文 key/探测历史已按保留策略清除"
                    if e.deletedAt == nil { e.deletedAt = age }
                    dirty = true
                    didPurge = true
                    purged += 1
                }
            }
            if dirty {
                if didPurge { stubs.append(e) } else { noteFixes.append(e) }
            }
        }
        // note 归一走 update:probeLog/modelProbeLog 是 store 托管字段,updateAll 整条替换
        // 会把快照之后并发追加的探测点静默回滚。审计桩恰恰需要显式清除探测历史,
        // 必须走 updateAll(唯一的整条替换通道),两批各一次落盘
        do {
            for e in noteFixes { try history.update(e) }
            if !stubs.isEmpty { try history.updateAll(stubs) }
            if purged > 0 { out.append("压实: \(purged) 条超期已删条目已转审计桩(明文 key/探测历史已清除)") }
            if normalized > 0 { out.append("压实: \(normalized) 条条目的备注已去重截断") }
        } catch {
            out.append("⚠ 账本压实写入失败: \(error.localizedDescription)")
        }
        return out
    }

    /// note 归一:按 "; " 分句去重(同一句历史 bug 曾堆积 655 遍)+ 总长上限 4000 字符
    /// (超限保留开头=导入记录、结尾=最近状态,中间以省略标记衔接)。
    /// 审计语义不受损:去重的只是完全相同的重复句,不同内容全部保留。
    static func normalizedNote(_ note: String?) -> String? {
        guard let note, !note.isEmpty else { return note }
        var seen = Set<String>()
        var kept: [String] = []
        for seg in note.components(separatedBy: "; ") {
            let t = seg.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            if seen.insert(t).inserted { kept.append(t) }
        }
        var n = kept.joined(separator: "; ")
        // 上限 4000:头 590 + 标记 9 + 尾 3390 = 3989 < 4000 —— 截断结果必须
        // 严格低于阈值,否则每次压实都会再截一轮,渐进性啃掉尾部内容
        if n.count > 4000 {
            n = String(n.prefix(590)) + " …[已截断]… " + String(n.suffix(3390))
        }
        return n
    }

    // MARK: - 账本迁移(Phase 1):加密导出/导入 + 产物重放

    /// 导出账本:全量条目 + 目标开关,端到端加密(口令派生密钥,不落任何第三方)。
    /// 已删条目一并导出(文件本身是密文),由导入端决定是否搬墓碑。
    public func exportLedger(passphrase: String) throws -> Data {
        let payload = LedgerPayload(
            schemaVersion: LedgerCrypto.currentSchemaVersion,
            exportedAt: Date().timeIntervalSince1970,
            appVersion: Version.currentVersion(),
            entries: history.snapshot(),
            switches: .init(useCC: prefs.useCC, useGrok: prefs.useGrok,
                            useCPA: prefs.useCPA, useDSH: prefs.useDSH,
                            cpaResident: prefs.cpaResident, useMagpie: prefs.useMagpie)
        )
        let data = try JSONEncoder().encode(payload)
        return try LedgerCrypto.seal(data, passphrase: passphrase)
    }

    /// 导入账本(按 id 合并,绝不覆盖本机已有条目):
    /// - 已删除的条目不搬(一次性迁移不搬墓碑;同步语义留给 Phase 2);
    /// - 本机已有同 id → 跳过;本机 active 条目已有同 key → 跳过(防制造重复凭据条目);
    /// - 来源机器的本地产物绑定(ccProviderID/cpaConfigPath 等)清除,待本机 replayArtifacts 重建;
    /// - 目标开关按导出值应用(机器特定项:代理/CPA 路径/管理密钥不迁移)。
    public func importLedger(_ fileData: Data, passphrase: String, mode: LedgerImportMode = .migrate) throws -> String {
        let rawPayload = try LedgerCrypto.open(fileData, passphrase: passphrase)
        let payload: LedgerPayload
        do {
            payload = try JSONDecoder().decode(LedgerPayload.self, from: rawPayload)
        } catch {
            throw LedgerTransferError.badEnvelope("载荷解析失败: 文件可能来自更新版本的 KeyDrop")
        }
        return try importPayload(payload, mode: mode)
    }

    /// 载荷导入:.migrate = 一次性迁移(已存在跳过,目标开关按导出值应用);
    /// .feed = 订阅同步(同 id 按 updatedAt LWW,维护者墓碑向订阅者传播,
    /// 本机较新的条目保留,目标开关不动 —— 订阅者自己的偏好自主)
    func importPayload(_ payload: LedgerPayload, mode: LedgerImportMode) throws -> String {
        guard payload.schemaVersion <= LedgerCrypto.currentSchemaVersion else {
            throw LedgerTransferError.schemaTooNew(payload.schemaVersion)
        }
        var added = 0, skippedExisting = 0, skippedSameKey = 0, skippedTombstone = 0
        var updatedFromFeed = 0, skippedLocalNewer = 0, tombstonePropagated = 0
        let snapshotNow = history.snapshot()
        var activeKeysByID = Dictionary(snapshotNow.filter { $0.status == "active" }
            .map { ($0.id, Set($0.credentialKeys)) }, uniquingKeysWith: { $0.union($1) })
        // 本机墓碑与本批即将传播的墓碑均先建立凭据集合，避免 payload 的先后顺序复活 key。
        var localTombstoneKeys = Set(snapshotNow.filter { $0.status == "deleted" }.flatMap(\.credentialKeys))
        if mode == .feed {
            for tombstone in payload.entries where tombstone.status == "deleted" {
                if let local = snapshotNow.first(where: { $0.id == tombstone.id }),
                   local.status == "active",
                   tombstone.deletedAt != nil || (local.updatedAt ?? 0) < (tombstone.updatedAt ?? 0) {
                    localTombstoneKeys.formUnion(local.credentialKeys)
                    localTombstoneKeys.formUnion(tombstone.credentialKeys)
                }
            }
        }
        var feedChanged: [HistoryEntry] = []
        for var e in payload.entries {
            let local = history.find(idPrefix: e.id)
            if e.status == "deleted" {
                let deletedAt = e.deletedAt
                if mode == .feed, let local, local.status == "active",
                   deletedAt != nil || (local.updatedAt ?? 0) < (e.updatedAt ?? 0) {
                    // 健康更新不阻止显式删除。清理失败则保留绑定，下一次拉取可重试。
                    _ = try deleteEntry(local, deletedAt: deletedAt ?? Date().timeIntervalSince1970)
                    tombstonePropagated += 1
                    activeKeysByID.removeValue(forKey: local.id)
                    feedChanged.removeAll { $0.id == local.id }
                } else {
                    skippedTombstone += 1
                }
                continue
            }
            let incomingKeys = Set(e.credentialKeys)
            if !incomingKeys.isDisjoint(with: localTombstoneKeys) {
                if mode == .feed, let local, local.status == "deleted",
                   (e.updatedAt ?? 0) <= (local.updatedAt ?? 0) {
                    skippedLocalNewer += 1
                } else {
                    skippedTombstone += 1
                }
                continue
            }
            let otherActiveKeys = activeKeysByID.filter { $0.key != e.id }.values
            if otherActiveKeys.contains(where: { !incomingKeys.isDisjoint(with: $0) }) {
                skippedSameKey += 1
                continue
            }
            if mode == .feed, let local {
                // LWW:维护者版本较新 → 整条以维护者为准,但保留本机的产物绑定
                // (ccProviderID 是订阅者本机的行,维护者的 pid 对订阅者无意义);
                // 本机产物同步:cc 行内容更新 / CPA 组内旧 key 换新 / DSH upsert / grok sync
                let localTS = local.updatedAt ?? 0
                let remoteTS = e.updatedAt ?? 0
                if remoteTS > localTS, local.status == "deleted", e.status != "deleted" {
                    // 本机墓碑不被远端 active 版复活——即使远端较新(维护者更新不能
                    // 推翻本机删除;曾同 id 绕过 localTombstoneKeys 守卫,审计 2026-11-13)。
                    // 远端也是墓碑时走正常 LWW 更新 deletedAt
                    skippedTombstone += 1
                    continue
                }
                if remoteTS > localTS {
                    // 先同步本机已认领的产物。失败时保留旧账本，后续拉取可重试。
                    // 缺少凭据不能跳过目标写入后仍接收远端账本，否则会丢失本机
                    // 清理和重试所需的 key；在任何目标写入前检查以避免部分更新。
                    if local.targets.contains("magpie") {
                        guard !e.credentialKeys.isEmpty,
                              let incomingURL = e.url,
                              !incomingURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            throw ParseError.io("同步 Magpie 缺少地址或凭据，已保留本机记录")
                        }
                    }
                    // 实例绑定只属于本机；远端账本中的绑定不能参与回退。
                    e.magpieDestinationID = local.magpieDestinationID
                    var incomingModels = e.models ?? e.model.map { [$0] }
                        ?? local.models ?? local.model.map { [$0] } ?? []
                    if local.targets.contains("cpa") {
                        guard let oldKeys = extractAllKeys(for: local), !oldKeys.isEmpty, let oldURL = local.url,
                              var newKeys = extractAllKeys(for: e), !newKeys.isEmpty, let newURL = e.url,
                              let cfg = local.cpaConfigPath ?? prefs.resolvedCPAConfig() else {
                            throw ParseError.io("同步 CPA 缺少地址、凭据或配置路径，已保留本机记录")
                        }
                        let writer = CPAWriter(configPath: cfg)
                        if e.format == "cpa-multikey", e.key == nil, e.poolKeys == nil {
                            let (_, actualModels, accepted) = try writer.addMulti(
                                baseURL: newURL, keys: newKeys, proxy: proxyForHealth(),
                                fallbackModels: incomingModels.isEmpty ? nil : incomingModels)
                            newKeys = accepted
                            e.poolKeys = accepted
                            e.keyMasked = "\(accepted.count) 个 key"
                            if incomingModels.isEmpty, !actualModels.isEmpty {
                                incomingModels = actualModels
                                e.models = actualModels
                                e.model = actualModels.first
                            }
                        } else {
                            for key in newKeys {
                                _ = try writer.addAggregated(baseURL: newURL, key: key, models: incomingModels)
                            }
                        }
                        if !incomingModels.isEmpty {
                            _ = try updateCPASelection(writer: writer, entryID: e.id, url: newURL, models: incomingModels,
                                                       previous: writer.normalizeUpstreamURL(oldURL) == writer.normalizeUpstreamURL(newURL) ? local.configuredModels : [])
                        }
                        let sameUpstream = writer.normalizeUpstreamURL(oldURL) == writer.normalizeUpstreamURL(newURL)
                        let incomingKeys = Set(newKeys)
                        let staleKeys = oldKeys.filter { !sameUpstream || !incomingKeys.contains($0) }
                        if !staleKeys.isEmpty {
                            _ = try writer.remove(apiKeys: staleKeys, baseURL: oldURL)
                        }
                    }
                    if let pid = local.ccProviderID {
                        let oldApp = local.targets.first(where: { $0.hasPrefix("ccswitch-") })
                            .map { String($0.dropFirst("ccswitch-".count)) } ?? "claude"
                        var p = ParsedKey()
                        p.url = e.url
                        p.key = e.key
                        p.model = incomingModels.first
                        p.name = e.name
                        try cc.syncModelsAfterRefresh(p, providerID: pid, appType: oldApp,
                                                      models: incomingModels,
                                                      proxy: proxyForHealth())
                    }
                    if local.targets.contains("dsh"), let dk = e.key, !dk.isEmpty, let dURL = e.url {
                        if DSHWriter.installed() {
                            _ = try DSHWriter.add(providerID: e.id, key: dk, url: dURL, models: incomingModels)
                        } else {
                            AppLog.info("feed 同步: 本机未安装 DSH,跳过(\(e.id.prefix(8)))")
                        }
                    }
                    if local.targets.contains("grok"), let gp = local.grokConfigPath,
                       let gk = e.key, let gURL = e.url {
                        let writer = GrokBuildWriter(configPath: gp)
                        let previousModels = local.models ?? local.model.map { [$0] } ?? []
                        _ = try writer.sync(baseURL: gURL, key: gk, models: incomingModels,
                                            removing: previousModels,
                                            staleKeys: local.key.flatMap { $0 != gk ? [$0] : nil } ?? [])
                        if let oldURL = local.url, writer.normalizeURL(oldURL) != writer.normalizeURL(gURL),
                           let oldKey = local.key {
                            _ = try writer.remove(baseURL: oldURL, key: oldKey, models: previousModels)
                        }
                    }
                    if local.targets.contains("magpie"), let mk = e.credentialKeys.first, let mURL = e.url {
                        var desired = e
                        desired.key = mk; desired.url = mURL; desired.models = incomingModels; desired.model = incomingModels.first
                        desired.magpieDestinationID = local.magpieDestinationID
                        _ = try syncMagpie(&desired)
                        e.magpieDestinationID = desired.magpieDestinationID
                    }
                    var merged = e
                    if e.models == nil && e.model == nil {
                        merged.models = local.models
                        merged.model = local.model
                    }
                    merged.ccProviderID = local.ccProviderID
                    merged.ccRenamedFrom = local.ccRenamedFrom
                    merged.ccRenamedTo = local.ccRenamedTo
                    merged.cpaConfigPath = local.cpaConfigPath
                    merged.grokConfigPath = local.grokConfigPath
                    merged.magpieDestinationID = local.targets.contains("magpie") ? (e.magpieDestinationID ?? local.magpieDestinationID) : nil
                    merged.targetSyncErrors = local.targetSyncErrors
                    if local.targets.contains("magpie") { merged.targetSyncErrors?.removeValue(forKey: "magpie") }
                    merged.legacyProbeInvalidated = true
                    // 远端探测不能证明本机 CPA 路由正常，等待本机重新验证。
                    merged.viaCPAOk = nil; merged.viaCPAAt = nil
                    merged.modelProbeLog = local.modelProbeLog
                    merged.probeLog = local.probeLog
                    merged.poolProbeLog = local.poolProbeLog
                    // targets 是【本机产物事实】:整条取远端曾丢掉本机独有的标签
                    // (如本机同步过 DSH 而维护者没有)。取并集,顺序 = 本机优先。
                    // 必须迭代 local.targets:merged 初始 = e(远端),对 e 求差永假
                    for t in local.targets where !merged.targets.contains(t) {
                        merged.targets.append(t)
                    }
                    let sameConfiguration = merged.probeConfigurationID == local.probeConfigurationID
                    merged.health = sameConfiguration ? local.health : nil
                    merged.healthAt = sameConfiguration ? local.healthAt : nil
                    merged.healthDetail = sameConfiguration ? local.healthDetail : "同步配置已更新，等待本机验证"
                    merged.viaCPAOk = sameConfiguration ? local.viaCPAOk : nil
                    merged.viaCPAAt = sameConfiguration ? local.viaCPAAt : nil
                    merged.failStreak = sameConfiguration ? local.failStreak : nil
                    merged.updatedAt = Date().timeIntervalSince1970
                    feedChanged.removeAll { $0.id == merged.id }
                    feedChanged.append(merged)
                    activeKeysByID[merged.id] = Set(merged.credentialKeys)
                    updatedFromFeed += 1
                } else {
                    skippedLocalNewer += 1
                }
                continue
            }
            if history.find(idPrefix: e.id) != nil { skippedExisting += 1; continue }
            // 清来源机器的本地产物绑定:账本是可迁移的,产物绑定是机器本地的
            e.ccProviderID = nil
            e.ccRenamedFrom = nil
            e.ccRenamedTo = nil
            e.cpaConfigPath = nil
            e.grokConfigPath = nil
            e.magpieDestinationID = nil
            e.targetSyncErrors = nil
            e.legacyProbeInvalidated = true
            e.health = nil; e.healthAt = nil
            e.viaCPAOk = nil; e.viaCPAAt = nil
            e.modelProbeLog = nil; e.probeLog = nil
            e.poolProbeLog = nil
            e.ccMissing = nil
            if try history.appendDedupByKey(e) != nil {
                skippedSameKey += 1
                continue
            }
            added += 1
            activeKeysByID[e.id] = incomingKeys
        }
        // feed 模式的 LWW 替换条目整批落盘(含维护者墓碑传播);开关仅 migrate 应用
        // (订阅者自己的偏好自主,不被维护者的导出覆盖)
        if mode == .feed, !feedChanged.isEmpty {
            try history.updateAll(feedChanged)
        }
        if mode == .migrate {
            prefs.useCC = payload.switches?.useCC ?? prefs.useCC
            prefs.useGrok = payload.switches?.useGrok ?? prefs.useGrok
            prefs.useCPA = payload.switches?.useCPA ?? prefs.useCPA
            prefs.useDSH = payload.switches?.useDSH ?? prefs.useDSH
            prefs.useMagpie = payload.switches?.useMagpie ?? prefs.useMagpie
            prefs.cpaResident = payload.switches?.cpaResident ?? prefs.cpaResident
            try prefs.save()
        }
        if mode == .feed {
            return "同步: 新增 \(added) 条,更新 \(updatedFromFeed) 条,本机较新保留 \(skippedLocalNewer) 条,墓碑传播 \(tombstonePropagated) 条,已删除跳过 \(skippedTombstone) 条"
        }
        return "导入: 新增 \(added) 条,已存在跳过 \(skippedExisting) 条,同 key 跳过 \(skippedSameKey) 条,已删除跳过 \(skippedTombstone) 条;目标开关已按导出值应用。跑「产物重放」把各工具的配置在本机重建。"
    }

    /// 产物重放:把账本里 active 条目的产物按 targets 在本机重写一遍。
    /// 用于迁移后的新机器 —— 账本是源,产物是派生。幂等口径:
    /// cc-switch 以「账本无本机 pid 或 pid 已不存在」为重放条件(防重复建行);
    /// CPA/DSH/Grok 写入器天然 upsert,重复执行无副作用。
    /// 未安装的目标(cc-switch/CPA/dsh)逐条报告跳过,不阻断其他条目。
    @discardableResult
    public func replayArtifacts() -> [String] {
        var lines: [String] = ["产物重放:"]
        var replayed = 0
        let px = proxyForHealth()
        for var e in history.snapshot() where e.status == "active" {
            let models = e.models ?? e.model.map { [$0] } ?? []
            guard let url = e.url, let keys = extractAllKeys(for: e), let key = keys.first, !key.isEmpty,
                  !models.isEmpty, !e.targets.isEmpty else { continue }
            var entryLines: [String] = []
            var ccRebuilt = false
            // cc-switch
            if e.targets.contains(where: { $0.hasPrefix("ccswitch") }) {
                let appType = e.targets.first(where: { $0.hasPrefix("ccswitch-") })
                    .map { String($0.dropFirst("ccswitch-".count)) } ?? "claude"
                if let pid = e.ccProviderID, cc.providerExists(pid, appType: appType) {
                    entryLines.append("cc-switch: 本机已有,跳过")
                } else if e.ccMissing == true {
                    // 用户在本机确认过 provider 缺失待决策:重放不得复活(审计 2026-11-13)
                    entryLines.append("cc-switch: 已标记缺失待确认,跳过重放")
                } else {
                    do {
                        var p = ParsedKey()
                        p.url = url
                        p.key = key
                        p.model = models.first
                        p.name = e.name
                        // 重放语义 = 重建产物,不抢激活(activate: false;
                        // 曾批量重放多条时最后一条赢,激活结果取决于快照顺序)
                        let r = try cc.add(p, nameOverride: e.name, appType: appType,
                                           models: models, proxy: px, activate: false)
                        e.ccProviderID = r.providerID
                        let tag = appType == "claude" ? "ccswitch" : "ccswitch-\(appType)"
                        if !e.targets.contains(tag) { e.targets.append(tag) }
                        entryLines.append("cc-switch: 已重放(未激活)")
                        replayed += 1
                        ccRebuilt = true
                    } catch {
                        entryLines.append("⚠ cc-switch: \(error.localizedDescription)")
                    }
                }
            }
            // grok(本机未装 Grok Build 时凭空建目录+落明文 key 曾无守卫,审计 2026-11-13)
            if e.targets.contains("grok") {
                let grokInstalled = e.grokConfigPath != nil
                    || FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.grok")
                if !grokInstalled {
                    entryLines.append("– Grok Build: 本机未安装,跳过")
                } else {
                    do {
                        let writer = GrokBuildWriter(configPath: e.grokConfigPath)
                        let msg = try writer.sync(baseURL: url, key: key, models: models, removing: [])
                        e.grokConfigPath = writer.configPath
                        entryLines.append("Grok Build: 已重放")
                        replayed += 1
                    } catch {
                        entryLines.append("⚠ Grok Build: \(error.localizedDescription)")
                    }
                }
            }
            // cpa
            if e.targets.contains("cpa") {
                if let cfg = prefs.resolvedCPAConfig() {
                    do {
                        let writer = CPAWriter(configPath: cfg)
                        var msg = ""
                        if e.format == "cpa-multikey", e.key == nil, e.poolKeys == nil {
                            // 旧 raw 包含当时被剔除的凭据，先重新筛选并保存真实 key 池。
                            let result = try writer.addMulti(baseURL: url, keys: keys, proxy: px,
                                                             fallbackModels: models)
                            msg = result.0
                            e.poolKeys = result.2
                            e.keyMasked = "\(result.2.count) 个 key"
                        } else {
                            for credential in keys {
                                msg = try writer.addAggregated(baseURL: url, key: credential, models: models)
                            }
                        }
                        e.cpaConfigPath = cfg
                        entryLines.append("CPA: \(msg)")
                        replayed += 1
                    } catch {
                        entryLines.append("⚠ CPA: \(error.localizedDescription)")
                    }
                } else {
                    entryLines.append("– CPA: 本机未找到 CPA 配置,跳过")
                }
            }
            // magpie(经 Web API,与行内同步同通道)
            if e.targets.contains("magpie") {
                do {
                    let msg = try syncMagpie(&e)
                    entryLines.append("Magpie: \(msg)")
                    replayed += 1
                } catch {
                    e.targetSyncErrors = e.targetSyncErrors ?? [:]
                    e.targetSyncErrors?["magpie"] = error.localizedDescription
                    entryLines.append("⚠ Magpie: \(error.localizedDescription)")
                }
            }
            // dsh(未装 DSH 的机器曾凭空创建 ~/.dsh 并落明文凭据,审计 2026-11-13)
            if e.targets.contains("dsh") {
                if !DSHWriter.installed() {
                    entryLines.append("– DSH: 本机未安装,跳过")
                } else {
                    do {
                        _ = try DSHWriter.add(providerID: e.id, key: key, url: url, models: models)
                        entryLines.append("DSH: 已重放")
                        replayed += 1
                    } catch {
                        entryLines.append("⚠ DSH: \(error.localizedDescription)")
                    }
                }
            }
            guard !entryLines.isEmpty else { continue }
            if ccRebuilt { e.ccMissing = nil }   // 只在确实重建了 provider 时清除待确认状态
            do { try history.update(e) } catch {
                entryLines.append("⚠ 账本更新失败: \(error.localizedDescription)")
            }
            lines.append("[\(e.name ?? String(e.id.prefix(8)))] " + entryLines.joined(separator: "; "))
        }
        lines[0] = "产物重放: \(replayed) 个产物写入本机"
        return lines
    }

    // MARK: - 模型真伪鉴定

    /// 对条目的当前模型跑能力阶梯探针(数学/计数/逻辑逐级),返回真伪鉴定报告。
    /// 原理与局限见 docs/model-authenticity.md:实测的是"长在权重里的能力",
    /// 中转站改响应包装规避不了;同家族版本内替换判别力有限。
    /// - Parameter model: 指定鉴定的模型;nil = 条目里第一个「未鉴定」的模型,
    ///   全都鉴定过则取第一个。结论按模型存入 verifyVerdicts
    public func verifyModelAuthenticity(entryIDPrefix: String, model: String? = nil) throws -> String {
        guard let entry = history.find(idPrefix: entryIDPrefix)
            ?? history.findActiveByRaw(entryIDPrefix)
        else {
            throw ParseError.io("历史记录中找不到: \(entryIDPrefix)")
        }
        guard !entry.isDSHOnly else { throw ParseError.io("DSH 专用条目，请在 DSH 内验证") }
        guard let url = entry.url, !url.isEmpty, let key = entry.key, !key.isEmpty else {
            throw ParseError.io("该记录缺少 URL 或 key,无法鉴定")
        }
        let models = (entry.models ?? (entry.model.map { [$0] } ?? []))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !models.isEmpty else {
            throw ParseError.io("该记录没有模型,无法鉴定")
        }
        let target = (model?.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { m in models.first { $0 == m } }   // 必须是条目已知模型
            ?? models.first { entry.verifyVerdicts?[$0] == nil }
            ?? models.first!
        let report = AuthenticityProbe.run(base: url, key: key, model: target,
                                           proxy: proxyForHealth(), timeout: 40)
        var out = ["真伪鉴定: 声称模型 \(target)"]
        out.append(contentsOf: report.lines)
        if report.claimedTier == 3, report.verdict != "旗舰级" {
            out.append("⚠ 实测能力低于旗舰级声称——高概率模型替换/降级(网关间歇性失败也可能,建议隔天复测)")
        }
        // 每模型结论持久化:多模型条目逐个鉴定后各自可见
        if var e2 = history.find(idPrefix: entryIDPrefix)
            ?? history.findActiveByRaw(entryIDPrefix) {
            var v = e2.verifyVerdicts ?? [:]
            v[target] = report.verdict
            e2.verifyVerdicts = v
            e2.verifyVerdict = report.verdict
            try? history.update(e2)
        }
        return out.joined(separator: "\n")
    }

    // MARK: - WebDAV 同步(Phase 2 简化版:显式推送/拉取加密账本快照,无自建后端)

    /// 推送加密快照时使用远端最近一次确认的版本，避免覆盖另一台设备的更新。
    public func webdavPush(force: Bool = true) throws -> String {
        let cfg = try WebDAVSync.Config.resolved()
        // 指纹去重必须先行:exportLedger 含 60 万轮 PBKDF2 + 全账本加密,自动推送
        // 每 30 分钟一跳,账本没变时旧实现每次也白付整段 KDF
        let fp = LedgerCrypto.ledgerFingerprint(history.snapshot())
        if !force, fp == prefs.webdavLastPushFP {
            return "WebDAV: 账本无变更,跳过推送"
        }
        let eTag = prefs.webdavETag
        let ledger = try exportLedger(passphrase: cfg.exportPass)
        guard try WebDAVSync.Config.resolved() == cfg else {
            throw ParseError.io("WebDAV 设置已变更，请重试")
        }
        let result = try WebDAVSync.push(cfg: cfg, ledger: ledger, eTag: eTag)
        if (try? WebDAVSync.Config.resolved()) == cfg {
            prefs.webdavETag = result.eTag
            prefs.webdavLastPushFP = fp
            try? prefs.save()
        }
        return result.message
    }

    /// 拉取:下载远端快照 → 按 id 合并(本机墓碑的 key 不复活)→ 产物重放。
    @discardableResult
    public func webdavPull(replay: Bool = true, onlyIfNewer: Bool = false) throws -> String {
        let cfg = try WebDAVSync.Config.resolved()
        let remote = try WebDAVSync.fetchSnapshot(cfg: cfg)
        guard try WebDAVSync.Config.resolved() == cfg else {
            throw ParseError.io("WebDAV 设置已变更，请重试")
        }
        let payload = remote.payload
        if onlyIfNewer {
            if let tag = remote.eTag, tag == prefs.webdavETag {
                return "WebDAV: 远端无更新,跳过拉取"
            }
            if remote.eTag == nil, let last = prefs.webdavLastSync, payload.exportedAt <= last {
                return "WebDAV: 远端无更新,跳过拉取"
            }
        }
        var lines = [try importPayload(payload, mode: .feed)]
        if (try? WebDAVSync.Config.resolved()) == cfg {
            prefs.webdavLastSync = payload.exportedAt
            prefs.webdavETag = remote.eTag
            try? prefs.save()
        }
        if replay { lines.append(contentsOf: replayArtifacts()) }
        return lines.joined(separator: "\n")
    }

    func testEntry(entryIDPrefix: String) throws -> String {
        guard let entry = history.find(idPrefix: entryIDPrefix) else {
            throw ParseError.io("历史记录中找不到: \(entryIDPrefix)")
        }
        guard !entry.isDSHOnly else { throw ParseError.io("DSH 专用条目，请在 DSH 内验证") }
        guard let url = entry.url, let key = extractKey(entry), !key.isEmpty else {
            throw ParseError.io("该记录缺少 URL 或 key,无法测试")
        }
        let px = proxyForHealth()
        let test = APITester.test(url: url, key: key, proxy: px, preferredModel: entry.model,
                                  importedModels: entry.models, probePool: entry.configuredModels,
                                  styleHint: entry.apiStyle)
        if test.skippedForCooldown {
            var updated = entry
            updatePoolProbe(for: &updated, primary: test, at: Date().timeIntervalSince1970, proxy: px)
            try history.mergePoolEvidence([updated])
            return "暂缓探测: " + test.detail
        }
        noteProxyWorked(needsProxy: test.needsProxy, used: px)
        let h = Self.healthFor(test)
        if test.ok {
            if var found = history.find(idPrefix: entryIDPrefix) {
                found.health = h.health
                found.apiStyle = test.style
                found.healthDetail = h.detail
                found.healthAt = Date().timeIntervalSince1970
                found.failStreak = nil   // 手动重测成功即清零(审计 2026-11-14 P2)
                recordProbeResult(test, for: &found)
                historyUpdateLogged(found)
            }
            let label = history.find(idPrefix: entryIDPrefix)?.availability.label ?? h.health
            return "\(label): \(h.detail) (\(test.models.count) 个模型)"
        }
        if var found = history.find(idPrefix: entryIDPrefix) {
            found.health = h.health
            found.healthDetail = h.detail
            found.healthAt = Date().timeIntervalSince1970
            recordProbeResult(test, for: &found)
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

    public static func fetchSubscriptionProxies(url: String, operation: ImportOperation? = nil) throws -> [ClashProxy] {
        let operation = operation ?? ImportOperation.current
        try operation?.advance(to: .fetchingSubscription)
        guard let u = URL(string: url),
              let scheme = u.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              u.host?.isEmpty == false
        else { throw ParseError.io("无效的订阅 URL") }
        let o = ImportOperation.$current.withValue(operation) {
            NetSync.run(session: subscriptionSession, url: u, timeout: 20)
        }
        try operation?.checkCancellation()
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

    /// 节点能否真正写进 Clash 配置:缺 server/port/uuid 任一项都会被 ClashWriter 拒
    public static func clashNodeValid(_ p: ClashProxy) -> Bool {
        !p.server.isEmpty && p.port > 0 && !p.uuid.isEmpty
    }

    /// 勾选过滤:只保留「被勾选且有效」的节点,顺序保持预览列表原样(下标即视图顺序)。
    /// 无效节点即使被勾也不写 —— 写进去也是一条永远连不上的配置
    public static func chosenClashProxies(_ all: [ClashProxy], selected: Set<Int>) -> [ClashProxy] {
        all.enumerated().filter { selected.contains($0.offset) && clashNodeValid($0.element) }.map(\.element)
    }

    /// 刷新首探失败后是否仍应给出勾选弹窗:有勾选回调 + 端点自己的 /models 有清单就要给。
    /// 恰恰是勾选的那个模型挂了才最需要改选,一报错就 return 等于把用户锁死
    /// (真实卡死 c30beaa0:模型改不了、又因 cc-switch 在跑删不掉 → 两头堵)
    public static func shouldRepickAfterFail(ok: Bool, modelList: [String], hasPicker: Bool) -> Bool {
        !ok && hasPicker && !modelList.isEmpty
    }

    /// 删除失败原因并入 note:同一句话不重复追加(重试 5 次就重复 5 遍,note 无界增长)
    public static func mergedNote(_ existing: String?, _ failures: [String]) -> String {
        var out: [String] = []
        for piece in (existing ?? "").components(separatedBy: "; ") + failures
        where !piece.isEmpty && !out.contains(piece) {
            out.append(piece)
        }
        return out.joined(separator: "; ")
    }

    /// 同一上游的多条记录共享 CPA 模型段，改选只移除当前记录放弃的模型。
    private func updateCPASelection(writer: CPAWriter, entryID: String, url: String,
                                    models: [String], previous: [String]) throws -> String {
        let upstream = writer.normalizeUpstreamURL(url)
        let siblings = history.snapshot().filter {
            $0.id != entryID && $0.status == "active" && $0.targets.contains("cpa")
                && writer.normalizeUpstreamURL($0.url ?? "") == upstream
                && (CPAAPI.apiMode || $0.cpaConfigPath == nil || $0.cpaConfigPath == writer.configPath)
        }.flatMap(\.configuredModels)
        return try writer.updateAggregatedModels(baseURL: url, models: models,
                                                  removing: previous, preserving: siblings)
    }

    private func updateCPAProbe(for entry: inout HistoryEntry, test: APITestResult, at: TimeInterval) -> [String: Bool] {
        guard entry.targets.contains("cpa") else {
            entry.viaCPAOk = nil
            entry.viaCPAAt = nil
            return [:]
        }
        guard test.ok, !test.reachabilityOnly, !test.quotaExhausted,
              let cpa = CPAWriter.endpointInfo() else { return [:] }
        let configured = Set(entry.configuredModels)
        let models = test.workingModels.filter { configured.contains($0) && !Self.isNonChatModel($0) }
        guard !models.isEmpty else { return [:] }
        let base = cpa.baseURL.hasSuffix("/v1") ? cpa.baseURL : cpa.baseURL + "/v1"
        var results: [String: Bool] = [:]
        for model in models {
            let via = APITester.testModelChat(base: base, key: cpa.clientKey, model: model, timeout: 15)
            results[model] = via.ok
            if !via.ok {
                entry.healthDetail = (entry.healthDetail ?? "") + " | ⚠ CPA 链路探测失败[\(model)](\(via.detail.prefix(180)))"
            }
        }
        entry.viaCPAOk = results.values.allSatisfy { $0 }
        entry.viaCPAAt = at
        return results
    }

    /// 每轮除首个凭据外，再测最久未验证的一个成员，限制请求量并逐轮覆盖整池。
    private func updatePoolProbe(for entry: inout HistoryEntry, primary: APITestResult, at: TimeInterval, proxy: String?) {
        let keys = entry.credentialKeys
        guard entry.isCredentialPool, keys.count > 1, let url = entry.url else { return }
        let validIDs = Set(keys.map(HistoryEntry.credentialID))
        var log = (entry.poolProbeLog ?? [:]).filter { validIDs.contains($0.key) }
        func merge(_ key: String, _ result: APITestResult) {
            guard !result.skippedForCooldown else { return }
            let id = HistoryEntry.credentialID(key)
            var points = log[id] ?? [:]
            for (model, point) in entry.scopedProbePoints(result.modelProbePoints(at: at)) { points[model] = point }
            log[id] = points
        }
        merge(keys[0], primary)
        let scope = entry.probeConfigurationID
        func lastTime(_ key: String) -> TimeInterval {
            let points = log[HistoryEntry.credentialID(key)] ?? [:]
            return entry.configuredModels.map { model in
                guard let point = points[model], point.configurationID == scope else { return 0 }
                return point.t
            }.max() ?? 0
        }
        // 冷却成员没有产生新证据，不能更新采样时间；继续寻找可测成员，
        // 否则它会始终排在队首，饿死后面的有效凭据。
        for key in keys.dropFirst().sorted(by: { lastTime($0) < lastTime($1) }) {
            let points = log[HistoryEntry.credentialID(key)] ?? [:]
            let result = APITester.test(url: url, key: key, timeout: 10, proxy: proxy,
                                       preferredModel: entry.model,
                                       modelProbeTimes: points.compactMapValues { $0.configurationID == scope ? $0.t : nil },
                                       probePool: entry.configuredModels, knownNeedsProxy: entry.health == "proxy-ok",
                                       styleHint: entry.apiStyle)
            merge(key, result)
            if !result.skippedForCooldown { break }
        }
        entry.poolProbeLog = log
    }

    /// 所有手动重测分支共享监控落盘,包括失败和改选后的第二次探测。
    private func recordProbeResult(_ test: APITestResult, for entry: inout HistoryEntry) {
        let now = test.skippedForCooldown ? Date().timeIntervalSince1970 : (entry.healthAt ?? Date().timeIntervalSince1970)
        updatePoolProbe(for: &entry, primary: test, at: now, proxy: proxyForHealth())
        guard !test.skippedForCooldown else { return }
        var points = test.modelProbePoints(at: now)
        let cpaResults = updateCPAProbe(for: &entry, test: test, at: now)
        for (model, passed) in cpaResults {
            points[model]?.cpa = passed
        }
        let cpa: Bool? = cpaResults.isEmpty ? nil : cpaResults.values.allSatisfy { $0 }
        do {
            if !test.reachabilityOnly {
                try history.appendProbePoint(id: entry.id, ok: test.ok && !test.quotaExhausted && !test.chatDegraded, ms: test.latencyMs, cpa: cpa, at: now)
            }
            try history.appendModelProbePoints(id: entry.id, points: entry.scopedProbePoints(points))
        } catch {
            AppLog.warn("探测点写入失败: \(error.localizedDescription)")
        }
    }

    private func syncMagpie(_ entry: inout HistoryEntry) throws -> String {
        guard let url = entry.url, let key = extractKey(entry) else { throw ParseError.io("Magpie 同步缺少地址或凭据") }
        let destination = try entry.magpieDestinationID ?? MagpieWriter.destinationID()
        let message = try MagpieWriter.sync(providerID: entry.id, baseURL: url, key: key,
                                            models: entry.configuredModels, apiStyle: entry.apiStyle,
                                            expectedDestinationID: destination)
        entry.magpieDestinationID = destination
        entry.targetSyncErrors?.removeValue(forKey: "magpie")
        return message
    }

    private func syncMagpieIfNeeded(_ entry: inout HistoryEntry) -> String {
        guard entry.targets.contains("magpie") else { return "" }
        do {
            return "\n✓ Magpie: " + (try syncMagpie(&entry))
        } catch {
            entry.targetSyncErrors = entry.targetSyncErrors ?? [:]
            entry.targetSyncErrors?["magpie"] = error.localizedDescription
            return "\n⚠ Magpie 同步失败: \(error.localizedDescription)"
        }
    }

    private func restoreMagpie(after attempted: HistoryEntry, to original: HistoryEntry) throws {
        guard attempted.targets.contains("magpie"),
              attempted.targetSyncErrors?["magpie"] == nil,
              let newURL = attempted.url, let newKey = extractKey(attempted) else { return }
        let attemptedState = MagpieWriter.ProviderState(baseURL: newURL, key: newKey,
                                                        models: attempted.configuredModels, apiStyle: attempted.apiStyle)
        guard original.targets.contains("magpie") else {
            _ = try MagpieWriter.remove(providerID: attempted.id, expectedDestinationID: attempted.magpieDestinationID,
                                        onlyIfMatches: attemptedState)
            return
        }
        guard let oldURL = original.url, let oldKey = extractKey(original) else {
            throw ParseError.io("原 Magpie 记录缺少凭据，无法恢复配置，请检查后重试")
        }
        _ = try MagpieWriter.sync(providerID: original.id, baseURL: oldURL, key: oldKey,
                                   models: original.configuredModels, apiStyle: original.apiStyle,
                                   expectedDestinationID: attempted.magpieDestinationID,
                                   onlyIfMatches: attemptedState)
    }

    private func saveAfterMagpie(_ entry: HistoryEntry, previous: HistoryEntry) throws {
        do { try history.update(entry) }
        catch {
            do { try restoreMagpie(after: entry, to: previous) }
            catch let rollbackError {
                throw ParseError.io("账本保存失败: \(error.localizedDescription);Magpie 回滚未完成: \(rollbackError.localizedDescription)")
            }
            throw error
        }
    }

    public func refreshModels(
        entryIDPrefix: String,
        proxy: String? = nil,
        pickModels: (([String]) -> [String])? = nil
    ) throws -> String {
        guard var entry = history.find(idPrefix: entryIDPrefix) else {
            throw ParseError.io("历史记录中找不到: \(entryIDPrefix)")
        }
        let previousEntry = entry
        let effProxy = proxy ?? proxyForHealth()
        guard !entry.isDSHOnly else { throw ParseError.io("DSH 专用条目，请在 DSH 内验证") }
        guard let url = entry.url, let key = extractKey(entry), !key.isEmpty else {
            throw ParseError.io("该记录缺少 URL 或 key,无法重新测试")
        }
        let test = APITester.test(url: url, key: key, proxy: effProxy,
                                  preferredModel: entry.model, importedModels: entry.models,
                                  probePool: entry.configuredModels, styleHint: entry.apiStyle)
        if test.ok { entry.apiStyle = test.style }
        if test.skippedForCooldown {
            updatePoolProbe(for: &entry, primary: test, at: Date().timeIntervalSince1970, proxy: effProxy)
            try history.mergePoolEvidence([entry])
            if pickModels == nil || test.models.isEmpty { throw ParseError.io(test.detail) }
        }
        // 端点报错但 /models 拿到了清单 ≠ 不能改选:恰恰是勾选的那个模型 503/429 才最需要
        // 换掉它。以前一报错就 throw,弹窗永远出不来(真实卡死 c30beaa0:模型改不了,
        // 又因 cc-switch 在跑删不掉 → 两头堵)。放行到弹窗,选完按新模型重探。
        let repickAfterFail = Self.shouldRepickAfterFail(
            ok: test.ok, modelList: test.models, hasPicker: pickModels != nil)
        guard test.ok || repickAfterFail else {
            let h = Self.healthFor(test)
            // 只改 health 不动 status:status="dead" 会让条目从 UI 全部列表消失,
            // 且 delete() 只认 status=="active",记录变成删不掉的僵尸。
            // health="dead" + status="active" 会正常进入「探测失败」,与健康扫描路径一致
            entry.health = h.health
            entry.healthDetail = h.detail
            entry.healthAt = Date().timeIntervalSince1970
            recordProbeResult(test, for: &entry)
            historyUpdateLogged(entry)
            let deadMark = (test.authFailed || test.detail.contains("401") || test.detail.contains("403"))
                ? "(接口拒绝认证，已移入探测失败区)" : ""
            throw ParseError.io("✗ 不可用: \(test.detail)\(deadMark)")
        }
        // 额度状态:仅标记不提前返回——提前返回会让 quota 条目永远无法再选模型/更新列表。
        // 余额接口只在「本轮没有任何 chat 实测通过」时才有发言权:很多中转站的余额
        // 接口与实际可用性脱节(订阅制/分组计费/虚报),chat 实测通过才是硬证据。
        // 真实反馈(dc403556):chat 全绿却被余额接口判进无额度区,周期扫描又把它
        // 捞回可用区 —— 两条路径来回横跳
        var quotaNote: String? = nil
        var balanceZero = false
        if test.ok {
            if test.quotaExhausted {
                quotaNote = "无额度(chat 端点 429/402 quota exhausted)"
            } else {
                balanceZero = APITester.checkBalance(url: url, key: key, proxy: effProxy) == .zero
                if test.workingModels.isEmpty, balanceZero {
                    quotaNote = "无余额/配额耗尽(余额接口)"
                }
            }
            entry.health = quotaNote != nil ? "quota" : Self.healthFor(test).health
            if quotaNote == nil, balanceZero {
                // 余额接口报 0 但 chat 实测可用:保留可用判定,详情里留痕提醒用户
                entry.healthDetail = test.detail + " ⚠ 余额接口报 0,但 chat 实测可用 — 以实测为准"
            } else {
                entry.healthDetail = quotaNote ?? test.detail
            }
            entry.healthAt = Date().timeIntervalSince1970
            entry.failStreak = nil   // 手动重测成功即清零
            recordProbeResult(test, for: &entry)
        } else if !test.skippedForCooldown {
            // 改选路径:先如实记下本次失败,选完再重探覆盖(别停在旧模型的 503 上)
            let h = Self.healthFor(test)
            entry.health = h.health
            entry.healthDetail = h.detail
            entry.healthAt = Date().timeIntervalSince1970
            recordProbeResult(test, for: &entry)
        }
        let previousModels = entry.configuredModels
        let currentModels = Set(previousModels)
        // test.models 是 /models JSON(data[].id)的真实模型 ID;testModels 仅给无
        // picker 的 CLI 路径兖当去噪。弹窗选项必须用原始列表:step-3.7-flash /
        // stepaudio-2.5-tts 这类「非白名单家族+点分」名会在此被当域名预杀,
        // 用户在刷新弹窗里根本看不到它们(与 add() 的 picker 误杀同一根因)
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
                    if !entry.targets.contains("grok") { entry.targets.append("grok") }
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
                do { try cc.syncModelsAfterRefresh(p, providerID: oldPid, appType: oldAppType, models: models, proxy: effProxy) }
                catch { return "⚠ cc-switch 同步失败: \(error.localizedDescription)" }
                return nil
            }
            // 家族变化:先建新、再删旧。newTag 仅替换 ccswitch* 前缀,其他 targets(dsh/cpa/clash)原样保留。
            // 旧实现「先 try? 删旧再建新」:建新失败时旧 provider 已没了,回滚用的 try? add 再失败
            // 就两头落空,且账本仍指向已删 pid;删旧失败被 try? 吞掉时又照样摘牌 → cc-switch 孤儿。
            // 先建新:建新失败 = 什么都没动,旧 provider 与账本原样可用
            let newTag = "ccswitch" + (newAppType == "claude" ? "" : "-\(newAppType)")
            var p = ParsedKey()
            p.url = url; p.key = key; p.model = models.first ?? entry.model
            let r: CCAddResult
            do {
                r = try cc.add(p, nameOverride: entry.name, appType: newAppType, models: models, proxy: effProxy)
            } catch {
                return "⚠ 迁移 \(oldAppType) → \(newAppType) 失败,已保持原 provider 不变: \(error.localizedDescription)"
            }
            var removeNote = ""
            do {
                _ = try cc.remove(providerID: oldPid, renamedFrom: entry.ccRenamedFrom,
                                  renamedTo: entry.ccRenamedTo, appType: oldAppType)
                entry.targets = entry.targets.filter { !$0.hasPrefix("ccswitch") } + [newTag]
            } catch {
                // 旧 provider 删除失败:新 provider 已建出并接管账本 pid,旧 provider 残留在
                // cc-switch(账本不再持有其 pid,无法自动清理),明确提示用户手动删
                entry.targets = entry.targets.filter { !$0.hasPrefix("ccswitch") } + [newTag]
                removeNote = ";⚠ 旧 \(oldAppType) provider 删除失败,请在 cc-switch 手动删除: \(error.localizedDescription)"
            }
            entry.ccProviderID = r.providerID
            entry.ccRenamedFrom = r.renamedFrom
            entry.ccRenamedTo = r.renamedTo
            entry.models = models
            entry.model = models.first
            return "已迁移: \(oldAppType) → \(newAppType)\(r.warnings.isEmpty ? "" : " (\(r.warnings.joined(separator: "; ")))")\(removeNote)"
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
                                   appType: newAppType, models: models, proxy: effProxy)
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
                        // 必须用迁移前的模型:entry.models 上面已改成新家族模型,拿它去按内容
                        // 匹配旧 [model.*] 段永远匹配不到 → 旧 grok 段残留却被摘牌
                        _ = try GrokBuildWriter(configPath: path).remove(
                            baseURL: url, key: key, models: previousModels
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

        if testModels.isEmpty, !repickAfterFail {
            // 端点无模型列表也同步: wire_api 探测(chat-only 网关)需保持 DB/config 新鲜
            let migrateNote = grokSyncOrMigrate(&entry, models: currentModels.sorted())
                ?? ccSyncOrMigrate(&entry, models: currentModels.sorted())
            let magpieNote = syncMagpieIfNeeded(&entry)
            // 必须在 ccSyncOrMigrate 之后再落盘:它可能就地修改 entry(targets/ccProviderID/models),
            // 提前落盘会把迁移结果丢掉,而旧 provider 已删 → 历史指向已删 provider 的孤儿态
            // (下面「模型无变化」分支即为此处的正确写法)
            try saveAfterMagpie(entry, previous: previousEntry)
            let keep = currentModels.isEmpty ? "无" : currentModels.joined(separator: ", ")
            let q = quotaNote.map { "(\($0) — 充值后刷新自动恢复)" } ?? ""
            let m = migrateNote.map { "\n\($0)" } ?? ""
            return "\(history.find(idPrefix: entry.id)?.availability.label ?? entry.availability.label): \(test.detail) (端点无模型列表,保留已有模型: \(keep))\(q)\(m)\(magpieNote)"
        }
        // 变化检测用原始列表:entry.models 修复后可能含被本启发式误杀的点分名,
        // 拿过滤后的列表比对着会把「无变化」误判成「已变化」,每次刷新都弹窗
        let modelsChanged = currentModels != Set(test.models)

        if !modelsChanged, !repickAfterFail {
            historyUpdateLogged(entry)
            // 模型无变化也同步: wire_api 探测可能已变化(chat-only 网关)且 DB/config 需保持新鲜
            let migrateNote = grokSyncOrMigrate(&entry, models: currentModels.sorted())
                ?? ccSyncOrMigrate(&entry, models: currentModels.sorted())
            let magpieNote = syncMagpieIfNeeded(&entry)
            try saveAfterMagpie(entry, previous: previousEntry)
            let q = quotaNote.map { " ⚠ \($0) — 充值后刷新自动恢复" } ?? ""
            let m = migrateNote.map { "\n\($0)" } ?? ""
            return "\(history.find(idPrefix: entry.id)?.availability.label ?? entry.availability.label): \(test.detail) (\(test.models.count) 个模型,无变化)\(q)\(m)\(magpieNote)"
        }

        var filtered: [String] = []
        if let picker = pickModels {
            let sel = picker(test.models)
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

        // 报错放行进来的改选:选完必须重探,否则 health 还停在旧模型的报错上,新模型
        // 是死是活无从判断。全挂也保留用户的选择(清单是端点自己 /models 给的),
        // 只如实标 err 并留痕,下次扫描会重测
        var retestNote: String? = nil
        var selectionTest: APITestResult?
        if repickAfterFail || filtered != previousModels {
            // 新选择必须用其自身的调用结果，目录里的其他模型成功不能替它背书。
            if filtered != previousModels {
                entry.viaCPAOk = nil
                entry.viaCPAAt = nil
            }
            let retest = APITester.test(url: url, key: key, proxy: effProxy,
                                        preferredModel: filtered.first, importedModels: filtered,
                                        probePool: filtered, styleHint: entry.apiStyle)
            let h = Self.healthFor(retest)
            if !retest.skippedForCooldown {
                if retest.ok { entry.apiStyle = retest.style }
                entry.health = h.health
                entry.healthDetail = h.detail
                entry.healthAt = Date().timeIntervalSince1970
                entry.failStreak = retest.ok ? nil : 1
                selectionTest = retest
            } else if filtered != previousModels {
                entry.health = nil
                entry.healthAt = nil
                entry.healthDetail = retest.detail
            }
            let confirmed = h.health == "ok" || h.health == "proxy-ok"
            retestNote = confirmed
                ? "✓ 改选的模型实测可用: \(h.detail)"
                : "⚠ 已改选 \(filtered.count) 个模型,尚未验证可用: \(h.detail)(下次扫描自动重测)"
        }

        var syncWarn: String? = nil
        // 主分支:模型已变化,ccSyncOrMigrate 会按新模型列表决定原地 sync 还是迁移家族
        syncWarn = grokSyncOrMigrate(&entry, models: filtered)
            ?? ccSyncOrMigrate(&entry, models: filtered)

        // DSH 同步失败只告警:此时 cc/grok 可能已迁移(就地改了 entry.targets/ccProviderID),
        // 直接 throw 会跳过下面的 history.update → 账本仍指向已删的旧 provider
        var dshNote = ""
        if entry.targets.contains("dsh") {
            do {
                _ = try DSHWriter.add(providerID: entry.id, key: key, url: url, models: filtered)
            } catch {
                dshNote = "\n⚠ DSH 同步失败: \(error.localizedDescription)"
            }
        }
        // CPA 聚合条目同步:filtered 是用户在弹窗里重新确认的模型列表,与
        // cc-switch/grok/dsh 同一账本口径。缺失此步时刷新只更新 cc 系目标,
        // CPA 条目永远停在首次导入的列表(真实场景:cc 已 4 模型,CPA 仍 1 个)
        var cpaNote = ""
        if entry.targets.contains("cpa") {
            // API 模式:读写在 CPA 服务端,条目里记的本地路径不参与任何操作 ——
            // 对它 fileExists 会在路径位于 ~/Documents 时触发 TCC「文稿」弹窗
            // (更新换签名使授权作废后,每次刷新都弹一次)。此时直接用记录值。
            let cfgPath: String?
            if CPAAPI.apiMode {
                cfgPath = entry.cpaConfigPath ?? prefs.resolvedCPAConfig()
            } else {
                cfgPath = entry.cpaConfigPath
                    .flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
                    ?? prefs.resolvedCPAConfig()
            }
            if let cfg = cfgPath {
                do {
                    let cpaMsg = try updateCPASelection(writer: CPAWriter(configPath: cfg), entryID: entry.id, url: url,
                                                        models: filtered, previous: previousModels)
                    entry.cpaConfigPath = cfg
                    cpaNote = "\n✓ CPA: \(cpaMsg)"
                    let resident = syncCPAResidentEntries(models: filtered)
                    if !resident.isEmpty { cpaNote += "\n" + resident.joined(separator: "\n") }
                } catch {
                    cpaNote = "\n⚠ CPA 同步失败: \(error.localizedDescription)"
                }
            }
        }
        if let selectionTest { recordProbeResult(selectionTest, for: &entry) }
        let magpieNote = syncMagpieIfNeeded(&entry)
        try saveAfterMagpie(entry, previous: previousEntry)
        let q = quotaNote.map { " ⚠ \($0) — 充值后刷新自动恢复" } ?? ""
        let w = syncWarn.map { "\n\($0)" } ?? ""
        let r = retestNote == nil ? "" : "\n\(history.find(idPrefix: entry.id)?.availability.label ?? entry.availability.label): \(entry.healthDetail ?? "")"
        if retestNote != nil {
            // 以新选择的复测结果报告，不能沿用旧模型的成功提示。
            return "已改选 \(filtered.count) 个模型(端点: \(test.detail))\(w)\(dshNote)\(cpaNote)\(magpieNote)\(r)"
        }
        return "\(history.find(idPrefix: entry.id)?.availability.label ?? entry.availability.label): \(test.detail) (\(test.models.count) 个模型,已更新 \(filtered.count) 个)\(q)\(w)\(dshNote)\(cpaNote)\(magpieNote)"
    }

    /// 编辑弹窗「勾选模型」的数据源:只探测不写任何目标/账本
    /// (test.models 是 /models 的原始 ID 列表,未经 looksLikeModel 去噪,
    ///  否则点分新命名在弹窗里根本看不到)
    public func probeModels(entryIDPrefix: String) throws -> [String] {
        guard let entry = history.find(idPrefix: entryIDPrefix) else {
            throw ParseError.io("历史记录中找不到: \(entryIDPrefix)")
        }
        guard !entry.isDSHOnly else { throw ParseError.io("DSH 专用条目，请在 DSH 内使用") }
        guard let url = entry.url, let key = extractKey(entry), !key.isEmpty else {
            throw ParseError.io("该记录缺少 URL 或 key,无法探测模型")
        }
        let test = APITester.test(url: url, key: key, proxy: proxyForHealth(),
                                  preferredModel: entry.model, importedModels: entry.models, styleHint: entry.apiStyle)
        guard test.ok else { throw ParseError.io("探测失败: \(test.detail)") }
        return test.models
    }

    /// 编辑条目:改模型列表/名称,重新验证模型并同步所有目标(cc-switch/dsh)
    public func editEntry(
        entryIDPrefix: String,
        models: [String]? = nil,
        name: String? = nil,
        key newKey: String? = nil,
        note: String? = nil,
        verify: Bool = true
    ) throws -> String {
        guard var entry = history.find(idPrefix: entryIDPrefix)
            ?? history.findActiveByRaw(entryIDPrefix)
        else {
            throw ParseError.io("历史记录中找不到: \(entryIDPrefix)")
        }
        guard let url = entry.url, let key = extractKey(entry), !key.isEmpty else {
            throw ParseError.io("该记录缺少 URL 或 key,无法编辑")
        }

        if entry.isDSHOnly && (models != nil || newKey != nil) {
            throw ParseError.io("请通过「仅导入 DSH」更新此条目的模型或凭据")
        }
        let previousEntry = entry

        var lines: [String] = []
        let previousModels = entry.configuredModels
        var newModels = previousModels

        // key 轮换:站方轮换 key 是高频场景,同 URL 同模型只换凭据。新 key 必须先
        // 通过完整探测(与导入同口径),失败则整体拒绝 —— 不允许把没验证过的凭据
        // 写进任何产物。通过后本函数内所有验证与同步一律改用新 key。
        var effectiveKey = key
        let previousKey = key
        var keyRotated = false
        var rotationTest: APITestResult?
        if let newKey = newKey?.trimmingCharacters(in: .whitespacesAndNewlines), !newKey.isEmpty, newKey != key {
            if let owner = history.findActiveByKey(newKey) {
                throw ParseError.duplicate(id: owner.id, message: "新凭据已属于活跃记录，不能通过轮换重复认领")
            }
            let selected = models?.isEmpty == false ? models! : entry.configuredModels
            let test = APITester.test(url: url, key: newKey, proxy: proxyForHealth(),
                                      preferredModel: selected.first, probePool: selected, styleHint: entry.apiStyle)
            guard test.ok else {
                throw ParseError.io("新 key 验证失败,未做任何修改: \(test.detail)")
            }
            entry.apiStyle = test.style
            rotationTest = test
            effectiveKey = newKey
            keyRotated = true
            if entry.isCredentialPool {
                entry.poolKeys = entry.credentialKeys.map { $0 == previousKey ? newKey : $0 }
                entry.key = nil
                entry.keyMasked = "\(entry.poolKeys!.count) 个 key"
            } else {
                entry.key = newKey
                entry.keyMasked = newKey.count > 8
                    ? String(newKey.prefix(6)) + "…" + String(newKey.suffix(4))
                    : String(repeating: "*", count: max(newKey.count, 6))
            }
            entry.health = "ok"
            entry.healthDetail = "key 已轮换,新 key 已通过完整探测"
            entry.healthAt = Date().timeIntervalSince1970
            lines.append("✓ key 已轮换: \(entry.keyMasked)")
        }

        // 模型级探测点入档容器(函数级:models 块与 key 轮换块共用)
        var editModelPoints: [String: ProbePoint] = [:]
        let editProbeNow = Date().timeIntervalSince1970
        var editUsedProxy = false

        if let models, !models.isEmpty {
            var verified: [String] = []
            var failures: [String] = []
            // 验证结果入档为模型级探测点(此前编辑路径不写点,新加的模型在监控里
            // 全灰到下一次扫描;失败也记红格——监控如实记录失败轨迹)
            let verifyProxy = proxyForHealth()
            for m in models {
                if verify {
                    // 先直连再代理:验证端点拿到代理就只走代理(无直连回退),本机代理对
                    // 回环/内网网关会返 502,直接传代理会把本可直连的模型全判失败(与 add() 同口径)
                    var check = APITester.testModelChat(base: url, key: effectiveKey, model: m, styleHint: entry.apiStyle)
                    if !check.ok, let verifyProxy, !verifyProxy.isEmpty {
                        check = APITester.testModelChat(base: url, key: effectiveKey, model: m, proxy: verifyProxy, styleHint: entry.apiStyle)
                        if check.ok { editUsedProxy = true }
                    }
                    if check.ok {
                        entry.apiStyle = check.style
                        verified.append(m)
                        editModelPoints[m] = ProbePoint(t: editProbeNow, ms: nil, ok: true)
                    } else {
                        failures.append("\(m) → \(check.detail)")
                        editModelPoints[m] = ProbePoint(t: editProbeNow, ms: nil, ok: false)
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
        if let note {
            entry.note = note.isEmpty ? nil : note
            lines.append("✓ 备注已更新")
        }

        // 旧判断 newModels.isEmpty && name == nil:newModels 默认就是 previousModels(几乎总非空),
        // 什么都没传也会走完整同步流程;name == "" 也漏判
        if (models ?? []).isEmpty && (name ?? "").isEmpty && !keyRotated && note == nil {
            return "无变更"
        }

        // 池轮换先确认 CPA 成功，再同步其他目标并保存账本；失败不能把旧池抛弃。
        var poolRotationWriter: CPAWriter?
        if keyRotated, entry.isCredentialPool, entry.targets.contains("cpa") {
            let cfg: String?
            if CPAAPI.apiMode {
                cfg = entry.cpaConfigPath ?? prefs.resolvedCPAConfig()
            } else {
                cfg = entry.cpaConfigPath.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
                    ?? prefs.resolvedCPAConfig()
            }
            guard let cfg else { throw ParseError.io("未找到 CPA 配置，凭据池未轮换") }
            let writer = CPAWriter(configPath: cfg)
            let message = try writer.rotateKey(baseURL: url, oldKey: previousKey, newKey: effectiveKey)
            guard !message.isEmpty else { throw ParseError.io("CPA 组内未找到旧 key，凭据池未轮换") }
            poolRotationWriter = writer
            entry.cpaConfigPath = cfg
            lines.append("✓ CPA: " + message)
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
                let msg = try writer.sync(baseURL: url, key: effectiveKey, models: newModels, removing: [])
                if !entry.targets.contains("grok") { entry.targets.append("grok") }
                entry.grokConfigPath = writer.configPath
                lines.append("✓ Grok Build: \(msg)")
                // 旧 cc provider 删除成功才摘牌(先建后删):try? 吞掉失败照样摘 ccswitch
                // 标签+pid,provider 仍活在 cc-switch 却无人认领,delete/reconcile 都清不到
                var ccReleased = entry.ccProviderID == nil
                if let pid = entry.ccProviderID {
                    let oldTag = entry.targets.first(where: { $0.hasPrefix("ccswitch") }) ?? "ccswitch"
                    let oldApp = oldTag.hasPrefix("ccswitch-")
                        ? String(oldTag.dropFirst("ccswitch-".count)) : "claude"
                    do {
                        _ = try cc.remove(providerID: pid, renamedFrom: entry.ccRenamedFrom,
                                          renamedTo: entry.ccRenamedTo, appType: oldApp)
                        ccReleased = true
                    } catch {
                        lines.append("⚠ 旧 \(oldApp) provider 清理失败,账本仍认领它可再删: \(error.localizedDescription)")
                    }
                }
                if ccReleased {
                    entry.targets.removeAll { $0.hasPrefix("ccswitch") }
                    entry.ccProviderID = nil
                    entry.ccRenamedFrom = nil
                    entry.ccRenamedTo = nil
                }
            } catch {
                lines.append("⚠ Grok Build 同步失败: \(error.localizedDescription)")
            }
        } else if desiredAppType == "grok", entry.targets.contains("grok") {
            do {
                let writer = GrokBuildWriter(configPath: entry.grokConfigPath)
                // 换 key(站方轮换)必须传旧 key:removeModelSections 按 model+key 寻址,
                // 不传则旧 key 的模型表永久残留并在 upsert 时制造 #尾号 重复表
                let staleGrokKeys = keyRotated ? [previousKey] : []
                let msg = try writer.sync(
                    baseURL: url,
                    key: effectiveKey,
                    models: newModels,
                    removing: previousModels,
                    staleKeys: staleGrokKeys
                )
                entry.grokConfigPath = writer.configPath
                lines.append("✓ Grok Build: \(msg)")
            } catch {
                lines.append("⚠ Grok Build 同步失败: \(error.localizedDescription)")
            }
        } else if desiredAppType != "grok", entry.targets.contains("grok") {
            var p = ParsedKey()
            p.url = url
            p.key = effectiveKey
            p.model = newModels.first
            do {
                let r = try cc.add(p, nameOverride: entry.name,
                                   appType: desiredAppType, models: newModels, proxy: proxyForHealth())
                entry.targets.append(desiredAppType == "claude" ? "ccswitch" : "ccswitch-\(desiredAppType)")
                entry.ccProviderID = r.providerID
                entry.ccRenamedFrom = r.renamedFrom
                entry.ccRenamedTo = r.renamedTo
                lines.append("✓ 已迁移: Grok Build → \(desiredAppType)")
                // 旧 grok 段删除成功才摘 grok 牌:失败时 [model.*] 表仍在,保留标签让 delete 继续清理
                if let path = entry.grokConfigPath {
                    do {
                        _ = try GrokBuildWriter(configPath: path).remove(
                            baseURL: url, key: previousKey,
                            models: previousModels
                        )
                        entry.targets.removeAll { $0 == "grok" }
                    } catch {
                        lines.append("⚠ 旧 grok 段清理失败,账本仍认领: \(error.localizedDescription)")
                    }
                } else {
                    entry.targets.removeAll { $0 == "grok" }
                }
            } catch {
                lines.append("⚠ Grok Build → \(desiredAppType) 迁移失败: \(error.localizedDescription)")
            }
        }

        // 同步 cc-switch。目标家族是 grok 时跳过:此时仍带 ccswitch 标签只可能是旧 provider
        // 清理失败的残留,再往里同步 grok 模型只会把旧 provider 写坏
        if desiredAppType != "grok",
           entry.targets.contains(where: { $0.hasPrefix("ccswitch") }),
           let pid = entry.ccProviderID {
            let appType = entry.targets.first(where: { $0.hasPrefix("ccswitch-") })
                .map { String($0.dropFirst("ccswitch-".count)) } ?? "claude"
            var p = ParsedKey()
            p.url = url
            p.key = effectiveKey
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
                _ = try DSHWriter.add(providerID: entry.id, key: effectiveKey, url: url, models: newModels)
                lines.append("✓ DeepSeek Harness: 已同步模型")
            } catch {
                lines.append("⚠ DeepSeek Harness 同步失败: \(error.localizedDescription)")
            }
        }

        // CPA 同步(与 refresh 同一账本口径,此前编辑只更新 cc 系目标,CPA 条目停在旧列表):
        // 编辑模型只替换本条目选择，同时保留其他条目的模型;
        // key 轮换 → 聚合条目组内原位替换旧 key。API 模式全程零文件触碰。
        if entry.targets.contains("cpa") {
            let cfgPath: String?
            if CPAAPI.apiMode {
                cfgPath = entry.cpaConfigPath ?? prefs.resolvedCPAConfig()
            } else {
                cfgPath = entry.cpaConfigPath
                    .flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
                    ?? prefs.resolvedCPAConfig()
            }
            if let cfg = cfgPath {
                do {
                    let writer = CPAWriter(configPath: cfg)
                    var cpaLines: [String] = []
                    if keyRotated, poolRotationWriter == nil {
                        let msg = try writer.rotateKey(baseURL: url, oldKey: previousKey, newKey: effectiveKey)
                        if !msg.isEmpty {
                            cpaLines.append(msg)
                        } else {
                            // 静默跳过会让用户以为 CPA 也换了 key,旧 key 仍留在池内轮询
                            cpaLines.append("⚠ CPA 组内未找到旧 key,轮换未应用(可能已手动处理)")
                        }
                    }
                    if !(models ?? []).isEmpty {
                        let msg = try updateCPASelection(writer: writer, entryID: entry.id, url: url,
                                                         models: newModels, previous: previousModels)
                        cpaLines.append(msg)
                        entry.cpaConfigPath = cfg
                        lines.append("✓ CPA: " + cpaLines.joined(separator: "; "))
                        let resident = syncCPAResidentEntries(models: newModels)
                        if !resident.isEmpty { lines.append(contentsOf: resident) }
                    } else if !cpaLines.isEmpty {
                        entry.cpaConfigPath = cfg
                        lines.append("✓ CPA: " + cpaLines.joined(separator: "; "))
                    }
                } catch {
                    lines.append("⚠ CPA 同步失败: \(error.localizedDescription)")
                }
            } else if keyRotated {
                // 静默跳过会让用户以为 CPA 也换了 key,旧 key 仍留在池内轮询
                lines.append("⚠ CPA: 未找到本机 CPA 配置,key 轮换未同步到 CPA(旧 key 仍在池内)")
            }
        }

        if !editModelPoints.isEmpty || rotationTest != nil {
            let result = editModelPoints.isEmpty ? rotationTest! : APITestResult(
                ok: true, style: entry.apiStyle ?? "openai", models: newModels,
                detail: "编辑后所选模型验证通过", authFailed: false, needsProxy: editUsedProxy,
                workingModels: newModels.filter { editModelPoints[$0]?.ok == true },
                failedModels: editModelPoints.filter { !$0.value.ok }.map(\.key))
            let status = Self.healthFor(result)
            entry.health = status.health
            entry.healthDetail = status.detail
            entry.healthAt = editProbeNow
            entry.failStreak = nil
            recordProbeResult(result, for: &entry)
        }
        let magpieNote = syncMagpieIfNeeded(&entry)
        if !magpieNote.isEmpty { lines.append(magpieNote.trimmingCharacters(in: .newlines)) }
        do { try saveAfterMagpie(entry, previous: previousEntry) }
        catch {
            if let writer = poolRotationWriter {
                do { _ = try writer.rotateKey(baseURL: url, oldKey: effectiveKey, newKey: previousKey) }
                catch let rollbackError {
                    throw ParseError.io("账本保存失败: \(error.localizedDescription);CPA 轮换回滚失败: \(rollbackError.localizedDescription)")
                }
            }
            throw error
        }
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
        var msg: String
        if r.activationDeferred {
            msg = "✓ CPA 端点(\(ep.baseURL))已写入 cc-switch → \(appLabel)，保留当前 provider 未切换"
            msg += "\n  运行时缓存: cc-switch 已运行，需在 cc-switch 界面手动切换或重启后切换"
        } else {
            msg = "✓ CPA 端点(\(ep.baseURL))已写入 cc-switch → \(appLabel) 并激活"
        }
        if r.directMode { msg += "\n  直写模式: 已更新配置文件,重开会话生效" }
        else if r.proxyMode { msg += "\n  代理模式: 热切换,立即可用" }
        for w in r.warnings { msg += "\n  ⚠ \(w)" }
        return msg
    }

    /// 将已有条目同步到 DeepSeek Harness。该操作只新增/更新 DSH 目标，
    /// 不改变条目当前的 cc-switch、CPA 或 Grok Build 目标。
    /// DSH route 以条目 ID 为稳定键，重复同步只会原位更新。
    public func syncToDSH(entryIDPrefix: String) throws -> String {
        guard var entry = history.find(idPrefix: entryIDPrefix)
            ?? history.findActiveByRaw(entryIDPrefix)
        else {
            throw ParseError.io("历史记录中找不到: \(entryIDPrefix)")
        }
        guard entry.status == "active" else {
            throw ParseError.io("该记录已删除,无法同步到 DSH")
        }
        guard let url = entry.url, !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let key = extractKey(entry), !key.isEmpty else {
            throw ParseError.io("该记录缺少 URL 或 key,无法同步到 DSH")
        }
        let models = (entry.models ?? (entry.model.map { [$0] } ?? []))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !models.isEmpty else {
            throw ParseError.io("该记录没有模型,请先编辑或刷新模型后再同步到 DSH")
        }

        let alreadyLinked = entry.targets.contains("dsh")
        let route = try DSHWriter.add(providerID: entry.id, key: key, url: url, models: models)
        if !alreadyLinked { entry.targets.append("dsh") }
        entry.dshMissingAt = nil   // 路由回来了,清缺失标
        do {
            try history.update(entry)
        } catch {
            // 新增目标时可以安全回滚,避免留下没有账本认领的 DSH route。
            // 已有目标不能删除,否则账本保存失败会反而破坏原来可用的配置。
            if !alreadyLinked { try? DSHWriter.remove(providerID: entry.id) }
            throw ParseError.io("DSH 已写入,但 KeyDrop 记录保存失败: \(error.localizedDescription)")
        }
        // 全量对账必须在 history.update 之后:先认领再对账,否则刚写入的路由
        // (账本还没记 dsh 目标)会被当成孤儿删掉
        let reconcileLines = reconcileDSH()
        var msg = "✓ DeepSeek Harness: 已\(alreadyLinked ? "更新" : "添加") provider「\(route)」(\(models.count) 个模型)"
        msg += reconcileLines.map { "\n✓ " + $0 }.joined()
        msg += DSHWriter.dshWebRunning()
            ? "\n⚠ DSH web 正在运行:Jet Hub 在启动时才导入 settings.yaml,重启 DSH 后可见"
            : "\nDSH 未在运行:下次启动 DSH 时自动导入"
        return msg
    }

    /// 通用「按需同步到指定目标」:条目行的同步菜单入口(cc-switch/CPA/DSH/Grok)。
    /// 与 replayArtifacts 的区别:单条目、单目标、用户显式触发。
    /// - cc-switch:账本无本机 pid 或 pid 已不存在 → cc.add 建;已存在 → syncModelsAfterRefresh
    /// - CPA:聚合条目 upsert(key 和条目明确选择的模型合并)
    /// - DSH/Grok:写入器天然 upsert
    public func syncTarget(entryIDPrefix: String, target: String) throws -> String {
        guard var entry = history.find(idPrefix: entryIDPrefix)
            ?? history.findActiveByRaw(entryIDPrefix)
        else {
            throw ParseError.io("历史记录中找不到: \(entryIDPrefix)")
        }
        guard entry.status == "active" else {
            throw ParseError.io("该记录已删除,无法同步")
        }
        if entry.isDSHOnly && target != "dsh" {
            throw ParseError.io("此凭据仅配置给 DSH")
        }
        guard let url = entry.url, !url.isEmpty,
              let key = extractKey(entry), !key.isEmpty else {
            throw ParseError.io("该记录缺少 URL 或 key,无法同步")
        }
        let models = entry.configuredModels
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !models.isEmpty else {
            throw ParseError.io("该记录没有模型,请先编辑或刷新模型后再同步")
        }
        let px = proxyForHealth()
        switch target {
        case "ccswitch":
            let appType = entry.targets.first(where: { $0.hasPrefix("ccswitch-") })
                .map { String($0.dropFirst("ccswitch-".count)) } ?? "claude"
            if let pid = entry.ccProviderID, cc.providerExists(pid, appType: appType) {
                var p = ParsedKey()
                p.url = url
                p.key = key
                p.model = models.first
                p.name = entry.name
                try cc.syncModelsAfterRefresh(p, providerID: pid, appType: appType,
                                              models: models, proxy: px)
                return "cc-switch: 已同步模型(\(models.count) 个)"
            }
            var p = ParsedKey()
            p.url = url
            p.key = key
            p.model = models.first
            p.name = entry.name
            // 同步语义 = 写入凭据,不抢激活(用户当前用的 provider 不被换掉)
            let r = try cc.add(p, nameOverride: entry.name, appType: appType, models: models, proxy: px, activate: false)
            entry.ccProviderID = r.providerID
            let tag = appType == "claude" ? "ccswitch" : "ccswitch-\(appType)"
            if !entry.targets.contains(tag) { entry.targets.append(tag) }
            do { try history.update(entry) }
            catch {
                // 回滚 best-effort:防重复建 provider
                try? cc.remove(providerID: r.providerID, renamedFrom: nil, renamedTo: nil, appType: appType)
                throw ParseError.io("cc-switch 已写入但账本保存失败,已回滚: \(error.localizedDescription)")
            }
            return "cc-switch: 已新建 provider(未激活,需要时在 cc-switch 中切换)"
        case "cpa":
            guard let cfg = prefs.resolvedCPAConfig() else {
                throw ParseError.io("本机未找到 CPA 配置(config.yaml 或管理 API)")
            }
            // 旧配置路径漂移守卫:先从旧路径回收 key,防双配置残留无账本指针的凭据
            if let oldCfg = entry.cpaConfigPath, oldCfg != cfg {
                do { _ = try CPAWriter(configPath: oldCfg).remove(apiKeys: [key], baseURL: url) }
                catch { AppLog.warn("CPA 同步: 旧配置(\(oldCfg))key 回收失败: \(error.localizedDescription)") }
            }
            let alreadyHadCPA = entry.targets.contains("cpa")
            let msg = try CPAWriter(configPath: cfg)
                .addAggregated(baseURL: url, key: key, models: models)
            entry.cpaConfigPath = cfg
            if !entry.targets.contains("cpa") { entry.targets.append("cpa") }
            do { try history.update(entry) }
            catch {
                if !alreadyHadCPA { try? CPAWriter(configPath: cfg).remove(apiKeys: [key], baseURL: url) }
                throw ParseError.io("CPA 已写入但账本保存失败: \(error.localizedDescription)")
            }
            return "CPA: \(msg)"
        case "dsh":
            let alreadyHadDSH = entry.targets.contains("dsh")
            let route = try DSHWriter.add(providerID: entry.id, key: key, url: url, models: models)
            if !entry.targets.contains("dsh") { entry.targets.append("dsh") }
            do { try history.update(entry) }
            catch {
                // 已有目标不回滚:回滚会销毁同步前就完好的产物
                if !alreadyHadDSH { try? DSHWriter.remove(providerID: entry.id) }
                throw ParseError.io("DSH 已写入但账本保存失败: \(error.localizedDescription)")
            }
            // 先认领(history.update)再全量对账,顺序同理见 syncToDSH
            let reconcileLines = reconcileDSH()
            var msg = "DSH: \(route)"
            msg += reconcileLines.map { "; " + $0 }.joined()
            return msg
        case "grok":
            let alreadyHadGrok = entry.targets.contains("grok")
            let writer = GrokBuildWriter(configPath: entry.grokConfigPath)
            let msg = try writer.sync(baseURL: url, key: key, models: models, removing: [])
            entry.grokConfigPath = writer.configPath
            if !entry.targets.contains("grok") { entry.targets.append("grok") }
            do { try history.update(entry) }
            catch {
                if !alreadyHadGrok { try? writer.remove(baseURL: url, key: key, models: models) }
                throw ParseError.io("Grok Build 已写入但账本保存失败: \(error.localizedDescription)")
            }
            return "Grok Build: \(msg)"
        case "magpie":
            let alreadyHadMagpie = entry.targets.contains("magpie")
            let previous = entry
            let msg: String
            do { msg = try syncMagpie(&entry) }
            catch {
                if alreadyHadMagpie {
                    entry.targetSyncErrors = entry.targetSyncErrors ?? [:]
                    entry.targetSyncErrors?["magpie"] = error.localizedDescription
                    try history.update(entry)
                }
                throw error
            }
            if !entry.targets.contains("magpie") { entry.targets.append("magpie") }
            do { try saveAfterMagpie(entry, previous: previous) }
            catch {
                throw ParseError.io("Magpie 已写入但账本保存失败: \(error.localizedDescription)")
            }
            return "Magpie: \(msg)"
        default:
            throw ParseError.io("未知同步目标: \(target)")
        }
    }

    public func delete(entryIDPrefix: String) throws -> String {
        guard let entry = history.find(idPrefix: entryIDPrefix)
            ?? history.findActiveByRaw(entryIDPrefix)
        else {
            throw ParseError.io("历史记录中找不到: \(entryIDPrefix)")
        }
        guard entry.status == "active" else {
            return "该记录已删除"
        }

        return try deleteEntry(entry, deletedAt: Date().timeIntervalSince1970)
    }

    private func deleteEntry(_ original: HistoryEntry, deletedAt: TimeInterval) throws -> String {
        var entry = original
        var lines: [String] = []
        var failures: [String] = []
        var remaining = entry.targets

        if entry.targets.contains("cpa") {
            if let cfg = entry.cpaConfigPath,
               let keys = extractAllKeys(for: entry), !keys.isEmpty {
                do {
                    let msg = try CPAWriter(configPath: cfg).remove(apiKeys: keys, baseURL: entry.url)
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
        if entry.targets.contains("magpie") {
            do {
                let msg = try MagpieWriter.remove(providerID: entry.id, expectedDestinationID: entry.magpieDestinationID)
                if msg.isEmpty {
                    lines.append("– Magpie: 未找到本条目的行,跳过")
                } else {
                    lines.append("✓ Magpie: \(msg)")
                }
                remaining.removeAll { $0 == "magpie" }
            } catch {
                failures.append("Magpie: \(error.localizedDescription)")
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
                } catch let error as WriterError where error.isCurrentMutationBlocked {
                    // cc-switch 运行中拒绝删除,不能进入按 ID 兜底,否则会绕过运行态保护。
                    failures.append("cc-switch: \(error.localizedDescription)")
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
        // 记删除时间供账本压实计龄;恢复 active 时清除
        entry.deletedAt = remaining.isEmpty ? deletedAt : nil
        if !failures.isEmpty {
            entry.note = Self.mergedNote(entry.note, failures)
        }
        do {
            try history.update(entry)
        } catch {
            failures.append("历史状态保存失败: \(error.localizedDescription)")
        }
        if !failures.isEmpty {
            throw ParseError.io((lines + failures.map { "✗ \($0)" }).joined(separator: "\n"))
        }
        return lines.isEmpty ? "已删除" : lines.joined(separator: "\n")
    }

    /// 取条目可用于探测/验证的凭据:单 key 直接读 key，多 key 优先读已接受的凭据池，
    /// 仅旧账本回退 raw。编辑/重测/curl 复制只需一把凭据，CPA 侧会轮询全池。
    public func extractKey(_ e: HistoryEntry) -> String? {
        e.credentialKeys.first
    }

    /// 取条目对应的所有 key:优先读取持久化凭据；旧版多 key 条目从 raw 恢复。
    /// 返回 nil 表示无法恢复任何 key,调用方应跳过删除并报告失败。
    private func extractAllKeys(for e: HistoryEntry) -> [String]? {
        let keys = e.credentialKeys
        return keys.isEmpty ? nil : keys
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
