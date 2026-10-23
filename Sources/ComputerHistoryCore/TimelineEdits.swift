import Foundation

/// Manual text belongs to the source memory, so regenerated narrative IDs cannot discard it.
public struct TimelineEdits: Codable, Equatable, Sendable {
    public struct Edit: Codable, Equatable, Sendable {
        public var title: String
        public var summary: String
        public init(title: String, summary: String) { self.title = title; self.summary = summary }
    }
    public var entries: [String: Edit] = [:]
    public init() {}
    public static func load(root: URL) throws -> Self {
        let file = root.appendingPathComponent("timeline-edits.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return Self() }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
    }
    public mutating func set(_ edit: Edit?, for source: String, root: URL) throws {
        entries[source] = edit
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: root.appendingPathComponent("timeline-edits.json"), options: .atomic)
    }
}
