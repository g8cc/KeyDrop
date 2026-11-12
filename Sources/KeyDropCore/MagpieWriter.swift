import Foundation
import CryptoKit

/// Magpie(yetone/magpie)渠道同步:经其 Web 管理 API 创建/更新/删除 provider。
///
/// 鉴权:Magpie Web UI 用 `/?k=<webKey>` 换 Cookie(不是 Bearer);本 writer
/// 用独立 CookieStorage 完成登录后,后续请求自动携带。
/// 端点:GET /api/providers、POST /api/provider/save、POST /api/provider/delete。
/// payload 字段与 magpie internal/provider.Provider 的 json 标签一致:
/// name/key/chat/responses/anthropic/baseAPI/models(= 模型勾选)。
public enum MagpieWriter {

    public struct Config {
        public let baseURL: String
        public let webKey: String
    }

    /// 从用户粘贴的完整 Web 链接拆出 baseUrl 与 webKey:
    /// "http://127.0.0.1:3080/?k=abc" → (http://127.0.0.1:3080, abc)
    public static func parseWebLink(_ raw: String) -> Config? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        guard var wc = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let webKey = wc.queryItems?.first { $0.name == "k" }?.value ?? ""
        wc.queryItems = nil
        wc.fragment = nil
        guard let base = wc.url?.absoluteString else { return nil }
        let baseTrimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        if webKey.isEmpty { return nil }
        return Config(baseURL: baseTrimmed, webKey: webKey)
    }

    // MARK: - HTTP

    private static let sessionLock = NSLock()
    private static var sessions: [String: URLSession] = [:]
    /// 登录换到的 Cookie(按 base 缓存)。不用 HTTPCookieStorage:它对 IP 主机
    /// 的 Set-Cookie 处理有已知怪癖,手动捕获回传是确定性的
    private static var cookies: [String: String] = [:]

    private static func session(forBase base: String) -> URLSession {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        if let hit = sessions[base] { return hit }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 25
        let s = URLSession(configuration: cfg)
        sessions[base] = s
        return s
    }

    private static func login(config: Config) throws {
        var req = URLRequest(url: URL(string: "\(config.baseURL)/?k=\(config.webKey)")!)
        req.httpMethod = "GET"
        let o = NetSync.run(session: session(forBase: config.baseURL), request: req, timeout: 15)
        let status = NetSync.statusCode(o)
        guard status == 200 else {
            throw WriterError.file("Magpie 登录失败(HTTP \(status));请确认 Web 链接里的 key 未轮换")
        }
        // 手动捕获 Set-Cookie:后续请求显式回传(不依赖 CookieStorage 的 IP 主机怪癖)
        if let resp = o.response as? HTTPURLResponse,
           let sc = resp.allHeaderFields.first(where: { ($0.key as? String)?.lowercased() == "set-cookie" }) as? (String, String) {
            sessionLock.lock()
            cookies[config.baseURL] = sc.1
            sessionLock.unlock()
        }
    }

    private static func cookieHeader(forBase base: String) -> String? {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return cookies[base]
    }

    private static func requestJSON(config: Config, path: String, body: [String: Any]? = nil) throws -> Any {
        let s = session(forBase: config.baseURL)
        var req = URLRequest(url: URL(string: config.baseURL + path)!)
        req.httpMethod = body == nil ? "GET" : "POST"
        if let cookie = cookieHeader(forBase: config.baseURL) {
            req.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        let o = NetSync.run(session: s, request: req, timeout: 15)
        let status = NetSync.statusCode(o)
        guard status == 200 else {
            if status == 401 {
                throw WriterError.file("Magpie 未授权(401):Web key 失效或未登录,请更新设置里的 Web 链接")
            }
            let bodyText = String(data: o.data ?? Data(), encoding: .utf8) ?? ""
            throw WriterError.file("Magpie 请求失败(HTTP \(status))\(bodyText.isEmpty ? "" : ": \(bodyText.prefix(120))")")
        }
        guard let data = o.data, let obj = try? JSONSerialization.jsonObject(with: data) else {
            throw WriterError.file("Magpie 响应不是有效 JSON(\(path))")
        }
        return obj
    }

    // MARK: - Inventory

    private struct InventoryProvider {
        let id: String
        let name: String
    }

    private static func listProviders(config: Config) throws -> [InventoryProvider] {
        let obj = try requestJSON(config: config, path: "/api/providers")
        guard let dict = obj as? [String: Any], let arr = dict["providers"] as? [[String: Any]] else {
            throw WriterError.file("Magpie 响应缺 providers 列表")
        }
        return arr.compactMap { d in
            guard let id = d["id"] as? String, !id.isEmpty,
                  let name = d["name"] as? String else { return nil }
            return InventoryProvider(id: id, name: name)
        }
    }

    // MARK: - Sync / Remove

    /// 装饰名与 DSH 同风格:KeyDrop-<id8>-<host>
    public static func providerName(providerID: String, baseURL: String) -> String {
        let host = (URL(string: baseURL)?.host ?? "unknown").lowercased()
        return "KeyDrop-\(String(providerID.prefix(8)))-\(host)"
    }

    static func isOwnedName(_ name: String, providerID: String) -> Bool {
        name == providerName(providerID: providerID, baseURL: "") ||
        name.hasPrefix("KeyDrop-\(String(providerID.prefix(8)))-")
    }

    /// upsert 一个 provider:按 KeyDrop-<id8> 名字家族找既有行,update;没有则新建。
    /// 端点推导与 all-api-hub 的 channel-import 同语义:
    /// chat/responses = 带版本段挂载(<base>/v1),anthropic = 协议根(去版本段)
    public static func sync(providerID: String, baseURL: String, key: String,
                            models: [String]) throws -> String {
        guard let cfg = configured() else {
            throw WriterError.file("Magpie 未配置:设置里粘贴 Magpie Web 链接(托盘链接整条,含 ?k=)")
        }
        try login(config: cfg)
        let name = providerName(providerID: providerID, baseURL: baseURL)
        let existing = try listProviders(config: cfg).first { isOwnedName($0.name, providerID: providerID) }

        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let versioned = trimmed.range(of: "/v[0-9]+(beta[0-9]*)?$", options: .regularExpression) != nil
            ? trimmed : trimmed + "/v1"
        var root = trimmed
        if let r = root.range(of: "/v[0-9]+(beta[0-9]*)?$", options: .regularExpression) {
            root = String(root[..<r.lowerBound])
        }
        var payload: [String: Any] = [
            "id": existing?.id ?? "keydrop-\(String(providerID.prefix(8)))",
            "name": name,
            "chat": versioned,
            "responses": versioned,
            "anthropic": root,
            "baseAPI": "chat",
            "key": key,
            "keyName": "KeyDrop",
            "keyProtocol": "openai-compatible",
            "models": models,
        ]
        if existing != nil {
            payload.removeValue(forKey: "keyName")
            payload.removeValue(forKey: "keyProtocol")
        }
        let obj = try requestJSON(config: cfg, path: "/api/provider/save", body: payload)
        guard let dict = obj as? [String: Any],
              let providers = dict["providers"] as? [[String: Any]],
              providers.contains(where: { $0["id"] as? String == payload["id"] as? String }) else {
            throw WriterError.file("Magpie 写入未确认(响应无该 provider),请检查 Magpie 界面")
        }
        return "已\(existing != nil ? "更新" : "新建") provider「\(name)」(\(models.count) 个模型)"
    }

    /// 删除本 provider 的 Magpie 行(按名字家族找),找不到返回空串
    public static func remove(providerID: String) throws -> String {
        guard let cfg = configured() else { return "" }
        try login(config: cfg)
        guard let target = try listProviders(config: cfg)
            .first(where: { isOwnedName($0.name, providerID: providerID) }) else { return "" }
        _ = try requestJSON(config: cfg, path: "/api/provider/delete", body: ["id": target.id])
        return "已移除「\(target.name)」"
    }

    /// prefs.magpieWebLink → Config;未配置/非法返回 nil
    public static func configured() -> Config? {
        let link = Prefs.shared.magpieWebLink ?? ""
        guard !link.isEmpty else { return nil }
        return parseWebLink(link)
    }
}
