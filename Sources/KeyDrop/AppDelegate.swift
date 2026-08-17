import KeyDropCore
import AppKit
import SwiftUI
import ServiceManagement
import Carbon
import Darwin

class KeyDropPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }

    override func close() {
        orderOut(nil)
    }

    override func performClose(_ sender: Any?) {
        orderOut(nil)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "w" {
            orderOut(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var statusItem: NSStatusItem!
    var panel: KeyDropPanel?
    let state = AppState()
    private var panelObservers: [NSObjectProtocol] = []
    private var eventMonitor: Any?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerRef: EventHandlerRef?

    deinit {
        for token in panelObservers {
            NotificationCenter.default.removeObserver(token)
        }
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let hotKeyHandlerRef {
            RemoveEventHandler(hotKeyHandlerRef)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.info("KeyDrop 启动 v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
        NSApp.setActivationPolicy(.accessory)

        setupMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.title = "K"
            btn.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
            btn.action = #selector(onClick)
            btn.target = self
            btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
            btn.toolTip = "KeyDrop — 贴 key 即用 · ⌘⇧K"
        }

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event) ?? event
        }

        registerHotKey()

        let healed = Core.shared.selfHeal()
        if !healed.isEmpty {
            AppLog.info("self-heal: " + healed.joined(separator: "; "))
            Logger.info(healed.joined(separator: "; "))
        }

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(appActivationChanged(_:)),
                       name: NSApplication.didBecomeActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(appActivationChanged(_:)),
                       name: NSApplication.didResignActiveNotification, object: nil)
        logPasteEvent("应用启动")
    }

    @objc private func appActivationChanged(_ n: Notification) {
        logPasteEvent("激活状态变化: \(n.name.rawValue)")
    }

    private func setupMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "打开面板", action: #selector(showPanelAction), keyEquivalent: "o")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 KeyDrop", action: #selector(quitApp), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        NSApp.mainMenu = main
    }

    private func logHotKey(_ s: String) {
        SecureLog.append("hotkey.log", line: "\(Date().timeIntervalSince1970) \(s)")
    }

    private func registerHotKey() {
        let hotKeyID = EventHotKeyID(signature: OSType(0x4B44524F), id: 1)
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handler: EventHandlerUPP = { _, event, _ in
            var hkID = EventHotKeyID()
            if let event {
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID
                )
            }
            if hkID.id == 1 {
                DispatchQueue.main.async {
                    AppDelegateRef.shared?.logHotKey("热键触发,切换面板")
                    AppDelegateRef.shared?.togglePanel()
                }
            }
            return noErr
        }
        var handlerRef: EventHandlerRef?
        let installErr = InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventType,
            nil,
            &handlerRef
        )
        hotKeyHandlerRef = handlerRef
        let regErr = RegisterEventHotKey(
            UInt32(kVK_ANSI_K),
            UInt32(cmdKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        logHotKey("安装 handler: \(installErr) 注册热键 ⌘⇧K: \(regErr)")
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command),
              !flags.contains(.option),
              event.charactersIgnoringModifiers?.lowercased() == "v",
              panel?.isVisible == true
        else { return event }
        let isEditable = (panel?.firstResponder as? NSTextView)?.isEditable == true
        let hasPB = !(NSPasteboard.general.string(forType: .string) ?? "").isEmpty
        logPaste(isEditable: isEditable, hasPB: hasPB)
        if isEditable { return event }
        if hasPB {
            state.input = NSPasteboard.general.string(forType: .string) ?? ""
            return nil
        }
        return event
    }

    private func logPaste(isEditable: Bool, hasPB: Bool) {
        logPasteEvent("⌘V 到达应用; 输入框可编辑=\(isEditable) 剪贴板=\(hasPB) 面板可见=\(panel?.isVisible ?? false)")
    }

    private func logPasteEvent(_ message: String) {
        SecureLog.append("paste.log", line: "\(Date().timeIntervalSince1970) \(message)")
    }

    @objc func onClick(_ sender: Any?) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            togglePanel()
        }
    }

    func showMenu() {
        let menu = NSMenu()
        let panelItem = NSMenuItem(title: "打开面板", action: #selector(showPanelAction), keyEquivalent: "")
        panelItem.target = self
        menu.addItem(panelItem)

        let ccItem = NSMenuItem(title: "写入 cc-switch", action: #selector(toggleCC), keyEquivalent: "")
        ccItem.target = self
        ccItem.state = Prefs.shared.useCC ? .on : .off
        menu.addItem(ccItem)

        let cpaItem = NSMenuItem(title: "写入 CPA", action: #selector(toggleCPA), keyEquivalent: "")
        cpaItem.target = self
        cpaItem.state = Prefs.shared.useCPA ? .on : .off
        menu.addItem(cpaItem)

        let loginItem = NSMenuItem(
            title: "开机自启",
            action: #selector(toggleLogin),
            keyEquivalent: ""
        )
        loginItem.target = self
        loginItem.state = loginEnabled() ? .on : .off
        menu.addItem(loginItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 KeyDrop", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc func showPanelAction() {
        showPanel()
    }

    @objc func quitApp() {
        NSApp.terminate(nil)
    }

    @objc func toggleCC() {
        state.toggleUseCC()
    }

    @objc func toggleCPA() {
        state.toggleUseCPA()
    }

    @objc func togglePanel() {
        if let p = panel, p.isVisible {
            if NSApp.isActive {
                p.orderOut(nil)
            } else {
                // 窗口存在但 app 失焦(被其他窗口盖住):带回前台而非隐藏
                p.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                retryFocus()
            }
            return
        }
        showPanel()
    }

    func showPanel() {
        if panel == nil {
            let hosting = NSHostingView(rootView: PanelView(state: state))
            hosting.wantsLayer = true
            let p = KeyDropPanel(
                contentRect: NSRect(x: 0, y: 0, width: 580, height: 520),
                styleMask: [.titled, .closable, .utilityWindow],
                backing: .buffered,
                defer: false
            )
            p.title = "KeyDrop"
            p.contentView = hosting
            p.delegate = self
            p.level = .normal
            p.isFloatingPanel = false
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            p.isReleasedWhenClosed = false
            p.hasShadow = true
            p.isOpaque = true
            p.backgroundColor = NSColor.windowBackgroundColor
            // 换名避开之前被压矮后保存的错误尺寸
            p.setFrameAutosaveName("KeyDropPanel.v4")
            p.contentMinSize = NSSize(width: 520, height: 420)
            p.contentMaxSize = NSSize(width: 720, height: 780)
            p.setContentSize(NSSize(width: 580, height: 520))
            if let screen = NSScreen.main {
                let f = screen.visibleFrame
                p.setFrameOrigin(NSPoint(x: f.maxX - 600, y: f.maxY - 560))
            }
            if let closeBtn = p.standardWindowButton(.closeButton) {
                closeBtn.isEnabled = true
                closeBtn.target = self
                closeBtn.action = #selector(hidePanelFromButton(_:))
            }
            panel = p
        }
        state.useCC = Prefs.shared.useCC
        state.useCPA = Prefs.shared.useCPA
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        retryFocus()
    }

    @objc private func hidePanelFromButton(_ sender: Any?) {
        panel?.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    private func retryFocus() {
        focusInput(in: panel?.contentView)
        for d in [0.08, 0.2, 0.45] {
            DispatchQueue.main.asyncAfter(deadline: .now() + d) { [weak self] in
                guard let self, self.panel?.isVisible == true else { return }
                self.focusInput(in: self.panel?.contentView)
            }
        }
    }

    private func focusInput(in view: NSView?) {
        guard let v = view else { return }
        for sub in v.subviews {
            if let tv = sub as? NSTextView, tv.isEditable {
                panel?.makeFirstResponder(tv)
                return
            }
            focusInput(in: sub)
        }
        if panel?.firstResponder == nil || panel?.firstResponder == panel?.contentView {
            panel?.makeFirstResponder(v)
        }
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            Logger.warn("开机自启切换失败: \(error.localizedDescription)")
            let alert = NSAlert()
            alert.messageText = "开机自启设置失败"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    func loginEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }
}

enum SecureLog {
    private static let maxBytes: Int64 = 1_500_000
    private static let lock = NSLock()

    private static var logDir: String {
        if let home = ProcessInfo.processInfo.environment["KEYDROP_HOME"] {
            return home + "/logs"
        }
        return NSHomeDirectory() + "/.keydrop/logs"
    }

    static func append(_ filename: String, line: String) {
        lock.lock(); defer { lock.unlock() }
        let dir = logDir
        let path = (dir as NSString).appendingPathComponent(filename)
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            var st = stat()
            if FileManager.default.fileExists(atPath: path) {
                if stat(path, &st) == 0 && Int64(st.st_size) > maxBytes {
                    try? FileManager.default.removeItem(atPath: path)
                }
            }
            var created = false
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil)
                created = true
            }
            if created {
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
            }
            if let fh = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
                defer { try? fh.close() }
                _ = try? fh.seekToEnd()
                if let data = (line + "\n").data(using: .utf8) {
                    try? fh.write(contentsOf: data)
                }
            }
        } catch {
            // best-effort; never crash on logging
        }
    }
}
