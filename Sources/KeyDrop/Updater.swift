import AppKit
import Foundation
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

    private let repo = "g8cc/KeyDrop"
    private let apiURL: URL? = URL(string: "https://api.github.com/repos/g8cc/KeyDrop/releases/latest")

    enum State {
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
    private let lastCheckKey = "updateLastCheckAt"
    private let promptedVersionKey = "updatePromptedVersion"

    static func currentVersion() -> String { Version.currentVersion() }

    /// 启动时检查:同一天只查一次,避免频繁打 GitHub API
    func checkForUpdates(force: Bool = false) {
        guard let apiURL else { return }
        if !force {
            let last = defaults.double(forKey: lastCheckKey)
            if Date().timeIntervalSince1970 - last < 12 * 3600 { return }
        }
        defaults.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
        state = .checking

        var req = URLRequest(url: apiURL)
        req.timeoutInterval = 10
        req.setValue("KeyDrop-Updater/\(Self.currentVersion())", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
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
                    self.setState(.upToDate)
                    return
                }
                self.setState(.failed("检查更新失败: HTTP \(http.statusCode)"))
                return
            }
            do {
                let info = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                guard let tag = info?["tag_name"] as? String else {
                    self.setState(.failed("检查更新失败: 版本信息缺失"))
                    return
                }
                let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                let local = Self.currentVersion()
                if Version.compare(version, local) != .orderedDescending {
                    self.setState(.upToDate)
                    return
                }
                guard let assets = info?["assets"] as? [[String: Any]],
                      let asset = assets.first(where: { ($0["name"] as? String)?.hasPrefix("KeyDrop-") == true && ($0["name"] as? String)?.hasSuffix(".zip") == true }),
                      let urlStr = asset["browser_download_url"] as? String,
                      let url = URL(string: urlStr) else {
                    self.setState(.failed("检查更新失败: 未找到安装包"))
                    return
                }
                let notes = (info?["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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

    /// 下载 zip → 解压 → 替换运行中的 app → 重启
    func downloadAndInstall() {
        guard case .available(let version, let url, _) = state else { return }
        state = .downloading(version: version, progress: 0)
        var req = URLRequest(url: url)
        req.timeoutInterval = 300
        req.setValue("KeyDrop-Updater/\(Self.currentVersion())", forHTTPHeaderField: "User-Agent")
        let task = URLSession.shared.downloadTask(with: req) { [weak self] fileURL, resp, err in
            guard let self else { return }
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
            self.install(archive: fileURL, version: version)
        }
        downloadTask = task
        task.resume()
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
    }

    private func install(archive: URL, version: String) {
        let fm = FileManager.default
        let tmp = NSTemporaryDirectory() + "KeyDropUpdate-\(UUID().uuidString.prefix(8))"
        do {
            try fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
            let zipPath = tmp + "/KeyDrop-\(version).zip"
            try fm.copyItem(atPath: archive.path, toPath: zipPath)

            // 本函数运行在 URLSession 回调线程,state 更新必须走 main(setState)
            setState(.installing)
            let extractDir = tmp + "/extract"
            try fm.createDirectory(atPath: extractDir, withIntermediateDirectories: true)
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-x", "-k", zipPath, extractDir]
            let pipe = Pipe()
            ditto.standardOutput = pipe
            ditto.standardError = pipe
            try ditto.run()
            ditto.waitUntilExit()
            guard ditto.terminationStatus == 0 else {
                throw UpdateError.extractFailed("ditto exit \(ditto.terminationStatus)")
            }

            let newBundle = extractDir + "/KeyDrop.app"
            guard fm.fileExists(atPath: newBundle) else {
                throw UpdateError.extractFailed("包内缺少 KeyDrop.app")
            }
            let runningPath = Bundle.main.bundlePath
            guard !runningPath.isEmpty else {
                throw UpdateError.installFailed("无法定位当前应用路径")
            }
            // 仅允许 .app 形态自更新:裸二进制(如 .build/release/KeyDrop)的 bundlePath
            // 是普通目录,rm -rf 会连带删掉目录里的其他文件,且无法自替换
            guard runningPath.hasSuffix(".app") else {
                throw UpdateError.installFailed("当前不是 .app 运行形态,请手动更新")
            }

            // 杀自己用精确 PID,pkill -f 全串匹配是 ERE 正则,路径含 + 等元字符时
            // 会杀不掉或误杀其他进程。
            // 替换采用「先改名利旧 → 挪入新包 → 失败即回滚」:先 rm -rf 的话,
            // 后续 mv 一旦失败(磁盘满/占用),应用就彻底没了。
            let myPID = ProcessInfo.processInfo.processIdentifier
            let backupPath = runningPath + ".keydrop-old"
            func shellEscape(_ s: String) -> String {
                "'" + s.replacingOccurrences(of: "'", with: "'\\''" ) + "'"
            }
            let script = """
            sleep 2
            kill -9 \(myPID) 2>/dev/null || true
            sleep 1
            if mv \(shellEscape(runningPath)) \(shellEscape(backupPath)); then
              if mv \(shellEscape(newBundle)) \(shellEscape(runningPath)); then
                open \(shellEscape(runningPath))
                # 更新成功后清理临时目录(含下载的 zip 与 extract),
                # 否则每次成功更新都在 /tmp 泄漏一份完整安装包
                (sleep 6 && rm -rf \(shellEscape(tmp))) &
                (sleep 5 && rm -rf \(shellEscape(backupPath))) &
              else
                # 新包挪入失败,立即回滚,保证本机始终有一份可用的 KeyDrop
                mv \(shellEscape(backupPath)) \(shellEscape(runningPath))
                exit 1
              fi
            else
              exit 1
            fi
            """
            let sh = Process()
            sh.executableURL = URL(fileURLWithPath: "/bin/sh")
            sh.arguments = ["-c", script]
            try sh.run()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NSApp.terminate(nil)
            }
        } catch {
            try? fm.removeItem(atPath: tmp)
            setState(.failed(error.localizedDescription))
        }
    }

    private func setState(_ s: State) {
        DispatchQueue.main.async {
            self.state = s
            self.onStateChange?(s)
        }
    }

    private let defaults = UserDefaults.standard
}