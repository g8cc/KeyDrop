import Foundation

/// 版本号解析与比较:纯逻辑,供应用更新与测试共用
public enum Version {
    /// 从 GitHub releases/latest 的 302 重定向路径抠版本号:
    /// "/g8cc/KeyDrop/releases/tag/v1.4.24" → "1.4.24";非版本 tag 路径 → nil。
    /// 用于 API 限流(HTTP 403)时的兜底检查通道 —— 302 Location 不占 api.github.com 配额
    public static func fromTagPath(_ path: String) -> String? {
        guard let r = path.range(of: "/releases/tag/") else { return nil }
        var v = String(path[r.upperBound...])
        if v.hasPrefix("v") { v = String(v.dropFirst()) }
        guard let f = v.first, f.isNumber else { return nil }
        return v
    }

    /// 语义化版本比较:a > b → .orderedDescending;支持 v 前缀与多段数字(1.0.0.1),忽略 -后缀
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        func nums(_ s: String) -> [Int] {
            let core = s.lowercased().hasPrefix("v") ? String(s.dropFirst()) : s
            let parts = core.split(separator: "-").first?.split(separator: ".") ?? []
            // 不能用 compactMap { Int($0) }:数字溢出/非数字会被丢弃,造成段位错位
            // (如 [1] vs [1,5] 比出反向结果)。逐段安全解析,保留段位。
            return parts.map { part in
                let p = part.trimmingCharacters(in: .whitespaces)
                if p.isEmpty { return 0 }
                if p.allSatisfy({ $0.isNumber }) {
                    if let n = Int(p) { return n }
                    return Int.max   // 超长数字:视为极大,而不是丢弃
                }
                let digits = p.prefix(while: { $0.isNumber })
                return Int(digits) ?? 0
            }
        }
        let na = nums(a), nb = nums(b)
        for i in 0..<max(na.count, nb.count) {
            let va = i < na.count ? na[i] : 0
            let vb = i < nb.count ? nb[i] : 0
            if va != vb { return va > vb ? .orderedDescending : .orderedAscending }
        }
        return .orderedSame
    }

    /// 当前运行版本(Info.plist)
    public static func currentVersion() -> String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }
}