import Foundation
import CryptoKit

/// 记忆文件索引：把 `memories/` 下的 `.md` 读成可展示的时间线条目。
///
/// 只解析本实现写出的固定结构（frontmatter 三字段 + 分节正文），
/// 不做通用 Markdown 解析——记忆文件由 `MemoryWriter` 生成，形态是受控的。
public struct MemoryIndex: Sendable {

    /// 一条记忆。
    public struct Entry: Sendable, Identifiable {
        public var id: String { fileURL.lastPathComponent }
        public var fileURL: URL
        /// 段起始时刻，从文件名解析。
        public var startedAt: Date
        /// 该记忆对应的段 ID（含 UUID 后缀，与段目录名一致）。
        public var sourceSegmentID: String
        /// 粒度：`10min` 或 `6h`。
        public var granularity: String
        public var title: String
        public var summary: String
        public var applications: [String]
        /// frontmatter 之后的正文。
        public var body: String
        /// 正文里各小节标题，用于折叠展示。
        public var sections: [(heading: String, content: String)]
        public var noClearActivity: Bool = false
        public var inputListeningDegraded: Bool = false
        public var generationStatus: String? = nil
        public var revision: String = ""
        public var firstEventAt: Date? = nil
        public var endedAt: Date? = nil
        public var endReason: String? = nil
        public var activityFragmentCount: Int? = nil

        public var activitySummary: String {
            if inputListeningDegraded { return ActivityEvidence.inputDegradedSummary }
            if noClearActivity { return ActivityEvidence.noActivitySummary }
            return String(ActivityExport.formatted(ActivityExport.text(for: self), format: "txt").prefix(1800))
        }
        public var activityTitle: String {
            if inputListeningDegraded { return ActivityEvidence.inputDegradedTitle }
            if noClearActivity { return ActivityEvidence.noActivityTitle }
            let content = sections.filter { ["本次活动", "整体走向", "延续的工作线"].contains($0.heading) }
                .map(\.content).joined(separator: "\n")
            guard let first = content.split(separator: "\n").first,
                  let heading = first.range(of: #"^(?:[-*] )?\*\*[^*]+\*\*"#, options: .regularExpression) else { return title }
            return ActivityFragment.title(String(first[heading]).replacingOccurrences(of: #"^[-*] "#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "**", with: ""))
        }

        /// 用于展示的时刻，形如 `15:40`。
        public func timeLabel(timeZone: TimeZone = .current) -> String {
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            f.timeZone = timeZone
            f.locale = Locale(identifier: "en_US_POSIX")
            return f.string(from: startedAt)
        }

        public func dayLabel(timeZone: TimeZone = .current) -> String {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.timeZone = timeZone
            f.locale = Locale(identifier: "en_US_POSIX")
            return f.string(from: startedAt)
        }
    }

    public var entries: [Entry]

    public init(entries: [Entry]) { self.entries = entries }

    /// 扫描目录。文件不存在时返回空索引而非报错——应用首次启动时目录可能还没有。
    public static func load(from directory: URL) -> MemoryIndex {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else {
            return MemoryIndex(entries: [])
        }
        let entries = files
            .filter { $0.pathExtension == "md" }
            .compactMap { parse(fileURL: $0) }
            .sorted { $0.startedAt == $1.startedAt ? $0.id < $1.id : $0.startedAt > $1.startedAt }
        return MemoryIndex(entries: entries)
    }

    /// 解析单个记忆文件。文件名不符合约定时返回 nil（外部放入的文件不参与）。
    public static func parse(fileURL: URL) -> Entry? {
        let name = fileURL.lastPathComponent
        guard name.hasSuffix("-memory-summary.md") else { return nil }

        // 形如 `<段ID>-<4位码>-<粒度>-memory-summary.md`。
        // 段 ID 可能带 `_UUID` 后缀，故从右侧按固定段数切分更稳。
        let stem = String(name.dropLast("-memory-summary.md".count))
        let parts = stem.split(separator: "-")
        guard parts.count >= 3 else { return nil }
        let granularity = String(parts[parts.count - 1])
        let code = String(parts[parts.count - 2])
        guard code.count == 4 else { return nil }
        var segmentID = parts[0..<(parts.count - 2)].joined(separator: "-")
        guard let startedAt = SegmentClock.date(fromSegmentID: segmentID) else { return nil }

        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        let front = MemoryWriter.parseFrontmatter(text)
        let noClearActivity = text.hasPrefix("---\n") && text.dropFirst(4).split(separator: "\n")
            .prefix { $0 != "---" }.contains("activity_status: no_clear_activity")
        let inputListeningDegraded = text.hasPrefix("---\n") && text.dropFirst(4).split(separator: "\n")
            .prefix { $0 != "---" }.contains("activity_status: input_listening_degraded")
        let apps = parseApplications(text)
        let body = stripFrontmatter(text)
        // 文件名省略重启段的 UUID，来源引用保留完整 ID；短码校验避免认错同窗的段。
        if granularity == "10min", let citations = body.components(separatedBy: "## Citations\n").last {
            for line in citations.split(separator: "\n") where line.hasPrefix("- ") {
                let path = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                let url = URL(fileURLWithPath: path)
                guard ["events.jsonl", "events.jsonl.gz"].contains(url.lastPathComponent) else { continue }
                let candidate = url.deletingLastPathComponent().lastPathComponent
                if MemoryWriter.fileName(segmentID: candidate) == name {
                    segmentID = candidate
                    break
                }
            }
        }
        let metadataURL = fileURL.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("segments/\(segmentID)/metadata.json")
        let metadata = granularity == "10min" ? (try? EventStreamJSON.makeDecoder()
            .decode(EventStreamMetadata.self, from: Data(contentsOf: metadataURL))) : nil

        let unknownPassiveCoverage = noClearActivity && metadata?.inputListeningDegraded == nil
        return Entry(fileURL: fileURL, startedAt: startedAt,
                     sourceSegmentID: segmentID, granularity: granularity,
                     title: front.title, summary: front.description,
                     applications: apps, body: body,
                     sections: parseSections(body),
                     noClearActivity: noClearActivity && !unknownPassiveCoverage,
                     inputListeningDegraded: inputListeningDegraded || unknownPassiveCoverage,
                     generationStatus: text.split(separator: "\n").first(where: { $0.hasPrefix("generation: ") }).map { String($0.dropFirst(12)) },
                     revision: SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined(),
                     firstEventAt: metadata?.firstEventAt, endedAt: metadata?.endedAt, endReason: metadata?.endReason)
    }

    static func parseApplications(_ text: String) -> [String] {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.hasPrefix("applications: ") else { continue }
            let raw = line.dropFirst("applications: ".count)
                .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            return raw.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        return []
    }

    static func stripFrontmatter(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return text
        }
        lines.removeFirst()
        while let first = lines.first {
            lines.removeFirst()
            if first.trimmingCharacters(in: .whitespaces) == "---" { break }
        }
        return lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 按 `###` 小节切分正文。
    static func parseSections(_ body: String) -> [(heading: String, content: String)] {
        var result: [(String, String)] = []
        var currentHeading: String?
        var buffer: [String] = []

        func flush() {
            guard let heading = currentHeading else { return }
            let content = buffer.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            result.append((heading, content))
        }

        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("### ") {
                flush()
                currentHeading = String(line.dropFirst(4))
                buffer = []
            } else if line.hasPrefix("## ") {
                // 二级标题不单独成条目，但其内容归入当前小节之前的引言。
                flush()
                currentHeading = nil
                buffer = []
            } else if currentHeading != nil {
                buffer.append(String(line))
            }
        }
        flush()
        return result
    }

    // MARK: - 查询

    /// 按天分组，新的在前。
    public func groupedByDay(timeZone: TimeZone = .current) -> [(day: String, entries: [Entry])] {
        var groups: [String: [Entry]] = [:]
        for entry in entries {
            groups[entry.dayLabel(timeZone: timeZone), default: []].append(entry)
        }
        return groups.keys.sorted(by: >).map { ($0, groups[$0]!.sorted { $0.startedAt > $1.startedAt }) }
    }

    /// 最近若干条，用于托盘菜单的简要展示。
    public func recent(_ count: Int) -> [Entry] {
        Array(entries.prefix(count))
    }
}
