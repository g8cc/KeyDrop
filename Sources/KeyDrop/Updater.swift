import AppKit
import Foundation
import CryptoKit
import KeyDropCore

enum UpdateError: LocalizedError {
    case noRelease
    case badResponse(String)
    case noAsset
    case downloadFailed(String)
    case extractFailed(String)
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .noRelease: return "GitHub 上还没有发布版本"
        case .badResponse(let s): return "更新源响应异常: \(s)"
        case .noAsset: return "发布中没有找到 KeyDrop 安装包"
        case .downloadFailed(let s): return "下载失败: \(s)"
        case .extractFailed(let s): return "解压失败: \(s)"
        case .installFailed(let s): return "安装失败: \(s)"
        }
    }
}

/// 软件更新:GitHub Releases 为版本源,启动时静默检查,发现新版本由 UI 提醒,下载解压后替换自身
final class Updater {
    static let shared = Updater()

    private static let repo = "g8cc/KeyDrop"
    private let apiURL: URL? = URL(string: "https://api.github.com/repos/g8cc/KeyDrop/releases/latest")

    enum State: Equatable {
        case idle
        case checking
        case available(version: String, url: URL, notes: String)
        case downloading(version: String, progress: Double)
        case ready(version: String)
        case installing
        case upToDate
        case failed(String)
    }

    private(set) var state: State = .idle
    var onStateChange: ((State) -> Void)?
    private var downloadTask: URLSessionDownloadTask?
    /// 发布资产声明的 sha256(GitHub asset.digest)。若存在,安装前校验下载包完整性
    private var pendingDigest: String?
    /// 已下载就绪的更新包(.ready 态):用户确认重启后才真正替换安装
    private var pendingArchive: (url: URL, version: String)?
    private var progressTimer: Timer?
    private var downloadGeneration = UUID()
    private let lastCheckKey = "updateLastCheckAt"
    private let promptedVersionKey = "updatePromptedVersion"

    static func currentVersion() -> String { Version.currentVersion() }

    /// 启动时检查:同一天只查一次,避免频繁打 GitHub API
    func checkForUpdates(force: Bool = false) {
        guard let apiURL else { return }
        // 重入保护:正在检查/下载/安装时,「检查更新」不得把状态覆盖回 .checking
        switch state {
        case .checking, .downloading, .installing: return
        default: break
        }
        if !force {
            let last = defaults.double(forKey: lastCheckKey)
            if Date().timeIntervalSince1970 - last < 12 * 3600 { return }
        }
        // 注意:不在发起请求前写 lastCheckKey。旧实现先写时间戳,
        // 网络瞬时失败也会进入 12h 冷却,用户从此收不到自动更新提示。
        state = .checking

        var req = URLRequest(url: apiURL)
        req.timeoutInterval = 10
        req.setValue("KeyDrop-Updater/\(Self.currentVersion())", forHTTPHeaderField: "User-Agent")
        Self.urlSession(proxy: Prefs.shared.proxy).dataTask(with: req) { [weak self] data, resp, err in
            guard let self else { return }
            if let err {
                self.setState(.failed("检查更新失败: \(err.localizedDescription)"))
                return
            }
            guard let data, let http = resp as? HTTPURLResponse else {
                self.setState(.failed("检查更新失败: 无响应"))
                return
            }
            guard http.statusCode == 200 else {
                if http.statusCode == 404 {
                    self.defaults.set(Date().timeIntervalSince1970, forKey: self.lastCheckKey)
                    self.setState(.upToDate)
                    return
                }
                // GitHub API 匿名配额按出口 IP 计(60 次/时),共享代理出口 IP 常被
                // 同节点用户耗光 → 403/429(真实事故:2026-09-23,代理 146.70.x.x)。
                // 兜底:github.com/<repo>/releases/latest 的 302 Location 自带版本号,
                // 不走 api.github.com 配额。失败才报错,报错文案带上限流语义。
                if http.statusCode == 403 || http.statusCode == 429 {
                    Self.fetchLatestByRedirect(proxy: Prefs.shared.proxy) { [weak self] version, err in
                        self?.handleRedirectCheck(version, err: err)
                    }
                    return
                }
                self.setState(.failed("检查更新失败: HTTP \(http.statusCode)"))
                return
            }
            // 服务端已应答:记录检查时间,避免重复轮询(失败路径不写,留给下次启动重试)
            self.defaults.set(Date().timeIntervalSince1970, forKey: self.lastCheckKey)
            do {
                let info = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                guard let tag = info?["tag_name"] as? String else {
                    self.setState(.failed("检查更新失败: 版本信息缺失"))
                    return
                }
                let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                guard Version.isValidReleaseVersion(version) else {
                    self.setState(.failed("检查更新失败: 版本号格式无效"))
                    return
                }
                let local = Self.currentVersion()
                if Version.compare(version, local) != .orderedDescending {
                    self.setState(.upToDate)
                    return
                }
                guard let assets = info?["assets"] as? [[String: Any]],
                      let asset = assets.first(where: { ($0["name"] as? String)?.hasPrefix("KeyDrop-") == true && ($0["name"] as? String)?.hasSuffix(".zip") == true }),
                      let urlStr = asset["browser_download_url"] as? String,
                      let url = URL(string: urlStr),
                      Self.isTrustedDownloadURL(url) else {
                    self.setState(.failed("检查更新失败: 未找到安装包"))
                    return
                }
                let notes = (info?["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if let digest = asset["digest"] as? String, digest.lowercased().hasPrefix("sha256:") {
                    self.pendingDigest = String(digest.dropFirst("sha256:".count)).lowercased()
                } else {
                    self.pendingDigest = nil
                }
                self.setState(.available(version: version, url: url, notes: notes))
            } catch {
                self.setState(.failed("检查更新失败: 解析错误"))
            }
        }.resume()
    }

    /// 有新版本且本机未提示过 → 返回是否需要弹窗
    func shouldPromptFor(_ version: String) -> Bool {
        let prompted = defaults.string(forKey: promptedVersionKey)
        if prompted == version { return false }
        defaults.set(version, forKey: promptedVersionKey)
        return true
    }

    /// 自动下载新包;完成停在 .ready,等用户确认后 applyUpdate() 才替换重启。
    /// (产品决策:自动下载可以,静默重启不行 —— 重启会打断用户正在用的会话)
    func startDownload() {
        guard case .available(let version, let url, _) = state else { return }
        guard Self.isTrustedDownloadURL(url) else {
            setState(.failed("下载失败: 更新地址不受信任"))
            return
        }
        let generation = UUID()
        downloadGeneration = generation
        state = .downloading(version: version, progress: 0)
        var req = URLRequest(url: url)
        req.timeoutInterval = 300
        req.setValue("KeyDrop-Updater/\(Self.currentVersion())", forHTTPHeaderField: "User-Agent")
        let task = Self.urlSession(proxy: Prefs.shared.proxy).downloadTask(with: req) { [weak self] fileURL, resp, err in
            // URLSession 回调在后台线程:downloadTask/progressTimer 都是主线程对象,
            // 在后台写它们与 Timer 的读取构成数据竞争(且 Timer.invalidate 非线程安全)。
            // 统一 hop 回 main 再处理。
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.downloadGeneration == generation else {
                    if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
                    return
                }
                self.downloadTask = nil
                if let err {
                    self.setState(.failed("下载失败: \(err.localizedDescription)"))
                    return
                }
                guard let fileURL, let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                    self.setState(.failed("下载失败: HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)"))
                    return
                }
                // 大小防护:异常/恶意响应不应写满磁盘。两道拦截:
                // ① 响应头声明的大小;② 落盘后实测(downloadTask 无法边下边限流,这里兜底)
                let maxBytes = 150_000_000
                if http.expectedContentLength > maxBytes {
                    self.setState(.failed("更新包过大(\(http.expectedContentLength / 1_000_000)MB),已取消"))
                    return
                }
                if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                   let size = attrs[.size] as? Int, size > maxBytes {
                    self.setState(.failed("更新包过大(\(size / 1_000_000)MB),已取消"))
                    return
                }
                self.progressTimer?.invalidate()
                self.progressTimer = nil
                self.pendingArchive = (url: fileURL, version: version)
                self.setState(.ready(version: version))
            }
        }
        downloadTask = task
        task.resume()
        // 轮询下载进度(downloadTask 回调式 API 不推进度;面板/菜单都要展示百分比)
        progressTimer?.invalidate()
        let v = version
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, let t = self.downloadTask else { return }
            let total = t.countOfBytesExpectedToReceive
            let got = t.countOfBytesReceived
            guard total > 0 else { return }
            self.setState(.downloading(version: v, progress: min(Double(got) / Double(total), 1.0)))
        }
    }

    /// 用户确认后:替换运行中的 app 并重启(只有 .ready 态可用)
    func applyUpdate() {
        guard case .ready = state, let a = pendingArchive else { return }
        progressTimer?.invalidate()
        progressTimer = nil
        // install 会做 sha256(最大 150MB)、ditto 解压、codesign 校验 —— 全部同步阻塞。
        // 直接在主线程跑会让菜单栏应用无响应数十秒(点「重启完成更新」后界面卡死,
        // 用户以为崩了会强杀进程,正好卡在「已移走旧包」的中间态)。
        // 放后台执行,状态更新由 setState 自己 hop 回 main。
        let digest = pendingDigest
        setState(.installing)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.install(archive: a.url, version: a.version, expectedDigest: digest)
        }
    }

    func cancelDownload() {
        downloadGeneration = UUID()
        progressTimer?.invalidate()
        downloadTask?.cancel()
        downloadTask = nil
        if let archive = pendingArchive {
            try? FileManager.default.removeItem(at: archive.url)
        }
        pendingArchive = nil
        pendingDigest = nil
        // 取消后必须把状态清掉,否则 UI 永远停在「下载中」
        setState(.idle)
    }

    private func install(archive: URL, version: String, expectedDigest: String?) {
        let fm = FileManager.default
        let tmp = NSTemporaryDirectory() + "KeyDropUpdate-\(UUID().uuidString.prefix(8))"
        do {
            try fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
            // version 来自 GitHub tag,可能含 / 等路径字符 → 先净化再拼路径
            let zipPath = tmp + "/KeyDrop-\(Self.sanitizePathComponent(version)).zip"
            try fm.copyItem(atPath: archive.path, toPath: zipPath)

            // 在任何解压落盘前校验归档条目。解压后再检查只能发现越界,
            // 无法撤销恶意条目已经覆盖的文件,也无法阻止 zip bomb 先撑满磁盘。
            try Self.verifyArchiveBeforeExtraction(at: zipPath)

            // ① 若 GitHub 资产带 sha256,先校验下载包完整性(能挡住被替包的 zip)
            if let expected = expectedDigest {
                guard let actual = Self.sha256Hex(zipPath), actual.caseInsensitiveCompare(expected) == .orderedSame else {
                    throw UpdateError.downloadFailed("更新包 sha256 校验失败,已拒绝安装")
                }
            }

            let extractDir = tmp + "/extract"
            try fm.createDirectory(atPath: extractDir, withIntermediateDirectories: true)
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-x", "-k", zipPath, extractDir]
            // ditto 输出必须被消费:只建 Pipe 不读,输出超管道缓冲会让子进程阻塞在 write,
            // waitUntilExit() 就永久卡死。先读完(到 EOF)再 wait。
            let pipe = Pipe()
            ditto.standardOutput = pipe
            ditto.standardError = pipe
            try ditto.run()
            let dittoOut = pipe.fileHandleForReading.readDataToEndOfFile()
            ditto.waitUntilExit()
            guard ditto.terminationStatus == 0 else {
                let tail = String(data: dittoOut, encoding: .utf8)?.suffix(200) ?? ""
                throw UpdateError.extractFailed("ditto exit \(ditto.terminationStatus) \(tail)")
            }

            // Zip Slip 防护:ditto -x 对含 "../" 或绝对路径的条目并非总是拒绝,
            // 恶意/损坏的包可以把文件写到 extractDir 之外(甚至覆盖 ~/.ssh 等)。
            // 解压后校验:顶层必须只有一个 KeyDrop.app,且所有条目都解析在 extractDir 内。
            try Self.verifyExtractionContained(at: extractDir)

            let newBundle = extractDir + "/KeyDrop.app"
            guard fm.fileExists(atPath: newBundle) else {
                throw UpdateError.extractFailed("包内缺少 KeyDrop.app")
            }
            let runningPath = Bundle.main.bundlePath
            guard !runningPath.isEmpty else {
                throw UpdateError.installFailed("无法定位当前应用路径")
            }
            // 仅允许 .app 形态自更新:裸二进制(如 .build/release/KeyDrop)的 bundlePath
            // 是普通目录,替换会连带删掉目录里的其他文件,且无法自替换
            guard runningPath.hasSuffix(".app") else {
                throw UpdateError.installFailed("当前不是 .app 运行形态,请手动更新")
            }

            // ② 包身份/版本/签名校验:必须同一 bundle id、版本与发布一致、ad-hoc 签名未破坏
            try Self.verifyNewBundle(at: newBundle, expectedVersion: version)

            // ③ 先替换、后杀进程。替换(改名旧包→挪入新包)是唯一可能失败的可逆步骤,
            //    放在杀进程之前:失败可回滚且应用仍在运行。
            //    旧实现先 kill -9 再 mv,mv 失败时应用已死、无回滚、用户无感知。
            let backupPath = runningPath + ".keydrop-old"
            try? fm.removeItem(atPath: backupPath)
            try fm.moveItem(atPath: runningPath, toPath: backupPath)
            do {
                try fm.moveItem(atPath: newBundle, toPath: runningPath)
            } catch {
                try? fm.moveItem(atPath: backupPath, toPath: runningPath)
                throw UpdateError.installFailed("替换失败,已回滚: \(error.localizedDescription)")
            }

            // ④ 替换成功后才重启。必须 kill 在 open 之前:同 bundle id 已有实例在跑时,
            //    open 只会激活旧实例而不会启动新包。
            let myPID = ProcessInfo.processInfo.processIdentifier
            let script = """
            kill -9 \(myPID) 2>/dev/null || true
            sleep 1
            open \(Self.shellEscape(runningPath))
            (sleep 8 && rm -rf \(Self.shellEscape(tmp))) &
            """
            let sh = Process()
            sh.executableURL = URL(fileURLWithPath: "/bin/sh")
            sh.arguments = ["-c", script]
            try sh.run()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NSApp.terminate(nil)
            }
        } catch {
            // 任何失败都清掉临时目录,不泄漏下载的 zip 与解压内容
            try? fm.removeItem(atPath: tmp)
            setState(.failed(error.localizedDescription))
        }
    }

    // MARK: - 更新包校验

    /// 预检 zip 条目路径与声明的解压总量,避免 Zip Slip/zip bomb 在解压阶段生效。
    private static func verifyArchiveBeforeExtraction(at path: String) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-l", path]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            throw UpdateError.extractFailed("无法预检更新包: \(error.localizedDescription)")
        }

        let output: Data
        do {
            output = try Self.readProcessOutputBounded(pipe, maxBytes: 4_000_000, process: proc)
        } catch {
            proc.terminate()
            proc.waitUntilExit()
            throw error
        }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw UpdateError.extractFailed("更新包目录读取失败")
        }
        guard let text = String(data: output, encoding: .utf8) else {
            throw UpdateError.extractFailed("更新包目录不是有效 UTF-8")
        }

        var count = 0
        var totalSize = 0
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4,
                  parts[1].count == 10,
                  parts[2].contains(":"),
                  let size = Int(parts[0]), size >= 0 else { continue }
            let name = String(parts[3])
            let normalized = name.replacingOccurrences(of: "\\", with: "/")
            let components = normalized.split(separator: "/", omittingEmptySubsequences: true)
            guard !normalized.hasPrefix("/"), !normalized.contains("\0"),
                  !components.contains(".."), let first = components.first else {
                throw UpdateError.extractFailed("更新包包含越界路径,已拒绝安装")
            }
            guard first == "KeyDrop.app" || first == "__MACOSX" || (components.count == 1 && first == ".DS_Store") else {
                throw UpdateError.extractFailed("更新包顶层含非预期内容,已拒绝安装: \(name)")
            }
            count += 1
            let (sum, overflow) = totalSize.addingReportingOverflow(size)
            guard !overflow, sum <= 150_000_000 else {
                throw UpdateError.extractFailed("更新包解压后超过 150MB,已拒绝安装")
            }
            totalSize = sum
            guard count <= 10_000 else {
                throw UpdateError.extractFailed("更新包文件数过多,已拒绝安装")
            }
        }
    }

    private static func readProcessOutputBounded(_ pipe: Pipe, maxBytes: Int, process: Process) throws -> Data {
        var output = Data()
        let handle = pipe.fileHandleForReading
        while true {
            let chunk = handle.readData(ofLength: 4096)
            if chunk.isEmpty { break }
            if output.count > maxBytes - chunk.count {
                process.terminate()
                throw UpdateError.extractFailed("更新包目录过大,已拒绝安装")
            }
            output.append(chunk)
        }
        return output
    }

    /// Zip Slip 防护:确认解压产物全部落在 extractDir 之内,且顶层只有 KeyDrop.app。
    /// 不依赖 ditto 的路径清洗行为 —— 它面对 "../" / 绝对路径条目时并不保证拒绝,
    /// 一旦写出目录外就是任意文件覆盖(可覆盖 ~/.ssh/authorized_keys 等)。
    private static func verifyExtractionContained(at extractDir: String) throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: extractDir).standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) else {
            throw UpdateError.extractFailed("无法枚举解压产物")
        }
        for case let url as URL in en {
            // 解析符号链接后再判断:包内符号链接可以指向目录外
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path.hasPrefix(rootPath) || resolved.path == root.path else {
                throw UpdateError.extractFailed("更新包包含越界路径,已拒绝安装: \(url.lastPathComponent)")
            }
        }
        // 顶层条目白名单:只允许 KeyDrop.app
        let top = (try? fm.contentsOfDirectory(atPath: extractDir)) ?? []
        guard top.allSatisfy({ $0 == "KeyDrop.app" || $0 == ".DS_Store" || $0 == "__MACOSX" }) else {
            throw UpdateError.extractFailed("更新包顶层含非预期内容(\(top.joined(separator: ", "))),已拒绝安装")
        }
    }

    /// 启动后延迟清理上次更新留下的 .keydrop-old 备份与 /tmp 更新目录。
    /// 旧实现由替换脚本在 6 秒后无条件删备份:若新版本一启动就崩,唯一可用的旧版也没了,
    /// 用户被锁死在坏版本上。改为「新版本正常运行到启动后若干秒」才清理,
    /// 启动即崩时备份仍在,可手动恢复。
    static func cleanupAfterUpdate() {
        let fm = FileManager.default
        let backup = Bundle.main.bundlePath + ".keydrop-old"
        if fm.fileExists(atPath: backup) { try? fm.removeItem(atPath: backup) }
        let tmpRoot = NSTemporaryDirectory()
        if let entries = try? fm.contentsOfDirectory(atPath: tmpRoot) {
            for e in entries where e.hasPrefix("KeyDropUpdate-") {
                try? fm.removeItem(atPath: tmpRoot + e)
            }
        }
    }

    /// 校验下载解压出的 KeyDrop.app:身份、版本、可执行文件与 ad-hoc 签名完整性
    private static func verifyNewBundle(at path: String, expectedVersion: String) throws {
        let fm = FileManager.default
        guard let dict = NSDictionary(contentsOfFile: path + "/Contents/Info.plist") as? [String: Any] else {
            throw UpdateError.installFailed("更新包缺少 Info.plist")
        }
        guard (dict["CFBundleIdentifier"] as? String) == "com.keydrop.app" else {
            throw UpdateError.installFailed("更新包 bundle id 不匹配,已拒绝安装")
        }
        let bundleVersion = (dict["CFBundleShortVersionString"] as? String) ?? ""
        guard bundleVersion == expectedVersion else {
            throw UpdateError.installFailed("更新包版本(\(bundleVersion))与发布版本(\(expectedVersion))不一致,已拒绝安装")
        }
        guard fm.isExecutableFile(atPath: path + "/Contents/MacOS/KeyDrop") else {
            throw UpdateError.installFailed("更新包缺少可执行文件")
        }
        // ad-hoc 签名完整性:包被篡改会使签名失效,--verify 返回非 0
        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = ["--verify", "--deep", "--strict", path]
        codesign.standardOutput = FileHandle.nullDevice
        codesign.standardError = FileHandle.nullDevice
        try codesign.run()
        codesign.waitUntilExit()
        guard codesign.terminationStatus == 0 else {
            throw UpdateError.installFailed("更新包签名校验失败,已拒绝安装")
        }
    }

    /// 流式计算 sha256,避免把上百 MB 的 zip 整体读进内存
    private static func sha256Hex(_ path: String) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        var hasher = SHA256()
        while true {
            let chunk = fh.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func sanitizePathComponent(_ s: String) -> String {
        let allowed = s.replacingOccurrences(of: #"[^A-Za-z0-9._-]"#, with: "_", options: .regularExpression)
        return allowed.isEmpty ? "unknown" : String(allowed.prefix(64))
    }

    private static func isTrustedDownloadURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return host == "github.com" || host == "objects.githubusercontent.com" || host.hasSuffix(".githubusercontent.com")
    }

    private static func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 更新请求走用户配置的本机代理(GitHub API/资产下载在部分网络直连不可达);
    /// 代理为空/不可识别 → 系统默认会话。
    /// session 按代理地址缓存:旧实现每次检查/下载都新建 URLSession 且从不 invalidate,
    /// 内部线程与连接池常驻(菜单栏 app 长驻,反复「检查更新」持续泄漏)。
    private static let sessionLock = NSLock()
    private static var sessions: [String: URLSession] = [:]

    private static func urlSession(proxy: String?) -> URLSession {
        let p = proxy?.trimmingCharacters(in: .whitespaces) ?? ""
        // 只接受 http(s) 代理:CFNetwork 的 connectionProxyDictionary 不支持 socks,
        // 传 socks 地址进去等于把请求发到 SOCKS 端口上,必然失败
        guard !p.isEmpty, let u = URL(string: p), u.host != nil,
              ["http", "https"].contains(u.scheme?.lowercased() ?? ""),
              (u.port ?? 80) > 0, (u.port ?? 80) <= 65535
        else { return .shared }
        sessionLock.lock()
        defer { sessionLock.unlock() }
        if let cached = sessions[p] { return cached }
        let s = URLSession(configuration: proxyConfig(p))
        // 上限保护:用户反复改代理会产生多个地址
        if sessions.count >= 4 {
            let evicted = sessions
            sessions.removeAll()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 60) {
                evicted.values.forEach { $0.finishTasksAndInvalidate() }
            }
        }
        sessions[p] = s
        return s
    }

    private static func proxyConfig(_ proxy: String?) -> URLSessionConfiguration {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        if let p = proxy?.trimmingCharacters(in: .whitespaces), !p.isEmpty,
           let u = URL(string: p), let host = u.host,
           ["http", "https"].contains(u.scheme?.lowercased() ?? "") {
            let port = u.port ?? (u.scheme?.lowercased() == "https" ? 443 : 80)
            cfg.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPProxy as String: host,
                kCFNetworkProxiesHTTPPort as String: port,
                kCFNetworkProxiesHTTPSProxy as String: host,
                kCFNetworkProxiesHTTPSPort as String: port,
            ]
        }
        return cfg
    }

    /// 只取 302 的目标 URL 就停,不跟进重定向(release 页面没必要拉下来)
    private final class RedirectCapture: NSObject, URLSessionDataDelegate {
        var target: URL?
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            target = request.url
            completionHandler(nil)
        }
    }

    /// 限流兜底:GET releases/latest 拿 302 Location 里的 tag,不占 API 配额
    private static func fetchLatestByRedirect(proxy: String?, completion: @escaping (_ version: String?, _ err: String?) -> Void) {
        guard let base = URL(string: "https://github.com/\(repo)/releases/latest") else {
            completion(nil, "URL 无效"); return
        }
        var req = URLRequest(url: base)
        req.timeoutInterval = 10
        req.setValue("KeyDrop-Updater/\(Self.currentVersion())", forHTTPHeaderField: "User-Agent")
        let cap = RedirectCapture()
        let sess = URLSession(configuration: proxyConfig(proxy), delegate: cap, delegateQueue: nil)
        sess.dataTask(with: req) { _, resp, err in
            sess.invalidateAndCancel()
            if let err { completion(nil, err.localizedDescription); return }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard (300...399).contains(status), let loc = cap.target else {
                completion(nil, "HTTP \(status),无重定向")
                return
            }
            guard let v = Version.fromTagPath(loc.path) else {
                completion(nil, "重定向路径解析不出版本: \(loc.path)")
                return
            }
            completion(v, nil)
        }.resume()
    }

    /// 兜底检查结果落状态。此通道拿不到发布说明与 sha256 digest:
    /// notes 置空、pendingDigest 置 nil,安装前仍靠 codesign 严格校验把关
    private func handleRedirectCheck(_ version: String?, err: String?) {
        guard let version else {
            setState(.failed("检查更新失败: GitHub API 限流(403),兜底通道也失败: \(err ?? "未知")"))
            return
        }
        defaults.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
        guard Version.compare(version, Self.currentVersion()) == .orderedDescending else {
            setState(.upToDate); return
        }
        // 资产名由 make release 固定为 KeyDrop-v<版本>.zip;若改命名需同步这里
        guard let asset = URL(string: "https://github.com/\(Self.repo)/releases/download/v\(version)/KeyDrop-v\(version).zip") else {
            setState(.failed("检查更新失败: 兜底安装包地址无效"))
            return
        }
        pendingDigest = nil
        setState(.available(version: version, url: asset, notes: ""))
    }

    private func setState(_ s: State) {
        DispatchQueue.main.async {
            self.state = s
            self.onStateChange?(s)
        }
    }

    private let defaults = UserDefaults.standard
}
