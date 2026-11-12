import Foundation

/// 更新包清单校验(纯逻辑):Updater 与测试套件共用(同 Version.swift 的先例)。
public enum UpdatePackage {

    public struct ValidationError: LocalizedError {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    /// 解析 `unzip -l` 清单并做安装前安全校验(越界路径/顶层白名单/体积与数量上限)。
    /// 关键修复(2026-11-12):名称列必须 trim——unzip -l 的名称列带列对齐填充空格,
    /// split(maxSplits: 3) 预算耗尽后填充空格残留在名称里,顶层组件变成
    /// "  KeyDrop.app"(带空格)≠ "KeyDrop.app",v1.4.34 引入白名单起
    /// 任何真实更新包都通不过校验,自动更新用户全部被拒(真实事故:旧版升级报
    /// 「顶层含非预期内容: KeyDrop.ap…」)
    public static func validateListing(_ text: String) throws {
        var count = 0
        var totalSize = 0
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4,
                  parts[1].count == 10,
                  parts[2].contains(":"),
                  let size = Int(parts[0]), size >= 0 else { continue }
            let name = String(parts[3]).trimmingCharacters(in: .whitespaces)
            let normalized = name.replacingOccurrences(of: "\\", with: "/")
            let components = normalized.split(separator: "/", omittingEmptySubsequences: true)
            guard !normalized.hasPrefix("/"), !normalized.contains("\0"),
                  !components.contains(".."), let first = components.first else {
                throw ValidationError("更新包包含越界路径,已拒绝安装")
            }
            guard first == "KeyDrop.app" || first == "__MACOSX" || (components.count == 1 && first == ".DS_Store") else {
                throw ValidationError("更新包顶层含非预期内容,已拒绝安装: \(name)")
            }
            count += 1
            let (sum, overflow) = totalSize.addingReportingOverflow(size)
            guard !overflow, sum <= 150_000_000 else {
                throw ValidationError("更新包解压后超过 150MB,已拒绝安装")
            }
            totalSize = sum
            guard count <= 10_000 else {
                throw ValidationError("更新包文件数过多,已拒绝安装")
            }
        }
    }
}
