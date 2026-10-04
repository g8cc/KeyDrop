import Foundation

/// WebDAV 同步(Phase 2 简化版,无需自建账号服务):
/// 把端到端加密的账本快照推送到用户自己的 WebDAV(坚果云等),另一台机器拉取后
/// 走 importLedger 合并 + replayArtifacts 重放。WebDAV 服务端只见密文;
/// 导出口令只存本机 prefs(与明文账本同级敏感度,不上传)。
///
/// 语义:显式推送/拉取,不做后台自动同步。推送=覆盖远端快照;
/// 拉取=按 id 合并(绝不覆盖本机已有条目),本机墓碑(已删除)的 key 不复活。
enum WebDAVSync {

    struct Config {
        let base: String        // 目录 URL(无尾斜杠)
        let user: String
        let pass: String
        let exportPass: String

        static func resolved() -> Config? {
            let p = Prefs.shared
            guard let url = p.webdavURL, !url.isEmpty,
                  let user = p.webdavUser, !user.isEmpty,
                  let pass = p.webdavPass, !pass.isEmpty,
                  let ep = p.webdavExportPass, !ep.isEmpty else { return nil }
            var base = url
            while base.hasSuffix("/") { base = String(base.dropLast()) }
            guard let u = URL(string: base), u.scheme == "http" || u.scheme == "https" else { return nil }
            return Config(base: base, user: user, pass: pass, exportPass: ep)
        }
    }

    static func notConfiguredMessage() -> String {
        "WebDAV 未配置:需要目录 URL、账号、密码与账本加密口令(菜单栏「WebDAV 同步设置…」)"
    }

    /// 文件名固定:同目录只有一份快照,推送即覆盖,拉取即最新
    static func fileURL(_ base: String) -> URL {
        URL(string: base + "/KeyDrop-ledger.keydrop")!
    }

    private static func request(_ method: String, _ url: URL, cfg: Config,
                                body: Data? = nil) throws -> (Int, Data) {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 60
        let auth = Data("\(cfg.user):\(cfg.pass)".utf8).base64EncodedString()
        req.setValue("Basic \(auth)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = body
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        }
        var payload = Data()
        var code = 0
        var taskError: Error?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { d, r, e in
            defer { sem.signal() }
            payload = d ?? Data()
            code = (r as? HTTPURLResponse)?.statusCode ?? 0
            taskError = e
        }.resume()
        sem.wait()
        if let taskError { throw taskError }
        return (code, payload)
    }

    /// 推送:端到端加密导出 → PUT 覆盖远端快照。目录不存在时自动 MKCOL 一次。
    public static func push(cfg: Config, ledger: Data) throws -> String {
        let fileURL = fileURL(cfg.base)
        var (code, _) = try request("PUT", fileURL, cfg: cfg, body: ledger)
        if code == 409 {
            // 目录不存在:MKCOL 父目录后重试一次(坚果云等对不存在的集合返回 409)
            _ = try? request("MKCOL", URL(string: cfg.base)!, cfg: cfg)
            (code, _) = try request("PUT", fileURL, cfg: cfg, body: ledger)
        }
        guard (200...299).contains(code) else {
            throw LedgerTransferError.badEnvelope("WebDAV 推送失败: HTTP \(code)(检查地址/账号/密码)")
        }
        return "已推送加密账本到 WebDAV(\(ledger.count) 字节,服务端只见密文)"
    }

    /// 拉取:下载远端快照 → importLedger 按 id 合并(绝不覆盖本机已有条目,
    /// 本机墓碑的 key 不复活)→ 产物重放把新补入的条目在本机重建。
    public static func pull(cfg: Config, core: Core, replay: Bool = true) throws -> String {
        let (code, data) = try request("GET", fileURL(cfg.base), cfg: cfg)
        guard code == 200, !data.isEmpty else {
            throw LedgerTransferError.badEnvelope("WebDAV 拉取失败: HTTP \(code)(远端还没有快照?)")
        }
        let msg = try core.importLedger(data, passphrase: cfg.exportPass)
        var lines = [msg]
        if replay {
            lines.append(contentsOf: core.replayArtifacts())
        }
        return lines.joined(separator: "\n")
    }
}
