import AppKit
import Foundation
import KeyDropCore

weak var appDelegateWeak: AppDelegate?
enum AppDelegateRef {
    static var shared: AppDelegate? { appDelegateWeak }
}

let args = Array(CommandLine.arguments.dropFirst())

let cliCommands = ["add", "list", "delete", "rm", "parse", "status", "refresh",
                   "reimport", "edit", "self-heal", "picker-test", "help", "h",
                   "image-add", "image", "mcp-image"]
if let first = args.first, first.hasPrefix("--") || cliCommands.contains(first) {
    let code = CLI.run(args)
    exit(code)
}

let app = NSApplication.shared
let delegate = AppDelegate()
appDelegateWeak = delegate
app.delegate = delegate
app.run()
