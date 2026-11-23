import Foundation
import KeyDropCore

private final class ConcurrentCPAConfigServer {
    private let listener: TCPServer
    private let lock = NSLock()
    private let secondRead = DispatchSemaphore(value: 0)
    private var reads = 0
    private var config = "port: 8317\n"
    var port: Int { listener.port }
    var configText: String {
        lock.lock(); defer { lock.unlock() }
        return config
    }

    init() throws {
        listener = try TCPServer()
        Thread.detachNewThread {
            for _ in 0..<4 {
                guard let client = self.listener.accept() else { return }
                Thread.detachNewThread { self.handle(client) }
            }
        }
    }

    private func handle(_ client: SocketClient) {
        defer { client.close() }
        guard let request = client.readRequest() else { return }
        let response: String
        if request.hasPrefix("GET ") {
            lock.lock()
            response = config
            reads += 1
            let first = reads == 1
            lock.unlock()
            // A second unprotected GET reads the same snapshot before either PUT.
            if first { _ = secondRead.wait(timeout: .now() + 0.5) }
            else { secondRead.signal() }
        } else {
            var body = request.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
            let lengthLine = request.components(separatedBy: "\r\n")
                .first { $0.lowercased().hasPrefix("content-length:") } ?? ""
            let length = Int(lengthLine.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
            if body.utf8.count < length { body += client.readBody(toLength: length - body.utf8.count) }
            lock.lock()
            config = body
            lock.unlock()
            response = "{}"
        }
        client.write("HTTP/1.1 200 OK\r\nContent-Length: \(response.utf8.count)\r\nConnection: close\r\n\r\n\(response)")
    }
}

/// CPA 管理 API 双轨(v1.4.13 真实事故:CPA 数据目录在 ~/Documents 下,
/// KeyDrop 每次导入/扫描/代理池绑定直接读写文件 → macOS TCC 反复弹「文稿」。
/// 配置管理密钥后全部走 /v0/management/*,本地文件零触达;未配置回退文件模式)
enum CPAAAPITests {
    static func run(_ h: Harness) {
        h.runSuite("CPAAPI.model audit reads and replaces YAML variants") { t in
            let variants: [(String, String)] = [
                ("reordered", "    models:\n      - alias: preserve-alias\n        name: 'model-a' # selected\n"),
                ("commented", "    models: # curated\n# a comment within the model list\n      - name: model-a\n        alias: preserve-alias\n"),
                ("indentless", "    models:\n    - name: model-a\n      alias: preserve-alias\n"),
                ("spaced", "    models:\n      -   name: model-a\n          alias: preserve-alias\n"),
                ("standalone", "    models:\n      -\n          alias: preserve-alias\n          name: model-a\n"),
                ("quoted", "    models:\n      - name: \"model-a\" # quoted model ID\n        alias: preserve-alias\n")
            ]
            for (label, modelLines) in variants {
                let env = try TestEnv("model-audit-replace-\(label)")
                defer { env.cleanup() }
                let fixture = "port: 8317\nopenai-compatibility:\n  - name: models\n    base-url: https://models.example/v1\n" + modelLines
                    + "    api-key-entries:\n      - api-key: sk-model-fixture1111\n  - name: untouched\n    base-url: https://untouched.example/v1\n    models:\n      - name: untouched-model\n"
                env.write("cpa-config.yaml", fixture)
                let writer = CPAWriter(configPath: env.dir + "/cpa-config.yaml")
                t.equal(writer.entryModels(baseURL: "https://models.example/v1"), ["model-a"], "\(label) 读取真实模型 ID")
                do {
                    _ = try writer.updateAggregatedModels(baseURL: "https://models.example/v1", models: ["model-b"])
                    let config = env.read("cpa-config.yaml")
                    t.equal(writer.entryModels(baseURL: "https://models.example/v1"), ["model-b"], "\(label) 更新后只剩本次选择")
                    t.expect(!config.contains("model-a"), "\(label) 移除旧模型")
                    t.contains(config, "sk-model-fixture1111", "\(label) 保留凭据池")
                    t.contains(config, "untouched-model", "\(label) 不修改相邻 provider")
                } catch {
                    t.expect(false, "\(label) 合法 YAML 更新失败: \(error.localizedDescription)")
                }
            }
        }
        h.runSuite("CPAAPI.model audit image updates are idempotent") { t in
            let variants: [(String, String)] = [
                ("reordered", "    models:\n      - alias: preserve-alias\n        name: model-a\n        image: false\n"),
                ("commented", "    models: # curated image models\n# comment before image model\n      - name: model-a\n        alias: preserve-alias\n"),
                ("indentless", "    models:\n    - name: model-a\n      alias: preserve-alias\n"),
                ("spaced", "    models:\n      -   name: model-a\n          alias: preserve-alias\n          image: false\n"),
                ("standalone", "    models:\n      -\n          name: model-a\n          alias: preserve-alias\n"),
                ("image-first", "    models:\n      - image: false\n        name: model-a\n        alias: preserve-alias\n")
            ]
            for (label, modelLines) in variants {
                let env = try TestEnv("model-audit-image-\(label)")
                defer { env.cleanup() }
                env.write("cpa-config.yaml", "port: 8317\nopenai-compatibility:\n  - name: models.example-image\n    base-url: https://models.example/v1\n"
                          + modelLines + "    api-key-entries:\n      - api-key: sk-model-fixture1111\n")
                let writer = CPAWriter(configPath: env.dir + "/cpa-config.yaml")
                do {
                    _ = try writer.addImageChannel(baseURL: "https://models.example/v1", key: "sk-model-fixture1111", models: ["model-a"])
                    let first = env.read("cpa-config.yaml")
                    t.equal(first.components(separatedBy: "name: model-a").count - 1, 1, "\(label) 不重复追加模型")
                    t.expect(!first.contains("image: false"), "\(label) 原模型 image 标记原位更新")
                    t.contains(first, "preserve-alias", "\(label) 保留用户别名")
                    _ = try writer.addImageChannel(baseURL: "https://models.example/v1", key: "sk-model-fixture1111", models: ["model-a"])
                    t.equal(env.read("cpa-config.yaml"), first, "\(label) 重复导入幂等")
                    _ = try writer.addImageChannel(baseURL: "https://models.example/v1", key: "sk-model-fixture1111", models: ["model-b"])
                    t.equal(writer.entryModels(baseURL: "https://models.example/v1"), ["model-a", "model-b"], "\(label) 新模型追加为同级子项")
                } catch {
                    t.expect(false, "\(label) 合法图片模型更新失败: \(error.localizedDescription)")
                }
            }
        }
        h.runSuite("CPAAPI.model audit models may be the first property") { t in
            let env = try TestEnv("model-audit-first-property")
            defer { env.cleanup() }
            env.write("cpa-config.yaml", """
            port: 8317
            openai-compatibility:
              - models:
                  - name: model-a
                    alias: preserve-alias
                name: models.example-image
                base-url: https://models.example/v1
                api-key-entries:
                  - api-key: sk-model-fixture1111
            """)
            let writer = CPAWriter(configPath: env.dir + "/cpa-config.yaml")
            t.equal(writer.entryModels(baseURL: "https://models.example/v1"), ["model-a"], "首属性 models 可以读取")
            _ = try writer.addImageChannel(baseURL: "https://models.example/v1", key: "sk-model-fixture1111", models: ["model-a"])
            t.equal(env.read("cpa-config.yaml").components(separatedBy: "models:").count - 1, 1, "不重复追加 models 属性")
            _ = try writer.updateAggregatedModels(baseURL: "https://models.example/v1", models: ["model-b"])
            t.equal(writer.entryModels(baseURL: "https://models.example/v1"), ["model-b"], "替换首属性 models 下的列表")
        }
        h.runSuite("CPAAPI.model audit expands explicit empty lists") { t in
            for operation in ["replace", "image"] {
                let env = try TestEnv("model-audit-empty-\(operation)")
                defer { env.cleanup() }
                env.write("cpa-config.yaml", """
                port: 8317
                openai-compatibility:
                  - name: models.example-image
                    base-url: https://models.example/v1
                    models: [] # no selected models yet
                    api-key-entries:
                      - api-key: sk-model-fixture1111
                """)
                let writer = CPAWriter(configPath: env.dir + "/cpa-config.yaml")
                do {
                    if operation == "replace" {
                        _ = try writer.updateAggregatedModels(baseURL: "https://models.example/v1", models: ["model-a"])
                    } else {
                        _ = try writer.addImageChannel(baseURL: "https://models.example/v1", key: "sk-model-fixture1111", models: ["model-a"])
                    }
                    t.equal(writer.entryModels(baseURL: "https://models.example/v1"), ["model-a"], "\(operation) 空列表可扩展")
                    t.equal(env.read("cpa-config.yaml").components(separatedBy: "models:").count - 1, 1, "\(operation) 不重复建段")
                } catch {
                    t.expect(false, "\(operation) 空列表扩展失败: \(error.localizedDescription)")
                }
            }
        }
        h.runSuite("CPAAPI.model audit preserves curated models during key merge") { t in
            let env = try TestEnv("model-audit-curated")
            defer { env.cleanup() }
            let server = try MockHTTPServer(mode: .openAI)
            let url = "http://127.0.0.1:\(server.port)/v1"
            env.write("cpa-config.yaml", "port: 8317\nopenai-compatibility:\n  - name: manual\n    base-url: \(url)\n    models: # curated\n      - alias: favorite-model\n        name: model-a\n    api-key-entries:\n      - api-key: sk-previous-fixture1111\n")
            Prefs.shared.cpaResident = false
            let core = Core()
            _ = try core.add(raw: "\(url)\nsk-new-model-fixture2222", ccOverride: false, grokOverride: false,
                             cpaOverride: true, dshOverride: false, models: ["model-b"], force: true)
            let writer = CPAWriter(configPath: env.dir + "/cpa-config.yaml")
            t.equal(writer.entryModels(baseURL: url), ["model-a", "model-b"], "保留手写精选模型并加入本次明确选择")
            t.contains(env.read("cpa-config.yaml"), "alias: favorite-model", "合并选择不改变手写模型别名")
            t.contains(env.read("cpa-config.yaml"), "sk-new-model-fixture2222", "新凭据仍成功合并")
            _ = try writer.updateAggregatedModels(baseURL: url, models: ["model-c"], removing: ["model-b"])
            t.equal(writer.entryModels(baseURL: url), ["model-a", "model-c"], "局部改选保留非本条目模型")
            t.contains(env.read("cpa-config.yaml"), "alias: favorite-model", "局部改选必须保留其他模型的自定义别名")
        }
        h.runSuite("CPAAPI.cross-review spaced credential indentation") { t in
            let env = try TestEnv("cross-review-spaced-key")
            defer { env.cleanup() }
            env.write("cpa-config.yaml", """
            port: 8317
            openai-compatibility:
              - name: spaced
                base-url: https://spaced.example/v1
                api-key-entries:
                  -   api-key: sk-spaced-fixture1111
                      proxy-url: http://preserve-proxy.example:1234
            """)
            let writer = CPAWriter(configPath: env.dir + "/cpa-config.yaml")
            let result = try writer.rotateKey(baseURL: "https://spaced.example/v1",
                                               oldKey: "sk-spaced-fixture1111", newKey: "sk-rotated-fixture2222")
            t.expect(!result.isEmpty, "多空格序列属性仍可轮换")
            t.contains(env.read("cpa-config.yaml"), "-   api-key: sk-rotated-fixture2222", "保留 dash 后原始缩进")
            t.contains(env.read("cpa-config.yaml"), "proxy-url: http://preserve-proxy.example:1234", "保留凭据的代理属性")
        }
        h.runSuite("CPAAPI.cross-review standalone dash mapping merge") { t in
            let env = try TestEnv("cross-review-standalone-dash")
            defer { env.cleanup() }
            env.write("cpa-config.yaml", """
            port: 8317
            openai-compatibility:
              -
                  name: image.example-image
                  base-url: https://image.example/v1
                  models:
                    - name: image-test
                      alias: image-test
                      image: true
            """)
            let writer = CPAWriter(configPath: env.dir + "/cpa-config.yaml")
            _ = try writer.addImageChannel(baseURL: "https://image.example/v1", key: "sk-merged-fixture1111", models: ["image-test"])
            t.contains(env.read("cpa-config.yaml"), "sk-merged-fixture1111", "独立 dash 及可变属性缩进可合并")
        }
        h.runSuite("CPAAPI.cross-review standalone dash image models") { t in
            let env = try TestEnv("cross-review-standalone-image-models")
            defer { env.cleanup() }
            env.write("cpa-config.yaml", """
            port: 8317
            openai-compatibility:
              -
                  name: image.example-image
                  base-url: https://image.example/v1
                  api-key-entries:
                    - api-key: sk-image-fixture1111
            """)
            let writer = CPAWriter(configPath: env.dir + "/cpa-config.yaml")
            _ = try writer.addImageChannel(baseURL: "https://image.example/v1", key: "sk-image-fixture1111", models: ["image-test"])
            let config = env.read("cpa-config.yaml")
            t.contains(config, "      models:", "models 按已有属性缩进补建")
            t.contains(config, "image: true", "新增图片模型保留 image 标记")
            t.equal(config.components(separatedBy: "sk-image-fixture1111").count - 1, 1, "不重复插入已有 key")
        }
        h.runSuite("CPAAPI.cross-review standalone dash model update") { t in
            let env = try TestEnv("cross-review-standalone-model-update")
            defer { env.cleanup() }
            env.write("cpa-config.yaml", """
            port: 8317
            openai-compatibility:
              -
                  name: models
                  base-url: https://models.example/v1
                  api-key-entries:
                    - api-key: sk-models-fixture1111
            """)
            let writer = CPAWriter(configPath: env.dir + "/cpa-config.yaml")
            _ = try writer.updateAggregatedModels(baseURL: "https://models.example/v1", models: ["model-test"])
            let config = env.read("cpa-config.yaml")
            t.contains(config, "      models:", "缺失模型段按已有属性缩进补建")
            t.equal(writer.entryModels(baseURL: "https://models.example/v1"), ["model-test"], "写入模型可重新读取")
            t.contains(config, "sk-models-fixture1111", "模型更新保留凭据池")
        }
        h.runSuite("CPAAPI.writer rotated and merged reordered keys") { t in
            let env = try TestEnv("writer-reaudit-rotation")
            defer { env.cleanup() }
            env.write("cpa-config.yaml", """
            port: 8317
            openai-compatibility: # preserve providers
            - base-url: https://image.example/v1 # preserve URL
              name: image.example-image # name is not the first property
              api-key-entries:
              # key entries use an indentless sequence
              - proxy-url: http://preserve-proxy.example:1234
                api-key: 'sk-rotate-fixture1111' # credential is not the first property
              models:
                - name: image-test
                  alias: image-test
                  image: true
            """)
            let writer = CPAWriter(configPath: env.dir + "/cpa-config.yaml")
            let rotated = try writer.rotateKey(baseURL: "https://image.example/v1/",
                                               oldKey: "sk-rotate-fixture1111", newKey: "sk-rotated-fixture2222")
            t.expect(!rotated.isEmpty, "找到重排和顶格子项里的 key")
            var config = env.read("cpa-config.yaml")
            t.expect(!config.contains("sk-rotate-fixture1111"), "原凭据已替换")
            t.contains(config, "http://preserve-proxy.example:1234", "轮换保留凭据级代理")
            _ = try writer.addImageChannel(baseURL: "https://image.example/v1", key: "sk-rotated-fixture2222", models: ["image-test"])
            _ = try writer.addImageChannel(baseURL: "https://image.example/v1", key: "sk-added-fixture3333", models: ["image-test"])
            config = env.read("cpa-config.yaml")
            t.equal(config.components(separatedBy: "sk-rotated-fixture2222").count - 1, 1, "重导入识别非首行的既有 key")
            t.equal(config.components(separatedBy: "image.example-image").count - 1, 1, "重导入不重复追加 provider")
            t.equal(config.components(separatedBy: "sk-added-fixture3333").count - 1, 1, "按既有顶格子项缩进合并新 key")
            t.contains(config, "# preserve providers", "保留段头注释")
        }
        h.runSuite("CPAAPI.writer nested fields cannot match credentials") { t in
            let env = try TestEnv("writer-reaudit-nested-key")
            defer { env.cleanup() }
            let fixture = """
            port: 8317
            claude-api-key:
              - api-key: sk-retain-fixture2222
                base-url: https://a.example/v1
                headers:
                  api-key: sk-delete-fixture1111
            """
            env.write("cpa-config.yaml", fixture)
            let core = Core()
            var record = HistoryTests.entry("yaml-delete-nested", ts: 1)
            record.key = "sk-delete-fixture1111"
            record.url = "https://a.example/v1"
            record.targets = ["cpa"]
            record.cpaConfigPath = env.dir + "/cpa-config.yaml"
            try core.history.append(record)
            _ = try core.delete(entryIDPrefix: record.id)
            t.equal(env.read("cpa-config.yaml"), fixture, "嵌套同名字段不能触发整条 provider 删除")
        }
        h.runSuite("CPAAPI.writer single quoted hash key") { t in
            let env = try TestEnv("writer-reaudit-quoted-key")
            defer { env.cleanup() }
            env.write("cpa-config.yaml", """
            port: 8317
            openai-compatibility:
                - name: quoted
                  base-url: https://quoted.example/v1
                  api-key-entries:
                    - api-key: 'sk-fixture'' #literal' # comment
                      proxy-url: http://preserve-proxy.example:1234
            """)
            let writer = CPAWriter(configPath: env.dir + "/cpa-config.yaml")
            let result = try writer.rotateKey(baseURL: "https://quoted.example/v1",
                                              oldKey: "sk-fixture' #literal", newKey: "sk-quoted-replacement")
            t.expect(!result.isEmpty, "单引号转义和引号内 # 不截断凭据")
            t.contains(env.read("cpa-config.yaml"), "sk-quoted-replacement", "非固定条目缩进下轮换成功")
            t.contains(env.read("cpa-config.yaml"), "http://preserve-proxy.example:1234", "保持其他属性")
        }
        h.runSuite("CPAAPI.writer duplicate mapping rejected before write") { t in
            let python = Process()
            python.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            python.arguments = ["-c", "import yaml"]
            python.standardError = FileHandle.nullDevice
            try python.run()
            python.waitUntilExit()
            guard python.terminationStatus == 0 else { return } // optional runtime validator
            let env = try TestEnv("writer-reaudit-duplicate-yaml")
            defer { env.cleanup() }
            let fixtures = [
                "port: 8317\nport: 9090\n",
                "port: 8317\nopenai-compatibility:\n  - name: existing\n    name: repeated\n    base-url: https://a.example/v1\n"
            ]
            for fixture in fixtures {
                env.write("cpa-config.yaml", fixture)
                do {
                    _ = try CPAWriter(configPath: env.dir + "/cpa-config.yaml")
                        .addImageChannel(baseURL: "https://image.example/v1", key: "sk-validator-fixture1111", models: ["image-test"])
                    t.expect(false, "重复 mapping key 必须拒绝写入")
                } catch {
                    t.contains(error.localizedDescription, "重复键", "说明真实的 YAML 重复键原因")
                }
                t.equal(env.read("cpa-config.yaml"), fixture, "预检拒绝时原配置逐字保留")
            }
        }
        h.runSuite("CPAAPI.writer scoped deletion YAML variants") { t in
            let fixtures = [
                "port: 8317\nclaude-api-key:\n  - base-url: https://a.example/v1\n    api-key: sk-delete-fixture1111\n  - api-key: sk-delete-fixture1111\n    base-url: https://b.example/v1\n",
                "port: 8317\nclaude-api-key: # flat providers\n  - api-key: 'sk-delete-fixture1111' # credential\n    base-url: \"https://a.example/v1\" # provider\n  - api-key: sk-delete-fixture1111\n    base-url: https://b.example/v1\n",
                "port: 8317\nopenai-compatibility:\n  - base-url: https://a.example/v1\n    name: first\n    api-key-entries:\n      - api-key: sk-delete-fixture1111\n  - name: second\n    base-url: https://b.example/v1\n    api-key-entries:\n      - api-key: sk-delete-fixture1111\n",
                "port: 8317\nopenai-compatibility: # providers\n- base-url: 'https://a.example/v1' # URL\n  name: first\n  api-key-entries:\n  - proxy-url: http://old-proxy.example:1234\n    api-key: 'sk-delete-fixture1111' # key\n- name: second\n  base-url: https://b.example/v1\n  api-key-entries:\n  - api-key: sk-delete-fixture1111\n"
            ]
            for (index, fixture) in fixtures.enumerated() {
                let env = try TestEnv("writer-reaudit-yaml-\(index)")
                defer { env.cleanup() }
                env.write("cpa-config.yaml", fixture)
                let core = Core()
                var record = HistoryTests.entry("yaml-delete-\(index)", ts: 1)
                record.key = "sk-delete-fixture1111"
                record.url = "https://a.example/v1/"
                record.targets = ["cpa"]
                record.cpaConfigPath = env.dir + "/cpa-config.yaml"
                try core.history.append(record)
                _ = try core.delete(entryIDPrefix: record.id)
                let config = env.read("cpa-config.yaml")
                t.expect(!config.contains("https://a.example/v1"), "字段序/注释/顶格列表变体 \(index) 删除正确地址")
                t.contains(config, "https://b.example/v1", "变体 \(index) 保留其他地址")
                t.equal(config.components(separatedBy: record.key!).count - 1, 1, "变体 \(index) 只保留其他 provider 的相同凭据")
            }
        }
        h.runSuite("CPAAPI.writer deletion removes key properties") { t in
            let env = try TestEnv("writer-reaudit-key-properties")
            defer { env.cleanup() }
            env.write("cpa-config.yaml", """
            port: 8317
            openai-compatibility:
              - name: first
                base-url: https://a.example/v1
                api-key-entries:
                  - api-key: sk-delete-fixture1111
                    proxy-url: http://old-proxy.example:1234
                  - api-key: sk-retain-fixture2222
                    proxy-url: http://keep-proxy.example:4321
            """)
            let core = Core()
            var record = HistoryTests.entry("yaml-delete-properties", ts: 1)
            record.key = "sk-delete-fixture1111"
            record.url = "https://a.example/v1"
            record.targets = ["cpa"]
            record.cpaConfigPath = env.dir + "/cpa-config.yaml"
            try core.history.append(record)
            _ = try core.delete(entryIDPrefix: record.id)
            let config = env.read("cpa-config.yaml")
            t.expect(!config.contains("sk-delete-fixture1111") && !config.contains("old-proxy"), "删除完整凭据子项与其代理属性")
            t.contains(config, "sk-retain-fixture2222", "保留下一把 key")
            t.contains(config, "http://keep-proxy.example:4321", "保留下一把 key 的原代理")
        }
        h.runSuite("WriterAudit.CPA 非法管理地址") { t in
            let env = try TestEnv("cpa-invalid-management-base")
            defer { env.cleanup() }
            Prefs.shared.cpaManagementKey = "test-key"
            defer {
                Prefs.shared.cpaManagementKey = nil
                Prefs.shared.cpaAPIBase = nil
            }
            for address in ["file:///tmp/config", "https://fixture:secret@example.invalid", "https://example.invalid/#fragment",
                            "https:///", "http://127.0.0.1:0", "http://127.0.0.1:65536"] {
                Prefs.shared.cpaAPIBase = address
                do {
                    _ = try CPAAPI.request("GET", "v0/management/config.yaml")
                    t.expect(false, "非法管理地址应在请求前拒绝")
                } catch let error as CPAAPIError {
                    t.contains(error.localizedDescription, "地址无效", "非法地址不会回落到默认服务")
                }
            }
        }
        h.runSuite("WriterAudit.CPA API 并发修改") { t in
            let env = try TestEnv("cpa-api-concurrent-config")
            defer { env.cleanup() }
            let server = try ConcurrentCPAConfigServer()
            Prefs.shared.cpaManagementKey = "test-key"
            Prefs.shared.cpaAPIBase = "http://127.0.0.1:\(server.port)"
            defer {
                Prefs.shared.cpaManagementKey = nil
                Prefs.shared.cpaAPIBase = nil
            }
            let resultLock = NSLock()
            var errors: [String] = []
            DispatchQueue.concurrentPerform(iterations: 2) { index in
                do {
                    _ = try CPAWriter(configPath: env.dir + "/untouched/config.yaml")
                        .addImageChannel(baseURL: "https://writer-\(index).example/v1",
                                         key: "sk-concurrent-fixture-\(index)", models: ["gpt-image-1"])
                } catch {
                    resultLock.lock()
                    errors.append(error.localizedDescription)
                    resultLock.unlock()
                }
            }
            t.expect(errors.isEmpty, "并发导入均成功")
            t.contains(server.configText, "sk-concurrent-fixture-0", "保留第一个并发配置修改")
            t.contains(server.configText, "sk-concurrent-fixture-1", "保留第二个并发配置修改")
            t.expect(!env.fileExists("untouched"), "API 模式未创建本地 CPA 配置目录")
        }
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

            // 9. 代理池扫描(API 模式;scanAccounts 内部处理错误不抛出)
            let accounts = ProxyPool.scanAccounts(authDir: "/nonexistent", types: ["xai"])
            t.equal(accounts.count, 1, "API 模式扫描到 1 个 xai 账号")
            t.equal(accounts.first?.fileName, "acc-a.json", "文件名正确")
            t.equal(accounts.first?.existingProxy, nil as String?, "清除后 existingProxy=nil(未绑定)")
            let unbound = ProxyPool.unboundAccounts(authDir: "/nonexistent", types: ["xai"])
            t.equal(unbound.count, 1, "清除后视为未绑定")

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

            // 11. 真实事故(2026-09-22):UI saveCPAAPI 漏调 Prefs.save(),
            // 密钥只在内存、prefs.json 无记录,重启即丢。回归:save() 后
            // 磁盘 $KEYDROP_HOME/prefs.json 必须含 cpaManagementKey。
            do {
                Prefs.shared.cpaManagementKey = "persist-roundtrip-key"
                try Prefs.shared.save()
                defer { Prefs.shared.cpaManagementKey = origKey }
                let home = ProcessInfo.processInfo.environment["KEYDROP_HOME"]!
                let text = try String(contentsOfFile: home + "/prefs.json", encoding: .utf8)
                let obj = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
                t.equal(obj?["cpaManagementKey"] as? String, "persist-roundtrip-key",
                        "save() 后密钥已写入磁盘 prefs.json")
            } catch {
                t.expect(false, "prefs 持久化回归失败: \(error)")
            }
        }

        // MARK: - endpointInfo 零文件触碰(2026-09-25 事故:apiMode 下读路径仍 locateConfig
        // stat Documents 里的 config.yaml,更新换签名使 TCC 授权作废后启动即弹「文稿」;
        // v1.4.31 起启动对账调 endpointInfo,把偶发变成必弹)
        h.runSuite("CPAAPI.endpointInfo 零文件触碰") { t in
            let oldCfg = ProcessInfo.processInfo.environment["KEYDROP_CPA_CONFIG"]
            let oldLLMKey = ProcessInfo.processInfo.environment["KEYDROP_LLM_KEY"]
            defer {
                if let oldCfg { setenv("KEYDROP_CPA_CONFIG", oldCfg, 1) } else { unsetenv("KEYDROP_CPA_CONFIG") }
                if let oldLLMKey { setenv("KEYDROP_LLM_KEY", oldLLMKey, 1) } else { unsetenv("KEYDROP_LLM_KEY") }
            }
            guard let server = try? MockHTTPServer(mode: .cpaMgmt) else {
                t.expect(false, "mock 启动失败")
                return
            }
            let origKey = Prefs.shared.cpaManagementKey
            let origBase = Prefs.shared.cpaAPIBase
            let origProxy = Prefs.shared.proxy
            Prefs.shared.proxy = ""
            Prefs.shared.cpaManagementKey = "test-key"
            Prefs.shared.cpaAPIBase = "http://127.0.0.1:\(server.port)"
            defer {
                Prefs.shared.cpaManagementKey = origKey
                Prefs.shared.cpaAPIBase = origBase
                Prefs.shared.proxy = origProxy
            }

            // ① apiMode:KEYDROP_CPA_CONFIG 指向不存在的路径 —— 旧实现 locateConfig
            //    返回 nil → endpointInfo 整体 nil;新实现经管理 API 取文本,零文件依赖
            setenv("KEYDROP_CPA_CONFIG", "/nonexistent-keydrop-tcc/config.yaml", 1)
            setenv("KEYDROP_LLM_KEY", "", 1)
            server.mgmtLock.lock()
            server.cpaYAML = "port: 18317\napi-keys:\n  - sk-mockclientkey\n"
            server.mgmtLock.unlock()
            let ep = CPAWriter.endpointInfo()
            let e = t.notNil(ep, "[apiMode] 本地无文件也能取到 endpoint")
            t.equal(e?.baseURL, "http://127.0.0.1:18317", "[apiMode] port 取自管理 API 文本")
            t.equal(e?.clientKey, "sk-mockclientkey", "[apiMode] clientKey 取自管理 API 文本")

            // ② 文件模式(无管理密钥):行为不变,locateConfig+读文件
            Prefs.shared.cpaManagementKey = nil
            let tmpCfg = NSTemporaryDirectory() + "kd-tcc-filemode-\(UUID().uuidString.prefix(6)).yaml"
            try? "port: 18432\napi-keys:\n  - sk-filemode\n".write(toFile: tmpCfg, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(atPath: tmpCfg) }
            setenv("KEYDROP_CPA_CONFIG", tmpCfg, 1)
            let ep2 = CPAWriter.endpointInfo()
            t.equal(ep2?.baseURL, "http://127.0.0.1:18432", "[文件模式] 行为不变")
            t.equal(ep2?.clientKey, "sk-filemode", "[文件模式] clientKey 仍读文件")
        }

        // MARK: - ProxyPool apiMode 扫描零文件触碰(2026-09-25:scanHealth 巡检经
        // defaultAuthDir stat Documents 下的 auth-dir,更新换签名使 TCC 授权作废后
        // 每次巡检即弹「文稿」;apiMode 应走 /auth-files 管理端点,本地目录无关)
        h.runSuite("ProxyPool.apiMode 扫描零文件触碰") { t in
            guard let server = try? MockHTTPServer(mode: .cpaMgmt) else {
                t.expect(false, "mock 启动失败")
                return
            }
            let origKey = Prefs.shared.cpaManagementKey
            let origBase = Prefs.shared.cpaAPIBase
            let origProxy = Prefs.shared.proxy
            Prefs.shared.proxy = ""
            Prefs.shared.cpaManagementKey = "test-key"
            Prefs.shared.cpaAPIBase = "http://127.0.0.1:\(server.port)"
            defer {
                Prefs.shared.cpaManagementKey = origKey
                Prefs.shared.cpaAPIBase = origBase
                Prefs.shared.proxy = origProxy
            }
            server.mgmtLock.lock()
            server.cpaYAML = "port: 8317\n"
            server.cpaAuthFiles = ["acc-a.json": "{\"type\":\"xai\",\"email\":\"a@x.com\",\"proxy_url\":\"\"}"]
            server.mgmtLock.unlock()

            // authDir 传 nil:apiMode 走 /auth-files,本地目录完全无关
            // (有本地 auth-dir 可 stat 的场景反而会弹 TCC,这正是要防的)
            let unbound = ProxyPool.unboundAccounts(authDir: nil)
            t.equal(unbound.count, 1, "[apiMode] 经管理 API 扫到未绑定账号")
            t.equal(unbound.first?.fileName, "acc-a.json", "[apiMode] 账号来自 /auth-files")

            // 文件模式:authDir nil → 无从扫描,返回空(不崩)
            Prefs.shared.cpaManagementKey = nil
            t.equal(ProxyPool.unboundAccounts(authDir: nil).count, 0, "[文件模式] 无 authDir 返回空")
        }
    }
}
