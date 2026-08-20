import Foundation

/// 版本号解析与比较:纯逻辑,供应用更新与测试共用
public enum Version {
    /// 语义化版本比较:a > b → .orderedDescending;支持 v 前缀与多段数字(1.0.0.1),忽略 -后缀
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        func nums(_ s: String) -> [Int] {
            let core = s.lowercased().hasPrefix("v") ? String(s.dropFirst()) : s
            return core.split(separator: "-").first?.split(separator: ".").compactMap { Int($0) } ?? []
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