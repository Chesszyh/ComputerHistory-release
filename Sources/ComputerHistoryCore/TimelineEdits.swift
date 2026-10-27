import Foundation

/// Manual text belongs to the source memory, so regenerated narrative IDs cannot discard it.
public struct TimelineEdits: Codable, Equatable, Sendable {
    public struct Edit: Codable, Equatable, Sendable {
        public var title: String
        public var summary: String
        public var revisions: [String: String]?
        public init(title: String, summary: String, revisions: [String: String]? = nil) {
            self.title = title; self.summary = summary; self.revisions = revisions
        }
    }
    public var entries: [String: Edit] = [:]
    public var taskTitles: [String: String]?
    public init() {}

    public static func key(for item: TrayTimelineItem, mode: SummarySettings.TimelineMode) -> String? {
        guard !item.isAway, item.children == nil else { return nil }
        if mode == .fixedTenMinutes, item.memoryFiles.count == 1 { return item.memoryFiles[0].lastPathComponent }
        guard item.isNarrative else { return nil }
        guard let name = item.sourceActivities?.keys.sorted().first,
              let number = item.sourceActivities?[name]?.min() else { return "narrative:" + item.id }
        return "activity:" + name + "#" + String(number)
    }

    public static func taskAnchorKeys(for item: TrayTimelineItem) -> [String] {
        guard let activities = item.sourceActivities else { return [] }
        var keys: [String] = []
        for name in activities.keys.sorted() {
            let numbers: [Int] = activities[name] ?? []
            let revision: String = item.sourceRevisions?[name] ?? ""
            let prefix = "task-source:\(name)#\(revision)#"
            for number in numbers { keys.append(prefix + String(number)) }
        }
        return keys
    }

    public func applying(to item: TrayTimelineItem, mode: SummarySettings.TimelineMode, index: MemoryIndex) -> TrayTimelineItem {
        var item = item
        if let title = Self.taskAnchorKeys(for: item).compactMap({ taskTitles?[$0] }).first {
            item.taskTitle = title
        } else if let task = item.taskID, let title = taskTitles?[task] { item.taskTitle = title }
        guard let key = Self.key(for: item, mode: mode), let edit = entries[key] else { return item }
        if let revisions = edit.revisions {
            let names = Set(item.memoryFiles.map(\.lastPathComponent))
            guard revisions.allSatisfy({ name, revision in
                names.contains(name) && index.entries.first(where: { $0.id == name })?.revision == revision
            }) else { return item }
        }
        item.title = edit.title; item.summary = edit.summary; item.manualEdit = true
        return item
    }
    public static func load(root: URL) throws -> Self {
        let file = root.appendingPathComponent("timeline-edits.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return Self() }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
    }
    public mutating func set(_ edit: Edit?, for source: String, root: URL) throws {
        entries[source] = edit
        try save(root: root)
    }
    public func save(root: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: root.appendingPathComponent("timeline-edits.json"), options: .atomic)
    }
}
