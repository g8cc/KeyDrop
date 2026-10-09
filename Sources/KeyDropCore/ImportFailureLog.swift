import Foundation
import Darwin

public enum ImportFailureLog {
    public struct Event: Codable {
        public let stage: String
        public let reason: String
        public var count: Int
        public let firstSeen: Date
        public var lastSeen: Date
    }

    public static var path: String {
        let home = ProcessInfo.processInfo.environment["KEYDROP_HOME"]
            ?? NSHomeDirectory() + "/.keydrop"
        return home + "/logs/import-failures.json"
    }

    private static let lock = NSLock()

    /// 导入结果行 → 阶段。先按目标归类,再认验证/保存,最后兜到 write:
    /// 「贴入模型均验证失败,改用站点模型目录」这类降级 note 若按目标名判会混进 write,
    /// 排查时看不出到底是写入挂了还是模型不通。
    public static func stage(forLine line: String) -> String {
        let targets: [(String, String)] = [
            ("cc-switch", "write_ccswitch"), ("Grok Build", "write_grok"),
            ("CPA", "write_cpa"), ("DeepSeek Harness", "write_dsh"), ("Clash", "write_clash")
        ]
        for (needle, stage) in targets where line.contains(needle) { return stage }
        if line.contains("验证失败") || line.contains("模型验证") { return "verify" }
        if line.contains("保存失败") { return "save" }
        return "write"
    }

    public static func record(_ error: Error, stage: String) {
        let message = error.localizedDescription
        guard !message.contains("已取消") else { return }
        var reason = "other"
        if let parsed = error as? ParseError {
            switch parsed {
            case .emptyInput: reason = "empty_input"
            case .noKeyFound: reason = "key_not_found"
            case .noURL: reason = "url_not_found"
            case .duplicate: reason = "duplicate_url_conflict"
            case .io: break
            }
        }
        if reason == "other" {
            let rules: [(String, [String])] = [
                ("input_too_large", ["内容过大", "输入过大"]),
                ("no_target", ["没有选中的目标"]),
                ("multikey_requires_cpa", ["多 key 仅支持"]),
                ("configuration_missing", ["未找到 config.yaml", "未找到本机 CPA"]),
                ("permission_denied", ["permission", "权限", "not permitted"]),
                ("authentication_failed", ["401", "403", "认证失败"]),
                ("rate_limited", ["429", "限流"]),
                ("quota_exhausted", ["402", "额度", "quota"]),
                ("timeout", ["超时", "timed out"]),
                ("network", ["连接", "network", "connect"]),
                ("model_validation_failed", ["模型均验证失败", "模型验证也失败"]),
                ("verification_failed", ["测试失败"])
            ]
            reason = rules.first { rule in
                rule.1.contains { message.lowercased().contains($0.lowercased()) }
            }?.0 ?? "other"
        }
        do { try save(reason: reason, stage: stage) }
        catch { AppLog.error("导入错误分类日志保存失败；请检查日志目录权限或文件格式") }
    }

    private static func save(reason: String, stage: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let destination = URL(fileURLWithPath: path)
        let directory = destination.deletingLastPathComponent()
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let descriptor = open(path + ".lock", O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.EACCES) }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            if errno != EINTR { throw POSIXError(.EIO) }
        }
        defer { flock(descriptor, LOCK_UN) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var events = manager.fileExists(atPath: path)
            ? try decoder.decode([Event].self, from: Data(contentsOf: destination)) : []
        let now = Date()
        if let index = events.firstIndex(where: { $0.stage == stage && $0.reason == reason }) {
            events[index].count += 1
            events[index].lastSeen = now
        } else {
            events.append(Event(stage: stage, reason: reason, count: 1, firstSeen: now, lastSeen: now))
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(events)
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".tmp")
        defer { try? manager.removeItem(at: temporary) }
        guard manager.createFile(atPath: temporary.path, contents: data,
                                 attributes: [.posixPermissions: 0o600]) else { throw POSIXError(.EIO) }
        guard rename(temporary.path, destination.path) == 0 else { throw POSIXError(.EIO) }
    }
}
