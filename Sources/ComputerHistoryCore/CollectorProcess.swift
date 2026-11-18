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

    public func stop(signal: Int32, timeout: Int) throws -> Int32 {
        let queue = kqueue()
        guard queue >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(queue) }
        var event = kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC),
                           flags: UInt16(EV_ADD | EV_ONESHOT), fflags: NOTE_EXIT | UInt32(NOTE_EXITSTATUS),
                           data: 0, udata: nil)
        guard kevent(queue, &event, 1, nil, 0, nil) == 0,
              matchesLiveProcess, kill(pid, signal) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ESRCH)
        }
        var deadline = timespec(tv_sec: timeout, tv_nsec: 0)
        var result = kevent()
        let count = kevent(queue, nil, 0, &result, 1, &deadline)
        guard count > 0 else {
            throw POSIXError(count == 0 ? .ETIMEDOUT : (POSIXErrorCode(rawValue: errno) ?? .EIO))
        }
        guard result.flags & UInt16(EV_ERROR) == 0, result.fflags & UInt32(NOTE_EXITSTATUS) != 0 else {
            throw POSIXError(.EIO)
        }
        let signal = Int32(result.data & 0x7F)
        return signal == 0 ? Int32((result.data >> 8) & 0xFF) : 128 + signal
    }
}

/// 锁文件保持原位，避免删除后并发启动的进程锁住不同 inode。
public final class CollectorProcessLease {
    private let descriptor: Int32
    private let recordURL: URL
    public let identity: CollectorProcessIdentity
    private var released = false

    public enum LeaseError: Error { case alreadyRunning, identityUnavailable }

    public enum Role: String {
        case collector, supervisor

        fileprivate func file(in root: URL, extension suffix: String) -> URL {
            root.appendingPathComponent(rawValue).appendingPathExtension(suffix)
        }
    }

    public init(root: URL, role: Role = .collector) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fd = open(role.file(in: root, extension: "lock").path,
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
        recordURL = role.file(in: root, extension: "pid")
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
                                       role: Role = .collector,
                                       executableName: String = "computer-history") -> CollectorProcessIdentity? {
        guard (try? isHeld(root: root, role: role)) == true,
              let data = try? Data(contentsOf: role.file(in: root, extension: "pid")),
              let identity = try? JSONDecoder().decode(CollectorProcessIdentity.self, from: data),
              URL(fileURLWithPath: identity.executablePath).lastPathComponent == executableName,
              identity.matchesLiveProcess else { return nil }
        return identity
    }

    public static func isHeld(root: URL, role: Role) throws -> Bool {
        let fd = open(role.file(in: root, extension: "lock").path, O_RDWR | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return false }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { return false }
        if errno == EWOULDBLOCK { return true }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
