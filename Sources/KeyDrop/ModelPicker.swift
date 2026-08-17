import Foundation
import KeyDropCore
import Darwin

enum ModelPicker {

    static func pick(from models: [String], title: String, preselected: Set<String> = []) -> [String]? {
        guard !models.isEmpty else { return nil }
        if !isTTY() {
            print("\(title) 非交互终端,将导入全部模型")
            return nil
        }
        print(title)
        return runLoop(models: models, preselected: preselected)
    }

    private static func isTTY() -> Bool {
        isatty(STDIN_FILENO) == 1
    }

    private static func runLoop(models: [String], preselected: Set<String>) -> [String]? {
        guard let old = setRawMode() else { return nil }
        defer { restoreMode(old) }

        var query = ""
        var index = 0
        var selected = preselected
        let hint = "空格 勾选/取消 · ↑↓ 移动 · 输入 过滤 · a 全选 · Enter 确认 · Esc 取消"

        func filtered() -> [String] {
            guard !query.isEmpty else { return models }
            let q = query.lowercased()
            let contains = models.filter { $0.lowercased().contains(q) }
            let starts = contains.filter { $0.lowercased().hasPrefix(q) }
            return starts + contains.filter { !starts.contains($0) }
        }

        func render() {
            let list = filtered()
            if index >= list.count { index = max(0, list.count - 1) }
            var out = "\u{1B}[2J\u{1B}[H"
            out += "搜索: \(query)_\n"
            out += hint + "\n\n"
            let shown = Array(list.prefix(20))
            for (i, m) in shown.enumerated() {
                let mark = selected.contains(m) ? "[x]" : "[ ]"
                if i == index {
                    out += "\u{1B}[7m\(mark) \(m)\u{1B}[0m\n"
                } else {
                    out += "\(mark) \(m)\n"
                }
            }
            if list.count > shown.count {
                out += "... 共 \(list.count) 个\n"
            }
            out += "\n已选 \(selected.count) 个: \(selected.sorted().prefix(3).joined(separator: ", "))"
            if selected.count > 3 { out += "…" }
            out += "\n"
            print(out, terminator: "")
            fflush(stdout)
        }

        render()
        while true {
            guard let key = readKey() else { return nil }
            switch key {
            case "\u{1B}": return nil
            case "\r", "\n":
                var result = Array(selected)
                if result.isEmpty {
                    let list = filtered()
                    if list.indices.contains(index) { result = [list[index]] }
                }
                return result.isEmpty ? nil : result
            case "\u{03}": return nil
            case " ":
                let list = filtered()
                if list.indices.contains(index) {
                    let m = list[index]
                    if selected.contains(m) { selected.remove(m) } else { selected.insert(m) }
                }
            case "a", "A":
                if selected.count == filtered().count { selected = [] } else { selected = Set(filtered()) }
            case "\u{7F}", "\u{08}":
                if !query.isEmpty { query.removeLast(); index = 0 }
            case "\u{1B}[A":
                if index > 0 { index -= 1 }
            case "\u{1B}[B":
                let c = filtered().count
                if c > 0 && index < c - 1 { index += 1 }
            default:
                if let scalar = key.unicodeScalars.first, scalar.isASCII || !key.utf8.isEmpty {
                    if query.count < 120 { query += key; index = 0 }
                }
            }
            render()
        }
    }

    private static func setRawMode() -> termios? {
        var t = termios()
        guard tcgetattr(STDIN_FILENO, &t) == 0 else { return nil }
        let old = t
        t.c_lflag &= ~tcflag_t(ECHO | ICANON)
        t.c_iflag &= ~tcflag_t(IXON | ICRNL)
        t.c_oflag &= ~tcflag_t(OPOST)
        t.c_cc.16 = 1
        t.c_cc.17 = 0
        tcsetattr(STDIN_FILENO, TCSANOW, &t)
        return old
    }

    private static func restoreMode(_ t: termios) {
        var t = t
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &t)
    }

    private static func debugLog(_ s: String) {
        if let f = ProcessInfo.processInfo.environment["KEYDROP_PICKER_DEBUG"],
           let h = FileHandle(forWritingAtPath: f) {
            h.seekToEndOfFile()
            if let d = (s + "\n").data(using: .utf8) { h.write(d) }
        }
    }

    private static var pending: [UInt8] = []

    private static func readKey() -> String? {
        if pending.isEmpty {
            var buf = [UInt8](repeating: 0, count: 64)
            let n = read(STDIN_FILENO, &buf, 64)
            guard n > 0 else { return nil }
            pending = Array(buf.prefix(n))
        }
        let byte = pending.removeFirst()
        if byte == 0x1B {
            while pending.count < 2 {
                var buf = [UInt8](repeating: 0, count: 2)
                let n = read(STDIN_FILENO, &buf, 2)
                guard n > 0 else { return nil }
                pending += buf.prefix(n)
            }
            let a = pending.removeFirst()
            let b = pending.removeFirst()
            if a == 0x5B {
                return "\u{1B}[" + String(UnicodeScalar(b))
            }
            if a == 0x1B {
                pending.insert(a, at: 0)
                return "\u{1B}"
            }
            return "\u{1B}"
        }
        guard byte >= 0x20 || byte == 0x7F || byte == 0x0D || byte == 0x0A || byte == 0x03 else {
            return nil
        }
        return String(UnicodeScalar(byte))
    }
}
