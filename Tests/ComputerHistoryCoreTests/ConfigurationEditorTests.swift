import XCTest
@testable import ComputerHistoryCore

final class ConfigurationEditorTests: XCTestCase {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testModelFormRoundTripsFallbackPricingAndBudgets() throws {
        let root = try temporaryRoot()
        let settings = ModelSettings(baseURL: URL(string: "http://127.0.0.1:1234/v1")!, model: "synthetic-model",
            requiresAPIKey: false, reasoningEffort: "custom", pricing: .init(currency: "USD", inputPerMillion: 1.5,
                cachedInputPerMillion: 0.2, outputPerMillion: 3), dailyBudget: 5, monthlyBudget: 30,
            fallback: .init(baseURL: URL(string: "http://127.0.0.1:1235/v1")!, model: "synthetic-fallback",
                reasoningEffort: "none", pricing: .init(inputPerMillion: 0, cachedInputPerMillion: 0, outputPerMillion: 0)))
        try settings.save(root: root)
        var draft = ModelSettingsDraft(try ModelSettings.load(root: root), environment: [:])
        draft.model = "edited-model"
        try draft.value().save(root: root)
        let saved = try XCTUnwrap(ModelSettings.load(root: root))
        XCTAssertEqual(saved.model, "edited-model")
        XCTAssertEqual(saved.baseURL, settings.baseURL)
        XCTAssertFalse(saved.requiresAPIKey)
        XCTAssertEqual(saved.reasoningEffort, "custom")
        XCTAssertEqual(saved.pricing, settings.pricing)
        XCTAssertEqual(saved.dailyBudget, 5)
        XCTAssertEqual(saved.monthlyBudget, 30)
        XCTAssertEqual(saved.fallback?.model, "synthetic-fallback")
        XCTAssertEqual(saved.fallback?.pricing, settings.fallback?.pricing)
        draft.hasFallback = false
        draft.hasPricing = false
        draft.dailyBudget = ""
        draft.monthlyBudget = ""
        try draft.value().save(root: root)
        XCTAssertNil(try ModelSettings.load(root: root)?.fallback)
        XCTAssertNil(try ModelSettings.load(root: root)?.pricing)
    }

    func testOldComparisonSettingsDoNotEnableFallback() throws {
        let root = try temporaryRoot()
        let text = #"{"baseURL":"http://127.0.0.1:1234/v1","model":"synthetic","requiresAPIKey":false,"reasoningEffort":"none","comparison":{"model":"old-shadow"}}"#
        try Data(text.utf8).write(to: root.appendingPathComponent("model.json"))
        let loaded = try XCTUnwrap(ModelSettings.load(root: root))
        XCTAssertNil(loaded.fallback)
        try loaded.save(root: root)
        XCTAssertFalse(try String(contentsOf: root.appendingPathComponent("model.json"), encoding: .utf8).contains("comparison"))
    }

    func testFormRejectsInvalidValuesBeforeWriting() throws {
        var model = ModelSettingsDraft(environment: [:])
        model.baseURL = "not a service"
        XCTAssertThrowsError(try model.value())
        model.baseURL = "http://127.0.0.1:1234/v1"
        model.dailyBudget = "-1"
        XCTAssertThrowsError(try model.value())
        model.dailyBudget = "5"
        XCTAssertThrowsError(try model.value(), "Budget requires prices")
        model.hasPricing = true
        XCTAssertNoThrow(try model.value())
        model.pricing.output = "nan"
        XCTAssertThrowsError(try model.value())
        var collector = CollectorSettingsDraft()
        collector.blockedDomains = "https://example.com/path"
        XCTAssertThrowsError(try collector.value())
        collector.blockedDomains = "example.com"
        collector.maxNodes = "0"
        XCTAssertThrowsError(try collector.value())
        collector.maxNodes = "4000"
        collector.maxAgeDays = "2.5"
        XCTAssertThrowsError(try collector.value())
    }

    func testCollectorFormPreservesPoliciesAndByteLimits() throws {
        let original = CollectorConfig(policy: .init(defaultApplicationBehavior: .doNotObserve,
            defaultURLBehavior: .doNotObserve,
            allowlist: [.application("example.allowed"), .domain("example.com")],
            blocklist: [.application("example.blocked"), .domain("private.example.com")],
            forcedBlockedDomains: ["forced.example.com"]), maxNodesPerSnapshot: 2500,
            retention: .init(maxTotalBytes: 123_456_789, maxAgeDays: 4, unsummarizedMaxAgeDays: 9),
            maxLogBytes: 5_000_000, windowTextApplications: ["example.music"])
        var draft = CollectorSettingsDraft(original)
        draft.maxAgeDays = "5"
        draft.blockedDomains += "\nother.example.com"
        let saved = try draft.value()
        XCTAssertEqual(saved.retention.maxTotalBytes, original.retention.maxTotalBytes)
        XCTAssertEqual(saved.maxLogBytes, original.maxLogBytes)
        XCTAssertEqual(saved.retention.maxAgeDays, 5)
        XCTAssertEqual(saved.retention.unsummarizedMaxAgeDays, 9)
        XCTAssertEqual(saved.maxNodesPerSnapshot, 2500)
        XCTAssertEqual(saved.windowTextApplications, ["example.music"])
        XCTAssertEqual(saved.policy.allowlist, original.policy.allowlist)
        XCTAssertEqual(saved.policy.forcedBlockedDomains, ["forced.example.com"])
        XCTAssertTrue(saved.policy.shouldSuppress(app: .init(bundleIdentifier: "example.blocked"), window: nil))
        XCTAssertFalse(saved.policy.shouldSuppress(app: .init(bundleIdentifier: "example.allowed"),
            window: .init(url: "https://www.example.com")))
    }

    func testConfigurationMonitorAppliesOnlyChangedValidFiles() throws {
        let root = try temporaryRoot()
        let file = CollectorConfig.fileURL(rootDirectory: root)
        try CollectorConfig().jsonData().write(to: file)
        var monitor = CollectorConfigurationMonitor(root: root)
        XCTAssertNil(try monitor.poll())
        try Data(#"{"policy":{"blocklist":[{"scope":"app","bundleID":"example.blocked"}]}}"#.utf8).write(to: file, options: .atomic)
        let changed = try XCTUnwrap(monitor.poll())
        XCTAssertTrue(changed.policy.shouldSuppress(app: .init(bundleIdentifier: "example.blocked"), window: nil))
        XCTAssertNil(try monitor.poll())
        try Data(#"{"policy":{"blocklist":false}}"#.utf8).write(to: file, options: .atomic)
        XCTAssertThrowsError(try monitor.poll())
        XCTAssertNil(try monitor.poll(), "Invalid bytes must not repeatedly log the same error")
        try changed.jsonData().write(to: file, options: .atomic)
        XCTAssertNotNil(try monitor.poll())
    }

    func testApplyingPolicyDiscardsBufferedInputAndOutstandingOCR() throws {
        let root = try temporaryRoot()
        let app = EventStreamApp(name: "Synthetic", processIdentifier: 42, bundleIdentifier: "example.editor")
        let session = CollectionSession(configuration: .init(rootDirectory: root, windowTextApplications: ["example.editor"]))
        let start = Date()
        try session.start(now: start)
        session.recordSnapshot(roots: [], app: app, window: nil, now: start)
        session.updateWindowTextContext(roots: [], app: app, window: nil)
        let old = try XCTUnwrap(session.windowTextContext)
        session.sampleTextInput(app: app, window: nil, readFocused: { (.init(value: "", caret: 0), nil) }, now: start)
        session.sampleTextInput(app: app, window: nil, readFocused: { (.init(value: "sensitive pending", caret: 17,
            hasInputActivity: true), nil) }, now: start.addingTimeInterval(0.1))
        session.applyConfiguration(.init(policy: .init(blocklist: [.application("example.editor")])))
        XCTAssertNil(session.windowTextContext)
        session.recordWindowText(.init(text: "stale OCR", windowID: 1), context: old)
        session.recordSnapshot(roots: [.init(id: 1, text: "secret body")], app: app, window: nil, now: start.addingTimeInterval(1))
        try session.stop(now: start.addingTimeInterval(2))
        let dir = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("segments"), includingPropertiesForKeys: nil)[0]
        let events = try EventArchive.readEvents(at: dir.appendingPathComponent("events.jsonl"))
        XCTAssertFalse(events.contains { $0.keyboard?.text?.contains("pending") == true })
        XCTAssertFalse(events.contains { $0.ax?.text.contains("secret body") == true || $0.ax?.source == "window_ocr" })
    }
}
