import Foundation

/// 一份历史快照只排序一次,各分区互斥。搜索条件预先分词,不在每行重新解析。
public struct HistorySections {
    public private(set) var available: [HistoryEntry] = []
    public private(set) var quota: [HistoryEntry] = []
    public private(set) var dead: [HistoryEntry] = []
    public private(set) var okCount = 0
    public private(set) var warnCount = 0

    public init(_ entries: [HistoryEntry], query: String = "", limit: Int = 60) {
        let terms = query.lowercased().split(whereSeparator: { $0.isWhitespace })
        let limit = max(0, limit)
        for e in entries.filter({ $0.status == "active" }).sorted(by: { $0.ts > $1.ts }) {
            let isDead = e.health == "dead" || e.health == "err"
            let isQuota = !isDead && (e.health == "quota" || e.allConfiguredModelsLimited)
            if !isDead, !isQuota, e.healthAt != nil, e.health == "ok" || e.health == "proxy-ok" {
                if e.viaCPAOk == false { warnCount += 1 } else { okCount += 1 }
            }
            if !terms.isEmpty {
                let haystack = ([e.name, e.url, e.keyMasked, e.model] + (e.models ?? []))
                    .compactMap { $0 }.joined(separator: " ").lowercased()
                guard terms.allSatisfy({ haystack.contains($0) }) else { continue }
            }
            if isDead {
                if dead.count < limit { dead.append(e) }
            } else if isQuota {
                if quota.count < limit { quota.append(e) }
            } else if available.count < limit {
                available.append(e)
            }
        }
    }
}
