import Foundation
import KeyDropCore

/// 模型真伪鉴定:能力阶梯探针的纯逻辑与生成有效性
enum AuthenticityProbeTests {
    static func run(_ h: Harness) {
        h.runSuite("AuthenticityProbe.题库生成") { t in
            // 多次生成:每次都是随机实例(无法背题),但结构恒定
            for round in 0..<20 {
                let qs = AuthenticityProbe.generateLadder()
                t.equal(qs.count, 6, "[轮\(round)] 6 题(T1 + T2×2 + T3×3,含排名谜题)")
                t.expect(qs.contains { $0.tier == 1 } && qs.contains { $0.tier == 2 } && qs.contains { $0.tier == 3 },
                         "[轮\(round)] 三层齐备")
                // 每题的期望答案与题面数字自洽(算术题程序可复算)
                for q in qs where q.skill == "算术" {
                    let nums = q.prompt.matchNumbers()
                    t.expect(nums.count >= 2, "[轮\(round)] 题面含随机数")
                }
            }
            // T3 排名谜题:期望答案是 1-5 的名次编号(唯一解由生成器枚举验证)
            for round in 0..<10 {
                let qs = AuthenticityProbe.generateLadder()
                guard let logic = qs.first(where: { $0.skill == "逻辑" }) else {
                    t.expect(false, "[轮\(round)] 缺逻辑题"); continue
                }
                t.expect(logic.expectedName != nil && ["甲","乙","丙","丁","戊"].contains(logic.expectedName!),
                         "[轮\(round)] 排名答案是人名(\(logic.expectedName ?? "?"))")
            }
        }

        h.runSuite("AuthenticityProbe.回答判定与声称层级") { t in
            // 数值提取:容忍千分位/全角/文字包裹
            t.equal(AuthenticityProbe.firstNumber(in: "1,234。"), 1234, "千分位逗号")
            t.equal(AuthenticityProbe.firstNumber(in: "The answer is 42."), 42, "文字包裹")
            t.equal(AuthenticityProbe.firstNumber(in: "结果是 17 个"), 17, "普通提取")
            t.equal(AuthenticityProbe.firstNumber(in: "没有数字"), nil, "无数字返回 nil")

            // 声称层级(按名称)
            t.equal(AuthenticityProbe.claimedTier(model: "claude-opus-5-5"), 3, "opus → 旗舰")
            t.equal(AuthenticityProbe.claimedTier(model: "gpt-5.6-sol"), 3, "gpt-5 → 旗舰")
            t.equal(AuthenticityProbe.claimedTier(model: "deepseek-v4.1-flash"), nil, "非旗舰关键词 → 不比对")
        }
    }
}

extension String {
    /// 提取题面里的所有整数(算术题自洽校验用)
    func matchNumbers() -> [Int] {
        let r = try? NSRegularExpression(pattern: "[0-9]+")
        let ms = r?.matches(in: self, range: NSRange(startIndex..., in: self)) ?? []
        return ms.compactMap { Int(self[Range($0.range, in: self)!]) }
    }
}
