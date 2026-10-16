import Foundation
import XCTest
@testable import ComputerHistoryCore

final class TextQualityTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testSeparatePositionsRemainSeparateAndUndoRemovesPendingEdit() {
        let tracker = TextInputTracker()
        _ = tracker.observe(.init(value: "abc DEF ghi"), at: t0)
        _ = tracker.observe(.init(value: "abc DEF ghi!"), at: t0.addingTimeInterval(0.1))
        _ = tracker.observe(.init(value: "Xabc DEF ghi!"), at: t0.addingTimeInterval(0.2))
        let fragments = tracker.flush()
        XCTAssertEqual(fragments.map(\.text), ["!", "X"])
        XCTAssertFalse(fragments.contains { $0.text.contains("DEF") })
        let undo = TextInputTracker()
        _ = undo.observe(.init(value: "original"), at: t0)
        _ = undo.observe(.init(value: "replacement"), at: t0.addingTimeInterval(0.1))
        _ = undo.observe(.init(value: "original"), at: t0.addingTimeInterval(0.2))
        XCTAssertTrue(undo.flush().isEmpty)
    }

    func testUndoRestoresOnlyChangedRegionWithoutQuotingExistingWords() {
        let tracker = TextInputTracker()
        for (i, value) in ["one two", "ONE two", "ONE TWO", "ONE two"].enumerated() {
            _ = tracker.observe(.init(value: value), at: t0.addingTimeInterval(Double(i) * 0.1))
        }
        XCTAssertEqual(tracker.flush().map(\.text), ["ONE"])
    }

    func testUndoDeletionDoesNotTurnExistingWordIntoNewInput() {
        let tracker = TextInputTracker()
        for (i, value) in ["one two", "ONE two", "ONE ", "ONE two"].enumerated() {
            _ = tracker.observe(.init(value: value), at: t0.addingTimeInterval(Double(i) * 0.1))
        }
        XCTAssertEqual(tracker.flush().map(\.text), ["ONE"])
    }

    func testCorrectionAfterIdleRetainsPersistedSourceWithoutRewritingEvents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = CollectionSession(configuration: .init(rootDirectory: root))
        try session.start(now: t0)
        let id = try XCTUnwrap(session.currentSegmentID)
        let app = EventStreamApp(processIdentifier: 42, bundleIdentifier: "com.example.editor")
        func sample(_ text: String, _ tick: Double) {
            session.sampleTextInput(app: app, window: nil, readFocused: {
                (.init(value: text, focusIdentity: 1, hasInputActivity: true), nil)
            }, now: t0.addingTimeInterval(tick))
        }
        sample("", 0.1)
        sample("ni", 0.2)
        sample("ni", 4)
        sample("你", 5)
        try session.stop(now: t0.addingTimeInterval(6))
        let events = try MemoryGenerator.readEvents(at: root.appendingPathComponent("segments/\(id)/events.jsonl"))
        let edits = events.filter { $0.kind == .keyboardTextInput }
        XCTAssertEqual(edits.compactMap { $0.keyboard?.text }, ["ni", "你"])
        XCTAssertEqual(edits.last?.keyboard?.textReplaces, ["\(id)#\(edits[0].id)"])
        let first = SegmentDigest.make(events: [edits[0]], segmentID: id)
        let second = SegmentDigest.make(events: [edits[1]], segmentID: id)
        let merged = SegmentDigest.merging([first, second], bucketID: "bucket")
        XCTAssertEqual(merged.activities.first?.textExcerpts.first?.evidence, .uncertainValueChange)
        XCTAssertTrue(merged.activities.first?.textExcerpts.first?.wasReplaced == true)
        let material = MemoryWriter.textEvidenceSection(for: merged.activities[0])
        XCTAssertTrue(material.contains("后续已覆盖"))
        XCTAssertTrue(material.contains("覆盖来源"))
    }

    func testSplitRegionsKeepDistinctPersistedReferences() {
        let tracker = TextInputTracker()
        for (i, value) in ["abc", "XYZ", "XbZ"].enumerated() {
            _ = tracker.observe(.init(value: value), at: t0.addingTimeInterval(Double(i) * 0.1))
        }
        let fragments = tracker.flush()
        XCTAssertEqual(fragments.map(\.text), ["X", "Z"])
        for (i, fragment) in fragments.enumerated() { tracker.acknowledge(fragment, reference: "s#\(i)") }
        _ = tracker.observe(.init(value: "XbQ"), at: t0.addingTimeInterval(1))
        XCTAssertEqual(tracker.flush().first?.replaces, ["s#1"])
    }

    func testMarkedTextDoesNotCommitOnPauseAndConfirmedCommitReplacesIt() {
        let tracker = TextInputTracker()
        _ = tracker.observe(.init(value: ""), at: t0)
        _ = tracker.observe(.init(value: "ni", hasMarkedText: true, hasInputActivity: true), at: t0.addingTimeInterval(0.1))
        XCTAssertTrue(tracker.observe(.init(value: "ni", hasMarkedText: true), at: t0.addingTimeInterval(10)).isEmpty)
        _ = tracker.observe(.init(value: "你", hasMarkedText: false, hasInputActivity: true), at: t0.addingTimeInterval(11))
        let fragments = tracker.flush()
        XCTAssertEqual(fragments.map(\.text), ["你"])
        XCTAssertEqual(fragments.first?.evidence, .editedValue)
    }

    func testCollectionEncodingDigestAndBothSummaryPathsPreserveEvidence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = CollectionSession(configuration: .init(rootDirectory: root))
        try session.start(now: t0)
        let id = try XCTUnwrap(session.currentSegmentID)
        let app = EventStreamApp(name: "Fixture", processIdentifier: 42, bundleIdentifier: "com.example.editor")
        let window = EventStreamWindow(title: "Synthetic", windowID: 1)
        let placeholder = "询问ChatGPT"
        func sample(_ value: String, at second: Double, editable: Bool = true, activity: Bool? = nil) {
            session.sampleTextInput(app: app, window: window, readFocused: {
                (.init(value: value, isEditableBuffer: editable, focusIdentity: 7,
                       placeholder: placeholder, hasInputActivity: activity),
                 .init(role: "AXTextArea", value: value, placeholder: placeholder))
            }, now: t0.addingTimeInterval(second))
        }
        sample("", at: 0.1)
        sample(placeholder, at: 0.2)
        sample("", at: 0.3)
        sample("ni", at: 0.4)
        session.noteInputActivity(processIdentifier: 42, at: t0.addingTimeInterval(0.5))
        sample("你", at: 0.6)
        sample("你", at: 4)
        sample("你程序更新", at: 8)
        sample("你程序更新", at: 12)
        // 输入同一提示字有交互证据时仍保留。
        sample("", at: 13)
        session.noteInputActivity(processIdentifier: 42, at: t0.addingTimeInterval(14))
        sample(placeholder, at: 14.1)
        try session.stop(now: t0.addingTimeInterval(15))
        let events = try MemoryGenerator.readEvents(at: root.appendingPathComponent("segments/\(id)/events.jsonl"))
        let edits = events.filter { $0.kind == .keyboardTextInput }
        XCTAssertEqual(edits.compactMap { $0.keyboard?.text }, ["你", "程序更新", placeholder])
        XCTAssertEqual(edits.compactMap { $0.keyboard?.textEvidence }, [.editedValue, .uncertainValueChange, .editedValue])
        let digest = SegmentDigest.make(events: events, segmentID: id)
        let activity = try XCTUnwrap(digest.activities.first)
        XCTAssertEqual(activity.textExcerpts.last?.focusIdentity, 7)
        XCTAssertEqual(activity.textExcerpts.last?.windowID, 1)
        let material = MemoryWriter.textEvidenceSection(for: activity)
        let prompt = MemoryGenerator.userPrompt(digest: digest, events: events, priorMemory: nil)
        let fact = MemoryWriter.recordingSection(for: activity)
        XCTAssertTrue(prompt.contains(material))
        XCTAssertTrue(fact.contains(material))
        XCTAssertTrue(material.contains("控件变化"))
        XCTAssertFalse(material.contains("`ni`"))
        XCTAssertTrue(material.contains("\(id)#\(edits[0].id)"))
        let output = try MemoryGenerator(rootDirectory: root,
            memoriesDirectory: root.appendingPathComponent("memories")).generate(segmentID: id)
        XCTAssertFalse(output.usedModel)
        XCTAssertTrue(try String(contentsOf: output.memoryURL, encoding: .utf8).contains(material))
        let entry = try XCTUnwrap(MemoryIndex.parse(fileURL: output.memoryURL))
        let narrative = NarrativeGenerator.userPrompt(day: "synthetic-day", sources: [entry])
        XCTAssertFalse(narrative.contains("文本证据：本段含未确认归因的值变化"))
        XCTAssertTrue(narrative.contains("Synthetic"))
    }

    func testInputActivityDoesNotCrossWindowsOrPause() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = CollectionSession(configuration: .init(rootDirectory: root))
        try session.start(now: t0)
        let id = try XCTUnwrap(session.currentSegmentID)
        let app = EventStreamApp(processIdentifier: 42, bundleIdentifier: "com.example.editor")
        func sample(_ value: String, _ tick: Double, windowID: UInt32) {
            session.sampleTextInput(app: app, window: .init(windowID: windowID), readFocused: {
                (.init(value: value, focusIdentity: 1), nil)
            }, now: t0.addingTimeInterval(tick))
        }
        sample("", 0.1, windowID: 1)
        session.noteInputActivity(processIdentifier: 42, at: t0.addingTimeInterval(0.2))
        sample("", 0.3, windowID: 2)
        sample("programmatic", 0.4, windowID: 2)
        sample("programmatic", 4, windowID: 2)
        session.isPaused = true
        session.noteInputActivity(processIdentifier: 42, at: t0.addingTimeInterval(5))
        session.isPaused = false
        sample("", 5.1, windowID: 2)
        sample("after-pause", 5.2, windowID: 2)
        try session.stop(now: t0.addingTimeInterval(6))
        let events = try MemoryGenerator.readEvents(at: root.appendingPathComponent("segments/\(id)/events.jsonl"))
        let edits = events.filter { $0.kind == .keyboardTextInput }
        XCTAssertEqual(edits.compactMap { $0.keyboard?.textEvidence }, [.uncertainValueChange, .uncertainValueChange])
    }

    func testSummaryBudgetKeepsLateReliableEditsAndLegacyRemainsUnknown() throws {
        var events: [EventStreamRecord] = []
        for i in 0..<35 {
            let keyboard = EventStreamKeyboardInteraction(text: i < 30 ? "fragment-\(i)" : "effective-\(i)",
                textEvidence: i < 30 ? nil : .editedValue, focusIdentity: i < 30 ? nil : 7)
            events.append(.init(id: i, timestamp: t0.addingTimeInterval(Double(i)), kind: .keyboardTextInput,
                app: .init(bundleIdentifier: "com.example.editor"), window: .init(windowID: 1), mouse: nil,
                keyboard: keyboard, selection: nil, ax: nil))
        }
        let activity = try XCTUnwrap(SegmentDigest.make(events: events, segmentID: "fixture").activities.first)
        let selected = activity.selectedTextExcerpts()
        XCTAssertEqual(selected.count, 20)
        XCTAssertTrue(selected.contains { $0.text == "effective-34" })
        XCTAssertTrue(selected.contains { $0.text == "fragment-0" })
        XCTAssertTrue(selected.contains { $0.text == "fragment-29" })
        let legacy = try JSONDecoder().decode(EventStreamKeyboardInteraction.self, from: Data(#"{"text":"git status"}"#.utf8))
        XCTAssertNil(legacy.textEvidence)
        let roundtrip = try JSONDecoder().decode(EventStreamKeyboardInteraction.self,
            from: JSONEncoder().encode(events.last!.keyboard!))
        XCTAssertEqual(roundtrip.textEvidence, .editedValue)
    }
}
