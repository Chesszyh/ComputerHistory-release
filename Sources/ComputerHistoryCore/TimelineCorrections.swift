import Foundation

/// Corrections refer to source revisions, never to a generated sentence's position.
public struct TimelineCorrections: Codable, Equatable, Sendable {
    public struct Reference: Codable, Equatable, Hashable, Sendable {
        public var memory: String
        public var revision: String
        public var fragment: Int
        public init(memory: String, revision: String, fragment: Int) {
            self.memory = memory; self.revision = revision; self.fragment = fragment
        }
    }
    public enum Action: String, Codable, Sendable { case sameTask, differentTask, split }
    public struct Correction: Codable, Equatable, Sendable, Identifiable {
        public var id: UUID
        public var action: Action
        public var groups: [[Reference]]
        public init(action: Action, groups: [[Reference]]) {
            id = UUID(); self.action = action; self.groups = groups
        }
    }
    public var entries: [Correction] = []
    public init() {}
    public static func load(root: URL) throws -> Self {
        let file = root.appendingPathComponent("timeline-corrections.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return Self() }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
    }
    public func save(root: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: root.appendingPathComponent("timeline-corrections.json"), options: .atomic)
    }
    public static func references(_ item: ActivityNarrative.Item, index: MemoryIndex) -> [Reference] {
        item.sourceMemories.flatMap { memory -> [Reference] in
            guard let entry = index.entries.first(where: { $0.id == memory }) else { return [] }
            let numbers = item.sourceActivities?[memory] ?? Array(1...max(1, ActivityFragment.count(in: entry)))
            return numbers.map { .init(memory: memory, revision: entry.revision, fragment: $0) }
        }
    }
    public func invalidCount(index: MemoryIndex) -> Int { entries.filter { !valid($0, index: index) }.count }
    private func valid(_ correction: Correction, index: MemoryIndex) -> Bool {
        let refs = correction.groups.flatMap { $0 }
        return !refs.isEmpty && refs.allSatisfy { ref in
            index.entries.contains { $0.id == ref.memory && $0.revision == ref.revision
                && ref.fragment > 0 && ref.fragment <= ActivityFragment.count(in: $0) }
        }
    }
    public func applying(to narrative: ActivityNarrative, index: MemoryIndex, away: AwayPeriods) -> ActivityNarrative {
        var result = narrative
        for correction in entries where valid(correction, index: index) {
            let sets = correction.groups.map(Set.init)
            let all = Set(sets.flatMap { $0 })
            // Split only selected facts; unrelated members remain in their original activity.
            result.items = result.items.flatMap { item -> [ActivityNarrative.Item] in
                let refs = Self.references(item, index: index)
                guard !all.isDisjoint(with: refs) else { return [item] }
                var pieces: [[Reference]] = []
                if correction.action == .split {
                    pieces = refs.map { [$0] }
                } else {
                    pieces = sets.map { set in refs.filter { set.contains($0) } }.filter { !$0.isEmpty }
                    let remaining = refs.filter { !all.contains($0) }
                    if !remaining.isEmpty { pieces.append(remaining) }
                }
                if pieces.count == 1 { return [item] }
                return pieces.map { piece in
                    let names = Set(piece.map(\.memory))
                    let sources = index.entries.filter { names.contains($0.id) }.map { MemoryIndex.parse(fileURL: $0.fileURL) ?? $0 }.sorted { $0.startedAt < $1.startedAt }
                    var split = ActivityNarrative.sourceItem(sources, away: away)
                    split.sourceActivities = Dictionary(grouping: piece, by: \.memory).mapValues { $0.map(\.fragment).sorted() }
                    split.sourceRevisions = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0.revision) })
                    split.id = NarrativeGenerator.itemID(for: piece.map { "\($0.memory):\($0.fragment)" })
                    split.taskID = item.taskID
                    split.taskTitle = item.taskTitle
                    split.generationMode = item.generationMode
                    split.summary = sources.flatMap { entry in
                        ActivityFragment.fragments(in: entry).filter { split.sourceActivities?[entry.id]?.contains($0.number) == true }
                    }.map(\.text).joined(separator: "\n\n")
                    let first = split.summary.components(separatedBy: "**")
                    if first.count >= 3 { split.title = ActivityFragment.title(first[1]) }
                    return split
                }
            }
            let affectedTasks = Set(result.items.filter { !all.isDisjoint(with: Self.references($0, index: index)) }.compactMap(\.taskID))
            let taskTitle = result.items.first { !sets[0].isDisjoint(with: Self.references($0, index: index)) }.map { $0.taskTitle ?? $0.title }
            for i in result.items.indices {
                let refs = Set(Self.references(result.items[i], index: index))
                let sameTaskMember = correction.action == .sameTask && result.items[i].taskID.map { affectedTasks.contains($0) } == true
                guard !all.isDisjoint(with: refs) || sameTaskMember else { continue }
                if correction.action == .sameTask {
                    result.items[i].taskID = correction.id.uuidString
                    result.items[i].taskTitle = taskTitle
                }
                else if let group = sets.firstIndex(where: { !$0.isDisjoint(with: refs) }) {
                    result.items[i].taskID = "\(correction.id.uuidString):\(correction.action == .split ? result.items[i].id : String(group))"
                }
            }
        }
        return result
    }
}
