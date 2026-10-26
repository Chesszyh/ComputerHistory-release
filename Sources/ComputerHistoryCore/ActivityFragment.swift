import Foundation

/// 原有活动正文中的条目；编号只表示原文位置，不推断条目的精确发生时间。
public struct ActivityFragment: Sendable, Equatable {
    public var number: Int
    public var text: String

    public struct Detail: Identifiable, Sendable {
        public var id: String
        public var time: String
        public var text: String
    }

    public static func details(files: [URL], activities: [String: [Int]]?, excluding: [String: [Int]]? = nil) -> [Detail] {
        files.compactMap { file in
            guard let entry = MemoryIndex.parse(fileURL: file) else { return nil }
            let selected = activities?[entry.id]
            let text = fragments(in: entry).filter { fragment in
                (selected.map { $0.contains(fragment.number) } ?? true) && excluding?[entry.id]?.contains(fragment.number) != true
            }
                .map(\.text).joined(separator: "\n\n")
            guard !text.isEmpty else { return nil }
            return Detail(id: entry.id, time: entry.timeLabel(), text: ActivityExport.formatted(text, format: "txt"))
        }
    }

    public static func title(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasSuffix("。") { result.removeLast() }
        return result
    }

    public static func count(in entry: MemoryIndex.Entry) -> Int {
        entry.activityFragmentCount ?? fragments(in: entry).count
    }

    public static func fragments(in entry: MemoryIndex.Entry) -> [Self] {
        let content = entry.sections.filter { ["本次活动", "整体走向", "延续的工作线"].contains($0.heading) }
            .map(\.content).joined(separator: "\n\n")
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return [.init(number: 1, text: entry.summary)]
        }
        var blocks: [String] = []
        var lines: [String] = []
        func flush() {
            let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(text) }
            lines = []
        }
        for line in content.components(separatedBy: .newlines) {
            if line.range(of: #"^(?:[-*] )?\*\*[^*]+\*\*"#, options: .regularExpression) != nil {
                flush()
            }
            lines.append(line)
        }
        flush()
        return blocks.enumerated().map { .init(number: $0.offset + 1, text: $0.element) }
    }
}
