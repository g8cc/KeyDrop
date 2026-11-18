import Foundation

/// 加密账本快照同步。已有远端文件仅在版本与本机已知的 ETag 一致时更新。
enum WebDAVSync {

    struct Config: Equatable {
        let directory: URL
        let user: String
        let pass: String
        let exportPass: String

        static func resolved() throws -> Config {
            let values = Prefs.shared.webdavSettingsSnapshot()
            let fields = [(values.url, "目录 URL"), (values.user, "账号"),
                          (values.pass, "密码"), (values.exportPass, "加密口令")]
            let missing = fields.compactMap { value, label in
                value?.isEmpty == false ? nil : label
            }
            guard missing.isEmpty, let address = fields[0].0, let user = fields[1].0,
                  let pass = fields[2].0, let exportPass = fields[3].0 else {
                throw ParseError.io("WebDAV 未配置，缺少：\(missing.joined(separator: "、"))")
            }
            guard let parts = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
                  let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
                  parts.query == nil, parts.fragment == nil,
                  let directory = parts.url else {
                throw ParseError.io("WebDAV 目录 URL 无效，请填写带主机名的 HTTP 或 HTTPS 目录地址")
            }
            return Config(directory: directory, user: user, pass: pass, exportPass: exportPass)
        }

        var fileURL: URL { directory.appendingPathComponent("KeyDrop-ledger.keydrop", isDirectory: false) }
    }

    private static func strongTag(_ response: URLResponse?) -> String? {
        guard let tag = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag")?
            .trimmingCharacters(in: .whitespaces),
              tag.hasPrefix("\""), tag.hasSuffix("\""), tag.count >= 2 else { return nil }
        return tag
    }

    private static func request(_ method: String, _ url: URL, cfg: Config, body: Data? = nil,
                                eTag: String? = nil) throws -> (code: Int, data: Data, eTag: String?) {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        req.httpMethod = method
        req.timeoutInterval = 60
        let auth = Data("\(cfg.user):\(cfg.pass)".utf8).base64EncodedString()
        req.setValue("Basic \(auth)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = body
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            if let eTag = validatedTag(eTag) {
                req.setValue(eTag, forHTTPHeaderField: "If-Match")
            } else {
                req.setValue("*", forHTTPHeaderField: "If-None-Match")
            }
        }
        let outcome = NetSync.run(session: URLSession.shared, request: req, timeout: 60)
        if let error = outcome.error { throw error }
        return (NetSync.statusCode(outcome), outcome.data ?? Data(), strongTag(outcome.response))
    }

    // Only accept a single strong entity tag. Treat missing/weak tags as an unknown version.
    private static func validatedTag(_ tag: String?) -> String? {
        guard let tag, tag.count >= 2, tag.first == "\"", tag.last == "\"",
              tag.dropFirst().dropLast().utf8.allSatisfy({ $0 == 0x21 || $0 >= 0x23 && $0 <= 0x7e }) else { return nil }
        return tag
    }

    static func fetchSnapshot(cfg: Config) throws -> (payload: LedgerPayload, eTag: String?) {
        let result = try request("GET", cfg.fileURL, cfg: cfg)
        guard result.code == 200, !result.data.isEmpty else {
            throw LedgerTransferError.badEnvelope("WebDAV 拉取失败: HTTP \(result.code)")
        }
        let data = try LedgerCrypto.open(result.data, passphrase: cfg.exportPass)
        return (try JSONDecoder().decode(LedgerPayload.self, from: data), validatedTag(result.eTag))
    }

    static func push(cfg: Config, ledger: Data, eTag: String?) throws -> (message: String, eTag: String?) {
        var result = try request("PUT", cfg.fileURL, cfg: cfg, body: ledger, eTag: eTag)
        if result.code == 409 {
            _ = try? request("MKCOL", cfg.directory, cfg: cfg)
            result = try request("PUT", cfg.fileURL, cfg: cfg, body: ledger, eTag: eTag)
        }
        if result.code == 412 {
            throw LedgerTransferError.badEnvelope("WebDAV 远端账本已存在或已更新。请先拉取并检查合并结果，再重新推送。服务端须提供强 ETag 才能更新已有快照。")
        }
        guard (200...299).contains(result.code) else {
            throw LedgerTransferError.badEnvelope("WebDAV 推送失败: HTTP \(result.code)")
        }
        return ("已推送加密账本到 WebDAV(\(ledger.count) 字节,服务端只见密文)", validatedTag(result.eTag))
    }
}
