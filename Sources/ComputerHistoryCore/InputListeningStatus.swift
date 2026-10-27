import Foundation

public struct InputListeningStatus: Codable, Equatable, Sendable {
    public var owner: CollectorProcessIdentity
    public var checkedAt: Date
    public var enabled: Bool
    public var keyboard: Bool

    public init(owner: CollectorProcessIdentity, checkedAt: Date = Date(), enabled: Bool, keyboard: Bool) {
        self.owner = owner; self.checkedAt = checkedAt; self.enabled = enabled; self.keyboard = keyboard
    }
    public func save(root: URL) throws {
        try EventStreamJSON.makeEncoder().encode(self).write(to: root.appendingPathComponent("input-listening.json"), options: .atomic)
    }
    public static func load(root: URL, now: Date = Date()) -> Self? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("input-listening.json")),
              let value = try? EventStreamJSON.makeDecoder().decode(Self.self, from: data),
              value.owner == CollectorProcessLease.runningIdentity(root: root),
              now.timeIntervalSince(value.checkedAt) >= 0, now.timeIntervalSince(value.checkedAt) <= 90 else { return nil }
        return value
    }
    public var label: String { enabled ? (keyboard ? "输入监听已启用" : "键盘监听不可用，鼠标与滚动可用") : "输入监听不可用" }
}
