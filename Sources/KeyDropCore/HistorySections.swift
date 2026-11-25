import Foundation

/// 一份历史快照只排序一次,各分区互斥。搜索条件预先分词,不在每行重新解析。
public struct HistorySections {
    public private(set) var available: [HistoryEntry] = []
    public private(set) var attention: [HistoryEntry] = []
    public private(set) var unverified: [HistoryEntry] = []
    public private(set) var quota: [HistoryEntry] = []
    public private(set) var dead: [HistoryEntry] = []
    public private(set) var okCount = 0
    public private(set) var warnCount = 0

    public init(_ entries: [HistoryEntry], query: String = "", limit: Int = .max) {
        let terms = query.lowercased().split(whereSeparator: { $0.isWhitespace })
        let limit = max(0, limit)
        for e in entries.filter({ $0.status == "active" }).sorted(by: { $0.ts > $1.ts }) {
            let availability = e.availability
            if availability == .chainError || availability == .partial || availability == .retry || availability == .syncError || availability == .poolPartial {
                warnCount += 1
            } else if availability == .available || availability == .proxyAvailable {
                okCount += 1
            }
            if !terms.isEmpty {
                let haystack = ([e.id, e.name, e.url, e.keyMasked, e.model] + (e.models ?? []))
                    .compactMap { $0 }.joined(separator: " ").lowercased()
                guard terms.allSatisfy({ haystack.contains($0) }) else { continue }
            }
            switch availability {
            case .dead, .error:
                if dead.count < limit { dead.append(e) }
            case .quota:
                if quota.count < limit { quota.append(e) }
            case .available, .proxyAvailable:
                if available.count < limit { available.append(e) }
            case .partial, .chainError, .retry, .syncError, .poolPartial:
                if attention.count < limit { attention.append(e) }
            case .unverified, .reachable, .dshOnly, .chainUnverified:
                if unverified.count < limit { unverified.append(e) }
            case .inactive: break
            }
        }
    }
}
