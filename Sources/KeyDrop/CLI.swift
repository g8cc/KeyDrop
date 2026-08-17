import Foundation
import KeyDropCore

enum CLI {
    static func run(_ args: [String]) -> Int32 {
        let a = args
        guard !a.isEmpty else {
            print(helpText)
            return 0
        }
        var ccOverride: Bool? = nil
        var cpaOverride: Bool? = nil
        var dshOverride: Bool? = nil
        var modelsOverride: [String] = []
        var editName: String? = nil
        var noVerify = false
        var force = false
        var appType: String? = nil
        var proxy: String? = nil
        var remaining: [String] = []
        var i = 0
        while i < a.count {
            let t = a[i]
            switch t {
            case "--cc": ccOverride = true
            case "--no-cc": ccOverride = false
            case "--cpa": cpaOverride = true
            case "--no-cpa": cpaOverride = false
            case "--dsh": dshOverride = true
            case "--no-dsh": dshOverride = false
            case "--force": force = true
            case "--yes", "-y": break
            case "--no-verify": noVerify = true
            case "--name":
                if i + 1 < a.count {
                    editName = a[i + 1]
                    i += 1
                }
            case "--app":
                if i + 1 < a.count {
                    appType = a[i + 1].lowercased()
                    i += 1
                }
            case "--model", "--models":
                if i + 1 < a.count {
                    modelsOverride = a[i + 1]
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    i += 1
                }
            case "--cpa-config":
                if i + 1 < a.count {
                    setenv("KEYDROP_CPA_CONFIG", a[i + 1], 1)
                    i += 1
                }
            case "--proxy":
                if i + 1 < a.count {
                    proxy = a[i + 1]
                    i += 1
                }
            default: remaining.append(t)
            }
            i += 1
        }
        var cmd = remaining.isEmpty ? "" : remaining.removeFirst()
        if cmd.hasPrefix("--") { cmd = String(cmd.dropFirst(2)) }

        switch cmd {
        case "add":
            let text = inputText(from: remaining)
            guard !text.isEmpty else {
                print("用法: KeyDrop --add <key内容> [--cc] [--no-cc] [--cpa] [--no-cpa] [--dsh] [--no-dsh] [--cpa-config <path>] [--proxy <url>]")
                return 2
            }
            do {
                let outcome = try Core.shared.add(
                    raw: text,
                    ccOverride: ccOverride,
                    cpaOverride: cpaOverride,
                    dshOverride: dshOverride,
                    models: modelsOverride.isEmpty ? nil : modelsOverride,
                    force: force,
                    appType: appType ?? Core.defaultAppType,
                    appTypeForced: appType != nil,
                    proxy: proxy ?? ProcessInfo.processInfo.environment["KEYDROP_PROXY"]
                ) { models in
                    ModelPicker.pick(from: models, title: "测试通过,获取到 \(models.count) 个模型(空格勾选,可多选):") ?? models
                }
                print(outcome.lines.joined(separator: "\n"))
                if outcome.ok { AppLog.info("CLI add ok: \(outcome.lines.joined(separator: "; "))") }
                else { AppLog.error("CLI add failed: \(outcome.lines.joined(separator: "; "))") }
                return outcome.ok ? 0 : 1
            } catch {
                AppLog.error("CLI add error: \(error.localizedDescription) | 原文: \(text)")
                print("失败: \(error.localizedDescription)")
                return 1
            }

        case "picker-test":
            let models = ["kimi-k3", "qwen3.5:397b", "glm-5.2", "minimax-m3", "deepseek-v4-pro"]
            if let picked = ModelPicker.pick(from: models, title: "PICKER TEST:") {
                print("PICKED: \(picked.joined(separator: ", "))")
            } else {
                print("PICKED: nil")
            }
            return 0

        case "parse":
            let text = inputText(from: remaining)
            do {
                let p = try Parser.parseWithFallback(text)
                print("""
                格式: \(p.format)
                名称: \(p.name ?? "-")
                URL:  \(p.url ?? "-")
                模型: \(p.model ?? "-")
                models: \(p.models?.joined(separator: ", ") ?? "-")
                key:  \(p.keyMasked)
                """)
                return 0
            } catch {
                AppLog.error("CLI parse error: \(error.localizedDescription)")
                print("解析失败: \(error.localizedDescription)")
                return 1
            }

        case "list":
            print(Core.shared.list(limit: 50))
            return 0

        case "delete", "rm":
            guard let target = remaining.first else {
                print("用法: KeyDrop --delete <历史ID前缀或内容片段>")
                return 2
            }
            do {
                print(try Core.shared.delete(entryIDPrefix: target))
                return 0
            } catch {
                AppLog.error("CLI delete error: \(error.localizedDescription)")
                print("删除失败: \(error.localizedDescription)")
                return 1
            }

        case "refresh":
            guard let target = remaining.first else {
                print("用法: KeyDrop --refresh <历史ID前缀>")
                return 2
            }
            do {
                let msg = try Core.shared.refreshModels(entryIDPrefix: target) { models in
                    ModelPicker.pick(from: models, title: "共 \(models.count) 个模型(空格勾选):") ?? models
                }
                print(msg)
                return 0
            } catch {
                AppLog.error("CLI refresh error: \(error.localizedDescription)")
                print("刷新失败: \(error.localizedDescription)")
                return 1
            }

        case "reimport":
            guard let target = remaining.first else {
                print("用法: KeyDrop --reimport <历史ID前缀>")
                return 2
            }
            do {
                print(try Core.shared.reimportToCC(entryIDPrefix: target))
                return 0
            } catch {
                AppLog.error("CLI reimport error: \(error.localizedDescription)")
                print("重新导入失败: \(error.localizedDescription)")
                return 1
            }

        case "edit":
            guard let target = remaining.first else {
                print("用法: KeyDrop --edit <历史ID前缀> [--model <模型1,模型2>] [--name <名称>] [--no-verify]")
                return 2
            }
            do {
                let msg = try Core.shared.editEntry(
                    entryIDPrefix: target,
                    models: modelsOverride.isEmpty ? nil : modelsOverride,
                    name: editName,
                    verify: !noVerify
                )
                print(msg)
                return 0
            } catch {
                AppLog.error("CLI edit error: \(error.localizedDescription)")
                print("编辑失败: \(error.localizedDescription)")
                return 1
            }

        case "self-heal":
            let msgs = Core.shared.selfHeal()
            if msgs.isEmpty { print("无需修复") } else { print(msgs.joined(separator: "\n")) }
            return 0

        case "status":
            print("cc-switch DB:  \(CCSwitchWriter.dbPath)")
            print("switch 设置:   \(CCSwitchWriter.switchSettingsPath)")
            print("claude 设置:   \(CCSwitchWriter.claudeSettingsPath)")
            print("cc-switch 运行中: \(CCSwitchWriter.ccSwitchRunning())")
            print("CPA 配置:      \(Core.shared.prefs.resolvedCPAConfig() ?? "未找到")")
            print(LLMParser.configSummary())
            let cc = CCSwitchWriter()
            if let cur = cc.readSwitchSettings()?["currentProviderClaude"] as? String {
                print("当前 provider (switch settings): \(cur)")
            }
            if let db = try? DB(path: CCSwitchWriter.dbPath),
               let row = try? db.query(
                   "SELECT id, name FROM providers WHERE app_type='claude' AND is_current=1 LIMIT 1"
               ).first, let id = row[0] {
                print("当前 provider (DB is_current):   \(id) \(row[1] ?? "")")
            }
            if let claude = cc.readClaudeSettings(),
               let env = claude["env"] as? [String: Any] {
                let token = (env["ANTHROPIC_AUTH_TOKEN"] as? String) ?? ""
                let masked = token.count > 10 ? String(token.prefix(6)) + "…" : token
                print("claude settings: \(env["ANTHROPIC_BASE_URL"] ?? "-") token=\(masked)")
            }
            return 0

        case "help", "h":
            print(helpText)
            return 0

        default:
            print("未知命令: \(cmd)\n")
            print(helpText)
            return 2
        }
    }

    private static func inputText(from args: [String]) -> String {
        guard !args.isEmpty else { return "" }
        if args.count == 1 {
            let value = args[0]
            if value == "-" {
                return String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
            }
            let expanded = NSString(string: value).expandingTildeInPath
            if FileManager.default.fileExists(atPath: expanded) {
                if let data = try? Data(contentsOf: URL(fileURLWithPath: expanded)),
                   let s = String(data: data, encoding: .utf8) {
                    return s
                }
            }
            return value
        }
        return args.joined(separator: " ")
    }

    static let helpText = """
    KeyDrop — 贴 key 即用
    用法:
      KeyDrop                        启动菜单栏小窗
      KeyDrop --add "<内容>"         解析→测试→选模型→添加(明文/base64/JSON/zip路径/文件路径/curl命令)
                                      [--cc|--no-cc] [--cpa|--no-cpa] [--cpa-config <path>]
                                       [--app claude|opencode|codex] [--model 名称1,名称2] [--force 跳过测试]
                                       [--proxy http://127.0.0.1:7890] (或环境变量 KEYDROP_PROXY)
      KeyDrop --parse "<内容>"       只看解析结果,不写入
      KeyDrop --list                 历史记录
      KeyDrop --delete <ID前缀|片段> 删除该条(自动还原/回退)
      KeyDrop --refresh <ID前缀>     重新测试并更新模型列表
      KeyDrop --status               查看当前状态
      KeyDrop --self-heal            检查并重建丢失的 cc-switch provider
    """
}
