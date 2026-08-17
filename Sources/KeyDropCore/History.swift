import Foundation

public struct HistoryEntry: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, ts, raw, format, name, url, model, models, key, keyMasked, targets
        case ccProviderID, ccRenamedFrom, ccRenamedTo, cpaConfigPath, status, note
        case health, healthDetail, healthAt
        case ccMissing
    }

    public var id: String
    public var ts: TimeInterval
    public var raw: String
    public var format: String
    public var name: String?
    public var url: String?
    public var model: String?
    public var models: [String]?
    public var key: String?
    public var keyMasked: String
    public var targets: [String]
    public var ccProviderID: String?
    public var ccRenamedFrom: String?
    public var ccRenamedTo: String?
    public var cpaConfigPath: String?
    public var status: String
    public var note: String?
    public var health: String?
    public var healthDetail: String?
    public var healthAt: TimeInterval?
    /// cc-switch 中 provider 已缺失,但 key 仍可用(可手动重新导入)
    public var ccMissing: Bool?

    public var healthColor: (ok: Bool, dead: Bool) {
        switch health {
        case "dead": return (false, true)
        case "err": return (false, false)
        default: return (true, false)
        }
    }

    public init(
        id: String,
        ts: TimeInterval,
        raw: String,
        format: String,
        name: String?,
        url: String?,
        model: String?,
        models: [String]? = nil,
        key: String?,
        keyMasked: String,
        targets: [String],
        ccProviderID: String?,
        ccRenamedFrom: String?,
        ccRenamedTo: String?,
        cpaConfigPath: String?,
        status: String,
        note: String? = nil,
        health: String? = nil,
        healthDetail: String? = nil,
        healthAt: TimeInterval? = nil,
        ccMissing: Bool? = nil
    ) {
        self.id = id
        self.ts = ts
        self.raw = raw
        self.format = format
        self.name = name
        self.url = url
        self.model = model
        self.models = models
        self.key = key
        self.keyMasked = keyMasked
        self.targets = targets
        self.ccProviderID = ccProviderID
        self.ccRenamedFrom = ccRenamedFrom
        self.ccRenamedTo = ccRenamedTo
        self.cpaConfigPath = cpaConfigPath
        self.status = status
        self.note = note
        self.health = health
        self.healthDetail = healthDetail
        self.healthAt = healthAt
        self.ccMissing = ccMissing
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        ts = try c.decode(TimeInterval.self, forKey: .ts)
        raw = try c.decode(String.self, forKey: .raw)
        format = try c.decode(String.self, forKey: .format)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        models = try c.decodeIfPresent([String].self, forKey: .models)
        key = try c.decodeIfPresent(String.self, forKey: .key)
        keyMasked = try c.decode(String.self, forKey: .keyMasked)
        targets = try c.decode([String].self, forKey: .targets)
        ccProviderID = try c.decodeIfPresent(String.self, forKey: .ccProviderID)
        ccRenamedFrom = try c.decodeIfPresent(String.self, forKey: .ccRenamedFrom)
        ccRenamedTo = try c.decodeIfPresent(String.self, forKey: .ccRenamedTo)
        cpaConfigPath = try c.decodeIfPresent(String.self, forKey: .cpaConfigPath)
        status = try c.decode(String.self, forKey: .status)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        health = try c.decodeIfPresent(String.self, forKey: .health)
        healthDetail = try c.decodeIfPresent(String.self, forKey: .healthDetail)
        healthAt = try c.decodeIfPresent(TimeInterval.self, forKey: .healthAt)
        ccMissing = try c.decodeIfPresent(Bool.self, forKey: .ccMissing)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(ts, forKey: .ts)
        try c.encode(raw, forKey: .raw)
        try c.encode(format, forKey: .format)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(url, forKey: .url)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(models, forKey: .models)
        try c.encodeIfPresent(key, forKey: .key)
        try c.encode(keyMasked, forKey: .keyMasked)
        try c.encode(targets, forKey: .targets)
        try c.encodeIfPresent(ccProviderID, forKey: .ccProviderID)
        try c.encodeIfPresent(ccRenamedFrom, forKey: .ccRenamedFrom)
        try c.encodeIfPresent(ccRenamedTo, forKey: .ccRenamedTo)
        try c.encodeIfPresent(cpaConfigPath, forKey: .cpaConfigPath)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(note, forKey: .note)
        try c.encodeIfPresent(health, forKey: .health)
        try c.encodeIfPresent(healthDetail, forKey: .healthDetail)
        try c.encodeIfPresent(healthAt, forKey: .healthAt)
        try c.encodeIfPresent(ccMissing, forKey: .ccMissing)
    }

    public var timeStr: String {
        let df = DateFormatter()
        df.dateFormat = "MM-dd HH:mm"
        return df.string(from: Date(timeIntervalSince1970: ts))
    }

    public var summary: String {
        var parts: [String] = []
        let ms = models ?? (model.map { [$0] })
        if let ms, !ms.isEmpty {
            if ms.count == 1 {
                parts.append(ms[0])
            } else {
                parts.append("\(ms[0]) +\(ms.count - 1)")
            }
        }
        if let u = url, let h = URL(string: u)?.host { parts.append(h) }
        return parts.isEmpty ? keyMasked : parts.joined(separator: " · ")
    }
}

public final class HistoryStore {
    static let shared = HistoryStore()

    var storeDir: URL {
        let base = ProcessInfo.processInfo.environment["KEYDROP_HOME"]
            ?? (NSHomeDirectory() + "/.keydrop")
        return URL(fileURLWithPath: base)
    }
    private var fileURL: URL { storeDir.appendingPathComponent("history.json") }

    private let lock = NSLock()
    private var _items: [HistoryEntry] = []

    /// 非线程安全快照入口;UI/CLI 请用 snapshot()
    var items: [HistoryEntry] { snapshot() }

    public init() { load() }

    public func snapshot() -> [HistoryEntry] {
        lock.lock(); defer { lock.unlock() }
        return _items
    }

    func load() {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL) else { _items = []; return }
        struct Wrapper: Codable { var items: [HistoryEntry] }
        if let w = try? JSONDecoder().decode(Wrapper.self, from: data) {
            _items = w.items
        } else {
            Logger.warn("history 文件格式无效,已忽略: \(fileURL.path)")
            _items = []
        }
    }

    public func save() throws {
        lock.lock()
        let copy = _items
        lock.unlock()
        struct Wrapper: Codable { var items: [HistoryEntry] }
        var merged = copy
        // 竞态保护(跨进程,如 CLI 删除 vs app 内存):
        //   - 文件存在而内存缺失(文件独有)= CLI 新增 → 保留
        //   - 内存存在而文件缺失:
        //       条目的 ts 晚于文件全部条目 → 本次会话新增 → 保留
        //       否则 → 其他进程已删除 → 丢弃(防复活)
        //   - 同 id 以内存版为准(健康更新等)
        if let data = try? Data(contentsOf: fileURL),
           let w = try? JSONDecoder().decode(Wrapper.self, from: data) {
            let fileMaxTS = w.items.map { $0.ts }.max() ?? 0
            let fileByID = Dictionary(uniqueKeysWithValues: w.items.map { ($0.id, $0) })
            let memIDs = Set(copy.map { $0.id })
            merged = copy.filter { e in
                if fileByID[e.id] != nil { return true }
                return e.ts > fileMaxTS
            } + w.items.filter { !memIDs.contains($0.id) }
            merged.sort { $0.ts > $1.ts }
        }
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: storeDir.path)
        let data = try JSONEncoder().encode(Wrapper(items: merged))
        let tmp = fileURL.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: fileURL)
        }
        lock.lock()
        _items = merged
        lock.unlock()
    }

    public func append(_ e: HistoryEntry) throws {
        lock.lock()
        _items.insert(e, at: 0)
        if _items.count > 500 { _items = Array(_items.prefix(500)) }
        lock.unlock()
        try save()
    }

    public func update(_ e: HistoryEntry) throws {
        lock.lock()
        if let i = _items.firstIndex(where: { $0.id == e.id }) {
            _items[i] = e
            lock.unlock()
            try save()
        } else {
            lock.unlock()
        }
    }

    public func find(idPrefix: String) -> HistoryEntry? {
        let prefix = idPrefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !prefix.isEmpty else { return nil }
        let matches = snapshot().filter { $0.id.hasPrefix(prefix) }
        if matches.count == 1 { return matches[0] }
        if let exact = matches.first(where: { $0.id == prefix }) { return exact }
        return nil
    }

    func findActiveByRaw(_ snippet: String) -> HistoryEntry? {
        let s = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count >= 8 else { return nil }
        let matches = snapshot().filter {
            $0.status == "active" && ($0.raw == s || $0.raw.contains(s))
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// 按 API key 查找已存在的活跃记录(同一 key 全局唯一)
    public func findActiveByKey(_ key: String) -> HistoryEntry? {
        let wantKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wantKey.isEmpty else { return nil }
        return snapshot().first {
            $0.status == "active" && ($0.key ?? "") == wantKey
        }
    }

    /// 兼容旧调用:按 key 去重(忽略 url)
    func findActiveDuplicate(url: String, key: String) -> HistoryEntry? {
        findActiveByKey(key)
    }

    public func lastURL() -> String? {
        snapshot().first { ($0.url ?? "").isEmpty == false && $0.status == "active" }?.url
    }
}

public final class Prefs {
    public static let shared = Prefs()

    private var fileURL: URL {
        let base = ProcessInfo.processInfo.environment["KEYDROP_HOME"]
            ?? (NSHomeDirectory() + "/.keydrop")
        return URL(fileURLWithPath: base).appendingPathComponent("prefs.json")
    }

    private let lock = NSLock()
    private var _useCC = true
    private var _useCPA = false
    private var _useDSH = true
    private var _cpaConfigPath: String? = nil
    private var _proxy = ""

    public var useCC: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _useCC }
        set { lock.lock(); _useCC = newValue; lock.unlock() }
    }
    public var useCPA: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _useCPA }
        set { lock.lock(); _useCPA = newValue; lock.unlock() }
    }
    public var useDSH: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _useDSH }
        set { lock.lock(); _useDSH = newValue; lock.unlock() }
    }
    public var cpaConfigPath: String? {
        get { lock.lock(); defer { lock.unlock() }; return _cpaConfigPath }
        set { lock.lock(); _cpaConfigPath = newValue; lock.unlock() }
    }
    /// 本地代理(如 http://127.0.0.1:7890);为空表示直连
    public var proxy: String {
        get { lock.lock(); defer { lock.unlock() }; return _proxy }
        set { lock.lock(); _proxy = newValue; lock.unlock() }
    }

    private(set) var loaded = false

    init() { load() }

    func load() {
        lock.lock(); defer { lock.unlock() }
        if let data = try? Data(contentsOf: fileURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let v = obj["useCC"] as? Bool { _useCC = v }
            if let v = obj["useCPA"] as? Bool { _useCPA = v }
            if let v = obj["useDSH"] as? Bool { _useDSH = v }
            _cpaConfigPath = obj["cpaConfigPath"] as? String
            if let v = obj["proxy"] as? String { _proxy = v }
        }
        loaded = true
    }

    public func resolvedCPAConfig() -> String? {
        if let override = ProcessInfo.processInfo.environment["KEYDROP_CPA_CONFIG"],
           FileManager.default.fileExists(atPath: override) {
            return override
        }
        lock.lock()
        let stored = _cpaConfigPath
        lock.unlock()
        if let p = stored, FileManager.default.fileExists(atPath: p) {
            return p
        }
        return CPAWriter.locateConfig()
    }

    public func save() throws {
        lock.lock()
        let cc = _useCC
        let cpa = _useCPA
        let dsh = _useDSH
        let path = _cpaConfigPath
        let proxy = _proxy
        lock.unlock()
        var obj: [String: Any] = ["useCC": cc, "useCPA": cpa, "useDSH": dsh, "proxy": proxy]
        if let path, !path.isEmpty { obj["cpaConfigPath"] = path }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        let tmp = fileURL.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: fileURL)
        }
    }
}
