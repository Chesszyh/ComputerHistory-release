import Foundation
import XCTest
@testable import ComputerHistoryCore

final class InteractionEvidenceTests: XCTestCase {
    func testRepeatedInterfaceChangesAndUncertainValuesDoNotEstablishUserInteraction() {
        let start = Date(timeIntervalSince1970: 1_600_000_000)
        let app = EventStreamApp(name: "Synthetic status", bundleIdentifier: "example.status")
        var events = (0..<120).map {
            EventStreamRecord(id: $0, timestamp: start.addingTimeInterval(Double($0 * 5)), kind: .windowChanged,
                              app: app, window: .init(title: "Countdown \(120 - $0)"))
        }
        events.append(.init(id: 120, timestamp: start.addingTimeInterval(599), kind: .keyboardTextInput,
                            app: app, keyboard: .init(text: "background response", textEvidence: .uncertainValueChange)))
        let evidence = ActivityEvidence.interactionSummary(events: events)
        XCTAssertTrue(evidence.contains("未记录到上述明确交互"))
        let prompt = MemoryGenerator.userPrompt(digest: .make(events: events, segmentID: "synthetic"), events: events, priorMemory: nil)
        XCTAssertTrue(prompt.contains(evidence))
        XCTAssertTrue(prompt.contains("界面记录"))
        XCTAssertFalse(prompt.contains("- 活跃"))
    }

    func testLongPassiveObservationsBecomeNeutralActivityWithoutModelClaims() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let segmentID = "2020-01-01T10-00-00Z"
        let folder = root.appendingPathComponent("segments/" + segmentID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let start = SegmentClock.date(fromSegmentID: segmentID)!
        let events = (0..<70).map { n in
            EventStreamRecord(id: n, timestamp: start.addingTimeInterval(Double(n * 8)), kind: .windowChanged,
                              app: .init(name: "Status", bundleIdentifier: "example.status"),
                              window: .init(title: "Countdown"), ax: .init(mode: .fullTree, text: "0 staticText Value: Remaining \(70-n)"))
        }
        XCTAssertTrue(ActivityEvidence.hasNoClearActivity(events: events))
        var active = events
        active.append(.init(id: 71, timestamp: start.addingTimeInterval(560), kind: .mouseClick))
        XCTAssertFalse(ActivityEvidence.hasNoClearActivity(events: active))
        XCTAssertTrue(ActivityEvidence.hasNoClearActivity(events: Array(events.prefix(3))))
        let bytes = try events.map { try EventStreamJSON.makeEncoder().encode($0) + Data([10]) }.reduce(Data(), +)
        try bytes.write(to: folder.appendingPathComponent("events.jsonl"))
        let metadata = EventStreamMetadata(id: segmentID, startedAt: start, endedAt: start.addingTimeInterval(560),
            eventCount: events.count, suppressedEventCount: 0, eventsPath: folder.appendingPathComponent("events.jsonl").path,
            inputListeningDegraded: false)
        try EventStreamJSON.makeEncoder().encode(metadata).write(to: folder.appendingPathComponent("metadata.json"))
        let client = DeepSeekClient(apiKey: "synthetic", baseURL: URL(string: "http://127.0.0.1:1")!, timeout: 0.1)
        let outcome = try MemoryGenerator(rootDirectory: root, memoriesDirectory: root.appendingPathComponent("memories"), client: client)
            .generate(segmentID: segmentID)
        XCTAssertFalse(outcome.usedModel)
        let entry = try XCTUnwrap(MemoryIndex.parse(fileURL: outcome.memoryURL))
        XCTAssertTrue(entry.noClearActivity)
        XCTAssertEqual(entry.activityTitle, "无明显活动")
        XCTAssertEqual(entry.activitySummary, ActivityEvidence.noActivitySummary)
        let result = try NarrativeGenerator(rootDirectory: root, client: client).generate(day: entry.dayLabel())
        XCTAssertFalse(result.usedModel)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("requests").path), "Passive segments must not send either summary request")
        let snapshot = await TraySnapshotLoader().load(root: root)
        let item = try XCTUnwrap(snapshot.groups.first?.items.first)
        XCTAssertEqual(item.title, "无明显活动")
        XCTAssertFalse(item.summary.contains("Countdown"))
        let stored = try String(contentsOf: outcome.memoryURL, encoding: .utf8)
        XCTAssertTrue(stored.contains("Remaining"), "Original observation details must remain available")
        let activeFile = root.appendingPathComponent("memories/2020-01-01T09-50-00Z-ABCD-10min-memory-summary.md")
        try "---\ntitle: 阅读文档\ndescription: 核对方法。\n---\n### 本次活动\n- **阅读文档**：核对方法。".write(to: activeFile, atomically: true, encoding: .utf8)
        let activeEntry = try XCTUnwrap(MemoryIndex.parse(fileURL: activeFile))
        let stale = ActivityNarrative.Item(id: "old-merged", timestamp: activeEntry.startedAt, title: "旧的混合标题", summary: "STALE_ACTIVE_CLAIM",
                                          apps: [], sourceMemories: [activeEntry.id, entry.id])
        try ActivityNarrative(items: [stale]).save(root: root)
        let split = await TraySnapshotLoader().load(root: root)
        let leaves = split.groups.flatMap(\.items).flatMap(\.leafItems)
        XCTAssertEqual(Set(leaves.map(\.title)), ["阅读文档", "无明显活动"])
        XCTAssertEqual(leaves.first { $0.title == "无明显活动" }?.summary, ActivityEvidence.noActivitySummary)
        let bodyOnly = stored.replacingOccurrences(of: "\nactivity_status: no_clear_activity\n", with: "\n")
            + "\nactivity_status: no_clear_activity\n"
        try bodyOnly.write(to: outcome.memoryURL, atomically: true, encoding: .utf8)
        XCTAssertFalse(try XCTUnwrap(MemoryIndex.parse(fileURL: outcome.memoryURL)).noClearActivity,
                       "Observation text must not set presentation metadata")
    }

    func testExplicitEditingClicksAndShortcutsAreDistinguishedFromPassiveObservation() {
        let start = Date(timeIntervalSince1970: 1_600_000_000)
        let events: [EventStreamRecord] = [
            .init(id: 1, timestamp: start, kind: .mouseClick),
            .init(id: 2, timestamp: start, kind: .keyboardShortcut),
            .init(id: 3, timestamp: start, kind: .keyboardTextInput, keyboard: .init(text: "synthetic edit", textEvidence: .editedValue))
        ]
        let evidence = ActivityEvidence.interactionSummary(events: events)
        XCTAssertFalse(evidence.contains("未记录到上述明确交互"))
        XCTAssertTrue(evidence.contains("鼠标 1 次"))
        XCTAssertTrue(evidence.contains("确证编辑片段 1 段"))
    }

    func testScrollEventsCountAsExplicitActivity() {
        let start = Date(timeIntervalSince1970: 1_600_000_000)
        let app = EventStreamApp(name: "Browser", bundleIdentifier: "com.apple.Safari")
        let events = (0..<70).map { n in
            EventStreamRecord(id: n, timestamp: start.addingTimeInterval(Double(n * 8)), kind: .windowChanged,
                              app: app, window: .init(title: "Safari"),
                              ax: .init(mode: .fullTree, text: "0 staticText Value: Page content"))
        }
        XCTAssertTrue(ActivityEvidence.hasNoClearActivity(events: events))

        var withScroll = events
        withScroll.append(.init(id: 71, timestamp: start.addingTimeInterval(560), kind: .mouseScroll,
                                app: app, mouse: .init(button: "scroll", clickCount: nil, modifiers: [], target: nil)))
        XCTAssertFalse(ActivityEvidence.hasNoClearActivity(events: withScroll))

        let evidence = ActivityEvidence.interactionSummary(events: withScroll)
        XCTAssertFalse(evidence.contains("未记录到上述明确交互"))
        XCTAssertTrue(evidence.contains("浏览滚动证据 1 条"))
    }

    func testInputListeningDegradedSegmentProducesDegradedMemoryWithoutModel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let segmentID = "2020-01-01T10-00-00Z"
        let folder = root.appendingPathComponent("segments/" + segmentID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let start = SegmentClock.date(fromSegmentID: segmentID)!
        let events = (0..<70).map { n in
            EventStreamRecord(id: n, timestamp: start.addingTimeInterval(Double(n * 8)), kind: .windowChanged,
                              app: .init(name: "Status", bundleIdentifier: "example.status"),
                              window: .init(title: "Countdown"), ax: .init(mode: .fullTree, text: "0 staticText Value: Remaining \(70-n)"))
        }
        let bytes = try events.map { try EventStreamJSON.makeEncoder().encode($0) + Data([10]) }.reduce(Data(), +)
        try bytes.write(to: folder.appendingPathComponent("events.jsonl"))

        // 写入带有 inputListeningDegraded = true 的 metadata
        let metadata = EventStreamMetadata(
            id: segmentID,
            startedAt: start,
            endedAt: start.addingTimeInterval(560),
            endReason: nil,
            eventCount: events.count,
            suppressedEventCount: 0,
            eventsPath: folder.appendingPathComponent("events.jsonl").path,
            firstEventAt: start,
            inputListeningDegraded: true
        )
        let metaData = try EventStreamJSON.makeEncoder().encode(metadata)
        try metaData.write(to: folder.appendingPathComponent("metadata.json"))

        let client = DeepSeekClient(apiKey: "synthetic", baseURL: URL(string: "http://127.0.0.1:1")!, timeout: 0.1)
        let outcome = try MemoryGenerator(rootDirectory: root, memoriesDirectory: root.appendingPathComponent("memories"), client: client)
            .generate(segmentID: segmentID)

        XCTAssertFalse(outcome.usedModel)
        let entry = try XCTUnwrap(MemoryIndex.parse(fileURL: outcome.memoryURL))
        XCTAssertFalse(entry.noClearActivity, "Degraded input must not be treated as noClearActivity")
        XCTAssertTrue(entry.inputListeningDegraded)
        XCTAssertEqual(entry.activityTitle, ActivityEvidence.inputDegradedTitle)
        XCTAssertEqual(entry.activitySummary, ActivityEvidence.inputDegradedSummary)

        let snapshot = await TraySnapshotLoader().load(root: root)
        let item = try XCTUnwrap(snapshot.groups.first?.items.first)
        XCTAssertEqual(item.title, ActivityEvidence.inputDegradedTitle)
        XCTAssertEqual(item.summary, ActivityEvidence.inputDegradedSummary)
    }
}
