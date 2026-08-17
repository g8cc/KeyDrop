import Foundation
import CSQLite

enum SQLiteError: LocalizedError {
    case open(String)
    case exec(String)
    case query(String)

    var errorDescription: String? {
        switch self {
        case .open(let m): return "SQLite 打开失败: \(m)"
        case .exec(let m): return "SQLite 执行失败: \(m)"
        case .query(let m): return "SQLite 查询失败: \(m)"
        }
    }
}

public final class DB {
    private var handle: OpaquePointer?

    public init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "rc=\(rc)"
            if let handle { sqlite3_close(handle) }
            throw SQLiteError.open("\(path): \(msg)")
        }
        sqlite3_busy_timeout(handle, 8000)
    }

    deinit {
        if let h = handle { sqlite3_close(h) }
    }

    public func exec(_ sql: String) throws {
        var errPtr: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &errPtr)
        if rc != SQLITE_OK {
            let msg = errPtr.map { String(cString: $0) } ?? "rc=\(rc)"
            sqlite3_free(errPtr)
            throw SQLiteError.exec("\(msg) | \(sql.prefix(120))")
        }
    }

    public func run(_ sql: String, _ binds: [Any?] = []) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw SQLiteError.exec(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(s) }
        try bind(stmt: s, binds)
        let rc = sqlite3_step(s)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw SQLiteError.exec(String(cString: sqlite3_errmsg(handle)))
        }
    }

    public func query(_ sql: String, _ binds: [Any?] = []) throws -> [[String?]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw SQLiteError.query(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(s) }
        try bind(stmt: s, binds)
        var rows: [[String?]] = []
        while true {
            let rc = sqlite3_step(s)
            if rc == SQLITE_DONE { break }
            if rc != SQLITE_ROW { throw SQLiteError.query(String(cString: sqlite3_errmsg(handle))) }
            let n = sqlite3_column_count(s)
            var row: [String?] = []
            for i in 0..<n {
                if sqlite3_column_type(s, i) == SQLITE_NULL {
                    row.append(nil)
                } else if let cStr = sqlite3_column_text(s, i) {
                    row.append(String(cString: cStr))
                } else {
                    row.append(nil)
                }
            }
            rows.append(row)
        }
        return rows
    }

    public func scalar(_ sql: String, _ binds: [Any?] = []) throws -> String? {
        try query(sql, binds).first?.first ?? nil
    }

    private func bind(stmt: OpaquePointer, _ binds: [Any?]) throws {
        for (idx, v) in binds.enumerated() {
            let pos = Int32(idx + 1)
            let rc: Int32
            switch v {
            case nil:
                rc = sqlite3_bind_null(stmt, pos)
            case let s as String:
                rc = sqlite3_bind_text(stmt, pos, s, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case let d as Double:
                rc = sqlite3_bind_double(stmt, pos, d)
            case let b as Bool:
                rc = sqlite3_bind_int(stmt, pos, b ? 1 : 0)
            case let i as Int64:
                rc = sqlite3_bind_int64(stmt, pos, i)
            case let i as Int:
                rc = sqlite3_bind_int64(stmt, pos, Int64(i))
            default:
                rc = sqlite3_bind_text(stmt, pos, String(describing: v), -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            guard rc == SQLITE_OK else {
                throw SQLiteError.exec("SQLite 参数绑定失败: rc=\(rc)")
            }
        }
    }
}
