import Foundation
import KeyDropCore

/// CPA 管理 API 双轨(v1.4.13 真实事故:CPA 数据目录在 ~/Documents 下,
/// KeyDrop 每次导入/扫描/代理池绑定直接读写文件 → macOS TCC 反复弹「文稿」。
/// 配置管理密钥后全部走 /v0/management/*,本地文件零触达;未配置回退文件模式)
enum CPAAAPITests {
    static func run(_ h: Harness) {
        h.runSuite("CPAAPI") { t in
            guard let server = try? MockHTTPServer(mode: .cpaMgmt) else {
                t.expect(false, "mock 启动失败")
                return
            }
            let origKey = Prefs.shared.cpaManagementKey
            let origBase = Prefs.shared.cpaAPIBase
            let origProxy = Prefs.shared.proxy
            Prefs.shared.proxy = ""   // API 走 127.0.0.1 本机,绝不能套本机代理
            Prefs.shared.cpaManagementKey = "test-key"
            Prefs.shared.cpaAPIBase = "http://127.0.0.1:\(server.port)"
            defer {
                Prefs.shared.cpaManagementKey = origKey
                Prefs.shared.cpaAPIBase = origBase
                Prefs.shared.proxy = origProxy
            }

            // 1. 读配置走 GET,拿到的是 mock 里的哨兵 YAML(而非本地文件)
            do {
                let text = try CPAAPI.readConfigText(path: "/nonexistent/should-not-be-read.yaml")
                t.expect(text.contains("# cpa-mgmt-sentinel"), "GET config.yaml 返回哨兵内容")
            } catch {
                t.expect(false, "读配置失败: \(error)")
            }

            // 2. 写配置走 PUT,服务端收到完整正文
            do {
                try CPAAPI.writeConfigText("# replaced-by-test\nport: 8317\n", path: "/nonexistent/x.yaml")
                server.mgmtLock.lock()
                let put = server.cpaPutBody
                server.mgmtLock.unlock()
                t.equal(put, "# replaced-by-test\nport: 8317\n", "PUT 正文=完整 YAML")
            } catch {
                t.expect(false, "写配置失败: \(error)")
            }

            // 3. 鉴权:错误密钥 401
            Prefs.shared.cpaManagementKey = "wrong-key"
            do {
                _ = try CPAAPI.readConfigText(path: "/x")
                t.expect(false, "错误密钥应当抛错")
            } catch let e as CPAAPIError {
                t.expect(e.localizedDescription.contains("401"), "错误密钥 → HTTP 401")
            } catch {
                t.expect(false, "错误密钥抛了别的错: \(error)")
            }
            Prefs.shared.cpaManagementKey = "test-key"

            // 4. 密钥为空 → apiMode=false → 回退文件模式(读真实路径,应报文件不存在而非 401)
            Prefs.shared.cpaManagementKey = ""
            do {
                _ = try CPAAPI.readConfigText(path: "/nonexistent/fallback.yaml")
                t.expect(false, "文件模式读不存在路径应抛错")
            } catch let e as CPAAPIError {
                t.expect(false, "空密钥不该走 API: \(e)")
            } catch {
                t.expect(true, "空密钥回退文件模式(文件不存在报 NSCocoaError)")
            }
            Prefs.shared.cpaManagementKey = "test-key"

            // 5. auth 文件列表
            do {
                let names = try CPAAPI.listAuthFileNames()
                t.equal(names, ["acc-a.json"], "auth-files 列表")
            } catch {
                t.expect(false, "列表失败: \(error)")
            }

            // 6. auth 文件下载原文可解析
            do {
                let data = try CPAAPI.authFileData(fileName: "acc-a.json")
                let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                t.equal(obj?["email"] as? String, "a@x.com", "下载原文含 email")
            } catch {
                t.expect(false, "下载失败: \(error)")
            }

            // 7. 代理池 PATCH:proxy_url 写入 + 空串清除
            do {
                try CPAAPI.patchAuthFile(name: "acc-a.json", fields: ["proxy_url": "http://1.2.3.4:8080"])
                server.mgmtLock.lock()
                let patchBody = server.cpaPatchBody
                server.mgmtLock.unlock()
                t.expect(patchBody.contains("\"proxy_url\":\"http:\\/\\/1.2.3.4:8080\"") || patchBody.contains("\"proxy_url\": \"http://1.2.3.4:8080\""),
                         "PATCH 含 proxy_url")
                let obj = try JSONSerialization.jsonObject(with: CPAAPI.authFileData(fileName: "acc-a.json")) as? [String: Any]
                t.equal(obj?["proxy_url"] as? String, "http://1.2.3.4:8080", "PATCH 后下载原文反映新代理")
                try CPAAPI.patchAuthFile(name: "acc-a.json", fields: ["proxy_url": ""])
                let obj2 = try JSONSerialization.jsonObject(with: CPAAPI.authFileData(fileName: "acc-a.json")) as? [String: Any]
                t.equal(obj2?["proxy_url"] as? String, "", "空串 = 清除")
            } catch {
                t.expect(false, "PATCH 失败: \(error)")
            }

            // 8. 真实事故回归:API 模式下本地文件零触达
            do {
                let tmp = NSTemporaryDirectory() + "cpaapi-sentinel-\(UUID().uuidString.prefix(6)).yaml"
                let sentinel = "# local-file-sentinel\n"
                try sentinel.write(toFile: tmp, atomically: true, encoding: .utf8)
                defer { try? FileManager.default.removeItem(atPath: tmp) }
                // API 模式下 read/write 都必须走 mock,本地哨兵文件内容不得变化
                let read = try CPAAPI.readConfigText(path: tmp)
                t.expect(!read.contains("# local-file-sentinel"), "API 模式读的是远端而非本地哨兵")
                try CPAAPI.writeConfigText("# via-api\n", path: tmp)
                let local = try String(contentsOfFile: tmp, encoding: .utf8)
                t.equal(local, sentinel, "本地文件内容分毫未动")
                t.expect(!FileManager.default.fileExists(atPath: tmp + ".keydrop-bak"), "不产生备份文件")
            } catch {
                t.expect(false, "零触达回归失败: \(error)")
            }

            // 9. 代理池扫描(API 模式)
            do {
                let accounts = ProxyPool.scanAccounts(authDir: "/nonexistent", types: ["xai"])
                t.equal(accounts.count, 1, "API 模式扫描到 1 个 xai 账号")
                t.equal(accounts.first?.fileName, "acc-a.json", "文件名正确")
                t.equal(accounts.first?.existingProxy, nil as String?, "清除后 existingProxy=nil(未绑定)")
                let unbound = ProxyPool.unboundAccounts(authDir: "/nonexistent", types: ["xai"])
                t.equal(unbound.count, 1, "清除后视为未绑定")
            } catch {
                t.expect(false, "API 扫描失败: \(error)")
            }

            // 10. 代理池 apply(API 模式):绑定写入 PATCH,且 loopback 改写仍生效
            do {
                let account = ProxyPool.PoolAccount(path: "", fileName: "acc-a.json",
                                                    accountID: "a@x.com", type: "xai",
                                                    disabled: false, existingProxy: nil)
                let binding = ProxyPool.PoolBinding(accountID: "a@x.com", fileName: "acc-a.json",
                                                    oldProxy: nil, newProxy: "http://127.0.0.1:7890",
                                                    action: .assigned, note: "t")
                let written = try ProxyPool.apply(bindings: [binding], accounts: [account],
                                                  configContent: "port: 8317\n# docker: host.docker.internal\n")
                t.equal(written, 1, "API 模式 apply 写入 1 个")
                server.mgmtLock.lock()
                let patch = server.cpaPatchBody
                server.mgmtLock.unlock()
                // loopback 127.0.0.1 → host.docker.internal(docker 容器访问宿主机)
                t.expect(patch.contains("host.docker.internal"), "loopback 已改写为 host.docker.internal")
                let obj = try JSONSerialization.jsonObject(with: CPAAPI.authFileData(fileName: "acc-a.json")) as? [String: Any]
                t.equal(obj?["proxy_url"] as? String, "http://host.docker.internal:7890", "凭据文件反映改写后代理")
            } catch {
                t.expect(false, "apply 失败: \(error)")
            }
        }
    }
}
