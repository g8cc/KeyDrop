import Foundation

/// 单次探测结果点(监控图数据源)。每条目滚动保留最近 30 个点
public struct ProbePoint: Codable, Equatable {
    public var t: TimeInterval
    public var ms: Double?
    public var ok: Bool
    /// CPA 链路探测结果(nil=该轮未测/无 cpa 目标)
    public var cpa: Bool?

    public init(t: TimeInterval, ms: Double?, ok: Bool, cpa: Bool? = nil) {
        self.t = t; self.ms = ms; self.ok = ok; self.cpa = cpa
    }
}

public struct HistoryEntry: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, ts, raw, format, name, url, model, models, key, keyMasked, targets
        case ccProviderID, ccRenamedFrom, ccRenamedTo, cpaConfigPath, grokConfigPath, status, note
        case health, healthDetail, healthAt
        case ccMissing
        case clashFile
        case latencyMs, failStreak, viaCPAOk, viaCPAAt
        case probeLog
        case modelProbeLog
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
    /// Grok Build config used by this entry, so delete/reimport never guesses a path.
    public var grokConfigPath: String?
    public var status: String
    public var note: String?
    public var health: String?
    public var healthDetail: String?
    public var healthAt: TimeInterval?
    /// cc-switch 中 provider 已缺失,但 key 仍可用(可手动重新导入)
    public var ccMissing: Bool?
    /// Clash 订阅生成的 yaml 文件名(仅 basename,存于 profiles 目录);
    /// 没有它 delete 无法清理生成的订阅文件
    public var clashFile: String?
    /// 最近一次 chat 探测的端到端延迟(毫秒)。实战监控:慢网关也显示"可用",
    /// 但延迟让用户对"用的时候行不行"有预期(真实反馈:显示可用,用起来 30s 无响应)
    public var latencyMs: Double?
    /// 连续探测失败次数(成功即清零)。防抖:单次网络抖动不降级状态,
    /// 连续 ≥2 次才把 health 从 ok 改为 err/dead
    public var failStreak: Int?
    /// CPA 链路最近一次探测结果(经 127.0.0.1:8317 用实际激活模型)。nil=未测/无 cpa 目标。
    /// 健康测试直连上游,但用户真实请求走 CPA —— 上游 OK ≠ CPA 链路 OK
    public var viaCPAOk: Bool?
    /// CPA 链路探测时间
    public var viaCPAAt: TimeInterval?
    /// 探测历史(监控图数据源),滚动保留最近 30 个点
    public var probeLog: [ProbePoint]?
    /// 模型级探测历史(模型级监控):模型名 → 各自的 30 点轨迹。
    /// key 级 probeLog 回答"这把 key 整体好不好",这里回答"每个模型分别好不好"
    public var modelProbeLog: [String: [ProbePoint]]?

    /// uptime 百分比(status page 行业指标):已采集周期中通过的占比。
    /// 只按已采集格算(灰格不拉低),nil=尚无采集数据
    public var uptimePercent: Int? {
        guard let log = probeLog, !log.isEmpty else { return nil }
        let ok = log.filter { $0.ok }.count
        return Int((Double(ok) / Double(log.count) * 100).rounded())
    }

    /// 模型级 uptime:模型名 → 百分比(只含有采集数据的模型)
    public var modelUptimes: [String: Int] {
        var out: [String: Int] = [:]
        for (m, log) in modelProbeLog ?? [:] where !log.isEmpty {
            let ok = log.filter { $0.ok }.count
            out[m] = Int((Double(ok) / Double(log.count) * 100).rounded())
        }
        return out
    }

    public var healthColor: (ok: Bool, dead: Bool) {
        switch health {
        case "dead": return (false, true)
        case "err", "quota": return (false, false)
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
        grokConfigPath: String? = nil,
        status: String,
        note: String? = nil,
        health: String? = nil,
        healthDetail: String? = nil,
        healthAt: TimeInterval? = nil,
        ccMissing: Bool? = nil,
        clashFile: String? = nil,
        latencyMs: Double? = nil,
        failStreak: Int? = nil,
        viaCPAOk: Bool? = nil,
        viaCPAAt: TimeInterval? = nil,
        probeLog: [ProbePoint]? = nil,
        modelProbeLog: [String: [ProbePoint]]? = nil
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
        self.grokConfigPath = grokConfigPath
        self.status = status
        self.note = note
        self.health = health
        self.healthDetail = healthDetail
        self.healthAt = healthAt
        self.ccMissing = ccMissing
        self.clashFile = clashFile
        self.latencyMs = latencyMs
        self.failStreak = failStreak
        self.viaCPAOk = viaCPAOk
        self.viaCPAAt = viaCPAAt
        self.probeLog = probeLog
        self.modelProbeLog = modelProbeLog
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
        grokConfigPath = try c.decodeIfPresent(String.self, forKey: .grokConfigPath)
        status = try c.decode(String.self, forKey: .status)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        health = try c.decodeIfPresent(String.self, forKey: .health)
        healthDetail = try c.decodeIfPresent(String.self, forKey: .healthDetail)
        healthAt = try c.decodeIfPresent(TimeInterval.self, forKey: .healthAt)
        ccMissing = try c.decodeIfPresent(Bool.self, forKey: .ccMissing)
        clashFile = try c.decodeIfPresent(String.self, forKey: .clashFile)
        latencyMs = try c.decodeIfPresent(Double.self, forKey: .latencyMs)
        failStreak = try c.decodeIfPresent(Int.self, forKey: .failStreak)
        viaCPAOk = try c.decodeIfPresent(Bool.self, forKey: .viaCPAOk)
        viaCPAAt = try c.decodeIfPresent(TimeInterval.self, forKey: .viaCPAAt)
        probeLog = try c.decodeIfPresent([ProbePoint].self, forKey: .probeLog)
        modelProbeLog = try c.decodeIfPresent([String: [ProbePoint]].self, forKey: .modelProbeLog)
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
        try c.encodeIfPresent(grokConfigPath, forKey: .grokConfigPath)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(note, forKey: .note)
        try c.encodeIfPresent(health, forKey: .health)
        try c.encodeIfPresent(healthDetail, forKey: .healthDetail)
        try c.encodeIfPresent(healthAt, forKey: .healthAt)
        try c.encodeIfPresent(ccMissing, forKey: .ccMissing)
        try c.encodeIfPresent(clashFile, forKey: .clashFile)
        try c.encodeIfPresent(latencyMs, forKey: .latencyMs)
        try c.encodeIfPresent(failStreak, forKey: .failStreak)
        try c.encodeIfPresent(viaCPAOk, forKey: .viaCPAOk)
        try c.encodeIfPresent(viaCPAAt, forKey: .viaCPAAt)
        try c.encodeIfPresent(probeLog, forKey: .probeLog)
        try c.encodeIfPresent(modelProbeLog, forKey: .modelProbeLog)
    }

    private static let timeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "MM-dd HH:mm"
        return df
    }()

    public var timeStr: String {
        Self.timeFormatter.string(from: Date(timeIntervalSince1970: ts))
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
    /// 启动 load 时磁盘上已有的条目 id 快照。
    /// 防复活规则:内存条目若既不在当前文件、也不在 loadedIDs(=本会话新增),视为其他进程已删除,丢弃。
    /// 旧实现用 `ts > fileMaxTS` 判断,被删条目恰好是最新时 ts 最大 → 复活,bug。
    private var loadedIDs: Set<String> = []
    /// 上次读文件时的 mtime:snapshot 检测到外部(CLI)改过文件就重载,
    /// 否则常驻 app 看不到 CLI 新增的条目,直到重启
    private var lastMtime: Date? = nil

    /// 非线程安全快照入口;UI/CLI 请用 snapshot()
    var items: [HistoryEntry] { snapshot() }

    public init() { load() }

    public func snapshot() -> [HistoryEntry] {
        lock.lock(); defer { lock.unlock() }
        refreshIfExternalChangeLocked()
        return _items
    }

    /// 锁内调用:文件被其他进程改过(mtime 变化)→ 重读进内存
    private func refreshIfExternalChangeLocked() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let mtime = attrs[.modificationDate] as? Date else { return }
        if lastMtime == nil { lastMtime = mtime; return }
        if mtime != lastMtime {
            loadLocked()
        }
    }

    func load() {
        lock.lock(); defer { lock.unlock() }
        loadLocked()
    }

    private func loadLocked() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let mtime = attrs[.modificationDate] as? Date else { return }
        // 记录进入时的 mtime:仅当本轮真正消费了文件内容才更新 lastMtime,
        // 否则解析失败后外部把文件修好,也会因 mtime 未变而被跳过、永远读不进来
        let currentMtime = mtime
        guard let data = try? Data(contentsOf: fileURL) else {
            // 读失败 ≠ 文件为空,可能是磁盘满/权限瞬时故障;保留内存快照,
            // 且不更新 lastMtime,下轮 snapshot 时 mtime 未变会自动重试
            Logger.warn("history 文件读取失败,保留内存快照: \(fileURL.path)")
            return
        }
        struct Wrapper: Codable { var items: [HistoryEntry] }
        if data.isEmpty {
            // 只有确认是空文件才清空内存(首次初始化场景);同样视为已消费,更新 mtime,
            // 否则 snapshot 每轮都会因 mtime 未变未更新而反复重读空文件
            _items = []; loadedIDs = []
            lastMtime = currentMtime
        } else if let w = try? JSONDecoder().decode(Wrapper.self, from: data) {
            _items = w.items
            loadedIDs = Set(w.items.map { $0.id })
            lastMtime = currentMtime
        } else {
            // 解析失败:很可能是 CLI 写到一半被并发读到(partial JSON)。保留上一份内存,不要清空,
            // 否则 mtime 刷新路径下 UI 会出现短暂的「历史清空」闪动
            Logger.warn("history 文件解析失败,保留内存快照(可能是并发写入): \(fileURL.path)")
        }
    }

    public func save() throws {
        lock.lock()
        defer { lock.unlock() }
        // 语义:内存是权威快照,全部条目视为脏(覆盖外部同名条目)
        try saveLocked(dirtyIDs: Set(_items.map { $0.id }))
    }

    /// 全部保存逻辑,调用方必须已持有 NSLock。
    /// flock 锁住整个「读文件→合并→写文件」临界区:CLI 与 app 并发时,
    /// 没有它,两个进程各自的读-改-写会互相覆盖、静默丢条目。
    /// dirtyIDs = 本次调用真正修改过的条目 id:合并冲突时以内存为准;
    /// 非脏条目若文件已被其他进程更新,则以文件为准,避免旧内存回滚并发修改。
    private func saveLocked(dirtyIDs: Set<String> = []) throws {
        try FileLock.withLock(FileLock.lockPath(for: fileURL.path)) {
            try saveLockedNoFlock(dirtyIDs: dirtyIDs)
        }
    }

    private func saveLockedNoFlock(dirtyIDs: Set<String>) throws {
        struct Wrapper: Codable { var items: [HistoryEntry] }
        var merged = _items
        // 文件从存在变为缺失 = 其他进程/用户清空了历史。防复活规则同样适用:
        // 本会话已落盘过的条目不复活,只保留本次调用新增(非 loadedIDs)的脏条目。
        // 仅在文件确实不存在时触发;文件存在但读失败(瞬时 IO 错误)不动内存。
        if !FileManager.default.fileExists(atPath: fileURL.path), lastMtime != nil {
            merged = merged.filter { dirtyIDs.contains($0.id) || !loadedIDs.contains($0.id) }
        } else if let data = try? Data(contentsOf: fileURL),
           let w = try? JSONDecoder().decode(Wrapper.self, from: data) {
            let fileIDs = Set(w.items.map { $0.id })
            let memIDs = Set(merged.map { $0.id })
            // 文件 mtime 晚于我们上次消费的时间 = 其他进程改过:非脏同 id 条目以文件版为准,
            // 否则内存里的旧版本会把 CLI 刚改的 status/health 静默回滚
            var externalChanged = false
            if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
               let mtime = attrs[.modificationDate] as? Date, let last = lastMtime, mtime != last {
                externalChanged = true
            }
            merged = merged.filter { e in
                guard fileIDs.contains(e.id) else { return !loadedIDs.contains(e.id) }
                if dirtyIDs.contains(e.id) { return true }
                return !externalChanged
            } + w.items.filter { wItem in
                // 外部变更时,被丢弃的非脏同 id 内存条目必须用文件版补回,
                // 否则条目凭空消失;脏条目(本次刚改)保持内存版,不回填文件旧版
                !memIDs.contains(wItem.id) || (externalChanged && !dirtyIDs.contains(wItem.id))
            }
            // 文件独有的 id 登记进 loadedIDs:后续 save 时若它再从文件消失,同样按「其他进程删除」处理
            for e in w.items where !loadedIDs.contains(e.id) { loadedIDs.insert(e.id) }
            merged.sort { $0.ts > $1.ts }
        }
            // 合并可能带回文件独有的旧条目,重新执行上限(丢最旧)
            merged = Self.applyCap(merged)
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
        _items = merged
        // 已落盘的 id 全部登记:此后任何一次 save 发现它从文件消失 → 其他进程删除 → 不复活
        loadedIDs = Set(merged.map { $0.id })
        // 落盘后同步 mtime:避免下一次 save 把「自己刚写的」误判为外部变更,
        // 白白多做一轮文件版对账
        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let mtime = attrs[.modificationDate] as? Date {
            lastMtime = mtime
        }
    }

    public func append(_ e: HistoryEntry) throws {
        lock.lock()
        defer { lock.unlock() }
        _items.insert(e, at: 0)
        _items = Self.applyCap(_items)
        try saveLocked(dirtyIDs: [e.id])
    }

    /// 历史上限 500,但绝不丢弃仍持有外部产物写入凭据的 active 条目:
    /// 账本不变量要求每个 cc-switch provider / CPA key / Grok route 至少有一条历史指向它,
    /// 静默裁剪 active 条目会让这些外部产物变孤儿 —— 删不掉、对账不认领。
    /// 输入按 ts desc:优先从尾部丢弃 deleted / 无 target 条目,凑不够额就保留 active
    /// (宁可软超限也不制造孤儿)。结果保持 ts desc,不改变 list/snapshot 顺序
    public static func applyCap(_ items: [HistoryEntry]) -> [HistoryEntry] {
        guard items.count > 500 else { return items }
        var keep = items
        // 从最旧(尾部)开始,丢弃可回收条目直到不超限
        var idx = keep.count - 1
        while keep.count > 500, idx >= 0 {
            let e = keep[idx]
            let reclaimable = e.status != "active" || e.targets.isEmpty
            if reclaimable { keep.remove(at: idx) }
            idx -= 1
        }
        // 全部是 active 仍超限时:接受超限而非丢 active(软上限)
        return keep
    }

    public func update(_ e: HistoryEntry) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let i = _items.firstIndex(where: { $0.id == e.id }) else { return }
        var merged = e
        // probeLog 是监控账本,归 store 所有:调用方的 entry 快照可能早于最新探测点
        // (refreshModels 先 appendProbePoint 再 update 整条),整条覆盖会回滚监控历史
        merged.probeLog = _items[i].probeLog
        merged.modelProbeLog = _items[i].modelProbeLog
        _items[i] = merged
        try saveLocked(dirtyIDs: [e.id])
    }

    /// 批量健康更新:只合并 health/healthDetail/healthAt 三个字段,其余字段以内存现状为准。
    /// scanHealth 持有旧快照做网络测试,测试期间条目可能被本进程或 CLI 改过(note/targets/status),
    /// 整条覆盖会把并发修改静默回滚 —— 所以这里按字段合并而不是整条替换。
    public func mergeHealth(_ entries: [HistoryEntry], at: TimeInterval) throws {
        lock.lock()
        defer { lock.unlock() }
        for e in entries {
            guard let i = _items.firstIndex(where: { $0.id == e.id }) else { continue }
            _items[i].health = e.health
            _items[i].healthDetail = e.healthDetail
            _items[i].healthAt = at
            // 实战监控字段随健康扫描一并合并(延迟/防抖/CPA 链路)
            _items[i].latencyMs = e.latencyMs
            _items[i].failStreak = e.failStreak
            _items[i].viaCPAOk = e.viaCPAOk
            _items[i].viaCPAAt = e.viaCPAAt
            // 探测历史滚动追加(监控图数据源)
            let pt = ProbePoint(t: at, ms: e.latencyMs,
                                ok: e.health == "ok" || e.health == "proxy-ok", cpa: e.viaCPAOk)
            var log = (_items[i].probeLog ?? []) + [pt]
            if log.count > 30 { log = Array(log.suffix(30)) }
            _items[i].probeLog = log
            // 模型级追加:e.modelProbeLog 携带本轮各模型新点,与 store 现状合并截 30
            if let newPoints = e.modelProbeLog, !newPoints.isEmpty {
                var merged = _items[i].modelProbeLog ?? [:]
                for (m, pts) in newPoints {
                    var arr = (merged[m] ?? []) + pts
                    if arr.count > 30 { arr = Array(arr.suffix(30)) }
                    merged[m] = arr
                }
                _items[i].modelProbeLog = merged
            }
        }
        try saveLocked(dirtyIDs: Set(entries.map { $0.id }))
    }

    /// 手动重测(refreshModels)路径追加单个探测点(监控图数据源)
    public func appendProbePoint(id: String, ok: Bool, ms: Double?, cpa: Bool?, at: TimeInterval) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let i = _items.firstIndex(where: { $0.id == id }) else { return }
        var log = (_items[i].probeLog ?? []) + [ProbePoint(t: at, ms: ms, ok: ok, cpa: cpa)]
        if log.count > 30 { log = Array(log.suffix(30)) }
        _items[i].probeLog = log
        try saveLocked(dirtyIDs: [id])
    }

    /// 模型级探测点追加(手动重测/扫描共用)
    public func appendModelProbePoints(id: String, points: [String: ProbePoint]) throws {
        guard !points.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let i = _items.firstIndex(where: { $0.id == id }) else { return }
        var merged = _items[i].modelProbeLog ?? [:]
        for (m, pt) in points {
            var arr = (merged[m] ?? []) + [pt]
            if arr.count > 30 { arr = Array(arr.suffix(30)) }
            merged[m] = arr
        }
        _items[i].modelProbeLog = merged
        try saveLocked(dirtyIDs: [id])
    }

    /// 批量更新后只落盘一次。健康扫描等高频小更新的场景用这个,
    /// 逐条 update 会把整份历史反复序列化写盘(O(N²) IO 放大)。
    public func updateAll(_ entries: [HistoryEntry]) throws {
        lock.lock()
        defer { lock.unlock() }
        for e in entries {
            if let i = _items.firstIndex(where: { $0.id == e.id }) {
                _items[i] = e
            }
        }
        try saveLocked(dirtyIDs: Set(entries.map { $0.id }))
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

    /// 原子「查重或插入」。Core.add 的 findActiveByKey 查重与最终 append 之间
    /// 隔着数秒到数十秒的网络测试,CLI 与 app 同时导入同一 key 时双方都查不到
    /// 对方,各建一条重复记录。这里在 flock 临界区内对文件做最终查重:
    /// 命中文件中的 active 同 key 条目 → 返回它(不插入);未命中 → 插入并返回 nil
    public func appendDedupByKey(_ e: HistoryEntry) throws -> HistoryEntry? {
        func isDup(_ other: HistoryEntry) -> Bool {
            guard let k = e.key?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty else { return false }
            return other.status == "active" && (other.key ?? "") == k && other.id != e.id
        }
        lock.lock(); defer { lock.unlock() }
        refreshIfExternalChangeLocked()
        if let dup = _items.first(where: isDup) { return dup }
        var survivor: HistoryEntry? = nil
        try FileLock.withLock(FileLock.lockPath(for: fileURL.path)) {
            struct Wrapper: Codable { var items: [HistoryEntry] }
            if let data = try? Data(contentsOf: fileURL),
               let w = try? JSONDecoder().decode(Wrapper.self, from: data),
               let dup = w.items.first(where: isDup) {
                survivor = dup
                return  // 已有同 key 条目:不插入
            }
            _items.insert(e, at: 0)
            // 与 append() 同走 applyCap:硬截 prefix(500) 会把尾部仍持有 cc-switch/CPA/Grok
            // 产物的 active 老条目直接丢掉,外部产物成孤儿(删不掉、对账不认领)
            _items = Self.applyCap(_items)
            // 内部直接用 NoFlock 版:外层已持 flock,再走 saveLocked 会二次 flock 自锁
            try saveLockedNoFlock(dirtyIDs: [e.id])
        }
        return survivor
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
    private var _useGrok = true
    private var _useCPA = false
    private var _useDSH = true
    private var _cpaResident = true
    private var _cpaConfigPath: String? = nil
    private var _proxy = ""

    public var useCC: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _useCC }
        set { lock.lock(); _useCC = newValue; lock.unlock() }
    }
    public var useGrok: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _useGrok }
        set { lock.lock(); _useGrok = newValue; lock.unlock() }
    }
    public var useCPA: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _useCPA }
        set { lock.lock(); _useCPA = newValue; lock.unlock() }
    }
    public var useDSH: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _useDSH }
        set { lock.lock(); _useDSH = newValue; lock.unlock() }
    }
    /// CPA 导入成功后自动同步「CPA 固定入口」到 cc-switch(opencode/codex/claude),
    /// 让各工具无需手动配置即可用 http://127.0.0.1:8317/v1 消费新导入的 key
    public var cpaResident: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _cpaResident }
        set { lock.lock(); _cpaResident = newValue; lock.unlock() }
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
    /// CPA 管理 API 密钥(管理面板登录口令);非空 = 全部 CPA 读写走管理 API,
    /// 不触碰 CPA 数据目录文件(根治 ~/Documents 下的 TCC「文稿」弹窗)
    private var _cpaManagementKey: String? = nil
    private var _cpaAPIBase: String? = nil
    public var cpaManagementKey: String? {
        get { lock.lock(); defer { lock.unlock() }; return _cpaManagementKey }
        set { lock.lock(); _cpaManagementKey = newValue; lock.unlock() }
    }
    /// CPA 管理 API 地址,默认 http://127.0.0.1:8317
    public var cpaAPIBase: String? {
        get { lock.lock(); defer { lock.unlock() }; return _cpaAPIBase }
        set { lock.lock(); _cpaAPIBase = newValue; lock.unlock() }
    }

    init() { load() }

    func load() {
        lock.lock(); defer { lock.unlock() }
        if let data = try? Data(contentsOf: fileURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let v = obj["useCC"] as? Bool { _useCC = v }
            if let v = obj["useGrok"] as? Bool { _useGrok = v }
            if let v = obj["useCPA"] as? Bool { _useCPA = v }
            if let v = obj["useDSH"] as? Bool { _useDSH = v }
            if let v = obj["cpaResident"] as? Bool { _cpaResident = v }
            _cpaConfigPath = obj["cpaConfigPath"] as? String
            if let v = obj["proxy"] as? String { _proxy = v }
            _cpaManagementKey = obj["cpaManagementKey"] as? String
            _cpaAPIBase = obj["cpaAPIBase"] as? String
        }
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
        let grok = _useGrok
        let cpa = _useCPA
        let dsh = _useDSH
        let resident = _cpaResident
        let path = _cpaConfigPath
        let proxy = _proxy
        let mgmtKey = _cpaManagementKey
        let apiBase = _cpaAPIBase
        lock.unlock()
        // flock 串行化跨进程写:app 与 CLI 并发 save 时,固定 tmp 路径会被对方
        // replaceItemAt 拽走导致写失败,并发覆盖也会丢掉对方的设置变更
        try FileLock.withLock(FileLock.lockPath(for: fileURL.path)) {
            var obj: [String: Any] = ["useCC": cc, "useGrok": grok, "useCPA": cpa, "useDSH": dsh, "cpaResident": resident, "proxy": proxy]
            if let path, !path.isEmpty { obj["cpaConfigPath"] = path }
            if let mgmtKey, !mgmtKey.isEmpty { obj["cpaManagementKey"] = mgmtKey }
            if let apiBase, !apiBase.isEmpty { obj["cpaAPIBase"] = apiBase }
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: fileURL.deletingLastPathComponent().path
            )
            let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
            let tmp = fileURL.appendingPathExtension("tmp-\(UUID().uuidString.prefix(8))")
            try data.write(to: tmp, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: fileURL)
            }
        }
    }
}

// MARK: - 分区辅助:用户配置的模型是否全军覆没

public extension HistoryEntry {
    /// 条目自己配置的模型是否「全部限流/失败」:每个配置模型的最新探测点都存在且全红。
    ///
    /// key 级 health=ok 只说明网关上「某个」模型能通 —— 哪怕通的不是用户配置的。
    /// 真实反馈(ed0d76a6):条目只配了 glm-5.3-flash,它连续 6 轮 429,但网关上
    /// 未配置的 nemotron 能通 → key 级判 ok → 条目躺在可用区,对用户却是纯坏消息。
    /// 分区/横幅必须以「用户配置的模型」为准;未采集的模型不算数(轮换中,不误伤)
    var allConfiguredModelsLimited: Bool {
        let configured = models ?? (model.map { [$0] } ?? [])
        guard !configured.isEmpty else { return false }
        let log = modelProbeLog ?? [:]
        return configured.allSatisfy { m in
            guard let last = log[m]?.last else { return false }
            return !last.ok
        }
    }
}
