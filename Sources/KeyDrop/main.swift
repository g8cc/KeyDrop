import AppKit
import Foundation
import KeyDropCore

weak var appDelegateWeak: AppDelegate?
enum AppDelegateRef {
    static var shared: AppDelegate? { appDelegateWeak }
}

let args = Array(CommandLine.arguments.dropFirst())

let cliCommands = ["add", "list", "scan", "cpa-sync", "delete", "rm", "parse", "status", "refresh",
                   "reimport", "edit", "self-heal", "picker-test", "help", "h",
                   "image-add", "image", "mcp-image"]
if let first = args.first {
    // 已知子命令/选项 → CLI;未知裸词命令必须报错退出而非静默启动菜单栏:
    // 曾因新子命令漏加白名单,`KeyDrop scan` 静默拉起第二个 app 实例,命令毫无反应
    if first.hasPrefix("--") || cliCommands.contains(first) {
        let code = CLI.run(args)
        exit(code)
    }
    print("未知命令: \(first)\n可用命令: \(cliCommands.filter { $0 != "h" }.joined(separator: ", "))")
    exit(2)
}

let app = NSApplication.shared
let delegate = AppDelegate()
appDelegateWeak = delegate
app.delegate = delegate
app.run()
