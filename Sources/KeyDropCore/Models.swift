import Foundation

public struct ParsedKey {
    public init() {}
    public var name: String? = nil
    public var url: String? = nil
    public var key: String? = nil
    public var model: String? = nil
    public var models: [String]? = nil
    public var format = "unknown"
    public var sourceFile: String? = nil

    public var keyMasked: String {
        guard let k = key else { return "" }
        if k.count <= 10 { return String(repeating: "*", count: k.count) }
        return String(k.prefix(5)) + "…" + String(k.suffix(4))
    }

    var host: String {
        guard let u = url, let urlObj = URL(string: u), let h = urlObj.host else { return "" }
        return h
    }

    var score: Int {
        var s = 0
        if key != nil { s += 4 }
        if url != nil { s += 2 }
        if model != nil { s += 1 }
        if name != nil { s += 1 }
        return s
    }
}

public enum ParseError: LocalizedError {
    case emptyInput
    case noKeyFound(String)
    case noURL
    case io(String)
    case duplicate(id: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .emptyInput: return "输入为空"
        case .noKeyFound(let hint): return "未找到 API key。\(hint)"
        case .noURL: return "未找到 URL。请提供包含 base_url 的内容,或先添加过一条带 URL 的记录以便复用。"
        case .io(let s): return s
        case .duplicate(_, let message): return message
        }
    }
}
