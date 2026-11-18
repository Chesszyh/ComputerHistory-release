import Foundation
import XCTest
@testable import ComputerHistoryCore

@MainActor
final class CollectorPowerTests: XCTestCase {
    private let app = EventStreamApp(name: "Synthetic", processIdentifier: 42, bundleIdentifier: "test.editor")
    private let login = EventStreamApp(bundleIdentifier: "com.apple.loginwindow")
    private let start = SegmentClock.alignedStart(for: Date(timeIntervalSince1970: 1_800_000_000))

    private func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("power-" + UUID().uuidString)
    }

    func testSleepSealsImmediatelyAndMaintenanceDoesNotResumeSampling() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        var readers = CollectionSession.ContentReaders()
        let app = app
        readers.currentApp = { app }
        readers.idleSeconds = { 0 }
        var windowReads = 0
        readers.window = { _, _ in windowReads += 1; return .init(details: .init(windowID: 7)) }
        readers.prepare = { _, _, _, _ in }
        readers.tree = { _, _, _ in [.init(id: 1, text: "Synthetic frame")] }
        let session = CollectionSession(configuration: .init(rootDirectory: root), readers: readers, secureInput: { false })
        try session.start(now: start)
        let originalSegment = try XCTUnwrap(session.currentSegmentID)
        session.sampleFrontmost(now: start)
        let before = windowReads
        let sleepingAt = start.addingTimeInterval(33)
        session.observePower(.willSleep(sleepingAt))
        XCTAssertTrue(session.isAway)
        XCTAssertTrue(session.isSystemSleeping)
        XCTAssertEqual(AwayPeriods.load(root: root).startedAt, sleepingAt)
        let metaFile = root.appendingPathComponent("segments/\(originalSegment)/metadata.json")
        let metadata = try EventStreamJSON.makeDecoder().decode(EventStreamMetadata.self, from: Data(contentsOf: metaFile))
        XCTAssertEqual(metadata.endedAt, sleepingAt)
        XCTAssertNil(session.currentSegmentID)
        for offset in [40.0, 80, 1500] {
            let now = start.addingTimeInterval(offset)
            session.sampleFrontmost(now: now)
            session.sampleTextInput(now: now)
            XCTAssertFalse(session.observeAvailability(app: app, now: now, idleSeconds: 0))
            session.observePower(.willSleep(now))
        }
        XCTAssertEqual(windowReads, before)
        XCTAssertEqual(AwayPeriods.load(root: root).startedAt, sleepingAt)
        XCTAssertTrue(AwayPeriods.load(root: root).periods.isEmpty)

        let unlockedAt = start.addingTimeInterval(3200)
        session.observePower(.didWake)
        session.observePower(.didWake)
        XCTAssertFalse(session.isSystemSleeping)
        XCTAssertFalse(session.observeAvailability(app: login, now: unlockedAt.addingTimeInterval(-3)))
        XCTAssertFalse(session.observeAvailability(app: nil, now: unlockedAt.addingTimeInterval(-2)))
        XCTAssertEqual(AwayPeriods.load(root: root).startedAt, sleepingAt)
        session.sampleFrontmost(now: unlockedAt)
        XCTAssertFalse(session.isAway)
        try session.stop(now: unlockedAt.addingTimeInterval(1))
        let periods = AwayPeriods.load(root: root).periods
        XCTAssertEqual(periods, [.init(start: sleepingAt, end: unlockedAt, reason: .locked)])
        let timeline = await TraySnapshotLoader().load(root: root)
        let cards = timeline.groups.flatMap(\.items).flatMap(\.leafItems)
        XCTAssertEqual(cards.filter(\.isAway).map(\.summary), ["锁屏或休眠"])
        let folders = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("segments"), includingPropertiesForKeys: nil)
        let events = try folders.flatMap { try EventArchive.readEvents(at: EventArchive.eventsURL(in: $0)) }
        XCTAssertEqual(events.compactMap(\.ax?.mode), [.fullTree, .fullTree])
    }

    func testSleepExtendsExistingLockAndSurvivesCollectorRestart() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = CollectionSession.Configuration(rootDirectory: root)
        let session = CollectionSession(configuration: configuration, readers: .init(), secureInput: { false })
        try session.start(now: start)
        XCTAssertFalse(session.observeAvailability(app: login, now: start, idleSeconds: 0))
        session.observePower(.willSleep(start.addingTimeInterval(30)))
        try session.stop(now: start.addingTimeInterval(60))
        let restarted = CollectionSession(configuration: configuration, readers: .init(), secureInput: { false })
        try restarted.start(now: start.addingTimeInterval(120))
        XCTAssertTrue(restarted.isAway)
        XCTAssertTrue(restarted.isSystemSleeping)
        XCTAssertFalse(restarted.observeAvailability(app: app, now: start.addingTimeInterval(120), idleSeconds: 0))
        restarted.observePower(.willSleep(start.addingTimeInterval(150)))
        restarted.observePower(.didWake)
        XCTAssertTrue(restarted.observeAvailability(app: app, now: start.addingTimeInterval(900), idleSeconds: 0))
        XCTAssertEqual(AwayPeriods.load(root: root).periods, [.init(start: start, end: start.addingTimeInterval(900), reason: .locked)])
        XCTAssertNil(AwayPeriods.load(root: root).systemSleep)
        try restarted.stop(now: start.addingTimeInterval(901))
    }

    func testIdleAndSleepKeepTheirOwnNonOverlappingTimesAndPausedSleepRecordsNothing() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = CollectionSession(configuration: .init(rootDirectory: root), readers: .init(), secureInput: { false })
        try session.start(now: start)
        XCTAssertFalse(session.observeAvailability(app: app, now: start, idleSeconds: 300))
        let sleepingAt = start.addingTimeInterval(100)
        session.observePower(.willSleep(sleepingAt))
        session.observePower(.didWake)
        let awake = start.addingTimeInterval(200)
        XCTAssertTrue(session.observeAvailability(app: app, now: awake, idleSeconds: 0))
        let recorded = AwayPeriods.load(root: root)
        XCTAssertEqual(recorded.periods, [.init(start: start, end: sleepingAt, reason: .idle),
                                          .init(start: sleepingAt, end: awake, reason: .locked)])
        session.isPaused = true
        session.observePower(.willSleep(start.addingTimeInterval(201)))
        session.observePower(.didWake)
        XCTAssertTrue(session.isPaused)
        XCTAssertFalse(session.canSampleContent())
        XCTAssertEqual(AwayPeriods.load(root: root), recorded)
        try session.stop(now: start.addingTimeInterval(202))
    }
}
