import Foundation

enum TerminationSignals {
    static func listen(on queue: DispatchQueue, handler: @escaping @Sendable () -> Void) -> [DispatchSourceSignal] {
        [SIGINT, SIGTERM].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler(handler: handler)
            source.resume()
            return source
        }
    }
}

final class SupervisorStopRequest: Sendable {
    private let wake = DispatchSemaphore(value: 0)
    private let signals: [DispatchSourceSignal]

    init() {
        let wake = wake
        signals = TerminationSignals.listen(on: DispatchQueue(label: "computer-history.supervisor-signals")) {
            wake.signal()
        }
    }

    func wait(for interval: TimeInterval) -> Bool {
        guard wake.wait(timeout: .now() + interval) == .success else { return false }
        wake.signal()
        return true
    }
}
