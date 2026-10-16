import Foundation

/// 登录界面只留下起止时间，不进入界面采样或模型总结。
public struct AwayPeriods: Codable, Equatable, Sendable {
    public struct Period: Codable, Equatable, Sendable {
        public var start: Date
        public var end: Date
    }
    public var startedAt: Date?
    public var periods: [Period] = []
    public static func isLoginWindow(_ app: EventStreamApp?) -> Bool {
        app?.bundleIdentifier == "com.apple.loginwindow"
    }
    public static func load(root: URL) -> Self {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("away.json")),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
    public func save(root: URL) throws {
        try JSONEncoder().encode(self).write(to: root.appendingPathComponent("away.json"), options: .atomic)
    }
}
