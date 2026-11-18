import Foundation

/// 合盖与系统睡眠限制生成；后台维护唤醒不应重新开始模型请求。
public final class GenerationPowerState: @unchecked Sendable {
    public static let shared = GenerationPowerState()
    private let lock = NSLock()
    private var sleeping = false
    private var revision: UInt64 = 0
    private var observer: SystemPowerObserver?
    private let lidClosed: @Sendable () -> Bool

    init(observingSystem: Bool = true, lidClosed: @escaping @Sendable () -> Bool = SystemPowerObserver.readLidClosed) {
        self.lidClosed = lidClosed
        guard observingSystem else { return }
        observer = SystemPowerObserver(queue: DispatchQueue(label: "computer-history.generation-power")) { [weak self] event in
            switch event {
            case .willSleep: self?.setSleeping(true)
            case .didWake: self?.setSleeping(false)
            }
        }
    }

    func setSleeping(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        if value && !sleeping { revision &+= 1 }
        sleeping = value
    }

    public var canGenerate: Bool { snapshot() != nil }

    func snapshot() -> UInt64? {
        let closed = lidClosed()
        lock.lock(); defer { lock.unlock() }
        return sleeping || closed ? nil : revision
    }

    func check(_ expected: UInt64? = nil) throws {
        guard let current = snapshot(), expected == nil || current == expected else {
            throw DeepSeekClient.ClientError.sleepDeferred
        }
    }
}
