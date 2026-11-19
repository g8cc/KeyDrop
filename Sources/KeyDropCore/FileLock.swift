import Foundation
import Darwin

/// 跨进程 advisory 文件锁(flock)。
///
/// KeyDrop 同时存在常驻菜单栏进程与 CLI 进程,共享 `~/.keydrop` 下的历史与各工具配置。
/// 这些文件都是「读全文 → 内存改 → 整体覆盖写」模式,进程内 NSLock 管不住跨进程,
/// 并发时后写者会静默抹掉先写者的修改(丢记录,CPA 原地写甚至可能交错损坏文件)。
/// 在临界区外层用 flock 锁住同目录的锁文件即可串行化跨进程读写。
public enum FileLock {

    public static func withLock<T>(_ path: String, _ body: () throws -> T) throws -> T {
        // 锁文件父目录可能尚未创建(首次运行 ~/.keydrop、~/.dsh 不存在),
        // open 会因 ENOENT 失败并静默退化为无锁。先补建目录,让首次写入也有锁保护。
        let parent = (path as NSString).deletingLastPathComponent
        if !parent.isEmpty, !FileManager.default.fileExists(atPath: parent) {
            try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        }
        let fd = open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO,
                             userInfo: [NSFilePathErrorKey: path])
        }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            if errno != EINTR {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO,
                                 userInfo: [NSFilePathErrorKey: path])
            }
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    /// 统一锁文件路径，所有读改写调用方使用同一把锁。
    public static func lockPath(for target: String) -> String {
        target + ".keydrop-lock"
    }
}
