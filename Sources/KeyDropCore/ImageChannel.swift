import Foundation

/// 生图渠道存储:url/key/默认模型,供 CLI 生图与 MCP server 使用
public struct ImageChannel: Codable {
    public var url: String
    public var key: String
    public var model: String
    public var keyMasked: String

    public init(url: String, key: String, model: String) {
        self.url = url
        self.key = key
        self.model = model
        // 短 key 也不能明文返回:masked 字段可能进展示/日志,≤8 位时用星号替代
        self.keyMasked = key.count > 8 ? String(key.prefix(6)) + "…" + String(key.suffix(4)) : String(repeating: "*", count: max(key.count, 6))
    }
}

public enum ImageChannelStore {
    public static var path: String {
        ProcessInfo.processInfo.environment["KEYDROP_IMAGE_CHANNEL"]
            ?? (NSHomeDirectory() + "/.keydrop/image-channel.json")
    }

    public static func load() -> ImageChannel? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? JSONDecoder().decode(ImageChannel.self, from: data)
    }

    public static func save(_ c: ImageChannel) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(c)
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        // 文件内容是明文 key,权限对齐 history.json(600)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }
}

/// MCP 配置写入:把生图工具注册到 claude / codex,命令 = 当前可执行文件 + mcp-image
public enum ImageMCPWriter {

    private static var claudeSettingsPath: String {
        ProcessInfo.processInfo.environment["KEYDROP_CLAUDE_SETTINGS"]
            ?? (NSHomeDirectory() + "/.claude/settings.json")
    }

    private static var codexConfigPath: String {
        ProcessInfo.processInfo.environment["KEYDROP_CODEX_CONFIG"]
            ?? (NSHomeDirectory() + "/.codex/config.toml")
    }

    /// 可执行命令(测试可用 KEYDROP_MCP_COMMAND 覆盖)
    public static func mcpCommand() -> [String] {
        if let raw = getenv("KEYDROP_MCP_COMMAND") {
            let override = String(cString: raw)
            if !override.isEmpty {
                return override.split(separator: " ").map(String.init)
            }
        }
        let exe = Bundle.main.executablePath ?? "/usr/local/bin/keydrop"
        return [exe, "mcp-image"]
    }

    /// 写入 claude settings.json mcpServers;返回是否已存在
    public static func writeClaude() throws -> Bool {
        let path = claudeSettingsPath
        var obj: [String: Any]
        if FileManager.default.fileExists(atPath: path) {
            // 文件存在但解析失败时拒绝写入,避免把用户既有配置清空
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw WriterError.file("\(path) 不是有效 JSON,为避免覆盖未修改")
            }
            obj = parsed
        } else {
            obj = [:]
        }
        var servers = (obj["mcpServers"] as? [String: Any]) ?? [:]
        if servers["keydrop-image"] != nil { return true }
        servers["keydrop-image"] = [
            "command": mcpCommand()[0],
            "args": Array(mcpCommand().dropFirst()),
        ]
        obj["mcpServers"] = servers
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        return false
    }

    /// 写入 codex config.toml [mcp_servers.keydrop-image];返回是否已存在
    public static func writeCodex() throws -> Bool {
        let path = codexConfigPath
        let cmd = mcpCommand()
        let quote = { (s: String) -> String in
            let q = "\""
            return q + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: q, with: "\\" + q) + q
        }
        let section = "\n[mcp_servers.keydrop-image]\ncommand = \(quote(cmd[0]))\nargs = [" + cmd.dropFirst().map(quote).joined(separator: ", ") + "]\n"
        let existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        if existing.contains("[mcp_servers.keydrop-image]") { return true }
        let out = existing + section
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try out.write(toFile: path, atomically: true, encoding: .utf8)
        return false
    }

    /// 全部写入;返回各目标是否已存在(未改动)
    public static func writeAll() throws -> [String: Bool] {
        var out: [String: Bool] = [:]
        out["claude"] = try writeClaude()
        out["codex"] = try writeCodex()
        out["opencode"] = try writeOpencode()
        return out
    }

    /// opencode: ~/.config/opencode/opencode.json 的 "mcp" 段
    public static func writeOpencode() throws -> Bool {
        let path = ProcessInfo.processInfo.environment["KEYDROP_OPENCODE_CONFIG"]
            ?? (NSHomeDirectory() + "/.config/opencode/opencode.json")
        var root: [String: Any]
        if FileManager.default.fileExists(atPath: path) {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw WriterError.file("\(path) 不是有效 JSON,为避免覆盖未修改")
            }
            root = obj
        } else {
            root = [:]
        }
        var mcp = root["mcp"] as? [String: Any] ?? [:]
        let existed = mcp["keydrop-image"] != nil
        mcp["keydrop-image"] = [
            "type": "local",
            "enabled": true,
            "command": mcpCommand(),
        ]
        root["mcp"] = mcp
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: path))
        return existed
    }
}