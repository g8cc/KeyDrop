import Foundation

final class ClashWriter {

    static var profilesDir: String {
        ProcessInfo.processInfo.environment["KEYDROP_CLASH_PROFILES"]
            ?? (NSHomeDirectory() + "/Library/Application Support/mihomo-party/profiles")
    }

    static func add(proxies: [ClashProxy]) throws -> String {
        let valid = proxies.filter { !$0.server.isEmpty && $0.port > 0 && $0.port <= 65535 && !$0.uuid.isEmpty }
        guard !valid.isEmpty else {
            throw WriterError.file("没有有效的代理节点可写入")
        }
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss"
        let name = "KeyDrop-\(df.string(from: Date()))"
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
              uuid: \(yamlQuote(p.uuid))
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
        return msg
    }

    private static func yamlScalar(_ s: String) -> String {
        if s.isEmpty { return "\"\"" }
        if s.range(of: #"^[\x21-\x7E]+$"#, options: .regularExpression) != nil,
           !s.hasPrefix("-"), !s.hasPrefix("?"), !s.hasPrefix(":"),
           !s.hasPrefix(" "), !s.contains(": ") {
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