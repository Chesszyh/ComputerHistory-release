import Foundation

/// 前端叙述条目：供托盘时间线直接展示的第三层总结。
///
/// 三层流水线：
///   1. 原始事件 → 十分钟记忆（`MemoryGenerator`，含事实细节与引用）
///   2. 十分钟记忆 → 叙述条目（本类型，面向快速回忆与定位）
///
/// 第二层不是第一层的缩写，而是**换一种用途**：记忆文件用于追溯（含事件路径、
/// 完整分节），叙述条目用于扫读（标题 + 一两句 + 时刻 + 应用）。
public struct ActivityNarrative: Codable, Sendable, Equatable {

    public struct Item: Codable, Sendable, Equatable, Identifiable {
        /// 稳定标识：由覆盖的源记忆文件名派生，便于去重与增量更新。
        public var id: String
        /// 本条覆盖时段的起始时刻。
        public var timestamp: Date
        /// 动词 + 对象，不含「用户」「进行」这类空词。
        public var title: String
        /// 第二人称，一到两句，说明目标、关键操作与结果或当前状态。
        public var summary: String
        /// 涉及的应用 bundleID。
        public var apps: [String]
        /// 本条归纳自哪些记忆文件（文件名）。
        public var sourceMemories: [String]
        public var sourceRevisions: [String: String]?
        /// 每个来源内的活动条目编号；旧记录缺省表示整份来源。
        public var sourceActivities: [String: [Int]]?
        public var sourceSteps: [String: [Int]]?
        public var sourceIncidental: [String: [Int]]?
        public var previousIDs: [String]?
        public var generationMode: SummarySettings.TimelineMode?
        public var taskID: String?
        public var taskTitle: String?

        public var isIncidentalOnly: Bool {
            guard let activities = sourceActivities, !activities.isEmpty else { return false }
            return activities.allSatisfy { name, numbers in
                Set(numbers).isSubset(of: sourceIncidental?[name] ?? [])
            }
        }

        public init(id: String, timestamp: Date, title: String,
                    summary: String, apps: [String], sourceMemories: [String]) {
            self.id = id
            self.timestamp = timestamp
            self.title = title
            self.summary = summary
            self.apps = apps
            self.sourceMemories = sourceMemories
        }
    }

    public var generatedAt: Date
    public var items: [Item]

    public init(generatedAt: Date = Date(), items: [Item] = []) {
        self.generatedAt = generatedAt
        self.items = items
    }

    static func sourceItem(_ entries: [MemoryIndex.Entry], away: AwayPeriods, previous: Item? = nil) -> Item {
        let names = entries.map(\.id)
        var item = Item(id: NarrativeGenerator.itemID(for: names), timestamp: away.activityStart(for: entries[0]),
            title: entries[0].activityTitle,
            summary: entries.map(\.activitySummary).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: "\n\n"),
            apps: entries.flatMap(\.applications).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }, sourceMemories: names)
        if let previous {
            item.taskID = previous.taskID
            item.taskTitle = previous.taskTitle
            item.previousIDs = Array(Set([previous.id] + (previous.previousIDs ?? []))).filter { $0 != item.id }.sorted()
        }
        return item
    }

    func separatingAwayPeriods(index: MemoryIndex, away: AwayPeriods,
                               mode: SummarySettings.TimelineMode = .continuous) -> Self {
        let lookup = Dictionary(uniqueKeysWithValues: index.entries.map { ($0.id, $0) })
        if mode == .fixedTenMinutes {
            var result = self
            let unavailable = items.filter { $0.sourceMemories.isEmpty || !$0.sourceMemories.allSatisfy { lookup[$0] != nil } }
            let unavailableIDs = Set(unavailable.map(\.id))
            let ownersByMemory = items.filter { !unavailableIDs.contains($0.id) }.reduce(into: [String: [Item]]()) { groups, item in
                for name in item.sourceMemories { groups[name, default: []].append(item) }
            }
            result.items = unavailable + ownersByMemory.keys.sorted().compactMap { name in
                guard let entry = lookup[name] else { return nil }
                let owners = ownersByMemory[name]!
                if owners.count == 1, let owner = owners.first, owner.sourceMemories == [name],
                   owner.sourceSteps == nil, owner.sourceIncidental == nil,
                   owner.sourceActivities?[name] == nil || owner.sourceActivities?[name]?.count == ActivityFragment.count(in: entry) {
                    var adjusted = owner
                    adjusted.timestamp = away.activityStart(for: entry)
                    return adjusted
                }
                var item = Self.sourceItem([entry], away: away)
                item.previousIDs = Array(Set(owners.flatMap { [$0.id] + ($0.previousIDs ?? []) })).filter { $0 != item.id }.sorted()
                return item
            }
            return result
        }
        let ordered = index.entries.filter { $0.granularity == "10min" }.sorted {
            let left = away.activityStart(for: $0), right = away.activityStart(for: $1)
            return left == right ? $0.id < $1.id : left < right
        }
        let positions = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0.element.id, $0.offset) })
        var result = self
        result.items = items.flatMap { item -> [Item] in
            let entries = item.sourceMemories.compactMap { lookup[$0] }
            guard !entries.isEmpty, entries.count == item.sourceMemories.count else { return [item] }
            let groups = away.activityGroups(entries).flatMap { group -> [[MemoryIndex.Entry]] in
                var runs: [[MemoryIndex.Entry]] = []
                for entry in group {
                    if mode == .continuous, let last = runs.last?.last,
                       last.noClearActivity == entry.noClearActivity,
                       !NarrativeGenerator.hasCollectionBoundary(last, entry),
                       last.inputListeningDegraded == entry.inputListeningDegraded,
                       let before = positions[last.id], positions[entry.id] == before + 1 {
                        runs[runs.count - 1].append(entry)
                    } else { runs.append([entry]) }
                }
                return runs
            }
            if groups.count == 1 {
                var adjusted = item
                adjusted.timestamp = away.activityStart(for: groups[0][0])
                return [adjusted]
            }
            // A whole-day summary cannot be attributed to any one episode. Use each episode's sources
            // until the user chooses to regenerate the automatic summaries.
            return groups.map { entries in
                var split = Self.sourceItem(entries, away: away, previous: item)
                if let activities = item.sourceActivities {
                    let selected = activities.filter { split.sourceMemories.contains($0.key) }
                    split.sourceActivities = selected
                    split.sourceSteps = item.sourceSteps?.filter { selected[$0.key] != nil }
                    split.sourceIncidental = item.sourceIncidental?.filter { selected[$0.key] != nil }
                    split.id = NarrativeGenerator.itemID(for: split.sourceMemories.map { name in
                        name + ":" + (selected[name] ?? []).sorted().map(String.init).joined(separator: ",")
                    })
                    split.title = item.title
                    split.summary = ActivityFragment.details(files: entries.map(\.fileURL), activities: selected)
                        .map(\.text).joined(separator: "\n\n")
                }
                return split
            }
        }
        return result
    }

    /// 缓存文件名，位于数据根目录下。
    public static let fileName = "narrative.json"

    public static func fileURL(root: URL) -> URL {
        root.appendingPathComponent(fileName)
    }

    /// 读取缓存。缺失或损坏时返回空——托盘应能在没有缓存时正常显示其余部分。
    public static func load(root: URL) -> ActivityNarrative {
        guard let data = try? Data(contentsOf: Self.fileURL(root: root)) else {
            return ActivityNarrative()
        }
        let decoder = EventStreamJSON.makeDecoder()
        guard let decoded = try? decoder.decode(ActivityNarrative.self, from: data) else {
            return ActivityNarrative()
        }
        return decoded
    }

    public func save(root: URL) throws {
        let encoder = EventStreamJSON.makeEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: Self.fileURL(root: root), options: .atomic)
    }

    /// 按天分组，新的在前。
    public func groupedByDay(timeZone: TimeZone = .current)
        -> [(day: String, items: [Item])] {
        var groups: [String: [Item]] = [:]
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        for item in items {
            groups[f.string(from: item.timestamp), default: []].append(item)
        }
        return groups.keys.sorted(by: >).map {
            ($0, groups[$0]!.sorted { $0.timestamp > $1.timestamp })
        }
    }
}
