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

Task { @MainActor in
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

    print("App 回归: \(failures) 失败")
    exit(failures == 0 ? 0 : 1)
}
app.run()
