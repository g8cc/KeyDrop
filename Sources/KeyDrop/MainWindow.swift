import AppKit

/// 跟随所在桌面的普通应用窗口。
enum MainWindow {
    static func make(contentView: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "KeyDrop"
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        window.tabbingMode = .disallowed
        window.contentMinSize = NSSize(width: 600, height: 520)
        window.contentView = contentView
        // 初始位置先设,然后恢复保存的 frame。
        window.center()
        window.setFrameAutosaveName("KeyDrop.MainWindow.v1")
        return window
    }
}
