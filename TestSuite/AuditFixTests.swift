import Foundation
import KeyDropCore

/// 深度审计修复的回归测试(2026-11 审计批次):
/// 每个用例对应一个真实修复点,防止同类回归。
enum AuditFixTests {
    static func run(_ h: Harness) {

        // P1:HistoryEntry.encode 曾漏掉 deletedAt/updatedAt/verifyVerdict 三个字段
        // —— 能解码但永不落盘:LWW 同步失效(远端恒 0)、墓碑计龄回退、鉴定结论重启即丢
        h.runSuite("Audit.History encode 三字段落盘") { t in
            var e = HistoryEntry(
                id: "encode-0001-1111-2222-333333333333", ts: 1000, raw: "raw-content",
                format: "single", name: "n", url: "https://x.example/v1", model: nil,
                models: nil, key: "sk-abcdef123456", keyMasked: "sk-a…",
                targets: ["cpa"], ccProviderID: nil, ccRenamedFrom: nil,
                ccRenamedTo: nil, cpaConfigPath: nil, status: "deleted"
            )
            e.deletedAt = 1234.5
            e.updatedAt = 5678.5
            e.verifyVerdict = "中端级"
            struct Wrapper: Codable { var items: [HistoryEntry] }
            let data = try! JSONEncoder().encode(Wrapper(items: [e]))
            let back = try! JSONDecoder().decode(Wrapper.self, from: data).items[0]
            t.equal(back.deletedAt, 1234.5, "deletedAt 落盘")
            t.equal(back.updatedAt, 5678.5, "updatedAt 落盘(LWW 依据)")
            t.equal(back.verifyVerdict, "中端级", "verifyVerdict 落盘")
            // 原始 JSON 里必须真的有这三个键(不是内存对象相等假象)
            let obj = try! JSONSerialization.jsonObject(with: data) as? [String: Any]
            let item = (obj?["items"] as? [[String: Any]])?.first
            t.notNil(item?["deletedAt"], "JSON 含 deletedAt 键")
            t.notNil(item?["updatedAt"], "JSON 含 updatedAt 键")
            t.notNil(item?["verifyVerdict"], "JSON 含 verifyVerdict 键")
        }

        // P1:--force + 同 key 不同 URL 曾把新 URL 静默丢弃(appendDedupByKey 按 key
        // 命中旧条目 → 回滚刚写的产物、保留旧 URL)。修复后 force = 覆盖旧条目
        h.runSuite("Audit.force 覆盖同 key 异 URL") { t in
            let env = try! TestEnv("audit-force-url")
            defer { env.cleanup() }
            let core = Core()
            guard let srv = try? MockHTTPServer(mode: .openAI) else {
                t.expect(false, "mock 启动失败"); return
            }
            env.write("cpa-config.yaml", "port: 18317\n")
            let oldURL = "http://127.0.0.1:\(srv.port)/v1"
            let newURL = "http://127.0.0.1:\(srv.port)/openai/v1"
            let seeded = HistoryEntry(
                id: "force-0001-1111-2222-333333333333", ts: 1,
                raw: "\(oldURL)\nsk-force-test-key-000001", format: "multiline",
                name: "old", url: oldURL, model: nil, models: nil,
                key: "sk-force-test-key-000001", keyMasked: "sk-f…", targets: [],
                ccProviderID: nil, ccRenamedFrom: nil, ccRenamedTo: nil,
                cpaConfigPath: env.dir + "/cpa-config.yaml", status: "active"
            )
            try! core.history.append(seeded)
            let outcome = try! core.add(
                raw: "\(newURL)\nsk-force-test-key-000001",
                ccOverride: false, grokOverride: false, cpaOverride: true,
                dshOverride: false, force: true)
            t.expect(outcome.ok, "force 导入成功: \(outcome.lines.joined(separator: " | "))")
            t.equal(outcome.entry.id, seeded.id, "覆盖原条目而非新建/合并")
            t.equal(outcome.entry.url, newURL, "URL 更新为新值(修复前保留旧 URL)")
            let actives = core.history.snapshot().filter {
                $0.status == "active" && $0.key == "sk-force-test-key-000001"
            }
            t.equal(actives.count, 1, "同 key 仍只有一条记录")
        }

        // P1:聚合条目没有 api-key-entities: 段(用户手写的精简形态)时新 key 曾被
        // 静默丢弃却报告成功;修复后在条目末尾补建该段再插入
        h.runSuite("Audit.CPA 聚合条目缺 api-key-entries 补建") { t in
            let env = try! TestEnv("audit-cpa-nokeys")
            defer { env.cleanup() }
            let core = Core()
            guard let srv = try? MockHTTPServer(mode: .openAI) else {
                t.expect(false, "mock 启动失败"); return
            }
            let base = "http://127.0.0.1:\(srv.port)/v1"
            env.write("cpa-config.yaml",
            """
            port: 18317

            openai-compatibility:
              - name: 127.0.0.1:\(srv.port)
                base-url: "\(base)"
                models:
                  - name: seedmodel1
                    alias: ""
            """)
            let outcome = try! core.add(
                raw: "\(base) nvapi-aaa111bbb222ccc333ddd111 nvapi-eee444fff555ggg666hhh222",
                ccOverride: false, cpaOverride: true, dshOverride: false, force: true)
            t.expect(outcome.ok, "导入成功: \(outcome.lines.joined(separator: " | "))")
            let cfg = env.read("cpa-config.yaml")
            t.contains(cfg, "api-key-entries:", "缺失段已补建")
            t.contains(cfg, "nvapi-aaa111bbb222ccc333ddd111", "新 key 1 落盘(修复前静默丢弃)")
            t.contains(cfg, "nvapi-eee444fff555ggg666hhh222", "新 key 2 落盘")
            t.contains(cfg, "seedmodel1", "既有 models 保留")
            // 补建段必须缩进在条目内,不得顶格损坏 YAML
            for ln in cfg.components(separatedBy: "\n") where ln.contains("nvapi-aaa111") {
                t.expect(ln.hasPrefix("      - api-key:"), "补建 key 正确缩进: \(ln)")
            }
            let y = Process()
            y.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            y.arguments = ["-c", "import yaml; yaml.safe_load(open('\(env.dir)/cpa-config.yaml'))"]
            try? y.run(); y.waitUntilExit()
            t.expect(y.terminationStatus == 0, "补建后 YAML 合法")
        }

        // P1:同 host 不同 path 的两个上游曾是同一个条目名(host:port),第二批 key
        // 被挂到第一批的 base-url 上轮询(静默路由错端点);修复后按 base-url 分条目
        h.runSuite("Audit.CPA 同 host 异 path 分条目") { t in
            let env = try! TestEnv("audit-cpa-crosspath")
            defer { env.cleanup() }
            let core = Core()
            guard let srv = try? MockHTTPServer(mode: .openAI) else {
                t.expect(false, "mock 启动失败"); return
            }
            let azureBase = "http://127.0.0.1:\(srv.port)/azure/v1"
            env.write("cpa-config.yaml",
            """
            port: 18317

            openai-compatibility:
              - name: 127.0.0.1:\(srv.port)
                base-url: "\(azureBase)"
                api-key-entries:
                  - api-key: nvapi-azure-seed-0000000001
                models:
                  - name: seedmodel1
                    alias: ""
            """)
            let openaiBase = "http://127.0.0.1:\(srv.port)/openai/v1"
            let outcome = try! core.add(
                raw: "\(openaiBase) nvapi-openai-key-00000000002",
                ccOverride: false, cpaOverride: true, dshOverride: false, force: true)
            t.expect(outcome.ok, "导入成功: \(outcome.lines.joined(separator: " | "))")
            let cfg = env.read("cpa-config.yaml")
            t.contains(cfg, "base-url: \"\(azureBase)\"", "第一批 base-url 原样保留")
            t.contains(cfg, "base-url: \"\(openaiBase)\"", "第二批 base-url 独立落盘")
            t.contains(cfg, "nvapi-azure-seed-0000000001", "第一批 key 不受影响")
            t.contains(cfg, "nvapi-openai-key-00000000002", "第二批 key 落盘")
            // 新条目 name 必须与既有条目可区分(host 名被不同 base-url 占用时派生后缀)。
            // 条目级 name 行固定 2 空格缩进(条目内 models 子项在 6 空格,不会混入)
            let nameLines = cfg.components(separatedBy: "\n").filter { $0.hasPrefix("  - name:") }
            t.equal(nameLines.count, 2, "两个独立条目: \(nameLines)")
            t.contains(cfg, "-2", "name 已派生去重后缀(基名被不同 base-url 占用)")
            let y = Process()
            y.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            y.arguments = ["-c", "import yaml; yaml.safe_load(open('\(env.dir)/cpa-config.yaml'))"]
            try? y.run(); y.waitUntilExit()
            t.expect(y.terminationStatus == 0, "YAML 合法")
        }

        // P1:codex 顶层 model 行曾按 "model = "(带空格)前缀匹配,`model="x"`
        // 不命中 → 原行保留 + 补插,config.toml 出现两个 model 键,codex 拒启
        h.runSuite("Audit.codex 无空格 model 行不重复") { t in
            let env = try! TestEnv("audit-codex-tight")
            defer { env.cleanup() }
            try! CCSwitchWriterTests.createSchema(env)
            env.write("codex.toml",
            """
            model_provider="custom"
            model="gpt-5"
            model_reasoning_effort = "high"

            [model_providers.custom]
            name = "custom"
            wire_api = "responses"
            requires_openai_auth = true
            base_url = "https://old-gateway/v1"
            experimental_bearer_token = "sk-old-token-000001"
            """)
            let w = CCSwitchWriter()
            var p = ParsedKey()
            p.key = "sk-new-token-0000002"
            p.url = "https://new-gateway.example/v1"
            _ = try! w.add(p, appType: "codex", models: ["gpt-5.6-sol"], proxy: nil)
            let cfg = env.read("codex.toml")
            let modelLines = cfg.components(separatedBy: "\n").filter {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("model=")
                    || $0.trimmingCharacters(in: .whitespaces).hasPrefix("model =")
            }
            t.equal(modelLines.count, 1, "model 键唯一(修复前出现两个): \(modelLines)")
            t.contains(cfg, "gpt-5.6-sol", "激活模型更新")
            t.contains(cfg, "base_url = \"https://new-gateway.example/v1\"", "base_url 更新")
        }

        // P2:codex custom 段缺失 base_url/wire_api/bearer 时曾永不补写
        // (merge 只「存在才替换」),DB 已更新而 live 缺键
        h.runSuite("Audit.codex custom 段缺失键补写") { t in
            let env = try! TestEnv("audit-codex-sparse")
            defer { env.cleanup() }
            try! CCSwitchWriterTests.createSchema(env)
            // 手写精简段:只有 name + env_key,缺 base_url/wire_api/bearer
            env.write("codex.toml",
            """
            model_provider = "custom"

            [model_providers.custom]
            name = "custom"
            env_key = "OPENAI_API_KEY"
            """)
            let w = CCSwitchWriter()
            var p = ParsedKey()
            p.key = "sk-backfill-key-000001"
            p.url = "https://sparse-gateway.example/v1"
            _ = try! w.add(p, appType: "codex", models: ["gpt-5.6-sol"], proxy: nil)
            let cfg = env.read("codex.toml")
            t.contains(cfg, "base_url = \"https://sparse-gateway.example/v1\"", "缺失 base_url 已补写")
            t.contains(cfg, "wire_api = \"responses\"", "缺失 wire_api 已补写")
            t.contains(cfg, "experimental_bearer_token = \"sk-backfill-key-000001\"", "缺失 bearer 已补写")
            t.contains(cfg, "requires_openai_auth = true", "缺失 auth 行已补写")
        }

        // P2:ClashWriter 曾不去重节点名,mihomo 对重复 proxy name 拒载整个订阅
        h.runSuite("Audit.Clash 同名节点去重") { t in
            let env = try! TestEnv("audit-clash-dup")
            defer { env.cleanup() }
            let proxies = [
                ClashProxy(name: "香港 01", type: "trojan", server: "a.example.com", port: 443, uuid: "pw-a", sni: "a.example.com"),
                ClashProxy(name: "香港 01", type: "trojan", server: "b.example.com", port: 443, uuid: "pw-b", sni: "b.example.com"),
            ]
            let (msg, fileName) = try! Core.addClashProxies(proxies)
            t.contains(msg, "2 个节点", "两个节点都写入")
            let yaml = env.read("clash-profiles/" + (fileName ?? ""))
            t.expect(yaml.components(separatedBy: "- name: \"香港 01\"\n").count - 1 == 1,
                     "重名节点已加后缀区分")
            t.contains(yaml, "香港 01 2", "第二个节点带序号后缀")
            // proxy-groups 引用的名字必须与 proxies 段一致(否则组引用悬空)
            let groups = yaml.components(separatedBy: "proxies: [").last ?? ""
            t.contains(groups, "香港 01 2", "proxy-groups 引用去重后名字")
            let y = Process()
            y.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            y.arguments = ["-c", "import yaml,sys; d=yaml.safe_load(open('\(env.dir)/clash-profiles/\(fileName ?? "")')); sys.exit(0 if len({p['name'] for p in d['proxies']})==2 else 1)"]
            try? y.run(); y.waitUntilExit()
            t.expect(y.terminationStatus == 0, "YAML 中节点名唯一 | yaml=\(yaml)")
        }

        // P2:yamlScalar 曾放行纯数字/bool/null 形态,裸写落地成 int/bool 节点,
        // 消费方(Go yaml.v3)反序列化进 string 字段直接拒载配置
        h.runSuite("Audit.YAML 标量歧义类型加引号") { t in
            t.equal(DSHWriter.yamlScalar("1234567890"), "\"1234567890\"", "纯数字加引号")
            t.equal(DSHWriter.yamlScalar("007"), "\"007\"", "前导零加引号(八进制歧义)")
            t.equal(DSHWriter.yamlScalar("true"), "\"true\"", "bool 词加引号")
            t.equal(DSHWriter.yamlScalar("null"), "\"null\"", "null 词加引号")
            t.equal(DSHWriter.yamlScalar("1.5e3"), "\"1.5e3\"", "科学计数加引号")
            t.equal(DSHWriter.yamlScalar("sk-abcdef123456"), "sk-abcdef123456", "普通 key 保持裸写")
            t.equal(DSHWriter.yamlScalar("https://a.example.com/v1"), "https://a.example.com/v1", "URL 保持裸写")
        }

        // P2:探测顺序激活模型置顶曾两分支口径不一 + 大小写敏感(大小写差异漏探)
        h.runSuite("Audit.chatProbeOrder 大小写不敏感置顶") { t in
            let models = ["GPT-5.6-SOL", "other-a", "other-b", "other-c"]
            let r = APITester.chatProbeOrder(models, preferred: "gpt-5.6-sol")
            t.equal(r.first, "GPT-5.6-SOL", "激活模型大小写不敏感命中并置顶(目录原拼写)")
            // 不在目录:回落原序(既有回归约定保持不变)
            let r2 = APITester.chatProbeOrder(["a", "b"], preferred: "not-in-list")
            t.equal(r2.first, "a", "不在目录仍回落原序")
            // 轮换分支同口径:不在目录不置顶
            let big = (1...10).map { "m\($0)" }
            let times = Dictionary(uniqueKeysWithValues: big.map { ($0, 100.0) })
            let r3 = APITester.chatProbeOrder(big, preferred: "absent", modelProbeTimes: times)
            t.expect(!r3.contains("absent"), "轮换分支不在目录不置顶(修复前无条件探)")
            t.equal(r3.count, 4, "轮换仍只探 4 个")
        }

        // P2:真伪鉴定人名题判定曾用「前 80 字符 contains」——单字答案名使
        // 思维链复述题面即判对,连错误结论都能过
        h.runSuite("Audit.鉴定人名题按末行判定") { t in
            let q = AuthenticityProbe.Question(prompt: "p", expectedName: "乙", tier: 3, skill: "逻辑")
            t.expect(AuthenticityProbe.isCorrect("根据甲比乙名次高……所以第一名是乙", question: q),
                     "末行含答案判对")
            t.expect(!AuthenticityProbe.isCorrect("根据甲比乙名次高,乙比丙名次高……综上第一名是丙", question: q),
                     "复述约束但结论错误判错(修复前前 80 字符 contains 乙 会判对)")
            t.expect(AuthenticityProbe.isCorrect("乙", question: q), "裸答案判对")
            let numQ = AuthenticityProbe.Question(prompt: "p", expectedNumber: 42, tier: 1, skill: "算术")
            t.expect(AuthenticityProbe.isCorrect("答案是 42。", question: numQ), "数值题判定不变")
        }

        // 用户真实事故(2026-11-04):粘贴「tokenhub.icu/v1 + key」两行,裸域名带路径
        // 的 URL 因 /v1 不在 hostname 字符集内被漏判,Core.add 静默复用历史旧 URL,
        // 新 key 被拿去测别的站 → 401「Invalid API key」,报错也看不出复用了谁
        h.runSuite("Audit.裸域名带路径 URL 识别(tokenhub 事故)") { t in
            // 与事故完全相同的输入形态(key 用同形状假值,不入库真实凭据)
            let raw = "tokenhub.icu/v1\nsk-VaC9RcZ9dBvFyxVeFtZ1BPotpRnNjJpqpN7NDSi7OhbwHgdn"
            let p = try! Parser.parse(raw)
            t.equal(p.url, "https://tokenhub.icu/v1", "裸域名/路径被识别为 URL(修复前 nil → 复用旧 URL)")
            t.equal(p.key, "sk-VaC9RcZ9dBvFyxVeFtZ1BPotpRnNjJpqpN7NDSi7OhbwHgdn", "key 不受影响")

            // looksLikeURL 形态矩阵
            t.expect(Parser.looksLikeURL("tokenhub.icu/v1"), "裸域名/路径")
            t.expect(Parser.looksLikeURL("gw.example.com:8317/v1"), "裸域名:端口/路径")
            t.expect(Parser.looksLikeURL("example.com"), "裸域名(回归不变)")
            t.expect(Parser.looksLikeURL("deepseek.com/v1"), "家族词+点域名仍是 URL")
            t.expect(!Parser.looksLikeURL("z-ai/glm-5.3-free"), "斜杠模型名(host 无点)不是 URL")
            t.expect(!Parser.looksLikeURL("o3.5/x"), "点分版本模型+斜杠不是 URL")
            t.expect(!Parser.looksLikeURL("qwen3.8-flash"), "带点模型名(回归不变)")

            // 防呆判定:像域名的 token 被识别;key/JWT(含点)/模型名不算
            t.equal(Parser.firstDomainLikeToken(raw), "tokenhub.icu/v1", "防呆:漏判时能找到疑似 URL token")
            t.equal(Parser.firstDomainLikeToken("sk-abcdef123456"), nil, "纯 key 不算域名")
            t.equal(Parser.firstDomainLikeToken("z-ai/glm-5.3-free sk-abcdef123456"), nil, "模型名不算域名")
            let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJVadQssw5c"
            t.equal(Parser.firstDomainLikeToken(jwt), nil, "JWT(三段含点)不算域名")
            t.equal(Parser.firstDomainLikeToken("https://ok.example.com/v1 sk-abcdef123456"), nil, "URL 已被正常识别时不算漏判")
        }

        // Core.add 防呆:URL 漏判且输入含域名形 token 时,绝不能静默复用上次记录
        h.runSuite("Audit.URL 漏判时禁止静默复用旧 URL") { t in
            let env = try! TestEnv("audit-url-noreuse")
            defer { env.cleanup() }
            let core = Core()
            let stale = HistoryEntry(
                id: "noreuse-0001-1111-2222-333333333333", ts: 1,
                raw: "https://www.xiaoshengapi.top/v1\nsk-stale-key-00000001", format: "multiline",
                name: "old", url: "https://www.xiaoshengapi.top/v1", model: nil, models: nil,
                key: "sk-stale-key-00000001", keyMasked: "sk-s…", targets: [],
                ccProviderID: nil, ccRenamedFrom: nil, ccRenamedTo: nil,
                cpaConfigPath: nil, status: "active"
            )
            try! core.history.append(stale)
            // 端口非法(99999)→ 解析器认不出 URL,但 token 明显是域名:
            // 修复前会静默复用 xiaoshengapi.top 并拿新 key 去测(401 惑人)
            do {
                _ = try core.add(
                    raw: "tokenhub.icu:99999/v1\nsk-fresh-key-000000001",
                    ccOverride: false, grokOverride: false, cpaOverride: false,
                    dshOverride: false, force: true)
                t.expect(false, "应抛错而不是静默复用")
            } catch {
                let msg = error.localizedDescription
                t.contains(msg, "未找到可用 URL", "明确报错而非复用: \(msg.prefix(120))")
                t.expect(!msg.contains("xiaoshengapi"), "报错与导入不得触达旧 URL")
            }
        }
        // 用户反馈(2026-11-10):DSH 里堆积一堆 keydrop-* 旧路由(每个历史导入
        // 条目一个,删除/迁移后残留),且部分凭据已丢失 → DSH 搜不到模型。
        // 修复:同步到 DSH 时对账清理账本不再认领的 keydrop-* 孤儿路由
        h.runSuite("Audit.DSH 孤儿路由对账清理") { t in
            let env = try! TestEnv("audit-dsh-prune")
            defer { env.cleanup() }
            let core = Core()
            // 账本两条 active:entryA 将被同步(同步后其路由合法);
            // entryB 已带 dsh 目标(路由合法)
            let entryA = HistoryEntry(
                id: "aaaa1111-1111-1111-111111111111", ts: 1,
                raw: "https://a.example.com/v1\nsk-entrya-key-000001", format: "multiline",
                name: "a", url: "https://a.example.com/v1", model: nil,
                models: ["deepseek-v4.1"], key: "sk-entrya-key-000001", keyMasked: "sk-a…",
                targets: [], ccProviderID: nil, ccRenamedFrom: nil, ccRenamedTo: nil,
                cpaConfigPath: nil, status: "active")
            let entryB = HistoryEntry(
                id: "bbbb2222-2222-2222-222222222222", ts: 1,
                raw: "https://b.example.com/v1\nsk-entryb-key-000002", format: "multiline",
                name: "b", url: "https://b.example.com/v1", model: nil,
                models: ["deepseek-v4.1"], key: "sk-entryb-key-000002", keyMasked: "sk-b…",
                targets: ["dsh"], ccProviderID: nil, ccRenamedFrom: nil, ccRenamedTo: nil,
                cpaConfigPath: nil, status: "active")
            try! core.history.append(entryA)
            try! core.history.append(entryB)
            // settings.yaml 预置:孤儿路由(无账本条目)+ 用户手配路由 + cparesid 常驻路由
            env.write("dsh.yaml",
            """
            llm-pi-ai:
              providers:
                keydrop-stale99:
                  apiKeyEnv: KEYDROP_STALE99_API_KEY
                  api: openai-completions
                  baseURL: https://dead.example.com/v1
                  models:
                    - id: old-model
                      name: old-model
                user-own-route:
                  apiKeyEnv: MY_OWN_KEY
                  api: openai-completions
                  baseURL: https://mine.example.com/v1
                  models:
                    - id: my-model
                      name: my-model
                keydrop-cparesid:
                  apiKeyEnv: KEYDROP_CPARESID_API_KEY
                  api: openai-completions
                  baseURL: http://127.0.0.1:8317/v1
                  models:
                    - id: deepseek-v4.1
                      name: deepseek-v4.1
            """)
            env.write("dsh-creds.yaml",
            """
            version: 1
            refs:
              KEYDROP_STALE99_API_KEY: sk-stale-orphan-0000001
              MY_OWN_KEY: sk-user-own-00000000001
              KEYDROP_CPARESID_API_KEY: sk-cpa-resident-00001
            """)
            let msg = try! core.syncToDSH(entryIDPrefix: "aaaa1111")
            let cfg = env.read("dsh.yaml")
            t.contains(cfg, "keydrop-aaaa1111", "本次同步的路由已写入")
            t.contains(cfg, "user-own-route", "用户手配路由不动")
            t.contains(cfg, "keydrop-cparesid", "CPA 常驻路由不动")
            t.expect(!cfg.contains("keydrop-stale99"), "孤儿路由被清理")
            t.contains(msg, "清理 1 个", "播报清理: \(msg)")
            let creds = env.read("dsh-creds.yaml")
            t.expect(!creds.contains("KEYDROP_STALE99_API_KEY"), "孤儿凭据一并清除")
            t.contains(creds, "MY_OWN_KEY", "用户凭据不动")
            t.contains(creds, "KEYDROP_CPARESID_API_KEY", "常驻凭据不动")
            let y = Process()
            y.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            y.arguments = ["-c", "import yaml; yaml.safe_load(open('\(env.dir)/dsh.yaml')); yaml.safe_load(open('\(env.dir)/dsh-creds.yaml'))"]
            try? y.run(); y.waitUntilExit()
            t.expect(y.terminationStatus == 0, "清理后 YAML 合法")
        }

        // 账本外部变更通知:CLI/另一进程写入 → 目录监听触发回调并重载。
        // 此前面板只在「本进程操作后」刷新,外部写入要手动点什么才可见
        h.runSuite("Audit.账本外部变更通知") { t in
            let env = try! TestEnv("audit-extwatch")
            defer { env.cleanup() }
            let store = HistoryStore()
            let sem = DispatchSemaphore(value: 0)
            store.onExternalChange = { sem.signal() }
            let e1 = HistoryEntry(
                id: "watch1111-1111-1111-111111111111", ts: 1,
                raw: "https://w.example.com/v1\nsk-watch-key-0000001", format: "multiline",
                name: "w1", url: "https://w.example.com/v1", model: nil,
                models: ["deepseek-v4.1"], key: "sk-watch-key-0000001", keyMasked: "sk-w…",
                targets: [], ccProviderID: nil, ccRenamedFrom: nil, ccRenamedTo: nil,
                cpaConfigPath: nil, status: "active")
            try! store.append(e1)
            // 第二个实例模拟另一进程(CLI/另一端)的完整保存管线(replaceItemAt 换 inode)
            let other = HistoryStore()
            let e2 = HistoryEntry(
                id: "watch2222-2222-2222-222222222222", ts: 2,
                raw: "https://w2.example.com/v1\nsk-watch-key-0000002", format: "multiline",
                name: "w2", url: "https://w2.example.com/v1", model: nil,
                models: ["deepseek-v4.1"], key: "sk-watch-key-0000002", keyMasked: "sk-w…",
                targets: [], ccProviderID: nil, ccRenamedFrom: nil, ccRenamedTo: nil,
                cpaConfigPath: nil, status: "active")
            try! other.append(e2)
            let fired = sem.wait(timeout: .now() + 6) == .success
            t.expect(fired, "外部写入触发通知")
            t.equal(store.snapshot().count, 2, "通知后已重载外部条目")
        }

        // 装饰路由名:keydrop-<id8>-<host>-<模型>,一眼可见;改模型即改名且总量守恒
        h.runSuite("Audit.DSH 装饰路由名") { t in
            let env = try! TestEnv("audit-dsh-decor")
            defer { env.cleanup() }
            let core = Core()
            var e = HistoryEntry(
                id: "decor1111-1111-1111-111111111111", ts: 1,
                raw: "https://abc.example.com/v1\nsk-decor-key-0000001", format: "multiline",
                name: "d", url: "https://abc.example.com/v1", model: nil,
                models: ["deepseek-v4.1"], key: "sk-decor-key-0000001", keyMasked: "sk-d…",
                targets: [], ccProviderID: nil, ccRenamedFrom: nil, ccRenamedTo: nil,
                cpaConfigPath: nil, status: "active")
            try! core.history.append(e)
            _ = try! core.syncToDSH(entryIDPrefix: "decor1111")
            var cfg = env.read("dsh.yaml")
            t.contains(cfg, "keydrop-decor111-abc.example.com-deepseek-v4.1:", "装饰名含站点与模型")
            // 改模型再同步:旧装饰名摘除、新名挂上,路由总量守恒
            e.models = ["deepseek-v4.1-flash-1017"]
            e.targets = ["dsh"]
            try! core.history.update(e)
            _ = try! core.syncToDSH(entryIDPrefix: "decor1111")
            cfg = env.read("dsh.yaml")
            t.expect(!cfg.contains("keydrop-decor111-abc.example.com-deepseek-v4.1:"), "旧装饰名摘除")
            t.contains(cfg, "keydrop-decor111-abc.example.com-deepseek-v4.1-flash-1017:", "新装饰名挂上")
            let n = cfg.components(separatedBy: "\n").filter { $0.hasPrefix("    keydrop-") }.count
            t.equal(n, 1, "改名后仍单块,实际 \(n)")
        }

        // 行 hover 提示:信息密度(界面行保持紧凑,信息全在悬浮层)
        h.runSuite("Audit.行 hover 提示") { t in
            var e = HistoryEntry(
                id: "tip111111-1111-1111-111111111111", ts: 1_760_000_000,
                raw: "https://x.example.com/v1\nsk-tip-key-00000001", format: "multiline",
                name: "tip", url: "https://x.example.com/v1", model: nil,
                models: ["deepseek-v4.1", "glm-5.3-flash"], key: "sk-tip-key-00000001",
                keyMasked: "sk-t…4321", targets: ["ccswitch", "cpa", "dsh"],
                ccProviderID: nil, ccRenamedFrom: nil, ccRenamedTo: nil,
                cpaConfigPath: nil, status: "active",
                health: "ok", healthDetail: "GET → 200, 2 个模型", healthAt: 1_760_000_500,
                latencyMs: 850, failStreak: 2, viaCPAOk: false, viaCPAAt: 1_760_000_600,
                probeLog: [ProbePoint(t: 1_760_000_000, ms: 900, ok: true),
                           ProbePoint(t: 1_760_000_300, ms: nil, ok: true)])
            e.verifyVerdict = "中端级"
            e.note = "备注内容"
            let tip = e.richTooltip
            t.contains(tip, "https://x.example.com/v1")
            t.contains(tip, "模型: deepseek-v4.1 / glm-5.3-flash")
            t.contains(tip, "key: sk-t…4321")
            t.contains(tip, "状态: 可用 · GET → 200, 2 个模型")
            t.contains(tip, "延迟 850ms")
            t.contains(tip, "uptime 100%")
            t.contains(tip, "连续失败 2 次")
            t.contains(tip, "CPA 链路: ✗ 异常")
            t.contains(tip, "真伪鉴定: 中端级")
            t.contains(tip, "cc-switch(Claude) · CPA · DeepSeek Harness")
        }

        // 用户真实反馈(2026-11-12):newapi 渠道导出(JSON 行 + 活动说明 + 可用模型列表)
        // 曾整段按普通多行文本切碎:key 变垃圾碎片、URL 被官方 fallback 误猜成
        // api.deepseek.com、带注解的模型行(deepseek-v4.1-flash (会映射到 xx))整行丢失
        h.runSuite("Audit.内嵌 JSON 行 + 可用模型列表") { t in
            let raw = """
            {"_type":"newapi_channel_conn","key":"sk-MOX-qGuUJHrsLe2ReLNLP8wzpefaLVlEay2xoSSlraEvkoM75POq","url":"https://jpn.cdn.moxuna.com"}
            [11.11 - 11.13] Deepseek-flash 1017不限量
            可用模型：
            deepseek-v4-pro
            deepseek-flash
            deepseek-v4.1-flash (会映射到deepseek-flash)
            """
            let p = try! Parser.parse(raw)
            t.equal(p.url, "https://jpn.cdn.moxuna.com", "JSON 行 URL(修复前误猜官方站)")
            t.equal(p.key, "sk-MOX-qGuUJHrsLe2ReLNLP8wzpefaLVlEay2xoSSlraEvkoM75POq", "JSON 行 key(修复前垃圾碎片)")
            t.equal(p.models, ["deepseek-v4-pro", "deepseek-flash", "deepseek-v4.1-flash"],
                    "模型列表全齐且注解剥离")
            t.equal(p.model, "deepseek-v4-pro", "激活模型 = 列表第一个")
            t.equal(p.format, "json", "标记 json 来源")

            // 带 key 的普通多行 + 注解模型行(classify 路径)
            let p2 = try! Parser.parse("https://x.example.com/v1\nsk-test-annkey-00001\ndeepseek-v4.1-flash (会映射到deepseek-flash)")
            t.equal(p2.models, ["deepseek-v4.1-flash"], "注解剥离(classify 路径)")
        }

        // CPA 生命周期守恒:账本 cpa 认领与 config.yaml 的 key 一一对应,删除即回收
        h.runSuite("Audit.CPA 生命周期守恒") { t in
            let env = try! TestEnv("audit-cpa-invariant")
            defer { env.cleanup() }
            let core = Core()
            let cfgPath = env.dir + "/cpa-config.yaml"
            env.write("cpa-config.yaml", "port: 18317\n")
            let e1 = HistoryEntry(
                id: "inv1aaaa-1111-1111-111111111111", ts: 1,
                raw: "https://inv1.example.com/v1\nsk-inv1-key-00000001", format: "multiline",
                name: "i1", url: "https://inv1.example.com/v1", model: nil,
                models: ["deepseek-v4.1"], key: "sk-inv1-key-00000001", keyMasked: "sk-i1…",
                targets: ["cpa"], ccProviderID: nil, ccRenamedFrom: nil, ccRenamedTo: nil,
                cpaConfigPath: cfgPath, status: "active")
            let e2 = HistoryEntry(
                id: "inv2bbbb-2222-2222-222222222222", ts: 2,
                raw: "https://inv2.example.com/v1\nsk-inv2-key-00000002", format: "multiline",
                name: "i2", url: "https://inv2.example.com/v1", model: nil,
                models: ["deepseek-v4.1"], key: "sk-inv2-key-00000002", keyMasked: "sk-i2…",
                targets: ["cpa"], ccProviderID: nil, ccRenamedFrom: nil, ccRenamedTo: nil,
                cpaConfigPath: cfgPath, status: "active")
            try! core.history.append(e1)
            try! core.history.append(e2)
            // 直接播种 KeyDrop 写入格式的聚合条目(addAggregated 是 internal,
            // 测试目标不可见;守恒断言关注删除侧的回收,与谁写入无关)
            env.write("cpa-config.yaml", """
            port: 18317

            openai-compatibility:
              - name: inv1.example.com
                base-url: "https://inv1.example.com/v1"
                api-key-entries:
                  - api-key: sk-inv1-key-00000001
                models:
                  - name: deepseek-v4.1
                    alias: ""
              - name: inv2.example.com
                base-url: "https://inv2.example.com/v1"
                api-key-entries:
                  - api-key: sk-inv2-key-00000002
                models:
                  - name: deepseek-v4.1
                    alias: ""
            """)
            var cfg = env.read("cpa-config.yaml")
            t.contains(cfg, "sk-inv1-key-00000001", "基线:key1 在配置")
            t.contains(cfg, "sk-inv2-key-00000002", "基线:key2 在配置")

            let msg = try! core.delete(entryIDPrefix: "inv1aaaa")
            cfg = env.read("cpa-config.yaml")
            t.expect(!cfg.contains("sk-inv1-key-00000001"), "删除后 key1 回收: \(msg.prefix(80))")
            t.contains(cfg, "sk-inv2-key-00000002", "未删条目的 key 保留")
            t.equal(core.history.find(idPrefix: "inv1aaaa")?.status, "deleted", "账本同步标记删除")
            let y = Process()
            y.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            y.arguments = ["-c", "import yaml; yaml.safe_load(open('\(env.dir)/cpa-config.yaml'))"]
            try? y.run(); y.waitUntilExit()
            t.expect(y.terminationStatus == 0, "删除后 YAML 合法")
        }

        // Grok 生命周期守恒:两个 provider 共存,删除其一带走自己的路由
        h.runSuite("Audit.Grok 生命周期守恒") { t in
            let env = try! TestEnv("audit-grok-invariant")
            defer { env.cleanup() }
            let core = Core()
            let cfgPath = env.dir + "/grok-config.toml"
            let w = GrokBuildWriter(configPath: cfgPath)
            _ = try! w.add(baseURL: "https://g1.example.com/v1", key: "sk-grok1-key-0000001", models: ["grok-4-fast"])
            _ = try! w.add(baseURL: "https://g2.example.com/v1", key: "sk-grok2-key-0000002", models: ["grok-4-fast"])
            var cfg = env.read("grok-config.toml")
            t.contains(cfg, "g1.example.com", "基线:provider1 在配置")
            t.contains(cfg, "g2.example.com", "基线:provider2 在配置")
            let e1 = HistoryEntry(
                id: "groc1aaa-1111-1111-111111111111", ts: 1,
                raw: "https://g1.example.com/v1\nsk-grok1-key-0000001", format: "multiline",
                name: "g1", url: "https://g1.example.com/v1", model: nil,
                models: ["grok-4-fast"], key: "sk-grok1-key-0000001", keyMasked: "sk-g1…",
                targets: ["grok"], ccProviderID: nil, ccRenamedFrom: nil, ccRenamedTo: nil,
                cpaConfigPath: nil, grokConfigPath: cfgPath, status: "active")
            try! core.history.append(e1)
            _ = try! core.delete(entryIDPrefix: "groc1aaa")
            cfg = env.read("grok-config.toml")
            t.expect(!cfg.contains("g1.example.com"), "删除后 provider1 路由回收")
            t.contains(cfg, "g2.example.com", "provider2 保留")
        }

        // DSH 全生命周期对账(与 cc-switch 同级):守恒/漂移修复/凭据自愈/缺失报告/补丁层检测
        h.runSuite("Audit.DSH 全生命周期对账") { t in
            let env = try! TestEnv("audit-dsh-full")
            defer { env.cleanup() }
            // installed()/补丁层扫描基于 DSH_HOME;套件结束恢复,不污染后续套件
            let oldDSHHome = getenv("DSH_HOME").map { String(cString: $0) }
            setenv("DSH_HOME", env.dir + "/dshhome", 1)
            try! FileManager.default.createDirectory(atPath: env.dir + "/dshhome/profiles/headless", withIntermediateDirectories: true)
            defer {
                if let old = oldDSHHome { setenv("DSH_HOME", old, 1) } else { unsetenv("DSH_HOME") }
            }
            let core = Core()
            let entryA = HistoryEntry(
                id: "dddd4444-4444-4444-444444444444", ts: 1,
                raw: "https://a.example.com/v1\nsk-entrya-key-000001", format: "multiline",
                name: "a", url: "https://a.example.com/v1", model: nil,
                models: ["deepseek-v4.1"], key: "sk-entrya-key-000001", keyMasked: "sk-a…",
                targets: [], ccProviderID: nil, ccRenamedFrom: nil, ccRenamedTo: nil,
                cpaConfigPath: nil, status: "active")
            let entryB = HistoryEntry(
                id: "eeee5555-5555-5555-555555555555", ts: 1,
                raw: "https://b.example.com/v1\nsk-entryb-key-000002", format: "multiline",
                name: "b", url: "https://b.example.com/v1", model: nil,
                models: ["deepseek-v4.1"], key: "sk-entryb-key-000002", keyMasked: "sk-b…",
                targets: ["dsh"], ccProviderID: nil, ccRenamedFrom: nil, ccRenamedTo: nil,
                cpaConfigPath: nil, status: "active")
            let entryC = HistoryEntry(
                id: "ffff6666-6666-6666-666666666666", ts: 1,
                raw: "https://c.example.com/v1\nsk-entryc-key-000003", format: "multiline",
                name: "c", url: "https://c.example.com/v1", model: nil,
                models: ["deepseek-v4.1"], key: "sk-entryc-key-000003", keyMasked: "sk-c…",
                targets: ["dsh"], ccProviderID: nil, ccRenamedFrom: nil, ccRenamedTo: nil,
                cpaConfigPath: nil, status: "active")
            try! core.history.append(entryA)
            try! core.history.append(entryB)
            try! core.history.append(entryC)
            // 预置:entryB 路由漂移(baseURL/models 都是旧值)+ 凭据缺失;
            // cparesid 与用户手配路由正常
            env.write("dsh.yaml",
            """
            llm-pi-ai:
              providers:
                keydrop-eeee5555:
                  apiKeyEnv: KEYDROP_EEEE5555_API_KEY
                  api: openai-completions
                  baseURL: https://stale.example.com/v1
                  models:
                    - id: stale-model
                      name: stale-model
                keydrop-cparesid:
                  apiKeyEnv: KEYDROP_CPARESID_API_KEY
                  api: openai-completions
                  baseURL: http://127.0.0.1:8317/v1
                  models:
                    - id: deepseek-v4.1
                      name: deepseek-v4.1
                user-own-route:
                  apiKeyEnv: MY_OWN_KEY
                  api: openai-completions
                  baseURL: https://mine.example.com/v1
                  models:
                    - id: my-model
                      name: my-model
            """)
            env.write("dsh-creds.yaml",
            """
            version: 1
            refs:
              MY_OWN_KEY: sk-user-own-00000000001
              KEYDROP_CPARESID_API_KEY: sk-cpa-resident-00001
            """)

            // ①②③ 漂移修复 + 凭据自愈 + 缺失报告(不自动重建)
            let lines = core.reconcileDSH().joined(separator: "\n")
            t.contains(lines, "漂移,已重写", "漂移被识别: \(lines.prefix(200))")
            let cfg = env.read("dsh.yaml")
            t.contains(cfg, "baseURL: https://b.example.com/v1", "漂移 baseURL 重写为账本值")
            t.expect(!cfg.contains("stale.example.com"), "旧 baseURL 清除")
            t.contains(cfg, "- id: deepseek-v4.1\n          name: deepseek-v4.1", "漂移 models 重写为账本值")
            t.expect(!cfg.contains("stale-model"), "旧模型清除")
            let creds = env.read("dsh-creds.yaml")
            t.contains(creds, "KEYDROP_EEEE5555_API_KEY: sk-entryb-key-000002", "缺失凭据自愈")
            t.contains(lines, "keydrop-ffff6666", "缺失路由被报告")
            t.expect(!cfg.contains("keydrop-ffff6666"), "缺失路由不自动重建(尊重用户手删)")

            // ④ 守恒:同步两次,路由数 == 账本认领数,不增长
            _ = try! core.syncToDSH(entryIDPrefix: "dddd4444")
            _ = try! core.syncToDSH(entryIDPrefix: "dddd4444")
            let cfg2 = env.read("dsh.yaml")
            let routeCount = cfg2.components(separatedBy: "\n").filter { $0.hasPrefix("    keydrop-") }.count
            t.equal(routeCount, 3, "同步两次后 keydrop 路由数 = 账本认领数(a/b/cparesid),实际 \(routeCount)")

            // ⑤ 补丁层只读检测:残留被点名,文件不被改写
            let patchPath = env.dir + "/dshhome/profiles/headless/x.patch.yml"
            try! "x:\n  providers:\n      keydrop-deadbeef:\n        apiKeyEnv: KEYDROP_DEADBEEF_API_KEY\n".write(
                toFile: patchPath, atomically: true, encoding: .utf8)
            let lines2 = core.reconcileDSH().joined(separator: "\n")
            t.contains(lines2, "补丁层残留", "补丁层残留被点名")
            t.contains(lines2, "keydrop-deadbeef", "残留路由具名")
            t.contains(env.read("dshhome/profiles/headless/x.patch.yml"), "keydrop-deadbeef", "补丁层文件未被改写")
        }
    }
}
