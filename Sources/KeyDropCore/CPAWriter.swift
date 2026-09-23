import Foundation

public enum CPAWriteError: Error, LocalizedError {
    case notFound(String)
    public var errorDescription: String? {
        switch self {
        case .notFound(let p): return "CPA config 不存在: \(p)"
        }
    }
}

public final class CPAWriter {

    let configPath: String

    public init(configPath: String) {
        self.configPath = configPath
    }

    /// CPA 跑在 Docker 时,宿主机 loopback 代理(127.0.0.1/localhost/0.0.0.0)在容器内
    /// 指向容器自身,直连测试能过(宿主机视角)但写进 config 后 CPA 取不到代理,导入的 key
    /// 全废。此处按部署形态改写 host 为 host.docker.internal(保留 scheme/port/path)。
    /// 判定 docker:显式 KEYDROP_CPA_DOCKER=1,或现有 config 里已有 proxy-url 含
    /// host.docker.internal(用户已在用 docker 代理)。KEYDROP_CPA_DOCKER=0 强制非 docker。
    /// 纯函数(不碰文件),供单测直接断言
    public static func rewriteProxyForDocker(_ proxy: String?, configContent: String) -> String? {
        guard let proxy = proxy, !proxy.isEmpty else { return proxy }
        let env = ProcessInfo.processInfo.environment["KEYDROP_CPA_DOCKER"]
        if env == "0" { return proxy }
        let isDocker = env == "1" || configContent.contains("host.docker.internal")
        guard isDocker else { return proxy }
        guard var comps = URLComponents(string: proxy), let host = comps.host else { return proxy }
        let loopback = host == "127.0.0.1" || host == "localhost" || host == "0.0.0.0"
                      || host.hasPrefix("127.")
        guard loopback else { return proxy }
        comps.host = "host.docker.internal"
        return comps.string ?? proxy
    }

    public static func locateConfig() -> String? {
        if let override = ProcessInfo.processInfo.environment["KEYDROP_CPA_CONFIG"] {
            return FileManager.default.fileExists(atPath: override) ? override : nil
        }
        if let fromPrefs = Prefs.shared.cpaConfigPath,
           FileManager.default.fileExists(atPath: fromPrefs) {
            return fromPrefs
        }
        if let fromProc = runningProcessConfig() { return fromProc }
        // Docker 部署:容器进程宿主机 ps 不可见,prefs 路径易失效。
        // 用 docker inspect 找挂载了 CLIProxyAPI config.yaml 的容器,返回其宿主机源路径。
        if let fromDocker = dockerMountedConfig() { return fromDocker }
        let candidates = [
            NSHomeDirectory() + "/cliproxyapi/config.yaml",
            NSHomeDirectory() + "/.cli-proxy-api/config.yaml",
            NSHomeDirectory() + "/.config/cli-proxy-api/config.yaml"
        ]
        for c in candidates {
            if FileManager.default.fileExists(atPath: c) { return c }
        }
        return nil
    }

    /// 扫描 docker 容器,找挂载了 CLIProxyAPI config.yaml 的那个,返回宿主机路径。
    /// 容器镜像名含 cli-proxy / cliproxy 且挂载 destination 或 source basename 命中
    /// config.yaml 才算。docker 不可用/无匹配返回 nil,不打扰主流程
    private static func dockerMountedConfig() -> String? {
        // GUI app 经 open 启动时 PATH 不含 /usr/local/bin,不能依赖 `env docker`;
        // KEYDROP_DOCKER_BIN 显式指定优先,否则逐个候选绝对路径找可执行的 docker
        let candidates: [String]
        if let env = ProcessInfo.processInfo.environment["KEYDROP_DOCKER_BIN"], !env.isEmpty {
            candidates = [env]
        } else {
            candidates = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "/usr/bin/docker"]
        }
        guard let docker = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { return nil }
        guard let ids = runCapture(docker, ["ps", "--format", "{{.ID}} {{.Image}}"]) else { return nil }
        var best: String? = nil
        for line in ids.split(whereSeparator: \.isNewline) {
            let cols = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard cols.count == 2 else { continue }
            let (cid, image) = (cols[0], cols[1])
            let img = image.lowercased()
            guard img.contains("cli-proxy") || img.contains("cliproxy") || img.contains("cliproxyapi") else { continue }
            guard let mounts = runCapture(docker, ["inspect", cid, "--format",
                "{{range .Mounts}}{{.Source}}|{{.Destination}}\n{{end}}"]) else { continue }
            for m in mounts.split(whereSeparator: \.isNewline) {
                let parts = m.split(separator: "|", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                let (src, dst) = (parts[0], parts[1])
                // 目标或源是 config.yaml 文件(非目录),宿主机真实存在
                let dstIsConfig = (dst as NSString).lastPathComponent == "config.yaml"
                let srcIsConfig = (src as NSString).lastPathComponent == "config.yaml"
                guard dstIsConfig || srcIsConfig else { continue }
                guard FileManager.default.fileExists(atPath: src) else { continue }
                if best == nil { best = src }
            }
        }
        return best
    }

    /// 运行命令捕获 stdout;命令不存在/失败返回 nil。绝不抛错:探测性质
    private static func runCapture(_ exe: String, _ args: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: exe) else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = args
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func runningProcessConfig() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-eo", "args="]
        let pipe = Pipe()
        proc.standardOutput = pipe
        do {
            try proc.run()
        } catch { return nil }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        proc.waitUntilExit()
        for line in out.split(whereSeparator: \.isNewline) {
            if line.contains("cli-proxy-api") || line.contains("CLIProxyAPI") {
                let parts = line.split(separator: " ").map(String.init)
                for (i, t) in parts.enumerated() {
                    if (t == "-config" || t == "--config" || t == "-c") && i + 1 < parts.count {
                        let p = NSString(string: parts[i + 1]).expandingTildeInPath
                        if FileManager.default.fileExists(atPath: p) { return p }
                    }
                    if t.hasPrefix("--config=") {
                        let p = NSString(string: String(t.dropFirst(9))).expandingTildeInPath
                        if FileManager.default.fileExists(atPath: p) { return p }
                    }
                }
            }
        }
        return nil
    }

    // MARK: - CPA endpoint info

    public struct CPAEndpoint {
        public let baseURL: String
        public let clientKey: String
    }

    public static func endpointInfo() -> CPAEndpoint? {
        let port = ProcessInfo.processInfo.environment["KEYDROP_CPA_PORT"]
            ?? readPortFromConfig() ?? "8317"
        let host = ProcessInfo.processInfo.environment["KEYDROP_CPA_HOST"] ?? "127.0.0.1"
        let baseURL: String
        if let envURL = ProcessInfo.processInfo.environment["KEYDROP_LLM_ENDPOINT"], !envURL.isEmpty {
            baseURL = envURL.hasSuffix("/v1") ? String(envURL.dropLast(3)) : envURL
        } else {
            baseURL = "http://\(host):\(port)"
        }
        let clientKey = LLMParser.apiKey
        guard !clientKey.isEmpty else { return nil }
        return CPAEndpoint(baseURL: baseURL, clientKey: clientKey)
    }

    private static func readPortFromConfig() -> String? {
        guard let cfg = locateConfig(),
              let content = try? CPAAPI.readConfigText(path: cfg)
        else { return nil }
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = String(line)
            let trimmed = l.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("port:"), !l.hasPrefix(" ") {
                let v = trimmed.dropFirst("port:".count).trimmingCharacters(in: .whitespaces)
                if !v.isEmpty { return v }
            }
        }
        return nil
    }

    // MARK: - image channel

    /// 生图 key 写入 CPA:落到独立的 openai-compatibility 聚合条目
    /// (`name = host:port-image`,base-url 与文本条目相同)。必须分条目:
    /// - 同条目会让文本 `--add` 的「精选保护」逻辑把生图模型灌进 CPA 常驻
    ///   入口(文本工具看到 image 模型),反向导入时又会因 models 非空而
    ///   跳过探测模型 → 文本 provider 一个模型都没有
    /// - 分条目后两条链路互不干扰,CPA 按模型名把 /v1/images/generations
    ///   路由到打了 `image: true` 的这条
    /// 幂等:重复 image-add 同上游只合 key(去重)、重写模型标记,不产生重复项
    public func addImageChannel(baseURL: String, key: String, models: [String], proxy: String? = nil) throws -> String {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelList = models.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !k.isEmpty, !url.isEmpty else { throw WriterError.missingKey }
        guard !modelList.isEmpty else { throw WriterError.file("生图模型列表为空") }
        guard configAvailable() else {
            throw CPAWriteError.notFound(configPath)
        }
        return try withCPASync {
            let content = try readConfigText()
            let proxy = Self.rewriteProxyForDocker(proxy, configContent: content)
            var lines = content.components(separatedBy: "\n")
            let providerName = aggregatedName(for: url) + "-image"
            if let entryRange = findAggregatedEntry(in: lines, providerName: providerName) {
                // keys 合并(去重);models 交给 markImageModel 逐项处理
                try mergeIntoAggregatedEntry(&lines, range: entryRange, providerName: providerName, keys: [k], models: [])
                for m in modelList {
                    // 每次插入都可能位移行号,逐项重新定位条目范围
                    let fresh = findAggregatedEntry(in: lines, providerName: providerName) ?? entryRange
                    markImageModel(&lines, entryRange: fresh, model: m)
                }
            } else {
                try appendAggregatedEntry(&lines, providerName: providerName, baseURL: url,
                                          keys: [k], models: modelList, proxy: proxy)
                for m in modelList {
                    guard let fresh = findAggregatedEntry(in: lines, providerName: providerName) else { break }
                    markImageModel(&lines, entryRange: fresh, model: m)
                }
            }
            try atomicWrite(lines.joined(separator: "\n"))
            return "已写入 CPA 生图条目「\(providerName)」模型 \(modelList.joined(separator: ", "))(image: true);CPA 自动热重载"
        }
    }

    /// 在聚合条目内确保 `model` 这个 models 子项带 `image: true`:
    /// - 子项存在且已有 image: → 值改成 true(保留其它字段)
    /// - 子项存在无 image: → 在子项末尾插 image: true
    /// - models 段存在但无此子项 → 段尾追加 name+alias+image: true
    /// - 条目无 models 段 → 条目末尾新建 models: 段带标记项
    /// 幂等:同 key 重复 image-add 只会重写 image: true 行,不产生重复项
    /// (子项判重按 `- name:` 行精确匹配,`entryModels` 同源读 name)
    private func markImageModel(_ lines: inout [String], entryRange: Range<Int>, model: String) {
        guard let header = entryRange.first(where: { lines[$0].trimmingCharacters(in: .whitespaces) == "models:" }) else {
            // 条目无 models 段:在条目末尾(去尾随空行)追加 models: 头 + 带标记的模型项。
            // 不能走 mergeAggregatedModels —— 它只写 name+alias,会漏掉 image: true
            let entryIndent = String(lines[entryRange.lowerBound].prefix(while: { $0 == " " || $0 == "\t" }))
            let propIndent = entryIndent + "  "
            var insertAt = entryRange.upperBound
            while insertAt > entryRange.lowerBound + 1, lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty { insertAt -= 1 }
            let block = [
                "\(propIndent)models:",
                "\(propIndent)  - name: \(yamlScalar(model))",
                "\(propIndent)    alias: \(yamlScalar(model))",
                "\(propIndent)    image: true",
            ]
            lines.insert(contentsOf: block, at: insertAt)
            return
        }
        let headerIndent = lines[header].prefix(while: { $0 == " " || $0 == "\t" }).count
        // 遍历 models 子项找 name == model
        var i = header + 1
        while i < entryRange.upperBound {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { i += 1; continue }
            let curIndent = line.prefix(while: { $0 == " " || $0 == "\t" }).count
            if curIndent <= headerIndent { break } // 出了 models 段
            if trimmed.hasPrefix("- name:") {
                let nm = stripYAMLValue(String(trimmed.dropFirst("- name:".count))).trimmingCharacters(in: .whitespaces)
                if nm == model {
                    // 找到子项:确定其行范围(到下一条同级或更浅缩进的非空行为止)
                    var end = entryRange.upperBound
                    var j = i + 1
                    while j < entryRange.upperBound {
                        let lj = lines[j]
                        let tj = lj.trimmingCharacters(in: .whitespacesAndNewlines)
                        if tj.isEmpty { j += 1; continue }
                        let ij = lj.prefix(while: { $0 == " " || $0 == "\t" }).count
                        if ij <= curIndent { end = j; break }
                        j += 1
                    }
                    let imgIndent = String(repeating: " ", count: curIndent + 2)
                    if let imgLine = (i+1..<end).first(where: {
                        lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("image:")
                    }) {
                        lines[imgLine] = "\(imgIndent)image: true"
                    } else {
                        // 插到子项末尾(end 前进至最后一条非空子项行之后)
                        var ins = end
                        while ins > i + 1, lines[ins - 1].trimmingCharacters(in: .whitespaces).isEmpty { ins -= 1 }
                        lines.insert("\(imgIndent)image: true", at: ins)
                    }
                    return
                }
            }
            i += 1
        }
        // models 段存在但无此子项:段尾追加带标记的完整项
        let itemIndent = String(repeating: " ", count: headerIndent + 2)
        var insertAt = header + 1
        var j2 = header + 1
        while j2 < entryRange.upperBound {
            let lj = lines[j2]
            let tj = lj.trimmingCharacters(in: .whitespacesAndNewlines)
            if tj.isEmpty { j2 += 1; continue }
            let ij = lj.prefix(while: { $0 == " " || $0 == "\t" }).count
            if ij <= headerIndent { break }
            j2 += 1
            insertAt = j2
        }
        while insertAt > header + 1, lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty { insertAt -= 1 }
        let block = [
            "\(itemIndent)- name: \(yamlScalar(model))",
            "\(itemIndent)  alias: \(yamlScalar(model))",
            "\(itemIndent)  image: true",
        ]
        lines.insert(contentsOf: block, at: insertAt)
    }

    // MARK: - add

    /// 单 key 写入 openai-compatibility 聚合条目(与多 key addMulti 同一条路)。
    /// 不再走 claude-api-key 平铺段的原因:
    /// - collectCuratedModels(cpa-sync 常驻入口的模型来源)只读聚合段,平铺段
    ///   条目对 cpa-sync 隐形 → 下次同步会丢掉这些模型
    /// - 聚合段才有轮询/weight/精选保护这套成体系的行为
    /// 复用 addMultiLocked 的写入逻辑(合并/新建/精选保护/原子写),但不做 key 探测:
    /// 调用方(Core.add)已对 key 做过认证测试,models 传本次 selectedModels(用户已选)。
    func addAggregated(baseURL: String, key: String, models: [String], proxy: String? = nil) throws -> String {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { throw WriterError.missingKey }
        guard FileManager.default.fileExists(atPath: configPath) else {
            throw WriterError.file("CPA config 不存在: \(configPath)")
        }
        let writeMsg = try withWriteLock {
            try addMultiLocked(baseURL: baseURL, keys: [k], models: models, proxy: proxy)
        }
        return writeMsg.0
    }

    /// 刷新时按用户重新勾选的列表「整体替换」聚合条目 models 段。
    /// 与 addMultiLocked 的「只合 key 不动精选列表」不同:refresh 的语义是用户对
    /// 模型列表的重新确认,被取消勾选的模型必须同步移除,否则 CPA 条目永远停在
    /// 首次导入的列表(真实场景:cc 系已更新 4 模型,CPA 仍停在误杀后剩下的 1 个)。
    /// 条目不存在时抛错(由调用方提示),绝不重建已删除的条目
    public func updateAggregatedModels(baseURL: String, models: [String]) throws -> String {
        var uniq: [String] = []
        var seen = Set<String>()
        for m in models {
            let t = m.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty, seen.insert(t).inserted { uniq.append(t) }
        }
        guard !uniq.isEmpty else { throw WriterError.file("更新 CPA 模型列表收到空列表") }
        guard configAvailable() else {
            throw WriterError.file("CPA config 不存在: \(configPath)")
        }
        return try withCPASync {
            let content = try readConfigText()
            var lines = content.components(separatedBy: "\n")
            let providerName = aggregatedName(for: baseURL)
            guard let entryRange = findAggregatedEntry(in: lines, providerName: providerName) else {
                throw WriterError.file("CPA 聚合条目不存在: \(providerName)")
            }
            guard let header = entryRange.first(where: { lines[$0].trimmingCharacters(in: .whitespaces) == "models:" }) else {
                // 条目无 models 段(上次探测失败):补写本次列表,复用 merge 的插入逻辑
                try mergeIntoAggregatedEntry(&lines, range: entryRange, providerName: providerName, keys: [], models: uniq)
                try atomicWrite(lines.joined(separator: "\n"))
                return "已补写 CPA 聚合条目「\(providerName)」模型 \(uniq.count) 个"
            }
            let headerIndent = lines[header].prefix(while: { $0 == " " || $0 == "\t" }).count
            // models 段范围:header+1 起直到缩进 ≤ header 的非空行(段内其它子键更深缩进,一并替换)
            var end = header + 1
            var itemIndent = String(repeating: " ", count: headerIndent + 4)
            while end < entryRange.upperBound {
                let line = lines[end]
                if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { end += 1; continue }
                let ind = line.prefix(while: { $0 == " " || $0 == "\t" }).count
                if ind <= headerIndent { break }
                if lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("- name:") {
                    itemIndent = String(repeating: " ", count: ind)
                }
                end += 1
            }
            var block: [String] = []
            for m in uniq {
                block.append("\(itemIndent)- name: \(yamlScalar(m))")
                block.append("\(itemIndent)  alias: \(yamlScalar(m))")
            }
            lines.replaceSubrange((header + 1)..<end, with: block)
            try atomicWrite(lines.joined(separator: "\n"))
            return "已更新 CPA 聚合条目「\(providerName)」模型 \(uniq.count) 个"
        }
    }

    /// 多 key 写聚合条目到 `openai-compatibility:` 段下,同 baseURL 的 key 归一组,
    /// 共享一组 models 列表。CPA 加载后会在此组内轮询所有 api-key。
    /// 模型列表自动探测:探测失败返回空 models,条目可后续刷新。
    /// 返回 (提示消息, 探测到的模型) —— 模型回传给历史条目,
    /// UI 才能按真实家族路由「打开应用」(曾因 models 空被误标 claude)
    func addMulti(baseURL: String, keys: [String], proxy: String? = nil) throws -> (String, [String]) {
        var seen = Set<String>()
        let uniqueKeys = keys.compactMap { raw -> String? in
            let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, seen.insert(key).inserted else { return nil }
            return key
        }
        guard !uniqueKeys.isEmpty else {
            throw WriterError.file("addMulti 收到空 keys 列表")
        }
        // 每把 key 都做一次认证探测。只有明确 401/403 的失效 key 自动剔除；
        // 超时、429、5xx 等非认证错误保留，避免暂时性网关故障导致凭据丢失。
        // 并发上限 4(与 scanHealth 同口径):串行时网关抽风每 key 最坏 24s,
        // 批量上百把 key 会卡死整个导入;按原顺序合并结果保证确定性
        var results = [APITestResult?](repeating: nil, count: uniqueKeys.count)
        let resultLock = NSLock()
        let sem = DispatchSemaphore(value: 4)
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)
        for (i, key) in uniqueKeys.enumerated() {
            sem.wait()
            group.enter()
            queue.async {
                defer { sem.signal(); group.leave() }
                let test = APITester.test(url: baseURL, key: key, proxy: proxy)
                resultLock.lock()
                results[i] = test
                resultLock.unlock()
            }
        }
        group.wait()
        var rejected = 0
        var accepted: [String] = []
        var probedModels: [String] = []
        // 必须按索引对齐收集:compactMap+zip 会在任一结果缺失时让后续 key 整体错位,
        // 把好 key 对到别处的探测结果上误剔除。结果缺失(理论不可达)按非认证错误保留
        for (i, key) in uniqueKeys.enumerated() {
            guard let test = results[i] else {
                accepted.append(key)
                continue
            }
            if test.authFailed {
                rejected += 1
                continue
            }
            accepted.append(key)
            if probedModels.isEmpty, test.ok {
                probedModels = test.models.filter { Parser.looksLikeModel($0) }
            }
        }
        guard !accepted.isEmpty else {
            throw WriterError.file("多 key 中没有可用 key,已剔除 \(rejected) 个失效 key")
        }
        let writeMsg = try withCPASync {
            try addMultiLocked(baseURL: baseURL, keys: accepted, models: probedModels, proxy: proxy)
        }
        // 回传条目最终 models(已有精选时=精选原列表,新建/补写时=探测结果):
        // 历史/UI/常驻入口与配置文件同源,绝不把探测全量当精选
        let suffix = rejected > 0 ? ",自动剔除 \(rejected) 个失效 key" : ""
        return ("已写入 CPA 配置(\(configPath))\(suffix);\(writeMsg.0);CPA 运行时会自动热重载", writeMsg.1)
    }

    /// 模型探测在锁外完成:探测是网络请求,离线时要等超时,
    /// 不能在 flock 临界区内做 —— 否则 CLI 与菜单栏并发写时互相串行排队到对方超时
    /// 返回 (消息, 条目最终模型列表)。已有非空 models 的条目视为用户精选:
    /// 再导入只合并 key,绝不追加探测模型(真实反馈:CPA 聚合 /models 混入 22 家
    /// 上游共 100+ 模型,用户只要 SOTA 四件套,KeyDrop 不得把一大堆回填)
    private func addMultiLocked(baseURL: String, keys: [String], models probedModels: [String], proxy rawProxy: String? = nil) throws -> (String, [String]) {
        let content = try readConfigText()
        let proxy = Self.rewriteProxyForDocker(rawProxy, configContent: content)
        var lines = content.components(separatedBy: "\n")
        let providerName = aggregatedName(for: baseURL)
        var finalModels = probedModels
        var preservedNote = ""

        // 定位 openai-compatibility 段下同 name 的现有条目
        if let entryRange = findAggregatedEntry(in: lines, providerName: providerName) {
            let existingModels = Self.entryModels(in: lines, entryRange: entryRange)
            if existingModels.isEmpty {
                // 条目无模型列表(上次探测失败):补写本次探测结果
                try mergeIntoAggregatedEntry(&lines, range: entryRange, providerName: providerName, keys: keys, models: probedModels)
            } else {
                // 已有精选列表:只合 key,保留 models 原样
                try mergeIntoAggregatedEntry(&lines, range: entryRange, providerName: providerName, keys: keys, models: [])
                finalModels = existingModels
                preservedNote = ",保留条目现有 \(existingModels.count) 个模型"
            }
        } else {
            // 新建条目
            try appendAggregatedEntry(&lines, providerName: providerName, baseURL: baseURL,
                                      keys: keys, models: probedModels, proxy: proxy)
        }
        try atomicWrite(lines.joined(separator: "\n"))
        let modelPart = finalModels.isEmpty ? "" : ", 模型 \(finalModels.count) 个"
        return ("已写入 \(keys.count) 个 key 到 CPA 聚合条目「\(providerName)」\(modelPart)\(preservedNote)", finalModels)
    }

    /// 从给定条目范围解析 models: 段的模型名(按条目内容缩进判定,与 merge 同一口径)
    static func entryModels(in lines: [String], entryRange: Range<Int>) -> [String] {
        guard let header = entryRange.first(where: { lines[$0].trimmingCharacters(in: .whitespaces) == "models:" })
        else { return [] }
        let headerIndent = lines[header].prefix(while: { $0 == " " || $0 == "\t" }).count
        var out: [String] = []
        for j in (header + 1)..<entryRange.upperBound {
            let line = lines[j]
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if line.prefix(while: { $0 == " " || $0 == "\t" }).count <= headerIndent { break }
            if trimmed.hasPrefix("- name:") {
                let nm = trimmed.dropFirst("- name:".count).trimmingCharacters(in: .whitespaces)
                if !nm.isEmpty { out.append(nm) }
            }
        }
        return out
    }

    /// 读取指定 baseURL 聚合条目当前精选的模型列表(锁内读,与写者互斥)。
    /// 条目/段不存在返回 []
    public func entryModels(baseURL: String) -> [String] {
        guard configAvailable() else { return [] }
        return (try? withCPASync { () -> [String] in
            guard let content = try? readConfigText() else { return [] }
            let lines = content.components(separatedBy: "\n")
            guard let range = findAggregatedEntry(in: lines, providerName: aggregatedName(for: baseURL)) else { return [] }
            return Self.entryModels(in: lines, entryRange: range)
        }) ?? []
    }

    /// 聚合条目 name 取 baseURL 的 host[:port]。端口必须计入:同一 host 的不同端口
    /// 是不同上游端点,只取 host 会把 8317 和 9090 两批 key 并进同一条目,
    /// 后一批 key 被挂到先一批的 base-url 上轮询(静默路由错端点)。
    /// 无端口 URL 的 name 与历史一致(host),存量条目不受影响
    private func aggregatedName(for baseURL: String) -> String {
        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let u = URL(string: trimmed) ?? URL(string: "https://\(trimmed)"), let host = u.host, !host.isEmpty {
            if let port = u.port { return "\(host):\(port)" }
            return host
        }
        return trimmed
    }

    /// 找 `openai-compatibility:` 段下指定 name 的条目范围(从 `- name: X` 行到下一个同级 `- ` 行或段尾)。
    /// 条目边界必须按缩进判定:条目内 models 子序列的 `- name:` 项缩进更深,
    /// 按 trimmed 前缀一刀切会把条目截断在 models 首项,合并时误判「无已有 models」重复写入
    private func findAggregatedEntry(in lines: [String], providerName: String) -> Range<Int>? {
        guard let section = findNamedSection(in: lines, key: "openai-compatibility:") else { return nil }
        var idx = section.start
        while idx < section.end {
            let l = lines[idx]
            let t = l.drop(while: { $0 == " " || $0 == "\t" })
            if t.hasPrefix("- name:") || t == "-" || t.hasPrefix("- ") {
                let entryStart = idx
                let indent = String(l.prefix(l.count - t.count))
                let nameOnLine = t.hasPrefix("- name:")
                    ? stripYAMLValue(String(t.dropFirst("- name:".count))).trimmingCharacters(in: .whitespaces)
                    : nil
                // 条目结束 = 下一个同缩进(或更浅)的 `- ` 行 / 反缩进到父级键;子序列深层项不算
                var j = idx + 1
                while j < section.end {
                    let lj = lines[j]
                    let tj = lj.drop(while: { $0 == " " || $0 == "\t" })
                    if tj.isEmpty { j += 1; continue }
                    let indj = String(lj.prefix(lj.count - tj.count))
                    if tj.hasPrefix("- ") || tj == "-" {
                        if indj.count <= indent.count { break }
                    } else if indj.count < indent.count {
                        break
                    }
                    j += 1
                }
                if nameOnLine == providerName {
                    return entryStart..<j
                }
                idx = j
            } else {
                idx += 1
            }
        }
        return nil
    }

    private func stripYAMLValue(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.count >= 2 {
            if t.hasPrefix("\"") && t.hasSuffix("\"") {
                return String(t.dropFirst().dropLast())
            }
            if t.hasPrefix("'") && t.hasSuffix("'") {
                return String(t.dropFirst().dropLast())
            }
        }
        return t
    }

    // MARK: - aggregated write helpers

    /// 合并 keys 和 models 进现有聚合条目;keys 去重(已有的跳过),models 同样。
    /// models 与 keys 的插入都会使后续行号整体位移,所以每次插入后必须重新定位条目范围
    /// 再扫描/插入下一项。曾两次踩这个坑:先用失效 range 合并 models(重复 `models:` 键、
    /// 第二批整体回滚),后又用「models 插入后失效的 range」扫描 api-key-entries ——
    /// 当配置里 models: 排在 api-key-entries: 之前(手写或 CPA 工具回写的合法字段序),
    /// 新 key 会被静默丢弃却报告成功。现在 models 合并完重新 findAggregatedEntry 取新 range。
    private func mergeIntoAggregatedEntry(_ lines: inout [String], range: Range<Int>, providerName: String, keys: [String], models: [String]) throws {
        // models 合并(去重)
        if !models.isEmpty {
            try mergeAggregatedModels(&lines, entryRange: range, newModels: models)
        }

        // models 插入可能已使原 range 失效:重新定位条目范围再处理 keys
        let keyRange = models.isEmpty ? range : (findAggregatedEntry(in: lines, providerName: providerName) ?? range)

        // 提取已有 keys
        var existingKeys = Set<String>()
        if let entriesRange = findAPIKeyEntriesSubrange(in: lines, entryRange: keyRange) {
            for i in entriesRange {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("- api-key:") {
                    let scalar = String(t.dropFirst("- api-key:".count)).trimmingCharacters(in: .whitespaces)
                    existingKeys.insert(decodeYAMLScalar(scalar))
                }
            }
        }
        let newKeys = keys.filter { !existingKeys.contains($0) }
        guard !newKeys.isEmpty else { return }

        // 在 api-key-entries 末尾追加新 key
        if let entriesRange = findAPIKeyEntriesSubrange(in: lines, entryRange: keyRange) {
            // 计算 entries 缩进:从第一条非空行推断(api-key-entries: 后紧跟空行时,
            // 首行 lowerBound 是空行,若据其取缩进会得到 "" → key 插到顶格损坏 YAML)
            let indent: String = {
                for i in entriesRange {
                    let l = lines[i]
                    if l.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                    return String(l.prefix(while: { $0 == " " || $0 == "\t" }))
                }
                return "      "
            }()
            // 插入位置:最后一条非空 entry 之后(跳过尾随空行)
            var insertAt = entriesRange.upperBound
            while insertAt > entriesRange.lowerBound, lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                insertAt -= 1
            }
            let block = newKeys.map { "\(indent)- api-key: \(yamlScalar($0))" }
            lines.insert(contentsOf: block, at: insertAt)
        }
    }

    /// 在聚合条目范围内合并 models(去重)
    private func mergeAggregatedModels(_ lines: inout [String], entryRange: Range<Int>, newModels: [String]) throws {
        // 找现有 `models:` 段位置
        var modelsHeader: Int? = nil
        for i in entryRange {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("models:") { modelsHeader = i; break }
        }
        var existing = Set<String>()
        if let header = modelsHeader {
            let headerIndent = lines[header].prefix(while: { $0 == " " || $0 == "\t" }).count
            var modelItemIndent = ""
            var endModels = entryRange.upperBound
            for j in (header + 1)..<entryRange.upperBound {
                let line = lines[j]
                let curIndent = line.prefix(while: { $0 == " " || $0 == "\t" }).count
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && curIndent <= headerIndent { endModels = j; break }
                if trimmed.hasPrefix("- name:") {
                    if modelItemIndent.isEmpty { modelItemIndent = String(line.prefix(curIndent)) }
                    let nm = stripYAMLValue(String(trimmed.dropFirst("- name:".count)))
                    existing.insert(nm.trimmingCharacters(in: .whitespaces))
                }
            }
            let toAdd = newModels.filter { !existing.contains($0) }
            if toAdd.isEmpty { return }
            let indent = modelItemIndent.isEmpty ? String(repeating: " ", count: headerIndent + 2) : modelItemIndent
            var insertAt = endModels
            while insertAt > header + 1, lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty { insertAt -= 1 }
            let block = toAdd.flatMap { ["\(indent)- name: \(yamlScalar($0))", "\(indent)  alias: \(yamlScalar($0))"] }
            lines.insert(contentsOf: block, at: insertAt)
        } else {
            // 条目无 models 段:在条目末尾(去空行后)追加
            let headerIndent: Int = {
                let firstLine = lines[entryRange.lowerBound]
                return firstLine.prefix(while: { $0 == " " || $0 == "\t" }).count
            }()
            let propIndent = String(repeating: " ", count: headerIndent + 2)
            var insertAt = entryRange.upperBound
            while insertAt > entryRange.lowerBound + 1, lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty { insertAt -= 1 }
            var block: [String] = ["\(propIndent)models:"]
            for m in newModels {
                block.append("\(propIndent)  - name: \(yamlScalar(m))")
                block.append("\(propIndent)    alias: \(yamlScalar(m))")
            }
            lines.insert(contentsOf: block, at: insertAt)
        }
    }

    /// 追加全新聚合条目到 `openai-compatibility:` 段末尾;段不存在则创建
    private func appendAggregatedEntry(_ lines: inout [String], providerName: String, baseURL: String,
                                       keys: [String], models: [String], proxy: String?) throws {
        // 段不存在时新建
        guard let section = findNamedSection(in: lines, key: "openai-compatibility:") else {
            if let last = lines.last, !last.isEmpty { lines.append("") }
            lines.append("openai-compatibility:")
            let entryIndent = "  "
            lines.append(contentsOf: aggregatedEntryLines(indent: entryIndent, name: providerName, baseURL: baseURL,
                                                          keys: keys, models: models, proxy: proxy))
            return
        }
        // 段末尾追加(跳过末尾空行)
        var insertAt = section.end
        while insertAt > section.start + 1, lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty { insertAt -= 1 }
        // 缩进从现有条目推断
        let existingIndent: String = {
            for i in (section.start + 1)..<section.end {
                let l = lines[i]
                let t = l.drop(while: { $0 == " " || $0 == "\t" })
                if t.hasPrefix("- name:") || t == "-" {
                    return String(l.prefix(l.count - t.count))
                }
            }
            return "  "
        }()
        lines.insert(contentsOf: aggregatedEntryLines(indent: existingIndent, name: providerName, baseURL: baseURL,
                                                      keys: keys, models: models, proxy: proxy), at: insertAt)
    }

    /// 生成一个聚合条目所有行
    private func aggregatedEntryLines(indent: String, name: String, baseURL: String,
                                       keys: [String], models: [String], proxy: String?) -> [String] {
        var out: [String] = []
        out.append("\(indent)- name: \(yamlScalar(name))")
        out.append("\(indent)  base-url: \(yamlScalar(baseURL))")
        if let proxy, !proxy.isEmpty {
            out.append("\(indent)  proxy-url: \(yamlScalar(proxy))")
        }
        out.append("\(indent)  api-key-entries:")
        for k in keys { out.append("\(indent)    - api-key: \(yamlScalar(k))") }
        if !models.isEmpty {
            out.append("\(indent)  models:")
            for m in models {
                out.append("\(indent)    - name: \(yamlScalar(m))")
                out.append("\(indent)      alias: \(yamlScalar(m))")
            }
        }
        return out
    }

    // MARK: - remove

    /// 删除 keys:同时清理 `claude-api-key:` 平铺段和 `openai-compatibility:` 聚合段。
    /// 平铺段命中 → 删整条目;聚合段命中 → 删单个 api-key 子项,删空则整条目移除。
    func remove(apiKeys: [String]) throws -> String {
        guard FileManager.default.fileExists(atPath: configPath) else {
            return "CPA config 不存在,跳过"
        }
        return try withCPASync {
            return try removeLocked(apiKeys: apiKeys)
        }
    }

    /// 文件模式下调用方必须已持有 configPath 的 flock;API 模式无需 flock
    private func removeLocked(apiKeys: [String]) throws -> String {
        let content = try readConfigText()
        var lines = content.components(separatedBy: "\n")
        let targets = Set(apiKeys)
        var removed = Set<String>()   // 至少删掉一处 occurrence 的目标 key

        // 每轮删一个命中(平铺段优先),直到两个段都不再含任何目标 key。
        // 同一个 key 可能同时存在于 claude-api-key 与 openai-compatibility 两处,
        // 必须两处都删净才算移除 —— 曾在删完平铺段就 pending.remove,聚合段副本存活
        // 却报告「已移除」,key 仍被 CPA 轮询(账本不一致,删不掉的僵尸凭据)。
        var did = true
        while did {
            did = false
            // 1. claude-api-key 平铺段:命中即删整条目
            if let section = findSection(in: lines) {
                let items = splitItems(lines: lines, section: section)
                for item in items {
                    guard let k = targets.first(where: { itemContainsAPIKey(item, in: lines, key: $0) }) else { continue }
                    var newSectionLines: [String] = [lines[section.start]]
                    var emitted = Set<Int>()
                    for it in items where it.range.lowerBound != item.range.lowerBound {
                        for i in it.range { newSectionLines.append(lines[i]); emitted.insert(i) }
                    }
                    for i in (section.start + 1)..<section.end where !emitted.contains(i) {
                        let l = lines[i]
                        if l.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || l.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
                            newSectionLines.append(l)
                        }
                    }
                    if newSectionLines.count == 1 {
                        lines.removeSubrange(section.start..<section.end)
                    } else {
                        lines.replaceSubrange(section.start..<section.end, with: newSectionLines)
                    }
                    removed.insert(k)
                    did = true
                    break
                }
            }
            if did { continue }
            // 2. openai-compatibility 聚合段:删命中的单条 api-key,条目内真实 key 清零则删整条目
            if let section = findNamedSection(in: lines, key: "openai-compatibility:") {
                let entries = aggregatedEntries(in: lines, section: section)
                for entry in entries {
                    guard let entriesRange = findAPIKeyEntriesSubrange(in: lines, entryRange: entry.range),
                          let hitLine = findAPIKeyLine(in: lines, range: entriesRange, keys: Array(targets)) else { continue }
                    let t = lines[hitLine].trimmingCharacters(in: .whitespaces)
                    let scalar = String(t.dropFirst("- api-key:".count)).trimmingCharacters(in: .whitespaces)
                    let matchedKey = decodeYAMLScalar(scalar)
                    // 删除后统计条目内「剩余真实 api-key 行」:只数 `- api-key:` 行,
                    // 不能把空行/注释/别的字段算进来(否则删掉最后一把 key 会留下
                    // 无子项的空 `api-key-entries:`,CPA 的 Go 解析器可能判 null 序列拒启)
                    var remainingRealKeys = 0
                    for i in entriesRange where i != hitLine {
                        if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("- api-key:") { remainingRealKeys += 1 }
                    }
                    if remainingRealKeys == 0 {
                        lines.removeSubrange(entry.range)   // 整条目移除,不留空头
                    } else {
                        lines.remove(at: hitLine)
                    }
                    removed.insert(matchedKey)
                    did = true
                    break
                }
            }
        }
        if removed.isEmpty { return "未在 CPA 配置中找到 \(targets.count) 个 key" }
        try atomicWrite(lines.joined(separator: "\n"))
        let notFound = targets.count - removed.count
        return notFound > 0
            ? "已从 CPA 配置移除 \(removed.count) 个 key,余 \(notFound) 个未找到"
            : "已从 CPA 配置移除 \(removed.count) 个 key"
    }

    func remove(apiKey: String) throws -> String {
        try remove(apiKeys: [apiKey])
    }

    /// 在 openai-compatibility 段下枚举所有条目范围(每个 `- name:` 开头为一组)
    private func aggregatedEntries(in lines: [String], section: Section) -> [Item] {
        var items: [Item] = []
        var current: Range<Int>? = nil
        for i in section.start..<section.end {
            let l = lines[i]
            let t = l.drop(while: { $0 == " " || $0 == "\t" })
            let indent = String(l.prefix(l.count - t.count))
            if (t.hasPrefix("- name:") || t == "-") && !indent.hasPrefix("    ") {
                if let c = current { items.append(Item(range: c)) }
                current = i..<(i + 1)
            } else if current != nil {
                current = current!.lowerBound..<(i + 1)
            }
        }
        if let c = current { items.append(Item(range: c)) }
        return items
    }

    /// 聚合条目范围内找 `api-key-entries:` 子段下的 `- api-key:` 行范围
    private func findAPIKeyEntriesSubrange(in lines: [String], entryRange: Range<Int>) -> Range<Int>? {
        var entriesHeader: Int? = nil
        for i in entryRange {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("api-key-entries:") {
                entriesHeader = i
                break
            }
        }
        guard let header = entriesHeader else { return nil }
        let headerIndent = lines[header].prefix(while: { $0 == " " || $0 == "\t" }).count
        var end = entryRange.upperBound
        for j in (header + 1)..<entryRange.upperBound {
            let line = lines[j]
            let curIndent = line.prefix(while: { $0 == " " || $0 == "\t" }).count
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && curIndent <= headerIndent {
                end = j
                break
            }
        }
        return (header + 1)..<end
    }

    private func findAPIKeyLine(in lines: [String], range: Range<Int>, keys: [String]) -> Int? {
        for i in range {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("- api-key:") else { continue }
            let scalar = String(t.dropFirst("- api-key:".count)).trimmingCharacters(in: .whitespaces)
            let decoded = decodeYAMLScalar(scalar)
            if keys.contains(decoded) { return i }
        }
        return nil
    }

    /// 找任意顶层命名段(如 `openai-compatibility:`),返回段范围
    private func findNamedSection(in lines: [String], key: String) -> Section? {
        var start: Int? = nil
        for (i, l) in lines.enumerated() {
            if !l.hasPrefix(" ") && !l.hasPrefix("\t") && l.trimmingCharacters(in: .whitespaces) == key {
                start = i
                break
            }
        }
        guard let s = start else { return nil }
        var end = lines.count
        for i in (s + 1)..<lines.count {
            let l = lines[i]
            guard !l.isEmpty else { continue }
            let t = l.trimmingCharacters(in: .whitespaces)
            // 顶格注释行不是新段开头,跳过:否则段范围在这里被截断,
            // 后续条目找不到导致重复建段、插入位置错乱
            if t.hasPrefix("#") { continue }
            let first = l.first!
            if first != " " && first != "\t" {
                end = i
                break
            }
        }
        return Section(start: s, end: end, itemIndent: nil)
    }

    // MARK: - internals

    struct Section {
        let start: Int
        let end: Int
        let itemIndent: String?
    }

    private func findSection(in lines: [String]) -> Section? {
        var start: Int? = nil
        for (i, l) in lines.enumerated() {
            if !l.hasPrefix(" ") && !l.hasPrefix("\t") && l.trimmingCharacters(in: .whitespaces) == "claude-api-key:" {
                start = i
                break
            }
        }
        guard let s = start else { return nil }
        var end = lines.count
        for i in (s + 1)..<lines.count {
            let l = lines[i]
            guard !l.isEmpty else { continue }
            // 同 findNamedSection:顶格注释不算段边界
            if l.trimmingCharacters(in: .whitespaces).hasPrefix("#") { continue }
            let first = l.first!
            if first != " " && first != "\t" {
                end = i
                break
            }
        }
        var itemIndent: String? = nil
        for i in (s + 1)..<end {
            let l = lines[i]
            let t = l.drop(while: { $0 == " " || $0 == "\t" })
            if t.hasPrefix("- ") || t == "-" {
                itemIndent = String(l.prefix(l.count - t.count))
                break
            }
        }
        return Section(start: s, end: end, itemIndent: itemIndent)
    }

    private struct Item {
        let range: Range<Int>
    }

    private func splitItems(lines: [String], section: Section) -> [Item] {
        var items: [Item] = []
        var current: Range<Int>? = nil
        for i in (section.start + 1)..<section.end {
            let l = lines[i]
            let t = l.drop(while: { $0 == " " || $0 == "\t" })
            let indent = String(l.prefix(l.count - t.count))
            if (t.hasPrefix("- ") || t == "-"), let base = section.itemIndent, indent == base {
                if let c = current { items.append(Item(range: c)) }
                current = i..<(i + 1)
            } else if current != nil {
                current = current!.lowerBound..<(i + 1)
            }
        }
        if let c = current { items.append(Item(range: c)) }
        return items
    }

    private func itemContainsAPIKey(_ item: Item, in lines: [String], key: String) -> Bool {
        for index in item.range {
            var line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("-") {
                line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            guard line.hasPrefix("api-key:") else { continue }
            let scalar = String(line.dropFirst("api-key:".count))
                .trimmingCharacters(in: .whitespaces)
            if decodeYAMLScalar(scalar) == key { return true }
        }
        return false
    }

    private func decodeYAMLScalar(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        if value.hasPrefix("\"") && value.hasSuffix("\"") {
            let inner = String(value.dropFirst().dropLast())
            return inner.replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        if value.hasPrefix("'") && value.hasSuffix("'") {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return value
    }

    private func yamlScalar(_ s: String) -> String {
        if s.range(of: #"^[A-Za-z0-9_\-./]+$"#, options: .regularExpression) != nil,
           !s.hasPrefix("-"), !s.isEmpty {
            return s
        }
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    // MARK: - 双轨 IO(API 模式 / 文件模式)

    /// 文件模式才需要 flock 与本地 YAML 预检;API 模式下 CPA 服务端自带互斥与写入校验,
    /// 且 KeyDrop 完全不触碰本地文件 —— flock 的锁文件也在 Documents 下,同样触发 TCC 弹窗
    private func withCPASync<T>(_ body: () throws -> T) throws -> T {
        if CPAAPI.apiMode { return try body() }
        return try withWriteLock {
            try Self.validateYAML(path: configPath)
            return try body()
        }
    }
    /// 写路径统一锁入口。API 模式不取本地文件锁:写入经 CPA 服务端 PUT 串行化,
    /// KeyDrop 对 Documents 下的 config.yaml 系文件零触碰 —— 无条件 open
    /// config.yaml.keydrop-lock 正是 API 模式下仍弹「文稿」授权的残余源头
    /// (真实事故:2026-09-24,导入时 addAggregated 无条件取锁,重新编译使
    /// TCC 授权作废后,这次 open 即触发弹窗)
    private func withWriteLock<T>(_ body: () throws -> T) rethrows -> T {
        if CPAAPI.apiMode { return try body() }
        return try FileLock.withLock(FileLock.lockPath(for: configPath)) {
            try body()
        }
    }

    private func configAvailable() -> Bool {
        CPAAPI.apiMode ? true : FileManager.default.fileExists(atPath: configPath)
    }
    private func readConfigText() throws -> String {
        try CPAAPI.readConfigText(path: configPath)
    }

    private func atomicWrite(_ content: String) throws {
        if CPAAPI.apiMode {
            // API 模式:PUT 交 CPA 服务端校验+落盘+热重载;KeyDrop 不触碰本地文件。
            // 服务端校验失败直接 422,原配置不受影响,无需本地备份/回滚
            try CPAAPI.writeConfigText(content, path: configPath)
            return
        }
        let url = URL(fileURLWithPath: configPath)
        let bak = url.appendingPathExtension("keydrop-bak")
        try? FileManager.default.removeItem(at: bak)
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.copyItem(at: url, to: bak)
        }
        guard let data = content.data(using: .utf8) else {
            throw WriterError.file("CPA 配置无法编码为 UTF-8")
        }
        // 注意:禁止 rename/原子替换(config.yaml 可能被 Docker 单文件 bind mount,
        // inode 更换会导致容器内挂载断链,报 open ...: no such file or directory)。
        // 必须原地写入保持 inode;崩溃损坏可用 keydrop-bak 恢复。
        try data.write(to: url)
        // 写后校验 YAML;失败则回滚旧内容,避免损坏配置导致网关拒绝启动
        do {
            try Self.validateYAML(path: configPath)
        } catch {
            let bakPath = url.appendingPathExtension("keydrop-bak").path
            var rollbackFailed = false
            if let old = try? Data(contentsOf: URL(fileURLWithPath: bakPath)) {
                do { try old.write(to: url) }
                catch { rollbackFailed = true }
            }
            let suffix = rollbackFailed
                ? "。⚠ 回滚也失败,请手动用备份恢复: \(bakPath)"
                : "(备份: \(bakPath))"
            throw WriterError.file("CPA 配置 YAML 校验失败,已回滚: \(error.localizedDescription)\(suffix)")
        }
    }

    private static let validatorLock = NSLock()
    private static var validatorState = 0  // 0=未探测 1=可用 2=不可用

    /// python3/PyYAML 缺失 → 校验器不可用。这只意味着「无法校验」而非「YAML 非法」,
    /// 此时放行写入,避免无 PyYAML 的机器上 CPA 功能整体瘫痪。
    private static func yamlValidatorAvailable() -> Bool {
        validatorLock.lock(); defer { validatorLock.unlock() }
        if validatorState != 0 { return validatorState == 1 }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-c", "import yaml"]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            validatorState = p.terminationStatus == 0 ? 1 : 2
        } catch {
            validatorState = 2
        }
        return validatorState == 1
    }

    private static func markValidatorUnavailable() {
        validatorLock.lock()
        validatorState = 2
        validatorLock.unlock()
    }

    /// 用系统 python3(yaml) 校验配置:语法 + 重复键(Go yaml.v3 会拒绝重复键,容器拒启)
    private static func validateYAML(path: String) throws {
        guard yamlValidatorAvailable() else {
            Logger.warn("CPA YAML 校验器不可用(缺 python3/PyYAML),已跳过校验")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-c",
            "import sys,yaml\n"
            + "def walk(n):\n"
            + "    if isinstance(n, yaml.MappingNode):\n"
            + "        seen = set()\n"
            + "        for k, v in n.value:\n"
            + "            key = k.value\n"
            + "            if key in seen:\n"
            + "                print(f'重复键 {key} (第 {k.start_mark.line+1} 行)', file=sys.stderr)\n"
            + "                sys.exit(1)\n"
            + "            seen.add(key)\n"
            + "            walk(v)\n"
            + "    elif isinstance(n, yaml.SequenceNode):\n"
            + "        for v in n.value: walk(v)\n"
            + "try:\n"
            + "    walk(yaml.compose(open(sys.argv[1])))\n"
            + "except Exception as e:\n"
            + "    print(e, file=sys.stderr)\n"
            + "    sys.exit(1)",
            path]
        let pipe = Pipe()
        p.standardError = pipe
        p.standardOutput = Pipe()
        try p.run()
        // 先读完再等退出:输出超过管道缓冲时,先 wait 会导致子进程写阻塞而死锁
        let errData = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus != 0 else { return }
        let err = String(data: errData, encoding: .utf8) ?? "未知错误"
        // 运行中途才暴露的 import 失败按「校验器不可用」处理,不误判为 YAML 非法
        if err.contains("No module named") || err.contains("ImportError") || err.contains("ModuleNotFoundError") {
            markValidatorUnavailable()
            Logger.warn("CPA YAML 校验器不可用(缺 PyYAML),已跳过校验")
            return
        }
        throw WriterError.file(err.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
