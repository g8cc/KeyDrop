import Foundation

public struct ClashProxy: Codable {
    public var name: String
    public var type: String = "anytls"
    public var server: String
    public var port: Int
    public var uuid: String
    public var sni: String
    public var skipCertVerify: Bool = true
    public var udp: Bool = true
    public init(name: String, type: String = "anytls", server: String, port: Int, uuid: String, sni: String) {
        self.name = name
        self.type = type
        self.server = server
        self.port = port
        self.uuid = uuid
        self.sni = sni
    }
}

public enum Parser {

    private struct Cand { let value: String; let lhs: String? }

    public static func parse(_ raw: String, depth: Int = 0) throws -> ParsedKey {
        let text = stripPasteNoise(normalizeFullWidth(raw)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ParseError.emptyInput }

        if depth < 3, !text.contains("\n") {
            let expanded = NSString(string: text).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) {
                return try parseFile(at: expanded, depth: depth)
            }
        }

        if depth < 3, isPureBase64(text), let data = base64DecodeLoose(text) {
            if data.count > 4, data[0] == 0x50, data[1] == 0x4B {
                return try parseZipData(data, depth: depth)
            }
            if let inner = String(data: data, encoding: .utf8) {
                if var r = try? parse(inner, depth: depth + 1) {
                    r.format = "base64>" + r.format
                    return r
                }
            }
        }

        return try parsePlain(text)
    }

    public static func parseWithFallback(_ raw: String) throws -> ParsedKey {
        let parsed: ParsedKey
        do {
            parsed = try parse(raw)
        } catch let ruleError {
            if let llm = LLMParser.extract(from: raw),
               let key = llm.key {
                var p = ParsedKey()
                p.key = key
                p.url = llm.url
                p.model = llm.model
                p.name = llm.name
                p.format = "llm"
                return p
            }
            throw ruleError
        }
        let suspicious = (parsed.model?.count ?? 0) > 50
            || (parsed.model?.contains("http") == true)
            || (parsed.name?.count ?? 0) < 3
        if suspicious, let llm = LLMParser.extract(from: raw),
           let key = llm.key, key != parsed.key {
            var p = ParsedKey()
            p.key = key
            p.url = llm.url ?? parsed.url
            p.model = llm.model ?? parsed.model
            p.name = llm.name ?? parsed.name
            p.format = "llm>" + parsed.format
            return p
        }
        return parsed
    }

    public static func extractAllKeys(_ raw: String) -> [String] {
        let tokens = raw.split(whereSeparator: { $0.isNewline || $0 == " " || $0 == "\t" })
            .map(String.init)
            .filter { !$0.isEmpty }
        var keys: [String] = []
        var seen = Set<String>()
        for t in tokens {
            if t.hasPrefix("cwk-") || t.hasPrefix("sk-") || t.hasPrefix("ak-") || t.hasPrefix("pk-") {
                let clean = t.trimmingCharacters(in: .whitespaces)
                if clean.count >= 16, clean.count <= 256, !seen.contains(clean) {
                    keys.append(clean)
                    seen.insert(clean)
                }
            }
        }
        return keys
    }

    static func parseFile(at path: String, depth: Int = 0) throws -> ParsedKey {
        let lower = path.lowercased()
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        if isDir.boolValue {
            throw ParseError.io("不支持直接解析目录: \(path)。请拖入具体文件或 zip 文件。")
        }
        if lower.hasSuffix(".zip") {
            return try parseZipFile(path, depth: depth)
        }
        guard FileManager.default.fileExists(atPath: path) else {
            throw ParseError.io("文件不存在: \(path)")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        if data.count > 4, data[0] == 0x50, data[1] == 0x4B {
            return try parseZipData(data, depth: depth)
        }
        guard let s = String(data: data, encoding: .utf8) else {
            throw ParseError.io("无法读取文件(非 UTF-8): \(path)")
        }
        var r = try parse(s, depth: depth + 1)
        r.format = "file>" + r.format
        r.sourceFile = path
        return r
    }

    // MARK: - plain text / json / multiline

    static func parsePlain(_ text: String) throws -> ParsedKey {
        let trimmed = normalizeQuotes(text).trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("["),
           let data = trimmed.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) {
            var p = ParsedKey()
            extractJSON(obj, into: &p)
            if p.key != nil {
                p.format = "json"
                applyOfficialURLFallback(&p, raw: text)
                return p
            }
        }
        var p = try parseMultiline(trimmed)
        applyOfficialURLFallback(&p, raw: text)
        return p
    }

    // MARK: - 官方站点 fallback

    /// 无 URL 时按名称/文本匹配官方提供商 base URL
    static let officialBaseURLs: [(pattern: String, url: String)] = [
        ("deepseek", "https://api.deepseek.com"),
        ("moonshot|kimi", "https://api.moonshot.cn/v1"),
        ("dashscope|qwen|通义", "https://dashscope.aliyuncs.com/compatible-mode/v1"),
        ("zhipu|glm|bigmodel", "https://open.bigmodel.cn/api/paas/v4"),
        ("openai|chatgpt", "https://api.openai.com/v1"),
        ("anthropic|claude", "https://api.anthropic.com"),
        ("gemini|generativelanguage|gemini官方", "https://generativelanguage.googleapis.com/v1beta/openai/"),
        ("groq", "https://api.groq.com/openai/v1"),
        ("mistral", "https://api.mistral.ai/v1"),
        ("volcengine|火山|ark", "https://ark.cn-beijing.volces.com/api/v3"),
        ("siliconflow|硅基流动", "https://api.siliconflow.cn/v1"),
        ("openrouter", "https://openrouter.ai/api/v1"),
        ("together", "https://api.together.xyz/v1"),
        ("fireworks", "https://api.fireworks.ai/inference/v1"),
        ("stepfun|阶跃", "https://api.stepfun.com/v1"),
        ("minimax|海螺", "https://api.minimaxi.com/v1"),
        ("讯飞|xfyun|spark", "https://spark-api-open.xf-yun.com/v1")
    ]

    public static func applyOfficialURLFallback(_ p: inout ParsedKey, raw: String) {
        guard p.url == nil else { return }
        let haystack = ((p.name ?? "") + " " + raw).lowercased()
        for item in officialBaseURLs where haystack.range(of: item.pattern, options: .regularExpression) != nil {
            p.url = item.url
            return
        }
    }

    static func normalizeQuotes(_ s: String) -> String {
        s.replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")
            .replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "：", with: ":")
            .replacingOccurrences(of: "，", with: ",")
    }

    static func parseMultiline(_ text: String) throws -> ParsedKey {
        if text.hasPrefix("curl") {
            if let r = parseCurl(text) { return r }
        }
        let separator = separatorInstruction(text)
        let lines = text.split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "---" && !isInstructionLine(String($0)) }

        guard !lines.isEmpty else { throw ParseError.emptyInput }

        var cands: [Cand] = []

        if lines.count == 1 {
            let tokens = lines[0]
                .components(separatedBy: CharacterSet(charactersIn: " \t,;"))
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let hasAssignment = lines[0].range(of: #"(?:^|[\s,;])[A-Za-z_][A-Za-z0-9_.-]{0,59}\s*="#, options: .regularExpression) != nil
            let hasLabeledColon = lines[0].range(
                of: #"(?:^|[\s,;])[^:]{1,60}\s*:(?!/)"#,
                options: .regularExpression
            ) != nil && !lines[0].hasPrefix("http://") && !lines[0].hasPrefix("https://")

            if hasAssignment {
                var inline: [Cand] = []
                for token in tokens {
                    guard let eq = token.firstIndex(of: "=") else {
                        inline.append(Cand(value: token, lhs: nil))
                        continue
                    }
                    let lhs = String(token[..<eq]).trimmingCharacters(in: .whitespaces)
                    let value = String(token[token.index(after: eq)...])
                    if !lhs.isEmpty && !value.isEmpty {
                        inline.append(Cand(value: stripQuotes(value), lhs: lhs.lowercased()))
                    }
                }
                if !inline.isEmpty { return try classify(inline, separator: separator) }
            } else if tokens.count > 1 && !hasLabeledColon {
                for t in tokens { cands.append(Cand(value: t, lhs: nil)) }
                return try classify(cands, separator: separator)
            }
        }

        for l in lines {
            var line = l.hasPrefix("export ") ? String(l.dropFirst(7)) : l
            line = stripInlineComment(line).trimmingCharacters(in: .whitespaces)
            var lhs: String? = nil
            var eq: String.Index? = nil
            if let e = line.firstIndex(of: "="), line.distance(from: line.startIndex, to: e) < 60 {
                let after = String(line[line.index(after: e)...]).trimmingCharacters(in: .whitespaces)
                let hasColon = line.firstIndex(of: ":") != nil
                if !after.isEmpty || !hasColon {
                    eq = e
                }
            }
            if let eq {
                lhs = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
                line = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            } else if let ci = line.firstIndex(of: ":") {
                let pre = String(line[line.startIndex..<ci])
                if pre.count < 60, !pre.contains("http"), !pre.contains(" ") {
                    lhs = pre.trimmingCharacters(in: .whitespaces)
                    line = String(line[line.index(after: ci)...]).trimmingCharacters(in: .whitespaces)
                } else {
                    let tokens = line.components(separatedBy: CharacterSet.whitespaces)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    for t in tokens {
                        let cleaned = stripCJK(t)
                        if looksLikeURL(cleaned) { cands.append(Cand(value: cleaned, lhs: nil)) }
                        else { cands.append(Cand(value: stripQuotes(t), lhs: nil)) }
                    }
                    continue
                }
            }
            line = stripQuotes(line.trimmingCharacters(in: CharacterSet(charactersIn: ",;")))
            if line.isEmpty { continue }
            cands.append(Cand(value: line, lhs: lhs?.lowercased()))
        }
        return try classify(cands, separator: separator)
    }

    // MARK: - 分隔符打码 key 重组

    /// 识别「去除 X 即可」类指令,返回分隔符 X(如 :diamond_suit: 或 emoji)
    private static func separatorInstruction(_ text: String) -> String? {
        let re = try! NSRegularExpression(pattern: #"(?:去除|去掉|删除|移除)\s*[:：]?\s*(.+?)\s*(?:即可|就可以|使用|,|，|。|$)"#)
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let r = m.range(at: 1)
        guard r.location != NSNotFound else { return nil }
        let s = ns.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    private static func isInstructionLine(_ line: String) -> Bool {
        line.range(of: #"(?:去除|去掉|删除|移除).*?(?:即可|就可以)"#, options: .regularExpression) != nil
    }

    /// key 行重组:剥字段标签 → 去分隔符 → 过滤非 key 字符(emoji/标点) → 校验
    private static func extractKey(_ t: String, _ sep: String?) -> String? {
        var s = stripCJK(t).trimmingCharacters(in: .whitespacesAndNewlines)
        var hadLabel = false
        if let r = s.range(of: #"^(?:key|api[-_]?key|token|secret|auth)(?:\s*[:=]\s*|\s+)"#, options: [.regularExpression, .caseInsensitive]) {
            s = String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            hadLabel = true
        }
        if let sep, !sep.isEmpty {
            let cleaned = s.replacingOccurrences(of: sep, with: "")
            if looksLikeKey(cleaned) { return cleaned }
        }
        let filtered = s.filter { $0.isASCII && ($0.isLetter || $0.isNumber || "+-/_.=".contains($0)) }
        if filtered != s, looksLikeKey(filtered) { return filtered }
        if looksLikeKey(s) { return s }
        // 带 key 标签的短 token(如 keyhub 的 APIKEY linuxdo):无空格非 URL 即可
        if hadLabel, !s.isEmpty, !s.contains(" "), !s.contains("\t"),
           s.range(of: #"^[\x21-\x7E]+$"#, options: .regularExpression) != nil,
           !looksLikeURL(s) {
            return s
        }
        return nil
    }

    // MARK: - curl

    private static func shellTokenize(_ s: String) -> [String] {
        var tokens: [String] = []
        var cur = ""
        var quote: Character? = nil
        var escaped = false
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if escaped {
                cur.append(ch)
                escaped = false
                i += 1
                continue
            }
            if ch == "\\" {
                if i + 1 < chars.count, chars[i + 1] == "\n" {
                    i += 2
                    continue
                }
                escaped = true
                i += 1
                continue
            }
            if let q = quote {
                if ch == q {
                    quote = nil
                } else if ch == "\\", q == "\"" {
                    escaped = true
                } else {
                    cur.append(ch)
                }
                i += 1
                continue
            }
            if ch == "\"" || ch == "'" {
                quote = ch
                i += 1
                continue
            }
            if ch.isWhitespace {
                if !cur.isEmpty {
                    tokens.append(cur)
                    cur = ""
                }
                i += 1
                continue
            }
            cur.append(ch)
            i += 1
        }
        if !cur.isEmpty { tokens.append(cur) }
        return tokens
    }

    static func parseCurl(_ raw: String) -> ParsedKey? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("curl ") || trimmed.hasPrefix("curl\t") || trimmed == "curl" else { return nil }
        let tokens = shellTokenize(trimmed)
        guard tokens.count >= 2, tokens[0] == "curl" else { return nil }

        var url: String? = nil
        var key: String? = nil
        var model: String? = nil

        func takeKey(_ k: String) {
            guard key == nil else { return }
            if looksLikeKey(k) {
                key = k
            } else if let d = decodeKeyIfBase64(k), looksLikeKey(d) {
                key = d
            }
        }

        var i = 1
        while i < tokens.count {
            let t = tokens[i]
            switch t {
            case "-H", "--header":
                if i + 1 < tokens.count {
                    i += 1
                    let h = tokens[i]
                    if let c = h.firstIndex(of: ":") {
                        let hn = String(h[..<c]).trimmingCharacters(in: .whitespaces).lowercased()
                        let hv = String(h[h.index(after: c)...]).trimmingCharacters(in: .whitespaces)
                        if hn == "authorization" {
                            if hv.lowercased().hasPrefix("bearer ") {
                                takeKey(String(hv.dropFirst(7)).trimmingCharacters(in: .whitespaces))
                            } else {
                                takeKey(hv)
                            }
                        } else if hn.contains("key") || hn.contains("token") {
                            takeKey(hv)
                        }
                    }
                }
            case "-d", "--data", "--data-raw", "--data-binary", "--data-ascii", "--data-urlencode":
                if i + 1 < tokens.count {
                    i += 1
                    let body = tokens[i]
                    if let data = body.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        if model == nil, let m = obj["model"] as? String, !m.isEmpty {
                            model = m
                        }
                        for fk in ["api_key", "apikey", "api-key", "key", "token", "auth_token"] {
                            if key == nil, let k = obj[fk] as? String { takeKey(k) }
                        }
                    }
                }
            case "-u", "--user":
                if i + 1 < tokens.count {
                    i += 1
                    if let c = tokens[i].firstIndex(of: ":") {
                        takeKey(String(tokens[i][tokens[i].index(after: c)...]))
                    }
                }
            case "--url":
                if i + 1 < tokens.count {
                    i += 1
                    if url == nil, let u = normalizeURL(tokens[i]) { url = u }
                }
            case "-X", "--request", "-o", "--output", "--output-file":
                i += 1
            default:
                if t.hasPrefix("-") { break }
                if url == nil, let u = normalizeURL(t) {
                    url = u
                } else {
                    takeKey(t)
                }
            }
            i += 1
        }

        if let u = url, let comp = URLComponents(string: u) {
            for item in comp.queryItems ?? [] {
                let n = item.name.lowercased()
                if model == nil, n == "model", let v = item.value, !v.isEmpty {
                    model = v
                }
                if key == nil, ["api_key", "apikey", "key", "token"].contains(n), let v = item.value {
                    takeKey(v)
                }
            }
        }

        guard let k = key else { return nil }
        var p = ParsedKey()
        p.key = k
        p.url = url
        p.model = model
        p.format = "curl"
        return p
    }

    private static func stripInlineComment(_ s: String) -> String {
        var quoted: Character? = nil
        var escaped = false
        for i in s.indices {
            let ch = s[i]
            if escaped {
                escaped = false
                continue
            }
            if ch == "\\" && quoted != nil {
                escaped = true
                continue
            }
            if ch == "\"" || ch == "'" {
                if quoted == ch { quoted = nil }
                else if quoted == nil { quoted = ch }
                continue
            }
            if ch == "#", quoted == nil {
                let before = i > s.startIndex ? s[s.index(before: i)] : " "
                if before.isWhitespace { return String(s[..<i]) }
            }
        }
        return s
    }

    private static func stripQuotes(_ s: String) -> String {
        if s.count >= 2,
           (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) {
            return String(s.dropFirst().dropLast())
        }
        return s
    }

    /// base16/hex 编码 key(如 736b2d… = "sk-…"):纯 hex、偶数长度、解码为 ASCII key
    static func decodeKeyIfHex(_ t: String) -> String? {
        let cleaned = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count >= 32, cleaned.count % 2 == 0,
              cleaned.range(of: #"^[0-9a-fA-F]+$"#, options: .regularExpression) != nil
        else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(cleaned.count / 2)
        var it = cleaned.makeIterator()
        while let hi = it.next(), let lo = it.next() {
            guard let h = UInt8(String(hi), radix: 16), let l = UInt8(String(lo), radix: 16) else { return nil }
            bytes.append(h << 4 | l)
        }
        guard let inner = String(bytes: bytes, encoding: .utf8) else { return nil }
        let stripped = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty, isRealKey(stripped) else { return nil }
        return stripped
    }

    static func decodeKeyIfBase64(_ t: String, depth: Int = 0) -> String? {
        guard depth < 3 else { return nil }
        let cleaned = stripCJK(t)
        if let hex = decodeKeyIfHex(cleaned) { return hex }
        guard let match = cleaned.range(of: #"[A-Za-z0-9+/_-]{16,}={0,2}"#, options: .regularExpression),
              match.lowerBound == cleaned.startIndex || cleaned[..<match.lowerBound].allSatisfy({ !$0.isASCII || $0 == "(" || $0 == ")" || $0 == "," || $0 == ";" })
        else { return nil }
        let clean = String(cleaned[match])
        guard isPureBase64(clean),
              let data = base64DecodeLoose(clean),
              let inner = String(data: data, encoding: .utf8)
        else { return nil }
        let trimmed = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = stripCJK(trimmed)
        if !stripped.isEmpty, stripped.count < clean.count, isRealKey(stripped) {
            return stripped
        }
        if stripped.count < clean.count, isPureBase64(stripped) {
            return decodeKeyIfBase64(stripped, depth: depth + 1)
        }
        return nil
    }

    private static func isRealKey(_ s: String) -> Bool {
        guard s.count >= 16, s.count <= 256 else { return false }
        guard s.range(of: #"^[\x21-\x7E]+$"#, options: .regularExpression) != nil else { return false }
        if s.contains(":") { return false }
        if s.range(of: #"^(sk|ak|key|pk|cr|sp|dk|bk|rk|fk|tk|xk|wk|zk|gk|vk|nk|mk|hk|csk|gsk|sk-or|sk-ant|sk_tr|cfut|nvapi|ms)[-_]"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        if s.count >= 28, s.range(of: #"^[A-Za-z0-9_\-./=]+$"#, options: .regularExpression) != nil {
            if s.range(of: #"^[A-Za-z0-9+/]{10,}={0,2}$"#, options: .regularExpression) != nil { return false }
            return true
        }
        return false
    }

    private static func classify(_ cands: [Cand], separator: String? = nil) throws -> ParsedKey {
        var urls: [String] = []
        var keys: [String] = []
        var rest: [(String, String?)] = []

        for c in cands {
            let t = c.value
            if let lhs = c.lhs {
                if lhs.contains("url") || lhs.contains("endpoint") || lhs.contains("host") {
                    if let url = normalizeURL(t) { urls.append(url); continue }
                }
                if lhs.contains("key") || lhs.contains("token") || lhs.contains("secret") {
                    if let decoded = decodeKeyIfBase64(t) { keys.append(decoded); continue }
                    if let k = extractKey(t, separator) { keys.append(k); continue }
                    // 标签行(keyhub 式 APIKEY: xxx)短 token 也接受
                    let bare = t.trimmingCharacters(in: .whitespaces)
                    if !bare.isEmpty, !bare.contains(" "), !bare.contains("\t"),
                       bare.range(of: #"^[\x21-\x7E]+$"#, options: .regularExpression) != nil,
                       !looksLikeURL(bare), !looksLikeModel(bare) {
                        keys.append(bare)
                        continue
                    }
                }
            }
            if looksLikeURL(t), let u = normalizeURL(t) { urls.append(u) }
            else if let decoded = decodeKeyIfBase64(t) { keys.append(decoded) }
            else if let k = extractKey(t, separator) { keys.append(k) }
            else { rest.append((t, c.lhs)) }
        }

        guard let key = keys.first else {
            throw ParseError.noKeyFound("识别到 \(cands.count) 行文本但无 key 特征(sk-*/ak-*/长令牌/KEY=值)。")
        }

        var p = ParsedKey()
        p.key = applySuffixInstructions(key, rest: rest)
        p.url = urls.first
        p.format = cands.count > 1 ? "multiline" : "single"

        if keys.count == 1 {
            let vals = rest.map { $0.0 }
            if let m = rest.first(where: { ($0.1 ?? "").contains("model") || ($0.1 ?? "").contains("模型") }) {
                p.model = m.0
            }
            let modelCands = vals.filter { looksLikeModel($0) }
            if p.model == nil { p.model = modelCands.first }
            var extraModels: [String] = []
            if modelCands.isEmpty {
                for v in vals { extraModels.append(contentsOf: modelTokens(from: v)) }
            }
            p.models = (modelCands.isEmpty ? (extraModels.isEmpty ? nil : extraModels) : modelCands)
            if p.model == nil { p.model = extraModels.first }
            if let n = rest.first(where: {
                let l = $0.1 ?? ""
                return l.contains("name") || l.contains("provider") || l.contains("名称") || l.contains("名字")
            }) {
                p.name = n.0
            } else {
                let nameCands = vals.filter { isNameLike($0) && !modelCands.contains($0) && !extraModels.contains($0) }
                if let n = nameCands.first {
                    p.name = n
                }
            }
            if vals.count == 1, p.model == nil {
                if looksLikeModel(vals[0]) { p.model = vals[0] }
                else if isNameLike(vals[0]) { p.name = p.name ?? vals[0] }
            } else if vals.count == 2, p.model == nil {
                if isNameLike(vals[0]) { p.name = vals[0] }
                if isNameLike(vals[1]) { p.model = vals[1] }
                if looksLikeModel(vals[0]) && !looksLikeModel(vals[1]) {
                    p.name = vals[1]; p.model = vals[0]
                }
            }
        }
        return p
    }

    /// 从噪音行提取模型名(如 "500rmb的余额,DeepSeek-V4-Flash-0731和DeepSeek-V4-Pro-0813")
    private static func modelTokens(from s: String) -> [String] {
        let withSeqs = s
            .replacingOccurrences(of: "和", with: ",")
            .replacingOccurrences(of: "及", with: ",")
            .replacingOccurrences(of: "与", with: ",")
            .replacingOccurrences(of: "或", with: ",")
        let tokens = withSeqs.components(separatedBy: CharacterSet(charactersIn: ",，、; "))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let cleaned = stripCJK(withSeqs)
        let cleanedTokens = cleaned.components(separatedBy: CharacterSet(charactersIn: ",，、; "))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var out: [String] = []
        for (i, t) in cleanedTokens.enumerated() {
            // 原 token 含中文 → 名称/描述(如 "deepseek官方api"→"deepseekapi"),非模型
            let origHasCJK = i < tokens.count && tokens[i].unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
            if origHasCJK { continue }
            if looksLikeModel(t) {
                let l = t.lowercased()
                if l.range(of: #"(claude|gpt|gemini|glm|kimi|qwen|deepseek|grok|opus|sonnet|haiku|mistral|llama|minimax|mimo|longcat|codex)"#, options: .regularExpression) != nil
                    || l.range(of: #"v\d"#, options: .regularExpression) != nil {
                    out.append(t)
                }
            }
        }
        return out
    }

    private static func applySuffixInstructions(_ key: String, rest: [(String, String?)]) -> String {
        var result = key
        for (line, _) in rest {
            if line.contains("去掉后缀") || line.contains("去掉尾巴") || line.contains("去掉") || line.contains("删除后缀") || line.contains("移除后缀") || line.contains("去掉尾缀") {
                if let r = line.range(of: #"(?:去掉|删除|移除)(?:后缀|尾巴|尾缀)?[_:：]?\s*([A-Za-z0-9_\-]+)"#, options: .regularExpression),
                   let match = line[r].range(of: #"[A-Za-z0-9_\-]+$"#, options: .regularExpression) {
                    let suffix = String(line[match])
                    let cands = [suffix, "_" + suffix]
                    for c in cands where result.hasSuffix(c) {
                        result = String(result.dropLast(c.count))
                        break
                    }
                }
            }
        }
        return result
    }

    private static func isNameLike(_ s: String) -> Bool {
        let noise: [Character] = [",", ".", ";", "、", ":", "|", "$", "！", "？", "!", "?"]
        let l = s.lowercased()
        // keyhub 类说明行(如 动态RPM/静态RPM/请求速率)不是名字
        if l.contains("rpm") || l.contains("限流") || l.contains("额度") || l.contains("余额") {
            return false
        }
        return s.count >= 2 && s.count <= 40
            && !s.contains(where: { noise.contains($0) })
            && !s.contains(where: { $0.isWhitespace })
            && !looksLikeURL(s)
            && !looksLikeKey(s)
            && !looksLikeModel(s)
    }

    // MARK: - JSON extraction

    static let keyFieldPriority = ["anthropic_auth_token", "anthropic_api_key", "api_key", "apikey", "api-key", "auth_token", "access_token", "token", "secret", "key"]
    static let urlFieldPriority = ["anthropic_base_url", "base_url", "baseurl", "base-url", "endpoint", "anthropic_api_url", "url"]
    static let modelFieldPriority = ["anthropic_model", "model", "default_model", "claude_model"]
    static let nameFieldPriority = ["provider_name", "provider", "name", "label", "title"]

    static func extractJSON(_ obj: Any, into p: inout ParsedKey) {
        var keyCandidates: [(Int, String)] = []
        var urlCandidates: [(Int, String)] = []
        var modelCandidates: [(Int, String)] = []
        var nameCandidates: [(Int, String)] = []
        collectJSON(obj, keyC: &keyCandidates, urlC: &urlCandidates, modelC: &modelCandidates, nameC: &nameCandidates)

        if p.key == nil, let best = keyCandidates.min(by: { $0.0 < $1.0 }) {
            var k = stripCJK(best.1)
            if let d = decodeKeyIfBase64(k), looksLikeKey(d) { k = d }
            p.key = k
        }
        if p.url == nil, let best = urlCandidates.min(by: { $0.0 < $1.0 }) { p.url = best.1 }
        if p.model == nil, let best = modelCandidates.min(by: { $0.0 < $1.0 }) { p.model = best.1 }
        if p.name == nil, let best = nameCandidates.min(by: { $0.0 < $1.0 }) { p.name = best.1 }
    }

    private static func collectJSON(_ v: Any, keyC: inout [(Int, String)], urlC: inout [(Int, String)], modelC: inout [(Int, String)], nameC: inout [(Int, String)]) {
        if let d = v as? [String: Any] {
            for (k, val) in d {
                let kl = k.lowercased()
                if let s = val as? String, !s.isEmpty {
                    if let i = keyFieldPriority.firstIndex(of: kl), looksLikeKey(s) { keyC.append((i, s)) }
                    else if kl == "apikey" || kl == "sk", looksLikeKey(s) { keyC.append((9, s)) }
                    if let i = urlFieldPriority.firstIndex(of: kl), let url = normalizeURL(s) { urlC.append((i, url)) }
                    if let i = modelFieldPriority.firstIndex(of: kl), s.count < 80, !s.contains("\n") { modelC.append((i, s)) }
                    if let i = nameFieldPriority.firstIndex(of: kl), s.count < 50, !s.contains("\n"), !looksLikeURL(s) { nameC.append((i, s)) }
                } else {
                    collectJSON(val, keyC: &keyC, urlC: &urlC, modelC: &modelC, nameC: &nameC)
                }
            }
        } else if let arr = v as? [Any] {
            for e in arr { collectJSON(e, keyC: &keyC, urlC: &urlC, modelC: &modelC, nameC: &nameC) }
        }
    }

    // MARK: - zip

    static func parseZipData(_ data: Data, depth: Int = 0) throws -> ParsedKey {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("keydrop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let zipFile = tmp.appendingPathComponent("input.zip")
        try data.write(to: zipFile)
        return try parseZipFile(zipFile.path, depth: depth)
    }

    static func parseZipFile(_ path: String, depth: Int = 0) throws -> ParsedKey {
        let outDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keydrop-x-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outDir) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-o", "-q", "-j", path, "-d", outDir.path]
        let errPipe = Pipe()
        proc.standardError = errPipe
        try proc.run()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let errText = String(data: errData, encoding: .utf8) ?? ""
            throw ParseError.io("zip 解压失败: \(errText.prefix(200))")
        }

        var files: [(URL, Int)] = []
        if let en = FileManager.default.enumerator(at: outDir, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let url as URL in en {
                let p = url.path
                if p.contains("__MACOSX") || p.contains("node_modules") { continue }
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values?.isSymbolicLink != true else { continue }
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir), !isDir.boolValue else { continue }
                let size = ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                if size > 1_500_000 { continue }
                files.append((url, priority(ext: url.pathExtension.lowercased())))
            }
        }
        files.sort { $0.1 < $1.1 }

        var best: ParsedKey? = nil
        var urlBorrow: String? = nil
        for (url, _) in files {
            guard let data = try? Data(contentsOf: url),
                  let s = String(data: data, encoding: .utf8) else { continue }
            if let r = try? parse(s, depth: depth + 1) {
                if r.key != nil, best == nil || r.score > best!.score { best = r; best?.sourceFile = url.lastPathComponent }
                if r.url != nil, urlBorrow == nil { urlBorrow = r.url }
            }
        }
        guard var found = best else {
            throw ParseError.noKeyFound("zip 内扫描了 \(files.count) 个文件,未找到 key。")
        }
        if found.url == nil, let u = urlBorrow { found.url = u }
        found.format = "zip>" + found.format
        return found
    }

    private static func priority(ext e: String) -> Int {
        switch e {
        case "json": return 0
        case "env": return 1
        case "txt": return 2
        case "toml", "yaml", "yml", "conf", "ini": return 3
        case "md": return 4
        default: return 9
        }
    }

    // MARK: - heuristics

    static public func stripPasteNoise(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "`", with: "")
        t = t.replacingOccurrences(of: #"^```[A-Za-z0-9]*\s*\n"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\n```[A-Za-z0-9]*\s*$"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\n```[A-Za-z0-9]*\s*\n"#, with: "\n", options: .regularExpression)
        let lines = t.components(separatedBy: "\n")
        return lines.map { line -> String in
            var l = line
            l = l.replacingOccurrences(of: #"^\s*(?:•|·|◦|\*)\s+"#, with: "", options: .regularExpression)
            l = l.replacingOccurrences(of: #"^\s*-\s+"#, with: "", options: .regularExpression)
            l = l.replacingOccurrences(of: #"^\s*\d+[,.]\s*"#, with: "", options: .regularExpression)
            return l
        }.joined(separator: "\n")
    }

    static public func normalizeFullWidth(_ s: String) -> String {
        let map: [Character: Character] = [
            "：": ":", "（": "(", "）": ")",
            "，": ",", "、": ",", "；": ";",
            "　": " ", "＝": "=", "。": "."
        ]
        return String(s.map { map[$0] ?? $0 })
    }

    static func stripCJK(_ s: String) -> String {
        String(s.unicodeScalars.filter {
            !(0x3400...0x9FFF).contains($0.value) && !(0xF900...0xFAFF).contains($0.value)
        })
    }

    static func isPureBase64(_ s: String) -> Bool {
        let compact = s.filter { !$0.isWhitespace }
        guard compact.count >= 16 else { return false }
        return compact.range(of: #"^[A-Za-z0-9+/_-]+={0,2}$"#, options: .regularExpression) != nil
    }

    static func base64DecodeLoose(_ s: String) -> Data? {
        var t = s.filter { !$0.isWhitespace }
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t, options: [.ignoreUnknownCharacters])
    }

    static func looksLikeURL(_ s: String) -> Bool {
        let l = stripCJK(s).lowercased()
        guard !l.contains(where: { $0.isWhitespace }) else { return false }
        if l.hasPrefix("https://") || l.hasPrefix("http://") {
            return URL(string: l)?.host?.isEmpty == false
        }
        // 裸域名(如 s.0v0.club):无协议、形如 hostname 且至少一个点
        guard l.range(of: #"^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$"#, options: .regularExpression) != nil,
              !l.contains(".."),
              l.range(of: #"^(?:gpt|claude|gemini|glm|kimi|qwen|deepseek|grok|opus|sonnet|haiku|mistral|llama|minimax|mimo|longcat|codex|o[134])-"#, options: .regularExpression) == nil
        else { return false }
        return URL(string: "https://" + l)?.host?.isEmpty == false
    }

    static func normalizeURL(_ raw: String) -> String? {
        var value = stripQuotes(raw.trimmingCharacters(in: .whitespacesAndNewlines))
            .trimmingCharacters(in: CharacterSet(charactersIn: ",;"))
        guard !value.isEmpty, !value.contains(where: { $0.isWhitespace }) else { return nil }
        if !value.contains("://") { value = "https://" + value }
        if let schemeRange = value.range(of: "://") {
            let after = value[schemeRange.upperBound...]
            let hostEnd = after.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? after.endIndex
            let host = String(after[..<hostEnd])
            if let ascii = toASCIIHost(host), ascii != host {
                value = String(value[..<schemeRange.lowerBound]) + "://" + ascii + String(after[hostEnd...])
            }
        }
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host?.isEmpty == false
        else { return nil }
        // 去 query/fragment 与尾部括号注释,再剥完整接口路径 → base URL
        if let qi = value.firstIndex(of: "?") { value = String(value[..<qi]) }
        if let fi = value.firstIndex(of: "#") { value = String(value[..<fi]) }
        value = value.replacingOccurrences(of: #"\([A-Za-z0-9 _-]*\)$"#, with: "", options: .regularExpression)
        if let r = value.range(of: #"/(?:chat/completions|messages|models)/?$"#, options: .regularExpression) {
            value = String(value[..<r.lowerBound])
        }
        if value.hasSuffix("/") { value = String(value.dropLast()) }
        guard !value.isEmpty else { return nil }
        return value
    }

    static func toASCIIHost(_ host: String) -> String? {
        var out: [String] = []
        for label in host.split(separator: ".", omittingEmptySubsequences: false) {
            let s = String(label)
            if s.unicodeScalars.allSatisfy({ $0.value < 128 }) {
                out.append(s)
            } else if let p = punycodeEncode(s) {
                out.append("xn--" + p)
            } else {
                return nil
            }
        }
        return out.isEmpty ? nil : out.joined(separator: ".")
    }

    static func punycodeEncode(_ input: String) -> String? {
        let base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700
        let initialBias = 72, initialN = 128
        let scalars = Array(input.unicodeScalars)
        guard !scalars.isEmpty else { return nil }
        var output = ""
        var n = initialN
        var delta = 0
        var bias = initialBias
        var h = 0
        var b = 0
        for s in scalars where s.value < 128 {
            output.unicodeScalars.append(s)
            b += 1
        }
        h = b
        if b > 0 { output += "-" }
        func adapt(_ dd: Int, _ numPoints: Int, _ firstTime: Bool) -> Int {
            var d = dd
            d = firstTime ? d / damp : d / 2
            d += d / numPoints
            var k = 0
            while d > ((base - tMin) * tMax) / 2 {
                d /= (base - tMin)
                k += base
            }
            return k + (base - tMin + 1) * d / (d + skew)
        }
        while h < scalars.count {
            var m = Int.max
            for s in scalars where s.value >= n && s.value < m { m = Int(s.value) }
            guard m != Int.max else { return nil }
            delta += (m - n) * (h + 1)
            n = m
            for s in scalars {
                let c = Int(s.value)
                if c < n { delta += 1 }
                if c == n {
                    var q = delta
                    var k = base
                    while true {
                        let t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias)
                        if q < t { break }
                        output.unicodeScalars.append(digitToChar(t + (q - t) % (base - t)))
                        q = (q - t) / (base - t)
                        k += base
                    }
                    output.unicodeScalars.append(digitToChar(q))
                    bias = adapt(delta, h + 1, h == b)
                    delta = 0
                    h += 1
                }
            }
            delta += 1
            n += 1
        }
        return output
    }

    private static func digitToChar(_ d: Int) -> UnicodeScalar {
        if d < 26 { return UnicodeScalar(d + 97)! }
        return UnicodeScalar(d - 26 + 48)!
    }

    static func looksLikeKey(_ s: String) -> Bool {
        let t = stripCJK(s).trimmingCharacters(in: .whitespaces)
        guard t.count >= 16, t.count <= 256 else { return false }
        guard t.range(of: #"^[\x21-\x7E]+$"#, options: .regularExpression) != nil else { return false }
        if t.contains(":") { return false }
        if t.range(of: #"^(sk|ak|key|pk|cr|sp|dk|bk|rk|fk|tk|xk|wk|zk|gk|vk|nk|mk|hk|csk|gsk|sk-or|sk-ant|sk_tr|cfut|nvapi|ms)[-_]"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        if t.count >= 28,
           t.range(of: #"^[A-Za-z0-9_\-./=]+$"#, options: .regularExpression) != nil,
           !(t.range(of: #"^[0-9a-fA-F]+$"#, options: .regularExpression) != nil && decodeKeyIfHex(t) == nil),
           t.lowercased().range(of: #"(claude|gpt|gemini|glm|kimi|qwen|deepseek|grok|opus|sonnet|haiku|mistral|llama|minimax|mimo|longcat|codex)"#, options: .regularExpression) == nil {
            return true
        }
        return false
    }

    static func looksLikeModel(_ s: String) -> Bool {
        if s.contains(where: { $0.isWhitespace }) { return false }
        if s.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) { return false }
        if s.count < 2 || s.count > 80 { return false }
        guard s.contains(where: { $0.isLetter }) else { return false }
        if s.contains(where: { $0 == "$" || $0 == "！" || $0 == "？" || $0 == "!" || $0 == "?" }) { return false }
        let l = s.lowercased()
        if l.range(of: #"(rmb|usd|cny|yuan|元|块|钱包|余额)"#, options: .regularExpression) != nil { return false }
        if s.contains("."), s.range(of: #"^[a-z0-9][a-z0-9.-]*$"#, options: [.regularExpression, .caseInsensitive]) != nil,
           s.range(of: #"^(?:gpt|claude|gemini|glm|kimi|qwen|deepseek|grok|opus|sonnet|haiku|mistral|llama|minimax|mimo|longcat|codex|o[134])-"#, options: .regularExpression) == nil
        { return false }
        let families = "claude|gpt|gemini|glm|kimi|qwen|deepseek|grok|opus|sonnet|haiku|mistral|llama|minimax|mimo|longcat|codex|o[134]|k2"
        if l.range(of: families, options: .regularExpression) != nil { return true }
        if l.range(of: #"\d"#, options: .regularExpression) != nil { return true }
        if l.range(of: #"v\d"#, options: .regularExpression) != nil { return true }
        return false
    }

    static public func isAnyTLS(_ s: String) -> Bool {
        s.lowercased().hasPrefix("anytls://")
    }

    static public func isProxyURL(_ s: String) -> Bool {
        let l = s.lowercased()
        return l.hasPrefix("anytls://") || l.hasPrefix("vless://") || l.hasPrefix("vmess://")
            || l.hasPrefix("ss://") || l.hasPrefix("trojan://") || l.hasPrefix("hysteria2://")
            || l.hasPrefix("hy2://") || l.hasPrefix("socks5://")
    }

    static func parseProxyURL(_ url: String) -> ClashProxy? {
        let l = url.lowercased()
        if l.hasPrefix("anytls://") { return parseAnyTLS(url) }
        if l.hasPrefix("vless://") || l.hasPrefix("vmess://")
            || l.hasPrefix("ss://") || l.hasPrefix("trojan://")
            || l.hasPrefix("hysteria2://") || l.hasPrefix("hy2://") {
            return parseGenericProxy(url)
        }
        return nil
    }

    private static func parseGenericProxy(_ url: String) -> ClashProxy? {
        guard let scheme = url.split(separator: ":").first.map(String.init),
              let schemeEnd = url.firstIndex(of: ":") else { return nil }
        let rest = String(url[url.index(after: schemeEnd)...]).dropFirst(2)
        let type = String(scheme)
        guard let at = rest.firstIndex(of: "@") else { return nil }
        let uuid = String(rest[..<at])
        guard !uuid.isEmpty else { return nil }
        let afterAt = String(rest[rest.index(after: at)...])
        guard let hash = afterAt.firstIndex(of: "#") else { return nil }
        let hostPort = String(afterAt[..<hash])
        let nameRaw = String(afterAt[afterAt.index(after: hash)...])
        let name = nameRaw.removingPercentEncoding ?? nameRaw
        guard let colon = hostPort.firstIndex(of: ":") else { return nil }
        let host = String(hostPort[..<colon])
        guard !host.isEmpty else { return nil }
        let portStr = String(hostPort[hostPort.index(after: colon)...])
        let qmIdx = portStr.firstIndex(of: "?")
        let port = Int(qmIdx.map { String(portStr[..<$0]) } ?? portStr) ?? 0
        guard port > 0, port <= 65535 else { return nil }
        var sni = host
        if let qm = qmIdx {
            let query = String(portStr[portStr.index(after: qm)...])
            for pair in query.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2, kv[0] == "sni" || kv[0] == "peer" { sni = kv[1] }
            }
        }
        return ClashProxy(name: name.isEmpty ? "\(host):\(port)" : name, type: type, server: host, port: port, uuid: uuid, sni: sni)
    }

    static public func parseAnyTLS(_ url: String) -> ClashProxy? {
        guard isAnyTLS(url) else { return nil }
        let s = String(url.dropFirst("anytls://".count))
        guard let at = s.firstIndex(of: "@") else { return nil }
        let uuid = String(s[..<at])
        let afterAt = String(s[s.index(after: at)...])
        guard let hash = afterAt.firstIndex(of: "#") else { return nil }
        let hostPort = String(afterAt[..<hash])
        let nameRaw = String(afterAt[afterAt.index(after: hash)...])
        let name = nameRaw.removingPercentEncoding ?? nameRaw
        guard let colon = hostPort.firstIndex(of: ":") else { return nil }
        let host = String(hostPort[..<colon])
        let portAndQuery = String(hostPort[hostPort.index(after: colon)...])
        guard let qm = portAndQuery.firstIndex(of: "?") else { return nil }
        guard let port = Int(portAndQuery[..<qm]), port > 0, port <= 65535 else { return nil }
        guard !host.isEmpty, !uuid.isEmpty else { return nil }
        let query = String(portAndQuery[portAndQuery.index(after: qm)...])
        var sni = host
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 {
                if kv[0] == "sni" { sni = kv[1] }
            }
        }
        return ClashProxy(name: name.isEmpty ? "\(host):\(port)" : name, server: host, port: port, uuid: uuid, sni: sni)
    }
}
