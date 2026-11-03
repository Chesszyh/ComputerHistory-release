import Foundation
import IOKit
import IOKit.pwr_mgt

/// 合盖与系统睡眠限制生成；后台维护唤醒不应重新开始模型请求。
public final class GenerationPowerState: @unchecked Sendable {
    // IOMessage.h 的函数式宏不能由 Swift 导入。
    private static let canSystemSleep: UInt32 = 0xe0000270
    private static let systemWillSleep: UInt32 = 0xe0000280
    private static let systemHasPoweredOn: UInt32 = 0xe0000300
    public static let shared = GenerationPowerState()
    private let lock = NSLock()
    private var sleeping = false
    private var revision: UInt64 = 0
    private var connection: io_connect_t = 0
    private var notifier: io_object_t = 0
    private var port: IONotificationPortRef?
    private let lidClosed: @Sendable () -> Bool

    init(observingSystem: Bool = true, lidClosed: @escaping @Sendable () -> Bool = GenerationPowerState.readLidClosed) {
        self.lidClosed = lidClosed
        guard observingSystem else { return }
        connection = IORegisterForSystemPower(Unmanaged.passUnretained(self).toOpaque(), &port, { context, _, message, argument in
            guard let context else { return }
            let state = Unmanaged<GenerationPowerState>.fromOpaque(context).takeUnretainedValue()
            switch message {
            case GenerationPowerState.systemWillSleep:
                state.setSleeping(true)
                IOAllowPowerChange(state.connection, Int(bitPattern: argument))
            case GenerationPowerState.canSystemSleep:
                IOAllowPowerChange(state.connection, Int(bitPattern: argument))
            case GenerationPowerState.systemHasPoweredOn:
                state.setSleeping(false)
            default: break
            }
        }, &notifier)
        if let port { IONotificationPortSetDispatchQueue(port, DispatchQueue(label: "computer-history.generation-power")) }
    }

    deinit {
        if notifier != 0 { IODeregisterForSystemPower(&notifier) }
        if connection != 0 { IOServiceClose(connection) }
        if let port { IONotificationPortDestroy(port) }
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

    private static func readLidClosed() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        return (IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool) == true
    }
}
