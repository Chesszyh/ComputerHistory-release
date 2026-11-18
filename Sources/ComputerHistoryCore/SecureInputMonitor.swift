import Foundation

final class SecureInputMonitor: @unchecked Sendable {
    struct State: Equatable, Sendable {
        var enabled = false
        var epoch = 0
    }

    private let lock = NSLock()
    private let read: @Sendable () -> Bool
    private var state = State()

    init(read: @escaping @Sendable () -> Bool) {
        self.read = read
    }

    func refresh() -> State {
        lock.withLock {
            let enabled = read()
            if enabled != state.enabled {
                state.enabled = enabled
                state.epoch += 1
            }
            return state
        }
    }
}
