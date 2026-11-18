import ApplicationServices
import Foundation
import os
import XCTest
@testable import ComputerHistoryCore

@MainActor
final class WindowIdentityTests: XCTestCase {
    private typealias Context = CollectionSession.FrontmostSnapshotContext
    private let app = EventStreamApp(name: "Synthetic", processIdentifier: 42, bundleIdentifier: "test.windows")
    private let start = SegmentClock.alignedStart(for: Date(timeIntervalSince1970: 1_800_000_000))

    private func context(_ proxy: pid_t? = nil, title: String = "Same title",
                         url: String? = "https://example.test/shared", number: UInt32? = nil) -> Context {
        // These opaque CF proxies exercise equality without querying any process or UI.
        .init(app: app, observedWindow: .init(details: .init(title: title, url: url, windowID: number),
            reference: proxy.map { .init(element: AXUIElementCreateApplication($0)) }))
    }

    private func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    private func events(_ root: URL) throws -> [EventStreamRecord] {
        let folders = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("segments"),
                                                                  includingPropertiesForKeys: nil)
        return try folders.flatMap { try EventArchive.readEvents(at: $0.appendingPathComponent("events.jsonl")) }
    }

    func testNumberlessWindowsWithTheSameTitleAndURLDoNotShareTreeDiffs() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = CollectionSession(configuration: .init(rootDirectory: root))
        try session.start(now: start)
        let owners = [context(101), context(102), context(102, title: "Renamed"),
                      context(102, title: "Renamed", url: "https://example.test/other")]
        for (index, owner) in owners.enumerated() {
            session.recordSnapshot(roots: [.init(id: 1, text: "Synthetic content \(index)")],
                                   context: owner, now: start.addingTimeInterval(Double(index)))
        }
        try session.stop(now: start.addingTimeInterval(4))
        let snapshots = try events(root).filter { $0.kind == .windowChanged }
        XCTAssertEqual(snapshots.compactMap(\.ax?.mode), [.fullTree, .fullTree, .diffFromPrevious, .fullTree])
        XCTAssertEqual(snapshots.compactMap(\.window?.title), ["Same title", "Same title", "Renamed", "Renamed"])
        XCTAssertTrue(snapshots.allSatisfy { $0.window?.windowID == nil })
    }

    func testSystemWindowNumberTakesPrecedenceOverAXProxy() {
        let first = context(101, number: 7)
        XCTAssertTrue(first.matches(context(102, title: "Renamed", number: 7)))
        XCTAssertFalse(first.matches(context(101, number: 8)))
        XCTAssertFalse(first.matches(context(101, url: nil, number: 7)))
    }

    func testUnresolvedIdentityKeepsFullFramesAndSkipsUnboundContentReads() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = CollectionSession(configuration: .init(rootDirectory: root))
        let unknown = context()
        try session.start(now: start)
        session.recordSnapshot(roots: [.init(id: 1, text: "Content A")], context: unknown, now: start)
        session.recordSnapshot(roots: [.init(id: 1, text: "Content B")], context: unknown, now: start.addingTimeInterval(1))
        XCTAssertNil(session.sampleTextInput(context: unknown, readFocused: {
            XCTFail("Unresolved window must not enter the text tracker")
            return (.init(value: "Unbound"), nil)
        }, now: start.addingTimeInterval(2)))
        session.sampleFrontmostAsync(context: unknown, now: start.addingTimeInterval(3), idleSeconds: 0,
            read: { _, _, _ in XCTFail("Unresolved window must not schedule a tree"); return [] },
            currentContext: { unknown })
        XCTAssertFalse(session.frontmostSampleInFlight)
        try session.stop(now: start.addingTimeInterval(4))
        XCTAssertEqual(try events(root).compactMap(\.ax?.mode), [.fullTree, .fullTree])
    }

    func testNumberlessWindowSwitchFlushesTextUnderItsOriginalOwner() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = CollectionSession(configuration: .init(rootDirectory: root))
        let first = context(101), second = context(102)
        try session.start(now: start)
        func read(_ owner: Context, value: String, target: String, tick: TimeInterval) {
            session.sampleTextInput(context: owner, readFocused: {
                (.init(value: value, caret: value.utf16.count, focusIdentity: 1, hasInputActivity: true),
                 .init(identifier: target))
            }, now: start.addingTimeInterval(tick))
        }
        read(first, value: "First buffer", target: "first", tick: 0)
        read(first, value: "First buffer edit A", target: "first", tick: 0.1)
        read(second, value: "Second preexisting buffer", target: "second", tick: 0.2)
        read(second, value: "Second preexisting buffer edit B", target: "second", tick: 0.3)
        try session.stop(now: start.addingTimeInterval(1))
        let recorded = try events(root).filter { $0.kind == .keyboardTextInput }
        XCTAssertEqual(recorded.compactMap(\.keyboard?.text), [" edit A", " edit B"])
        XCTAssertEqual(recorded.compactMap(\.keyboard?.target?.identifier), ["first", "second"])
        XCTAssertTrue(recorded.allSatisfy { $0.window?.windowID == nil })
    }

    func testPublicInputActivityRequiresTheWindowThatOwnsTheTextBaseline() throws {
        let switches = [(context(101), context(102)),
                        (context(101, url: nil), context(101)),
                        (context(101), context(101, url: nil))]
        for (first, second) in switches {
            try checkInputActivityDuringSwitch(from: first, to: second)
        }
    }

    private func checkInputActivityDuringSwitch(from first: Context, to second: Context) throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        var active = first
        let buffer = OSAllocatedUnfairLock(initialState: "Initial buffer")
        var readers = CollectionSession.ContentReaders()
        let app = app
        readers.currentApp = { app }
        readers.window = { _, _ in active.observedWindow }
        readers.inputWindowMatches = { _, expected, access in
            FrontmostApplication.focusedWindowMatches(expected, access: access,
                readWindow: { active.observedWindow?.reference?.element }, readURL: { _ in active.window?.url })
        }
        readers.focusedText = { _, _, _ in
            let value = buffer.withLock { $0 }
            return (.init(value: value, caret: value.utf16.count, focusIdentity: 1), nil)
        }
        let session = CollectionSession(configuration: .init(rootDirectory: root), readers: readers, secureInput: { false })
        try session.start(now: start)
        session.sampleTextInput(now: start)
        active = second
        session.noteInputActivity(at: start.addingTimeInterval(0.1))
        active = first
        buffer.withLock { $0 += " synthetic insertion" }
        session.sampleTextInput(now: start.addingTimeInterval(0.2))
        session.noteInputActivity(at: start.addingTimeInterval(3))
        buffer.withLock { $0 += " confirmed edit" }
        session.sampleTextInput(now: start.addingTimeInterval(3.1))
        try session.stop(now: start.addingTimeInterval(4))
        let edits = try events(root).filter { $0.keyboard?.textEvidence == .editedValue }
        XCTAssertEqual(edits.compactMap(\.keyboard?.text), [" confirmed edit"],
                       "Unexpected edit evidence across \(String(describing: first.window?.url)) → \(String(describing: second.window?.url))")
    }

    func testInputActivityWaitsForAnotherWindowObservationAfterTimeout() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = context(101)
        var readers = CollectionSession.ContentReaders()
        let app = app
        readers.currentApp = { app }
        readers.window = { _, _ in owner.observedWindow }
        readers.focusedText = { _, _, _ in (.init(value: "Baseline", focusIdentity: 1), nil) }
        var checks = 0
        readers.inputWindowMatches = { _, expected, access in
            FrontmostApplication.focusedWindowMatches(expected, access: access, readWindow: {
                checks += 1
                _ = access.perform { .cannotComplete }
                return nil
            }, readURL: { _ in XCTFail("query must stop on timeout"); return nil })
        }
        let session = CollectionSession(configuration: .init(rootDirectory: root), readers: readers, secureInput: { false })
        try session.start(now: start)
        session.sampleTextInput(now: start)
        for tick in [0.1, 0.2, 0.3] { session.noteInputActivity(at: start.addingTimeInterval(tick)) }
        XCTAssertEqual(checks, 1)
        session.sampleTextInput(now: start.addingTimeInterval(1))
        session.noteInputActivity(at: start.addingTimeInterval(1.1))
        XCTAssertEqual(checks, 2)
        try session.stop(now: start.addingTimeInterval(2))
    }

    func testTimedOutURLCannotMatchAnAbsentURL() throws {
        let window = try XCTUnwrap(context(101, url: nil).observedWindow)
        let access = AccessibilityRead { true }
        XCTAssertFalse(FrontmostApplication.focusedWindowMatches(window, access: access,
            readWindow: { window.reference?.element }, readURL: { _ in
                _ = access.perform { .cannotComplete }
                return nil
            }))
        XCTAssertTrue(access.communicationFailed)
    }

    func testScrollThrottleUsesWindowIdentity() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = CollectionSession(configuration: .init(rootDirectory: root))
        try session.start(now: start)
        for (idx, proxy) in [101, 101, 102].enumerated() {
            session.recordScroll(deltaX: 0, deltaY: -5, modifiers: [], context: context(pid_t(proxy)),
                readTarget: { .init(identifier: "target-\(idx)") }, at: start.addingTimeInterval(Double(idx) * 0.1))
        }
        try session.stop(now: start.addingTimeInterval(1))
        XCTAssertEqual(try events(root).compactMap(\.mouse?.target?.identifier), ["target-0", "target-2"])
    }
}
