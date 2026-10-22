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
}
