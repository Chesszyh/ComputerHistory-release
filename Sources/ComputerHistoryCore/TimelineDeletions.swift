import Foundation

/// 展示删除独立于生成缓存，避免后台整理重新写入同一条消息。
public struct TimelineDeletions: Codable, Sendable, Equatable {
    public struct Record: Codable, Sendable, Equatable, Identifiable {
        public var item: TrayTimelineItem
        public var deletedAt: Date?
        public var id: String { item.deletionID }
    }
    public var ids: Set<String> = []
    public var records: [Record] = []
    public var restoredItems: [TrayTimelineItem] = []
    public var purgedIDs: Set<String> = []
    public static let fileName = "timeline-deletions.json"
    public init() {}

    private enum CodingKeys: String, CodingKey { case ids, records, purgedIDs, restoredItems }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        ids = try values.decode(Set<String>.self, forKey: .ids)
        records = try values.decodeIfPresent([Record].self, forKey: .records) ?? []
        restoredItems = try values.decodeIfPresent([TrayTimelineItem].self, forKey: .restoredItems) ?? []
        purgedIDs = try values.decodeIfPresent(Set<String>.self, forKey: .purgedIDs) ?? []
    }

    public static func load(root: URL) throws -> Self {
        let url = root.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        return try EventStreamJSON.makeDecoder(acceptingLegacyNumericDates: true).decode(Self.self, from: Data(contentsOf: url))
    }

    private func save(root: URL) throws {
        let encoder = EventStreamJSON.makeEncoder(preservingSubseconds: true)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try encoder.encode(self).write(to: root.appendingPathComponent(Self.fileName), options: .atomic)
    }

    public static func delete(_ item: TrayTimelineItem, root: URL) throws {
        var value = try load(root: root)
        guard !item.isAway, !value.ids.contains(item.deletionID) else { return }
        value.restoredItems.removeAll { $0.deletionID == item.deletionID }
        value.ids.insert(item.deletionID)
        value.records.append(Record(item: item, deletedAt: Date()))
        try value.save(root: root)
    }

    public static func restore(id: String, root: URL, item: TrayTimelineItem? = nil) throws {
        var value = try load(root: root)
        guard !value.purgedIDs.contains(id) else {
            throw CocoaError(.fileNoSuchFile)
        }
        if let snapshot = value.records.first(where: { $0.id == id })?.item ?? item,
           !value.restoredItems.contains(where: { $0.deletionID == id }) {
            value.restoredItems.append(snapshot)
        }
        value.ids.remove(id)
        value.records.removeAll { $0.id == id }
        try value.save(root: root)
    }

    public static func purge(id: String, root: URL) throws {
        var value = try load(root: root)
        guard value.ids.contains(id) else { return }
        value.records.removeAll { $0.id == id }
        value.purgedIDs.insert(id)
        try value.save(root: root)
    }

    public func trashEntries(candidates: [TrayTimelineItem]) -> [Record] {
        let saved = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let current = Dictionary(candidates.map { ($0.deletionID, $0) }, uniquingKeysWith: { _, last in last })
        return ids.subtracting(purgedIDs).map { id in
            if let record = saved[id] { return record }
            if let item = current[id] { return Record(item: item, deletedAt: nil) }
            let narrative = id.hasPrefix("narrative:")
            let item = TrayTimelineItem(id: String(id.dropFirst(narrative ? 10 : 7)), timestamp: .distantPast,
                title: "来源已不可用的总结", summary: "", apps: [], isNarrative: narrative,
                memoryFiles: [], coveredCount: 1, eventCount: nil, endTimestamp: .distantPast)
            return Record(item: item, deletedAt: nil)
        }.sorted {
            let left = $0.deletedAt ?? $0.item.timestamp, right = $1.deletedAt ?? $1.item.timestamp
            return left == right ? $0.id < $1.id : left > right
        }
    }
}
