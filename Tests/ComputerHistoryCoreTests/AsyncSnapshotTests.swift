import Foundation
import XCTest
@testable import ComputerHistoryCore

private final class ControlledAXRead: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false
    private var calls = 0
    private var onMain = false

    var count: Int { condition.lock(); defer { condition.unlock() }; return calls }
    var ranOnMain: Bool { condition.lock(); defer { condition.unlock() }; return onMain }

    func read(pid: Int32, maxNodes: Int) -> [UIElementRender] {
        condition.lock()
        calls += 1
        onMain = Thread.isMainThread
        let deadline = Date().addingTimeInterval(5)
        while !released {
            if !condition.wait(until: deadline) { break }
        }
        condition.unlock()
        return [.init(id: 1, text: "synthetic snapshot")]
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

@MainActor
final class AsyncSnapshotTests: XCTestCase {
    private typealias Context = CollectionSession.FrontmostSnapshotContext
    private final class State {
        var context: Context?
        var now: Date
        init(_ context: Context, now: Date) { self.context = context; self.now = now }
    }
    private let app = EventStreamApp(name: "Synthetic", processIdentifier: 42, bundleIdentifier: "test.browser")
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("async-snapshot-" + UUID().uuidString)
    }

    private func schedule(_ session: CollectionSession, _ state: State, _ reader: ControlledAXRead, sampledAt: Date? = nil) {
        session.sampleFrontmostAsync(context: state.context, now: sampledAt ?? start, idleSeconds: 0,
            read: { reader.read(pid: $0, maxNodes: $1) },
            currentContext: { state.context }, completedAt: { state.now })
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() {
            guard Date() < deadline else { XCTFail("async snapshot did not settle"); return }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private func events(_ root: URL) throws -> [EventStreamRecord] {
        let directories = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("segments"), includingPropertiesForKeys: nil)
        let decoder = EventStreamJSON.makeDecoder()
        return try directories.sorted { $0.lastPathComponent < $1.lastPathComponent }.flatMap { directory in
            try Data(contentsOf: directory.appendingPathComponent("events.jsonl"))
                .split(separator: 0x0A).map { try decoder.decode(EventStreamRecord.self, from: Data($0)) }
        }
    }

    func testBlockedReadDoesNotBlockInputOrLaunchOverlappingReads() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = CollectionSession(configuration: .init(rootDirectory: root))
        try session.start(now: start)
        let state = State(Context(app: app, window: .init(windowID: 7)), now: start.addingTimeInterval(2))
        let reader = ControlledAXRead()
        defer { reader.release() }
        schedule(session, state, reader)
        try await waitFor { reader.count == 1 }
        XCTAssertFalse(reader.ranOnMain)
        session.recordClick(button: "left", clickCount: 1, modifiers: [], app: app,
                            window: state.context?.window, readTarget: { nil }, at: start.addingTimeInterval(1))
        XCTAssertEqual(session.totalEventsWritten, 2)
        schedule(session, state, reader)
        XCTAssertEqual(reader.count, 1)
        reader.release()
        try await waitFor { !session.frontmostSampleInFlight }
        try session.stop(now: start.addingTimeInterval(3))
        let records = try events(root)
        XCTAssertEqual(records.map(\.kind), [.sessionStarted, .mouseClick, .windowChanged, .sessionEnded])
        XCTAssertEqual(records.map(\.timestamp), records.map(\.timestamp).sorted())
    }

    func testTabNavigationRejectsSnapshotAndBlockedPageIsNotRead() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = CollectionSession(configuration: .init(rootDirectory: root,
            policy: .init(blocklist: [.domain("blocked.test")])))
        try session.start(now: start)
        let state = State(Context(app: app, window: .init(url: "https://allowed.test", windowID: 7)),
                          now: start.addingTimeInterval(2))
        let reader = ControlledAXRead()
        defer { reader.release() }
        schedule(session, state, reader)
        try await waitFor { reader.count == 1 }
        state.context?.window?.url = "https://blocked.test"
        reader.release()
        try await waitFor { !session.frontmostSampleInFlight }
        schedule(session, state, reader)
        XCTAssertFalse(session.frontmostSampleInFlight)
        XCTAssertEqual(reader.count, 1)
        try session.stop(now: start.addingTimeInterval(3))
        XCTAssertFalse(try events(root).contains { $0.ax != nil })
    }

    func testObservedWindowSwitchAndReturnRejectsOldRead() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = CollectionSession(configuration: .init(rootDirectory: root))
        try session.start(now: start)
        let original = Context(app: app, window: .init(windowID: 7))
        let state = State(original, now: start.addingTimeInterval(2))
        let reader = ControlledAXRead()
        defer { reader.release() }
        schedule(session, state, reader)
        try await waitFor { reader.count == 1 }
        state.context?.window?.windowID = 8
        schedule(session, state, reader)
        state.context = original
        schedule(session, state, reader)
        reader.release()
        try await waitFor { !session.frontmostSampleInFlight }
        try session.stop(now: start.addingTimeInterval(3))
        XCTAssertFalse(try events(root).contains { $0.ax != nil })
    }

    func testPauseConfigurationRestartAndIdleTransitionsRejectOldReads() async throws {
        for transition in ["pause", "configuration", "restart", "idle"] {
            let root = root()
            defer { try? FileManager.default.removeItem(at: root) }
            let session = CollectionSession(configuration: .init(rootDirectory: root))
            try session.start(now: start)
            let state = State(Context(app: app, window: .init(windowID: 7)), now: start.addingTimeInterval(2))
            let reader = ControlledAXRead()
            defer { reader.release() }
            schedule(session, state, reader)
            try await waitFor { reader.count == 1 }
            switch transition {
            case "pause": session.isPaused = true; session.isPaused = false
            case "configuration": session.applyConfiguration(.init())
            case "restart":
                try session.stop(now: start.addingTimeInterval(1))
                try session.start(now: start.addingTimeInterval(1))
            default:
                session.observeAvailability(app: app, now: start.addingTimeInterval(1), idleSeconds: AwayPeriods.idleThreshold)
                session.observeAvailability(app: app, now: start.addingTimeInterval(1), idleSeconds: 0)
            }
            reader.release()
            try await waitFor { !session.frontmostSampleInFlight }
            XCTAssertFalse(try events(root).contains { $0.ax != nil }, transition)
            schedule(session, state, reader)
            try await waitFor { !session.frontmostSampleInFlight }
            try session.stop(now: start.addingTimeInterval(3))
            XCTAssertEqual(try events(root).filter { $0.ax != nil }.count, 1, transition)
        }
    }

    func testCompletionAfterSegmentBoundaryUsesCompletionTime() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = CollectionSession(configuration: .init(rootDirectory: root))
        let boundary = SegmentClock.alignedStart(for: start).addingTimeInterval(600)
        try session.start(now: boundary.addingTimeInterval(-1))
        let state = State(Context(app: app, window: .init(windowID: 7)), now: boundary.addingTimeInterval(2))
        let reader = ControlledAXRead()
        defer { reader.release() }
        schedule(session, state, reader, sampledAt: boundary.addingTimeInterval(-1))
        try await waitFor { reader.count == 1 }
        session.recordClick(button: "left", clickCount: 1, modifiers: [], app: app,
                            window: state.context?.window, readTarget: { nil }, at: boundary.addingTimeInterval(1))
        let activeSegment = try XCTUnwrap(session.currentSegmentID)
        reader.release()
        try await waitFor { !session.frontmostSampleInFlight }
        try session.stop(now: boundary.addingTimeInterval(3))
        let records = try events(root)
        XCTAssertEqual(records.map(\.timestamp), records.map(\.timestamp).sorted())
        XCTAssertEqual(records.first { $0.ax != nil }?.timestamp, boundary.addingTimeInterval(2))
        let data = try Data(contentsOf: root.appendingPathComponent("segments/\(activeSegment)/metadata.json"))
        let metadata = try EventStreamJSON.makeDecoder().decode(EventStreamMetadata.self, from: data)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(metadata.firstEventAt), boundary)
    }
}
