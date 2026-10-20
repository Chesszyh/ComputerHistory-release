import Foundation

public struct ModelHealth: Codable, Sendable {
    public var updatedAt: Date
    public var error: String?
    public var usedFallback: Bool
    public var lastNotification: Date?
    public static func load(root: URL) -> Self? {
        try? JSONDecoder().decode(Self.self, from: Data(contentsOf: root.appendingPathComponent("model-health.json")))
    }
    static func record(root: URL, error: String?, usedFallback: Bool) throws {
        let previous = load(root: root)
        let now = Date()
        let notify = error != nil && now.timeIntervalSince(previous?.lastNotification ?? .distantPast) > 900
        let state = Self(updatedAt: now, error: error, usedFallback: usedFallback,
            lastNotification: notify ? now : previous?.lastNotification)
        try JSONEncoder().encode(state).write(to: root.appendingPathComponent("model-health.json"), options: .atomic)
        if notify, ProcessInfo.processInfo.environment["COMPUTER_HISTORY_NOTIFICATIONS"] != "0" {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", "display notification \"模型请求未能完成，请在总结用量中查看错误并检查模型设置。\" with title \"计算机历史\""]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try? process.run()
        }
    }
}
