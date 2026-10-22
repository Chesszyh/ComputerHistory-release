import Darwin
import Foundation
import XCTest
@testable import ComputerHistoryCore

final class HandoffRegressionTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let app = EventStreamApp(name: "Synthetic", processIdentifier: 98765, bundleIdentifier: "test.editor")

    private func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("handoff-" + UUID().uuidString)
    }

    // Only the test-owned writer's descriptor is closed, then restored before any file is opened.
    private func failingWrites(at url: URL, _ action: () throws -> Void) throws {
        var descriptor: Int32?
        for fd: Int32 in 3..<1024 {
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            if fcntl(fd, F_GETPATH, &path) == 0,
               URL(fileURLWithPath: String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)).resolvingSymlinksInPath() == url.resolvingSymlinksInPath() {
                descriptor = fd
                break
            }
        }
        let fd = try XCTUnwrap(descriptor)
        let backup = dup(fd)
        XCTAssertGreaterThanOrEqual(backup, 0)
        close(fd)
        defer { XCTAssertEqual(dup2(backup, fd), fd); close(backup) }
        try action()
    }

    func testAllowlistRejectsMissingIdentityAndUnknownBrowserURL() {
        let policy = ObservationPolicy(defaultApplicationBehavior: .doNotObserve,
            defaultURLBehavior: .doNotObserve,
            allowlist: [.application("test.editor"), .application("com.apple.Safari"), .domain("allowed.test")],
            blocklist: [.domain("blocked.allowed.test")])
        XCTAssertTrue(policy.shouldSuppress(app: nil, window: nil))
        XCTAssertTrue(policy.shouldSuppress(app: .init(name: "Unknown"), window: nil))
        XCTAssertTrue(policy.shouldSuppress(app: .init(bundleIdentifier: "test.other"), window: nil))
        XCTAssertFalse(policy.shouldSuppress(app: app, window: nil))
        XCTAssertFalse(policy.shouldSuppress(app: app, window: .init(url: "file:///tmp/synthetic.txt")))
        let browser = EventStreamApp(bundleIdentifier: "com.apple.Safari")
        for url in [nil, "", "invalid", "https://other.test", "https://blocked.allowed.test"] as [String?] {
            XCTAssertTrue(policy.shouldSuppress(app: browser, window: .init(url: url)), url ?? "missing")
        }
        XCTAssertFalse(policy.shouldSuppress(app: browser, window: .init(url: "https://allowed.test")))
        XCTAssertTrue(policy.shouldSuppress(app: app, window: .init(url: "invalid")))
    }

    func testAllowlistChecksBeforeReadingAndPreservesSessionEvents() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = CollectionSession(configuration: .init(rootDirectory: root,
            policy: .init(defaultApplicationBehavior: .doNotObserve, defaultURLBehavior: .doNotObserve,
                allowlist: [.application("com.apple.Safari")])))
        try session.start(now: start)
        let id = try XCTUnwrap(session.currentSegmentID)
        for current in [EventStreamApp(name: "Unknown"), .init(bundleIdentifier: "com.apple.Safari")] {
            session.sampleTextInput(app: current, window: nil, readFocused: {
                XCTFail("Disallowed context was read")
                return (.init(value: "synthetic"), nil)
            }, now: start)
        }
        try session.stop(now: start.addingTimeInterval(1))
        let events = try EventArchive.readEvents(at: root.appendingPathComponent("segments/\(id)/events.jsonl"))
        XCTAssertEqual(events.map(\.kind), [.sessionStarted, .sessionEnded])
    }

    func testSnapshotRetriesSameContentAfterSingleAndRepeatedFailures() throws {
        for failures in [1, 3] {
            let root = root()
            defer { try? FileManager.default.removeItem(at: root) }
            let session = CollectionSession(configuration: .init(rootDirectory: root))
            try session.start(now: start)
            let id = try XCTUnwrap(session.currentSegmentID)
            let url = root.appendingPathComponent("segments/\(id)/events.jsonl")
            func snapshot(_ text: String, _ tick: Double) {
                session.recordSnapshot(roots: [.init(id: 1, text: "文本", detailText: "Value: " + text)],
                    app: app, window: .init(windowID: 1), now: start.addingTimeInterval(tick))
            }
            snapshot("BASE", 1)
            try failingWrites(at: url) {
                for n in 0..<failures { snapshot("LOST", Double(n + 2)) }
            }
            XCTAssertEqual(session.writeFailureCount, failures)
            XCTAssertNotNil(session.lastWriteError)
            snapshot("LOST", 6)
            XCTAssertNil(session.lastWriteError)
            snapshot("NEXT", 7)
            try session.stop(now: start.addingTimeInterval(8))
            let events = try EventArchive.readEvents(at: url)
            let trees = events.compactMap(\.ax)
            XCTAssertEqual(trees.count, 3)
            XCTAssertTrue(trees.contains { $0.text.contains("LOST") })
            XCTAssertEqual(trees.dropFirst().first?.mode, .fullTree)
            XCTAssertEqual(events.count, session.totalEventsWritten)
            let meta = try EventStreamJSON.makeDecoder().decode(EventStreamMetadata.self,
                from: Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent("metadata.json")))
            XCTAssertEqual(meta.eventCount, events.count)
        }
    }

    func testRotationFailureRecoversWithFullSnapshot() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = CollectionSession(configuration: .init(rootDirectory: root))
        try session.start(now: start)
        let id = try XCTUnwrap(session.currentSegmentID)
        func snapshot(_ value: String, _ second: Double) {
            session.recordSnapshot(roots: [.init(id: 1, text: "文本", detailText: "Value: " + value)],
                app: app, window: .init(windowID: 1), now: start.addingTimeInterval(second))
        }
        snapshot("BASE", 1)
        let metadata = root.appendingPathComponent("segments/\(id)/metadata.json")
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        snapshot("LOST", 601)
        XCTAssertNotNil(session.lastWriteError)
        try FileManager.default.removeItem(at: metadata)
        snapshot("CHANGED", 602)
        XCTAssertNil(session.lastWriteError)
        let recovered = try XCTUnwrap(session.currentSegmentID)
        XCTAssertNotEqual(recovered, id)
        try session.stop(now: start.addingTimeInterval(603))
        let trees = try EventArchive.readEvents(at: root.appendingPathComponent("segments/\(recovered)/events.jsonl")).compactMap(\.ax)
        XCTAssertEqual(trees.count, 1)
        XCTAssertEqual(trees.first?.mode, .fullTree)
        XCTAssertTrue(trees.first?.text.contains("CHANGED") == true)
    }

    func testPauseDiscardsFailedPendingText() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = CollectionSession(configuration: .init(rootDirectory: root))
        try session.start(now: start)
        let id = try XCTUnwrap(session.currentSegmentID)
        let url = root.appendingPathComponent("segments/\(id)/events.jsonl")
        func sample(_ value: String, _ second: Double) {
            session.sampleTextInput(app: app, window: nil, readFocused: {
                (.init(value: value, focusIdentity: 1), nil)
            }, now: start.addingTimeInterval(second))
        }
        sample("", 0); sample("PENDING", 1)
        try failingWrites(at: url) { sample("PENDING", 5) }
        session.isPaused = true
        session.isPaused = false
        sample("PENDING", 6)
        try session.stop(now: start.addingTimeInterval(7))
        XCTAssertTrue(try EventArchive.readEvents(at: url).allSatisfy { $0.kind != .keyboardTextInput })
    }

    func testOCRRetriesAndStartsNewSegmentWithUnchangedText() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = CollectionSession(configuration: .init(rootDirectory: root, windowTextApplications: ["test.editor"]))
        try session.start(now: start)
        let id = try XCTUnwrap(session.currentSegmentID)
        let url = root.appendingPathComponent("segments/\(id)/events.jsonl")
        session.updateWindowTextContext(roots: [], app: app, window: .init(windowID: 1))
        let context = try XCTUnwrap(session.windowTextContext)
        let result = WindowTextReader.Result(text: "Synthetic OCR", windowID: 1)
        try failingWrites(at: url) { session.recordWindowText(result, context: context, now: start.addingTimeInterval(1)) }
        session.recordWindowText(result, context: context, now: start.addingTimeInterval(2))
        session.recordWindowText(result, context: context, now: start.addingTimeInterval(601))
        try session.stop(now: start.addingTimeInterval(602))
        let dirs = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("segments"), includingPropertiesForKeys: nil)
        XCTAssertEqual(dirs.count, 2)
        for dir in dirs {
            XCTAssertEqual(try EventArchive.readEvents(at: dir.appendingPathComponent("events.jsonl"))
                .filter { $0.ax?.source == "window_ocr" }.count, 1)
        }
    }

    func testFailedTextIsRetriedBeforeReplacementReferenceIsAcknowledged() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = CollectionSession(configuration: .init(rootDirectory: root))
        try session.start(now: start)
        let id = try XCTUnwrap(session.currentSegmentID)
        let url = root.appendingPathComponent("segments/\(id)/events.jsonl")
        func sample(_ value: String, _ tick: Double) {
            session.sampleTextInput(app: app, window: .init(windowID: 1), readFocused: {
                (.init(value: value, focusIdentity: 1, hasInputActivity: true), nil)
            }, now: start.addingTimeInterval(tick))
        }
        sample("", 0)
        sample("FIRST", 1)
        try failingWrites(at: url) { sample("FIRST", 5); sample("FIRST", 6) }
        sample("FIRST", 7)
        sample("SECOND", 8)
        sample("SECOND", 12)
        try session.stop(now: start.addingTimeInterval(13))
        let inputs = try EventArchive.readEvents(at: url).filter { $0.kind == .keyboardTextInput }
        XCTAssertEqual(inputs.compactMap { $0.keyboard?.text }, ["FIRST", "SECOND"])
        XCTAssertEqual(inputs.last?.keyboard?.textReplaces, inputs.first.map { ["\(id)#\($0.id)"] })
    }
}
