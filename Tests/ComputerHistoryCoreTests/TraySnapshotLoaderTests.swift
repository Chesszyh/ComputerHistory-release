import Foundation
import XCTest
@testable import ComputerHistoryCore

final class TraySnapshotLoaderTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func segment(_ root: URL, id: String = "2026-10-16T00-00-00Z", text: String) throws -> URL {
        let dir = root.appendingPathComponent("segments/\(id)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("events.jsonl")
        try Data(text.utf8).write(to: file)
        return file
    }
    func testCountsOnlyAppendedBytesAndRebuildsAfterReplacementOrTruncation() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try segment(root, text: "one\npart")
        let loader = TraySnapshotLoader()
        let first = await loader.load(root: root)
        XCTAssertEqual(first.status.data.eventCount, 2)
        XCTAssertEqual(first.eventBytesRead, 8)
        let unchanged = await loader.load(root: root)
        XCTAssertEqual(unchanged.eventBytesRead, 0)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("ial\nthree".utf8))
        try handle.close()
        let appended = await loader.load(root: root)
        XCTAssertEqual(appended.eventBytesRead, 9)
        XCTAssertEqual(appended.status.data.eventCount, 3)
        try Data("x\n".utf8).write(to: file)
        let truncated = await loader.load(root: root)
        XCTAssertEqual(truncated.status.data.eventCount, 1)
        XCTAssertEqual(truncated.eventBytesRead, 2)
        try Data("a\nb\nc\n".utf8).write(to: file, options: .atomic)
        let replaced = await loader.load(root: root)
        XCTAssertEqual(replaced.status.data.eventCount, 3)
        XCTAssertEqual(replaced.eventBytesRead, 6)
        try FileManager.default.removeItem(at: file.deletingLastPathComponent())
        let deleted = await loader.load(root: root)
        XCTAssertEqual(deleted.status.data.eventCount, 0)
    }
    func testSealedMetadataAndMemoryCacheInvalidate() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try segment(root, text: "a\nb\n")
        let metadata = file.deletingLastPathComponent().appendingPathComponent("metadata.json")
        try Data(#"{"eventCount":2}"#.utf8).write(to: metadata)
        let dir = root.appendingPathComponent("memories")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let memory = dir.appendingPathComponent("2026-10-16T00-00-00Z-1234-10min-memory-summary.md")
        try "---\ntitle: first\ndescription: fixture\napplications: [com.example.app]\n---\n### body\ntext".write(to: memory, atomically: true, encoding: .utf8)
        let loader = TraySnapshotLoader()
        let first = await loader.load(root: root)
        XCTAssertEqual(first.eventBytesRead, 0)
        XCTAssertEqual(first.memoriesParsed, 1)
        XCTAssertEqual(first.status.memories.pendingSegments, 0)
        let unchanged = await loader.load(root: root)
        XCTAssertEqual(unchanged.memoriesParsed, 0)
        XCTAssertEqual(unchanged.groups, first.groups)
        try "---\ntitle: rewritten\ndescription: new fixture\n---".write(to: memory, atomically: true, encoding: .utf8)
        let rewritten = await loader.load(root: root)
        XCTAssertEqual(rewritten.memoriesParsed, 1)
        XCTAssertEqual(rewritten.groups.first?.items.first?.title, "rewritten")
        try Data("invalid".utf8).write(to: metadata)
        let fallback = await loader.load(root: root)
        XCTAssertEqual(fallback.eventBytesRead, 4)
        XCTAssertEqual(fallback.status.data.eventCount, 2)
        let cached = await loader.load(root: root)
        XCTAssertEqual(cached.eventBytesRead, 0)
        try FileManager.default.removeItem(at: memory)
        let deleted = await loader.load(root: root)
        XCTAssertTrue(deleted.groups.isEmpty)
        XCTAssertEqual(deleted.status.memories.pendingSegments, 1)
    }
    func testLegacyBriefActivitiesUseNormalPresentationAndOriginalTitle() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("memories")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("2020-01-01T10-00-00Z-ABCD-10min-memory-summary.md")
        try "---\ntitle: Window\ndescription: Counts\n---\n### 本次活动\n- **核对预约名额**：你查看周末场次的剩余名额。".write(to: file, atomically: true, encoding: .utf8)
        var item = ActivityNarrative.Item(id: "brief", timestamp: Date(timeIntervalSince1970: 0), title: "期间的其他活动", summary: "你查看周末场次的剩余名额。", apps: ["example.browser"], sourceMemories: [file.lastPathComponent])
        item.sourceActivities = [file.lastPathComponent: [1]]
        item.sourceIncidental = item.sourceActivities
        try ActivityNarrative(items: [item]).save(root: root)
        let snapshot = await TraySnapshotLoader().load(root: root)
        let row = try XCTUnwrap(snapshot.groups.first?.items.first)
        XCTAssertEqual(row.title, "核对预约名额")
        XCTAssertEqual(row.summary, item.summary)
        XCTAssertNil(row.sourceIncidental)
        XCTAssertFalse(row.isIncidentalOnly)
    }

    func testOngoingAwayDoesNotInvalidateUnchangedHistory() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        var away = AwayPeriods(startedAt: Date().addingTimeInterval(-120))
        away.startedReason = .idle
        try away.save(root: root)
        let loader = TraySnapshotLoader()
        let first = await loader.load(root: root)
        let second = await loader.load(root: root)
        XCTAssertEqual(first.contentVersion, second.contentVersion,
                       "Advancing an open period must not rebuild and publish unchanged historical content")
        XCTAssertEqual(second.groups.first?.items.first?.title, "用户离开电脑")
        XCTAssertTrue(second.groups.first?.items.first?.isAway == true)
    }

    func testOpenAwayUsesTheSameUniqueTimeLayoutAsHistoricalItems() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 120)
        try AwayPeriods(startedAt: start).save(root: root)
        try ActivityNarrative(items: [.init(id: "same-time", timestamp: start, title: "Synthetic source",
            summary: "Synthetic activity", apps: [], sourceMemories: [])]).save(root: root)
        let snapshot = await TraySnapshotLoader().load(root: root)
        let cards = snapshot.groups.flatMap(\.items)
        XCTAssertEqual(Set(cards.map(\.timestamp)).count, cards.count)
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards[0].leafItems.count, 2)
    }

    func testRefreshRequestsCoalesceAndCanBeCancelled() {
        var state = TrayRefreshState()
        XCTAssertTrue(state.request())
        for _ in 0..<100 { XCTAssertFalse(state.request()) }
        XCTAssertTrue(state.finished())
        XCTAssertFalse(state.finished())
        XCTAssertTrue(state.request())
        state.cancel()
        XCTAssertTrue(state.request())
    }

    func testSharedMemoryActivitiesKeepSourcePeriodsAndFixedModeKeepsWholeMemory() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("memories")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("2020-01-01T10-00-00Z-ABCD-10min-memory-summary.md")
        let detail = String(repeating: "核对合成文档的独立条目。", count: 220) + "SYNTHETIC_FINAL_DETAIL"
        try "---\ntitle: Window\ndescription: Counts\n---\n## Memory summary\n### 本次活动\n- **审阅文档。**：\(detail)\n- **迁移示例项目**：保留提交历史。".write(to: file, atomically: true, encoding: .utf8)
        let entry = try XCTUnwrap(MemoryIndex.parse(fileURL: file))
        let items = NarrativeGenerator.parseItems("## [S1.A1] 审阅文档。\n核查文档。\n## [S1.A2] 迁移示例项目\n核查目录。", sources: [entry])
        try ActivityNarrative(items: items).save(root: root)
        let loader = TraySnapshotLoader()
        let continuous = await loader.load(root: root)
        let rows = continuous.groups.flatMap(\.items).flatMap(\.leafItems)
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.sharesSourcePeriod == true })
        let source = ActivityFragment.details(files: [file], activities: rows.first { $0.title == "审阅文档" }?.sourceActivities)
        XCTAssertTrue(source.first?.text.contains("SYNTHETIC_FINAL_DETAIL") == true)
        XCTAssertFalse(source.first?.text.contains("提交历史") == true)
        var settings = SummarySettings(); settings.timelineMode = .fixedTenMinutes; try settings.save(root: root)
        let fixed = await loader.load(root: root)
        XCTAssertEqual(fixed.groups.flatMap(\.items).flatMap(\.leafItems).count, 1)
        let full = ActivityFragment.details(files: [file], activities: fixed.groups.first?.items.first?.sourceActivities)
        XCTAssertTrue(full.first?.text.contains("SYNTHETIC_FINAL_DETAIL") == true)
        XCTAssertTrue(full.first?.text.contains("提交历史") == true)
    }

    func testSplitCardsUseActivityContentAndPreserveCompletedNarratives() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("memories")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "2020-01-01T10-30-00Z-1234-10min-memory-summary.md"
        let statistics = "本段约 3 分钟，记录 77 条事件，涉及 2 个应用。"
        let text = "---\ntitle: Synthetic terminal\ndescription: \(statistics)\ngeneration: model\n---\n## Memory summary\n### Relevant prior context\nOld task from before sleep.\n### Important non-obvious context about the user\nPrivate inference excluded.\n### 本次活动\n**核对合成文档**\n- 打开合成报告，核对任务 A 的运行结果，发现归档包不完整。\n## Recording summary\n### 时序证据\nRaw fixture excluded."
        try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        let start = SegmentClock.date(fromSegmentID: "2020-01-01T10-30-00Z")!
        var split = ActivityNarrative.Item(id: "split", timestamp: start, title: "Synthetic terminal",
            summary: statistics, apps: [], sourceMemories: [name])
        split.previousIDs = ["old-all-day"]
        var completed = ActivityNarrative.Item(id: "completed", timestamp: start,
            title: "已有的优质活动标题", summary: "已有的具体动作、对象和结果。", apps: [], sourceMemories: [name])
        completed.sourceRevisions = [name: try XCTUnwrap(MemoryIndex.parse(fileURL: dir.appendingPathComponent(name))).revision]
        try ActivityNarrative(items: [split, completed]).save(root: root)
        let original = try Data(contentsOf: ActivityNarrative.fileURL(root: root))
        let snapshot = await TraySnapshotLoader().load(root: root)
        let items = snapshot.groups.flatMap(\.items).flatMap(\.leafItems)
        let repaired = try XCTUnwrap(items.first { $0.id == "split" })
        XCTAssertEqual(repaired.title, "核对合成文档")
        XCTAssertTrue(repaired.summary.contains("核对任务 A 的运行结果"))
        XCTAssertTrue(repaired.summary.contains("归档包不完整"))
        for forbidden in [statistics, "Old task", "Private inference", "Raw fixture", "**"] {
            XCTAssertFalse(repaired.summary.contains(forbidden), forbidden)
        }
        XCTAssertEqual(items.first { $0.id == "completed" }?.summary, completed.summary)
        XCTAssertEqual(items.first { $0.id == "completed" }?.title, completed.title)
        XCTAssertEqual(try Data(contentsOf: ActivityNarrative.fileURL(root: root)), original)
    }

    func testOneTimelineSeparatesTaskReturnsAndSwitchesModesWithoutRewritingCache() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("memories")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var names: [String] = []
        let start = SegmentClock.date(fromSegmentID: "2020-01-01T10-00-00Z")!
        for i in 0..<3 {
            let id = SegmentClock.segmentID(for: start.addingTimeInterval(Double(i * 600)))
            let file = try segment(root, id: id, text: "")
            let metadata = EventStreamMetadata(id: id, startedAt: start.addingTimeInterval(Double(i * 600)),
                endedAt: start.addingTimeInterval(Double((i + 1) * 600 + 5)), eventCount: 1, suppressedEventCount: 0, eventsPath: file.path)
            try EventStreamJSON.makeEncoder().encode(metadata).write(to: file.deletingLastPathComponent().appendingPathComponent("metadata.json"))
            let name = id + "-1234-10min-memory-summary.md"
            names.append(name)
            try "---\ntitle: \(i == 1 ? "B" : "A")\ndescription: statistics\n---\n## Memory summary\n### 本次活动\n核对合成任务 \(i)，保留步骤及结果。".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try ActivityNarrative(items: [
            .init(id: "A", timestamp: start, title: "A", summary: "Whole task A", apps: [], sourceMemories: [names[0], names[2]]),
            .init(id: "B", timestamp: start.addingTimeInterval(600), title: "B", summary: "Independent B", apps: [], sourceMemories: [names[1]])
        ]).save(root: root)
        let loader = TraySnapshotLoader()
        let separated = await loader.load(root: root)
        let rows = separated.groups.flatMap(\.items).flatMap(\.leafItems).sorted { $0.timestamp < $1.timestamp }
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows[0].summary.contains("合成任务 0"))
        XCTAssertTrue(rows[2].summary.contains("合成任务 2"))
        XCTAssertEqual(rows[1].summary, "Independent B")
        let containers = separated.groups.flatMap(\.items).sorted { $0.timestamp < $1.timestamp }
        XCTAssertTrue(zip(containers, containers.dropFirst()).allSatisfy { $0.endTimestamp <= $1.timestamp })
        try ActivityNarrative(items: [.init(id: "merged", timestamp: start, title: "Continuous A",
            summary: "A specific continuous activity", apps: [], sourceMemories: names)]).save(root: root)
        let original = try Data(contentsOf: ActivityNarrative.fileURL(root: root))
        let continuous = await loader.load(root: root)
        XCTAssertEqual(continuous.groups.flatMap(\.items).flatMap(\.leafItems).count, 1)
        var settings = SummarySettings(); settings.timelineMode = .fixedTenMinutes
        try settings.save(root: root)
        let fixed = await loader.load(root: root)
        XCTAssertEqual(fixed.groups.flatMap(\.items).flatMap(\.leafItems).count, 3)
        XCTAssertEqual(try Data(contentsOf: ActivityNarrative.fileURL(root: root)), original)
        XCTAssertGreaterThan(fixed.contentVersion, continuous.contentVersion)
        settings.timelineMode = .continuous; try settings.save(root: root)
        let restored = await loader.load(root: root)
        XCTAssertEqual(restored.groups.flatMap(\.items).flatMap(\.leafItems).first?.summary, "A specific continuous activity")
    }

    func testResumedActivityIsSeparatedAroundAwayPeriodsWithoutRewritingHistory() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = ISO8601DateFormatter()
        func date(_ time: String) -> Date { clock.date(from: "2020-01-01T\(time)Z")! }
        let dir = root.appendingPathComponent("memories")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var names: [String] = []
        for (bucket, first, end, title) in [
            ("01:10:00", "01:10:05", "01:20:00", "Night"),
            ("01:50:00", "01:50:02", "01:59:17", "Night"),
            ("10:30:00", "10:36:04", "10:40:00", "Morning"),
            ("11:00:00", "11:00:01", "11:03:28", "Morning"),
            ("12:10:00", "12:18:57", "12:20:00", "Library"),
            ("12:20:00", "12:20:01", "12:30:00", "Library")
        ] {
            let id = SegmentClock.segmentID(for: date(bucket))
            let file = try segment(root, id: id, text: "")
            let meta = EventStreamMetadata(id: id, startedAt: date(bucket), endedAt: date(end),
                eventCount: 1, suppressedEventCount: 0, eventsPath: file.path, firstEventAt: date(first))
            try EventStreamJSON.makeEncoder().encode(meta).write(to: file.deletingLastPathComponent().appendingPathComponent("metadata.json"))
            let name = "\(id)-1234-10min-memory-summary.md"
            names.append(name)
            try "---\ntitle: \(title)\ndescription: \(title) evidence\napplications: [synthetic.editor]\n---".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        var away = AwayPeriods()
        let morningReturn = date("10:36:04").addingTimeInterval(0.395)
        let libraryReturn = date("12:18:57").addingTimeInterval(0.196)
        away.periods = [.init(start: date("01:59:17"), end: morningReturn),
                        .init(start: date("11:03:28"), end: libraryReturn)]
        try away.save(root: root)
        try ActivityNarrative(items: [.init(id: "merged", timestamp: date("01:10:00"), title: "All day",
            summary: "Night plus morning plus library", apps: ["synthetic.editor"], sourceMemories: names)]).save(root: root)
        let original = try Data(contentsOf: ActivityNarrative.fileURL(root: root))
        let loader = TraySnapshotLoader()
        let snapshot = await loader.load(root: root, timeZone: TimeZone(secondsFromGMT: 0)!)
        let items = snapshot.groups.flatMap(\.items).flatMap(\.leafItems)
        let expected = [libraryReturn, date("11:03:28"), date("11:00:01"), morningReturn, date("01:59:17"), date("01:50:02"), date("01:10:05")]
        XCTAssertEqual(items.count, expected.count)
        for (item, time) in zip(items, expected) {
            XCTAssertEqual(item.timestamp.timeIntervalSince1970, time.timeIntervalSince1970, accuracy: 0.001)
        }
        let active = items.filter { !$0.isAway }
        XCTAssertEqual(active.map(\.coveredCount), [2, 1, 1, 1, 1])
        XCTAssertEqual(active.map(\.endTimestamp), [date("12:30:00"), date("11:03:28"), date("10:40:00"), date("01:59:17"), date("01:20:00")])
        XCTAssertEqual(active.map(\.summary), ["Library evidence", "Morning evidence", "Morning evidence", "Night evidence", "Night evidence"])
        XCTAssertTrue(items.filter(\.isAway).allSatisfy { $0.summary == "锁屏或休眠" })
        XCTAssertEqual(try Data(contentsOf: ActivityNarrative.fileURL(root: root)), original)
        let warm = await loader.load(root: root, timeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertEqual(warm.memoriesParsed, 0)
        let metadataURL = root.appendingPathComponent("segments/2020-01-01T12-20-00Z/metadata.json")
        var metadata = try EventStreamJSON.makeDecoder().decode(EventStreamMetadata.self, from: Data(contentsOf: metadataURL))
        metadata.endedAt = date("12:31:00")
        try EventStreamJSON.makeEncoder().encode(metadata).write(to: metadataURL, options: .atomic)
        let changed = await loader.load(root: root, timeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertEqual(changed.memoriesParsed, 1)
        XCTAssertEqual(changed.groups.first?.items.first?.endTimestamp, date("12:31:00"))
        var parent = active[0]
        parent.id = "merged"
        parent.memoryFiles = names.map { dir.appendingPathComponent($0) }
        try TimelineDeletions.delete(parent, root: root)
        let hidden = await TraySnapshotLoader().load(root: root)
        XCTAssertTrue(hidden.groups.flatMap(\.items).flatMap(\.leafItems).allSatisfy(\.isAway), "Splitting must preserve deletion of the original card")
        try TimelineDeletions.restore(id: parent.deletionID, root: root)
        try TimelineDeletions.delete(active[0], root: root)
        let after = await TraySnapshotLoader().load(root: root)
        XCTAssertEqual(after.groups.flatMap(\.items).flatMap(\.leafItems).filter { !$0.isAway }.count, 4)
        try TimelineDeletions.restore(id: active[0].deletionID, root: root)
        let restored = await TraySnapshotLoader().load(root: root)
        XCTAssertEqual(restored.groups.flatMap(\.items).flatMap(\.leafItems).filter { !$0.isAway }.count, 5)
        try ActivityNarrative().save(root: root)
        let lostCache = await TraySnapshotLoader().load(root: root)
        XCTAssertEqual(lostCache.groups.flatMap(\.items).flatMap(\.leafItems).filter { !$0.isAway }.count, 5, "Restored snapshots must obey the same away boundaries")
    }

    func testLargeHistoryBenchmark() async throws {
        guard ProcessInfo.processInfo.environment["COMPUTER_HISTORY_TRAY_BENCHMARK"] == "1" else {
            throw XCTSkip("设置 COMPUTER_HISTORY_TRAY_BENCHMARK=1 运行约 1.5 GiB 合成基准")
        }
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        // 120 段，每段 12.5 MiB；单行仍是本项目能解析的合成事件。
        let event = EventStreamRecord(id: 1, timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            kind: .windowChanged, app: .init(bundleIdentifier: "com.example.fixture"),
            window: .init(title: String(repeating: "x", count: 4096)), mouse: nil, keyboard: nil, selection: nil, ax: nil)
        var line = try EventStreamJSON.makeEncoder().encode(event)
        line.append(10)
        let repetitions = 13_107_200 / line.count
        var block = Data()
        for _ in 0..<repetitions { block.append(line) }
        let memoryDir = root.appendingPathComponent("memories")
        try FileManager.default.createDirectory(at: memoryDir, withIntermediateDirectories: true)
        var names: [String] = []
        for i in 0..<125 {
            let id = SegmentClock.segmentID(for: Date(timeIntervalSince1970: 1_800_000_000 + Double(i) * 600))
            if i < 120 {
                let file = try segment(root, id: id, text: "")
                try block.write(to: file)
                if i < 119 {
                    try Data("{\"eventCount\":\(repetitions)}".utf8).write(to: file.deletingLastPathComponent().appendingPathComponent("metadata.json"))
                }
            }
            let name = "\(id)-1234-10min-memory-summary.md"
            names.append(name)
            try "---\ntitle: Synthetic \(i)\ndescription: fixture\napplications: [com.example.fixture]\n---\n### detail\n\(String(repeating: "fixture ", count: 400))".write(to: memoryDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try ActivityNarrative(items: (0..<72).map { i in
            .init(id: "n\(i)", timestamp: Date(timeIntervalSince1970: 1_800_000_000 + Double(i) * 600),
                  title: "fixture", summary: "synthetic narrative", apps: [], sourceMemories: [names[i]])
        }).save(root: root)
        let before = Date()
        let baseline = CollectorStatus.read(root: root)
        let baselineTime = Date().timeIntervalSince(before)
        let loader = TraySnapshotLoader()
        let coldStart = Date()
        let cold = await loader.load(root: root)
        let coldTime = Date().timeIntervalSince(coldStart)
        let warmStart = Date()
        let warm = await loader.load(root: root)
        let warmTime = Date().timeIntervalSince(warmStart)
        XCTAssertEqual(cold.status.data.eventCount, baseline.data.eventCount)
        XCTAssertEqual(warm.status.data.eventCount, baseline.data.eventCount)
        XCTAssertEqual(warm.eventBytesRead, 0)
        XCTAssertEqual(warm.memoriesParsed, 0)
        print("TRAY_BENCHMARK bytes=\(baseline.data.bytes) baseline_s=\(baselineTime) cold_s=\(coldTime) warm_s=\(warmTime) cold_bytes=\(cold.eventBytesRead) warm_bytes=\(warm.eventBytesRead) cold_parsed=\(cold.memoriesParsed) warm_parsed=\(warm.memoriesParsed)")
    }
    func testManualEditsSurviveRegenerationAndApplyOnlyInFixedMode() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("memories")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "2020-01-01T10-30-00Z-1234-10min-memory-summary.md"
        let memory = dir.appendingPathComponent(name)
        try "---\ntitle: Automatic title\ndescription: Automatic activity\n---\n### 本次活动\n检查合成报告，发现缺失章节。".write(to: memory, atomically: true, encoding: .utf8)
        var settings = SummarySettings(); settings.timelineMode = .fixedTenMinutes
        try settings.save(root: root)
        let loader = TraySnapshotLoader()
        let automatic = await loader.load(root: root)
        var edits = try TimelineEdits.load(root: root)
        try edits.set(.init(title: "手动标题", summary: "补充合成报告的缺失章节，并保存结果。"), for: name, root: root)
        let edited = await loader.load(root: root)
        XCTAssertEqual(edited.groups[0].items[0].title, "手动标题")
        XCTAssertEqual(edited.groups[0].items[0].manualEdit, true)
        XCTAssertGreaterThan(edited.contentVersion, automatic.contentVersion)
        try "---\ntitle: Regenerated title\ndescription: New automatic content\n---".write(to: memory, atomically: true, encoding: .utf8)
        let regenerated = await loader.load(root: root)
        XCTAssertEqual(regenerated.groups[0].items[0].summary, "补充合成报告的缺失章节，并保存结果。")
        settings.timelineMode = .continuous; try settings.save(root: root)
        let merged = await loader.load(root: root)
        XCTAssertEqual(merged.groups[0].items[0].title, "Regenerated title")
        XCTAssertNil(merged.groups[0].items[0].manualEdit)
        settings.timelineMode = .fixedTenMinutes; try settings.save(root: root)
        let fixed = await loader.load(root: root)
        XCTAssertEqual(fixed.groups[0].items[0].title, "手动标题")
        try edits.set(nil, for: name, root: root)
        let restored = await loader.load(root: root)
        XCTAssertEqual(restored.groups[0].items[0].title, "Regenerated title")
        XCTAssertNil(restored.groups[0].items[0].manualEdit)
        try Data("malformed".utf8).write(to: root.appendingPathComponent("timeline-edits.json"))
        XCTAssertThrowsError(try TimelineEdits.load(root: root))
    }

    func testCancelledCommandIsReaped() throws {
        let began = Date()
        XCTAssertThrowsError(try LocalCommand.run("/bin/sleep", ["30"], timeout: 10,
            cancelled: { Date().timeIntervalSince(began) > 0.15 })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(began), 3)
    }

}
