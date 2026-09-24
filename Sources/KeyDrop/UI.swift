import KeyDropCore
import AppKit
import SwiftUI
import UserNotifications

final class AppState: ObservableObject {
    deinit {
        // 卫生清理:timer 不 invalidate 会留在 runloop 空转;task 不 cancel 会延迟触发 weak no-op
        healthTimer?.invalidate()
        statusClearTask?.cancel()
    }

    @Published var input = ""
    @Published var statusText = ""
    @Published var statusOK = true
    @Published var historyVersion = 0
    @Published var refreshingID: String?
    @Published var isBusy = false
    @Published var busyLabel = ""
    @Published var modelPickerShown = false
    @Published var modelPickerOptions: [String] = []
    @Published var modelPickerPreselected: Set<String> = []
    var modelPickerResult: (([String]) -> Void)?
    private var modelPickerResolved = false
    @Published var clashPreviewShown = false
    @Published var clashPreviewProxies: [ClashProxy] = []
    @Published var useCC: Bool
    @Published var useGrok: Bool
    @Published var useCPA: Bool
    @Published var useDSH: Bool
    @Published var proxyText: String
    @Published var highlightID: String?
    @Published var highlightPulse = 0
    @Published var helpShown = false
    /// CPA 管理 API 配置 sheet(密钥走 prefs.cpaManagementKey,API 模式根治文稿弹窗)
    @Published var cpaAPISheetShown = false
    @Published var cpaAPIKeyInput = ""
    @Published var cpaAPIBaseInput = ""
    @Published var cpaAPIStatus = ""
    @Published var cpaAPIOk = false
    /// 监控图 sheet 当前展示的条目 ID(nil=关闭)

    /// status banner 计数:只统计可用区(health=ok/proxy-ok 的 active 条目)。
    /// 额度区(quota)与待删除区(dead/err)不进横幅 —— 用户只关注当前可用网关的
    /// 健康度,死 key/无额度是已知状态,各自分区里可见即可(统计口径由用户确认)。
    /// 配置模型全红的条目已挬入无额度区,同样不算可用(口径与分区一致)
    func statusCounts() -> (ok: Int, warn: Int, dead: Int) {
        var ok = 0, warn = 0
        for e in core.history.snapshot()
        where e.status == "active" && e.healthAt != nil
              && (e.health == "ok" || e.health == "proxy-ok")
              && !e.allConfiguredModelsLimited {
            if e.viaCPAOk == false { warn += 1 } else { ok += 1 }
        }
        return (ok, warn, 0)
    }
    @Published var updateState: Updater.State = .idle
    @Published var updateSheetShown = false
    @Published var editShown = false
    @Published var editTarget: HistoryEntry?
    @Published var editModelsText = ""
    @Published var editNameText = ""
    private var statusClearTask: DispatchWorkItem?
    private var healthTimer: Timer?

    let core = Core.shared

    init() {
        useCC = Prefs.shared.useCC
        useGrok = Prefs.shared.useGrok
        useCPA = Prefs.shared.useCPA
        useDSH = Prefs.shared.useDSH
        proxyText = Prefs.shared.proxy
        cpaAPIKeyInput = Prefs.shared.cpaManagementKey ?? ""
        cpaAPIBaseInput = Prefs.shared.cpaAPIBase ?? ""
    }

    func doAdd() {
        let raw = input
        guard !isBusy else { return }
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            setStatus("请先粘贴内容", ok: false)
            return
        }

        // 仅当「有效行几乎都是代理链接」时走 Clash,避免混贴 key 被误吞
        if Self.looksLikeClashOnly(raw) {
            let proxies = Core.parseClashProxies(raw: raw)
            if !proxies.isEmpty {
                input = ""
                clashPreviewProxies = proxies
                clashPreviewShown = true
                return
            }
        }

        // 单行订阅链接也不依赖 cc/cpa
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let maybeSub = !trimmed.contains("\n")
            && (trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://"))
            && !trimmed.contains(" ")
        if maybeSub {
            isBusy = true
            busyLabel = "拉取订阅…"
            setStatus("正在拉取订阅…", ok: true)
            Task { @MainActor in
                // 拉 sub 是探测:失败/空结果都不是最终结论,必须回落到普通 key 导入。
                // 注意交接:continueAddKey 有 guard !isBusy,必须先把外层的 busy 标志交还给
                // 它(否则回退路径会被静默吞掉,用户粘贴普通链接点导入毫无反应)
                var proxies: [ClashProxy]? = nil
                do {
                    proxies = try await Task.detached(priority: .userInitiated) {
                        try Core.fetchSubscriptionProxies(url: trimmed)
                    }.value
                } catch {
                    proxies = []
                }
                if let list = proxies, !list.isEmpty {
                    isBusy = false
                    busyLabel = ""
                    input = ""
                    clashPreviewProxies = list
                    clashPreviewShown = true
                    setStatus("检测到订阅,请确认导入", ok: true)
                    return
                }
                // 回退到普通 key 导入前必须先归还 busy 标志:
                // continueAddKey 有 guard !isBusy,不复位则回退被静默吞掉,
                // isBusy 永久卡在 true,面板按钮全部禁用只能重启
                isBusy = false
                busyLabel = ""
                await self.continueAddKey(raw: raw)
            }
            return
        }

        Task { @MainActor in
            await continueAddKey(raw: raw)
        }
    }

    private static func looksLikeClashOnly(_ raw: String) -> Bool {
        let lines = raw.split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return false }
        // 与 Core.add 一致:只统计能真正解析的代理行,socks5 等不支持的协议不算
        let proxyCount = lines.filter { Parser.parseProxyURL($0) != nil }.count
        return proxyCount > 0 && proxyCount * 2 >= lines.count
    }

    @MainActor
    private func continueAddKey(raw: String) async {
        if !useCC && !useGrok && !useCPA && !useDSH {
            setStatus("请先开启 cc-switch、Grok Build、CPA 或 DeepSeek Harness 写入目标", ok: false)
            return
        }
        guard !isBusy else { return }
        isBusy = true
        busyLabel = "解析并测试中…"
        setStatus("解析并测试中…", ok: true)
        defer {
            isBusy = false
            busyLabel = ""
        }
        do {
            let outcome = try await Task.detached(priority: .userInitiated) { () throws -> AddOutcome in
                try Core.shared.add(
                    raw: raw,
                    ccOverride: Prefs.shared.useCC,
                    grokOverride: Prefs.shared.useGrok,
                    cpaOverride: Prefs.shared.useCPA,
                    dshOverride: Prefs.shared.useDSH
                ) { options in
                    self.pickModelsSync(options)
                }
            }.value
            input = ""
            highlightID = nil
            setStatus(outcome.lines.joined(separator: "\n"), ok: outcome.ok)
            historyVersion += 1
            notify(summary: outcome.ok ? "KeyDrop 添加成功" : "KeyDrop 部分失败",
                   body: outcome.lines.joined(separator: "\n"))
        } catch {
            let msg = error.localizedDescription
            AppLog.error("导入失败: \(msg) | 原文: \(raw)")
            if case ParseError.duplicate(let id, _) = error {
                highlightID = id
                highlightPulse += 1
                setStatus("失败: \(msg)", ok: false)
            } else if msg.contains("已取消") {
                setStatus("已取消", ok: true)
            } else {
                setStatus("失败: \(msg)", ok: false)
            }
        }
    }

    private func pickModelsSync(_ options: [String]) -> [String] {
        let sem = DispatchSemaphore(value: 0)
        var result: [String] = []
        DispatchQueue.main.async {
            self.modelPickerResolved = false
            self.modelPickerOptions = options
            // 单选项(如解析到的模型验证失败回退)自动预选,用户只需确认
            self.modelPickerPreselected = options.count == 1 ? Set(options) : []
            self.modelPickerResult = { picked in
                guard !self.modelPickerResolved else { return }
                self.modelPickerResolved = true
                result = picked
                self.modelPickerShown = false
                self.modelPickerResult = nil
                sem.signal()
            }
            self.modelPickerShown = true
        }
        if sem.wait(timeout: .now() + 120) == .timedOut {
            // 120s:模型选择器没有用户响应时尽快放弃,
            // 避免后台线程和信号量被长时间占用(原先 300s 太久)
            DispatchQueue.main.async {
                guard !self.modelPickerResolved else { return }
                self.modelPickerResolved = true
                self.modelPickerShown = false
                self.modelPickerResult = nil
            }
            return []
        }
        return result
    }

    func confirmModelPicker(_ picked: [String]) {
        modelPickerResult?(picked)
    }

    func cancelModelPicker() {
        modelPickerResult?([])
    }

    /// Sheet 手势关闭时确保释放等待中的信号量
    func handleModelPickerDismiss() {
        if !modelPickerResolved, modelPickerResult != nil {
            cancelModelPicker()
        }
    }

    func handleClashPreviewDismiss() {
        if clashPreviewShown == false {
            clashPreviewProxies = []
        }
    }

    func doDelete(_ id: String) {
        guard !isBusy else { return }
        isBusy = true
        busyLabel = "删除中…"
        Task { @MainActor in
            defer {
                isBusy = false
                busyLabel = ""
            }
            do {
                let msg = try await Task.detached(priority: .userInitiated) {
                    try Core.shared.delete(entryIDPrefix: id)
                }.value
                setStatus(msg, ok: true)
                historyVersion += 1
                highlightID = nil
            } catch {
                setStatus("删除失败: \(error.localizedDescription)", ok: false)
                historyVersion += 1
                highlightID = nil
            }
        }
    }

    func doAddClashProxies() {
        let proxies = clashPreviewProxies
        clashPreviewShown = false
        clashPreviewProxies = []
        guard !proxies.isEmpty else {
            setStatus("没有可导入的节点", ok: false)
            return
        }
        let valid = proxies.filter { !$0.server.isEmpty && $0.port > 0 && !$0.uuid.isEmpty }
        guard !valid.isEmpty else {
            setStatus("节点无效(缺少 server/port/uuid)", ok: false)
            return
        }
        isBusy = true
        busyLabel = "导入 Clash…"
        Task { @MainActor in
            defer {
                isBusy = false
                busyLabel = ""
            }
            do {
                let r = try await Task.detached(priority: .userInitiated) {
                    let r = try Core.addClashProxies(valid)
                    let entry = HistoryEntry(
                        id: UUID().uuidString.lowercased(),
                        ts: Date().timeIntervalSince1970,
                        raw: valid.map { $0.name }.joined(separator: "\n"),
                        format: "clash",
                        name: nil,
                        url: nil,
                        model: nil,
                        key: nil,
                        keyMasked: "\(valid.count) 个节点",
                        targets: ["clash"],
                        ccProviderID: nil, ccRenamedFrom: nil, ccRenamedTo: nil,
                        cpaConfigPath: nil, status: "active",
                        clashFile: r.fileName
                    )
                    try Core.shared.history.append(entry)
                    try Core.shared.prefs.save()
                    return r
                }.value
                setStatus(r.message, ok: true)
                historyVersion += 1
            } catch {
                setStatus("Clash 导入失败: \(error.localizedDescription)", ok: false)
            }
        }
    }

    func doRefresh(_ id: String) {
        guard !isBusy else { return }
        refreshingID = id
        isBusy = true
        busyLabel = "重新测试…"
        Task { @MainActor in
            defer {
                refreshingID = nil
                isBusy = false
                busyLabel = ""
            }
            do {
                let msg = try await Task.detached(priority: .userInitiated) { () throws -> String in
                    try Core.shared.refreshModels(entryIDPrefix: id) { options in
                        self.pickModelsSync(options)
                    }
                }.value
                setStatus(msg, ok: true)
                historyVersion += 1
                notify(summary: "KeyDrop 刷新完成", body: msg)
            } catch {
                let msg = error.localizedDescription
                if msg.contains("已取消") {
                    setStatus("已取消", ok: true)
                } else {
                    setStatus("刷新失败: \(msg)", ok: false)
                }
            }
        }
    }

    func openCPAAPI() {
        cpaAPIKeyInput = Prefs.shared.cpaManagementKey ?? ""
        cpaAPIBaseInput = Prefs.shared.cpaAPIBase ?? ""
        cpaAPIStatus = CPAAPI.apiMode ? "当前:API 模式(不触碰 CPA 数据目录文件)" : "当前:文件直写模式"
        cpaAPIOk = CPAAPI.apiMode
        cpaAPISheetShown = true
    }
    func saveCPAAPI() {
        let key = cpaAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cpaAPIBaseInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            cpaAPIStatus = "密钥为空:留空并点「清除」可回到文件模式"; cpaAPIOk = false
            return
        }
        busyLabel = "测试 CPA 管理 API…"
        let prevKey = Prefs.shared.cpaManagementKey
        let prevBase = Prefs.shared.cpaAPIBase
        Task { @MainActor in
            defer { busyLabel = "" }
            let ok: Bool = await Task.detached(priority: .userInitiated) { () -> Bool in
                Prefs.shared.cpaManagementKey = key
                Prefs.shared.cpaAPIBase = base.isEmpty ? nil : base
                guard let (_, data) = try? CPAAPI.request("GET", "v0/management/config.yaml") else { return false }
                return data.count > 0
            }.value
            cpaAPIOk = ok
            if ok {
                // 真实事故(2026-09-22):此前漏调 Prefs.save(),密钥只存在内存,
                // prefs.json 无记录,重启即丢——用户保存成功后查文件发现没有。
                try? Prefs.shared.save()
                // 成功即关窗:设置已持久化,下次打开此面板可再次查看状态
                cpaAPISheetShown = false
            } else {
                // 测试失败不落盘,并回滚内存值,避免半生效状态
                Prefs.shared.cpaManagementKey = prevKey
                Prefs.shared.cpaAPIBase = prevBase
                cpaAPIStatus = "连接失败:检查 CPA 是否运行、密钥是否为管理面板口令"
            }
        }
    }
    func clearCPAAPI() {
        Prefs.shared.cpaManagementKey = nil
        Prefs.shared.cpaAPIBase = nil
        try? Prefs.shared.save()   // 清除同样必须落盘,否则重启后旧密钥“复活”
        cpaAPIKeyInput = ""
        cpaAPIBaseInput = ""
        cpaAPIOk = false
        cpaAPIStatus = "已清除:回到文件直写模式"
    }

    func doActivateCPA(_ id: String) {
        guard !isBusy else { return }
        isBusy = true
        busyLabel = "激活 CPA…"
        Task { @MainActor in
            defer {
                isBusy = false
                busyLabel = ""
            }
            do {
                let msg = try await Task.detached(priority: .userInitiated) { () throws -> String in
                    try Core.shared.activateCPA(entryIDPrefix: id)
                }.value
                setStatus(msg, ok: true)
                historyVersion += 1
                notify(summary: "CPA 已激活", body: msg)
            } catch {
                setStatus("CPA 激活失败: \(error.localizedDescription)", ok: false)
            }
        }
    }

    func doReimport(_ id: String) {
        guard !isBusy else { return }
        isBusy = true
        busyLabel = "重新导入…"
        Task { @MainActor in
            defer {
                isBusy = false
                busyLabel = ""
            }
            do {
                let msg = try await Task.detached(priority: .userInitiated) { () throws -> String in
                    try Core.shared.reimportToCC(entryIDPrefix: id)
                }.value
                setStatus(msg, ok: true)
                historyVersion += 1
                notify(summary: "已重新导入", body: msg)
            } catch {
                setStatus("重新导入失败: \(error.localizedDescription)", ok: false)
                historyVersion += 1
            }
        }
    }

    func showEdit(_ entry: HistoryEntry) {
        editTarget = entry
        editModelsText = (entry.models ?? (entry.model.map { [$0] } ?? [])).joined(separator: ", ")
        editNameText = entry.name ?? ""
        editShown = true
    }

    func doEdit() {
        guard let entry = editTarget else { return }
        guard !isBusy else { return }
        let models = editModelsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let name = editNameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !models.isEmpty || !name.isEmpty else {
            setStatus("模型或名称至少填一项", ok: false)
            return
        }
        editShown = false
        isBusy = true
        busyLabel = "保存编辑…"
        Task { @MainActor in
            defer {
                isBusy = false
                busyLabel = ""
            }
            do {
                let msg = try await Task.detached(priority: .userInitiated) { () throws -> String in
                    try Core.shared.editEntry(
                        entryIDPrefix: entry.id,
                        models: models.isEmpty ? nil : models,
                        name: name.isEmpty ? nil : name
                    )
                }.value
                setStatus(msg, ok: true)
                historyVersion += 1
                notify(summary: "已保存编辑", body: msg)
            } catch {
                setStatus("编辑失败: \(error.localizedDescription)", ok: false)
                historyVersion += 1
            }
        }
    }

    func doLaunchApp(entryID: String, cmd: String) {
        guard !isBusy else { return }
        let entry = core.history.find(idPrefix: entryID)
        let needsActivate = entry?.targets.contains("cpa") == true
            && entry?.targets.contains(where: { $0.hasPrefix("ccswitch") }) != true
            && entry?.targets.contains("grok") != true

        if needsActivate {
            isBusy = true
            busyLabel = "激活并打开…"
            Task { @MainActor in
                defer {
                    isBusy = false
                    busyLabel = ""
                }
                do {
                    let msg = try await Task.detached(priority: .userInitiated) {
                        try Core.shared.activateCPA(entryIDPrefix: entryID)
                    }.value
                    setStatus(msg, ok: true)
                    historyVersion += 1
                    Self.openTerminal(cmd)
                } catch {
                    setStatus("CPA 激活失败: \(error.localizedDescription)", ok: false)
                }
            }
        } else {
            Self.openTerminal(cmd)
        }
    }

    static func openTerminal(_ cmd: String) {
        // 白名单校验:命令经 osascript 拼接写入终端 shell,一旦未来把用户数据
        // (条目名/URL 等)拼进 cmd 就是注入漏洞。此处只允许三种启动目标。
        guard ["opencode", "codex", "claude", "grok"].contains(cmd) else {
            AppLog.error("openTerminal 拒绝非白名单命令: \(cmd)")
            return
        }
        let escaped = cmd
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        DispatchQueue.global(qos: .userInitiated).async {
            let iTermScript = """
            tell application "System Events"
                if (name of processes) contains "iTerm2" or (name of processes) contains "iTerm" then
                    tell application "iTerm"
                        activate
                        if (count of windows) = 0 then
                            create window with default profile
                        end if
                        tell current window
                            create tab with default profile
                            tell current session
                                write text "\(escaped)"
                            end tell
                        end tell
                    end tell
                    return "ok"
                end if
            end tell
            return "fallback"
            """
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", iTermScript]
            let pipe = Pipe()
            proc.standardOutput = pipe
            do {
                try proc.run()
                proc.waitUntilExit()
                let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if out == "ok" { return }
            } catch {}

            let termScript = """
            tell application "Terminal"
                activate
                do script "\(escaped)"
            end tell
            """
            let fallback = Process()
            fallback.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            fallback.arguments = ["-e", termScript]
            try? fallback.run()
        }
    }

    /// 节流 + 互斥:面板每次重新显示 onAppear 都会调这里,
    // 若不节流,用户每切一次面板就对全部 key 发一轮真实测试请求(白烧额度);
    // 若不互斥,多份扫描并发执行会互相覆盖 status、反复刷新整表
    private var lastHealthScanAt: Date?
    private var healthScanRunning = false
    /// 上次提醒过的未绑定账号数:数量不变就不重复记日志,变了(新增/绑完)才再提醒
    static var lastLoggedUnboundCount: Int = -1
    func scanHealth() {
        if let last = lastHealthScanAt, Date().timeIntervalSince(last) < 600 { return }
        guard !healthScanRunning else { return }
        healthScanRunning = true
        lastHealthScanAt = Date()
        Task.detached(priority: .userInitiated) { [weak self] in
            // OAuth 账号代理绑定提醒:只数数 + 落日志,绝不自动改 auth 文件
            // (批量写另一个应用的凭证必须显式触发;粘性设计保证手动重跑永远安全)。
            // 放在 UI 层巡检而非 Core.scanHealth:测试套件跑得到 Core,碰不到 AppState,
            // 免得测试环境经 docker inspect 触到开发者真实 auth-dir
            if let dir = ProxyPool.defaultAuthDir() {
                let unbound = ProxyPool.unboundAccounts(authDir: dir).count
                if unbound > 0 && unbound != Self.lastLoggedUnboundCount {
                    Self.lastLoggedUnboundCount = unbound
                    AppLog.info("CPA: \(unbound) 个 OAuth 账号未绑定独立代理,运行 KeyDrop proxy-pool 一键粘性绑定(默认读 ~/.keydrop/proxy-pool.txt)")
                }
            }
            Core.shared.scanHealth { msgs in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.healthScanRunning = false
                    self.historyVersion += 1
                    if !msgs.isEmpty {
                        // 扫描消息不再弹 statusText 横幅(用户确认:每 10 分钟弹一次纯打扰,
                        // 条目级变化由圆点/分区/行内监控格条承载)—— 落日志即可
                        AppLog.info("健康扫描: " + msgs.joined(separator: "; "))
                    }
                }
            }
        }
    }

    func startHealthTimer() {
        guard healthTimer == nil else { return }
        healthTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.scanHealth()
        }
    }

    func clearDead() {
        // proxy-ok 是「直连不可用但经代理可用」,不是失效,绝不能被一键清除误删
        let ids = core.history.snapshot()
            .filter { $0.status == "active" && ($0.health == "dead" || $0.health == "err") }
            .map { $0.id }
        guard !ids.isEmpty, !isBusy else { return }
        isBusy = true
        busyLabel = "清除失效 \(ids.count) 条…"
        Task { @MainActor in
            defer {
                isBusy = false
                busyLabel = ""
            }
            var failed: [String] = []
            for id in ids {
                do {
                    let msg = try await Task.detached(priority: .userInitiated) {
                        try Core.shared.delete(entryIDPrefix: id)
                    }.value
                    AppLog.info("清除失效: \(msg)")
                } catch {
                    failed.append("\(id.prefix(8)) \(error.localizedDescription)")
                }
            }
            historyVersion += 1
            if failed.isEmpty {
                setStatus("已清除 \(ids.count) 条失效 key", ok: true)
            } else {
                setStatus("清除完成,\(failed.count) 条失败: \(failed.prefix(3).joined(separator: "; "))", ok: false)
            }
        }
    }

    func setStatus(_ s: String, ok: Bool) {
        if ok { AppLog.info(s) } else { AppLog.error(s) }
        statusText = s
        statusOK = ok
        statusClearTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            self?.statusText = ""
        }
        statusClearTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: task)
    }

    func toggleUseCC() {
        useCC.toggle()
        prefs.useCC = useCC
        try? prefs.save()
    }

    func toggleUseGrok() {
        useGrok.toggle()
        prefs.useGrok = useGrok
        try? prefs.save()
    }

    func toggleUseCPA() {
        useCPA.toggle()
        prefs.useCPA = useCPA
        try? prefs.save()
    }

    func toggleUseDSH() {
        useDSH.toggle()
        prefs.useDSH = useDSH
        try? prefs.save()
    }

    func setProxy(_ v: String) {
        // 输入过程只更新显示文本;持久化的是规范化值,保证半截输入不落盘
        proxyText = v
        prefs.proxy = Core.normalizeProxyInput(v)
        try? prefs.save()
    }

    /// 提交(回车/失焦)时把显示也规范化成完整 URL,所见即所存
    func commitProxy() {
        let normalized = Core.normalizeProxyInput(proxyText)
        proxyText = normalized
        prefs.proxy = normalized
        try? prefs.save()
    }

    private var prefs: Prefs { Prefs.shared }

    func notify(summary: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = summary
            content.body = String(body.prefix(800))
            let req = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            center.add(req)
        }
    }
}

// MARK: - History row

struct HistoryRow: View {
    /// 单模型监控格条:该模型的采集轨迹;未采集显示浅灰待采格。
    /// 两种状态都用固定格宽 → 总宽恒定,不随模型名长短/记录数变化(用户反馈:有的宽有的窄)
    @ViewBuilder
    private func modelSparkline(_ m: String) -> some View {
        let log = entry.modelProbeLog?[m] ?? []
        if log.isEmpty {
            MonitorSparkline(log: log, slots: 14, height: 14, cellWidth: 6)
                .help("该模型尚未被探测(每轮只测 4 个:激活模型置顶,其余按「从未测过→最久未测」轮换,几轮内全覆盖);灰=无证据,≠不可用")
        } else {
            let okc = log.filter { $0.ok }.count
            let up = Int((Double(okc) / Double(log.count) * 100).rounded())
            MonitorSparkline(log: log, slots: 14, height: 14, cellWidth: 6)
                .help("绿=通过<3s · 黄=通过3-8s · 紫=通过≥8s(慢) · 红=失败;悬停单格看当次详情")
            Text("\(up)%")
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(up >= 95
                    ? Color(red: 0.22, green: 0.58, blue: 0.40)
                    : (up >= 80 ? Color.orange : Color.red))
                .frame(width: 34, alignment: .trailing)
                .help("该模型 uptime:探测中通过的占比(只数通过,不管快慢 —— 全黄/全紫也是 100%)")
        }
    }

    /// 实战监控徽章:探测延迟 / CPA 链路状态 / 最近验证时间。
    /// 拆成独立方法:内联在主行时表达式过复杂,SwiftUI 类型检查超时
    @ViewBuilder
    private func monitorBadges(_ entry: HistoryEntry) -> some View {
        if let ms = entry.latencyMs, entry.health == "ok" || entry.health == "proxy-ok" {
            Text("·")
            Text(String(format: "%.1fs", ms / 1000))
                .foregroundStyle(ms > 8000
                    ? Color(red: 0.85, green: 0.55, blue: 0.15)
                    : Color.secondary.opacity(0.9))
                .help("最近一次探测延迟。越低体感越快;超过 8s 标黄提醒")
        }
        if let ok = entry.viaCPAOk, entry.targets.contains("cpa") {
            Text("·")
            Text(ok ? "CPA ✓" : "CPA ⚠")
                .foregroundStyle(ok
                    ? Color(red: 0.22, green: 0.58, blue: 0.40)
                    : Color(red: 0.85, green: 0.55, blue: 0.15))
                .help(ok
                    ? "CPA 链路探测通过(经 127.0.0.1:8317,实际请求走的路径)"
                    : "上游可用但经 CPA 调不通:检查 CPA 配置/容器/模型路由(↻ 重测可复验)")
        }
        if let at = entry.healthAt {
            Text("·")
            Text(Self.healthAgeStr(at))
                .help("最近一次健康验证时间;扫描周期 30 分钟(仅测超期条目)")
        }
    }

    /// 健康验证距今的人类可读时长(监控:让"可用"带着新鲜度)
    static func healthAgeStr(_ at: TimeInterval) -> String {
        let mins = Int((Date().timeIntervalSince1970 - at) / 60)
        if mins < 1 { return "刚刚验证" }
        if mins < 60 { return "\(mins) 分钟前验证" }
        let hrs = mins / 60
        if hrs < 24 { return "\(hrs) 小时前验证" }
        return "\(hrs / 24) 天前验证"
    }

    let entry: HistoryEntry
    let refreshing: Bool
    let busy: Bool
    let onDelete: () -> Void
    let onCopy: (String) -> Void
    let onCopyId: (String) -> Void
    let onRefresh: (String) -> Void
    let onLaunchApp: (String, String) -> Void
    let onCopyCurl: () -> Void
    let onReimport: () -> Void
    let onEdit: () -> Void
    let highlighted: Bool
    @State private var showDeleteConfirm = false
    @State private var hovered = false
    @State private var flashOpacity: Double = 1

    private var appLaunch: (cmd: String, icon: String, color: Color)? {
        if entry.targets.contains("grok") { return ("grok", "sparkles", Color(red: 0.35, green: 0.45, blue: 0.85)) }
        if entry.targets.contains("ccswitch-opencode") { return ("opencode", "chevron.left.forwardslash.chevron.right", Color(red: 0.25, green: 0.48, blue: 0.85)) }
        if entry.targets.contains("ccswitch-codex") { return ("codex", "c.circle.fill", Color(red: 0.22, green: 0.62, blue: 0.40)) }
        if entry.targets.contains("ccswitch") { return ("claude", "star.fill", Color(red: 0.85, green: 0.48, blue: 0.18)) }
        if entry.targets.contains("cpa") {
            let models = entry.models ?? (entry.model.map { [$0] } ?? [])
            // 空模型列表(未探测/探测失败的多 key 条目)不得默认 claude:
            // CPA 聚合的中转 key 大多是通用 chat 模型,误标 claude 会把
            // 「打开应用」激活到 Claude Code(真实事故:nvapi 批量导入被显示为 claude)
            let appType = Core.routeAppType(selectedModels: models, modelsOverride: nil, default: "opencode")
            switch appType {
            case "claude": return ("claude", "star.fill", Color(red: 0.85, green: 0.48, blue: 0.18))
            case "codex": return ("codex", "c.circle.fill", Color(red: 0.22, green: 0.62, blue: 0.40))
            default: return ("opencode", "chevron.left.forwardslash.chevron.right", Color(red: 0.25, green: 0.48, blue: 0.85))
            }
        }
        return nil
    }

    var body: some View {
        let displayModels = entry.models ?? (entry.model.map { [$0] })
        let testable = entry.status == "active" && entry.key != nil && entry.url != nil
        let dotColor: Color = {
            if entry.status != "active" { return Color.secondary.opacity(0.6) }
            switch entry.health {
            case "dead": return Color(red: 0.86, green: 0.28, blue: 0.24)
            case "err": return Color(red: 0.90, green: 0.55, blue: 0.18)
            case "proxy-ok": return Color(red: 0.93, green: 0.68, blue: 0.20)
            default: return Color(red: 0.28, green: 0.68, blue: 0.42)
            }
        }()
        let dotTip: String = {
            switch entry.health {
            case "ok": return "可用 · 最近测试通过"
            case "quota": return "无余额 · 充值后刷新恢复"
            case "dead": return "key 已失效 · 建议删除"
            case "err": return "测试异常 · 点 ↻ 重测"
            case "proxy-ok": return "需代理 · 直连不可用,经代理可用"
            default: return "尚未测试"
            }
        }()

        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.id, forType: .string)
                    onCopyId(entry.id)
                } label: {
                    Text(entry.id.prefix(8))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("点击复制完整 ID")
                .frame(minWidth: 54, alignment: .leading)

                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
                    .padding(.top, 4)
                    .help(dotTip)

                // key 活着但用户配置的模型全被限流 → 已挬入无额度区,行内标注区别于真死 key
                if entry.allConfiguredModelsLimited,
                   entry.health == "ok" || entry.health == "proxy-ok" {
                    Text("所选模型均限流 · key 本身可用")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Color(red: 0.85, green: 0.55, blue: 0.15))
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color(red: 0.85, green: 0.55, blue: 0.15).opacity(0.13)))
                        .help("网关上其它模型能通所以 key 级判 ok,但你配置的模型最新探测全部失败;换选其它模型或等限流恢复")
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.summary)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 6) {
                        Text(entry.timeStr)
                        Text("·")
                        Text(entry.format)
                        Text("·")
                        Text(entry.keyMasked)
                        monitorBadges(entry)
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                    if let displayModels, !displayModels.isEmpty {
                        // 每个模型一行:模型名(点击复制)+ 右侧该模型的监控格条
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(displayModels, id: \.self) { m in
                                HStack(spacing: 8) {
                                    Button {
                                        onCopy(m)
                                    } label: {
                                        HStack(spacing: 3) {
                                            Image(systemName: "doc.on.doc")
                                                .font(.system(size: 10))
                                                .foregroundStyle(.secondary)
                                            Text(CCSwitchWriter.copyModelName(for: entry, model: m))
                                                .font(.system(size: 11, design: .monospaced))
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        }
                                    }
                                    .buttonStyle(.borderless)
                                    .foregroundStyle(Color(red: 0.22, green: 0.58, blue: 0.40))
                                    .help("点击复制，去 \(appLaunch?.cmd ?? "AI 客户端") /model 粘贴即可唯一定位")
                                    Spacer(minLength: 4)
                                    modelSparkline(m)
                                }
                            }
                        }
                        .padding(.top, 1)
                    }
                    // key 级格条不再上行:当前死活由圆点+分区表达,时间轴历史(何时死/挂几次/
                    // 延迟趋势)在「监控」弹窗的趋势图与事件记录里完整保留。监控系统本身
                    // (scanHealth)不受影响 —— 它是把 key 分进无额度/待删除区的机制,
                    // 也是充值后自动复活的检测器
                }

                Spacer(minLength: 4)

                if entry.status == "active" {
                    HStack(spacing: 10) {
                        if testable {
                            Button {
                                onCopyCurl()
                            } label: {
                                Image(systemName: "terminal")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Color(red: 0.35, green: 0.40, blue: 0.48))
                            }
                            .buttonStyle(.borderless)
                            .disabled(busy)
                            .help("复制可运行的 curl 请求")

                            Button {
                                onRefresh(entry.id)
                            } label: {
                                if refreshing {
                                    ProgressView()
                                        .controlSize(.small)
                                        .frame(width: 14, height: 14)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(Color(red: 0.28, green: 0.48, blue: 0.82))
                                }
                            }
                            .buttonStyle(.borderless)
                            .disabled(refreshing || busy)
                            .help(refreshing ? "测试中…" : "重新测试并更新模型列表")
                        }
                        if let app = appLaunch {
                            Button {
                                onLaunchApp(entry.id, app.cmd)
                            } label: {
                                Image(systemName: app.icon)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(app.color)
                            }
                            .buttonStyle(.borderless)
                            .disabled(busy)
                            .help(
                                entry.targets.contains("cpa") && !entry.targets.contains(where: { $0.hasPrefix("ccswitch") })
                                ? "写入 cc-switch 并打开 \(app.cmd)"
                                : "打开 \(app.cmd)"
                            )
                        }
                        Button {
                            onEdit()
                        } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color(red: 0.55, green: 0.55, blue: 0.62))
                        }
                        .buttonStyle(.borderless)
                        .disabled(busy)
                        .help("编辑模型 / 名称")
                        Button {
                            showDeleteConfirm = true
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 12))
                                .foregroundStyle(Color(red: 0.78, green: 0.28, blue: 0.24).opacity(0.85))
                        }
                        .buttonStyle(.borderless)
                        .disabled(busy)
                        .help("删除")
                        .confirmationDialog(
                            "确认删除?",
                            isPresented: $showDeleteConfirm,
                            titleVisibility: .visible
                        ) {
                            Button("删除", role: .destructive) { onDelete() }
                            Button("取消", role: .cancel) {}
                        } message: {
                            Text("将删除: \(entry.summary)\n此操作会从 cc-switch / CPA 移除该配置。")
                        }
                        if entry.ccMissing == true {
                            Button {
                                onReimport()
                            } label: {
                                Image(systemName: "arrow.uturn.backward.circle")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Color(red: 0.85, green: 0.55, blue: 0.15))
                            }
                            .buttonStyle(.borderless)
                            .disabled(busy)
                            .help("重新导入 cc-switch(provider 缺失但 key 可用)")
                        }
                    }
                } else {
                    Text("已删")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .opacity(highlighted ? flashOpacity : 1)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(highlighted
                      ? Color(red: 0.78, green: 0.28, blue: 0.24).opacity(0.12)
                      : (hovered ? Color.primary.opacity(0.04) : Color.clear))
                .overlay(
                    highlighted
                        ? RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color(red: 0.78, green: 0.28, blue: 0.24).opacity(0.5), lineWidth: 1)
                        : nil
                )
        )
        .animation(.easeOut(duration: 0.6), value: highlighted)
        .onChange(of: highlighted) { _, on in
            guard on else {
                flashOpacity = 1
                return
            }
            flashOpacity = 0.3
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.32).repeatCount(5, autoreverses: true)) {
                    flashOpacity = 1
                }
            }
        }
        .onHover { hovered = $0 }
        .contentShape(Rectangle())
    }
}

// MARK: - Model picker

struct ModelPickerView: View {
    @ObservedObject var state: AppState
    @State private var query = ""
    @State private var selected: Set<String> = []
    @State private var allOptions: [String] = []
    @State private var customInput = ""

    var filtered: [String] {
        guard !query.isEmpty else { return allOptions }
        let q = query.lowercased()
        let contains = allOptions.filter { $0.lowercased().contains(q) }
        let starts = contains.filter { $0.lowercased().hasPrefix(q) }
        return starts + contains.filter { !starts.contains($0) }
    }

    private var customModels: [String] {
        customInput
            .split { $0 == "," || $0 == "，" || $0 == "\n" }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(allOptions.isEmpty
                 ? "未检测到模型列表，手动输入模型名"
                 : "选择要导入的模型")
                .font(.system(size: 14, weight: .semibold))
            Text(allOptions.isEmpty
                 ? "多个模型用逗号或换行分隔"
                 : "可多选；导入后去 opencode /model 切换")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            if allOptions.isEmpty {
                TextField("例如: doubao-1-5-pro-32k-250115", text: $customInput, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(3...6)
            } else {
                TextField("过滤模型…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filtered, id: \.self) { m in
                            Toggle(isOn: Binding(
                                get: { selected.contains(m) },
                                set: { on in
                                    if on { selected.insert(m) } else { selected.remove(m) }
                                }
                            )) {
                                Text(m)
                                    .font(.system(size: 11, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .toggleStyle(.checkbox)
                            .padding(.vertical, 3)
                            Divider().opacity(0.25)
                        }
                    }
                }
                .frame(minHeight: 180, maxHeight: 300)
            }

            HStack(spacing: 8) {
                if !allOptions.isEmpty {
                    Button("全选") { selected = Set(filtered) }
                    Button("清空") { selected = [] }
                    Text("已选 \(selected.count) / \(allOptions.count)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else {
                    Text("已输入 \(customModels.count) 个模型")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { state.cancelModelPicker() }
                    .keyboardShortcut(.escape, modifiers: [])
                if allOptions.isEmpty {
                    Button(customModels.isEmpty ? "请输入模型" : "导入 \(customModels.count) 个") {
                        state.confirmModelPicker(customModels)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(customModels.isEmpty)
                    .keyboardShortcut(.return, modifiers: [])
                } else {
                    Button(selected.isEmpty ? "请勾选模型" : "导入 \(selected.count) 个") {
                        // Set 无序:按 allOptions(探测优先级)顺序传出,
                        // 保证 entry.model=第一个勾选是确定的,不随哈希顺序漂移
                        state.confirmModelPicker(allOptions.filter { selected.contains($0) })
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected.isEmpty)
                    .keyboardShortcut(.return, modifiers: [])
                }
            }
        }
        .padding(18)
        .frame(width: 540)
        .onAppear {
            allOptions = state.modelPickerOptions
            selected = state.modelPickerPreselected
        }
    }
}

// MARK: - Clash preview

struct ClashPreviewView: View {
    @ObservedObject var state: AppState

    private var validCount: Int {
        state.clashPreviewProxies.filter { !$0.server.isEmpty && $0.port > 0 }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("检测到 \(state.clashPreviewProxies.count) 个代理节点")
                .font(.system(size: 14, weight: .semibold))
            Text("确认后写入 Clash Party profiles 目录")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(state.clashPreviewProxies.enumerated()), id: \.offset) { _, p in
                        let valid = !p.server.isEmpty && p.port > 0
                        HStack(spacing: 8) {
                            Text(p.type.uppercased())
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.08)))
                            Text(p.name)
                                .font(.system(size: 11))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(valid ? "\(p.server):\(p.port)" : "无效节点")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(valid ? .secondary : Color(red: 0.8, green: 0.3, blue: 0.25))
                        }
                        .padding(.vertical, 5)
                        Divider().opacity(0.25)
                    }
                }
            }
            .frame(minHeight: 160, maxHeight: 300)

            HStack {
                if validCount < state.clashPreviewProxies.count {
                    Text("将跳过 \(state.clashPreviewProxies.count - validCount) 个无效节点")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(red: 0.85, green: 0.45, blue: 0.15))
                }
                Spacer()
                Button("取消") {
                    state.clashPreviewShown = false
                    state.clashPreviewProxies = []
                }
                .keyboardShortcut(.escape, modifiers: [])
                Button("确认导入") { state.doAddClashProxies() }
                    .buttonStyle(.borderedProminent)
                    .disabled(validCount == 0 || state.isBusy)
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(18)
        .frame(width: 520)
    }
}

// MARK: - 帮助

struct HelpView: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("KeyDrop 使用说明")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                Text("v\(Version.currentVersion())")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.14)))
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    section("贴 key 即用", icon: "arrow.down.doc") {
                        item("粘贴内容后点「导入」,自动解析 URL / key / 模型,测试通过后写入开启的通道(cc-switch / CPA 等)")
                        item("支持任意格式:明文 key、API 链接、curl 命令(含 \\ 续行)、订阅地址")
                        item("自动去噪:多余空格、空行、重复 key、平台前缀文案自动清理")
                    }
                    section("双通道写入", icon: "arrow.left.arrow.right") {
                        item("cc-switch:创建 provider 并激活;直写 Claude Code 配置,重开会话生效")
                        item("CPA:写入 Cliproxy API 的 config.yaml,运行时会自动热重载")
                        item("顶栏 cc-switch / CPA 开关控制写入目标,可同时开启")
                    }
                    section("代理", icon: "network") {
                        item("顶栏「代理」框填本地代理,如 http://127.0.0.1:7890")
                        item("写入时同步到 Claude Code 环境变量与 CPA 条目级 proxy-url;留空则清除旧代理")
                        item("Codex 特殊:其配置不支持代理字段。被墙网关导入 codex 后,请在 cc-switch「代理」面板开启 Codex 接管,或启动 codex 前 export HTTPS_PROXY")
                    }
                    section("健康探测与清理", icon: "heart") {
                        item("每小时自动探测全部 key:超时标「异常」,401/403 标「失效」")
                        item("失效/异常的 key 进入「待删除区」,展开后可一键清除全部(同步还原 cc-switch / CPA)")
                        item("单条删除:历史行垃圾桶图标;删除时自动还原被暂存的旧 provider")
                    }
                    section("模型", icon: "brain") {
                        item("粘贴内容含多个模型时,弹窗勾选要导入的模型")
                        item("历史行可复制模型名、复制 curl、重测健康、直接启动对应应用")
                    }
                    section("Clash 订阅", icon: "bolt") {
                        item("粘贴 Clash 订阅链接或节点列表,自动写入 Clash Party profiles 目录")
                    }
                    section("其他", icon: "info.circle") {
                        item("快捷键:⌘⏎ 快速导入")
                        item("状态栏显示导入/测试结果;失败时日志在 ~/Library/Logs/KeyDrop/keydrop.log")
                        item("命令行:KeyDrop --help 查看 CLI 用法(适合脚本/批量导入)")
                    }
                }
            }
        }
        .padding(18)
        .frame(width: 440, height: 480)
    }

    private func section(_ title: String, icon: String, @ViewBuilder body: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.primary)
            body()
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.04)))
    }

    private func item(_ text: String) -> some View {
        Text("· \(text)")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Edit sheet

struct EditView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("编辑条目")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button {
                    state.editShown = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
            if let entry = state.editTarget {
                Text("\(entry.id.prefix(8)) · \(entry.summary)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                TextField("模型(逗号分隔)", text: $state.editModelsText)
                    .font(.system(size: 12, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .help("留空则不改动模型;填写后逐一自动验证(大小写敏感)")
                TextField("名称(可选)", text: $state.editNameText)
                    .font(.system(size: 12))
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Text("保存后将自动重新验证并同步 cc-switch / dsh")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("取消") {
                        state.editShown = false
                    }
                    .buttonStyle(.bordered)
                    Button("保存") {
                        state.doEdit()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

// MARK: - Main panel

struct PanelView: View {
    @ObservedObject var state: AppState
    @State private var showStatusDetail = false
    @State private var showDeadArea = false
    @State private var showQuotaArea = false
    @State private var searchText = ""
    @State private var toastText: String?
    @State private var dropTargeted = false
    @FocusState private var inputFocused: Bool
    @FocusState private var proxyFieldFocused: Bool

    private func showToast(_ s: String) {
        withAnimation(.easeOut(duration: 0.15)) { toastText = s }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(.easeIn(duration: 0.2)) { toastText = nil }
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        if !state.statusText.isEmpty {
            let ok = state.statusOK
            let accent = ok
                ? Color(red: 0.22, green: 0.58, blue: 0.40)
                : Color(red: 0.78, green: 0.28, blue: 0.24)

            if !showStatusDetail {
                HStack(spacing: 8) {
                    Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(accent)
                        .font(.system(size: 14))
                    Text(state.statusText.components(separatedBy: "\n").first ?? state.statusText)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    let hasDetail = state.statusText.contains("\n") || state.statusText.count > 80
                    if hasDetail {
                        Button("详情") { showStatusDetail = true }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(accent.opacity(0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(accent.opacity(0.28), lineWidth: 1)
                        )
                )
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ScrollView {
                        Text(state.statusText)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 160)
                    Button("收起") { showStatusDetail = false }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(accent.opacity(0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(accent.opacity(0.28), lineWidth: 1)
                        )
                )
            }
        }
    }

    /// 搜索过滤:模型名 / 条目名 / URL / key 掩码,大小写不敏感,多词 AND
    private func matches(_ e: HistoryEntry) -> Bool {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        let hay = ([e.name, e.url, e.keyMasked, e.model] + (e.models ?? []))
            .compactMap { $0 }.joined(separator: " ").lowercased()
        return q.lowercased().split(separator: " ").allSatisfy { hay.contains($0) }
    }

    private var historyItems: [HistoryEntry] {
        _ = state.historyVersion
        return state.core.history.snapshot()
            .filter { $0.status == "active" && $0.health != "dead" && $0.health != "err" && $0.health != "quota"
                     && !$0.allConfiguredModelsLimited }   // 配置的模型全红(key 还活着)→ 无额度区
            .filter(matches)
            .sorted { $0.ts > $1.ts }
            .prefix(60)
            .map { $0 }
    }

    private var quotaItems: [HistoryEntry] {
        _ = state.historyVersion
        return state.core.history.snapshot()
            .filter { $0.status == "active" && ($0.health == "quota" || $0.allConfiguredModelsLimited) }
            .filter(matches)
            .sorted { $0.ts > $1.ts }
            .prefix(60)
            .map { $0 }
    }

    private var deadItems: [HistoryEntry] {
        _ = state.historyVersion
        return state.core.history.snapshot()
            .filter { $0.status == "active" && ($0.health == "dead" || $0.health == "err") }
            .filter(matches)
            .sorted { $0.ts > $1.ts }
            .prefix(60)
            .map { $0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.35)
            VStack(spacing: 12) {
                inputBlock
                actionRow
                statusArea
                historyBlock
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 600, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            DispatchQueue.main.async { inputFocused = true }
            state.scanHealth()
            state.startHealthTimer()
        }
        .onChange(of: state.statusText) { _, newValue in
            if newValue.isEmpty { showStatusDetail = false }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
        }
        .sheet(isPresented: $state.modelPickerShown, onDismiss: {
            state.handleModelPickerDismiss()
        }) {
            ModelPickerView(state: state)
        }
        .sheet(isPresented: $state.clashPreviewShown, onDismiss: {
            state.handleClashPreviewDismiss()
        }) {
            ClashPreviewView(state: state)
        }
        .sheet(isPresented: $state.helpShown) {
            HelpView(state: state)
        }
        .sheet(isPresented: $state.cpaAPISheetShown) {
            CPAAPISheet(state: state)
        }
        .sheet(isPresented: $state.updateSheetShown) {
            UpdateSheet(state: state)
        }
        .sheet(isPresented: $state.editShown) {
            EditView(state: state)
        }
        .overlay(alignment: .top) {
            if let toastText {
                Text(toastText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        Capsule().fill(Color(red: 0.12, green: 0.13, blue: 0.15).opacity(0.92))
                    )
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    private var header: some View {
        // 两行结构:第一行「身份 + 轻工具」,第二行「写入目标 + 网络」。
        // 旧版单行塞 8 个控件,高度参差、主次不分(真实反馈:顶部太挤)。
        // 版本号做成胶囊徽章:用户明确要求版本号常驻可见(比 tagline 有信息量)
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                Text("KeyDrop")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .fixedSize()
                Text("v\(Version.currentVersion())")
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.secondary.opacity(0.13)))
                Spacer()
                Button {
                    state.helpShown = true
                } label: {
                    Text("?")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("使用说明")
            }
            HStack(spacing: 6) {
                targetChip("cc-switch", on: state.useCC, color: Color(red: 0.22, green: 0.58, blue: 0.40)) {
                    state.toggleUseCC()
                }
                targetChip("Grok", on: state.useGrok, color: Color(red: 0.35, green: 0.45, blue: 0.85)) {
                    state.toggleUseGrok()
                }
                // CPA 芯片:主体点击=开关;齿轮内嵌框内,独立热区=管理 API 配置
                HStack(spacing: 3) {
                    Button {
                        state.toggleUseCPA()
                    } label: {
                        Text("CPA")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(state.useCPA ? Color(red: 0.28, green: 0.48, blue: 0.82) : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    Button {
                        state.openCPAAPI()
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(state.useCPA ? Color(red: 0.28, green: 0.48, blue: 0.82).opacity(0.85) : Color.secondary.opacity(0.85))
                            .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                    .help("CPA 管理 API 配置:密钥化后 KeyDrop 不触碰 CPA 数据目录,根治「文稿」弹窗")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(state.useCPA ? Color(red: 0.28, green: 0.48, blue: 0.82).opacity(0.14) : Color.primary.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(state.useCPA ? Color(red: 0.28, green: 0.48, blue: 0.82).opacity(0.35) : Color.clear, lineWidth: 1)
                )
                targetChip("DSH", on: state.useDSH, color: Color(red: 0.85, green: 0.55, blue: 0.15)) {
                    state.toggleUseDSH()
                }
                Spacer(minLength: 8)
                TextField("代理", text: Binding(
                    get: { state.proxyText },
                    set: { state.setProxy($0) }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 10, design: .monospaced))
                .frame(width: 132)
                .focused($proxyFieldFocused)
                .onSubmit { state.commitProxy() }
                .onChange(of: proxyFieldFocused) { _, focused in
                    if !focused { state.commitProxy() }
                }
                .help("本地代理,如 http://127.0.0.1:7890;留空则自动探测本机代理(直连失败时补测,连通后自动填入此框)")
                updateIndicator
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    /// 软件更新指示器:cc-switch 风格 —— 无更新时不显示任何东西,
    /// 有新版本才亮绿色 ↑(下载中=百分比,就绪=绿色对勾印章)。
    /// 用户确认的口径:「有新版本的时候才显示」;手动检查走菜单栏「检查更新…」
    @ViewBuilder
    private var updateIndicator: some View {
        switch state.updateState {
        case .available(let v, _, _):
            updateIconButton(
                systemName: "arrow.up.circle.fill",
                color: Color(red: 0.22, green: 0.58, blue: 0.40),
                help: "新版本 v\(v) 可更新!点击查看并更新")
        case .downloading(_, let p):
            Button {
                state.updateSheetShown = true
            } label: {
                Text("\(Int(p * 100))%")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color(red: 0.22, green: 0.58, blue: 0.40))
            }
            .buttonStyle(.borderless)
            .help("正在下载更新…点击查看详情")
        case .ready(let v):
            updateIconButton(
                systemName: "checkmark.seal.fill",
                color: Color(red: 0.22, green: 0.58, blue: 0.40),
                help: "v\(v) 已下载就绪,点击重启完成更新")
        case .installing:
            ProgressView().controlSize(.mini)
        default:
            EmptyView()
        }
    }

    private func updateIconButton(systemName: String, color: Color, help: String) -> some View {
        Button {
            state.updateSheetShown = true
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    private func targetChip(_ title: String, on: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(on ? color : Color.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(on ? color.opacity(0.14) : Color.primary.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(on ? color.opacity(0.35) : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.borderless)
        .help(on ? "点击关闭写入 \(title)" : "点击开启写入 \(title)")
    }

    private var inputBlock: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $state.input)
                .font(.system(size: 12.5, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 72, maxHeight: 130)
                .focused($inputFocused)
                .disabled(state.isBusy)
            if state.input.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("粘贴 key / JSON / base64 / curl / 代理链接")
                        .font(.system(size: 12, weight: .medium))
                    Text("也可拖入 zip、配置文件或粘贴路径")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.secondary.opacity(0.85))
                .padding(.top, 16)
                .padding(.leading, 14)
                .allowsHitTesting(false)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.65))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    dropTargeted
                        ? Color(red: 0.28, green: 0.48, blue: 0.82)
                        : Color.primary.opacity(0.12),
                    lineWidth: dropTargeted ? 2 : 1
                )
        )
        .animation(.easeOut(duration: 0.15), value: dropTargeted)
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button {
                state.doAdd()
            } label: {
                HStack(spacing: 6) {
                    if state.isBusy {
                        ProgressView()
                            .controlSize(.small)
                        Text(state.busyLabel.isEmpty ? "处理中…" : state.busyLabel)
                    } else {
                        Text("导入")
                    }
                }
                .frame(minWidth: 110)
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.borderedProminent)
            .disabled(state.isBusy || state.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button("粘贴") {
                state.input = NSPasteboard.general.string(forType: .string) ?? ""
                inputFocused = true
            }
            .disabled(state.isBusy)
            .help("⌘V 粘贴;⌘↩ 导入")
            Spacer()
        }
    }

    private var statusArea: some View {
        Group {
            if state.statusText.isEmpty {
                Color.clear.frame(height: 4)
            } else {
                statusBanner
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: 0.18), value: state.statusText.isEmpty)
        .animation(.easeOut(duration: 0.18), value: showStatusDetail)
    }

    private var historyBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            let sc = state.statusCounts()
            // 横幅只保留「零可用」一种(灰色,真正需要行动的状态)。CPA 链路异常
            // 横幅已移除(用户确认:无用信息纯打扰;签名制收起也挡不住异常集合
            // 每轮变动导致的重复弹出)—— 行内 CPA 徽章 + 行内模型监控格条承载
            if sc.ok + sc.warn == 0 {
                OverallStatusBanner(okCount: sc.ok, warnCount: sc.warn, deadCount: sc.dead, compact: true)
            }
            // 颜色图例常显在主界面(用户确认:不能只靠悬停)—— 模型格条是双维编码
            // (通过与否 × 延迟快慢),不标注的话「全黄/全紫也 100%」看起来像算错
            StatusLegend(showUptimeNote: false)
            Divider().opacity(0.3)
            let items = historyItems
            let deads = deadItems
            let quotas = quotaItems
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    TextField("搜模型/名称/URL,空格分隔多个词", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .disableAutocorrection(true)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("清空搜索")
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.05))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.12), lineWidth: 0.8))
                )
                .frame(width: 230)
                Spacer()
                Text("最近添加")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("\(items.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            let searching = !searchText.trimmingCharacters(in: .whitespaces).isEmpty
            if items.isEmpty && deads.isEmpty && quotas.isEmpty && !searching {
                VStack(spacing: 6) {
                    Image(systemName: "tray")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                    Text("暂无记录")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("粘贴 key 后点「导入」")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
            } else if items.isEmpty && deads.isEmpty && quotas.isEmpty && searching {
                VStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                    Text("无匹配「\(searchText)」的记录")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("试试更短的关键词,或点 ✕ 清空搜索")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(items, id: \.id) { e in
                                HistoryRow(
                                    entry: e,
                                    refreshing: state.refreshingID == e.id,
                                    busy: state.isBusy,
                                    onDelete: { state.doDelete(e.id) },
                                    onCopy: { m in
                                        let copyText = CCSwitchWriter.copyModelName(for: e, model: m)
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(copyText, forType: .string)
                                        showToast("已复制: \(copyText)")
                                    },
                                    onCopyId: { id in
                                        showToast("已复制 ID: \(id.prefix(8))…")
                                    },
                                    onRefresh: { id in state.doRefresh(id) },
                                    onLaunchApp: { id, cmd in state.doLaunchApp(entryID: id, cmd: cmd) },
                                    onCopyCurl: {
                                        guard let url = e.url, let key = e.key, !key.isEmpty else {
                                            showToast("缺少 URL 或 key")
                                            return
                                        }
                                        let model = e.models?.first ?? e.model
                                        let style: String? = {
                                            if e.targets.contains("ccswitch") { return "anthropic" }
                                            if let d = e.healthDetail, d.lowercased().contains("anthropic") { return "anthropic" }
                                            return nil
                                        }()
                                        let curl = APITester.curlCommand(url: url, key: key, model: model, styleHint: style)
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(curl, forType: .string)
                                        showToast("已复制 curl")
                                    },
                                    onReimport: { state.doReimport(e.id) },
                                    onEdit: { state.showEdit(e) },
                                                                        highlighted: state.highlightID == e.id && state.highlightPulse > 0
                                )
                            }
                            if !quotas.isEmpty {
                                Button {
                                    withAnimation(.easeInOut(duration: 0.2)) { showQuotaArea.toggle() }
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: showQuotaArea ? "chevron.down" : "chevron.right")
                                            .font(.system(size: 10, weight: .semibold))
                                        Text("无额度区")
                                            .font(.system(size: 11, weight: .semibold))
                                        Text("\(quotas.count)")
                                            .font(.system(size: 10, design: .monospaced))
                                        Spacer()
                                        Text(showQuotaArea ? "收起" : "无余额/配额耗尽 · 充值后刷新恢复")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(showQuotaArea ? Color.secondary : Color(red: 0.80, green: 0.62, blue: 0.20))
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(Color(red: 0.80, green: 0.62, blue: 0.20).opacity(showQuotaArea ? 0.12 : 0.07))
                                    )
                                }
                                .buttonStyle(.borderless)
                                .padding(.top, 6)
                                if showQuotaArea {
                                    ForEach(quotas, id: \.id) { e in
                                        HistoryRow(
                                            entry: e,
                                            refreshing: state.refreshingID == e.id,
                                            busy: state.isBusy,
                                            onDelete: { state.doDelete(e.id) },
                                            onCopy: { m in
                                                let copyText = CCSwitchWriter.copyModelName(for: e, model: m)
                                                NSPasteboard.general.clearContents()
                                                NSPasteboard.general.setString(copyText, forType: .string)
                                                showToast("已复制: \(copyText)")
                                            },
                                            onCopyId: { id in
                                                showToast("已复制 ID: \(id.prefix(8))…")
                                            },
                                            onRefresh: { id in state.doRefresh(id) },
                                            onLaunchApp: { id, cmd in state.doLaunchApp(entryID: id, cmd: cmd) },
                                            onCopyCurl: {
                                                guard let url = e.url, let key = e.key, !key.isEmpty else {
                                                    showToast("缺少 URL 或 key")
                                                    return
                                                }
                                                let model = e.models?.first ?? e.model
                                                let style: String? = {
                                                    if e.targets.contains("ccswitch") { return "anthropic" }
                                                    if let d = e.healthDetail, d.lowercased().contains("anthropic") { return "anthropic" }
                                                    return nil
                                                }()
                                                let curl = APITester.curlCommand(url: url, key: key, model: model, styleHint: style)
                                                NSPasteboard.general.clearContents()
                                                NSPasteboard.general.setString(curl, forType: .string)
                                                showToast("已复制 curl")
                                            },
                                            onReimport: { state.doReimport(e.id) },
                                            onEdit: { state.showEdit(e) },
                                                                                        highlighted: false
                                        )
                                    }
                                }
                            }
                            if !deads.isEmpty {
                                Button {
                                    withAnimation(.easeInOut(duration: 0.2)) { showDeadArea.toggle() }
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: showDeadArea ? "chevron.down" : "chevron.right")
                                            .font(.system(size: 10, weight: .semibold))
                                        Text("待删除区")
                                            .font(.system(size: 11, weight: .semibold))
                                        Text("\(deads.count)")
                                            .font(.system(size: 10, design: .monospaced))
                                        Spacer()
                                        Text(showDeadArea ? "收起" : "定时探测失效 · 一键清除")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(showDeadArea ? Color.secondary : Color(red: 0.85, green: 0.30, blue: 0.28))
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(Color(red: 0.86, green: 0.28, blue: 0.24).opacity(showDeadArea ? 0.12 : 0.07))
                                    )
                                }
                                .buttonStyle(.borderless)
                                .padding(.top, 6)
                                if showDeadArea {
                                    HStack(spacing: 6) {
                                        Spacer()
                                        Button {
                                            state.clearDead()
                                        } label: {
                                            Label("清除全部失效", systemImage: "trash.fill")
                                                .font(.system(size: 11, weight: .bold))
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 5)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 6)
                                                        .fill(Color(red: 0.85, green: 0.22, blue: 0.20))
                                                )
                                        }
                                        .buttonStyle(.borderless)
                                        .help("删除待删除区全部 \(deads.count) 条,并从 cc-switch / CPA 同步移除")
                                    }
                                    .padding(.horizontal, 2)
                                    .padding(.vertical, 4)
                                ForEach(deads, id: \.id) { e in
                                        HistoryRow(
                                            entry: e,
                                            refreshing: state.refreshingID == e.id,
                                            busy: state.isBusy,
                                            onDelete: { state.doDelete(e.id) },
                                            onCopy: { m in
                                                let copyText = CCSwitchWriter.copyModelName(for: e, model: m)
                                                NSPasteboard.general.clearContents()
                                                NSPasteboard.general.setString(copyText, forType: .string)
                                                showToast("已复制: \(copyText)")
                                            },
                                            onCopyId: { id in
                                                showToast("已复制 ID: \(id.prefix(8))…")
                                            },
                                            onRefresh: { id in state.doRefresh(id) },
                                            onLaunchApp: { id, cmd in state.doLaunchApp(entryID: id, cmd: cmd) },
                                            onCopyCurl: {
                                                guard let url = e.url, let key = e.key, !key.isEmpty else {
                                                    showToast("缺少 URL 或 key")
                                                    return
                                                }
                                                let model = e.models?.first ?? e.model
                                                let style: String? = {
                                                    if e.targets.contains("ccswitch") { return "anthropic" }
                                                    if let d = e.healthDetail, d.lowercased().contains("anthropic") { return "anthropic" }
                                                    return nil
                                                }()
                                                let curl = APITester.curlCommand(url: url, key: key, model: model, styleHint: style)
                                                NSPasteboard.general.clearContents()
                                                NSPasteboard.general.setString(curl, forType: .string)
                                                showToast("已复制 curl")
                                            },
                                            onReimport: { state.doReimport(e.id) },
                                            onEdit: { state.showEdit(e) },
                                                                                        highlighted: false
                                        )
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 240)
                    .onChange(of: state.highlightPulse) { _, _ in
                        guard let id = state.highlightID else { return }
                        if deadItems.contains(where: { $0.id == id }) {
                            showDeadArea = true
                        }
                        if quotaItems.contains(where: { $0.id == id }) {
                            showQuotaArea = true
                        }
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 4.2) {
                            if state.highlightID == id { state.highlightID = nil }
                        }
                    }
                }
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !state.isBusy else { return false }
        var handled = false
        let urlsLock = NSLock()
        var pendingURLs: [URL] = []
        let group = DispatchGroup()
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    urlsLock.lock()
                    pendingURLs.append(url)
                    urlsLock.unlock()
                }
                group.leave()
            }
            handled = true
        }
        guard handled else { return false }
        group.notify(queue: .main) {
            guard !state.isBusy, !pendingURLs.isEmpty else { return }
            // 多文件拖入原先每个文件各触发一次 doAdd,第一个置 isBusy 后
            // 其余全被 guard 静默吞掉。单文件仍走路径(Parser 支持 zip/base64);
            // 多文件读文本内容拼接后一次性导入
            if pendingURLs.count == 1 {
                state.input = pendingURLs[0].path
                state.doAdd()
                return
            }
            var contents: [String] = []
            var skipped = 0
            for u in pendingURLs {
                if let s = try? String(contentsOf: u, encoding: .utf8), !s.isEmpty {
                    contents.append(s)
                } else {
                    skipped += 1  // 二进制 zip 等无法当文本拼,跳过并提示
                }
            }
            if skipped > 0 {
                state.setStatus("部分拖入文件无法按文本读取(\(skipped) 个),已导入其余文件", ok: false)
            }
            guard !contents.isEmpty else {
                state.setStatus(skipped > 0 ? "拖入的 \(skipped) 个文件均无法按文本读取" : "拖入的文件均无法读取", ok: false)
                return
            }
            state.input = contents.joined(separator: "\n")
            state.doAdd()
        }
        return handled
    }
}

// MARK: - (end)\n
/// 底部状态格条(uptime status page 行业形态):固定 30 个格子,
/// 一格 = 一个采集周期,**统一高度**,颜色编码可用程度:
/// 绿=通过且快(<3s) 橙=通过偏慢(3-8s) 红=失败 浅灰=该周期未采集。
/// 新数据点从右侧填入,左侧灰格随采集积累逐渐被填满 —— 一屏扫过所有 provider。
/// 悬停单格显示该次探测的时间/延迟/结果
struct MonitorSparkline: View {
    let log: [ProbePoint]
    var slots: Int = 30
    var height: CGFloat = 20
    /// 最新格脉冲动画(status page 惯例:当前采集周期呼吸闪烁)—— 总览大图用
    var pulseLatest = false
    /// 固定格宽:设置后所有格(含未采集灰格)等宽固定,总宽 = slots×cellWidth+(slots-1)×spacing,
    /// 不随行内其他元素/记录数变化(用户反馈:监控条有的宽有的窄)
    var cellWidth: CGFloat? = nil
    @State private var pulsing = false

    var body: some View {
        let points = Array(log.suffix(slots))
        let pad = slots - points.count   // 左侧未采集的灰格(时间轴:最新在右)
        return HStack(spacing: 3) {
            ForEach(0..<max(pad, 0), id: \.self) { _ in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.13))
                    .frame(width: cellWidth, height: height)
                    .frame(maxWidth: cellWidth == nil ? .infinity : nil)
                    .help("该周期未采集(随自动扫描/↻ 重测逐渐填满)")
            }
            ForEach(Array(points.enumerated()), id: \.offset) { i, p in
                let isLatest = i == points.count - 1
                StatusCell(point: p, uptime: uptimePercent, height: height,
                           pulse: pulseLatest && isLatest, pulsing: $pulsing,
                           cellWidth: cellWidth)
            }
        }
    }

    private var uptimePercent: Int? {
        guard !log.isEmpty else { return nil }
        let ok = log.filter { $0.ok }.count
        return Int((Double(ok) / Double(log.count) * 100).rounded())
    }

}

/// 单个状态格:颜色编码 + 最新格脉冲(当前采集周期呼吸闪烁,status page 惯例)
struct StatusCell: View {
    let point: ProbePoint
    let uptime: Int?
    let height: CGFloat
    let pulse: Bool
    @Binding var pulsing: Bool
    /// 固定格宽(nil = 弹性填满,总览大图用)
    var cellWidth: CGFloat? = nil

    var body: some View {
        let base = RoundedRectangle(cornerRadius: 2)
            .fill(Self.cellColor(point))
            .frame(width: cellWidth, height: height)
            .frame(maxWidth: cellWidth == nil ? .infinity : nil)
            .frame(height: height)
        Group {
            if pulse {
                base.overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(Self.cellColor(point).opacity(pulsing ? 0.9 : 0.15),
                                      lineWidth: 1.5)
                )
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                        pulsing = true
                    }
                }
            } else {
                base
            }
        }
        .help(Self.hoverText(point, uptime: uptime))
    }

    /// 软件更新 sheet:发现新版本 → 自动下载(进度可见)→ 用户确认重启。
/// 流程刻意拆成「下载」与「重启」两步:重启会打断正在使用的会话,必须由用户拍板
// 状态色唯一事实源,图例(StatusLegend)从这里引用,避免两处改不同步
    static let okFast    = Color(red: 0.30, green: 0.66, blue: 0.42)   // 绿:通过且 <3s
    static let okSlow    = Color(red: 0.88, green: 0.62, blue: 0.20)   // 橙:通过但 3-8s
    // 紫:通过但 ≥8s。曾用与失败几乎相同的红(0.82,0.35,0.25),用户看到整条红
    // 以为什么时候都挂了,实际 uptime 100% —— 两红无法区分,换成紫
    static let okTooSlow = Color(red: 0.62, green: 0.46, blue: 0.85)
    static let fail      = Color(red: 0.80, green: 0.28, blue: 0.24)   // 红:探测失败
    static let pending   = Color.secondary.opacity(0.13)               // 灰:未采集

    static func cellColor(_ p: ProbePoint) -> Color {
        if !p.ok { return fail }
        let ms = p.ms ?? 3000
        if ms < 3000 { return okFast }
        if ms < 8000 { return okSlow }
        return okTooSlow
    }

    static func hoverText(_ p: ProbePoint, uptime: Int?) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        let time = f.string(from: Date(timeIntervalSince1970: p.t))
        let up = uptime.map { " · uptime \($0)%" } ?? ""
        if p.ok, let ms = p.ms {
            let speed = ms < 3000 ? "" : (ms < 8000 ? "(慢)" : "(很慢)")
            return "\(time) · 通过\(speed) · \(Int(ms)) ms\(up)"
        }
        return "\(time) · 探测失败\(up)"
    }
}

/// 状态格颜色图例:格条是「通过与否 × 延迟快慢」双维编码,而 uptime 只数通过与否
/// —— 不标注的话「全黄/全紫也 100%」看起来像算错(真实反馈)
struct UpdateSheet: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("软件更新")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                Text("当前 v\(Updater.currentVersion())")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }

            switch state.updateState {
            case .idle, .upToDate:
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal")
                        .foregroundStyle(Color(red: 0.22, green: 0.58, blue: 0.40))
                    Text("已是最新版本")
                    Button("检查更新") { Updater.shared.checkForUpdates(force: true) }
                        .controlSize(.small)
                }
                .font(.system(size: 12))
            case .checking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在检查更新…").font(.system(size: 12))
                }
            case .failed(let msg):
                VStack(alignment: .leading, spacing: 8) {
                    Text(msg).font(.system(size: 12)).foregroundStyle(.red)
                    Button("重试") { Updater.shared.checkForUpdates(force: true) }
                        .controlSize(.small)
                }
            case .available(let version, _, let notes):
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.circle.fill")
                            .foregroundStyle(Color(red: 0.22, green: 0.58, blue: 0.40))
                        Text("v\(version) 可更新")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    if !notes.isEmpty {
                        ScrollView {
                            Text(notes)
                                .font(.system(size: 10.5, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 140)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                    }
                    Button {
                        Updater.shared.startDownload()
                    } label: {
                        Text("下载更新").frame(minWidth: 110)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            case .downloading(let version, let progress):
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("正在下载 v\(version)").font(.system(size: 12))
                        Spacer()
                        Text("\(Int(progress * 100))%")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    }
                    ProgressView(value: progress)
                    HStack {
                        Spacer()
                        Button("取消") { Updater.shared.cancelDownload() }
                            .controlSize(.small)
                    }
                }
            case .ready(let version):
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color(red: 0.22, green: 0.58, blue: 0.40))
                        Text("v\(version) 已下载就绪")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    Text("点击后将替换应用并自动重启,当前会话即结束。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Button {
                        Updater.shared.applyUpdate()
                    } label: {
                        Text("重启完成更新").frame(minWidth: 110)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            case .installing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("安装中,应用即将重启…").font(.system(size: 12))
                }
            }
        }
        .padding(16)
        .frame(width: 460)
    }
}


struct StatusLegend: View {
    var showUptimeNote = true

    var body: some View {
        HStack(spacing: 10) {
            cell(StatusCell.okFast, "通过 <3s")
            cell(StatusCell.okSlow, "通过 3-8s")
            cell(StatusCell.okTooSlow, "通过 ≥8s(慢)")
            cell(StatusCell.fail, "失败")
            cell(Color.secondary.opacity(0.13), "未采集")
            if showUptimeNote {
                Spacer(minLength: 0)
                Text("% = 通过占比(uptime)")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func cell(_ c: Color, _ label: String) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 2).fill(c)
                .frame(width: 9, height: 9)
            Text(label)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
        }
        .help("格条颜色 = 通过与否 + 延迟快慢两维;uptime 只数通过与否,全黄/全紫也是 100%")
    }
}


// MARK: - 监控图(sub2api channelmonitor 思路:探针历史 + 趋势展示)


/// 单条目的延迟趋势图 + 探测明细。数据源 = probeLog(每条目滚动 30 点)


// MARK: - 总体状态横幅(status page 标志性元素)

/// "All Systems Operational" 式横幅:按 active 条目的 health 分布分级
struct OverallStatusBanner: View {
    let okCount: Int
    let warnCount: Int
    let deadCount: Int
    var compact = false

    var body: some View {
        // 口径(用户确认):只反映可用区。额度区/待删除区不参与分级 ——
        // 它们是已知状态,横幅只回答「我现在能用的网关好不好」
        let (bg, icon, title): (Color, String, String) = {
            if okCount + warnCount == 0 {
                return (Color.secondary.opacity(0.75),
                        "minus.circle.fill", "暂无可用网关(失效/无额度条目见下方分区)")
            }
            if warnCount > 0 {
                return (Color(red: 0.85, green: 0.55, blue: 0.15),
                        "exclamationmark.triangle.fill",
                        "可用 \(okCount) 个 · \(warnCount) 个链路异常(上游正常但经 CPA 不通)")
            }
            return (Color(red: 0.18, green: 0.52, blue: 0.34),
                    "checkmark.seal.fill", "全部网关可用 · \(okCount) 个在线")
        }()
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: compact ? 13 : 15))
            Text(title).font(.system(size: compact ? 12 : 13, weight: .semibold))
            Spacer()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12).padding(.vertical, compact ? 7 : 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(bg))
    }
}


/// CPA 管理 API 配置:密钥 + 可选地址;保存时实测 GET config.yaml 验证
struct CPAAPISheet: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CPA 管理 API").font(.system(size: 13, weight: .semibold))
            Text("配置后,KeyDrop 对 CPA 的全部读写经管理 API(127.0.0.1:8317),不再直接触碰 CPA 数据目录文件——若该目录在「文稿」下,权限弹窗从此消失。密钥即管理面板登录口令。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("管理密钥", text: $state.cpaAPIKeyInput)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
            TextField("API 地址(默认 http://127.0.0.1:8317)", text: $state.cpaAPIBaseInput)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
            if !state.cpaAPIStatus.isEmpty {
                Text(state.cpaAPIStatus)
                    .font(.system(size: 11))
                    .foregroundStyle(state.cpaAPIOk ? Color.green : Color.red)
            }
            HStack {
                Button("保存并测试") { state.saveCPAAPI() }
                    .keyboardShortcut(.defaultAction)
                Button("清除(回到文件模式)") { state.clearCPAAPI() }
                Spacer()
                Button("关闭") { state.cpaAPISheetShown = false }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 400)
    }
}
