import Foundation

/// 跨进程互斥锁。
///
/// 存在的理由：生成任务由监督进程按周期启动，也可以从命令行手动启动。两者同时跑
/// 时，各自读到同一份旧缓存、各自追加结果，就会写出重复条目——实测叙述缓存里
/// 出现过三条完全相同的内容。
///
/// 用 `flock` 而不是「先检查标记文件再写入」：标记文件在进程崩溃后会残留，
/// 需要额外的过期判断；`flock` 由内核在进程退出（含被 kill）时自动释放。
public final class ProcessLock {

    private var fd: Int32
    private let url: URL

    /// 尝试获取锁。
    ///
    /// - Returns: 获取成功返回实例；已被其他进程持有时返回 nil。调用方应据此
    ///   跳过本次执行而不是排队——生成任务错过一轮没有损失，堆积反而更慢。
    public init?(url: URL) {
        self.url = url
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return nil }
        // LOCK_NB：拿不到就立刻返回，不阻塞——阻塞会让监督循环卡住。
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        self.fd = descriptor

        // 写入持有者信息，便于排查「谁卡住了」。
        let info = "pid \(getpid())\n"
        _ = ftruncate(descriptor, 0)
        _ = info.withCString { write(descriptor, $0, strlen($0)) }
    }

    public func release() {
        guard fd >= 0 else { return }
        _ = flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit { release() }
}

/// 生成任务共用的锁路径。
public enum GenerationLock {
    /// 记忆生成与叙述生成分开加锁：两者写不同的文件，可以并行；
    /// 但同一类任务不得并发。
    public static func memorize(root: URL) -> ProcessLock? {
        ProcessLock(url: lockURL("memorize", root: root))
    }

    public static func narrative(root: URL) -> ProcessLock? {
        ProcessLock(url: lockURL("narrative", root: root))
    }

    /// 锁文件收进子目录，避免混进数据目录的产物列表。
    public static func lockURL(_ name: String, root: URL) -> URL {
        root.appendingPathComponent(".locks").appendingPathComponent("\(name).lock")
    }
}
