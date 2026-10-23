import Foundation

/// 登录界面只留下起止时间，不进入界面采样或模型总结。
public struct AwayPeriods: Codable, Equatable, Sendable {
    public struct Period: Codable, Equatable, Sendable {
        public var start: Date
        public var end: Date
    }
    public var startedAt: Date?
    public var periods: [Period] = []

    func sessionStart(at time: Date) -> Date {
        periods.lazy.filter { $0.end.timeIntervalSince($0.start) >= 60 && $0.end <= time }
            .map(\.end).max() ?? .distantPast
    }

    func activityStart(for entry: MemoryIndex.Entry) -> Date {
        if let first = entry.firstEventAt {
            // Segment metadata truncates subseconds; away.json retains them. A return in the same
            // second is the lower bound, otherwise the first resumed event falls into the old session.
            return periods.lazy.filter {
                $0.start <= first && $0.end > first && $0.end.timeIntervalSince(first) < 1
            }.map(\.end).max() ?? first
        }
        // Legacy memories use clock buckets; a return inside that bucket is a known lower bound.
        let end = entry.startedAt.addingTimeInterval(SegmentClock.durationSeconds)
        return periods.lazy.filter {
            $0.start <= entry.startedAt && $0.end > entry.startedAt && $0.end < end
        }.map(\.end).max() ?? entry.startedAt
    }

    func activityEnd(for entry: MemoryIndex.Entry) -> Date {
        let start = activityStart(for: entry)
        let boundary = periods.lazy.filter { $0.start >= start }.map(\.start).min()
        return max(start, min(entry.endedAt ?? start, boundary ?? .distantFuture))
    }

    func activityGroups(_ entries: [MemoryIndex.Entry]) -> [[MemoryIndex.Entry]] {
        let ordered = entries.sorted {
            let left = activityStart(for: $0), right = activityStart(for: $1)
            return left == right ? $0.id < $1.id : left < right
        }
        var groups: [[MemoryIndex.Entry]] = []
        for entry in ordered {
            if let last = groups.last?.last,
               sessionStart(at: activityStart(for: last)) == sessionStart(at: activityStart(for: entry)) {
                groups[groups.count - 1].append(entry)
            } else { groups.append([entry]) }
        }
        return groups
    }
    public static func isLoginWindow(_ app: EventStreamApp?) -> Bool {
        app?.bundleIdentifier == "com.apple.loginwindow"
    }
    public static func load(root: URL) -> Self {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("away.json")),
              let value = try? EventStreamJSON.makeDecoder(acceptingLegacyNumericDates: true).decode(Self.self, from: data) else { return Self() }
        return value
    }
    public func save(root: URL) throws {
        try EventStreamJSON.makeEncoder(preservingSubseconds: true).encode(self).write(to: root.appendingPathComponent("away.json"), options: .atomic)
    }
}
