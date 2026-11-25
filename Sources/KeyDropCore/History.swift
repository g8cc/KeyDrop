import Foundation
import Darwin
import CryptoKit

/// 单次探测结果点(监控图数据源)。每条目滚动保留最近 30 个点
public struct ProbePoint: Codable, Equatable {
    public var t: TimeInterval
    public var ms: Double?
    public var ok: Bool
    /// CPA 链路探测结果(nil=该轮未测/无 cpa 目标)
    public var cpa: Bool?
    /// 被测地址、凭据及协议的摘要，不存储额外密钥明文。
    public var configurationID: String? = nil

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
        case deletedAt
        case updatedAt
        case verifyVerdict
        case verifyVerdicts
        case dshMissingAt
        case latencyMs, failStreak, viaCPAOk, viaCPAAt
        case probeLog
        case modelProbeLog
        case apiStyle, poolKeys, legacyProbeInvalidated, magpieDestinationID, targetSyncErrors, poolProbeLog
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
    /// 多 key 导入经过认证筛选后实际写入的凭据；nil 表示旧账本尚未确认。
    public var poolKeys: [String]? = nil
    public var magpieDestinationID: String? = nil
    public var targetSyncErrors: [String: String]? = nil
    public var legacyProbeInvalidated: Bool? = nil
    /// 每个池成员各模型的最新实测；索引是凭据摘要。
    public var poolProbeLog: [String: [String: ProbePoint]]? = nil

    public var isCredentialPool: Bool { poolKeys != nil || format == "cpa-multikey" }

    /// 凭据身份、删除和重放共用这一来源。显式空池不能回退 raw 中被拒绝的 key。
    /// 兼容旧版池轮换留下的 key + poolKeys/raw:单 key 是原池首项的替换值，
    /// 其余成员仍属于本条目，旧首项不得在重放时复活。
    public var credentialKeys: [String] {
        let explicitKey = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates: [String]
        if let poolKeys {
            candidates = poolKeys
        } else if isCredentialPool || explicitKey?.isEmpty != false {
            candidates = Parser.extractAllKeys(raw)
            if candidates.isEmpty, let parsed = try? Parser.parse(raw), let key = parsed.key {
                candidates = [key]
            }
        } else {
            candidates = []
        }
        if let explicitKey, !explicitKey.isEmpty {
            candidates = isCredentialPool ? [explicitKey] + candidates.dropFirst() : [explicitKey]
        }
        var seen = Set<String>()
        return candidates.compactMap {
            let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return !value.isEmpty && seen.insert(value).inserted ? value : nil
        }
    }
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
    /// 进入已删除状态的时间;账本压实(超期转审计桩)据此计龄,缺失时回退 healthAt/ts
    public var deletedAt: TimeInterval?
    /// 最后修改时间(HistoryStore.append/update 自动盖章):多设备同步的 LWW 依据
    public var updatedAt: TimeInterval?
    /// 最近一次真伪鉴定的能力层级结论(旗舰级/中端级/基础级/异常);面板行图标着色与悬停展示
    public var verifyVerdict: String?
    /// 每模型的真伪鉴定结论(模型 → 判定):多模型条目逐模型鉴定后各自留存
    public var verifyVerdicts: [String: String]? = nil
    /// DSH 认领路由在 settings.yaml 中首次发现缺失的时间:
    /// reconcileDSH 据此判定「缺失持续 ≥3 天 → 用户已放弃,自动摘除 dsh 标」
    public var dshMissingAt: TimeInterval? = nil
    /// 最近一次 chat 探测的端到端延迟(毫秒)。实战监控:慢网关也显示"可用",
    /// 但延迟让用户对"用的时候行不行"有预期(真实反馈:显示可用,用起来 30s 无响应)
    public var latencyMs: Double?
    /// 连续探测失败次数(成功即清零)。防抖:单次网络抖动不降级状态,
    /// 连续 ≥2 次才把 health 从 ok 改为 err/dead
    public var failStreak: Int?
    /// CPA 链路最近一轮实测结果(本轮请求的所选模型全部通过)。nil=未测/无 cpa 目标。
    /// 健康测试直连上游,但用户真实请求走 CPA —— 上游 OK ≠ CPA 链路 OK
    public var viaCPAOk: Bool?
    /// CPA 链路探测时间
    public var viaCPAAt: TimeInterval?
    /// 探测历史(监控图数据源),滚动保留最近 30 个点
    public var probeLog: [ProbePoint]?
    /// 模型级探测历史(模型级监控):模型名 → 各自的 30 点轨迹。
    /// key 级 probeLog 回答"这把 key 整体好不好",这里回答"每个模型分别好不好"
    public var apiStyle: String? = nil
    public var modelProbeLog: [String: [ProbePoint]]?

    public var probeConfigurationID: String {
        let values = [Parser.normalizeURL(url ?? "") ?? url ?? "", apiStyle ?? "openai",
                      targets.contains("cpa") ? (cpaConfigPath ?? "cpa") : ""] + credentialKeys
        let data = (try? JSONEncoder().encode(values)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public func scopedProbePoints(_ points: [String: ProbePoint]) -> [String: ProbePoint] {
        let id = probeConfigurationID
        return points.mapValues { point in
            var point = point; point.configurationID = id; return point
        }
    }

    public static func credentialID(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public var credentialStatus: ModelStatus {
        let keys = credentialKeys
        let scope = probeConfigurationID
        let models = configuredModels.filter { !Core.isNonChatModel($0) }
        var passed = 0, failed = 0
        for key in keys {
            let points = poolProbeLog?[Self.credentialID(key)] ?? [:]
            let current = models.compactMap { points[$0] }.filter { $0.configurationID == scope }
            if current.contains(where: { !$0.ok }) { failed += 1 }
            else if !models.isEmpty, current.count == models.count { passed += 1 }
        }
        return ModelStatus(total: keys.count, passed: passed, failed: failed)
    }

    public var credentialStatusLabel: String? {
        guard isCredentialPool, credentialKeys.count > 1 else { return nil }
        let status = credentialStatus
        return "凭据：\(status.passed)/\(status.total) 通过 · \(status.failed) 失败 · \(status.untested) 未完成验证"
    }

    /// 默认模型也属于当前配置；空 models 数组不能遮住它。保序去重供探测和 UI 共用。
    public var configuredModels: [String] {
        var values = models ?? []
        if let model, !values.contains(model) { values.insert(model, at: 0) }
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    public struct ModelStatus {
        public let total: Int
        public let passed: Int
        public let failed: Int
        public var untested: Int { total - passed - failed }
        public var label: String {
            "模型：\(passed)/\(total) 通过" + (failed > 0 ? " · \(failed) 失败" : "")
                + (untested > 0 ? " · \(untested) 未验证" : "")
        }
    }

    /// 当前状态看各模型最新一次实测，历史通过率不参与分组。
    public var modelStatus: ModelStatus {
        var passed = 0, failed = 0
        let configured = configuredModels
        let scope = probeConfigurationID
        for model in configured {
            guard let last = modelProbeLog?[model]?.max(by: { $0.t < $1.t }) else { continue }
            guard last.configurationID == scope || (last.configurationID == nil && legacyProbeInvalidated != true) else { continue }
            if !last.ok || (targets.contains("cpa") && last.cpa == false) { failed += 1 }
            else if targets.contains("cpa"), !Core.isNonChatModel(model), last.cpa == nil { continue }
            else { passed += 1 }
        }
        return ModelStatus(total: configured.count, passed: passed, failed: failed)
    }

    /// uptime 百分比(status page 行业指标):已采集周期中通过的占比。
    /// 只按已采集格算(灰格不拉低),nil=尚无采集数据
    public var uptimePercent: Int? {
        guard let log = probeLog, !log.isEmpty else { return nil }
        let ok = log.filter { $0.ok && $0.cpa != false }.count
        return Int((Double(ok) / Double(log.count) * 100).rounded())
    }

    /// 模型级 uptime:模型名 → 百分比(只含有采集数据的模型)
    public var modelUptimes: [String: Int] {
        var out: [String: Int] = [:]
        for (m, log) in modelProbeLog ?? [:] where !log.isEmpty {
            let ok = log.filter { $0.ok && $0.cpa != false }.count
            out[m] = Int((Double(ok) / Double(log.count) * 100).rounded())
        }
        return out
    }

    /// 面板行 hover 提示:信息密度优先的多行摘要(界面行本身保持紧凑)。
    /// 纯逻辑便于测试;时间统一 MM-dd HH:mm
    public var richTooltip: String {
        var lines: [String] = []
        var head = url ?? "(无 URL)"
        let ms = models ?? (model.map { [$0] }) ?? []
        if !ms.isEmpty {
            let shown = ms.prefix(8).joined(separator: " / ")
            head += "\n模型: \(shown)" + (ms.count > 8 ? " 等 \(ms.count) 个" : "")
        }
        lines.append(head)
        lines.append("key: \(keyMasked)\(key == nil && format == "cpa-multikey" ? "(多 key 条目)" : "")")
        let label = status == "deleted" ? "已删除" : (status == "error" ? "导入失败" : availability.label)
        var statusLine = "状态: \(label)"
        if let d = displayHealthDetail, !d.isEmpty { statusLine += " · \(String(d.prefix(140)))" }
        lines.append(statusLine)
        var bits: [String] = []
        if let at = healthAt { bits.append("验证 \(Self.shortTime(at))") }
        if let l = latencyMs, l.isFinite, l >= 0, l < 1e9 { bits.append("延迟 \(Int(l))ms") }
        if let up = uptimePercent { bits.append("uptime \(up)%") }
        if let n = failStreak, n > 0 { bits.append("连续失败 \(n) 次，等待复测") }
        if !bits.isEmpty { lines.append(bits.joined(separator: " · ")) }
        if !configuredModels.isEmpty { lines.append(modelStatus.label) }
        if let cpa = viaCPAOk, targets.contains("cpa") {
            let at = viaCPAAt.map { Self.shortTime($0) } ?? ""
            lines.append("CPA 链路: \(cpa ? "✓ 正常" : "✗ 异常(上游 OK ≠ 经 8317 的真实链路 OK)")\(at.isEmpty ? "" : " · \(at)")")
            lines.append("CPA 为模型路由验证，可能转发到其他同名上游；不代表每把池内 key 均通过")
        }
        for (target, error) in (targetSyncErrors ?? [:]).sorted(by: { $0.key < $1.key }) where targets.contains(target) {
            lines.append("\(target) 同步待重试：\(error)")
        }
        if let credentialStatusLabel { lines.append(credentialStatusLabel) }
        if ccMissing == true { lines.append("⚠ cc-switch 中 provider 已缺失但 key 可用,可点行内 ↺ 重新导入") }
        if let vv = verifyVerdicts, !vv.isEmpty {
            let parts = vv.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
            lines.append("真伪鉴定(能力阶梯实测): " + parts.joined(separator: " · "))
        } else if let v = verifyVerdict {
            lines.append("真伪鉴定: \(v)")
        }
        if let n = note, !n.isEmpty { lines.append("备注: \(String(n.prefix(200)))") }
        lines.append("写入: \(Self.targetLabels(targets).joined(separator: " · "))")
        lines.append("ID \(id.prefix(8)) · 导入 \(Self.shortTime(ts)) · \(format)")
        return lines.joined(separator: "\n")
    }

    public var displayHealthDetail: String? {
        guard let healthDetail else { return nil }
        guard let key, !key.isEmpty else { return healthDetail }
        return healthDetail.replacingOccurrences(of: key, with: "•••")
    }

    static func targetLabels(_ targets: [String]) -> [String] {
        targets.map { t in
            if t == "ccswitch" { return "cc-switch(Claude)" }
            if t.hasPrefix("ccswitch-") { return "cc-switch(\(t.dropFirst("ccswitch-".count)))" }
            switch t {
            case "cpa": return "CPA"
            case "magpie": return "Magpie"
            case "dsh": return "DeepSeek Harness"
            case "grok": return "Grok Build"
            case "clash": return "Clash"
            default: return t
            }
        }
    }

    static func shortTime(_ t: TimeInterval) -> String {
        timeFormatter.string(from: Date(timeIntervalSince1970: t))
    }

    public var isDSHOnly: Bool { format == "dsh-only" }

    public enum Availability: Equatable {
        case unverified, reachable, available, proxyAvailable, partial, retry, quota, error, chainError, chainUnverified, syncError, poolPartial, dead, dshOnly, inactive

        public var label: String {
            switch self {
            case .unverified: return "尚无可用性验证"
            case .reachable: return "网关可达，模型尚未验证"
            case .available: return "最近一次探测通过"
            case .proxyAvailable: return "经代理探测通过"
            case .partial: return "部分模型通过，其他失败或未验证"
            case .retry: return "最近一次探测失败，待复测"
            case .quota: return "额度用尽"
            case .error: return "探测失败"
            case .chainError: return "上游通过，最近一次 CPA 链路探测失败"
            case .chainUnverified: return "上游通过，CPA 链路待验证"
            case .syncError: return "目标配置同步失败，需重试"
            case .poolPartial: return "凭据池尚未全部验证通过"
            case .dead: return "接口拒绝认证"
            case .dshOnly: return "DSH 专用，请在 DSH 内验证"
            case .inactive: return "记录已停用"
            }
        }
    }

    public var availability: Availability {
        guard status == "active" else { return .inactive }
        if isDSHOnly { return .dshOnly }
        if (targetSyncErrors ?? [:]).keys.contains(where: { targets.contains($0) }) { return .syncError }
        if isCredentialPool, credentialKeys.count > 1 {
            let credentials = credentialStatus
            if credentials.failed == credentials.total { return .error }
            if credentials.passed < credentials.total { return .poolPartial }
        }
        switch health {
        case "dead": return .dead
        case "err": return .error
        case "quota": return .quota
        case "reachable": return .reachable
        case "ok", "proxy-ok":
            if (failStreak ?? 0) > 0 { return .retry }
            guard healthAt != nil else { return .unverified }
            if targets.contains("cpa"), viaCPAOk == false { return .chainError }
            let models = modelStatus
            if models.total > 0 {
                if models.failed == models.total { return .error }
                if models.passed == 0 {
                    return models.failed > 0 ? .retry : (targets.contains("cpa") ? .chainUnverified : .unverified)
                }
                if models.passed < models.total { return .partial }
            }
            if models.total == 0, targets.contains("cpa"), viaCPAOk == nil { return .chainUnverified }
            return health == "proxy-ok" ? .proxyAvailable : .available
        default: return .unverified
        }
    }

    public var healthColor: (ok: Bool, dead: Bool) {
        (availability == .available || availability == .proxyAvailable, availability == .dead)
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
        deletedAt: TimeInterval? = nil,
        updatedAt: TimeInterval? = nil,
        verifyVerdict: String? = nil,
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
        self.deletedAt = deletedAt
        self.updatedAt = updatedAt
        self.verifyVerdict = verifyVerdict
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
        poolKeys = try c.decodeIfPresent([String].self, forKey: .poolKeys)
        legacyProbeInvalidated = try c.decodeIfPresent(Bool.self, forKey: .legacyProbeInvalidated)
        magpieDestinationID = try c.decodeIfPresent(String.self, forKey: .magpieDestinationID)
        targetSyncErrors = try c.decodeIfPresent([String: String].self, forKey: .targetSyncErrors)
        poolProbeLog = try c.decodeIfPresent([String: [String: ProbePoint]].self, forKey: .poolProbeLog)
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
        deletedAt = try c.decodeIfPresent(TimeInterval.self, forKey: .deletedAt)
        updatedAt = try c.decodeIfPresent(TimeInterval.self, forKey: .updatedAt)
        verifyVerdict = try c.decodeIfPresent(String.self, forKey: .verifyVerdict)
        verifyVerdicts = try c.decodeIfPresent([String: String].self, forKey: .verifyVerdicts)
        dshMissingAt = try c.decodeIfPresent(TimeInterval.self, forKey: .dshMissingAt)
        latencyMs = try c.decodeIfPresent(Double.self, forKey: .latencyMs)
        failStreak = try c.decodeIfPresent(Int.self, forKey: .failStreak)
        viaCPAOk = try c.decodeIfPresent(Bool.self, forKey: .viaCPAOk)
        viaCPAAt = try c.decodeIfPresent(TimeInterval.self, forKey: .viaCPAAt)
        probeLog = try c.decodeIfPresent([ProbePoint].self, forKey: .probeLog)
        apiStyle = try c.decodeIfPresent(String.self, forKey: .apiStyle)
        modelProbeLog = try c.decodeIfPresent([String: [ProbePoint]].self, forKey: .modelProbeLog)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(apiStyle, forKey: .apiStyle)
        try c.encode(id, forKey: .id)
        try c.encode(ts, forKey: .ts)
        try c.encode(raw, forKey: .raw)
        try c.encode(format, forKey: .format)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(url, forKey: .url)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(models, forKey: .models)
        try c.encodeIfPresent(key, forKey: .key)
        try c.encodeIfPresent(poolKeys, forKey: .poolKeys)
        try c.encodeIfPresent(legacyProbeInvalidated, forKey: .legacyProbeInvalidated)
        try c.encodeIfPresent(magpieDestinationID, forKey: .magpieDestinationID)
        try c.encodeIfPresent(targetSyncErrors, forKey: .targetSyncErrors)
        try c.encodeIfPresent(poolProbeLog, forKey: .poolProbeLog)
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
        try c.encodeIfPresent(deletedAt, forKey: .deletedAt)
        try c.encodeIfPresent(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(verifyVerdict, forKey: .verifyVerdict)
        try c.encodeIfPresent(verifyVerdicts, forKey: .verifyVerdicts)
        try c.encodeIfPresent(dshMissingAt, forKey: .dshMissingAt)
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
    public static let shared = HistoryStore()
    private static let maxHistoryBytes = 64_000_000

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
    /// 上次解析失败的时间。解析失败期间(文件持续损坏)不更新 lastMtime 会反复重读 +
    /// 全量解码失败(最多 64MB),这是最热的读路径 —— 按 5s 退避,期间沿用内存快照
    private var lastParseFailureAt: TimeInterval? = nil
    /// 内容代次:每次真正消费文件内容(mtime 变化后重载)自增。
    /// 目录监听用它判定「外部变更已消费」,驱动 onExternalChange
    private var dataGeneration = 0

    /// 外部变更回调:CLI/另一进程/WebDAV 拉取写入 history.json 后触发。
    /// 可能在任意后台队列调用,消费方自行跳主线程。nil 时不挂监听
    public var onExternalChange: (() -> Void)? = nil
    private var dirSource: DispatchSourceFileSystemObject? = nil
    private var watchedDirPath: String? = nil
    private var pendingExternalCheck = false

    /// 监听账本【目录】而非文件:history.json 每次保存都 replaceItemAt 换 inode,
    /// 文件 fd 在第一次保存后就指向旧 inode,事件从此静默失效。
    /// 自身写盘也会触发事件,但到点后走 mtime 对账判定「无外部变更」而跳过,无害
    private func startDirectoryWatcherLocked() {
        let dir = storeDir.path
        if dirSource != nil, watchedDirPath == dir { return }
        // 首次运行时 ~/.keydrop 尚不存在,open 会失败、监听从此静默缺失
        // (目录要等第一次 save 才创建)。挂监听前先补建
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        dirSource?.cancel()
        dirSource = nil
        let fd = open(dir, O_EVTONLY)
        guard fd >= 0 else { return }
        watchedDirPath = dir
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write,
            queue: DispatchQueue(label: "keydrop.history.watch", qos: .utility))
        src.setEventHandler { [weak self] in self?.scheduleExternalCheck() }
        src.setCancelHandler { close(fd) }
        src.resume()
        dirSource = src
    }

    private func scheduleExternalCheck() {
        guard !pendingExternalCheck else { return }
        pendingExternalCheck = true
        // 合并 0.4s 内的连续事件(批量写盘连发);到点后 mtime 对账,真有新内容才通知
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            self.pendingExternalCheck = false
            var changed = false
            self.lock.lock()
            self.startDirectoryWatcherLocked()   // KEYDROP_HOME 变更(测试隔离)后重挂
            let genBefore = self.dataGeneration
            self.refreshIfExternalChangeLocked()
            changed = self.dataGeneration != genBefore
            self.lock.unlock()
            if changed { self.onExternalChange?() }
        }
    }

    /// 非线程安全快照入口;UI/CLI 请用 snapshot()
    var items: [HistoryEntry] { snapshot() }

    public init() {
        load()
        lock.lock()
        startDirectoryWatcherLocked()
        lock.unlock()
    }

    deinit {
        // 测试环境每个套件都会建实例:监听不 cancel 会泄漏目录 fd 与事件源
        dirSource?.cancel()
    }

    public func snapshot() -> [HistoryEntry] {
        lock.lock(); defer { lock.unlock() }
        refreshIfExternalChangeLocked()
        return _items
    }

    /// 锁内调用:文件被其他进程改过(mtime 变化)→ 重读进内存
    private func refreshIfExternalChangeLocked() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let mtime = attrs[.modificationDate] as? Date else { return }
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
        // 退避必须发生在读盘/解码之前,否则每次 UI 刷新仍会重做昂贵的失败解码。
        if let failed = lastParseFailureAt, Date().timeIntervalSince1970 - failed < 5 { return }
        // 记录进入时的 mtime:仅当本轮真正消费了文件内容才更新 lastMtime,
        // 否则解析失败后外部把文件修好,也会因 mtime 未变而被跳过、永远读不进来
        let currentMtime = mtime
        guard let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? Int,
              size <= Self.maxHistoryBytes,
              let data = try? Data(contentsOf: fileURL),
              data.count <= Self.maxHistoryBytes else {
            // 读失败 ≠ 文件为空,可能是磁盘满/权限瞬时故障;保留内存快照,
            // 且不更新 lastMtime,下轮 snapshot 时 mtime 未变会自动重试
            Logger.warn("history 文件读取失败或过大,保留内存快照: \(fileURL.path)")
            return
        }
        struct Wrapper: Codable { var items: [HistoryEntry] }
        if data.isEmpty {
            // 只有确认是空文件才清空内存(首次初始化场景);同样视为已消费,更新 mtime,
            // 否则 snapshot 每轮都会因 mtime 未变未更新而反复重读空文件
            _items = []; loadedIDs = []
            lastMtime = currentMtime
            dataGeneration += 1
        } else if let w = try? JSONDecoder().decode(Wrapper.self, from: data) {
            _items = w.items
            loadedIDs = Set(w.items.map { $0.id })
            lastMtime = currentMtime
            lastParseFailureAt = nil   // 成功消费后清除退避,后续失败立即重试
            dataGeneration += 1
        } else {
            // 解析失败:很可能是 CLI 写到一半被并发读到(partial JSON)。保留上一份内存,不要清空,
            // 否则 mtime 刷新路径下 UI 会出现短暂的「历史清空」闪动。
            // 5s 退避:文件持续损坏期间 snapshot 每次都重读+解码失败(最热读路径)
            let now = Date().timeIntervalSince1970
            if let f = lastParseFailureAt, now - f < 5 { return }
            lastParseFailureAt = now
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

    /// Validate the disk snapshot before a write, even when the read path has cached data.
    private func readHistoryForWrite() throws -> [HistoryEntry]? {
        struct Wrapper: Decodable { var items: [HistoryEntry] }
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            guard let size = attrs[.size] as? Int, size <= Self.maxHistoryBytes else {
                throw ParseError.io("账本文件过大，已保留原文件")
            }
            let data = try Data(contentsOf: fileURL)
            guard data.count <= Self.maxHistoryBytes,
                  let wrapper = try? JSONDecoder().decode(Wrapper.self, from: data) else {
                throw ParseError.io("账本文件无法解析，已保留原文件")
            }
            return wrapper.items
        } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError) {
            return nil
        }
    }

    private func saveLockedNoFlock(dirtyIDs: Set<String>) throws {
        struct Wrapper: Codable { var items: [HistoryEntry] }
        var merged = _items
        // 文件从存在变为缺失 = 其他进程/用户清空了历史。防复活规则同样适用:
        // 本会话已落盘过的条目不复活,只保留本次调用新增(非 loadedIDs)的脏条目。
        // 仅在文件确实不存在时触发;文件存在但读失败(瞬时 IO 错误)不动内存。
        let onDisk = try readHistoryForWrite()
        if onDisk == nil, lastMtime != nil {
            merged = merged.filter { !loadedIDs.contains($0.id) }
        } else if let items = onDisk {
            let fileIDs = Set(items.map { $0.id })
            let memIDs = Set(merged.map { $0.id })
            // 文件 mtime 晚于我们上次消费的时间 = 其他进程改过:非脏同 id 条目以文件版为准,
            // 否则内存里的旧版本会把 CLI 刚改的 status/health 静默回滚
            var externalChanged = false
            if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
               let mtime = attrs[.modificationDate] as? Date, mtime != lastMtime {
                externalChanged = true
            }
            merged = merged.filter { e in
                guard fileIDs.contains(e.id) else { return !loadedIDs.contains(e.id) }
                if dirtyIDs.contains(e.id) { return true }
                return !externalChanged
            } + items.filter { wItem in
                // 外部变更时,被丢弃的非脏同 id 内存条目必须用文件版补回,
                // 否则条目凭空消失;脏条目(本次刚改)保持内存版,不回填文件旧版
                !memIDs.contains(wItem.id) || (externalChanged && !dirtyIDs.contains(wItem.id))
            }
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
        // replaceItemAt 保留【原文件】的权限:历史文件若在旧版本/手工操作下是 0644,
        // 上面给 tmp 设的 0600 会被丢弃,含明文 key 的 history.json 从此长期可读。
        // 落盘后再收紧一次(与 ImageChannelStore.save 同一处理)。
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
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
        var e = e
        e.updatedAt = Date().timeIntervalSince1970
        let previous = _items
        _items.insert(e, at: 0)
        _items = Self.applyCap(_items)
        do { try saveLocked(dirtyIDs: [e.id]) }
        catch { _items = previous; throw error }
    }

    /// 历史上限 500,但绝不丢弃仍持有外部产物写入凭据的 active 条目:
    /// 账本不变量要求每个 cc-switch provider / CPA key / Grok route 至少有一条历史指向它,
    /// 静默裁剪 active 条目会让这些外部产物变孤儿 —— 删不掉、对账不认领。
    /// 输入按 ts desc:优先从尾部丢弃 deleted / 无 target 条目,凑不够额就保留 active
    /// (宁可软超限也不制造孤儿)。结果保持 ts desc,不改变 list/snapshot 顺序
    public static func applyCap(_ items: [HistoryEntry]) -> [HistoryEntry] {
        guard items.count > 500 else { return items }
        var toRemove = items.count - 500
        var kept: [HistoryEntry] = []
        kept.reserveCapacity(items.count)
        for e in items.reversed() {
            // 近期墓碑豁免(60 天):墓碑是「已删 key 不复活」不变量的载体,
            // 被裁后 localTombstoneKeys 失效 → 维护者再推 active 版原样收下(凭据复活)
            let isRecentTombstone = e.status == "deleted" && {
                let t = e.deletedAt ?? e.healthAt ?? e.ts
                return Date().timeIntervalSince1970 - t < 60 * 24 * 3600
            }()
            if toRemove > 0, !isRecentTombstone, e.status != "active" || e.targets.isEmpty {
                toRemove -= 1
            } else {
                kept.append(e)
            }
        }
        return Array(kept.reversed())
    }

    public func update(_ e: HistoryEntry) throws {
        lock.lock()
        defer { lock.unlock() }
        try FileLock.withLock(FileLock.lockPath(for: fileURL.path)) {
            refreshIfExternalChangeLocked()
            guard let i = _items.firstIndex(where: { $0.id == e.id }) else { return }
            var merged = e
            if _items[i].probeConfigurationID != e.probeConfigurationID { merged.legacyProbeInvalidated = true }
            else if _items[i].legacyProbeInvalidated == true { merged.legacyProbeInvalidated = true }
            merged.updatedAt = Date().timeIntervalSince1970
            // probeLog 是监控账本,归 store 所有:调用方的 entry 快照可能早于最新探测点
            // (refreshModels 先 appendProbePoint 再 update 整条),整条覆盖会回滚监控历史
            merged.probeLog = _items[i].probeLog
            merged.modelProbeLog = _items[i].modelProbeLog
            merged.poolProbeLog = Self.mergedPoolEvidence(current: _items[i].poolProbeLog, incoming: e.poolProbeLog, for: merged)
            let previous = _items[i]
            _items[i] = merged
            do { try saveLockedNoFlock(dirtyIDs: [e.id]) }
            catch { _items[i] = previous; throw error }
        }
    }

    private static func mergedPoolEvidence(current: [String: [String: ProbePoint]]?,
                                           incoming: [String: [String: ProbePoint]]?,
                                           for entry: HistoryEntry) -> [String: [String: ProbePoint]]? {
        guard current != nil || incoming != nil else { return nil }
        let scope = entry.probeConfigurationID
        let validIDs = Set(entry.credentialKeys.map(HistoryEntry.credentialID))
        var log: [String: [String: ProbePoint]] = [:]
        for source in [current, incoming] {
            for (key, models) in source ?? [:] where validIDs.contains(key) {
                for (model, point) in models where point.configurationID == scope {
                    if let old = log[key]?[model], old.t >= point.t { continue }
                    log[key, default: [:]][model] = point
                }
            }
        }
        return log
    }

    private static func sameProbeConfiguration(_ current: HistoryEntry, _ tested: HistoryEntry) -> Bool {
        current.status == "active" && !current.isDSHOnly &&
            current.format == tested.format && current.url == tested.url && current.key == tested.key &&
            current.credentialKeys == tested.credentialKeys &&
            current.model == tested.model && current.models == tested.models &&
            current.targets.contains("cpa") == tested.targets.contains("cpa") &&
            current.cpaConfigPath == tested.cpaConfigPath
    }

    /// 只在被测配置仍有效时，合并对账产生的字段，保留同时发生的用户编辑。
    @discardableResult
    func mergeCCReconciliation(tested: HistoryEntry, health: String, detail: String,
                               authFailed: Bool, note: String, point: ProbePoint?,
                               modelPoints: [String: ProbePoint] = [:]) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return try FileLock.withLock(FileLock.lockPath(for: fileURL.path)) {
            refreshIfExternalChangeLocked()
            guard let i = _items.firstIndex(where: { $0.id == tested.id }) else { return false }
            let current = _items[i]
            guard Self.sameProbeConfiguration(current, tested),
                  current.ccProviderID == tested.ccProviderID, current.targets == tested.targets,
                  current.ccMissing == tested.ccMissing, current.healthAt == tested.healthAt else { return false }
            let now = point?.t ?? Date().timeIntervalSince1970
            var updated = current
            if authFailed {
                updated.targets.removeAll { $0.hasPrefix("ccswitch") }
                if updated.targets.isEmpty {
                    updated.status = "deleted"
                    updated.deletedAt = current.deletedAt ?? now
                }
            } else {
                updated.ccMissing = true
            }
            if !(updated.note ?? "").components(separatedBy: "; ").contains(note) {
                updated.note = [updated.note, note].compactMap { $0 }.joined(separator: "; ")
            }
            updated.health = health
            updated.healthDetail = detail
            updated.healthAt = now
            updated.failStreak = nil
            updated.latencyMs = point?.ms
            updated.updatedAt = max(current.updatedAt ?? 0, now)
            if let point {
                updated.probeLog = Array(((updated.probeLog ?? []) + [point]).suffix(30))
            }
            if !modelPoints.isEmpty {
                var log = updated.modelProbeLog ?? [:]
                for (model, point) in modelPoints {
                    log[model] = Array(((log[model] ?? []) + [point]).suffix(30))
                }
                updated.modelProbeLog = log
            }
            _items[i] = updated
            do { try saveLockedNoFlock(dirtyIDs: [current.id]) }
            catch { _items[i] = current; throw error }
            return true
        }
    }

    /// 批量合并本轮的探测字段。过时的结果在读写同一把文件锁内丢弃。
    public func mergeHealth(_ entries: [HistoryEntry], at: TimeInterval, testedConfigurations: [String: String] = [:]) throws {
        lock.lock()
        defer { lock.unlock() }
        try FileLock.withLock(FileLock.lockPath(for: fileURL.path)) {
            refreshIfExternalChangeLocked()
            let indices = Dictionary(_items.enumerated().map { ($0.element.id, $0.offset) },
                                     uniquingKeysWith: { first, _ in first })
            var previous: [(Int, HistoryEntry)] = []
            for e in entries {
                guard let i = indices[e.id], Self.sameProbeConfiguration(_items[i], e),
                      testedConfigurations[e.id].map({ $0 == _items[i].probeConfigurationID }) ?? true,
                      (_items[i].healthAt ?? -.infinity) < at else { continue }
                previous.append((i, _items[i]))
                if _items[i].probeConfigurationID != e.probeConfigurationID { _items[i].legacyProbeInvalidated = true }
                if let style = e.apiStyle { _items[i].apiStyle = style }
                _items[i].health = e.health
                _items[i].healthDetail = e.healthDetail
                _items[i].healthAt = at
                // 实战监控字段随健康扫描一并合并(延迟/防抖/CPA 链路)
                _items[i].latencyMs = e.latencyMs
                _items[i].failStreak = e.failStreak
                _items[i].viaCPAOk = e.viaCPAOk
                _items[i].viaCPAAt = e.viaCPAAt
                _items[i].poolProbeLog = Self.mergedPoolEvidence(current: _items[i].poolProbeLog, incoming: e.poolProbeLog, for: _items[i])
                _items[i].updatedAt = max(_items[i].updatedAt ?? 0, at)
                if e.health != "reachable" {
                    let pt = ProbePoint(t: at, ms: e.latencyMs,
                                        ok: (e.health == "ok" || e.health == "proxy-ok") && (e.failStreak ?? 0) == 0,
                                        cpa: e.viaCPAAt == at ? e.viaCPAOk : nil)
                    _items[i].probeLog = Array(((_items[i].probeLog ?? []) + [pt]).suffix(30))
                }
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
            guard !previous.isEmpty else { return }
            do { try saveLockedNoFlock(dirtyIDs: Set(previous.map { $0.1.id })) }
            catch {
                for (index, entry) in previous { _items[index] = entry }
                throw error
            }
        }
    }

    /// 首个凭据冷却时只合并其他成员的真实采样，不改变首个凭据的健康时间和轨迹。
    public func mergePoolEvidence(_ entries: [HistoryEntry]) throws {
        guard !entries.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        try FileLock.withLock(FileLock.lockPath(for: fileURL.path)) {
            refreshIfExternalChangeLocked()
            var previous: [(Int, HistoryEntry)] = []
            for entry in entries {
                guard let i = _items.firstIndex(where: { $0.id == entry.id }),
                      Self.sameProbeConfiguration(_items[i], entry),
                      _items[i].probeConfigurationID == entry.probeConfigurationID else { continue }
                let scope = _items[i].probeConfigurationID
                let validIDs = Set(_items[i].credentialKeys.map(HistoryEntry.credentialID))
                var log = _items[i].poolProbeLog ?? [:]
                var changed = false
                for (key, models) in entry.poolProbeLog ?? [:] where validIDs.contains(key) {
                    for (model, point) in models where point.configurationID == scope {
                        if let old = log[key]?[model], old.configurationID == scope, old.t >= point.t { continue }
                        log[key, default: [:]][model] = point
                        changed = true
                    }
                }
                guard changed else { continue }
                previous.append((i, _items[i]))
                _items[i].poolProbeLog = log
                _items[i].updatedAt = Date().timeIntervalSince1970
            }
            guard !previous.isEmpty else { return }
            do { try saveLockedNoFlock(dirtyIDs: Set(previous.map { $0.1.id })) }
            catch {
                for (index, entry) in previous { _items[index] = entry }
                throw error
            }
        }
    }

    /// 手动重测(refreshModels)路径追加单个探测点(监控图数据源)
    public func appendProbePoint(id: String, ok: Bool, ms: Double?, cpa: Bool?, at: TimeInterval) throws {
        lock.lock()
        defer { lock.unlock() }
        try FileLock.withLock(FileLock.lockPath(for: fileURL.path)) {
            refreshIfExternalChangeLocked()
            guard let i = _items.firstIndex(where: { $0.id == id }) else { return }
            let previous = _items[i]
            var log = (_items[i].probeLog ?? []) + [ProbePoint(t: at, ms: ms, ok: ok, cpa: cpa)]
            if log.count > 30 { log = Array(log.suffix(30)) }
            _items[i].probeLog = log
            _items[i].updatedAt = Date().timeIntervalSince1970
            do { try saveLockedNoFlock(dirtyIDs: [id]) }
            catch { _items[i] = previous; throw error }
        }
    }

    /// 模型级探测点追加(手动重测/扫描共用)
    public func appendModelProbePoints(id: String, points: [String: ProbePoint]) throws {
        guard !points.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        try FileLock.withLock(FileLock.lockPath(for: fileURL.path)) {
            refreshIfExternalChangeLocked()
            guard let i = _items.firstIndex(where: { $0.id == id }) else { return }
            let previous = _items[i]
            var merged = _items[i].modelProbeLog ?? [:]
            for (m, var pt) in points {
                if pt.configurationID == nil { pt.configurationID = _items[i].probeConfigurationID }
                var arr = (merged[m] ?? []) + [pt]
                if arr.count > 30 { arr = Array(arr.suffix(30)) }
                merged[m] = arr
            }
            _items[i].modelProbeLog = merged
            _items[i].updatedAt = Date().timeIntervalSince1970
            do { try saveLockedNoFlock(dirtyIDs: [id]) }
            catch { _items[i] = previous; throw error }
        }
    }

    /// 批量更新后只落盘一次。健康扫描等高频小更新的场景用这个,
    /// 逐条 update 会把整份历史反复序列化写盘(O(N²) IO 放大)。
    public func updateAll(_ entries: [HistoryEntry]) throws {
        lock.lock()
        defer { lock.unlock() }
        let previous = _items
        for var e in entries {
            if let i = _items.firstIndex(where: { $0.id == e.id }) {
                if _items[i].probeConfigurationID != e.probeConfigurationID || _items[i].legacyProbeInvalidated == true {
                    e.legacyProbeInvalidated = true
                }
                _items[i] = e
            }
        }
        do { try saveLocked(dirtyIDs: Set(entries.map { $0.id })) }
        catch { _items = previous; throw error }
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
            $0.status == "active" && $0.credentialKeys.contains(wantKey)
        }
    }

    /// 原子「查重或插入」。Core.add 的 findActiveByKey 查重与最终 append 之间
    /// 隔着数秒到数十秒的网络测试,CLI 与 app 同时导入同一 key 时双方都查不到
    /// 对方,各建一条重复记录。这里在 flock 临界区内对文件做最终查重:
    /// 命中文件中的 active 同 key 条目 → 返回它(不插入);未命中 → 插入并返回 nil
    public func appendDedupByKey(_ e: HistoryEntry) throws -> HistoryEntry? {
        let incomingKeys = Set(e.credentialKeys)
        func isDup(_ other: HistoryEntry) -> Bool {
            other.status == "active" && other.id != e.id &&
                !incomingKeys.isDisjoint(with: other.credentialKeys)
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
                // 文件侧幸存者必须并入 _items:它只存在于文件,后续 Core 拿它合并产物后
                // 调 update(merged) —— update 对 _items 里查无此 id 的条目静默 no-op,
                // 合并结果将永远不落盘
                if !_items.contains(where: { $0.id == dup.id }) {
                    _items.insert(dup, at: 0)
                    loadedIDs.insert(dup.id)
                }
                return  // 已有同 key 条目:不插入
            }
            let previous = _items
            _items.insert(e, at: 0)
            // 与 append() 同走 applyCap:硬截 prefix(500) 会把尾部仍持有 cc-switch/CPA/Grok
            // 产物的 active 老条目直接丢掉,外部产物成孤儿(删不掉、对账不认领)
            _items = Self.applyCap(_items)
            // 内部直接用 NoFlock 版:外层已持 flock,再走 saveLocked 会二次 flock 自锁
            do { try saveLockedNoFlock(dirtyIDs: [e.id]) }
            catch { _items = previous; throw error }
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
    private static let maxPrefsBytes = 1_000_000

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
    private var _useMagpie = false
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
    public var useMagpie: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _useMagpie }
        set { lock.lock(); _useMagpie = newValue; lock.unlock() }
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
    /// WebDAV 同步:目录 URL / 账号 / 密码 / 账本加密口令(密文上云,口令仅存本机)
    private var _webdavURL: String? = nil
    /// Magpie Web 链接(整条 http://host:port/?k=key),MagpieWriter 自己拆
    private var _magpieWebLink: String? = nil
    private var _webdavUser: String? = nil
    private var _webdavPass: String? = nil
    private var _webdavExportPass: String? = nil
    private var _webdavAutoPull = false
    private var _webdavAutoPush = false
    private var _webdavLastSync: TimeInterval? = nil
    private var _webdavLastPushFP: String? = nil
    private var _webdavETag: String? = nil
    public var webdavURL: String? {
        get { lock.lock(); defer { lock.unlock() }; return _webdavURL }
        set {
            lock.lock(); defer { lock.unlock() }
            if _webdavURL != newValue {
                _webdavETag = nil
                _webdavLastSync = nil
                _webdavLastPushFP = nil
                _webdavURL = newValue
            }
        }
    }
    public var magpieWebLink: String? {
        get { lock.lock(); defer { lock.unlock() }; return _magpieWebLink }
        set { lock.lock(); _magpieWebLink = newValue; lock.unlock() }
    }
    public var webdavUser: String? {
        get { lock.lock(); defer { lock.unlock() }; return _webdavUser }
        set {
            lock.lock(); defer { lock.unlock() }
            if _webdavUser != newValue {
                _webdavETag = nil
                _webdavLastSync = nil
                _webdavLastPushFP = nil
                _webdavUser = newValue
            }
        }
    }
    public var webdavPass: String? {
        get { lock.lock(); defer { lock.unlock() }; return _webdavPass }
        set {
            lock.lock(); defer { lock.unlock() }
            if _webdavPass != newValue {
                _webdavETag = nil
                _webdavLastSync = nil
                _webdavLastPushFP = nil
                _webdavPass = newValue
            }
        }
    }
    public var webdavExportPass: String? {
        get { lock.lock(); defer { lock.unlock() }; return _webdavExportPass }
        set {
            lock.lock(); defer { lock.unlock() }
            if _webdavExportPass != newValue {
                _webdavETag = nil
                _webdavLastSync = nil
                _webdavLastPushFP = nil
                _webdavExportPass = newValue
            }
        }
    }
    public var webdavAutoPull: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _webdavAutoPull }
        set { lock.lock(); _webdavAutoPull = newValue; lock.unlock() }
    }
    public var webdavAutoPush: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _webdavAutoPush }
        set { lock.lock(); _webdavAutoPush = newValue; lock.unlock() }
    }
    public var webdavLastSync: TimeInterval? {
        get { lock.lock(); defer { lock.unlock() }; return _webdavLastSync }
        set { lock.lock(); _webdavLastSync = newValue; lock.unlock() }
    }
    public var webdavLastPushFP: String? {
        get { lock.lock(); defer { lock.unlock() }; return _webdavLastPushFP }
        set { lock.lock(); _webdavLastPushFP = newValue; lock.unlock() }
    }

    var webdavETag: String? {
        get { lock.lock(); defer { lock.unlock() }; return _webdavETag }
        set { lock.lock(); _webdavETag = newValue; lock.unlock() }
    }

    func webdavSettingsSnapshot() -> (url: String?, user: String?, pass: String?, exportPass: String?) {
        lock.lock(); defer { lock.unlock() }
        return (_webdavURL, _webdavUser, _webdavPass, _webdavExportPass)
    }

    /// 测试隔离:TestEnv 每个环境调用一次,把全部偏好重置为默认值。
    /// Prefs.shared 是进程级单例,跨 TestEnv 共享;不重置会让前面套件的
    /// 设置(管理密钥/代理/WebDAV 凭据)泄漏到后面,套件间产生隐式依赖。
    public func resetForTest() {
        lock.lock()
        defer { lock.unlock() }
        _useCC = true
        _useGrok = true
        _useCPA = false
        _useDSH = true
        _useMagpie = false
        _cpaResident = true
        _cpaConfigPath = nil
        _proxy = ""
        _cpaManagementKey = nil
        _cpaAPIBase = nil
        _webdavURL = nil
        _magpieWebLink = nil
        _webdavUser = nil
        _webdavPass = nil
        _webdavExportPass = nil
        _webdavAutoPull = false
        _webdavAutoPush = false
        _webdavLastSync = nil
        _webdavLastPushFP = nil
        _webdavETag = nil
    }

    init() { load() }

    func load() {
        lock.lock(); defer { lock.unlock() }
        if let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? Int,
           size <= Self.maxPrefsBytes,
           let data = try? Data(contentsOf: fileURL),
           data.count <= Self.maxPrefsBytes,
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let v = obj["useCC"] as? Bool { _useCC = v }
            if let v = obj["useGrok"] as? Bool { _useGrok = v }
            if let v = obj["useCPA"] as? Bool { _useCPA = v }
            if let v = obj["useDSH"] as? Bool { _useDSH = v }
            if let v = obj["useMagpie"] as? Bool { _useMagpie = v }
            if let v = obj["cpaResident"] as? Bool { _cpaResident = v }
            _cpaConfigPath = obj["cpaConfigPath"] as? String
            if let v = obj["proxy"] as? String { _proxy = v }
            _cpaManagementKey = obj["cpaManagementKey"] as? String
            _cpaAPIBase = obj["cpaAPIBase"] as? String
            _webdavURL = obj["webdavURL"] as? String
            _magpieWebLink = obj["magpieWebLink"] as? String
            _webdavUser = obj["webdavUser"] as? String
            _webdavPass = obj["webdavPass"] as? String
            _webdavExportPass = obj["webdavExportPass"] as? String
            _webdavAutoPull = obj["webdavAutoPull"] as? Bool ?? false
            _webdavAutoPush = obj["webdavAutoPush"] as? Bool ?? false
            _webdavLastSync = obj["webdavLastSync"] as? TimeInterval
            _webdavLastPushFP = obj["webdavLastPushFP"] as? String
            _webdavETag = obj["webdavETag"] as? String
        }
    }

    public func resolvedCPAConfig() -> String? {
        if let override = ProcessInfo.processInfo.environment["KEYDROP_CPA_CONFIG"],
           CPAAPI.apiMode || FileManager.default.fileExists(atPath: override) {
            return override
        }
        lock.lock()
        let stored = _cpaConfigPath
        lock.unlock()
        // API 模式:path 只作为管理 API 请求的记录参数(服务端用它自己的配置),
        // 严禁对 stored 路径 stat —— Documents 下的路径一次 stat 就可能是一次
        // 「文稿」弹窗(更新换签名使 TCC 授权作废后)。文件模式才需要确认存在。
        if CPAAPI.apiMode {
            // 绝不能回落到 locateConfig():它会对 KEYDROP_CPA_CONFIG / prefs 路径 /
            // 三个默认候选路径逐个 stat,还可能拉起 ps / docker —— 路径在 Documents 下时
            // 每次导入都是一次「文稿」弹窗。API 模式下服务端用自己的配置,
            // 本地路径纯属记录参数,给一个非空占位即可让上层流程继续。
            return stored ?? "(CPA 管理 API)"
        }
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
        let magpie = _useMagpie
        let resident = _cpaResident
        let path = _cpaConfigPath
        let proxy = _proxy
        let mgmtKey = _cpaManagementKey
        let apiBase = _cpaAPIBase
        // WebDAV 字段必须在同一锁内快照:flock 只管跨进程文件写,
        // 管不住本进程 UI 线程写 _webdav* 与这里读的并发
        let webdavURL = _webdavURL
        let magpieWebLink = _magpieWebLink
        let webdavUser = _webdavUser
        let webdavPass = _webdavPass
        let webdavExportPass = _webdavExportPass
        let webdavAutoPull = _webdavAutoPull
        let webdavAutoPush = _webdavAutoPush
        let webdavLastSync = _webdavLastSync
        let webdavLastPushFP = _webdavLastPushFP
        let webdavETag = _webdavETag
        lock.unlock()
        // flock 串行化跨进程写:app 与 CLI 并发 save 时,固定 tmp 路径会被对方
        // replaceItemAt 拽走导致写失败,并发覆盖也会丢掉对方的设置变更
        try FileLock.withLock(FileLock.lockPath(for: fileURL.path)) {
            var obj: [String: Any] = ["useCC": cc, "useGrok": grok, "useCPA": cpa, "useDSH": dsh, "useMagpie": magpie, "cpaResident": resident, "proxy": proxy]
            if let path, !path.isEmpty { obj["cpaConfigPath"] = path }
            if let mgmtKey, !mgmtKey.isEmpty { obj["cpaManagementKey"] = mgmtKey }
            if let apiBase, !apiBase.isEmpty { obj["cpaAPIBase"] = apiBase }
            // WebDAV 同步配置:URL/账号/密码/导出口令(后者用于账本端到端加密,
            // WebDAV 服务端只见密文)。prefs 0600,含凭据与账本同级敏感度
            if let v = webdavURL, !v.isEmpty { obj["webdavURL"] = v }
            if let v = magpieWebLink, !v.isEmpty { obj["magpieWebLink"] = v }
            if let v = webdavUser, !v.isEmpty { obj["webdavUser"] = v }
            if let v = webdavPass, !v.isEmpty { obj["webdavPass"] = v }
            if let v = webdavExportPass, !v.isEmpty { obj["webdavExportPass"] = v }
            obj["webdavAutoPull"] = webdavAutoPull
            obj["webdavAutoPush"] = webdavAutoPush
            if let v = webdavLastSync { obj["webdavLastSync"] = v }
            if let v = webdavLastPushFP { obj["webdavLastPushFP"] = v }
            if let v = webdavETag { obj["webdavETag"] = v }
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
            // replaceItemAt 保留原文件权限:prefs 含 CPA 管理密钥与代理凭据,
            // 原文件若是 0644 则新文件也是 0644。落盘后统一收紧(同 history.save)。
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
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
        let configured = configuredModels
        guard !configured.isEmpty else { return false }
        let log = modelProbeLog ?? [:]
        return configured.allSatisfy { m in
            guard let last = log[m]?.last else { return false }
            return !last.ok
        }
    }
}
