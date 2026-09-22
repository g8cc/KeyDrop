import Foundation
import KeyDropCore

enum ProxyPoolTests {
    static func run(_ h: Harness) {
        h.runSuite("ProxyPool.代理列表解析") { t in
            // 真实事故形态:从订阅/服务商导出的列表格式混杂 —— 裸 host:port、带协议、注释、空行、重复
            let text = """
            # 主力住宅代理
            1.2.3.4:8080
            http://5.6.7.8:3128
            socks5://user:pass@9.9.9.9:1080
            socks5h://u:p@10.0.0.1:7891

            1.2.3.4:8080
            http://1.2.3.4:8080
            """
            let list = ProxyPool.loadProxyList(text)
            t.equal(list.count, 4, "裸地址补 http:// + 去重(含协议差异视为同一条?)")
            // 1.2.3.4:8080 补协议后与 http://1.2.3.4:8080 相同 → 去重为一条
            t.expect(list.contains("http://1.2.3.4:8080"), "裸地址补 http://")
            t.expect(list.contains("socks5://user:pass@9.9.9.9:1080"), "socks5 带认证保留")
            t.expect(list.contains("socks5h://u:p@10.0.0.1:7891"), "socks5h 保留")
        }

        h.runSuite("ProxyPool.账号扫描") { t in
            let env = try! TestEnv()
            let dir = env.dir + "/auth-dir"
            try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            func write(_ name: String, _ obj: [String: Any]) {
                let data = try! JSONSerialization.data(withJSONObject: obj)
                try! data.write(to: URL(fileURLWithPath: dir + "/" + name))
            }
            write("a1@x.com.json", ["type": "xai", "email": "a1@x.com", "access_token": "t1"])
            write("a2@x.com.json", ["type": "xai", "email": "a2@x.com", "disabled": true, "proxy_url": "http://1.1.1.1:1"])
            write("a3@x.com.json", ["type": "xai", "email": "a3@x.com", "proxy-url": "http://2.2.2.2:2"])
            write("gemini.json", ["type": "gemini", "email": "g@g.com"])
            try! "{oops".data(using: .utf8)!.write(to: URL(fileURLWithPath: dir + "/broken.json"))

            let all = ProxyPool.scanAccounts(authDir: dir)
            t.equal(all.count, 4, "损坏 json 跳过,其余全扫")
            let xai = ProxyPool.scanAccounts(authDir: dir, types: ["xai"])
            t.equal(xai.count, 3, "类型过滤")
            let a3 = xai.first { $0.accountID == "a3@x.com" }
            t.equal(a3?.existingProxy, "http://2.2.2.2:2", "proxy-url 连字符键也识别")
            t.equal(xai.first { $0.accountID == "a2@x.com" }?.disabled, true, "disabled 识别")
            t.expect(xai.allSatisfy { !$0.path.isEmpty }, "路径非空")
        }

        h.runSuite("ProxyPool.粘性绑定计划") { t in
            func acc(_ id: String, _ proxy: String?) -> ProxyPool.PoolAccount {
                ProxyPool.PoolAccount(path: "/" + id + ".json", fileName: id + ".json", accountID: id,
                                      type: "xai", disabled: false, existingProxy: proxy)
            }
            func p(_ url: String, _ s: ProxyPool.PoolProxy.Status) -> ProxyPool.PoolProxy {
                ProxyPool.PoolProxy(url: url, status: s, latencyMs: 0)
            }

            // 场景 1:既有绑定存活 → 粘性保留,绝不洗牌(换 IP = 风控事件)
            var plan = ProxyPool.planBinding(
                accounts: [acc("k1", "http://a:1"), acc("k2", "http://b:2")],
                proxies: [p("http://a:1", .alive), p("http://b:2", .alive), p("http://c:3", .alive)])
            t.equal(plan.bindings.first { $0.accountID == "k1" }?.action, .kept, "存活绑定保留")
            t.equal(plan.bindings.first { $0.accountID == "k2" }?.newProxy, "http://b:2", "保留时 new == old")
            t.equal(plan.spares.count, 1, "剩余备用")

            // 场景 2:绑定死亡 → 从备用按序替换;新账号按序分配
            plan = ProxyPool.planBinding(
                accounts: [acc("dead", "http://a:1"), acc("new1", nil), acc("new2", nil)],
                proxies: [p("http://a:1", .dead), p("http://b:2", .alive), p("http://c:3", .alive), p("http://d:4", .alive)])
            let r1 = plan.bindings.first { $0.accountID == "dead" }
            t.equal(r1?.action, .replaced, "死亡绑定被替换")
            t.equal(r1?.newProxy, "http://b:2", "替换取第一个存活备用")
            t.equal(plan.bindings.first { $0.accountID == "new1" }?.newProxy, "http://c:3", "新账号按序分配")
            t.equal(plan.bindings.first { $0.accountID == "new2" }?.newProxy, "http://d:4", "新账号按序分配 2")
            t.equal(plan.spares, [], "b/c/d 全部占用,备用为空")

            // 场景 2b:死亡的代理即便后续变存活也应可复用(本次死了就出局)
            plan = ProxyPool.planBinding(
                accounts: [acc("x", "http://a:1")],
                proxies: [p("http://a:1", .dead), p("http://a:1", .alive)])
            // 同 URL 两状态:status 字典 uniquing 取先出现的 dead(首次出现为准)
            t.equal(plan.bindings.first?.action, .cleared, "重复 URL 首次状态为准,死亡且无备用 → 清除")

            // 场景 3:代理耗尽 → 有死亡旧绑定清除回落全局,无绑定不动
            plan = ProxyPool.planBinding(
                accounts: [acc("d1", "http://a:1"), acc("n1", nil)],
                proxies: [p("http://a:1", .dead)])
            t.equal(plan.bindings.first { $0.accountID == "d1" }?.action, .cleared, "耗尽 + 旧绑定死亡 → 清除")
            t.equal(plan.bindings.first { $0.accountID == "n1" }?.action, .untouched, "耗尽 + 无绑定 → 不动")

            // 场景 4:池外绑定默认保留,strict 才接管
            plan = ProxyPool.planBinding(
                accounts: [acc("manual", "http://outside:1")],
                proxies: [p("http://in:2", .alive)])
            t.equal(plan.bindings.first?.action, .kept, "池外绑定默认视为手动管理")
            plan = ProxyPool.planBinding(
                accounts: [acc("manual", "http://outside:1")],
                proxies: [p("http://in:2", .alive)], strictPoolOnly: true)
            t.equal(plan.bindings.first?.action, .replaced, "strict 接管池外绑定 = 替换原代理")
            t.equal(plan.bindings.first?.oldProxy, "http://outside:1", "替换记录原池外代理")
            t.equal(plan.bindings.first?.newProxy, "http://in:2", "strict 分配池内存活代理")

            // 场景 5:数量翻转(代理 3 个、账号 1 个)→ 2 个留空备用
            plan = ProxyPool.planBinding(
                accounts: [acc("only", nil)],
                proxies: [p("http://a:1", .alive), p("http://b:2", .alive), p("http://c:3", .alive)])
            t.equal(plan.bindings.first?.newProxy, "http://a:1", "按序取第一个")
            t.equal(plan.spares, ["http://b:2", "http://c:3"], "剩余留空作备用")
        }

        h.runSuite("ProxyPool.写回auth文件") { t in
            let env = try! TestEnv()
            let dir = env.dir + "/auth-dir"
            try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let configWithDocker = "proxy-url: \"http://host.docker.internal:7890\"\nauth-dir: /root/.cli-proxy-api\n"
            // 真实事故形态 1:loopback 代理在 docker 部署下必须改写,否则容器内不可达,整批 key 全废
            let a1 = dir + "/u1.json"
            let obj1: [String: Any] = ["type": "xai", "email": "u1@x.com", "access_token": "tok", "refresh_token": "r", "expired": "2030-01-01"]
            try! JSONSerialization.data(withJSONObject: obj1).write(to: URL(fileURLWithPath: a1))
            let acc1 = ProxyPool.PoolAccount(path: a1, fileName: "u1.json", accountID: "u1@x.com", type: "xai", disabled: false, existingProxy: nil)
            let b1 = ProxyPool.PoolBinding(accountID: "u1@x.com", fileName: "u1.json", oldProxy: nil,
                                           newProxy: "socks5://127.0.0.1:7891", action: .assigned, note: "新绑定")
            try! ProxyPool.apply(bindings: [b1], accounts: [acc1], configContent: configWithDocker)
            let out1 = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: a1))) as! [String: Any]
            t.equal(out1["proxy_url"] as? String, "socks5://host.docker.internal:7891", "loopback 改写 host.docker.internal")
            t.equal(out1["access_token"] as? String, "tok", "既有字段保留")
            t.equal(out1["refresh_token"] as? String, "r", "既有字段保留 2")

            // 非回环地址不改写
            let b2 = ProxyPool.PoolBinding(accountID: "u1@x.com", fileName: "u1.json", oldProxy: nil,
                                           newProxy: "http://5.6.7.8:3128", action: .replaced, note: "替换")
            try! ProxyPool.apply(bindings: [b2], accounts: [acc1], configContent: configWithDocker)
            let out2 = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: a1))) as! [String: Any]
            t.equal(out2["proxy_url"] as? String, "http://5.6.7.8:3128", "公网代理原样写入")

            // cleared:删字段回落全局代理;kept/untouched 不写
            let clear = ProxyPool.PoolBinding(accountID: "u1@x.com", fileName: "u1.json", oldProxy: "http://5.6.7.8:3128",
                                              newProxy: nil, action: .cleared, note: "清除")
            try! ProxyPool.apply(bindings: [clear], accounts: [acc1], configContent: configWithDocker)
            let out3 = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: a1))) as! [String: Any]
            t.expect(out3["proxy_url"] == nil, "cleared 删除 proxy_url")
            let keep = ProxyPool.PoolBinding(accountID: "u1@x.com", fileName: "u1.json", oldProxy: "x", newProxy: "x", action: .kept, note: "保留")
            let before = try? FileManager.default.attributesOfItem(atPath: a1)[.modificationDate]
            try! ProxyPool.apply(bindings: [keep], accounts: [acc1], configContent: configWithDocker)
            let after = try? FileManager.default.attributesOfItem(atPath: a1)[.modificationDate]
            t.equal(before as? Date, after as? Date, "kept 零改动(粘性)")

            // 非 docker 配置:loopback 原样保留
            let b3 = ProxyPool.PoolBinding(accountID: "u1@x.com", fileName: "u1.json", oldProxy: nil,
                                           newProxy: "http://127.0.0.1:7890", action: .assigned, note: "")
            try! ProxyPool.apply(bindings: [b3], accounts: [acc1], configContent: "proxy-url: \"\"\n")
            let out4 = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: a1))) as! [String: Any]
            t.equal(out4["proxy_url"] as? String, "http://127.0.0.1:7890", "非 docker 不改写")
        }

        h.runSuite("ProxyPool.未绑定检测") { t in
            let env = try! TestEnv()
            let dir = env.dir + "/auth-dir"
            try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            func write2(_ name: String, _ obj: [String: Any]) {
                try! JSONSerialization.data(withJSONObject: obj).write(to: URL(fileURLWithPath: dir + "/" + name))
            }
            write2("b1.json", ["type": "xai", "email": "b1@x.com"])
            write2("b2.json", ["type": "xai", "email": "b2@x.com", "proxy_url": "http://1.1.1.1:1"])
            // 真实事故形态:用户手动停用的账号不该被提醒/分配(不替他做主)
            write2("b3.json", ["type": "xai", "email": "b3@x.com", "disabled": true])
            let unbound = ProxyPool.unboundAccounts(authDir: dir)
            t.equal(unbound.map(\.accountID), ["b1@x.com"], "只算未绑定且未禁用")
        }

        h.runSuite("ProxyPool.代理输入规范化") { t in
            // 真实事故形态:顶部代理框要手打完整 URL 还显示不全 —— 支持缩写输入
            t.equal(Core.normalizeProxyInput("7890"), "http://127.0.0.1:7890", "纯端口 → 本机回环")
            t.equal(Core.normalizeProxyInput("127.0.0.1:7891"), "http://127.0.0.1:7891", "host:port 补 scheme")
            t.equal(Core.normalizeProxyInput("localhost:7890"), "http://localhost:7890", "localhost:port 补 scheme")
            t.equal(Core.normalizeProxyInput("socks5://u:p@1.2.3.4:1080"), "socks5://u:p@1.2.3.4:1080", "已带 scheme 原样")
            t.equal(Core.normalizeProxyInput(""), "", "空串原样")
            t.equal(Core.normalizeProxyInput("  7890  "), "http://127.0.0.1:7890", "首尾空白容忍")
            t.equal(Core.normalizeProxyInput("99999"), "99999", "非法端口不猜测,原样返回")
            t.equal(Core.normalizeProxyInput("socks5h://host:1080"), "socks5h://host:1080", "socks5h 原样")
        }

        h.runSuite("ProxyPool.探测判活") { t in
            // 真实事故形态:不可用代理必须剔除。判活标准:收到任意 HTTP 状态码即存活
            // (403/429 只证明出口可达目标);407(要求认证)= 配错按死亡;超时/连接失败 = 死亡
            // 本地起一个一定拒连的端口验证死亡路径(不依赖外网)
            let dead = ProxyPool.probeOne(url: "http://127.0.0.1:1", target: "https://grok.com", timeout: 2)
            t.equal(dead.status, .dead, "拒连端口判死")
            // 无效 URL 也判死且不崩溃
            let bad = ProxyPool.probeOne(url: "http://", target: "https://grok.com", timeout: 2)
            t.equal(bad.status, .dead, "无效 URL 判死")
        }
    }
}
