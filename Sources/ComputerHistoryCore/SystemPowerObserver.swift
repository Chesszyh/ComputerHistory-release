import CoreGraphics
import Foundation
import IOKit
import IOKit.pwr_mgt

public final class SystemPowerObserver {
    public enum Event: Sendable {
        case willSleep(Date)
        case didWake
    }

    // Swift does not import the function-like macros in IOMessage.h.
    private static let canSystemSleep: UInt32 = 0xe0000270
    private static let systemWillSleep: UInt32 = 0xe0000280
    private static let systemHasPoweredOn: UInt32 = 0xe0000300
    private var connection: io_connect_t = 0
    private var notifier: io_object_t = 0
    private var port: IONotificationPortRef?
    private let handler: @Sendable (Event) -> Void

    public init?(queue: DispatchQueue, handler: @escaping @Sendable (Event) -> Void) {
        self.handler = handler
        connection = IORegisterForSystemPower(Unmanaged.passUnretained(self).toOpaque(), &port, { context, _, message, argument in
            guard let context else { return }
            let observer = Unmanaged<SystemPowerObserver>.fromOpaque(context).takeUnretainedValue()
            switch message {
            case SystemPowerObserver.canSystemSleep:
                IOAllowPowerChange(observer.connection, Int(bitPattern: argument))
            case SystemPowerObserver.systemWillSleep:
                observer.handler(.willSleep(Date()))
                IOAllowPowerChange(observer.connection, Int(bitPattern: argument))
            case SystemPowerObserver.systemHasPoweredOn:
                // IOPMrootDomain sends the completion message to application clients at full wake.
                observer.handler(.didWake)
            default: break
            }
        }, &notifier)
        guard connection != 0, let port else { return nil }
        IONotificationPortSetDispatchQueue(port, queue)
    }

    // A restored interval may predate registration for the visible wake notification.
    public static var hasAwakeDisplay: Bool {
        let display = CGMainDisplayID()
        guard display != kCGNullDirectDisplay, CGDisplayIsActive(display) != 0,
              CGDisplayIsAsleep(display) == 0 else { return false }
        return CGDisplayIsBuiltin(display) == 0 || !readLidClosed()
    }

    static func readLidClosed() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        return (IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool) == true
    }

    deinit {
        if notifier != 0 { IODeregisterForSystemPower(&notifier) }
        if connection != 0 { IOServiceClose(connection) }
        if let port { IONotificationPortDestroy(port) }
    }
}
