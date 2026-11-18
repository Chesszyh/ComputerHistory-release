import Darwin
import Foundation
import OSLog

/// A stable lock covers every append, tail trim, and startup rotation.
public struct CollectorLog: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func append(_ bytes: Data) throws {
        guard !bytes.isEmpty else { return }
        try withLock {
            let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw posixError() }
            let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try file.write(contentsOf: bytes)
        }
    }

    @discardableResult
    func enforceBound(maxBytes: Int, keepBytes: Int?) throws -> Bool {
        try withLock {
            guard let size = oversizedFile(maxBytes: maxBytes) else { return false }
            let keep = max(0, min(maxBytes, keepBytes ?? maxBytes / 2))
            let offset = size - UInt64(keep)
            let file = try FileHandle(forUpdating: url)
            defer { try? file.close() }
            try file.seek(toOffset: offset - 1)
            let previous = try file.read(upToCount: 1)?.first
            let tail = keep > 0 ? try file.read(upToCount: keep) ?? Data() : Data()
            let first = previous == 0x0A ? tail.startIndex : tail.firstIndex(of: 0x0A).map { $0 + 1 } ?? tail.endIndex
            let end = tail.lastIndex(of: 0x0A).map { $0 + 1 } ?? first
            let retained = tail[first..<max(first, end)]
            try file.seek(toOffset: 0)
            try file.write(contentsOf: retained)
            try file.truncate(atOffset: UInt64(retained.count))
            return true
        }
    }

    func rotate(maxBytes: Int) throws {
        try withLock {
            guard oversizedFile(maxBytes: maxBytes) != nil else { return }
            guard rename(url.path, url.path + ".1") == 0 else { throw posixError() }
        }
    }

    public func attachedStandardStreams() -> [Int32] {
        var pathInfo = stat()
        guard stat(url.path, &pathInfo) == 0, (pathInfo.st_mode & S_IFMT) == S_IFREG else { return [] }
        return [STDOUT_FILENO, STDERR_FILENO].filter { descriptor in
            var info = stat()
            return fstat(descriptor, &info) == 0 && info.st_dev == pathInfo.st_dev && info.st_ino == pathInfo.st_ino
        }
    }

    private func oversizedFile(maxBytes: Int) -> UInt64? {
        var info = stat()
        guard stat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size > maxBytes else { return nil }
        return UInt64(info.st_size)
    }

    private func withLock<T>(_ operation: () throws -> T) throws -> T {
        let lock = open(url.path + ".lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw posixError() }
        defer { close(lock) }
        while flock(lock, LOCK_EX) != 0 {
            if errno != EINTR { throw posixError() }
        }
        return try operation()
    }
}

private func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

/// A process and its inherited stdout/stderr write to a pipe. The drain opens the
/// current log only while holding its lock, so neither process keeps a stale log fd.
public final class CollectorLogCapture: @unchecked Sendable {
    public static let shared = CollectorLogCapture()
    private let queue = DispatchQueue(label: "computer-history.log-output")
    private let diagnostics = Logger(subsystem: "xyz.chesszyh.computer-history", category: "collector-log")
    private var source: DispatchSourceRead?
    private var pending = Data()
    private var failure: String?
    private var log: CollectorLog?
    private var reader: Int32 = -1

    private init() {}

    public func redirect(to log: CollectorLog, streams: [Int32] = [STDOUT_FILENO, STDERR_FILENO]) throws {
        guard !streams.isEmpty else { return }
        let probe = open(log.url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard probe >= 0 else { throw posixError() }
        var info = stat()
        let regular = fstat(probe, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
        if !regular {
            // A caller can use a FIFO as its output instead of a bounded file.
            for stream in streams { dup2(probe, stream) }
            if !streams.contains(probe) { close(probe) }
            configureBuffering()
            return
        }
        close(probe)

        var pipeEnds: [Int32] = [-1, -1]
        guard pipe(&pipeEnds) == 0 else { throw posixError() }
        let readEnd = fcntl(pipeEnds[0], F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
        let writeEnd = fcntl(pipeEnds[1], F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
        let duplicationError = posixError()
        close(pipeEnds[0]); close(pipeEnds[1])
        guard readEnd >= 0, writeEnd >= 0 else {
            if readEnd >= 0 { close(readEnd) }
            if writeEnd >= 0 { close(writeEnd) }
            throw duplicationError
        }
        defer { close(writeEnd) }
        guard fcntl(readEnd, F_SETFL, O_NONBLOCK) != -1 else {
            let error = posixError()
            close(readEnd)
            throw error
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: readEnd, queue: queue)
        queue.sync {
            self.log = log
            self.reader = readEnd
            self.source = source
        }
        source.setEventHandler { [weak self] in self?.drain(flushing: false) }
        source.setCancelHandler { close(readEnd) }
        source.activate()
        atexit { CollectorLogCapture.shared.flush() }
        for stream in streams {
            guard dup2(writeEnd, stream) != -1 else { throw posixError() }
        }
        configureBuffering()
    }

    private func configureBuffering() {
        setvbuf(stdout, nil, _IOLBF, 0)
        setvbuf(stderr, nil, _IONBF, 0)
    }

    private func flush() {
        fflush(stdout)
        fflush(stderr)
        queue.sync { drain(flushing: true) }
    }

    private func drain(flushing: Bool) {
        guard let log, reader >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = read(reader, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { break }
            pending.append(contentsOf: buffer.prefix(count))
            if let newline = pending.lastIndex(of: 0x0A) {
                append(Data(pending[...newline]), to: log)
                pending.removeSubrange(...newline)
            }
        }
        if flushing, !pending.isEmpty {
            pending.append(0x0A)
            append(pending, to: log)
            pending.removeAll()
        }
    }

    private func append(_ bytes: Data, to log: CollectorLog) {
        do {
            try log.append(bytes)
            failure = nil
        } catch {
            let message = String(describing: error)
            if message != failure { diagnostics.error("无法写入采集日志：\(message, privacy: .public)") }
            failure = message
        }
    }
}
