import KeyDropCore
import AppKit
import SwiftUI
import UserNotifications

final class AppState: ObservableObject {
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
    @Published var useCPA: Bool
    @Published var useDSH: Bool
    @Published var proxyText: String
    @Published var highlightID: String?
    @Published var highlightPulse = 0
    @Published var helpShown = false
    @Published var editShown = false
    @Published var editTarget: HistoryEntry?
    @Published var editModelsText = ""
    @Published var editNameText = ""
    private var statusClearTask: DispatchWorkItem?
    private var healthTimer: Timer?

    let core = Core.shared

    init() {
        useCC = Prefs.shared.useCC
        useCPA = Prefs.shared.useCPA
        useDSH = Prefs.shared.useDSH
        proxyText = Prefs.shared.proxy
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
                defer {
                    isBusy = false
                    busyLabel = ""
                }
                do {
                    let proxies = try await Task.detached(priority: .userInitiated) {
                        try Core.fetchSubscriptionProxies(url: trimmed)
                    }.value
                    if proxies.isEmpty {
                        // 不是订阅,继续当普通 API 内容处理
                        await self.continueAddKey(raw: raw)
                        return
                    }
                    input = ""
                    clashPreviewProxies = proxies
                    clashPreviewShown = true
                    setStatus("检测到订阅,请确认导入", ok: true)
                } catch {
                    // 拉取失败则回退到 key 解析
                    await self.continueAddKey(raw: raw)
                }
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
        let proxyCount = lines.filter { Parser.isProxyURL($0) }.count
        return proxyCount > 0 && proxyCount * 2 >= lines.count
    }

    @MainActor
    private func continueAddKey(raw: String) async {
        if !useCC && !useCPA && !useDSH {
            setStatus("请先开启 cc-switch、CPA 或 DeepSeek Harness 写入目标", ok: false)
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
        if sem.wait(timeout: .now() + 300) == .timedOut {
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
                let msg = try await Task.detached(priority: .userInitiated) {
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
                        cpaConfigPath: nil, status: "active"
                    )
                    try Core.shared.history.append(entry)
                    try Core.shared.prefs.save()
                    return r
                }.value
                setStatus(msg, ok: true)
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

    func scanHealth() {
        Task.detached(priority: .userInitiated) {
            Core.shared.scanHealth { msgs in
                DispatchQueue.main.async {
                    self.historyVersion += 1
                    if !msgs.isEmpty {
                        self.setStatus("健康扫描: \(msgs.joined(separator: "; "))", ok: false)
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
        let ids = core.history.snapshot()
            .filter { $0.status == "active" && ($0.health == "dead" || $0.health == "err" || $0.health == "proxy-ok") }
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
        proxyText = v
        prefs.proxy = v.trimmingCharacters(in: .whitespacesAndNewlines)
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
        if entry.targets.contains("ccswitch-opencode") { return ("opencode", "chevron.left.forwardslash.chevron.right", Color(red: 0.25, green: 0.48, blue: 0.85)) }
        if entry.targets.contains("ccswitch-codex") { return ("codex", "c.circle.fill", Color(red: 0.22, green: 0.62, blue: 0.40)) }
        if entry.targets.contains("ccswitch") { return ("claude", "star.fill", Color(red: 0.85, green: 0.48, blue: 0.18)) }
        if entry.targets.contains("cpa") {
            let models = entry.models ?? (entry.model.map { [$0] } ?? [])
            let appType = Core.routeAppType(selectedModels: models, modelsOverride: nil, default: "claude")
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
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                    if let displayModels, !displayModels.isEmpty {
                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(), alignment: .leading),
                                GridItem(.flexible(), alignment: .leading)
                            ],
                            spacing: 3
                        ) {
                            ForEach(Array(displayModels.enumerated()), id: \.offset) { _, m in
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
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(Color(red: 0.22, green: 0.58, blue: 0.40))
                                .help("点击复制，去 \(appLaunch?.cmd ?? "AI 客户端") /model 粘贴即可唯一定位")
                            }
                        }
                        .padding(.top, 1)
                    }
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
                        state.confirmModelPicker(Array(selected))
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
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    section("贴 key 即用", icon: "arrow.down.doc") {
                        item("粘贴内容后点「添加并激活」,自动解析 URL / key / 模型,并写入开启的通道(cc-switch / CPA)")
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
                        item("快捷键:⌘⏎ 快速添加并激活")
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
    @State private var showHistory = true
    @State private var showStatusDetail = false
    @State private var showDeadArea = false
    @State private var showQuotaArea = false
    @State private var searchText = ""
    @State private var toastText: String?
    @State private var dropTargeted = false
    @FocusState private var inputFocused: Bool

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
            .filter { $0.status == "active" && $0.health != "dead" && $0.health != "err" && $0.health != "quota" }
            .filter(matches)
            .sorted { $0.ts > $1.ts }
            .prefix(60)
            .map { $0 }
    }

    private var quotaItems: [HistoryEntry] {
        _ = state.historyVersion
        return state.core.history.snapshot()
            .filter { $0.status == "active" && $0.health == "quota" }
            .filter(matches)
            .sorted { $0.ts > $1.ts }
            .prefix(60)
            .map { $0 }
    }

    private var deadItems: [HistoryEntry] {
        _ = state.historyVersion
        return state.core.history.snapshot()
            .filter { $0.status == "active" && ($0.health == "dead" || $0.health == "err" || $0.health == "proxy-ok") }
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
                if showHistory {
                    historyBlock
                } else {
                    Spacer(minLength: 0)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 580, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            DispatchQueue.main.async { inputFocused = true }
            state.scanHealth()
            state.startHealthTimer()
        }
        .onChange(of: state.statusText) { _, newValue in
            if newValue.isEmpty { showStatusDetail = false }
        }
        .onChange(of: state.highlightID) { _, newValue in
            if newValue != nil { showHistory = true }
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
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Text("KeyDrop")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                Text("贴 key 即用")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            targetChip("cc-switch", on: state.useCC, color: Color(red: 0.22, green: 0.58, blue: 0.40)) {
                state.toggleUseCC()
            }
            targetChip("CPA", on: state.useCPA, color: Color(red: 0.28, green: 0.48, blue: 0.82)) {
                state.toggleUseCPA()
            }
            targetChip("DSH", on: state.useDSH, color: Color(red: 0.85, green: 0.55, blue: 0.15)) {
                state.toggleUseDSH()
            }
            TextField("代理 (可选)", text: Binding(
                get: { state.proxyText },
                set: { state.setProxy($0) }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 10, design: .monospaced))
            .frame(width: 130)
            .help("本地代理,如 http://127.0.0.1:7890;测试与写入时使用,Claude Code/CPA 同步生效")
            Toggle(isOn: $showHistory) {
                HStack(spacing: 3) {
                    Image(systemName: "clock")
                        .font(.system(size: 10))
                    Text("历史")
                        .font(.system(size: 10, weight: .semibold))
                }
            }
            .toggleStyle(.button)
            .buttonStyle(.borderless)
            .help(showHistory ? "隐藏历史列表" : "显示历史列表")
            .foregroundStyle(showHistory ? Color.primary : Color.secondary)
            .padding(.horizontal, 4)
            Button {
                state.helpShown = true
            } label: {
                Text("?")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("使用说明")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func targetChip(_ title: String, on: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(on ? color : Color.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
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
                        Text("添加并激活")
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

            Text("⌘↩ 添加 · ⌘V 粘贴")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            Spacer()

            Text("↻ 测试 · 终端图标复制 curl")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
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
                    Text("粘贴 key 后点「添加并激活」")
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
        for p in providers {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async {
                    guard !state.isBusy else { return }
                    state.input = url.path
                    state.doAdd()
                }
            }
            handled = true
        }
        return handled
    }
}

// MARK: - (end)
