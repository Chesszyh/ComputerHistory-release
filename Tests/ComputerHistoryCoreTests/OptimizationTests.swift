import Foundation
import XCTest
@testable import ComputerHistoryCore

final class OptimizationTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testLoginWindowSuspendsAllSamplingAndResumesWithFreshBaseline() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let session = CollectionSession(configuration: .init(rootDirectory: root))
        try session.start(now: start)
        let app = EventStreamApp(name: "Editor", processIdentifier: 42, bundleIdentifier: "example.editor")
        let login = EventStreamApp(name: "Login window", processIdentifier: 43, bundleIdentifier: "com.apple.loginwindow")
        let tree = [UIElementRender(id: 0, text: "Synthetic window")]
        session.recordSnapshot(roots: tree, app: app, window: nil, now: start)
        let count = session.totalEventsWritten
        session.recordSnapshot(roots: tree, app: login, window: nil, now: start.addingTimeInterval(60))
        XCTAssertTrue(session.isAway)
        var readFocused = false
        session.sampleTextInput(app: login, window: nil, readFocused: {
            readFocused = true
            fatalError("Login window must not read focused values")
        }, now: start.addingTimeInterval(120))
        XCTAssertFalse(readFocused)
        XCTAssertEqual(session.totalEventsWritten, count)
        XCTAssertEqual(AwayPeriods.load(root: root).startedAt, start.addingTimeInterval(60))
        // A missing frontmost application is not evidence that the user returned.
        XCTAssertFalse(session.observeAvailability(app: nil, now: start.addingTimeInterval(600)))
        session.recordSnapshot(roots: tree, app: app, window: nil, now: start.addingTimeInterval(7200))
        XCTAssertFalse(session.isAway)
        XCTAssertEqual(session.totalEventsWritten, count + 1)
        let away = AwayPeriods.load(root: root)
        XCTAssertNil(away.startedAt)
        XCTAssertEqual(away.periods.count, 1)
        XCTAssertEqual(away.periods[0].start, start.addingTimeInterval(60))
        XCTAssertEqual(away.periods[0].end, start.addingTimeInterval(7200))
        try session.stop(now: start.addingTimeInterval(7201))
        let snapshot = await TraySnapshotLoader().load(root: root)
        XCTAssertEqual(snapshot.groups.flatMap(\.items).map(\.title), ["离开电脑"])
        let dirs = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("segments"), includingPropertiesForKeys: nil)
        let events = try dirs.flatMap { try EventArchive.readEvents(at: EventArchive.eventsURL(in: $0)) }
        XCTAssertFalse(events.contains { AwayPeriods.isLoginWindow($0.app) })
        XCTAssertEqual(events.filter { $0.kind == .windowChanged }.map { $0.ax?.mode }, [.fullTree, .fullTree])
    }

    func testAwayStateSurvivesRestartAndManualPauseDoesNotSample() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let login = EventStreamApp(bundleIdentifier: "com.apple.loginwindow")
        let app = EventStreamApp(bundleIdentifier: "example.editor")
        let session = CollectionSession(configuration: .init(rootDirectory: root))
        try session.start(now: start)
        XCTAssertFalse(session.observeAvailability(app: login, now: start))
        try session.stop(now: start.addingTimeInterval(600))
        let restarted = CollectionSession(configuration: .init(rootDirectory: root))
        try restarted.start(now: start.addingTimeInterval(1200))
        XCTAssertTrue(restarted.isAway)
        restarted.isPaused = true
        XCTAssertFalse(restarted.observeAvailability(app: app, now: start.addingTimeInterval(1300)))
        XCTAssertTrue(restarted.isAway)
        restarted.isPaused = false
        XCTAssertTrue(restarted.observeAvailability(app: app, now: start.addingTimeInterval(1400)))
        XCTAssertEqual(AwayPeriods.load(root: root).periods.count, 1)
        try restarted.stop(now: start.addingTimeInterval(1401))
    }

    func testTimelineHidesLegacyLoginOnlySummariesButKeepsMixedActivity() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        try ActivityNarrative(items: [
            .init(id: "login", timestamp: start, title: "Login", summary: "", apps: ["com.apple.loginwindow"], sourceMemories: []),
            .init(id: "mixed", timestamp: start, title: "Editor", summary: "", apps: ["com.apple.loginwindow", "example.editor"], sourceMemories: [])
        ]).save(root: root)
        let loader = TraySnapshotLoader()
        let first = await loader.load(root: root)
        XCTAssertEqual(first.groups.flatMap(\.items).map(\.id), ["mixed"])
        var away = AwayPeriods()
        away.periods = [.init(start: start.addingTimeInterval(60), end: start.addingTimeInterval(7200))]
        away.periods.append(.init(start: start, end: start.addingTimeInterval(8)))
        try away.save(root: root)
        let second = await loader.load(root: root)
        XCTAssertEqual(second.groups.flatMap(\.items).map(\.title), ["离开电脑", "Editor"])
        XCTAssertGreaterThan(second.contentVersion, first.contentVersion)
    }

    func testRequestFiltersRespectLocalMidnightMondayAndCombinedSourceTask() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let parse = ISO8601DateFormatter()
        let now = parse.date(from: "2026-10-16T04:00:00Z")!
        func request(_ id: String, _ timestamp: String, _ task: String = "10min", comparison: Bool = false) -> ModelRequest {
            ModelRequest(id: id, startedAt: parse.date(from: timestamp)!, model: "fixture",
                endpoint: "http://localhost", task: task, sources: [], status: "success", system: "", input: "",
                comparisonOf: comparison ? "primary" : nil)
        }
        let records = [
            request("today", "2026-10-15T16:00:00Z"),
            request("compare", "2026-10-16T03:00:00Z", "narrative", comparison: true),
            request("yesterday", "2026-10-15T15:59:59Z"),
            request("monday", "2026-10-11T16:00:00Z"),
            request("sunday", "2026-10-11T15:59:59Z"),
            request("lastMonth", "2026-09-30T15:59:59Z"),
            request("tomorrow", "2026-10-16T16:00:00Z")
        ]
        var filter = ModelRequestFilter()
        func ids() -> [String] { filter.apply(records, now: now, calendar: calendar).map(\.id) }
        XCTAssertEqual(ids(), ["today", "compare"])
        filter.period = .yesterday
        XCTAssertEqual(ids(), ["yesterday"])
        filter.period = .week
        XCTAssertEqual(ids(), ["today", "compare", "yesterday", "monday", "tomorrow"])
        filter.period = .month
        XCTAssertFalse(ids().contains("lastMonth"))
        filter.source = .comparison; filter.task = "narrative"
        XCTAssertEqual(ids(), ["compare"])
        filter.source = .primary
        XCTAssertTrue(ids().isEmpty)
        filter.task = "10min"; filter.period = .today
        XCTAssertEqual(ids(), ["today"])
    }

    func testCompressedSegmentCanBeSummarizedAndCountedWithoutOriginal() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let writer = try SegmentWriter(rootDirectoryURL: root, start: start)
        let event = EventStreamRecord(id: 1, timestamp: start, kind: .windowChanged,
            app: .init(name: "Editor", bundleIdentifier: "example.editor"),
            ax: .init(mode: .fullTree, text: "0 窗口 Synthetic\n\t1 文本 Saved"))
        try writer.append(event)
        try writer.close(endedAt: start.addingTimeInterval(1))
        let original = try Data(contentsOf: writer.eventsURL)
        try EventArchive.archive(directory: writer.directoryURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: writer.eventsURL.path))
        XCTAssertEqual(try EventArchive.readEvents(at: writer.eventsURL).map(\.id), [1])
        let restored = try EventArchive.withReader(at: EventArchive.eventsURL(in: writer.directoryURL)) { $0.readDataToEndOfFile() }
        XCTAssertEqual(restored, original)
        let result = try MemoryGenerator(rootDirectory: root,
            memoriesDirectory: root.appendingPathComponent("memories")).generate(segmentID: writer.segmentID)
        XCTAssertTrue(try String(contentsOf: result.memoryURL, encoding: .utf8).contains("Saved"))
        XCTAssertEqual(CollectorStatus.read(root: root).data.eventCount, 1)
        let loader = TraySnapshotLoader()
        let first = await loader.load(root: root)
        let next = await loader.load(root: root)
        XCTAssertEqual(first.status.data.eventCount, 1)
        XCTAssertEqual(next.eventBytesRead, 0)
        XCTAssertEqual(next.memoriesParsed, 0)
    }

    func testRecoveryDoesNotRewriteRawEventsAndExcludesActiveSegment() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let old = try SegmentWriter(rootDirectoryURL: root, start: start)
        try old.append(.init(id: 1, timestamp: start, kind: .sessionStarted))
        // 模拟中断文件的半行尾部，不覆盖已有完整记录。
        let file = try FileHandle(forWritingTo: old.eventsURL)
        try file.seekToEnd(); try file.write(contentsOf: Data("{partial".utf8)); try file.close()
        let original = try Data(contentsOf: old.eventsURL)
        let active = try SegmentWriter(rootDirectoryURL: root, start: start.addingTimeInterval(600))
        try EventArchive.recoverUnsealed(root: root, excluding: active.segmentID)
        XCTAssertEqual(try Data(contentsOf: old.eventsURL), original)
        let meta = try EventStreamJSON.makeDecoder().decode(EventStreamMetadata.self,
            from: Data(contentsOf: old.metadataURL))
        XCTAssertEqual(meta.eventCount, 1)
        XCTAssertEqual(meta.endReason, "service_terminated")
        XCTAssertFalse(FileManager.default.fileExists(atPath: active.metadataURL.path))
    }

    func testCorruptArchiveFailsInsteadOfProducingEmptySummary() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("events.jsonl.gz")
        try Data("not gzip".utf8).write(to: file)
        XCTAssertThrowsError(try EventArchive.readEvents(at: file))
    }

    func testArchiveIndexesFirstEventLargerThanReadChunk() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let writer = try SegmentWriter(rootDirectoryURL: root, start: start)
        try writer.append(.init(id: 1, timestamp: start, kind: .windowChanged,
            ax: .init(mode: .fullTree, text: String(repeating: "合成界面", count: 30000))))
        try writer.close(endedAt: start.addingTimeInterval(1))
        var old = try EventStreamJSON.makeDecoder().decode(EventStreamMetadata.self,
            from: Data(contentsOf: writer.metadataURL))
        old.firstEventAt = nil
        try EventStreamJSON.makeEncoder().encode(old).write(to: writer.metadataURL)
        try EventArchive.archive(directory: writer.directoryURL)
        XCTAssertEqual(try EventArchive.firstEvent(at: EventArchive.eventsURL(in: writer.directoryURL))?.timestamp, start)
        let indexed = try EventStreamJSON.makeDecoder().decode(EventStreamMetadata.self,
            from: Data(contentsOf: writer.metadataURL))
        XCTAssertEqual(indexed.firstEventAt, start)
    }

    func testDeltaOmitsUnchangedLargeValueButKeepsChanges() throws {
        let large = String(repeating: "unchanged", count: 1000)
        let before = [UIElementRender(id: 0, text: "窗口", detailText: large,
            children: [.init(id: 1, text: "文本 old"), .init(id: 2, text: "文本 stable")])]
        let after = [UIElementRender(id: 0, text: "窗口", detailText: large,
            children: [.init(id: 1, text: "文本 new"), .init(id: 2, text: "文本 stable")])]
        let delta = try XCTUnwrap(UIElementRenderDifference.lines(from: before, to: after,
            includesUnchangedContext: false)).joined(separator: "\n")
        XCTAssertTrue(delta.contains("文本 new"))
        XCTAssertTrue(delta.contains("Removed element IDs:"))
        XCTAssertFalse(delta.contains(large))
        XCTAssertFalse(delta.contains("stable"))
    }

    func testSnapshotBaselinesResetOnAppWindowAndSegmentChanges() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let session = CollectionSession(configuration: .init(rootDirectory: root))
        try session.start(now: start)
        let app = EventStreamApp(name: "Fixture", processIdentifier: 42, bundleIdentifier: "example.fixture")
        let roots = [UIElementRender(id: 0, text: "窗口 Synthetic")]
        session.recordSnapshot(roots: roots, app: app, window: .init(windowID: 1), now: start.addingTimeInterval(1))
        session.recordSnapshot(roots: [.init(id: 0, text: "窗口 Changed")], app: app,
            window: .init(windowID: 1), now: start.addingTimeInterval(2))
        session.recordSnapshot(roots: roots, app: app, window: .init(windowID: 2), now: start.addingTimeInterval(3))
        session.isPaused = true
        session.recordSnapshot(roots: roots, app: app, window: .init(windowID: 2), now: start.addingTimeInterval(4))
        session.isPaused = false
        session.recordSnapshot(roots: roots, app: app, window: .init(windowID: 2), now: start.addingTimeInterval(5))
        session.recordSnapshot(roots: roots, app: app, window: .init(windowID: 2), now: start.addingTimeInterval(601))
        try session.stop(now: start.addingTimeInterval(602))
        let generator = MemoryGenerator(rootDirectory: root, memoriesDirectory: root.appendingPathComponent("memories"))
        let events = try generator.orderedSegments().flatMap {
            try EventArchive.readEvents(at: root.appendingPathComponent("segments/\($0.segmentID)/events.jsonl"))
        }
        let snapshots = events.filter { $0.kind == .windowChanged }
        XCTAssertEqual(snapshots.compactMap { $0.ax?.mode }, [.fullTree, .diffFromPrevious, .fullTree, .fullTree, .fullTree])
        XCTAssertEqual(snapshots.map { $0.window?.windowID }, [1, 1, 2, 2, 2])
    }

    func testEvidenceKeepsResultAndAppContextWithoutOldMultilineValues() {
        let events = [
            EventStreamRecord(id: 1, timestamp: start, kind: .windowChanged,
                app: .init(name: "Editor"), ax: .init(mode: .diffFromPrevious,
                    text: "~0 文本 OLD\nold continuation\n+1 文本 文件已保存\nnew continuation")),
            EventStreamRecord(id: 2, timestamp: start.addingTimeInterval(2), kind: .windowChanged,
                app: .init(name: "Terminal"), ax: .init(mode: .fullTree, text: "0 文本 tests passed"))]
        let text = ActivityEvidence.material(events: events, segmentID: "fixture")
        XCTAssertTrue(text.contains("文件已保存")); XCTAssertTrue(text.contains("tests passed"))
        XCTAssertTrue(text.contains("Editor")); XCTAssertTrue(text.contains("Terminal"))
        XCTAssertTrue(text.contains("fixture#1")); XCTAssertTrue(text.contains("fixture#2"))
        XCTAssertFalse(text.contains("OLD")); XCTAssertFalse(text.contains("old continuation"))
    }

    func testMissingUsageRemainsUnknownAndReasoningIsNotCountedTwice() throws {
        let missing = try DeepSeekClient.parse(Data(#"{"choices":[{"message":{"content":"ok"}}],"usage":{}}"#.utf8)).get()
        XCTAssertNil(missing.usage)
        let json = #"{"choices":[{"message":{"content":"ok"}}],"usage":{"prompt_tokens":1000,"completion_tokens":200,"prompt_cache_hit_tokens":800,"completion_tokens_details":{"reasoning_tokens":50}}}"#
        let value = try XCTUnwrap(DeepSeekClient.parse(Data(json.utf8)).get().usage)
        let pricing = ModelPricing(inputPerMillion: 2, cachedInputPerMillion: 0.04, outputPerMillion: 8)
        XCTAssertEqual(pricing.estimate(value), 0.002032, accuracy: 0.0000001)
        XCTAssertEqual(value.totalTokens, 1200)
        XCTAssertEqual(value.reasoningTokens, 50)
    }

    func testNarrativeBackfillDoesNotUseLaterItemsAsPriorContext() {
        let source = MemoryIndex.Entry(fileURL: URL(fileURLWithPath: "/tmp/synthetic.md"),
            startedAt: start, sourceSegmentID: "fixture", granularity: "10min", title: "Source",
            summary: "Synthetic", applications: [], body: "", sections: [])
        let future = ActivityNarrative.Item(id: "future", timestamp: start.addingTimeInterval(600),
            title: "FUTURE_CONTEXT", summary: "later", apps: [], sourceMemories: [])
        let material = NarrativeGenerator.userPrompt(day: "fixture", sources: [source], priorItems: [future])
        XCTAssertFalse(material.contains("FUTURE_CONTEXT"))
        XCTAssertTrue(material.contains("Source"))
    }

    func testRequestLoaderReloadsCompletionAndDoesNotRetainPrompt() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        var request = ModelRequest(id: "fixture", startedAt: start, model: "fixture",
            endpoint: "http://127.0.0.1", task: "10min", sources: ["segment"], status: "running",
            system: "system", input: String(repeating: "input", count: 1000))
        try request.save(root: root)
        let loader = ModelRequestLoader()
        let pending = await loader.load(root: root)
        XCTAssertEqual(pending.first?.status, "running"); XCTAssertEqual(pending.first?.input, "")
        request.finishedAt = start.addingTimeInterval(3); request.status = "success"; request.output = "result"
        try request.save(root: root)
        let done = await loader.load(root: root)
        XCTAssertEqual(done.first?.status, "success"); XCTAssertNil(done.first?.output)
        let detail = try ModelRequest.load(url: root.appendingPathComponent("requests/fixture.json"))
        XCTAssertEqual(detail.output, "result"); XCTAssertFalse(detail.input.isEmpty)
    }

    func testInterruptedRequestDoesNotRemainLabelledRunning() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        var request = ModelRequest(id: "fixture", startedAt: start, model: "fixture",
            endpoint: "http://127.0.0.1", task: "10min", sources: [], status: "running", system: "", input: "")
        request.worker = CollectorProcessIdentity.read(pid: process.processIdentifier)
        XCTAssertEqual(request.statusLabel, "请求中")
        process.terminate(); process.waitUntilExit()
        XCTAssertEqual(request.statusLabel, "已中断")
        XCTAssertNil(request.usage)
        XCTAssertNil(request.estimatedCost)
    }

    func testUnsummarizedGraceAndCapacityEvictsSummarizedFirst() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let old = try SegmentWriter(rootDirectoryURL: root, start: start)
        try old.append(.init(id: 1, timestamp: start, kind: .sessionStarted)); try old.close(endedAt: start)
        let newer = try SegmentWriter(rootDirectoryURL: root, start: start.addingTimeInterval(600))
        try newer.append(.init(id: 1, timestamp: start.addingTimeInterval(600), kind: .sessionStarted))
        try newer.close(endedAt: start.addingTimeInterval(600))
        let active = try SegmentWriter(rootDirectoryURL: root, start: start.addingTimeInterval(3 * 86400))
        let memories = root.appendingPathComponent("memories")
        try FileManager.default.createDirectory(at: memories, withIntermediateDirectories: true)
        try "---\ngeneration: model\n---\nsummary".write(to: memories.appendingPathComponent(
            MemoryWriter.fileName(segmentID: newer.segmentID)), atomically: true, encoding: .utf8)
        let age = SegmentPruner.prune(rootDirectory: root, retention: .init(maxTotalBytes: 0),
            now: start.addingTimeInterval(3 * 86400), activeSegmentID: active.segmentID)
        XCTAssertEqual(age.removedSegments, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.directoryURL.path))
        let pressure = SegmentPruner.prune(rootDirectory: root, retention: .init(maxTotalBytes: 1),
            now: start.addingTimeInterval(3 * 86400), activeSegmentID: active.segmentID)
        XCTAssertEqual(pressure.removedWithoutSummary, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: active.directoryURL.path))
    }

    func testRemoteConfigNeedsNoCloudKeyAndRejectsInvalidPricing() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        var config = ModelSettings(baseURL: URL(string: "http://127.0.0.1:11434/v1")!,
            model: "fixture", requiresAPIKey: false,
            pricing: .init(inputPerMillion: 0, cachedInputPerMillion: 0, outputPerMillion: 0))
        let file = root.appendingPathComponent("model.json")
        try JSONEncoder().encode(config).write(to: file)
        XCTAssertNoThrow(try DeepSeekClient.fromEnvironment([:], rootDirectory: root))
        config.pricing?.outputPerMillion = -1
        try JSONEncoder().encode(config).write(to: file)
        XCTAssertThrowsError(try DeepSeekClient.fromEnvironment([:], rootDirectory: root))
    }
}
