import XCTest
@testable import ComputerHistoryCore

private final class ActivityProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        guard request.httpMethod == "GET" else { fatalError("ActivityWatch must be read-only") }
        let body: String
        switch url.path {
        case "/api/0/info": body = #"{"hostname":"synthetic-host"}"#
        case "/api/0/buckets/", "/api/0/buckets": body = #"{"local-window":{"type":"currentwindow","hostname":"synthetic-host"},"local-afk":{"type":"afkstatus","hostname":"synthetic-host"},"foreign-window":{"type":"currentwindow","hostname":"other-host"}}"#
        case "/api/0/buckets/local-window/events":
            precondition(url.query == "limit=1")
            body = #"[{"id":1,"timestamp":"2026-10-20T00:00:00.000Z","duration":60,"data":{"app":"Synthetic Browser","title":"Synthetic document","url":"https://example.test"}}]"#
        case "/api/0/buckets/local-afk/events":
            body = #"[{"id":2,"timestamp":"2026-10-20T00:00:00Z","duration":60,"data":{"status":"afk"}}]"#
        default: fatalError("Unexpected or foreign bucket: \(url.path)")
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ActivityWatchTests: XCTestCase {
    func testAllowlistRejectsMissingApplicationAndBrowserAddress() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date().addingTimeInterval(60)
        let session = CollectionSession(configuration: .init(rootDirectory: root,
            policy: .init(defaultApplicationBehavior: .doNotObserve, defaultURLBehavior: .doNotObserve,
                allowlist: [.application("com.apple.Safari"), .domain("allowed.test")]), activityWatchEnabled: true))
        try session.start(now: now)
        var snapshot = ActivityWatchSnapshot(application: "Synthetic Browser", title: "Synthetic",
            evidence: .init(startedAt: now, endedAt: now.addingTimeInterval(5),
                windowBucket: "synthetic", windowEventID: 1))
        let browser = EventStreamApp(name: "Synthetic Browser", bundleIdentifier: "com.apple.Safari")
        session.recordActivityWatch(snapshot, current: .init(name: "Synthetic Browser"), now: now.addingTimeInterval(10))
        session.recordActivityWatch(snapshot, current: browser, now: now.addingTimeInterval(10))
        snapshot.url = "https://allowed.test"
        session.recordActivityWatch(snapshot, current: browser, now: now.addingTimeInterval(10))
        let id = try XCTUnwrap(session.currentSegmentID)
        try session.stop(now: now.addingTimeInterval(11))
        let imported = try EventArchive.readEvents(at: root.appendingPathComponent("segments/\(id)/events.jsonl"))
            .filter { $0.activityWatch != nil }
        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(imported.first?.window?.url, "https://allowed.test")
    }

    func testReadOnlyBoundedLocalBucketsAndStaleData() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ActivityProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = ActivityWatchClient(session: session)
        let now = ISO8601DateFormatter().date(from: "2026-10-20T00:01:05Z")!
        let fetched = try await client.snapshot(now: now)
        let snapshot = try XCTUnwrap(fetched)
        XCTAssertEqual(snapshot.application, "Synthetic Browser")
        XCTAssertEqual(snapshot.evidence.status, "afk")
        XCTAssertEqual(snapshot.evidence.windowBucket, "local-window")
        XCTAssertEqual(snapshot.evidence.afkEventID, 2)
        let stale = try await client.snapshot(now: now.addingTimeInterval(60))
        XCTAssertNil(stale)
    }

    func testDisabledByDefaultAndInvalidConfigRejected() throws {
        XCTAssertFalse(try CollectorConfig.decode(from: Data("{}".utf8)).activityWatchEnabled)
        for value in ["1", "null", "\"true\""] {
            XCTAssertThrowsError(try CollectorConfig.decode(from: Data("{\"activityWatchEnabled\":\(value)}".utf8)))
        }
        var draft = CollectorSettingsDraft()
        draft.activityWatchEnabled = true
        XCTAssertTrue(try CollectorConfig.decode(from: draft.value().jsonData()).activityWatchEnabled)
    }

    @MainActor func testSamplerDisableCancelsOutstandingRequest() async throws {
        let sampler = ActivityWatchSampler()
        var accepted = 0
        let now = Date()
        let snapshot = ActivityWatchSnapshot(application: "Synthetic", evidence: .init(startedAt: now,
            endedAt: now.addingTimeInterval(1), windowBucket: "synthetic", windowEventID: 1))
        sampler.update(enabled: true, read: {
            try await Task.sleep(for: .milliseconds(100))
            return snapshot
        }) { _ in accepted += 1 }
        await Task.yield()
        sampler.update(enabled: false, read: { XCTFail("Disabled integration must not request data"); return nil }) { _ in accepted += 1 }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(accepted, 0)
    }

    func testPausePolicyDeduplicationAndSummarySource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = CollectionSession(configuration: .init(rootDirectory: root,
            policy: .init(blocklist: [.domain("blocked.test")]), activityWatchEnabled: true))
        let start = Date()
        try session.start(now: start)
        let app = EventStreamApp(name: "Synthetic Browser", bundleIdentifier: "example.browser")
        var snapshot = ActivityWatchSnapshot(application: "Synthetic Browser", title: "Synthetic document", url: "https://example.test",
            evidence: .init(startedAt: start.addingTimeInterval(-3600), endedAt: start.addingTimeInterval(10), status: "not-afk",
                            windowBucket: "synthetic-window", windowEventID: 1))
        let now = start.addingTimeInterval(15)
        session.recordActivityWatch(snapshot, current: app, now: now)
        session.recordActivityWatch(snapshot, current: app, now: now)
        snapshot.url = "https://blocked.test"
        snapshot.evidence.endedAt = now
        session.recordActivityWatch(snapshot, current: app, now: now)
        snapshot.url = "https://example.test"
        session.isPaused = true
        session.recordActivityWatch(snapshot, current: app, now: now)
        session.isPaused = false
        session.recordActivityWatch(snapshot, current: .init(name: "Other"), now: now)
        try session.stop(now: now)
        let segments = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("segments"), includingPropertiesForKeys: nil)
        let events = try segments.flatMap { try EventArchive.readEvents(at: $0.appendingPathComponent("events.jsonl")) }
        let imported = events.filter { $0.activityWatch != nil }
        XCTAssertEqual(imported.count, 1)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(imported.first?.activityWatch?.startedAt), start.addingTimeInterval(-1))
        XCTAssertNil(imported.first?.ax)
        let evidence = ActivityEvidence.material(events: events, segmentID: "synthetic")
        XCTAssertTrue(evidence.contains("ActivityWatch：活动"))
        XCTAssertTrue(evidence.contains("窗口与网址元数据"))
        let roundTrip = try EventStreamJSON.makeDecoder().decode(EventStreamRecord.self, from: EventStreamJSON.makeEncoder().encode(imported[0]))
        XCTAssertEqual(roundTrip.activityWatch, imported[0].activityWatch)
    }
}
