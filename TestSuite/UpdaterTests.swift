import Foundation
import KeyDropCore

enum UpdaterTests {
    static func run(_ h: Harness) {
        h.runSuite("Updater") { t in
            t.equal(Version.compare("1.0.1", "1.0.0"), .orderedDescending, "补丁版本升级")
            t.equal(Version.compare("1.0.0", "1.0.1"), .orderedAscending, "补丁版本降级")
            t.equal(Version.compare("1.1.0", "1.0.9"), .orderedDescending, "次版本优先")
            t.equal(Version.compare("v1.2.0", "1.1.9"), .orderedDescending, "v 前缀忽略")
            t.equal(Version.compare("2.0.0", "1.99.99"), .orderedDescending, "主版本")
            t.equal(Version.compare("1.0.0", "1.0.0"), .orderedSame, "相同")
            t.equal(Version.compare("1.0.0.1", "1.0.0"), .orderedDescending, "多段数字")
            t.equal(Version.compare("1.0.1-beta", "1.0.0"), .orderedDescending, "后缀忽略")
            // 修复:compactMap 会因溢出/非数字丢段造成错位
            t.equal(Version.compare("1.99999999999999999999", "1.5"), .orderedDescending,
                    "超长数字段视为极大,不因溢出丢弃")
            t.equal(Version.compare("1.foo.5", "1.2.0"), .orderedAscending, "非数字段按 0 保留段位")
            t.equal(Version.compare("1.2.0", "1.foo.5"), .orderedDescending, "非数字段比较对称")
        }
    }
}