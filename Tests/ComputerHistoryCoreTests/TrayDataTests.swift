import Foundation
import XCTest
@testable import ComputerHistoryCore

/// 托盘应用数据层的测试：记忆索引与采集状态。
final class TrayDataTests: XCTestCase {

    private func tempRoot() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ch-tray-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 造一份与 MemoryWriter 输出同构的记忆文件。
    @discardableResult
    private func writeMemory(_ dir: URL, segmentID: String, granularity: String = "10min",
                             title: String, summary: String,
                             apps: [String] = ["com.example.app"]) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = MemoryWriter.fileName(segmentID: segmentID, granularity: granularity)
        let text = """
        ---
        title: \(title)
        description: \(summary)
        applications: [\(apps.joined(separator: ", "))]
        ---

        ## Memory summary

        ### Relevant prior context
        无此前记录。

        ### 本次活动
        做了些事情。
        """
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - 记忆索引

    /// 文件名解析出时刻、粒度与标识码。
    func testParseFileNameFields() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let url = try writeMemory(root, segmentID: "2026-10-11T17-20-00Z",
                                  title: "标题", summary: "描述")
        let entry = try XCTUnwrap(MemoryIndex.parse(fileURL: url))
        XCTAssertEqual(entry.granularity, "10min")
        XCTAssertEqual(entry.startedAt,
                       SegmentClock.date(fromSegmentID: "2026-10-11T17-20-00Z"))
        XCTAssertEqual(entry.title, "标题")
        XCTAssertEqual(entry.summary, "描述")
        XCTAssertEqual(entry.applications, ["com.example.app"])
    }

    /// 带 UUID 后缀的段也能解析出正确时刻。
    func testParseSuffixedSegmentID() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let id = "2026-10-13T04-00-00Z_4D08EBD2-0DF4-4253-9879-A2BCDC790737"
        let url = try writeMemory(root, segmentID: id, title: "T", summary: "D")
        let entry = try XCTUnwrap(MemoryIndex.parse(fileURL: url))
        XCTAssertEqual(entry.startedAt,
                       SegmentClock.date(fromSegmentID: "2026-10-13T04-00-00Z"))
    }

    /// 6h 粒度识别正确。
    func testParseSixHourGranularity() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let url = try writeMemory(root, segmentID: "2026-10-06T12-00-00Z",
                                  granularity: "6h", title: "T", summary: "D")
        let entry = try XCTUnwrap(MemoryIndex.parse(fileURL: url))
        XCTAssertEqual(entry.granularity, "6h")
    }

    /// 不符合命名约定的文件不参与——外部放入的 Markdown 不应污染时间线。
    func testUnrelatedMarkdownIgnored() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try "# 随手记".write(to: root.appendingPathComponent("notes.md"),
                          atomically: true, encoding: .utf8)
        XCTAssertNil(MemoryIndex.parse(fileURL: root.appendingPathComponent("notes.md")))
        XCTAssertTrue(MemoryIndex.load(from: root).entries.isEmpty)
    }

    /// frontmatter 被剥离，正文保留；`###` 小节被切出。
    func testBodyAndSectionsParsed() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let url = try writeMemory(root, segmentID: "2026-10-11T17-20-00Z",
                                  title: "标题", summary: "描述")
        let entry = try XCTUnwrap(MemoryIndex.parse(fileURL: url))
        XCTAssertFalse(entry.body.contains("title:"), "frontmatter 不应留在正文里")
        XCTAssertTrue(entry.body.contains("## Memory summary"))
        let headings = entry.sections.map(\.heading)
        XCTAssertTrue(headings.contains("Relevant prior context"))
        XCTAssertTrue(headings.contains("本次活动"))
    }

    /// 索引按时间倒序，新的在前。
    func testEntriesSortedNewestFirst() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try writeMemory(root, segmentID: "2026-10-11T10-00-00Z", title: "早", summary: "D")
        try writeMemory(root, segmentID: "2026-10-11T12-00-00Z", title: "晚", summary: "D")
        let index = MemoryIndex.load(from: root)
        XCTAssertEqual(index.entries.map(\.title), ["晚", "早"])
        XCTAssertEqual(index.recent(1).map(\.title), ["晚"])
    }

    /// 目录不存在时返回空索引而不报错——首次启动时目录可能还没有。
    func testMissingDirectoryYieldsEmptyIndex() {
        let missing = URL(fileURLWithPath: "/tmp/ch-tray-does-not-exist-\(UUID())")
        XCTAssertTrue(MemoryIndex.load(from: missing).entries.isEmpty)
    }

    /// 按天分组。
    func testGroupedByDay() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try writeMemory(root, segmentID: "2026-10-11T10-00-00Z", title: "A", summary: "D")
        try writeMemory(root, segmentID: "2026-10-11T12-00-00Z", title: "B", summary: "D")
        try writeMemory(root, segmentID: "2026-10-12T10-00-00Z", title: "C", summary: "D")
        let groups = MemoryIndex.load(from: root).groupedByDay()
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].entries.count, 1, "新的天在前")
        XCTAssertEqual(groups[1].entries.map(\.title), ["B", "A"])
    }

    // MARK: - 采集状态

    /// 无进程时状态为未运行，且不谎报数据量。
    func testStatusWithoutCollector() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let status = CollectorStatus.read(root: root)
        XCTAssertFalse(status.process.running)
        XCTAssertNil(status.process.pid)
        XCTAssertEqual(status.data.segmentCount, 0)
        XCTAssertEqual(status.memories.count, 0)
        XCTAssertFalse(status.isStalled, "未运行不算停滞")
    }

    /// 段数与事件数被统计；记忆数与待补写量按粒度分开计。
    func testStatusCountsDataAndMemories() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let decoder = EventStreamJSON.makeDecoder()

        // 两个段，各 3 条事件
        for id in ["2026-10-11T10-00-00Z", "2026-10-11T10-10-00Z"] {
            let dir = root.appendingPathComponent("segments").appendingPathComponent(id)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var lines = ""
            for i in 1...3 {
                let record = EventStreamRecord(
                    id: i, timestamp: Date(timeIntervalSince1970: 1_800_000_000 + Double(i)),
                    kind: .windowChanged,
                    app: EventStreamApp(name: "A", bundleIdentifier: "com.a"),
                    window: nil, mouse: nil, keyboard: nil, selection: nil, ax: nil)
                lines += String(decoding: try EventStreamJSON.makeEncoder().encode(record),
                                as: UTF8.self) + "\n"
            }
            try lines.write(to: dir.appendingPathComponent("events.jsonl"),
                            atomically: true, encoding: .utf8)
            // 只有封口的段才计入待补写判断。
            try "{}".write(to: dir.appendingPathComponent("metadata.json"),
                           atomically: true, encoding: .utf8)
            _ = decoder
        }

        // 只为其中一个段生成记忆
        try writeMemory(root.appendingPathComponent("memories"),
                        segmentID: "2026-10-11T10-00-00Z", title: "T", summary: "D")
        try writeMemory(root.appendingPathComponent("memories"),
                        segmentID: "2026-10-06T12-00-00Z", granularity: "6h",
                        title: "H", summary: "D")

        let status = CollectorStatus.read(root: root)
        XCTAssertEqual(status.data.segmentCount, 2)
        XCTAssertEqual(status.data.eventCount, 6)
        XCTAssertEqual(status.memories.tenMinuteCount, 1)
        XCTAssertEqual(status.memories.sixHourCount, 1)
        XCTAssertEqual(status.memories.pendingSegments, 1, "2 段 − 1 份十分钟记忆")
        XCTAssertNotNil(status.data.earliest)
    }

    /// 运行时长与体积标签可读。
    func testStatusLabels() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let status = CollectorStatus.read(root: root)
        XCTAssertEqual(status.uptimeLabel(), "—", "未运行时不显示时长")
        XCTAssertFalse(status.sizeLabel().isEmpty)
    }
}
