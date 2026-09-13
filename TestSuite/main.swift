import Darwin
import KeyDropCore

// 测试全局隔离:必须在任何套件运行前关掉 LLM 回退。ParserTests 是第一个跑的套件,
// 且不像其它套件那样构造 TestEnv(TestEnv.init 才设 KEYDROP_LLM_PARSE=0),
// 于是 base64「可疑」用例会走 parseWithFallback 的 LLM 回退,真连本机 127.0.0.1:8317
// 的上游模型 —— 模型偶尔把 key 幻觉出一个多余字符,导致该用例约 50% 概率假失败
// (解码是确定性的,多出的字符只可能来自网络大模型)。测试绝不该依赖网络。
// 需要显式测 LLM 的用例可自行 setenv 打开;LLMParser.enabled 每次访问读 env,故此处生效。
setenv("KEYDROP_LLM_PARSE", "0", 1)

let harness = Harness()

ParserTests.run(harness)
DSHWriterTests.run(harness)
APITesterTests.run(harness)
CCSwitchWriterTests.run(harness)
UpdaterTests.run(harness)
ImageAPITests.run(harness)
GrokBuildWriterTests.run(harness)
HistoryTests.run(harness)
CoreTests.run(harness)
RegressionTests.run(harness)
ImportPipelineTests.run(harness)

print("────────────────────────────")
if harness.failures.isEmpty {
    print("全部通过: \(harness.passed) 断言")
    exit(0)
} else {
    print("失败 \(harness.failures.count) 个, 通过 \(harness.passed) 个")
    exit(1)
}
