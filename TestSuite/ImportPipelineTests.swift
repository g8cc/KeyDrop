import Foundation
import KeyDropCore

/// 导入管线端到端测试 —— 产品核心:粘贴内容 → 解析 → 路由 → 写入正确目标、正确字段。
/// 每个用例都验证「DB 行(app_type/endpoint/settings_config)+ 真实配置文件内容 + entry 元数据」三层落点。
enum ImportPipelineTests {

    /// 建库 + 建 Core;返回 (env, core, db 路径)
    private static func makeEnv(_ name: String) -> (TestEnv, Core) {
        let env = try! TestEnv(name)
        try! CCSwitchWriterTests.createSchema(env)
        return (env, Core())
    }

    private static func db(_ env: TestEnv) -> DB { try! DB(path: env.dir + "/cc-switch.db") }

    static func run(_ h: Harness) {

        // MARK: - 路由矩阵:模型家族 → 目标 app → 落点文件

        h.runSuite("导入管线.路由矩阵") { t in
            // claude 系 → app_type=claude + claude.json
            let (e1, c1) = makeEnv("pipe-route-claude")
            defer { e1.cleanup() }
            let r1 = try! c1.add(raw: "https://route.example.com/v1 sk-routeclaude1111111",
                                 ccOverride: true, cpaOverride: false, dshOverride: false,
                                 models: ["claude-sonnet-4-5"], force: true, appType: "claude", appTypeForced: true)
            t.equal(r1.entry.targets, ["ccswitch"], "[claude] targets")
            let row1 = try! db(e1).query("SELECT app_type, settings_config FROM providers WHERE id=?", [r1.entry.ccProviderID!])
            t.equal(row1[0][0], "claude", "[claude] DB app_type")
            t.contains(row1[0][1] ?? "", "claude-sonnet-4-5", "[claude] DB settings_config 含模型")
            t.contains(row1[0][1] ?? "", "sk-routeclaude1111111", "[claude] DB settings_config 含 key")
            // cc-switch 运行时 KeyDrop 不直写 live(防 settings_config 回写腐败,见 CCSwitchWriter.add 注释);
            // 改断言 DB settings_config(永远写入)。live 门控由独立测试「live 门控」覆盖。
            let cfg1 = row1[0][1] ?? ""
            t.contains(cfg1, "ANTHROPIC_AUTH_TOKEN", "[claude] settings_config 含 token 键")
            t.contains(cfg1, "https://route.example.com/v1", "[claude] base URL 原样写入")

            // gpt 系 → app_type=codex + codex.toml + auth.json
            let (e2, c2) = makeEnv("pipe-route-codex")
            defer { e2.cleanup() }
            let r2 = try! c2.add(raw: "https://route.example.com/v1 sk-routegpt2222222222",
                                 ccOverride: true, cpaOverride: false, dshOverride: false,
                                 models: ["gpt-5.6-sol"], force: true, appType: "codex", appTypeForced: true)
            t.equal(r2.entry.targets, ["ccswitch-codex"], "[codex] targets")
            let row2 = try! db(e2).query("SELECT app_type FROM providers WHERE id=?", [r2.entry.ccProviderID!])
            t.equal(row2[0][0], "codex", "[codex] DB app_type")
            let toml = e2.read("codex.toml")
            t.contains(toml, "model = \"gpt-5.6-sol\"", "[codex] 激活模型")
            t.contains(toml, "experimental_bearer_token = \"sk-routegpt2222222222\"", "[codex] token")
            t.contains(e2.read("codex-auth.json"), "sk-routegpt2222222222", "[codex] auth.json key")

            // 其他家族 → app_type=opencode + opencode.json
            let (e3, c3) = makeEnv("pipe-route-opencode")
            defer { e3.cleanup() }
            let r3 = try! c3.add(raw: "https://route.example.com/v1 sk-routeglm3333333333",
                                 ccOverride: true, cpaOverride: false, dshOverride: false,
                                 models: ["glm-5.2"], force: true, appType: "opencode", appTypeForced: true)
            t.equal(r3.entry.targets, ["ccswitch-opencode"], "[opencode] targets")
            let row3 = try! db(e3).query("SELECT app_type FROM providers WHERE id=?", [r3.entry.ccProviderID!])
            t.equal(row3[0][0], "opencode", "[opencode] DB app_type")
            let oc = e3.read("opencode.json")
            t.contains(oc, "sk-routeglm3333333333", "[opencode] apiKey 写入")
            t.contains(oc, "glm-5.2", "[opencode] 模型写入")

            // deepseek + DSH 开 → dsh.yaml route + 凭证
            let (e4, c4) = makeEnv("pipe-route-dsh")
            defer { e4.cleanup() }
            let r4 = try! c4.add(raw: "https://route.example.com/v1 sk-routeds4444444444",
                                 ccOverride: true, cpaOverride: false, dshOverride: true,
                                 models: ["deepseek-v4-pro"], force: true, appType: "opencode", appTypeForced: true)
            t.contains(r4.entry.targets.joined(separator: ","), "dsh", "[dsh] targets")
            t.contains(e4.read("dsh.yaml"), DSHWriter.routeKey(providerID: r4.entry.id), "[dsh] route 写入")
            t.contains(e4.read("dsh.yaml"), "https://route.example.com/v1", "[dsh] baseURL 写入")
            t.contains(e4.read("dsh-creds.yaml"), "sk-routeds4444444444", "[dsh] 凭证写入")

            // CPA 开 → config.yaml 聚合条目
            let (e5, c5) = makeEnv("pipe-route-cpa")
            defer { e5.cleanup() }
            e5.write("cpa-config.yaml", "port: 18317\n")
            let r5 = try! c5.add(raw: "https://route.example.com/v1 sk-routecpa555555555",
                                 ccOverride: false, cpaOverride: true, dshOverride: false, force: true)
            t.contains(r5.entry.targets.joined(separator: ","), "cpa", "[cpa] targets")
            t.contains(e5.read("cpa-config.yaml"), "sk-routecpa555555555", "[cpa] key 写入")
            t.contains(e5.read("cpa-config.yaml"), "https://route.example.com/v1", "[cpa] base-url 写入")
        }

        // MARK: - URL 规范化:同一粘贴 URL 在不同目标里的正确形态

        h.runSuite("导入管线.URL 规范化按目标") { t in
            let rawURL = "https://norm.example.com"   // 无 /v1:claude 原样,opencode/codex 补 /v1
            // claude:anthropic base 无 /v1 语义,原样写入
            let (e1, c1) = makeEnv("pipe-url-claude")
            defer { e1.cleanup() }
            _ = try! c1.add(raw: "\(rawURL) sk-urlnormclaude11111", ccOverride: true, cpaOverride: false,
                            dshOverride: false, models: ["claude-sonnet-4-5"], force: true,
                            appType: "claude", appTypeForced: true)
            let cfgUrlClaude = (try? db(e1).scalar("SELECT settings_config FROM providers WHERE app_type='claude' LIMIT 1")) ?? "{}"
            t.contains(cfgUrlClaude, "\"ANTHROPIC_BASE_URL\":\"\(rawURL)\"",
                       "[claude] settings_config base URL 原样(不补 /v1)")
            t.expect(!cfgUrlClaude.contains("\(rawURL)/v1"), "[claude] claude 不补 /v1")

            // codex:openai 语义必须带 /v1
            let (e2, c2) = makeEnv("pipe-url-codex")
            defer { e2.cleanup() }
            _ = try! c2.add(raw: "\(rawURL) sk-urlnormcodex222222", ccOverride: true, cpaOverride: false,
                            dshOverride: false, models: ["gpt-5.6-sol"], force: true,
                            appType: "codex", appTypeForced: true)
            t.contains(e2.read("codex.toml"), "base_url = \"\(rawURL)/v1\"", "[codex] base_url 补 /v1")
            // endpoint DB 行记录原始 URL,去重比较在查询侧规范化
            let ep2 = try! db(e2).scalar("SELECT url FROM provider_endpoints")
            t.equal(ep2, rawURL, "[codex] endpoint 记录原始 URL")

            // opencode:同 codex 补 /v1,endpoint 行存规范化 URL
            let (e3, c3) = makeEnv("pipe-url-opencode")
            defer { e3.cleanup() }
            _ = try! c3.add(raw: "\(rawURL) sk-urlnormoc33333333", ccOverride: true, cpaOverride: false,
                            dshOverride: false, models: ["glm-5.2"], force: true,
                            appType: "opencode", appTypeForced: true)
            t.contains(e3.read("opencode.json"), "\"baseURL\" : \"\(rawURL)/v1\"", "[opencode] baseURL 补 /v1")
            let ep3 = try! db(e3).scalar("SELECT url FROM provider_endpoints")
            t.equal(ep3, "\(rawURL)/v1", "[opencode] endpoint 存规范化 URL")

            // 粘贴完整接口路径 → 自动剥到 base
            let (e4, c4) = makeEnv("pipe-url-path")
            defer { e4.cleanup() }
            let r4 = try! c4.add(raw: "https://path.example.com/v1/chat/completions sk-urlpath444444444",
                                 ccOverride: true, cpaOverride: false, dshOverride: false,
                                 models: ["glm-5.2"], force: true, appType: "opencode", appTypeForced: true)
            t.equal(r4.entry.url, "https://path.example.com/v1", "[path] 接口路径剥为 base URL")
            t.contains(e4.read("opencode.json"), "https://path.example.com/v1", "[path] 落盘为 base")
        }

        // MARK: - 粘贴格式 × 端到端落点(每种格式都要能走到正确的目标)

        h.runSuite("导入管线.格式端到端") { t in
            // JSON(openai 风格字段)
            let (e1, c1) = makeEnv("pipe-fmt-json")
            defer { e1.cleanup() }
            let r1 = try! c1.add(raw: "{\"base_url\":\"https://fmt.example.com/v1\",\"api_key\":\"sk-fmtjson111111111\",\"model\":\"gpt-5.6-sol\"}",
                                 ccOverride: true, cpaOverride: false, dshOverride: false, force: true)
            t.contains(r1.entry.targets.joined(separator: ","), "ccswitch-codex", "[JSON] 路由 codex")
            t.contains(e1.read("codex.toml"), "sk-fmtjson111111111", "[JSON] key 落盘")

            // JSON(anthropic 风格字段)
            let (e2, c2) = makeEnv("pipe-fmt-anthropic")
            defer { e2.cleanup() }
            let r2 = try! c2.add(raw: "{\"ANTHROPIC_BASE_URL\":\"https://fmt.example.com\",\"ANTHROPIC_AUTH_TOKEN\":\"sk-fmtanth22222222\"}",
                                 ccOverride: true, cpaOverride: false, dshOverride: false,
                                 models: ["claude-sonnet-4-5"], force: true, appType: "claude", appTypeForced: true)
            t.equal(r2.entry.key, "sk-fmtanth22222222", "[ANTHROPIC JSON] key 提取")
            t.equal(r2.entry.url, "https://fmt.example.com", "[ANTHROPIC JSON] url 提取")
            let cfg2 = (try? db(e2).scalar("SELECT settings_config FROM providers WHERE id=?", [r2.entry.ccProviderID!])) ?? "{}"
            t.contains(cfg2, "sk-fmtanth22222222", "[ANTHROPIC JSON] settings_config 落盘")

            // 环境变量格式(单行 KEY=VALUE 空格分隔)
            let (e3, c3) = makeEnv("pipe-fmt-env")
            defer { e3.cleanup() }
            let r3 = try! c3.add(raw: "ANTHROPIC_BASE_URL=https://fmt.example.com ANTHROPIC_AUTH_TOKEN=sk-fmtenv3333333333",
                                 ccOverride: true, cpaOverride: false, dshOverride: false,
                                 models: ["claude-sonnet-4-5"], force: true, appType: "claude", appTypeForced: true)
            t.equal(r3.entry.key, "sk-fmtenv3333333333", "[ENV] key 提取")
            t.equal(r3.entry.url, "https://fmt.example.com", "[ENV] url 提取")
            let cfg3 = (try? db(e3).scalar("SELECT settings_config FROM providers WHERE id=?", [r3.entry.ccProviderID!])) ?? "{}"
            t.contains(cfg3, "sk-fmtenv3333333333", "[ENV] settings_config 落盘")

            // curl 命令(解析层已有;这里验证写入链路)
            let (e4, c4) = makeEnv("pipe-fmt-curl")
            defer { e4.cleanup() }
            let r4 = try! c4.add(raw: "curl -sS 'https://fmt.example.com/v1/chat/completions' -H 'Authorization: Bearer sk-fmtcurl444444444' -d '{\"model\":\"gpt-5.6-sol\"}'",
                                 ccOverride: true, cpaOverride: false, dshOverride: false, force: true)
            t.equal(r4.entry.key, "sk-fmtcurl444444444", "[curl] key")
            t.equal(r4.entry.model, "gpt-5.6-sol", "[curl] model")
            t.contains(e4.read("codex.toml"), "sk-fmtcurl444444444", "[curl] 落盘 codex")

            // keyhub 风格(标签:URL + APIKEY 短 token)
            let (e5, c5) = makeEnv("pipe-fmt-keyhub")
            defer { e5.cleanup() }
            let r5 = try! c5.add(raw: "OpenAI:https://fmt.example.com/v1\nAPIKEY linuxdo-token12345678",
                                 ccOverride: true, cpaOverride: false, dshOverride: false,
                                 models: ["glm-5.2"], force: true, appType: "opencode", appTypeForced: true)
            t.equal(r5.entry.key, "linuxdo-token12345678", "[keyhub] 短 token key 提取")
            t.contains(e5.read("opencode.json"), "linuxdo-token12345678", "[keyhub] 落盘 opencode")

            // base64(JSON)
            let (e6, c6) = makeEnv("pipe-fmt-base64")
            defer { e6.cleanup() }
            let inner = "{\"base_url\":\"https://fmt.example.com/v1\",\"api_key\":\"sk-fmtb64666666666\",\"model\":\"gpt-5.6-sol\"}"
            let b64 = Data(inner.utf8).base64EncodedString()
            let r6 = try! c6.add(raw: b64, ccOverride: true, cpaOverride: false, dshOverride: false, force: true)
            t.contains(r6.entry.format, "base64", "[b64] format 标记")
            t.contains(e6.read("codex.toml"), "sk-fmtb64666666666", "[b64] 解码后落盘")
        }

        // MARK: - zip 文件导入

        h.runSuite("导入管线.zip 文件") { t in
            let (env, core) = makeEnv("pipe-zip")
            defer { env.cleanup() }
            let src = env.dir + "/zipsrc"
            try! FileManager.default.createDirectory(atPath: src, withIntermediateDirectories: true)
            let json = "{\"base_url\":\"https://zip.example.com/v1\",\"api_key\":\"sk-zipfile7777777777\",\"model\":\"gpt-5.6-sol\"}"
            try! json.write(toFile: src + "/config.json", atomically: true, encoding: .utf8)
            let zipPath = env.dir + "/bundle.zip"
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            proc.arguments = ["-q", "-j", zipPath, src + "/config.json"]
            try! proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else {
                t.expect(false, "zip 制作失败")
                return
            }
            let r = try! core.add(raw: zipPath, ccOverride: true, cpaOverride: false, dshOverride: false, force: true)
            t.contains(r.entry.format, "zip", "[zip] format 标记: \(r.entry.format)")
            t.contains(r.entry.format, "json", "[zip] 内层格式: \(r.entry.format)")
            t.equal(r.entry.key, "sk-zipfile7777777777", "[zip] key 解析")
            t.contains(env.read("codex.toml"), "sk-zipfile7777777777", "[zip] 落盘 codex")
        }

        // MARK: - 网关模型列表驱动的选择路径(真实测试流程,非 force)

        h.runSuite("导入管线.网关模型自动导入") { t in
            // ≤5 个模型:全部导入(混合家族)→ 路由 codex → 激活模型取 gpt 系
            let (e1, c1) = makeEnv("pipe-auto5")
            defer { e1.cleanup() }
            guard let srv = try? MockHTTPServer(mode: .openAI) else {
                t.expect(false, "mock 启动失败"); return
            }
            let r1 = try! c1.add(raw: "http://127.0.0.1:\(srv.port) sk-auto5models1111111",
                                 ccOverride: true, cpaOverride: false, dshOverride: false, force: false)
            t.equal(r1.entry.models, ["gpt-5.6-sol", "glm-5.2"], "[≤5] 全量导入")
            t.equal(r1.entry.targets, ["ccswitch-codex"], "[≤5] 混合家族路由 codex")
            t.contains(e1.read("codex.toml"), "model = \"gpt-5.6-sol\"", "[≤5] 激活模型家族过滤生效")

            // >5 个模型:走选择器;勾选子集
            let (e2, c2) = makeEnv("pipe-many")
            defer { e2.cleanup() }
            guard let srv2 = try? MockHTTPServer(mode: .manyModels) else {
                t.expect(false, "mock2 启动失败"); return
            }
            var pickerGot: [String]? = nil
            let r2 = try! c2.add(raw: "http://127.0.0.1:\(srv2.port) sk-manymodels11111111",
                                 ccOverride: true, cpaOverride: false, dshOverride: false, force: false) { options in
                pickerGot = options
                return ["model-3-sample"]
            }
            t.equal(pickerGot?.count, 8, "[>5] 选择器收到全量列表")
            t.equal(r2.entry.models, ["model-3-sample"], "[>5] 只导入勾选子集")
            t.contains(e2.read("opencode.json"), "model-3-sample", "[>5] 勾选模型落盘")

            // 选择器取消 → 不写入
            let (e3, c3) = makeEnv("pipe-cancel")
            defer { e3.cleanup() }
            do {
                _ = try c3.add(raw: "http://127.0.0.1:\(srv2.port) sk-canceltest11111111",
                               ccOverride: true, cpaOverride: false, dshOverride: false, force: false) { _ in [] }
                t.expect(false, "取消应抛错")
            } catch {
                t.contains(error.localizedDescription, "已取消", "取消报错")
            }
            t.expect(c3.history.findActiveByKey("sk-canceltest11111111") == nil, "取消后不建条目")

            // 网关无模型列表 + 粘贴了模型:逐一验证后导入
            let (e4, c4) = makeEnv("pipe-chatok")
            defer { e4.cleanup() }
            guard let srv4 = try? MockHTTPServer(mode: .chatOK) else {
                t.expect(false, "mock4 启动失败"); return
            }
            let r4 = try! c4.add(raw: "http://127.0.0.1:\(srv4.port) sk-chatokmodel1111111 gpt-5.6-sol",
                                 ccOverride: true, cpaOverride: false, dshOverride: false, force: false)
            t.equal(r4.entry.models, ["gpt-5.6-sol"], "[chatOK] 贴入模型验证通过后导入")
            t.contains(e4.read("codex.toml"), "model = \"gpt-5.6-sol\"", "[chatOK] 落盘 codex")
        }

        // MARK: - 点分模型名不误杀(真实事故:stepfun step_plan 7 选 5 只剩 1)

        h.runSuite("导入管线.点分模型名不误杀") { t in
            // add + picker:勾选含点分名的子集,不得被 looksLikeModel 域名规则静默过滤
            let (env, core) = makeEnv("pipe-dotted")
            defer { env.cleanup() }
            guard let srv = try? MockHTTPServer(mode: .dottedModels) else {
                t.expect(false, "mock 启动失败"); return
            }
            let picked = ["step-3.7-flash", "step-3.5-flash", "step-3.5-flash-2603", "step-image-edit-2"]
            let r = try! core.add(raw: "http://127.0.0.1:\(srv.port) sk-dottedmodels11111111",
                                  ccOverride: true, cpaOverride: false, dshOverride: false, force: false) { _ in picked }
            // 勾选 4 个(含 3 个点分名):修复前 strict 过滤只剩无点的 step-image-edit-2
            t.equal(r.entry.models, picked, "[add] 勾选的点分模型全部保留")
            t.equal(r.entry.model, picked.first, "[add] model=勾选第一个")
            t.contains(env.read("opencode.json"), "step-3.7-flash", "[add] 点分模型落盘 opencode")

            // refresh:弹窗选项必须是原始 /models 列表,点分名不得被预杀
            var refreshGot: [String]? = nil
            let msg = try! core.refreshModels(entryIDPrefix: r.entry.id) { options in
                refreshGot = options
                return picked
            }
            t.notNil(refreshGot)
            t.equal(refreshGot?.count, 7, "[refresh] 选项含全部 7 个原始模型")
            t.expect(refreshGot?.contains("step-3.7-flash") == true, "[refresh] 点分模型在选项中")
            t.contains(msg, "已更新 4 个", "[refresh] 勾选子集照常更新")
            let e1 = core.history.snapshot().first { $0.id == r.entry.id }
            t.equal(e1?.models, picked, "[refresh] 条目模型保持勾选子集")
        }

        // MARK: - 刷新同步 CPA 聚合条目模型列表(整体替换,取消勾选的同步移除)

        h.runSuite("Regression.refresh 同步 CPA 模型列表") { t in
            let env = try! TestEnv("reg-cpa-refresh")
            defer { env.cleanup() }
            env.write("cpa-config.yaml", "port: 18317\napi-keys:\n  - sk-client000000000\n")
            guard let srv = try? MockHTTPServer(mode: .dottedModels) else {
                t.expect(false, "mock 启动失败"); return
            }
            let core = Core()
            let r = try! core.add(raw: "http://127.0.0.1:\(srv.port) sk-cparefresh00000001",
                                  ccOverride: false, cpaOverride: true, dshOverride: false, force: false) { _ in
                ["step-3.7-flash", "step-image-edit-2"]
            }
            t.expect(r.ok, "导入成功")
            var cfg = env.read("cpa-config.yaml")
            t.contains(cfg, "- name: step-3.7-flash", "初选模型写入 CPA")
            t.expect(!cfg.contains("step-3.5-flash"), "未选模型不在 CPA")

            // 刷新重选 → CPA 模型列表整体替换
            let msg = try! core.refreshModels(entryIDPrefix: r.entry.id) { _ in
                ["step-3.5-flash", "step-5-preview", "step-image-edit-2"]
            }
            t.contains(msg, "CPA", "刷新消息含 CPA 同步结果")
            cfg = env.read("cpa-config.yaml")
            t.contains(cfg, "- name: step-3.5-flash", "新勾选模型写入")
            t.contains(cfg, "- name: step-5-preview", "新勾选模型写入 2")
            t.contains(cfg, "alias: step-3.5-flash", "alias 同步写入")
            t.expect(!cfg.contains("step-3.7-flash"), "被取消勾选的模型同步移除")
            t.contains(cfg, "sk-cparefresh00000001", "key 保留不动")
        }

        // MARK: - 代理随写传播

        h.runSuite("导入管线.代理传播") { t in
            let (env, core) = makeEnv("pipe-proxy")
            defer { env.cleanup() }
            env.write("cpa-config.yaml", "port: 18317\n")
            let r = try! core.add(raw: "https://proxy.example.com/v1 sk-proxytest11111111",
                                  ccOverride: true, cpaOverride: true, dshOverride: false,
                                  models: ["claude-sonnet-4-5"], force: true,
                                  appType: "claude", appTypeForced: true,
                                  proxy: "http://127.0.0.1:7890")
            t.expect(r.ok, "带代理导入成功")
            let cfgProxy = (try? db(env).scalar("SELECT settings_config FROM providers WHERE id=?", [r.entry.ccProviderID!])) ?? "{}"
            t.contains(cfgProxy, "http://127.0.0.1:7890", "[claude] 代理写入 settings_config")
            let cpa = env.read("cpa-config.yaml")
            // yamlScalar 对含冒号的 URL 加双引号
            t.contains(cpa, "proxy-url: \"http://127.0.0.1:7890\"", "[cpa] 代理写入条目")
        }

        // MARK: - 幂等更新:改模型重新导入 → 目标同步刷新

        h.runSuite("导入管线.幂等改模型") { t in
            let (env, core) = makeEnv("pipe-idem")
            defer { env.cleanup() }
            let raw = "https://idem.example.com/v1 sk-idemmodel11111111"
            _ = try! core.add(raw: raw, ccOverride: true, cpaOverride: false, dshOverride: false,
                              models: ["gpt-5.6-sol"], force: true, appType: "codex", appTypeForced: true)
            t.contains(env.read("codex.toml"), "model = \"gpt-5.6-sol\"", "[幂等前] 模型 A")
            // 同 key 同 URL,换模型重导 → 同条目刷新,codex 配置同步
            let second = try! core.add(raw: raw, ccOverride: true, cpaOverride: false, dshOverride: false,
                                       models: ["gpt-5.6-mini"], force: true, appType: "codex", appTypeForced: true)
            t.equal(second.entry.id, firstID(core, key: "sk-idemmodel11111111"), "同条目幂等")
            t.contains(env.read("codex.toml"), "model = \"gpt-5.6-mini\"", "[幂等后] 模型同步为 B")
            t.expect(!env.read("codex.toml").contains("model = \"gpt-5.6-sol\""), "[幂等后] 旧模型无残留")
        }

        // MARK: - live 门控:cc-switch 运行状态决定 KeyDrop 是否直写 live claude.json
        // 事故修复:cc-switch 运行时 KeyDrop 写 live 会被 cc-switch 回写进陈旧 current 的
        // settings_config,整块覆盖旧 provider 的 url/key/models。运行时交给 cc-switch 应用,
        // KeyDrop 只写 DB;未运行时 KeyDrop 独占 live。

        h.runSuite("导入管线.live 门控") { t in
            // cc-switch 运行(FAKE=1,harness 默认)→ 不写 live claude.json
            let (e1, c1) = makeEnv("pipe-livegate-running")
            defer { e1.cleanup() }
            _ = try! c1.add(raw: "https://gate.example.com/v1 sk-gaterun1111111111",
                             ccOverride: true, cpaOverride: false, dshOverride: false,
                             models: ["claude-sonnet-4-5"], force: true, appType: "claude", appTypeForced: true)
            t.expect(!FileManager.default.fileExists(atPath: e1.dir + "/claude.json"),
                     "[运行] 不写 live claude.json(交给 cc-switch 应用)")
            let cfgRun = (try? db(e1).scalar("SELECT settings_config FROM providers WHERE app_type='claude' LIMIT 1")) ?? "{}"
            t.contains(cfgRun, "sk-gaterun1111111111", "[运行] DB settings_config 仍写入")

            // 回归复现:旧 cc-switch 进程可能仍缓存旧 current provider,随后会把 live
            // 配置回写到旧 provider。导入新 key 后 live 必须为空,否则旧 provider 会被
            // 新 key/base_url/model 整块污染。
            let oldPID = try! db(e1).scalar("SELECT id FROM providers WHERE is_current=1 AND app_type='claude'") ?? ""
            let oldConfig = try! db(e1).scalar("SELECT settings_config FROM providers WHERE id=?", [oldPID]) ?? ""
            let second = try! c1.add(raw: "https://gate-new.example.com/v1 sk-gatenew1111111111",
                                     ccOverride: true, cpaOverride: false, dshOverride: false,
                                     models: ["claude-opus-4-1"], force: true,
                                     appType: "claude", appTypeForced: true)
            t.expect(second.ok, "[运行] 导入第二个 provider 成功")
            t.expect(!e1.fileExists("claude.json"), "[运行] 第二次导入仍不生成 live 配置")
            // 用测试替身模拟 cc-switch 的旧进程回写动作;没有 live 就不会发生污染。
            let live = e1.read("claude.json")
            if !live.isEmpty {
                try! db(e1).run("UPDATE providers SET settings_config=? WHERE id=?", [live, oldPID])
            }
            let oldAfter = try! db(e1).scalar("SELECT settings_config FROM providers WHERE id=?", [oldPID]) ?? ""
            t.contains(oldAfter, "sk-gaterun1111111111", "[运行] 旧 provider key 保持不变")
            t.contains(oldAfter, "gate.example.com/v1", "[运行] 旧 provider base_url 保持不变")
            t.contains(oldAfter, "claude-sonnet-4-5", "[运行] 旧 provider model 保持不变")
            t.expect(oldAfter == oldConfig, "[运行] 旧 provider settings_config 未被新导入污染")

            // cc-switch 未运行(FAKE=0)→ KeyDrop 独占 live,直接写
            setenv("KEYDROP_FAKE_CC_RUNNING", "0", 1)
            defer { setenv("KEYDROP_FAKE_CC_RUNNING", "1", 1) }
            let (e2, c2) = makeEnv("pipe-livegate-direct")
            defer { e2.cleanup() }
            _ = try! c2.add(raw: "https://gate.example.com/v1 sk-gatedirect1111111",
                            ccOverride: true, cpaOverride: false, dshOverride: false,
                            models: ["claude-sonnet-4-5"], force: true, appType: "claude", appTypeForced: true)
            t.contains(e2.read("claude.json"), "sk-gatedirect1111111", "[直连] 写 live claude.json")
        }
    }

    private static func firstID(_ core: Core, key: String) -> String {
        core.history.findActiveByKey(key)?.id ?? ""
    }
}
