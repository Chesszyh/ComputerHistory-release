import Foundation
import Darwin

/// 用启动时刻和可执行文件路径区分复用的进程号。
public struct CollectorProcessIdentity: Codable, Equatable, Sendable {
    public let pid: Int32
    public let startedSeconds: UInt64
    public let startedMicroseconds: UInt64
    public let executablePath: String

    public static func read(pid: Int32) -> Self? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        let executable = path.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return Self(pid: pid, startedSeconds: info.pbi_start_tvsec,
                    startedMicroseconds: info.pbi_start_tvusec, executablePath: executable)
    }

    public var matchesLiveProcess: Bool { Self.read(pid: pid) == self }
}

/// 锁文件保持原位，避免删除后并发启动的进程锁住不同 inode。
public final class CollectorProcessLease {
    private let descriptor: Int32
    private let recordURL: URL
    public let identity: CollectorProcessIdentity
    private var released = false

    public enum LeaseError: Error { case alreadyRunning, identityUnavailable }

    public init(root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fd = open(root.appendingPathComponent("collector.lock").path,
                      O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            Darwin.close(fd)
            if code == EWOULDBLOCK { throw LeaseError.alreadyRunning }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        guard let current = CollectorProcessIdentity.read(pid: getpid()) else {
            Darwin.close(fd)
            throw LeaseError.identityUnavailable
        }
        descriptor = fd
        identity = current
        recordURL = root.appendingPathComponent("collector.pid")
    }

    public func publish() throws {
        guard !released else { throw LeaseError.identityUnavailable }
        try JSONEncoder().encode(identity).write(to: recordURL, options: .atomic)
    }

    public func release() {
        guard !released else { return }
        released = true
        if let data = try? Data(contentsOf: recordURL),
           (try? JSONDecoder().decode(CollectorProcessIdentity.self, from: data)) == identity {
            try? FileManager.default.removeItem(at: recordURL)
        }
        Darwin.close(descriptor)
    }

    deinit { release() }

    public static func runningIdentity(root: URL,
                                       executableName: String = "computer-history") -> CollectorProcessIdentity? {
        // PID 文件本身不能证明实例仍在运行，必须同时有采集锁和进程身份。
        let fd = open(root.appendingPathComponent("collector.lock").path, O_RDWR | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) != 0, errno == EWOULDBLOCK,
              let data = try? Data(contentsOf: root.appendingPathComponent("collector.pid")),
              let identity = try? JSONDecoder().decode(CollectorProcessIdentity.self, from: data),
              URL(fileURLWithPath: identity.executablePath).lastPathComponent == executableName,
              identity.matchesLiveProcess else { return nil }
        return identity
    }
}
