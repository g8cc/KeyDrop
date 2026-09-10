import Foundation
import Darwin

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
            // 日志可能含 key 片段,目录/文件权限收紧到仅属主可读写
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            if !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            // 必须用 O_APPEND:菜单栏 app 与 CLI 是两个进程,进程内 NSLock 管不到对方,
            // 旧实现 FileHandle + seekToEnd 会让两进程 seek 到同一 offset 互相覆盖丢行。
            let fd = open(file.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
            if fd >= 0 {
                defer { close(fd) }
                let bytes = Array(line.utf8)
                var off = 0
                while off < bytes.count {
                    let w = bytes.withUnsafeBytes { raw -> Int in
                        guard let base = raw.baseAddress else { return 0 }
                        return Darwin.write(fd, base.advanced(by: off), bytes.count - off)
                    }
                    if w <= 0 { break }
                    off += w
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
            out = out.replacingOccurrences(of: "\u{0}URL\(i + 1)\u{0}", with: maskURLSecrets(u))
        }
        return out
    }

    /// URL 里的凭据不能因为「整段是 URL」就原样还原:
    /// ?api_key=/&token= 查询参数、以及 https://user:pass@host 的 userinfo 都要遮。
    private static let urlQuerySecretRegex = try! NSRegularExpression(
        pattern: #"(?i)([?&](?:api[_-]?key|apikey|key|token|access_token|auth|password|secret)=)[^&\s"']+"#)
    private static let urlUserInfoRegex = try! NSRegularExpression(pattern: #"://[^/@\s"']+@"#)

    private static func maskURLSecrets(_ u: String) -> String {
        var s = u
        let ns = s as NSString
        s = urlQuerySecretRegex.stringByReplacingMatches(
            in: s, range: NSRange(location: 0, length: ns.length), withTemplate: "$1***")
        let ns2 = s as NSString
        s = urlUserInfoRegex.stringByReplacingMatches(
            in: s, range: NSRange(location: 0, length: ns2.length), withTemplate: "://***@")
        return s
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
            // 只截断疑似密钥的 token。旧实现一律截 12 字符会破坏路径/模型名;
            // 但阈值只按长度 ≥24 会漏掉 16–23 字符的合法 key(key 判定门槛是 16)。
            // 因此长 token 一律截断,短 token 仅当它长得像 key(如 sk-…/gsk_…/nvapi-…)且不含 /
            // 时才截断,兼顾日志可读性与密钥不外泄。
            let looksLikeKey = tok.count >= 16 && !tok.contains("/") && Parser.looksLikeKey(tok)
            if tok.count >= 24 || looksLikeKey {
                out += String(tok.prefix(12)) + "…(\(tok.count)ch)"
            } else {
                out += tok
            }
            pos = r.location + r.length
        }
        if pos < ns.length {
            out += ns.substring(from: pos)
        }
        return out
    }

    /// (timestamp 已并入 write 锁内,见 tsFormatter)
}