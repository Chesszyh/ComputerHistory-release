import AppKit
import XCTest
@testable import ComputerHistoryCore

private final class SecureInputFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var state = false
    private var counts: [String: Int] = [:]
    var focusedText = "Synthetic text"
    let app = EventStreamApp(name: "Synthetic", processIdentifier: 42, bundleIdentifier: "test.editor")
    let window = EventStreamWindow(title: "Synthetic window", windowID: 7)

    var active: Bool {
        get { lock.withLock { state } }
        set { lock.withLock { state = newValue } }
    }

    func read(_ name: String) { lock.withLock { counts[name, default: 0] += 1 } }
    func count(_ name: String) -> Int { lock.withLock { counts[name, default: 0] } }

    var readers: CollectionSession.ContentReaders {
        .init(currentApp: { self.app }, window: { _, _ in self.read("window"); return .init(details: self.window) },
              tree: { _, _, _ in self.read("tree"); return [.init(id: 1, text: "Synthetic tree")] },
              focusedText: { _, _, _ in
                  self.read("focus")
                  return (.init(value: self.focusedText, focusIdentity: 1, hasInputActivity: true), nil)
              },
              focusedTarget: { _, _, _ in self.read("keyboard target"); return nil },
              clickedTarget: { _, _, _, _ in self.read("click target"); return nil },
              idleSeconds: { 0 }, prepare: { _, _, _, _ in self.read("activate") })
    }
}

@MainActor
final class SecureInputTests: XCTestCase {
    private func events(in root: URL) throws -> [EventStreamRecord] {
        let segments = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("segments"), includingPropertiesForKeys: nil)
        return try segments.flatMap { try EventArchive.readEvents(at: $0.appendingPathComponent("events.jsonl")) }
    }

    func testSecureInputBlocksContentReadsAndLeavesManualPauseInEffect() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = SecureInputFixture()
        let session = CollectionSession(configuration: .init(rootDirectory: root,
            windowTextApplications: ["test.editor"]), readers: fixture.readers, secureInput: { fixture.active })
        try session.start()
        session.updateWindowTextContext(roots: [], app: fixture.app, window: fixture.window)
        let originalOCR = try XCTUnwrap(session.windowTextContext)
        var ocrReads = 0
        func attemptReads() {
            session.sampleFrontmost(force: true)
            session.sampleFrontmostAsync(force: true)
            session.sampleTextInput()
            session.recordClick(button: "left", clickCount: 1, modifiers: [], location: .zero)
            session.recordScroll(deltaX: 0, deltaY: 4, modifiers: [], location: .zero)
            session.recordShortcut(keyEquivalent: "x", modifiers: ["command"])
            session.recordSubmit()
            XCTAssertNil(session.debugTextObservation())
            if session.allowsWindowTextSampling(originalOCR) { ocrReads += 1 }
        }
        fixture.active = true
        attemptReads()
        XCTAssertNil(session.windowTextContext)
        XCTAssertFalse(session.frontmostSampleInFlight)
        session.isPaused = true
        fixture.active = false
        attemptReads()
        XCTAssertTrue(session.isPaused)
        for field in ["window", "tree", "focus", "keyboard target", "click target", "activate"] {
            XCTAssertEqual(fixture.count(field), 0, field)
        }
        XCTAssertEqual(ocrReads, 0)

        session.isPaused = false
        session.sampleFrontmost()
        session.sampleTextInput()
        XCTAssertNotNil(session.debugTextObservation())
        XCTAssertEqual(fixture.count("tree"), 1)
        XCTAssertEqual(fixture.count("focus"), 2)
        XCTAssertEqual(fixture.count("window"), 3)
        let resumedOCR = try XCTUnwrap(session.windowTextContext)
        XCTAssertNotEqual(resumedOCR, originalOCR)
        session.recordWindowText(.init(text: "stale OCR", windowID: 7), context: originalOCR)
        try session.stop()
        let records = try events(in: root)
        XCTAssertEqual(records.map(\.kind), [.sessionStarted, .windowChanged, .sessionEnded])
        XCTAssertEqual(records[1].ax?.mode, .fullTree)
    }

    func testWindowCommunicationFailureSkipsOtherReadsInTheSamePoll() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = SecureInputFixture()
        var readers = fixture.readers
        readers.window = { _, access in
            fixture.read("window")
            XCTAssertEqual(access.perform { .cannotComplete }, .cannotComplete)
            return nil
        }
        let session = CollectionSession(configuration: .init(rootDirectory: root,
            windowTextApplications: ["test.editor"]), readers: readers, secureInput: { fixture.active })
        try session.start()
        session.updateWindowTextContext(roots: [], app: fixture.app, window: fixture.window)
        XCTAssertNil(session.pollFrontmost(debugText: true))
        XCTAssertNil(session.windowTextContext)
        XCTAssertFalse(session.frontmostSampleInFlight)
        XCTAssertEqual(fixture.count("window"), 1)
        XCTAssertEqual(fixture.count("focus"), 0)
        XCTAssertEqual(fixture.count("tree"), 0)
        XCTAssertEqual(fixture.count("activate"), 0)
        try session.stop()
    }

    func testUnsupportedAXAttributeCanFallBackAndCommunicationFailureCannot() {
        let access = AccessibilityRead { true }
        XCTAssertEqual(access.perform { .attributeUnsupported }, .attributeUnsupported)
        XCTAssertTrue(access.canRead)
        XCTAssertEqual(access.perform { .success }, .success)
        XCTAssertEqual(access.perform { .cannotComplete }, .cannotComplete)
        XCTAssertFalse(access.canRead)
        XCTAssertEqual(access.perform { XCTFail("a failed read must send no more messages"); return .success }, .cannotComplete)
        XCTAssertEqual(AccessibilityRead { true }.perform { .success }, .success)
    }

    func testSecureInputDiscardsTextBufferAndStartsNewBaseline() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = SecureInputFixture()
        let session = CollectionSession(configuration: .init(rootDirectory: root),
                                        readers: fixture.readers, secureInput: { fixture.active })
        let start = Date()
        try session.start(now: start)
        session.sampleTextInput(now: start)
        fixture.focusedText += " pending text"
        session.sampleTextInput(now: start.addingTimeInterval(0.1))
        fixture.active = true
        fixture.focusedText += " text entered during secure input"
        session.sampleTextInput(now: start.addingTimeInterval(0.2))
        fixture.active = false
        session.sampleTextInput(now: start.addingTimeInterval(0.3))
        fixture.focusedText += " resumed text"
        session.sampleTextInput(now: start.addingTimeInterval(0.4))
        try session.stop(now: start.addingTimeInterval(0.5))
        XCTAssertEqual(try events(in: root).filter { $0.kind == .keyboardTextInput }
            .compactMap { $0.keyboard?.text }, [" resumed text"])
    }

    func testPasswordSubroleDoesNotReadValueInTreeClickOrFocus() {
        let element = AXUIElementCreateSystemWide()
        var valueReads = 0
        let password = AXTreeReader.Attributes { attribute in
            switch attribute {
            case kAXSubroleAttribute: return kAXSecureTextFieldSubrole
            case kAXValueAttribute: valueReads += 1; return "synthetic secret"
            default: return nil
            }
        }
        XCTAssertNil(AXTreeReader.buildDetail(element, attributes: password))
        XCTAssertNil(FrontmostApplication.element(attributes: password).value)
        XCTAssertNil(FrontmostApplication.focusedTextSnapshot(of: element, attributes: password).0.value)
        XCTAssertEqual(valueReads, 0)

        let regular = AXTreeReader.Attributes { attribute in
            guard attribute == kAXValueAttribute else { return nil }
            valueReads += 1
            return "ordinary text"
        }
        XCTAssertTrue(AXTreeReader.buildDetail(element, attributes: regular)?.contains("ordinary text") == true)
        XCTAssertEqual(FrontmostApplication.element(attributes: regular).value, "ordinary text")
        XCTAssertEqual(valueReads, 2)
    }
}
