import Foundation
import KeyDropCore

/// 零依赖测试断言 + 结果收集(CLT 工具链无 XCTest/Testing)
final class Harness {
    struct Failure {
        let file: String
        let line: Int
        let msg: String
    }

    private(set) var passed = 0
    private(set) var failures: [Failure] = []
    var suiteName = ""

    func expect(_ cond: Bool, _ msg: String, file: String = #file, line: Int = #line) {
        if cond {
            passed += 1
        } else {
            failures.append(Failure(file: (file as NSString).lastPathComponent, line: line, msg: msg))
        }
    }

    func equal<T: Equatable>(_ a: T, _ b: T, _ msg: String = "", file: String = #file, line: Int = #line) {
        expect(a == b, msg.isEmpty ? "\(a) != \(b)" : "\(msg): \(a) != \(b)", file: file, line: line)
    }

    func notNil<T>(_ v: T?, _ msg: String = "", file: String = #file, line: Int = #line) -> T? {
        expect(v != nil, msg.isEmpty ? "期望非 nil" : msg, file: file, line: line)
        return v
    }

    func contains(_ haystack: String, _ needle: String, _ msg: String = "", file: String = #file, line: Int = #line) {
        expect(haystack.contains(needle), msg.isEmpty ? "「\(needle)」不在「\(haystack)」中" : msg, file: file, line: line)
    }

    func runSuite(_ name: String, _ body: (Harness) -> Void) {
        let h = Harness()
        h.suiteName = name
        body(h)
        passed += h.passed
        for f in h.failures {
            failures.append(Failure(file: f.file, line: f.line, msg: "\(name): \(f.msg)"))
        }
        if h.failures.isEmpty {
            print("✓ \(name) (\(h.passed) 断言)")
        } else {
            print("✗ \(name): \(h.failures.count) 失败")
            for f in h.failures {
                print("    \(f.file):\(f.line) \(f.msg)")
            }
        }
    }
}

/// 隔离测试环境:把 KeyDrop 所有文件/DB 路径指向临时目录
final class TestEnv {
    let dir: String
    init(_ name: String = UUID().uuidString.prefix(8).description) throws {
        dir = NSTemporaryDirectory() + "KeyDropTests-" + name
        try? FileManager.default.removeItem(atPath: dir)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        setenv("KEYDROP_HOME", dir + "/home", 1)
        setenv("KEYDROP_CC_DB", dir + "/cc-switch.db", 1)
        setenv("KEYDROP_CC_SETTINGS", dir + "/settings.json", 1)
        setenv("KEYDROP_OPENCODE_CONFIG", dir + "/opencode.json", 1)
        setenv("KEYDROP_CLAUDE_SETTINGS", dir + "/claude.json", 1)
        setenv("KEYDROP_CODEX_CONFIG", dir + "/codex.toml", 1)
        setenv("KEYDROP_CODEX_AUTH", dir + "/codex-auth.json", 1)
        setenv("KEYDROP_DSH_SETTINGS", dir + "/dsh.yaml", 1)
        setenv("KEYDROP_DSH_CREDENTIALS", dir + "/dsh-creds.yaml", 1)
        setenv("KEYDROP_FAKE_CC_RUNNING", "1", 1)
        setenv("KEYDROP_PROXY", "", 1)
    }

    func read(_ path: String) -> String {
        (try? String(contentsOfFile: dir + "/" + path, encoding: .utf8)) ?? ""
    }

    func write(_ path: String, _ content: String) {
        try! content.write(toFile: dir + "/" + path, atomically: true, encoding: .utf8)
    }

    func fileExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: dir + "/" + path)
    }

    func cleanup() {
        try? FileManager.default.removeItem(atPath: dir)
    }

    deinit { cleanup() }
}
