import Foundation
import XCTest
@testable import ComputerHistoryCore

final class ReviewRegressionTests: XCTestCase {
    func testPartialPolicyPreservesDefaults() throws {
        for json in ["{}", "{\"policy\":{}}", "{\"policy\":{\"forcedBlockedDomains\":[\"secret.test\"]}}"] {
            let config = try CollectorConfig.decode(from: Data(json.utf8))
            XCTAssertEqual(config.policy.blocklist, ObservationPolicy.conservative.blocklist)
        }
        let empty = try CollectorConfig.decode(from: Data("{\"policy\":{\"blocklist\":[]}}".utf8))
        XCTAssertTrue(empty.policy.blocklist.isEmpty)
    }

    func testInvalidConfigurationCannotSilentlyEnableObservation() throws {
        let invalid = [
            #"{"polciy":{}}"#,
            #"{"policy":null}"#,
            #"{"policy":{"defaultApplicationBehavior":"do-not-observe"}}"#,
            #"{"policy":{"blocklist":"com.example.secret"}}"#,
            #"{"policy":{"blocklist":[{"scope":"app","bundleId":"com.example.secret"}]}}"#,
            #"{"policy":{"blocklist":[{"scope":"app","bundleID":""}]}}"#,
            #"{"policy":{"forcedBlockedDomains":["https://secret.test"]}}"#,
            #"{"policy":{"blocklist":[{"scope":"url","urlDomain":"*.secret.test"}]}}"#,
            #"{"retention":{"maxAgeDays":-1}}"#,
            #"{"maxNodesPerSnapshot":true}"#,
            #"{"maxNodesPerSnapshot":1.5}"#,
        ]
        for json in invalid {
            XCTAssertThrowsError(try CollectorConfig.decode(from: Data(json.utf8)), json)
        }
        _ = try CollectorConfig.decode(from: CollectorConfig().jsonData())
    }

    func testRestartPreservesExistingSegment() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = CollectionSession(configuration: .init(rootDirectory: root))
        try first.start(now: now)
        first.recordTextInput("preserved", at: now.addingTimeInterval(1))
        let id = try XCTUnwrap(first.currentSegmentID)
        try first.stop(now: now.addingTimeInterval(2))
        let events = root.appendingPathComponent("segments/\(id)/events.jsonl")
        let original = try Data(contentsOf: events)
        let second = CollectionSession(configuration: .init(rootDirectory: root))
        try second.start(now: now.addingTimeInterval(4))
        XCTAssertEqual(try Data(contentsOf: events), original)
        XCTAssertNotEqual(second.currentSegmentID, id)
        try second.stop(now: now.addingTimeInterval(5))
    }

    func testUnicodeReplacementKeepsCompleteCharacters() {
        for (before, after) in [("😀", "😁"), ("𠀀", "𠀁"), ("👩‍💻", "👩‍🔬"), ("e", "e\u{301}")] {
            let tracker = TextInputTracker()
            let now = Date()
            _ = tracker.observe(.init(value: before, caret: nil), at: now)
            _ = tracker.observe(.init(value: after, caret: nil), at: now.addingTimeInterval(1))
            XCTAssertEqual(tracker.flush(), after)
        }
    }

    func testStableIdentitySurvivesListChanges() throws {
        func nodes(_ ids: [Int]) -> [UIElementRender] {
            ids.map { UIElementRender(id: $0, text: "文本", detailText: "row\($0)") }
        }
        let inserted = try XCTUnwrap(UIElementRenderDifference.lines(from: nodes([1, 2]), to: nodes([3, 1, 2])))
        XCTAssertEqual(inserted.filter { $0.hasPrefix("+") }.count, 1)
        XCTAssertFalse(inserted.contains { $0.hasPrefix("Removed") })
        let deleted = try XCTUnwrap(UIElementRenderDifference.lines(from: nodes([3, 1, 2]), to: nodes([1, 2])))
        XCTAssertEqual(deleted.first, "Removed element IDs: 0")
        XCTAssertFalse(deleted.contains { $0.hasPrefix("+") })
        let reordered = try XCTUnwrap(UIElementRenderDifference.lines(from: nodes([1, 2, 3]), to: nodes([3, 1, 2])))
        XCTAssertEqual(reordered.filter { $0.hasPrefix("+") }.count, 1)
        XCTAssertEqual(reordered.filter { $0.hasPrefix("~") }.count, 2)
    }

    func testTextKeepsOriginalContextAndNeverReadsBlockedValues() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let session = CollectionSession(configuration: .init(rootDirectory: root,
            policy: .init(blocklist: [.application("blocked.app"), .domain("secret.test")])))
        try session.start(now: now)
        let id = try XCTUnwrap(session.currentSegmentID)
        var tick = 0.0
        var blockedReads = 0
        func sample(_ bundle: String, _ window: EventStreamWindow, _ focus: Int, _ value: String) {
            tick += 0.1
            session.sampleTextInput(app: .init(processIdentifier: 123, bundleIdentifier: bundle),
                window: window, readFocused: {
                    if bundle == "blocked.app" || window.url?.contains("secret.test") == true { blockedReads += 1 }
                    return (.init(value: value, caret: nil, focusIdentity: focus),
                            .init(identifier: "field\(focus)"))
                }, now: now.addingTimeInterval(tick))
        }
        let first = EventStreamWindow(title: "first", windowID: 1)
        let second = EventStreamWindow(title: "second", windowID: 2)
        sample("allowed.app", first, 1, "")
        sample("allowed.app", first, 1, "first input")
        sample("allowed.app", first, 2, "existing")
        sample("allowed.app", first, 2, "existing second input")
        sample("other.app", second, 3, "")
        sample("other.app", second, 3, "third input")
        sample("blocked.app", second, 4, "")
        sample("blocked.app", second, 4, "secret")
        sample("allowed.app", .init(url: "https://secret.test"), 5, "domain secret")
        sample("allowed.app", first, 1, "baseline")
        sample("allowed.app", first, 1, "baseline tail")
        try session.stop(now: now.addingTimeInterval(2))
        XCTAssertEqual(blockedReads, 0)
        let data = try String(contentsOf: root.appendingPathComponent("segments/\(id)/events.jsonl"), encoding: .utf8)
        let records = try data.split(separator: "\n").map {
            try EventStreamJSON.makeDecoder().decode(EventStreamRecord.self, from: Data($0.utf8))
        }.filter { $0.kind == .keyboardTextInput }
        XCTAssertEqual(records.map { $0.keyboard?.text }, ["first input", " second input", "third input", " tail"])
        XCTAssertEqual(records.map { $0.app?.bundleIdentifier }, ["allowed.app", "allowed.app", "other.app", "allowed.app"])
        XCTAssertEqual(records.map { $0.keyboard?.target?.identifier }, ["field1", "field2", "field3", "field1"])
        XCTAssertEqual(records.map { $0.window?.windowID }, [1, 1, 2, 1])
    }

    func testSuppressionDoesNotDependOnCounting() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let session = CollectionSession(configuration: .init(rootDirectory: root,
            tracksSuppression: false, policy: .init(blocklist: [.application("blocked.app")])))
        try session.start(now: now)
        let id = try XCTUnwrap(session.currentSegmentID)
        session.sampleTextInput(app: .init(bundleIdentifier: "blocked.app"), window: nil,
            readFocused: { XCTFail("blocked text must not be read"); return (.init(value: "secret", caret: nil), nil) },
            now: now.addingTimeInterval(1))
        try session.stop(now: now.addingTimeInterval(2))
        let meta = try EventStreamJSON.makeDecoder().decode(EventStreamMetadata.self,
            from: Data(contentsOf: root.appendingPathComponent("segments/\(id)/metadata.json")))
        XCTAssertEqual(meta.eventCount, 2)
        XCTAssertEqual(meta.suppressedEventCount, 0)
    }

    func testCollidingSegmentsRemainPrunableAndActiveSegmentIsProtected() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try SegmentWriter(rootDirectoryURL: root, start: now)
        try first.close(endedAt: now)
        let active = try SegmentWriter(rootDirectoryURL: root, start: now.addingTimeInterval(1))
        let later = try SegmentWriter(rootDirectoryURL: root, start: now.addingTimeInterval(2))
        try later.close(endedAt: now.addingTimeInterval(3))
        XCTAssertEqual(SegmentClock.date(fromSegmentID: active.segmentID), active.startedAt)
        XCTAssertNil(SegmentClock.date(fromSegmentID: first.segmentID + "_unknown"))
        let report = SegmentPruner.prune(rootDirectory: root,
            retention: .init(maxTotalBytes: 1, maxAgeDays: 0), now: now,
            activeSegmentID: active.segmentID)
        XCTAssertEqual(report.removedSegments, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: active.eventsURL.path))
        try active.close(endedAt: now.addingTimeInterval(4))
    }

    func testWindowTitleChangeKeepsInputBaseline() throws {
        for windowID: UInt32? in [1, nil] {
            let root = temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let session = CollectionSession(configuration: .init(rootDirectory: root))
            try session.start(now: now)
            let id = try XCTUnwrap(session.currentSegmentID)
            let app = EventStreamApp(processIdentifier: 123, bundleIdentifier: "editor.app")
            for (index, value) in ["", "My first line", "My first line more text"].enumerated() {
                session.sampleTextInput(app: app,
                    window: .init(title: index == 0 ? "Untitled" : "My first line", windowID: windowID),
                    readFocused: { (.init(value: value, caret: nil, focusIdentity: 1), .init(identifier: "field")) },
                    now: now.addingTimeInterval(Double(index) * 0.1))
            }
            try session.stop(now: now.addingTimeInterval(1))
            let records = try textRecords(root: root, id: id)
            XCTAssertEqual(records.map { $0.keyboard?.text }, ["My first line more text"])
            XCTAssertEqual(records.first?.window?.title, "My first line")
        }
    }

    func testWindowAndDocumentChangesRebuildInputBaseline() throws {
        for nextWindow in [EventStreamWindow(title: "Other", url: "file:///first", windowID: 2),
                           EventStreamWindow(title: "Other", url: "file:///second", windowID: 1)] {
            let root = temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let session = CollectionSession(configuration: .init(rootDirectory: root))
            try session.start(now: now)
            let id = try XCTUnwrap(session.currentSegmentID)
            let app = EventStreamApp(processIdentifier: 123, bundleIdentifier: "editor.app")
            let first = EventStreamWindow(title: "First", url: "file:///first", windowID: 1)
            let samples: [(EventStreamWindow, String)] = [(first, ""), (first, "first input"),
                (nextWindow, "preexisting"), (nextWindow, "preexisting more text")]
            for (index, sample) in samples.enumerated() {
                session.sampleTextInput(app: app, window: sample.0,
                    readFocused: { (.init(value: sample.1, caret: nil, focusIdentity: 1), nil) },
                    now: now.addingTimeInterval(Double(index) * 0.1))
            }
            try session.stop(now: now.addingTimeInterval(1))
            let records = try textRecords(root: root, id: id)
            XCTAssertEqual(records.map { $0.keyboard?.text }, ["first input", " more text"])
            XCTAssertEqual(records.first?.window, first)
            XCTAssertEqual(records.last?.window, nextWindow)
        }
    }

    func testPauseDiscardsBaselineAndDoesNotReadFocusedText() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let session = CollectionSession(configuration: .init(rootDirectory: root))
        try session.start(now: now)
        let id = try XCTUnwrap(session.currentSegmentID)
        let app = EventStreamApp(processIdentifier: 123, bundleIdentifier: "editor.app")
        func sample(_ value: String, _ tick: Double) {
            session.sampleTextInput(app: app, window: nil,
                readFocused: { (.init(value: value, caret: nil, focusIdentity: 1), nil) },
                now: now.addingTimeInterval(tick))
        }
        sample("baseline", 0.1)
        sample("baseline pending", 0.2)
        session.isPaused = true
        session.sampleTextInput(app: app, window: nil, readFocused: {
            XCTFail("paused session must not read focused text")
            return (.init(value: "baseline pending SECRET", caret: nil, focusIdentity: 1), nil)
        }, now: now.addingTimeInterval(0.3))
        session.isPaused = false
        sample("baseline pending SECRET", 0.4)
        sample("baseline pending SECRET public", 0.5)
        try session.stop(now: now.addingTimeInterval(1))
        XCTAssertEqual(try textRecords(root: root, id: id).map { $0.keyboard?.text }, [" public"])
    }

    func testStopReportsMetadataFailure() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = CollectionSession(configuration: .init(rootDirectory: root))
        try session.start()
        let id = try XCTUnwrap(session.currentSegmentID)
        let metadata = root.appendingPathComponent("segments/\(id)/metadata.json")
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
        XCTAssertThrowsError(try session.stop())
        XCTAssertFalse(session.isRecording)
    }

    func testMetadataCloseCanRetryAfterWriteFailure() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try SegmentWriter(rootDirectoryURL: root, start: Date())
        try FileManager.default.createDirectory(at: writer.metadataURL, withIntermediateDirectories: false)
        XCTAssertThrowsError(try writer.close(endedAt: Date()))
        try FileManager.default.removeItem(at: writer.metadataURL)
        try writer.close(endedAt: Date())
        let meta = try EventStreamJSON.makeDecoder().decode(EventStreamMetadata.self,
            from: Data(contentsOf: writer.metadataURL))
        XCTAssertEqual(meta.id, writer.segmentID)
    }

    private func textRecords(root: URL, id: String) throws -> [EventStreamRecord] {
        let data = try String(contentsOf: root.appendingPathComponent("segments/\(id)/events.jsonl"), encoding: .utf8)
        return try data.split(separator: "\n").map {
            try EventStreamJSON.makeDecoder().decode(EventStreamRecord.self, from: Data($0.utf8))
        }.filter { $0.kind == .keyboardTextInput }
    }

    private func temporaryRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("review-\(UUID())")
    }
}
