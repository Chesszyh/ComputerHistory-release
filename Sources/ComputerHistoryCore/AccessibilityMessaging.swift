import ApplicationServices

public enum AccessibilityMessaging {
    public enum Client {
        case collector
        case menubar
    }

    public static func configure(for client: Client) throws {
        switch client {
        case .collector: try collector.get()
        case .menubar: try menubar.get()
        }
    }

    private static let collector = configure(seconds: 0.35)
    private static let menubar = configure(seconds: 0.2)

    private static func configure(seconds: Float) -> Result<Void, ConfigurationError> {
        let result = AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), seconds)
        return result == .success ? .success(()) : .failure(ConfigurationError(code: result.rawValue))
    }

    private struct ConfigurationError: Error, CustomStringConvertible {
        let code: Int32
        var description: String { "辅助功能消息超时设置失败（错误码 \(code)）" }
    }
}

// One read scope stays on its calling thread. A communication failure makes subsequent
// attributes in that scope unavailable, while ordinary unsupported attributes can fall back.
final class AccessibilityRead {
    private let isAllowed: () -> Bool
    private(set) var communicationFailed = false

    init(isAllowed: @escaping () -> Bool = { !FrontmostApplication.secureInputState() }) {
        self.isAllowed = isAllowed
    }

    var canRead: Bool { !communicationFailed && isAllowed() }

    func perform(_ operation: () -> AXError) -> AXError {
        guard canRead else { return communicationFailed ? .cannotComplete : .noValue }
        let result = operation()
        if result == .cannotComplete { communicationFailed = true }
        return result
    }
}
