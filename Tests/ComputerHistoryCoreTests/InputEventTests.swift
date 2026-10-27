import CoreGraphics
import XCTest
@testable import ComputerHistoryCore

final class InputEventTests: XCTestCase {
    func testMouseDispatchKeepsFlagsPositionAndClickCount() throws {
        var received: [InputEvent] = []
        let tap = InputTap { received.append($0) }
        let point = CGPoint(x: 123, y: 456)
        for type: CGEventType in [.leftMouseDown, .rightMouseDown, .otherMouseDown] {
            let event = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left))
            event.flags = [.maskCommand, .maskShift]
            event.setIntegerValueField(.mouseEventClickState, value: 2)
            tap.dispatch(type: type, event: event)
        }
        XCTAssertEqual(received.count, 3)
        for event in received {
            switch event {
            case .leftMouseDown(let count, let flags, let position),
                 .rightMouseDown(let count, let flags, let position),
                 .otherMouseDown(let count, let flags, let position):
                XCTAssertEqual(count, 2)
                XCTAssertEqual(ModifierNames.names(from: flags), ["command", "shift"])
                XCTAssertEqual(position, point)
            default: XCTFail("Unexpected mouse classification")
            }
        }
    }

    func testClickReadsHitTargetOnlyAfterPolicyAndKeepsUnknownTarget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = CollectionSession(configuration: .init(rootDirectory: root,
            policy: .init(defaultApplicationBehavior: .doNotObserve, allowlist: [.application("test.editor")])))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try session.start(now: now)
        let id = try XCTUnwrap(session.currentSegmentID)
        session.recordClick(button: "left", clickCount: 1, modifiers: [], app: nil, window: nil,
            readTarget: { XCTFail("Missing identity must not read target"); return nil }, at: now)
        for target: EventStreamAXElement? in [.init(title: "Hit button"), nil] {
            session.recordClick(button: "left", clickCount: 1, modifiers: ["shift"],
                app: .init(bundleIdentifier: "test.editor"), window: nil, readTarget: { target }, at: now)
        }
        try session.stop(now: now)
        let clicks = try EventArchive.readEvents(at: root.appendingPathComponent("segments/\(id)/events.jsonl"))
            .compactMap(\.mouse)
        XCTAssertEqual(clicks.count, 2)
        XCTAssertEqual(clicks.first?.target?.title, "Hit button")
        XCTAssertNil(clicks.last?.target)
        XCTAssertEqual(clicks.first?.modifiers, ["shift"])
    }

    func testCharacterModifiersAreNotShortcuts() {
        for flags: CGEventFlags in [[], .maskShift, .maskAlphaShift, .maskAlternate, [.maskShift, .maskAlternate]] {
            XCTAssertEqual(InputKey.action(for: 0, flags: flags), .text)
        }
        for flags: CGEventFlags in [.maskCommand, .maskControl, [.maskShift, .maskCommand]] {
            XCTAssertEqual(InputKey.action(for: 0, flags: flags), .shortcut)
        }
        XCTAssertEqual(InputKey.action(for: 36, flags: []), .submit)
        XCTAssertEqual(InputKey.action(for: 76, flags: []), .submit)
        XCTAssertEqual(InputKey.action(for: 48, flags: .maskShift), .shortcut)
        XCTAssertEqual(InputKey.action(for: 123, flags: .maskAlternate), .shortcut)
    }

    func testScrollDispatchKeepsDeltaAndLocation() throws {
        var received: [InputEvent] = []
        let tap = InputTap { received.append($0) }
        let point = CGPoint(x: 300, y: 400)
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: -10, wheel2: 5, wheel3: 0))
        event.location = point
        event.flags = [.maskShift]
        tap.dispatch(type: .scrollWheel, event: event)

        XCTAssertEqual(received.count, 1)
        guard case .scroll(_, let dy, let flags, let loc)? = received.first else {
            return XCTFail("Expected .scroll event")
        }
        XCTAssertEqual(flags, [.maskShift])
        XCTAssertEqual(loc, point)
        XCTAssertNotEqual(dy, 0)
    }

    func testDeferredScrollingCoalescesAndIgnoresMomentum() throws {
        var received: [InputEvent] = []
        let tap = InputTap { received.append($0) }
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 5, wheel2: 0, wheel3: 0))
        event.setIntegerValueField(.eventTargetUnixProcessID, value: 0)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 1)
        tap.dispatch(type: .scrollWheel, event: event)
        XCTAssertTrue(received.isEmpty)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
        for _ in 0..<100 { tap.dispatch(type: .scrollWheel, event: event, deferred: true) }
        XCTAssertTrue(received.isEmpty, "The system callback must not perform collection work")
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        XCTAssertEqual(received.count, 1)
    }

    func testScrollThrottlingWithinSameWindow() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = CollectionSession(configuration: .init(rootDirectory: root,
            policy: .init(defaultApplicationBehavior: .observe, allowlist: [])))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try session.start(now: now)
        let id = try XCTUnwrap(session.currentSegmentID)

        let app = EventStreamApp(name: "TestApp", processIdentifier: 12345, bundleIdentifier: "test.app")
        let win = EventStreamWindow(title: "Test Window", windowID: 999)

        // 第一次滚动
        session.recordScroll(deltaX: 0, deltaY: -5, modifiers: [], app: app, window: win, readTarget: { nil }, at: now)
        // 0.2 秒后第二次滚动（同应用同窗口，在 1.0s 内，应被节流）
        session.recordScroll(deltaX: 0, deltaY: -5, modifiers: [], app: app, window: win, readTarget: { nil }, at: now.addingTimeInterval(0.2))
        // 1.5 秒后第三次滚动（超过 1.0s，应落盘）
        session.recordScroll(deltaX: 0, deltaY: -5, modifiers: [], app: app, window: win, readTarget: { nil }, at: now.addingTimeInterval(1.5))

        try session.stop(now: now.addingTimeInterval(2.0))
        let events = try EventArchive.readEvents(at: root.appendingPathComponent("segments/\(id)/events.jsonl"))
        let scrolls = events.filter { $0.kind == .mouseScroll }
        XCTAssertEqual(scrolls.count, 2)
    }
}
