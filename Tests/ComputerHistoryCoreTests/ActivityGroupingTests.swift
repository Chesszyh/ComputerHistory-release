import XCTest
@testable import ComputerHistoryCore

final class ActivityGroupingTests: XCTestCase {
    func fixture() throws -> (URL, MemoryIndex, [MemoryIndex.Entry]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("memories")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (minute, text) in [("00", "- **修复解析**：检查字符边界。\n- **交流**：讨论晚餐。"), ("10", "- **继续修复解析**：验证组合字符。") ] {
            try ("---\ntitle: 合成\ndescription: 合成\n---\n### 本次活动\n" + text)
                .write(to: folder.appendingPathComponent("2020-01-01T00-\(minute)-00Z-ABCD-10min-memory-summary.md"), atomically: true, encoding: .utf8)
        }
        let index = MemoryIndex.load(from: folder)
        return (root, index, index.entries.sorted { $0.startedAt < $1.startedAt })
    }
    func testReturnLinksTaskWithoutBridgingConversation() throws {
        let (root, _, sources) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let plan = ActivityGrouping(groups: [
            .init(references: ["S1.A1"]), .init(references: ["S1.A2"]), .init(references: ["S2.A1"], task: "G1")])
        let items = try plan.items(sources: sources, prior: [], tasks: [])
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].taskID, items[2].taskID)
        XCTAssertNotEqual(items[0].taskID, items[1].taskID)
        XCTAssertEqual(items[0].sourceActivities, [sources[0].id: [1]])
        XCTAssertEqual(items[2].sourceMemories, [sources[1].id])
        for groups: [ActivityGrouping.Group] in [
            [.init(references: ["S1.A1", "S2.A1"]), .init(references: ["S1.A2"])],
            [.init(references: ["S1.A1"]), .init(references: ["S1.A2"])],
            [.init(references: ["S1.A1", "S1.A1", "S1.A2", "S2.A1"])],
            [.init(references: ["S1.A1", "S1.A2", "S2.A1"], task: "T-9223372036854775808")],
            [.init(references: ["S1.A1", "S1.A2", "S2.A1"], task: "G1")]
        ] {
            XCTAssertThrowsError(try ActivityGrouping(groups: groups).items(sources: sources, prior: [], tasks: []))
        }
    }
    func testAdjacentStepsCombineAndContinuationKeepsTaskIdentity() throws {
        let (root, _, sources) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var prior = ActivityNarrative.Item(id: "prior", timestamp: sources[0].startedAt.addingTimeInterval(-600), title: "稳定目标", summary: "旧结果", apps: [], sourceMemories: ["prior.md"])
        prior.taskID = "stable-task"
        let plan = ActivityGrouping(groups: [.init(references: ["S1.A1", "S1.A2", "S2.A1"], continuesPrevious: true, task: "T1")])
        let item = try XCTUnwrap(plan.items(sources: sources, prior: [prior], tasks: [prior]).first)
        XCTAssertEqual(item.taskID, "stable-task")
        XCTAssertEqual(item.title, "稳定目标")
        XCTAssertTrue(item.sourceMemories.contains("prior.md"))
    }
    func testWritingReturnKeepsTaskNameAndDistinctEpisodeTitles() throws {
        let (root, _, sources) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let plan = ActivityGrouping(groups: [
            .init(references: ["S1.A1"]), .init(references: ["S1.A2"]), .init(references: ["S2.A1"], task: "G1")])
        var work = ActivityGroupingWork(input: "", writingPrompt: "", model: "", plan: plan,
            items: try plan.items(sources: sources, prior: [], tasks: []))
        work.apply(.init(title: "修复字符边界", summary: "检查解析"), at: 0, continuationTitle: nil)
        work.apply(.init(title: "讨论晚餐", summary: "聊天"), at: 1, continuationTitle: nil)
        work.apply(.init(title: "验证组合字符", summary: "复查结果"), at: 2, continuationTitle: nil)
        XCTAssertEqual(work.items[0].taskTitle, "修复字符边界")
        XCTAssertEqual(work.items[2].taskTitle, work.items[0].taskTitle)
        XCTAssertEqual(work.items[2].title, "验证组合字符")
        XCTAssertNotEqual(work.items[1].taskTitle, work.items[0].taskTitle)
    }
    func testCorrectionsSurviveRegenerationAndRejectChangedSources() throws {
        let (root, index, sources) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let plan = ActivityGrouping(groups: [.init(references: ["S1.A1", "S1.A2", "S2.A1"])])
        let items = try plan.items(sources: sources, prior: [], tasks: [])
        let refs = TimelineCorrections.references(items[0], index: index)
        var correction = TimelineCorrections()
        correction.entries = [.init(action: .split, groups: [refs])]
        let split = correction.applying(to: .init(items: items), index: index, away: .init())
        XCTAssertEqual(split.items.count, 3)
        XCTAssertEqual(Set(split.items.compactMap(\.taskID)).count, 3)
        XCTAssertTrue(split.items.contains { $0.summary.contains("晚餐") })
        correction.entries.append(.init(action: .sameTask, groups: [[refs[0]], [refs[2]]]))
        let linked = correction.applying(to: .init(items: items), index: index, away: .init())
        XCTAssertEqual(linked.items[0].taskID, linked.items[2].taskID)
        XCTAssertNotEqual(linked.items[0].taskID, linked.items[1].taskID)
        var transitive = correction
        transitive.entries.append(.init(action: .sameTask, groups: [[refs[1]], [refs[2]]]))
        let joined = transitive.applying(to: .init(items: items), index: index, away: .init())
        XCTAssertEqual(joined.items.count, 3)
        XCTAssertEqual(Set(joined.items.compactMap(\.taskID)).count, 1, "Task association must be transitive")
        try correction.save(root: root)
        XCTAssertEqual(try TimelineCorrections.load(root: root), correction)
        var changed = index
        changed.entries[0].revision += "changed"
        XCTAssertGreaterThan(correction.invalidCount(index: changed), 0)
        XCTAssertEqual(correction.applying(to: .init(items: items), index: changed, away: .init()).items.count, 1)
    }
    func testPreviewFreezesInputsWithoutCopyingCredentialsOrChangingSources() throws {
        let (root, _, sources) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let original = try Data(contentsOf: sources[0].fileURL)
        let target = root.appendingPathComponent("previews/day")
        let preview = try NarrativePreview.prepare(source: root, destination: target, day: sources[0].dayLabel())
        XCTAssertEqual(try Data(contentsOf: preview.appendingPathComponent("memories/" + sources[0].id)), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: preview.appendingPathComponent("model.json").path))
        XCTAssertEqual(try NarrativePreview.prepare(source: root, destination: target, day: sources[0].dayLabel()), preview)
        XCTAssertThrowsError(try NarrativePreview.prepare(source: root, destination: root, day: sources[0].dayLabel()))
        XCTAssertEqual(try Data(contentsOf: sources[0].fileURL), original)
    }

    func testExplicitSessionEndBlocksContinuationButNotTaskAssociation() throws {
        let (root, _, sources) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var before = sources[0]
        before.endReason = "stopped"
        XCTAssertTrue(NarrativeGenerator.hasCollectionBoundary(before, sources[1]))
        before.endReason = nil; before.endedAt = sources[1].startedAt.addingTimeInterval(-61)
        XCTAssertTrue(NarrativeGenerator.hasCollectionBoundary(before, sources[1]))
        before.endedAt = sources[1].startedAt.addingTimeInterval(-1)
        XCTAssertFalse(NarrativeGenerator.hasCollectionBoundary(before, sources[1]))
    }

    func testNarrativeEditsAreLocalAndRemainAttachedToSource() throws {
        let (root, index, sources) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = sources[0].fileURL
        let before = try Data(contentsOf: file)
        var item = TrayTimelineItem(id: "first-generated-id", timestamp: sources[0].startedAt, title: "自动标题", summary: "自动内容", apps: [], isNarrative: true, memoryFiles: [file], coveredCount: 1, eventCount: nil, endTimestamp: sources[0].startedAt.addingTimeInterval(600), sourceActivities: [sources[0].id: [1]])
        let key = try XCTUnwrap(TimelineEdits.key(for: item, mode: .continuous))
        var edits = TimelineEdits()
        try edits.set(.init(title: "手动标题", summary: "手动内容", revisions: [sources[0].id: sources[0].revision]), for: key, root: root)
        item.id = "new-generated-id"
        let changed = edits.applying(to: item, mode: .continuous, index: index)
        XCTAssertEqual(changed.title, "手动标题")
        XCTAssertEqual(try Data(contentsOf: file), before)
        var revised = index
        revised.entries = index.entries.map { entry in var e = entry; e.revision += "change"; return e }
        XCTAssertEqual(edits.applying(to: item, mode: .continuous, index: revised).title, "自动标题")
        item.isNarrative = false
        XCTAssertNil(TimelineEdits.key(for: item, mode: .continuous))
    }
}
