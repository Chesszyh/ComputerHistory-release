import Foundation
import CoreGraphics

public struct PermissionStatus: Codable, Sendable {
    public var accessibility: Bool
    public var inputMonitoring: Bool
    public var screenRecording: Bool

    public static func current() -> Self {
        .init(accessibility: InputTap.hasAccessibilityPermission,
              inputMonitoring: InputTap.hasInputMonitoringPermission,
              screenRecording: CGPreflightScreenCaptureAccess())
    }
    public static func request(_ kind: String) throws {
        switch kind {
        case "accessibility": _ = InputTap.requestAccessibilityPermission()
        case "input": _ = InputTap.requestInputMonitoringPermission()
        case "screen": _ = CGRequestScreenCaptureAccess()
        default: throw ConfigurationInputError.invalid("未知权限。")
        }
    }
}
