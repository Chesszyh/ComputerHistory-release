import Foundation

/// 前端叙述条目：供托盘时间线直接展示的第三层总结。
///
/// 三层流水线：
///   1. 原始事件 → 十分钟记忆（`MemoryGenerator`，含事实细节与引用）
///   2. 十分钟记忆 → 叙述条目（本类型，面向快速回忆与定位）
///
/// 第二层不是第一层的缩写，而是**换一种用途**：记忆文件用于追溯（含事件路径、
/// 完整分节），叙述条目用于扫读（标题 + 一两句 + 时刻 + 应用）。
public struct ActivityNarrative: Codable, Sendable {

    public struct Item: Codable, Sendable, Identifiable {
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
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(ActivityNarrative.self, from: data) else {
            return ActivityNarrative()
        }
        return decoded
    }

    public func save(root: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
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
