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
                // 仅在搜索框为空时才算全选/清空快捷键。
                // 注意不能写 `case "a", "A" where query.isEmpty`:Swift 的 where 只作用于
                // 最后一个模式,小写 a 会无条件触发全选/清空,导致 "gpt-4o-audio" 永远打不出来。
                if query.isEmpty {
                    if selected.count == filtered().count { selected = [] } else { selected = Set(filtered()) }
                } else if query.count < 120 {
                    query += key
                    index = 0
                }
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

    /// 等待 stdin 有可读字节(非阻塞轮询);返回 false 表示 us 内没有新输入
    private static func hasInputWithin(ms: Int32) -> Bool {
        var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        let n = poll(&pfd, 1, ms)
        return n > 0 && (pfd.revents & Int16(POLLIN)) != 0
    }

    private static func readKey() -> String? {
        if pending.isEmpty {
            var buf = [UInt8](repeating: 0, count: 64)
            let n = read(STDIN_FILENO, &buf, 64)
            guard n > 0 else { return nil }
            pending = Array(buf.prefix(n))
        }
        let byte = pending.removeFirst()
        if byte == 0x1B {
            // 旧行为是死等后续两个字节,单独按 Esc 会卡住直到下一次按键。
            // 改为短轮询(~30ms):方向键等转义序列会在同一次终端写入中一起到达,
            // 没有后续字节的纯 Esc 立即生效。
            while pending.count < 2 {
                guard hasInputWithin(ms: 30) else { break }
                var buf = [UInt8](repeating: 0, count: 2)
                let n = read(STDIN_FILENO, &buf, 2)
                guard n > 0 else { break }
                pending += buf.prefix(n)
            }
            if pending.isEmpty { return "\u{1B}" }
            let a = pending.removeFirst()
            if a == 0x5B {
                // ESC [ + 一字节构成 CSI 序列(↑↓ 等)
                guard !pending.isEmpty else { return "\u{1B}" }
                let b = pending.removeFirst()
                return "\u{1B}[" + String(UnicodeScalar(b))
            }
            if a == 0x1B {
                // 连按两次 Esc:本次先生效,第二个留给下一轮
                pending.insert(a, at: 0)
                return "\u{1B}"
            }
            return "\u{1B}"
        }
        guard byte >= 0x20 || byte == 0x7F || byte == 0x0D || byte == 0x0A || byte == 0x03 else {
            return nil
        }
        if byte < 0x80 {
            return String(UnicodeScalar(byte))
        }
        // 多字节 UTF-8(如中文过滤词):按首字节推断序列长度,收齐后整体解码。
        // 逐字节返回会让 runLoop 把每个字节单独追加进 query,输入必然乱码、过滤永不命中
        let expected: Int
        switch byte {
        case 0xC2...0xDF: expected = 2
        case 0xE0...0xEF: expected = 3
        case 0xF0...0xF4: expected = 4
        default: return nil
        }
        var bytes = [byte]
        while bytes.count < expected {
            if pending.isEmpty {
                // 终端通常一次送齐整个字符;极慢链路下续字节可能晚到,短轮询等待
                guard hasInputWithin(ms: 50) else { return nil }
                var buf = [UInt8](repeating: 0, count: expected - bytes.count)
                let n = read(STDIN_FILENO, &buf, buf.count)
                guard n > 0 else { return nil }
                pending += buf.prefix(n)
            }
            bytes.append(pending.removeFirst())
        }
        return String(bytes: bytes, encoding: .utf8)
    }
}
