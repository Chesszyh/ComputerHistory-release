import Foundation
import Darwin

public enum SupervisedLifetime {
    public static let argument = "--supervised-child"
    static let descriptor: Int32 = 3

    public static func monitor(on queue: DispatchQueue,
                               stopped: @escaping @Sendable () -> Void) throws -> DispatchSourceRead {
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFIFO,
              fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            throw POSIXError(.EBADF)
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler(handler: stopped)
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
        return source
    }

    public static func monitorWorker() throws {
        helpers.source = try monitor(on: DispatchQueue(label: "computer-history.parent-lifetime")) {
            helpers.stop()
            exit(128 + SIGTERM)
        }
    }

    static func prepareHelper<Result>(_ prepare: () throws -> Result) throws -> Result {
        try helpers.lock.withLock {
            guard !helpers.stopping else { throw CancellationError() }
            return try prepare()
        }
    }

    static func startHelper(_ process: Process) throws {
        try prepareHelper {
            let tracked = helpers.source != nil
            if tracked {
                process.terminationHandler = { finished in
                    helpers.lock.withLock { helpers.active.removeAll { $0 === finished } }
                }
            }
            try process.run()
            if tracked { helpers.active.append(process) }
        }
    }

    static func withHelper<Result>(_ process: Process, _ body: () throws -> Result) throws -> Result {
        try startHelper(process)
        return try body()
    }

    private static let helpers = Helpers()

    private final class Helpers: @unchecked Sendable {
        let lock = NSLock()
        var source: DispatchSourceRead?
        var stopping = false
        var active: [Process] = []

        func stop() {
            let running = lock.withLock {
                stopping = true
                return active.filter { $0.isRunning }
            }
            for process in running where process.isRunning {
                let pid = process.processIdentifier
                // Foundation gives each helper its own group. Git may start remote and credential helpers there.
                if getpgid(pid) == pid { kill(-pid, SIGKILL) }
                else { kill(pid, SIGKILL) }
            }
            for process in running { process.waitUntilExit() }
        }
    }
}
