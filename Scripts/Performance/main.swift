import Foundation
import KeyDropCore

func oldCap(_ items: [HistoryEntry]) -> [HistoryEntry] {
    var keep = items
    var index = keep.count - 1
    while keep.count > 500, index >= 0 {
        if keep[index].status != "active" || keep[index].targets.isEmpty { keep.remove(at: index) }
        index -= 1
    }
    return keep
}

// 软上限允许保留大量仍有产物的 active 条目;交错墓碑会使旧 remove(at:) 不断搬移数组。
let entries = (0..<20_000).map { i in
    HistoryEntry(id: String(i), ts: Double(20_000 - i), raw: "test", format: "test",
                 name: nil, url: nil, model: nil, models: nil, key: nil, keyMasked: "test",
                 targets: ["cpa"], ccProviderID: nil, ccRenamedFrom: nil, ccRenamedTo: nil,
                 cpaConfigPath: nil, status: i.isMultiple(of: 2) ? "active" : "deleted")
}
func measure(_ body: () -> [HistoryEntry]) -> (Double, [String]) {
    let start = DispatchTime.now().uptimeNanoseconds
    let result = body()
    return (Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000, result.map(\.id))
}
let old = measure { oldCap(entries) }
let new = measure { HistoryStore.applyCap(entries) }
precondition(old.1 == new.1, "裁剪结果与排序必须完全一致")
print(String(format: "20,000 entries, old %.2f ms, new %.2f ms, %.1fx", old.0, new.0, old.0 / new.0))
