import Foundation

final class ClashWriter {

    static var profilesDir: String {
        ProcessInfo.processInfo.environment["KEYDROP_CLASH_PROFILES"]
            ?? (NSHomeDirectory() + "/Library/Application Support/mihomo-party/profiles")
    }

    /// 写入订阅文件。返回 (展示消息, 生成的 yaml 文件名):
    /// 文件名入历史后,delete 才能自动清理生成的订阅文件
    static func add(proxies: [ClashProxy]) throws -> (message: String, fileName: String?) {
        let valid = proxies.filter { !$0.server.isEmpty && $0.port > 0 && $0.port <= 65535 && !$0.uuid.isEmpty }
        guard !valid.isEmpty else {
            throw WriterError.file("没有有效的代理节点可写入")
        }
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss"
        // 秒级时间戳在 CLI 与 app 同秒并发导入订阅时会生成同名文件、后者覆盖前者;
        // 加 4 位随机后缀保证唯一
        let name = "KeyDrop-\(df.string(from: Date()))-\(UUID().uuidString.prefix(4))"
        let path = (profilesDir as NSString).appendingPathComponent("\(name).yaml")

        let dir = URL(fileURLWithPath: profilesDir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var yaml = """
        port: 7890
        socks-port: 1080
        mode: Rule
        log-level: info
        ipv6: true
        mixed-port: 7892
        allow-lan: false

        proxyless: false

        dns:
          enable: true
          ipv6: false
          enhanced-mode: fake-ip
          fake-ip-range: 198.18.0.1/16
          nameserver:
            - 114.114.114.114
            - 8.8.8.8
          fallback: []

        proxies:
        """
        for p in valid {
            yaml += """
            \n  - name: \(yamlQuote(p.name))
              type: \(yamlScalar(p.type))
              server: \(yamlScalar(p.server))
              port: \(p.port)
            """
            yaml += credentialLine(for: p)
            yaml += """
              sni: \(yamlScalar(p.sni))
              skip-cert-verify: \(p.skipCertVerify)
              udp: \(p.udp)
            """
        }

        let names = valid.map { yamlQuote($0.name) }.joined(separator: ", ")
        yaml += """

        proxy-groups:
          - name: Proxy
            type: url-test
            proxies: [\(names)]
            url: "http://www.gstatic.com/generate_204"
            interval: 300

        rules:
          - MATCH,Proxy
        """

        let data = Data(yaml.utf8)
        let url = URL(fileURLWithPath: path)
        try data.write(to: url, options: .atomic)
        var msg = "已生成订阅文件: \(name).yaml(\(valid.count) 个节点)"
        if valid.count < proxies.count {
            msg += ", 跳过 \(proxies.count - valid.count) 个无效节点"
        }
        return (msg, "\(name).yaml")
    }

    /// 凭据字段名随协议不同:anytls/vless/vmess 用 uuid,trojan/hysteria2 用 password,
    /// ss 用 cipher+password。旧实现一律写 `uuid:`,导致 trojan/ss/hysteria2 节点
    /// 在 mihomo 里因缺 password 而加载失败(被静默丢弃)。
    private static func credentialLine(for p: ClashProxy) -> String {
        let t = p.type.lowercased()
        if t == "ss" {
            // ss://method:password → 拆出 cipher;不含冒号只能写 password(尽力而为)
            if let colon = p.uuid.firstIndex(of: ":") {
                let cipher = String(p.uuid[..<colon])
                let pass = String(p.uuid[p.uuid.index(after: colon)...])
                return "    cipher: \(yamlScalar(cipher))\n    password: \(yamlQuote(pass))\n"
            }
            return "    password: \(yamlQuote(p.uuid))\n"
        }
        if t == "trojan" || t == "hysteria2" || t == "hy2" {
            return "    password: \(yamlQuote(p.uuid))\n"
        }
        return "    uuid: \(yamlQuote(p.uuid))\n"
    }

    private static func yamlScalar(_ s: String) -> String {
        if s.isEmpty { return "\"\"" }
        // 裸写只对「确定无歧义」的安全标量开放。YAML 里以 # & * ! [ ] { } > | % @ ` 开头的
        // 值是注释/锚点/别名/flow 语法的一部分,裸写会让节点凭据被静默丢弃或解析错乱;
        // name 来自订阅文本,完全可能出现 "#1 香港" 这类值
        let unsafeStart: Set<Character> = ["#", "&", "*", "!", "[", "]", "{", "}", ">", "|", "%", "@", "`", "-", "?", ":", " ", ",", "'", "\""]
        if s.range(of: #"^[\x21-\x7E]+$"#, options: .regularExpression) != nil,
           !unsafeStart.contains(s.first!),
           !s.contains(": ") {
            return s
        }
        return yamlQuote(s)
    }

    private static func yamlQuote(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }
}