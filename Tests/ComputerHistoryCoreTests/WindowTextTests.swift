import AppKit
import XCTest
@testable import ComputerHistoryCore

final class WindowTextTests: XCTestCase {
    func testConfigurationIsOptInAndRejectsWrongTypes() throws {
        XCTAssertTrue(try CollectorConfig.decode(from: Data("{}".utf8)).windowTextApplications.isEmpty)
        let config = try CollectorConfig.decode(from: Data(#"{"windowTextApplications":["example.music"]}"#.utf8))
        XCTAssertEqual(try CollectorConfig.decode(from: config.jsonData()).windowTextApplications, ["example.music"])
        for raw in [#"{"windowTextApplications":true}"#, #"{"windowTextApplications":[""]}"#] {
            XCTAssertThrowsError(try CollectorConfig.decode(from: Data(raw.utf8)))
        }
    }

    func testWindowTitleAloneDoesNotCountAsReadableBody() {
        XCTAssertFalse(AXTreeReader.hasReadableContent([.init(id: 1, text: "标准窗口", detailText: "Title: Music")]))
        XCTAssertFalse(AXTreeReader.hasReadableContent([.init(id: 1, text: "菜单项", detailText: "ID: _recentItemRequested:")]))
        XCTAssertTrue(AXTreeReader.hasReadableContent([.init(id: 1, text: "文本", detailText: "Value: Synthetic song")]))
    }

    func testBrowserChromeDoesNotPreventOCRFallback() {
        let toolbar = UIElementRender(id: 2, text: "工具栏", children: [
            .init(id: 3, text: "按钮", detailText: "Title: Reload"),
            .init(id: 4, text: "文本栏", detailText: "Value: https://example.test")])
        let shell = UIElementRender(id: 1, text: "窗口", children: [toolbar])
        XCTAssertFalse(AXTreeReader.hasReadableContent([shell]), "Browser toolbar and address bar are not page body")
        let document = UIElementRender(id: 5, text: "网页区域", children: [
            .init(id: 6, text: "文本", detailText: "Value: Synthetic document body")])
        XCTAssertTrue(AXTreeReader.hasReadableContent([shell, document]))
    }

    func testActivationReconnectsAfterRelaunchAndRetriesWithoutPerFrameRequests() {
        var activation = AccessibilityActivation()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var requests = 0
        for tick in 0..<30 {
            activation.prepare(pid: 42, launchedAt: start, now: start.addingTimeInterval(Double(tick))) { requests += 1; return true }
        }
        XCTAssertEqual(requests, 1)
        activation.prepare(pid: 42, launchedAt: start.addingTimeInterval(1), now: start.addingTimeInterval(29)) { requests += 1; return true }
        XCTAssertEqual(requests, 2, "PID reuse must not retain another process's connection")
        activation.prepare(pid: 43, launchedAt: start, now: start.addingTimeInterval(29)) { requests += 1; return true }
        XCTAssertEqual(requests, 3, "A relaunched application gets its own connection")
        activation.prepare(pid: 43, launchedAt: start, now: start.addingTimeInterval(60)) { requests += 1; return true }
        XCTAssertEqual(requests, 4, "Retry connection if the provider resets while the process lives")
    }

    func testActivationRetriesWhileApplicationIsStillLaunching() {
        var activation = AccessibilityActivation()
        let start = Date()
        var requests = 0
        activation.prepare(pid: 42, launchedAt: start, now: start) { requests += 1; return false }
        activation.prepare(pid: 42, launchedAt: start, now: start.addingTimeInterval(1)) { requests += 1; return true }
        XCTAssertEqual(requests, 2)
    }

    func testDisabledOCRRetainsApplicationAndDoesNotReadIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var draft = CollectorSettingsDraft(.init(windowTextApplications: ["example.editor"]))
        draft.windowTextDisabledApplications = ["example.editor"]
        let config = try CollectorConfig.decode(from: draft.value().jsonData())
        XCTAssertEqual(config.windowTextApplications, ["example.editor"])
        XCTAssertEqual(config.windowTextDisabledApplications, ["example.editor"])
        let session = CollectionSession(configuration: .init(rootDirectory: root, config: config))
        try session.start()
        session.updateWindowTextContext(roots: [], app: .init(bundleIdentifier: "example.editor"), window: nil)
        XCTAssertNil(session.windowTextContext)
        try session.stop()
    }

    func testPauseWindowSwitchAndStopRejectOutstandingOCR() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = CollectionSession(configuration: .init(rootDirectory: root, windowTextApplications: ["example.music"]))
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let app = EventStreamApp(name: "Music", processIdentifier: 42, bundleIdentifier: "example.music")
        let window = EventStreamWindow(windowID: 7)
        try session.start(now: start)
        session.recordSnapshot(roots: [], app: app, window: window, now: start)
        session.updateWindowTextContext(roots: [], app: app, window: window)
        let first = try XCTUnwrap(session.windowTextContext)
        session.isPaused = true
        session.recordWindowText(.init(text: "must not persist", windowID: 7), context: first, now: start)
        session.isPaused = false
        session.updateWindowTextContext(roots: [], app: app, window: window)
        let resumed = try XCTUnwrap(session.windowTextContext)
        session.recordWindowText(.init(text: "stale after resume", windowID: 7), context: first, now: start)
        session.recordWindowText(.init(text: "wrong window", windowID: 8), context: resumed, now: start)
        let result = WindowTextReader.Result(text: "Synthetic playlist\nExport complete", windowID: 7)
        session.recordWindowText(result, context: resumed, now: start)
        session.recordWindowText(result, context: resumed, now: start)
        session.recordSnapshot(roots: [], app: .init(name: "Other", processIdentifier: 43, bundleIdentifier: "example.other"), window: nil, now: start)
        session.recordWindowText(.init(text: "stale after switch", windowID: 7), context: resumed, now: start)
        try session.stop(now: start)
        session.recordWindowText(.init(text: "after stop", windowID: 7), context: resumed, now: start)
        let segments = root.appendingPathComponent("segments")
        let records = try FileManager.default.contentsOfDirectory(at: segments, includingPropertiesForKeys: nil)
            .flatMap { try EventArchive.readEvents(at: $0.appendingPathComponent("events.jsonl")) }
        let ocr = records.filter { $0.ax?.source == "window_ocr" }
        XCTAssertEqual(ocr.count, 1)
        XCTAssertEqual(ocr.first?.window?.windowID, 7)
        XCTAssertTrue(ocr.first?.ax?.text.contains("Synthetic playlist") == true)
        XCTAssertFalse(records.contains { $0.ax?.text.contains("must not persist") == true })
    }

    func testPolicyAndReadableContentPreventFallback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = EventStreamApp(bundleIdentifier: "example.music")
        let session = CollectionSession(configuration: .init(rootDirectory: root,
            policy: .init(blocklist: [.application("example.music")]), windowTextApplications: ["example.music"]))
        try session.start()
        session.updateWindowTextContext(roots: [], app: app, window: nil)
        XCTAssertNil(session.windowTextContext)
        try session.stop()
        let allowed = CollectionSession(configuration: .init(rootDirectory: root, windowTextApplications: ["example.music"]))
        try allowed.start()
        allowed.updateWindowTextContext(roots: [], app: app, window: nil)
        XCTAssertNotNil(allowed.windowTextContext)
        allowed.updateWindowTextContext(roots: [.init(id: 1, text: "文本", detailText: "Value: Visible body")], app: app, window: nil)
        XCTAssertNil(allowed.windowTextContext)
        allowed.updateWindowTextContext(roots: [], app: .init(bundleIdentifier: "example.other"), window: nil)
        XCTAssertNil(allowed.windowTextContext)
        try allowed.stop()
    }

    func testDisallowedReadDoesNotAccessTheScreen() async throws {
        let result = try await WindowTextReader.read(pid: 1, windowID: nil, isAllowed: { false })
        XCTAssertNil(result)
    }

    @MainActor func testLocalOCRReadsSyntheticImageWithoutScreenCapture() throws {
        let image = NSImage(size: NSSize(width: 800, height: 160))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 800, height: 160).fill()
        ("SYNTHETIC DOCUMENT" as NSString).draw(at: NSPoint(x: 30, y: 70), withAttributes: [
            .font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.black])
        image.unlockFocus()
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertTrue(try WindowTextReader.recognize(cg).contains("SYNTHETIC DOCUMENT"))
    }
}
