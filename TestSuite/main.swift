import Darwin
import KeyDropCore

let harness = Harness()

ParserTests.run(harness)
DSHWriterTests.run(harness)
APITesterTests.run(harness)
CCSwitchWriterTests.run(harness)
HistoryTests.run(harness)
CoreTests.run(harness)

print("────────────────────────────")
if harness.failures.isEmpty {
    print("全部通过: \(harness.passed) 断言")
    exit(0)
} else {
    print("失败 \(harness.failures.count) 个, 通过 \(harness.passed) 个")
    exit(1)
}
