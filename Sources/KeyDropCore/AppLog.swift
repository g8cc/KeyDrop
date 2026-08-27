import Foundation

public enum AppLog {

    static let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/KeyDrop", isDirectory: true)
    static let file = dir.appendingPathComponent("keydrop.log")
    static let maxBytes: Int64 = 2 * 1024 * 1024
    static let maxFiles = 5

    private static let lock = NSLock()
    private static let tokenRegex = try! NSRegularExpression(pattern: #"[A-Za-z0-9+/_\-.]{6,}"#)

    /// 热路径复用:每次写日志新建一个 DateFormatter 开销很大。
    /// 本 formatter 只会在 write() 的锁内被触达,序列化访问是安全的。
    private static let tsFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    public static func info(_ msg: String) { write("INFO", msg) }
    public static func warn(_ msg: String) { write("WARN", msg) }
    public static func error(_ msg: String) { write("ERROR", msg) }

    static func write(_ level: String, _ msg: String) {
        let safe = maskSecrets(msg)
            .replacingOccurrences(of: "\n", with: " ⏎ ")
        lock.lock()
        defer { lock.unlock() }
        // timestamp 在锁内生成(共用锁内串行访问的 formatter)
        let line = "\(tsFormatter.string(from: Date())) [\(level)] \(safe)\n"
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(atPath: file.path, contents: nil)
            }
            if let fh = FileHandle(forWritingAtPath: file.path) {
                defer { try? fh.close() }
                do {
                    try fh.seekToEnd()
                    // 用 throwing 全量写:旧 write(_:) 是部分写语义,磁盘异常时静默丢行
                    try fh.write(contentsOf: Data(line.utf8))
                } catch {
                    NSLog("AppLog write body failed: \(error)")
                }
            }
            rotateIfNeeded()
        } catch {
            NSLog("AppLog write failed: \(error)")
        }
    }

    private static func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = attrs[.size] as? Int64,
              size >= maxBytes
        else { return }
        let oldest = dir.appendingPathComponent("keydrop.log.\(maxFiles)")
        try? FileManager.default.removeItem(at: oldest)
        if maxFiles > 1 {
            for i in stride(from: maxFiles - 1, through: 1, by: -1) {
                let src = dir.appendingPathComponent("keydrop.log.\(i)")
                if FileManager.default.fileExists(atPath: src.path) {
                    try? FileManager.default.moveItem(at: src, to: dir.appendingPathComponent("keydrop.log.\(i + 1)"))
                }
            }
        }
        try? FileManager.default.moveItem(at: file, to: dir.appendingPathComponent("keydrop.log.1"))
        FileManager.default.createFile(atPath: file.path, contents: nil)
    }

    /// 长令牌/密钥截断为前 12 字符 + …,URL 与短串不受影响
    private static func maskSecrets(_ s: String) -> String {
        let ns = s as NSString
        let range = NSRange(location: 0, length: ns.length)
        // 先占位 URL,避免路径/主机被误遮
        let urlRegex = try! NSRegularExpression(pattern: #"https?://[^\s"']+"#)
        var t = ""
        var pos = 0
        var urls: [String] = []
        for m in urlRegex.matches(in: s, range: range) {
            let r = m.range
            if r.location > pos {
                t += ns.substring(with: NSRange(location: pos, length: r.location - pos))
            }
            urls.append(ns.substring(with: r))
            t += "\u{0}URL\(urls.count)\u{0}"
            pos = r.location + r.length
        }
        if pos < ns.length { t += ns.substring(from: pos) }

        var out = maskTokens(t)
        for (i, u) in urls.enumerated() {
            out = out.replacingOccurrences(of: "\u{0}URL\(i + 1)\u{0}", with: u)
        }
        return out
    }

    private static func maskTokens(_ s: String) -> String {
        let ns = s as NSString
        let range = NSRange(location: 0, length: ns.length)
        let matches = tokenRegex.matches(in: s, range: range)
        guard !matches.isEmpty else { return s }
        var out = ""
        var pos = 0
        for m in matches {
            let r = m.range
            if r.location > pos {
                out += ns.substring(with: NSRange(location: pos, length: r.location - pos))
            }
            let tok = ns.substring(with: r)
            out += String(tok.prefix(12)) + "…"
            pos = r.location + r.length
        }
        if pos < ns.length {
            out += ns.substring(from: pos)
        }
        return out
    }

    /// (timestamp 已并入 write 锁内,见 tsFormatter)
}