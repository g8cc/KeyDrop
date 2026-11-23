import AppKit
import SwiftUI
import KeyDropCore

weak var appDelegateWeak: AppDelegate?
enum AppDelegateRef { static var shared: AppDelegate? { appDelegateWeak } }

let testDir = NSTemporaryDirectory() + "KeyDropAppTests-" + UUID().uuidString
setenv("KEYDROP_HOME", testDir, 1)
setenv("KEYDROP_CC_DB", testDir + "/absent.db", 1)
setenv("KEYDROP_CPA_CONFIG", testDir + "/absent.yaml", 1)
setenv("KEYDROP_NO_AUTOPROXY", "1", 1)
setenv("KEYDROP_LLM_PARSE", "0", 1)
signal(SIGPIPE, SIG_IGN)
defer { try? FileManager.default.removeItem(atPath: testDir) }
let app = NSApplication.shared
var failures = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if condition() { print("✓ \(message)") } else { failures += 1; print("✗ \(message)") }
}

func capturePickerOutput(_ body: () -> [String]?) throws -> ([String]?, String) {
    let path = testDir + "/picker-\(UUID().uuidString).log"
    FileManager.default.createFile(atPath: path, contents: nil)
    let output = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
    let savedOutput = dup(STDOUT_FILENO)
    fflush(stdout)
    dup2(output.fileDescriptor, STDOUT_FILENO)
    defer {
        fflush(stdout)
        dup2(savedOutput, STDOUT_FILENO)
        close(savedOutput)
        try? output.close()
        try? FileManager.default.removeItem(atPath: path)
    }
    let result = body()
    fflush(stdout)
    return (result, try String(contentsOfFile: path, encoding: .utf8))
}

let failedCPA = ProbePoint(t: Date().timeIntervalSince1970, ms: 120, ok: true, cpa: false)
let passedUpstream = ProbePoint(t: failedCPA.t, ms: 120, ok: true)
let passedCPA = ProbePoint(t: failedCPA.t, ms: 120, ok: true, cpa: true)
let failedUpstream = ProbePoint(t: failedCPA.t, ms: nil, ok: false, cpa: true)
check(StatusCell.cellColor(failedCPA) == StatusCell.fail, "CPA 链路失败的监控格不能显示绿色")
check(StatusCell.hoverText(failedCPA, uptime: 0).contains("上游通过") &&
      StatusCell.hoverText(failedCPA, uptime: 0).contains("CPA 链路失败"),
      "监控格提示区分上游通过和 CPA 链路失败")
check(MonitorPresentation.uptimePercent([failedCPA, passedCPA]) == 50 &&
      MonitorPresentation.uptimePercent([failedCPA]) == 0,
      "CPA 失败点不计入监控通过率，避免错误显示 100%")
check(MonitorPresentation.passed(passedUpstream) && MonitorPresentation.passed(passedCPA) &&
      !MonitorPresentation.passed(failedUpstream) && MonitorPresentation.uptimePercent([]) == nil,
      "未采集、直连通过和任一路径失败保持正确语义")

let view = NSHostingView(rootView: PanelView(state: AppState()))
let window = MainWindow.make(contentView: view)
check(!(window is NSPanel), "使用普通 NSWindow")
check(window.styleMask.contains([.resizable, .miniaturizable, .closable]), "支持缩放、最小化和关闭")
check(!window.collectionBehavior.contains(.canJoinAllSpaces), "窗口归属所在桌面")
check(!window.collectionBehavior.contains(.fullScreenAuxiliary), "不作为全屏辅助面板")
check(window.level == .normal, "普通窗口层级")
window.setContentSize(NSSize(width: 800, height: 720))
view.layoutSubtreeIfNeeded()
check(view.frame.width >= 799 && view.frame.height >= 719, "SwiftUI 内容随窗口伸缩")
window.performClose(nil)
check(!window.isVisible, "关闭窗口")
window.makeKeyAndOrderFront(nil)
check(window.isVisible, "关闭后可重新打开")
window.orderOut(nil)

let state = AppState()
state.useCC = false; state.useGrok = false; state.useCPA = false; state.useDSH = false
state.isBusy = true
state.busyLabel = "拉取订阅…"

@MainActor
func waitUntil(_ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(3)
    while !condition() && clock.now < deadline {
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

final class UpdateFixtureProtocol: URLProtocol {
    static let successfulRelease = #"{"tag_name":"v999.0.0","assets":[{"name":"KeyDrop-v999.0.0.zip","browser_download_url":"https://github.com/g8cc/KeyDrop/releases/download/v999.0.0/KeyDrop-v999.0.0.zip"}]}"#
    private static let responseLock = NSLock()
    private static var releaseBody = successfulRelease
    static var releaseResponse: String {
        get { responseLock.lock(); defer { responseLock.unlock() }; return releaseBody }
        set { responseLock.lock(); defer { responseLock.unlock() }; releaseBody = newValue }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.url?.host == "api.github.com"
            ? Self.releaseResponse
            : "invalid zip fixture"
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": "\(body.utf8.count)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

Task { @MainActor in
    func failureFixture(_ id: String, health: String) -> HistoryEntry {
        HistoryEntry(id: id, ts: 1, raw: "fixture", format: "test", name: id,
                     url: "https://fixture.invalid/v1", model: nil, key: "sk-fixture", keyMasked: "***",
                     targets: [], ccProviderID: nil, ccRenamedFrom: nil, ccRenamedTo: nil,
                     cpaConfigPath: nil, status: "active", health: health, healthAt: 1)
    }
    let selectedFailure = failureFixture("selected-failure", health: "err")
    let hiddenFailure = failureFixture("hidden-failure", health: "dead")
    let recovered = failureFixture("recovered-entry", health: "ok")
    for entry in [selectedFailure, hiddenFailure, recovered] { try! Core.shared.history.append(entry) }
    let deletionState = AppState()
    deletionState.clearFailed(ids: [selectedFailure.id, recovered.id])
    let deletionFinished = await waitUntil { !deletionState.isBusy }
    check(deletionFinished && Core.shared.history.find(idPrefix: selectedFailure.id)?.status == "deleted",
          "批量删除只处理明确选中的失败记录")
    check(Core.shared.history.find(idPrefix: hiddenFailure.id)?.status == "active",
          "批量删除不影响搜索未命中的其他失败记录")
    check(Core.shared.history.find(idPrefix: recovered.id)?.status == "active",
          "确认后已恢复的记录不会被批量删除")

    await state.continueAddKey(raw: "https://example.invalid", assumeBusy: true)
    check(!state.isBusy && state.busyLabel.isEmpty, "订阅回退无目标时释放 busy 状态")
    check(!state.statusOK, "明确提示未启用写入目标")

    let subscription = try! MockHTTPServer(mode: .stalledImportProbe)
    let url = "http://127.0.0.1:\(subscription.port)/subscribe"
    state.input = url
    state.doAdd()
    let requestStarted = await waitUntil { subscription.countRequests("/subscribe") == 1 }
    check(requestStarted && state.importCanCancel && state.busyLabel == "拉取订阅…", "拉取订阅时显示阶段并允许取消")
    state.cancelImport()
    let subscriptionFinished = await waitUntil { !state.isBusy }
    check(subscriptionFinished && !state.importCanCancel && state.input == url && state.statusOK && state.statusText == "已取消导入",
          "取消订阅后释放 busy 状态、保留输入并显示取消结果")
    check(subscription.countRequests("/subscribe") == 1, "已取消的订阅不走回退重试")
    subscription.releaseImportProbe.signal()

    let provider = try! MockHTTPServer()
    state.useCC = true
    Prefs.shared.useCC = true
    Prefs.shared.useGrok = false
    Prefs.shared.useDSH = false
    let raw = "http://127.0.0.1:\(provider.port)/v1\nsk-pickerfixture1111"
    state.input = raw
    state.doAdd()
    let pickerShown = await waitUntil { state.modelPickerShown }
    check(pickerShown && state.modelPickerShown && state.importCanCancel && state.busyLabel == "等待选择模型…",
          "已完成探测时显示选择模型阶段")
    state.cancelModelPicker()
    let pickerFinished = await waitUntil { !state.isBusy }
    check(pickerFinished && !state.modelPickerShown && !state.importCanCancel && state.input == raw && state.statusOK
          && state.statusText == "已取消导入", "在模型弹窗取消时释放 busy 状态、保留输入并显示取消结果")

    let updateDefaultsName = "KeyDropUpdaterTests-\(UUID().uuidString)"
    let updateDefaults = UserDefaults(suiteName: updateDefaultsName)!
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [UpdateFixtureProtocol.self]
    let updateSession = URLSession(configuration: configuration)
    let updater = Updater(session: updateSession, defaults: updateDefaults)
    var updateStates: [Updater.State] = []
    updater.onStateChange = { updateStates.append($0) }
    updater.checkForUpdates(force: true)
    check(updateStates.last == .checking, "检查更新立即通知 UI 状态")
    let updateAvailable = await waitUntil {
        if case .available = updater.state { return true }
        return false
    }
    check(updateAvailable, "更新测试通过隔离会话获取发布信息")
    updater.startDownload()
    check(updateStates.last == .downloading(version: "999.0.0", progress: 0), "开始下载立即通知 UI 状态")
    let updateReady = await waitUntil { updater.state == .ready(version: "999.0.0") }
    check(updateReady, "下载完成后可等待用户确认安装")
    try? await Task.sleep(for: .milliseconds(100))
    updater.applyUpdate()
    check(updater.state == .installing, "开始安装立即进入安装状态，阻止重复提交")
    let updateRejected = await waitUntil {
        if case .failed = updater.state { return true }
        return false
    }
    if case .failed(let message) = updater.state {
        check(updateRejected && message.contains("更新包目录读取失败"), "延后安装仍可读取下载文件并进入归档校验")
    } else {
        check(false, "无效更新包按预期失败")
    }
    updater.cancelDownload()
    updateSession.invalidateAndCancel()
    updateDefaults.removePersistentDomain(forName: updateDefaultsName)

    for invalidRelease in ["invalid JSON", "{}", #"{"tag_name":"invalid"}"#,
                           #"{"tag_name":"v999.0.0","assets":[]}"#] {
        let defaultsName = "KeyDropUpdaterRetryTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        let session = URLSession(configuration: configuration)
        let retryUpdater = Updater(session: session, defaults: defaults)
        UpdateFixtureProtocol.releaseResponse = invalidRelease
        retryUpdater.checkForUpdates(force: true)
        let failed = await waitUntil {
            if case .failed = retryUpdater.state { return true }
            return false
        }
        check(failed && defaults.double(forKey: "updateLastCheckAt") == 0,
              "无效 HTTP 200 发布响应不启动 12 小时检查冷却")
        UpdateFixtureProtocol.releaseResponse = UpdateFixtureProtocol.successfulRelease
        retryUpdater.checkForUpdates()
        let retried = await waitUntil {
            if case .available = retryUpdater.state { return true }
            return false
        }
        check(retried && defaults.double(forKey: "updateLastCheckAt") > 0,
              "发布响应恢复后自动重试成功，再记录检查冷却")
        session.invalidateAndCancel()
        defaults.removePersistentDomain(forName: defaultsName)
    }

    var terminalMaster: Int32 = -1
    var terminalSlave: Int32 = -1
    let originalInput = dup(STDIN_FILENO)
    if openpty(&terminalMaster, &terminalSlave, nil, nil, nil) == 0 {
        dup2(terminalSlave, STDIN_FILENO)
        let terminal = FileHandle(fileDescriptor: terminalMaster, closeOnDealloc: false)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            terminal.write(Data([0x1b]))
        }
        let configURL = URL(fileURLWithPath: testDir + "/absent.yaml")
        let originalConfig = "port: 8317\n"
        try! originalConfig.write(to: configURL, atomically: true, encoding: .utf8)
        Prefs.shared.cpaResident = false
        let result = CLI.run(["add", "http://127.0.0.1:\(provider.port)/v1\nsk-clicancelfixture1111",
                              "--no-cc", "--no-grok", "--no-dsh", "--cpa"])
        check(result == 1 && (try? String(contentsOf: configURL, encoding: .utf8)) == originalConfig,
              "CLI 按 Esc 取消导入并保留目标配置")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            terminal.write(Data([0x0d, 0x1b]))
        }
        let firstPick = ModelPicker.pick(from: ["first-model"], title: "首轮选择")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            terminal.write(Data([0x0d]))
        }
        let secondPick = ModelPicker.pick(from: ["second-model"], title: "下一轮选择")
        check(firstPick == ["first-model"] && secondPick == ["second-model"],
              "完成选择后清空残留按键，下一轮不会被旧 Esc 误取消")
        let manyModels = (1...25).map { String(format: "model-%02d", $0) }
        do {
            let (lastPick, output) = try capturePickerOutput {
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                    let down = Array(repeating: [UInt8]("\u{1B}[B".utf8), count: 24).flatMap { $0 }
                    terminal.write(Data(down + [0x0d]))
                }
                return ModelPicker.pick(from: manyModels, title: "长列表选择")
            }
            let finalFrame = output.components(separatedBy: "\u{1B}[2J\u{1B}[H").last ?? ""
            check(lastPick == ["model-25"] && finalFrame.contains("\u{1B}[7m[ ] model-25"),
                  "超过 20 个模型后选择窗口跟随光标，当前项保持可见")
            let (allPicked, _) = try capturePickerOutput {
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                    terminal.write(Data([0x61, 0x0d]))
                }
                return ModelPicker.pick(from: manyModels, title: "按探测顺序多选")
            }
            check(allPicked == manyModels, "CLI 多选保留探测顺序，不随机改变默认模型")
        } catch {
            check(false, "可捕获隔离终端输出: \(error.localizedDescription)")
        }
        dup2(originalInput, STDIN_FILENO)
        close(terminalMaster)
        close(terminalSlave)
    } else {
        check(false, "可创建隔离终端验证交互取消")
    }
    close(originalInput)
    let nullInput = open("/dev/null", O_RDONLY)
    let savedInput = dup(STDIN_FILENO)
    dup2(nullInput, STDIN_FILENO)
    let models = ["deepseek-test", "qwen-test"]
    check(ModelPicker.pick(from: models, title: "非交互回归") == models, "非交互 CLI 保留自动选择全部模型")
    dup2(savedInput, STDIN_FILENO)
    close(savedInput)
    close(nullInput)

    print("App 回归: \(failures) 失败")
    exit(failures == 0 ? 0 : 1)
}
app.run()
