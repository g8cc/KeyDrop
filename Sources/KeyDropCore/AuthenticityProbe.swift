import Foundation
import CryptoKit

/// 模型真伪深度鉴定:能力阶梯探针。
///
/// 原理:中转站能伪造的(响应包装/usage/身份自述)全部不用作定罪;只测
/// 「长在权重里的能力」—— 推理阶梯(参数化题库,数字随机化,每次都是新题,
/// 答案程序精确比对)按模型层级标注区分度(旗舰题中端模型解不出)。
/// 实测层级 vs 声称层级不符 → 高概率模型替换。
public enum AuthenticityProbe {

    // MARK: - 题目与结果

    public struct Question {
        public let prompt: String
        public let expectedNumber: Int?    // 期望答案(数值精确比对)
        public let expectedName: String?   // 期望答案(人名,排名谜题)
        public let tier: Int               // 1=基础 2=中端 3=旗舰
        public let skill: String           // 数学/计数/逻辑

        public init(prompt: String, expectedNumber: Int, tier: Int, skill: String) {
            self.prompt = prompt; self.expectedNumber = expectedNumber
            self.expectedName = nil; self.tier = tier; self.skill = skill
        }

        public init(prompt: String, expectedName: String, tier: Int, skill: String) {
            self.prompt = prompt; self.expectedNumber = nil
            self.expectedName = expectedName; self.tier = tier; self.skill = skill
        }
    }

    public struct Report {
        public let verdict: String          // 旗舰级/中端级/基础级/异常
        public let claimedTier: Int?        // 按名称推断的声称层级(旗舰关键词 → 3)
        public let lines: [String]          // 逐题证据明细
    }

    // MARK: - 题库生成(每次鉴定随机实例化,无法背题)

    /// 字母计数用词(字母数无歧义,且属于公开的"模型易错"判别集)
    static let letterCases: [(word: String, letter: String, count: Int)] = [
        ("strawberry", "r", 3), ("success", "s", 3), ("possession", "s", 4),
        ("necessary", "s", 2), ("millennium", "l", 2), ("embarrass", "r", 2),
        ("accounting", "c", 2), ("occurrence", "c", 3),
    ]

    public static func generateLadder() -> [Question] {
        var qs: [Question] = []

        // T1 基础:两位数加法(任何真 LLM 都应通过;失败 = 网关/非模型响应)
        let a1 = Int.random(in: 23...97), b1 = Int.random(in: 14...86)
        qs.append(Question(prompt: "计算 \(a1) + \(b1),只返回数字结果。",
                           expectedNumber: a1 + b1, tier: 1, skill: "算术"))

        // T2 中端:三位数×两位数乘法 + 字母计数(经典易错判别)
        let m1 = Int.random(in: 112...987), m2 = Int.random(in: 23...89)
        qs.append(Question(prompt: "计算 \(m1) × \(m2),只返回数字结果。",
                           expectedNumber: m1 * m2, tier: 2, skill: "算术"))
        if let lc = letterCases.randomElement() {
            qs.append(Question(prompt: "单词 \(lc.word) 里有多少个字母 \(lc.letter)?只返回数字。",
                               expectedNumber: lc.count, tier: 2, skill: "字母计数"))
        }

        // T3 旗舰:三位数×三位数乘法(单步大数,无思维链易错)+ 四步混合运算 + 五人排名谜题
        let x1 = Int.random(in: 323...987), x2 = Int.random(in: 412...989)
        qs.append(Question(prompt: "计算 \(x1) × \(x2),只返回数字结果。",
                           expectedNumber: x1 * x2, tier: 3, skill: "算术"))
        let a = Int.random(in: 323...987), b = Int.random(in: 412...989)
        let c = Int.random(in: 112...899), d = Int.random(in: 23...97)
        let e = Int.random(in: 1500...9900)
        qs.append(Question(prompt: "计算 \(a) × \(b) + \(c) × \(d) − \(e) 的结果,只返回数字。",
                           expectedNumber: a * b + c * d - e, tier: 3, skill: "算术"))
        qs.append(contentsOf: rankingPuzzles())

        return qs
    }

    /// 五人排名谜题:从真实排列导出"全部为真"的两两名次约束,贪心加入直到
    /// 枚举 120 全排列恰好唯一解(= 约束构成唯一拓扑序)。答案 = 第一名人名;
    /// 推断需组合全部约束(链式传递),是真正的 deduction 题。
    static func rankingPuzzles() -> [Question] {
        let names = ["甲", "乙", "丙", "丁", "戊"]
        for _ in 0..<40 {
            var order = Array(0...4)
            order.shuffle()
            // 全部真事实(两两名次):order[i] 排在 order[j] 前(i<j 即前者名次更高)
            var allPairs: [(Int, Int)] = []
            for i in 0..<5 { for j in (i + 1)..<5 { allPairs.append((order[i], order[j])) } }

            func solutions(_ chosen: [(Int, Int)]) -> [[Int]] {
                var out: [[Int]] = []
                for cand in permutations(of: 5) {
                    var pos = [Int](repeating: 0, count: 5)
                    for (rank, person) in cand.enumerated() { pos[person] = rank }
                    if chosen.allSatisfy({ pos[$0.0] < pos[$0.1] }) { out.append(cand) }
                }
                return out
            }

            var chosen: [(Int, Int)] = []
            var sols = solutions(chosen)
            while sols.count > 1 {
                // 加入一条"当前多解中仍为真"的约束(消灭至少一对并列可能)
                var satisfiable = allPairs.filter { p in
                    sols.contains { cand in
                        var pos = [Int](repeating: 0, count: 5)
                        for (rank, person) in cand.enumerated() { pos[person] = rank }
                        return pos[p.0] < pos[p.1]
                    }
                }
                satisfiable.removeAll { c in chosen.contains { $0.0 == c.0 && $0.1 == c.1 } }
                guard let pick = satisfiable.first ?? satisfiable.randomElement() else { break }
                chosen.append(pick)
                sols = solutions(chosen)
            }
            guard sols.count == 1, sols[0] == order else { continue }

            let first = names[order[0]]
            let factText = chosen.map { "\(names[$0.0]) 比 \(names[$0.1]) 名次高" }.joined(separator: ";")
            let prompt = """
            甲乙丙丁戊五人比赛,名次满足:
            \(factText)。
            问:第一名是谁?只回答那个人的名字(一个字)。
            """
            return [Question(prompt: prompt, expectedName: first, tier: 3, skill: "逻辑")]
        }
        // 40 次都没凑出唯一解(概率极低):退化为四步混合运算
        let a = Int.random(in: 323...987), b = Int.random(in: 412...989)
        let c = Int.random(in: 112...899), d = Int.random(in: 23...97)
        return [Question(prompt: "计算 \(a) × \(b) + \(c) × \(d) − \(a + c) 的结果,只返回数字。",
                         expectedNumber: a * b + c * d - (a + c), tier: 3, skill: "算术")]
    }

    // MARK: - 回答判定

    /// 从模型回答中提取第一个整数(容忍千分位逗号/全角逗号/文字包裹)
    public static func firstNumber(in s: String) -> Int? {
        let cleaned = s.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "，", with: "")
        guard let r = cleaned.range(of: "[0-9]+", options: .regularExpression) else { return nil }
        return Int(cleaned[r])
    }

    public static func isCorrectResponse(_ response: String, expected: Int) -> Bool {
        firstNumber(in: response) == expected
    }

    /// 回答判定:数值题精确比对;人名题(排名谜题)提取显式结论句。
    /// 曾用「前 80 字符 contains」:答案名是单字(甲/乙/…),思维链复述题面约束时
    /// 前 80 字符几乎必然含全部五个人名,连错误结论都能判对,T3 形同虚设。
    /// 现优先匹配「第一名是/为 X」结论句(取最后一次出现),无结论句才退回
    /// 最后一个非空行(模型被要求只回答名字)
    public static func isCorrect(_ response: String, question: Question) -> Bool {
        if let name = question.expectedName {
            let ns = response as NSString
            if let re = try? NSRegularExpression(pattern: #"第一名[^甲乙丙丁戊]{0,6}([甲乙丙丁戊])"#) {
                let matches = re.matches(in: response, range: NSRange(location: 0, length: ns.length))
                if let last = matches.last, last.numberOfRanges >= 2,
                   last.range(at: 1).location != NSNotFound {
                    return ns.substring(with: last.range(at: 1)) == name
                }
            }
            let lastLine = response.split(whereSeparator: { $0.isNewline })
                .reversed().first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
            return lastLine.contains(name)
        }
        guard let expected = question.expectedNumber else { return false }
        return firstNumber(in: response) == expected
    }

    // MARK: - 探针执行

    /// 鉴定专用 session:旗舰模型的 T3 题(大数乘法/五人排名)常需 20-40s 长推理,
    /// 不能借用 APITester 的共享 session(timeoutIntervalForResource=20 是 session 级,
    /// 请求级 timeoutInterval=40 覆盖不了,慢模型每题在 ~20s 被杀 → 误判「中端级/替换」)
    private static func makeSession(proxy: String?, timeout: TimeInterval) -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = timeout
        c.timeoutIntervalForResource = timeout + 10
        c.httpMaximumConnectionsPerHost = 2
        c.connectionProxyDictionary = APITester.proxyDictionary(for: proxy ?? "") ?? [:]
        return URLSession(configuration: c)
    }

    /// 对指定模型跑能力阶梯,返回评测报告
    public static func run(base: String, key: String, model: String,
                           proxy: String?, timeout: TimeInterval = 40) -> Report {
        let questions = generateLadder()
        var tierStats: [Int: (pass: Int, total: Int)] = [:]
        var lines: [String] = []
        let session = makeSession(proxy: proxy, timeout: timeout)
        defer { session.finishTasksAndInvalidate() }

        for q in questions {
            let answer = chatContent(session: session, base: base, key: key, model: model,
                                     prompt: q.prompt, timeout: timeout)
            let ok = isCorrect(answer ?? "", question: q)
            let stat = tierStats[q.tier] ?? (0, 0)
            tierStats[q.tier] = (stat.pass + (ok ? 1 : 0), stat.total + 1)
            let shown = (answer ?? "无响应").prefix(60)
            lines.append("[T\(q.tier)/\(q.skill)] \(ok ? "✓" : "✗") 答:\(shown)")
        }

        func passed(_ tier: Int) -> Bool {
            guard let s = tierStats[tier] else { return false }
            return s.pass * 2 > s.total   // 过半才算通过
        }

        let t1 = passed(1), t2 = passed(2), t3 = passed(3)
        let verdict: String
        if !t1 { verdict = "异常:基础任务失败(网关异常或非模型响应)" }
        else if !t2 { verdict = "基础级" }
        else if !t3 { verdict = "中端级" }
        else { verdict = "旗舰级" }

        let claimed = claimedTier(model: model)
        var out: [String] = []
        out.append("实测能力层级: \(verdict)")
        if let claimed {
            let claimedName = claimed == 3 ? "旗舰级" : "中端级"
            out.append(claimed == 3 && verdict != "旗舰级"
                       ? "⚠ 实测能力低于声称的旗舰级 —— 高概率模型替换/降级"
                       : "✓ 与声称层级相符")
        }
        out.append(contentsOf: lines)
        return Report(verdict: verdict, claimedTier: claimed, lines: out)
    }

    /// 按名称推断声称层级(保守:只标明确的旗舰关键词,其余返回 nil 不比对)
    public static func claimedTier(model: String) -> Int? {
        let l = model.lowercased()
        let flagship = ["opus", "gpt-5", "gpt-6", "o1", "o3", "ultra", "gpt-4.5", "deepseek-r"]
        return flagship.contains(where: { l.contains($0) }) ? 3 : nil
    }

    // MARK: - chat 调用(返回 content 文本;openai 失败回退 anthropic /messages)

    static func chatContent(session: URLSession, base: String, key: String, model: String,
                            prompt: String, timeout: TimeInterval) -> String? {
        let hasV1 = base.hasSuffix("/v1") || base.hasSuffix("/api/v1")
        let s = session
        for path in hasV1 ? ["/chat/completions"] : ["/chat/completions", "/v1/chat/completions"] {
            guard let u = URL(string: base + path) else { continue }
            var req = URLRequest(url: u)
            req.httpMethod = "POST"
            req.timeoutInterval = timeout
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            req.httpBody = try? JSONSerialization.data(withJSONObject: [
                "model": model,
                "max_tokens": 600,
                "messages": [["role": "user", "content": prompt]]
            ])
            let o = NetSync.run(session: s, request: req, timeout: timeout)
            let status = NetSync.statusCode(o)
            let body = String(data: o.data ?? Data(), encoding: .utf8) ?? ""
            guard status == 200, !APITester.isHTMLBody(body) else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
                  let choices = obj["choices"] as? [[String: Any]] else { continue }
            if let msg = choices.first?["message"] as? [String: Any],
               let content = msg["content"] as? String, !content.isEmpty {
                return content
            }
        }
        // anthropic 协议回退(/v1/messages,x-api-key)
        for path in hasV1 ? ["/messages"] : ["/v1/messages"] {
            guard let u = URL(string: base + path) else { continue }
            var req = URLRequest(url: u)
            req.httpMethod = "POST"
            req.timeoutInterval = timeout
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            req.httpBody = try? JSONSerialization.data(withJSONObject: [
                "model": model,
                "max_tokens": 600,
                "messages": [["role": "user", "content": prompt]]
            ])
            let o = NetSync.run(session: s, request: req, timeout: timeout)
            let status = NetSync.statusCode(o)
            let body = String(data: o.data ?? Data(), encoding: .utf8) ?? ""
            guard status == 200, !APITester.isHTMLBody(body) else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
                  let contentArr = obj["content"] as? [[String: Any]] else { continue }
            let text = contentArr.compactMap { $0["text"] as? String }.joined()
            if !text.isEmpty { return text }
        }
        return nil
    }

    /// 排列枚举(验证排名谜题唯一解)
    static func permutations(of n: Int) -> [[Int]] {
        var result: [[Int]] = []
        func permute(_ arr: inout [Int], _ start: Int) {
            if start == arr.count { result.append(arr); return }
            for i in start..<arr.count {
                arr.swapAt(start, i)
                permute(&arr, start + 1)
                arr.swapAt(start, i)
            }
        }
        var base = Array(0..<n)
        permute(&base, 0)
        return result
    }
}
