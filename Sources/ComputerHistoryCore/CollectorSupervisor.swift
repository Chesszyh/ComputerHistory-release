import Foundation
import Darwin

/// 采集器自监督：崩溃后重启，正常停止则退出；可脱离终端会话独立运行。
///
public enum CollectorSupervisor {

    public enum Mode {
        /// 前台运行，便于观察输出。
        case foreground
        /// 脱离终端会话独立运行（`posix_spawn` + `POSIX_SPAWN_SETSID`）。
        case detached
    }

    /// 以脱离会话的方式重新启动自身，随后本进程返回。
    ///
    /// 参数里去掉 `--daemon`，避免子进程再次自我派生。
    public static func detach(executable: String,
                              arguments: [String]) throws -> pid_t {

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        // stdin 接 /dev/null：脱离终端后不应再有输入。
        posix_spawn_file_actions_addopen(
            &fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        // The detached supervisor connects both streams to its managed log after exec.
        posix_spawn_file_actions_addopen(&fileActions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&fileActions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // 新会话，脱离终端的进程组，终端关闭时不会被一并清理。
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))

        var argv: [UnsafeMutablePointer<CChar>?] =
            ([executable] + arguments).map { strdup($0) }
        argv.append(nil)
        defer { for p in argv where p != nil { free(p) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &fileActions, &attr, &argv, environ)
        guard rc == 0 else {
            throw SupervisorError.spawnFailed(code: rc)
        }
        return pid
    }

    public enum SupervisorError: Error, CustomStringConvertible {
        case spawnFailed(code: Int32)
        case executablePathUnavailable

        public var description: String {
            switch self {
            case .spawnFailed(let code):
                return "派生失败（错误码 \(code)）"
            case .executablePathUnavailable:
                return "无法确定可执行文件路径"
            }
        }
    }

    /// 运行一次采集子进程并等待其退出，返回退出码。
    ///
    /// 用 `posix_spawn` 而非 `Process`：后者在监督循环里会随父进程的
    /// 信号处理产生额外语义，这里只需要一个干净的子进程。
    public static func runCollectOnce(executable: String, arguments: [String]) -> Int32 {
        var argv: [UnsafeMutablePointer<CChar>?] =
            ([executable] + arguments).map { strdup($0) }
        argv.append(nil)
        defer { for p in argv where p != nil { free(p) } }

        var pid: pid_t = 0
        guard posix_spawn(&pid, executable, nil, nil, &argv, environ) == 0 else {
            return 1
        }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 {
            if errno != EINTR { return 1 }
        }
        // 被信号终止时 waitpid 的状态高位记录信号号；映射为 128+signal，
        // 便于监督循环区分「正常停止」与「被杀」。
        if (status & 0x7F) != 0 { return 128 + (status & 0x7F) }
        return (status >> 8) & 0xFF
    }

    /// 请求子进程停止：先 SIGTERM，宽限后 SIGKILL。返回是否已发出信号。
    ///
    /// 用于监督进程退出时收拾仍在运行的生成任务——它们可能正卡在网络请求上。
    @discardableResult
    public static func terminate(_ pid: pid_t, grace: TimeInterval = 3) -> Bool {
        guard kill(pid, SIGTERM) == 0 else { return false }
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline {
            if reap(pid) != nil { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        kill(pid, SIGKILL)
        return true
    }

    /// 子进程是否仍在运行。用 `WNOHANG` 轮询，不阻塞监督循环。
    public static func isRunning(_ pid: pid_t) -> Bool {
        var status: Int32 = 0
        let r = waitpid(pid, &status, WNOHANG)
        // 0 表示尚未结束；-1 表示已回收或不存在。
        return r == 0
    }

    /// 等待指定子进程结束并返回退出码。
    public static func runToCompletion(pid: pid_t) -> Int32 {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 {
            if errno != EINTR { return 1 }
        }
        if (status & 0x7F) != 0 { return 128 + (status & 0x7F) }
        return (status >> 8) & 0xFF
    }

    /// 取出已结束子进程的退出码；仍在运行时返回 nil。
    public static func reap(_ pid: pid_t) -> Int32? {
        var status: Int32 = 0
        let r = waitpid(pid, &status, WNOHANG)
        guard r == pid else { return nil }
        if (status & 0x7F) != 0 { return 128 + (status & 0x7F) }
        return (status >> 8) & 0xFF
    }

    public final class Child {
        public let pid: pid_t
        private var lifetime: Int32

        fileprivate init(pid: pid_t, lifetime: Int32) {
            self.pid = pid
            self.lifetime = lifetime
        }

        public func requestStop() {
            guard lifetime >= 0 else { return }
            Darwin.close(lifetime)
            lifetime = -1
        }

        deinit { requestStop() }
    }

    public static func spawnChild(executable: String, arguments: [String]) throws -> Child {
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else { throw SupervisorError.spawnFailed(code: errno) }
        let readEnd = descriptors[0], writeEnd = descriptors[1]
        defer { Darwin.close(readEnd) }
        var spawned = false
        defer { if !spawned { Darwin.close(writeEnd) } }
        // Only the supervisor keeps a writer, including when another worker or helper is spawned.
        guard fcntl(readEnd, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(writeEnd, F_SETFD, FD_CLOEXEC) == 0 else {
            throw SupervisorError.spawnFailed(code: errno)
        }
        var actions: posix_spawn_file_actions_t?
        let initialized = posix_spawn_file_actions_init(&actions)
        guard initialized == 0 else { throw SupervisorError.spawnFailed(code: initialized) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        let added = posix_spawn_file_actions_adddup2(&actions, readEnd, SupervisedLifetime.descriptor)
        guard added == 0 else { throw SupervisorError.spawnFailed(code: added) }
        var argv: [UnsafeMutablePointer<CChar>?] =
            ([executable] + arguments + [SupervisedLifetime.argument]).map { strdup($0) }
        argv.append(nil)
        defer { for p in argv where p != nil { free(p) } }
        var pid: pid_t = 0
        let code = posix_spawn(&pid, executable, &actions, nil, &argv, environ)
        guard code == 0 else { throw SupervisorError.spawnFailed(code: code) }
        spawned = true
        return Child(pid: pid, lifetime: writeEnd)
    }

    /// 日志超过上限时轮转为 `.1`，保留一份便于排查上次运行。
    public static func rotateLog(at url: URL, maxBytes: Int) throws {
        try CollectorLog(url: url).rotate(maxBytes: maxBytes)
    }

    /// 运行期保留上限内最近的完整日志行。
    @discardableResult
    public static func enforceLogBound(at url: URL, maxBytes: Int, keepBytes: Int? = nil) -> Bool {
        (try? CollectorLog(url: url).enforceBound(maxBytes: maxBytes, keepBytes: keepBytes)) ?? false
    }

    /// 当前可执行文件的绝对路径。
    public static func currentExecutablePath() -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(getpid(), &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }
}
