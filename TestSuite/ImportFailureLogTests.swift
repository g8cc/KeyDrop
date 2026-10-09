import Foundation
import KeyDropCore

enum ImportFailureLogTests {
    static func run(_ harness: Harness) {
        harness.runSuite("导入错误日志.去重与隐私") { test in
            let environment = try TestEnv("import-failures")
            defer { environment.cleanup() }
            let core = Core()
            for _ in 0..<2 {
                do {
                    _ = try core.add(raw: "")
                    test.expect(false, "空输入必须失败")
                } catch {}
            }
            ImportFailureLog.record(ParseError.noKeyFound("private-input-123"), stage: "parse")
            ImportFailureLog.record(ParseError.io("HTTP 401 secret-a"), stage: "verify")
            ImportFailureLog.record(ParseError.io("HTTP 401 secret-b"), stage: "verify")
            ImportFailureLog.record(ParseError.io("已取消选择模型"), stage: "verify")
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let data = try Data(contentsOf: URL(fileURLWithPath: ImportFailureLog.path))
            let events = try decoder.decode([ImportFailureLog.Event].self, from: data)
            test.equal(events.count, 3, "不同类型分开,重复和取消不新增")
            test.equal(events.first { $0.reason == "empty_input" }?.count, 2, "Core 抛错自动累计")
            test.equal(events.first { $0.reason == "authentication_failed" }?.count, 2, "不同密钥同错误只存一次")
            let content = String(decoding: data, as: UTF8.self)
            test.expect(!content.contains("private-input") && !content.contains("secret-"), "不落盘原文或密钥")
            let attributes = try FileManager.default.attributesOfItem(atPath: ImportFailureLog.path)
            test.equal((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600, "文件仅属主可读写")
            DispatchQueue.concurrentPerform(iterations: 20) { _ in
                ImportFailureLog.record(ParseError.noURL, stage: "parse")
            }
            let concurrent = try decoder.decode([ImportFailureLog.Event].self,
                from: Data(contentsOf: URL(fileURLWithPath: ImportFailureLog.path)))
            test.equal(concurrent.first { $0.reason == "url_not_found" }?.count, 20, "并发不丢计数")
            try Data("broken-json".utf8).write(to: URL(fileURLWithPath: ImportFailureLog.path))
            ImportFailureLog.record(ParseError.emptyInput, stage: "parse")
            test.equal(try String(contentsOfFile: ImportFailureLog.path, encoding: .utf8), "broken-json", "损坏日志不静默覆盖")
        }
        harness.runSuite("导入错误日志.写入失败") { test in
            let environment = try TestEnv("import-failures-writer")
            defer { environment.cleanup() }
            let outcome = try Core().add(raw: "https://api.example.com/v1 sk-testfixture123456789",
                                         ccOverride: false, grokOverride: false,
                                         cpaOverride: true, dshOverride: false, force: true)
            test.expect(!outcome.ok, "未安装 CPA 返回失败结果")
            let text = try String(contentsOfFile: ImportFailureLog.path, encoding: .utf8)
            test.contains(text, "write_cpa", "不抛错的失败结果也记录")
        }
        harness.runSuite("导入错误日志.阶段归类") { test in
            test.equal(ImportFailureLog.stage(forLine: "✗ cc-switch 失败: 数据库锁住"),
                       "write_ccswitch", "cc-switch 失败归目标")
            test.equal(ImportFailureLog.stage(forLine: "✗ CPA: 未找到 config.yaml,跳过"),
                       "write_cpa", "CPA 跳过归目标")
            test.equal(ImportFailureLog.stage(forLine: "✗ Grok Build 失败: 权限不足"),
                       "write_grok", "Grok 失败归目标")
            test.equal(ImportFailureLog.stage(forLine: "✗ DeepSeek Harness 失败: refs 写坏"),
                       "write_dsh", "DSH 失败归目标")
            test.equal(ImportFailureLog.stage(forLine: "贴入模型均验证失败,改用站点模型目录(401)"),
                       "verify", "验证降级不得混进 write")
            test.equal(ImportFailureLog.stage(forLine: "模型验证: 3 个通过,2 个失败已跳过(429; 超时)"),
                       "verify", "部分模型失败归验证")
            test.equal(ImportFailureLog.stage(forLine: "⚠ 历史/偏好保存失败: 磁盘满"),
                       "save", "账本落盘失败单独归类")
            test.equal(ImportFailureLog.stage(forLine: "✗ 订阅拉取失败: HTTP 500"),
                       "write", "无法归目标时兜底")
            // 目标名优先:CPA 写入报错里带着模型验证文本,应仍算 CPA
            test.equal(ImportFailureLog.stage(forLine: "✗ CPA 失败: 贴入的 2 个模型均验证失败"),
                       "write_cpa", "目标归类先于验证")
        }
    }
}
