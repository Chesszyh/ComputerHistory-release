import Foundation

/// Freeze only the requested day's inputs; credentials and request budgets stay at the source root.
public enum NarrativePreview {
    public static func prepare(source: URL, destination: URL, day: String) throws -> URL {
        let fm = FileManager.default
        let destination = URL(fileURLWithPath: destination.standardizedFileURL.path, isDirectory: true)
        let marker = destination.appendingPathComponent("preview-source.json")
        let identity = ["source": source.standardizedFileURL.path, "day": day]
        if fm.fileExists(atPath: destination.path) {
            guard let data = try? Data(contentsOf: marker),
                  let previous = try? JSONDecoder().decode([String: String].self, from: data), previous == identity else {
                throw NarrativeGenerator.GenerateError.modelFailed("预览目录已被使用，请选择新目录。")
            }
            return destination
        }
        let index = MemoryIndex.load(from: source.appendingPathComponent("memories"))
        let entries = index.entries.filter { $0.granularity == "10min" && $0.dayLabel() == day }
        guard !entries.isEmpty else { throw NarrativeGenerator.GenerateError.noSourceMemories }
        try fm.createDirectory(at: destination.appendingPathComponent("memories"), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        for entry in entries {
            try fm.copyItem(at: entry.fileURL, to: destination.appendingPathComponent("memories/" + entry.id))
            let metadata = "segments/\(entry.sourceSegmentID)/metadata.json"
            if fm.fileExists(atPath: source.appendingPathComponent(metadata).path) {
                let target = destination.appendingPathComponent(metadata)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: source.appendingPathComponent(metadata), to: target)
            }
        }
        for name in ["summary.json", "away.json", "timeline-edits.json", "timeline-corrections.json"] {
            let file = source.appendingPathComponent(name)
            if fm.fileExists(atPath: file.path) { try fm.copyItem(at: file, to: destination.appendingPathComponent(name)) }
        }
        let names = Set(entries.map(\.id))
        let original = ActivityNarrative.load(root: source)
        let before = ActivityNarrative(generatedAt: original.generatedAt,
            items: original.items.filter { !$0.sourceMemories.isEmpty && Set($0.sourceMemories).isSubset(of: names) })
        try EventStreamJSON.makeEncoder().encode(before).write(to: destination.appendingPathComponent("before-narrative.json"), options: .atomic)
        try JSONEncoder().encode(identity).write(to: marker, options: .atomic)
        return destination
    }
}
