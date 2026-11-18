import CoreFoundation
import CoreGraphics
import Foundation
import XCTest
@testable import ComputerHistoryCore

private final class TapFixture {
    var ports: [CFMachPort] = []
    var keyAccess = true
    var failCreation = false
    var frontmostPID: pid_t? = 11
    var enables: [Bool] = []

    var system: InputTap.System {
        .init(makePort: { [self] _, _, _ in
            guard !failCreation, let port = CFMachPortCreate(nil, nil, nil, nil) else { return nil }
            ports.append(port)
            return port
        }, listensToKeys: { [self] in keyAccess }, isEnabled: { CFMachPortIsValid($0) },
        enable: { [self] _, enabled in enables.append(enabled) }, frontmostPID: { [self] in frontmostPID })
    }

    deinit {
        for port in ports where CFMachPortIsValid(port) { CFMachPortInvalidate(port) }
    }
}

private final class RunLoopAction {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
}

final class InputTapAuditTests: XCTestCase {
    private func click(target: pid_t = 0) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                         mouseCursorPosition: .zero, mouseButton: .left))
        event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(target))
        return event
    }

    private func drain() { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    func testReleaseInvalidatesThePortWithoutDeliveringQueuedInput() throws {
        let fixture = TapFixture()
        var received = 0
        var tap: InputTap? = InputTap(system: fixture.system) { _ in received += 1 }
        let prior = { [weak tap] in tap }
        try tap?.start()
        let port = try XCTUnwrap(fixture.ports.last)
        XCTAssertTrue(CFMachPortIsValid(port))
        tap?.dispatch(type: .leftMouseDown, event: try click(), deferred: true)
        tap = nil
        XCTAssertNil(prior())
        XCTAssertFalse(CFMachPortIsValid(port))
        drain()
        XCTAssertEqual(received, 0)
    }

    func testRepeatedStartAndStopDoNotDuplicateNativeRegistration() throws {
        let fixture = TapFixture()
        let tap = InputTap(system: fixture.system) { _ in }
        try tap.start()
        try tap.start()
        XCTAssertEqual(fixture.ports.count, 1)
        tap.stop()
        tap.stop()
        XCTAssertEqual(fixture.enables, [true, false])
        XCTAssertTrue(fixture.ports.allSatisfy { !CFMachPortIsValid($0) })
        XCTAssertFalse(tap.hasKeyListening)
    }

    func testFailedStartLeavesNoKeyboardStatusAndCanRetry() throws {
        let fixture = TapFixture()
        fixture.failCreation = true
        let tap = InputTap(system: fixture.system) { _ in }
        XCTAssertThrowsError(try tap.start())
        XCTAssertFalse(tap.isEnabled)
        XCTAssertFalse(tap.hasKeyListening)
        XCTAssertTrue(fixture.enables.isEmpty)
        fixture.failCreation = false
        try tap.start()
        XCTAssertTrue(tap.hasKeyListening)
        tap.stop()
    }

    func testRestartDropsQueuedInputFromThePreviousRegistration() throws {
        let fixture = TapFixture()
        var received: [Int] = []
        let tap = InputTap(system: fixture.system) {
            if case .leftMouseDown(let count, _, _) = $0 { received.append(count) }
        }
        defer { tap.stop() }
        try tap.start()
        let event = try click()
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        tap.dispatch(type: .leftMouseDown, event: event, deferred: true)
        tap.stop()
        try tap.start()
        event.setIntegerValueField(.mouseEventClickState, value: 2)
        tap.dispatch(type: .leftMouseDown, event: event, deferred: true)
        drain()
        XCTAssertEqual(received, [2])
    }

    func testFirstClickDeliversOnlyWhenTheTargetOwnsTheForegroundAtDelivery() throws {
        let fixture = TapFixture()
        var attributed: [pid_t?] = []
        let tap = InputTap(system: fixture.system) { _ in attributed.append(fixture.frontmostPID) }
        defer { tap.stop() }
        try tap.start()
        let clickToB = try click(target: 22)
        XCTAssertEqual(clickToB.getIntegerValueField(.eventTargetUnixProcessID), 22)
        fixture.frontmostPID = 11
        tap.dispatch(type: .leftMouseDown, event: clickToB, deferred: true)
        XCTAssertTrue(attributed.isEmpty)
        fixture.frontmostPID = 22
        drain()
        XCTAssertEqual(attributed, [22])

        fixture.frontmostPID = 11
        tap.dispatch(type: .leftMouseDown, event: clickToB, deferred: true)
        drain()
        fixture.frontmostPID = 22
        drain()
        tap.dispatch(type: .leftMouseDown, event: try click(target: 11), deferred: true)
        drain()
        XCTAssertEqual(attributed, [22], "Clicks on a different target must not enter collection")
    }

    func testSameRunLoopDeliveryDoesNotWaitForAnotherEvent() throws {
        let fixture = TapFixture()
        let loop = CFRunLoopGetCurrent()
        let event = try click()
        var began: UInt64 = 0
        var callbackReturned = false
        var delays: [Double] = []
        let tap = InputTap(system: fixture.system) { _ in
            XCTAssertTrue(callbackReturned)
            delays.append(Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000)
            CFRunLoopStop(loop)
        }
        defer { tap.stop() }
        try tap.start()
        let action = RunLoopAction {
            callbackReturned = false
            began = DispatchTime.now().uptimeNanoseconds
            tap.dispatch(type: .leftMouseDown, event: event, deferred: true)
            callbackReturned = true
        }
        var context = CFRunLoopSourceContext()
        context.info = Unmanaged.passUnretained(action).toOpaque()
        context.perform = { context in
            guard let context else { return }
            Unmanaged<RunLoopAction>.fromOpaque(context).takeUnretainedValue().run()
        }
        let source = try XCTUnwrap(CFRunLoopSourceCreate(nil, 0, &context))
        CFRunLoopAddSource(loop, source, .commonModes)
        defer { CFRunLoopSourceInvalidate(source) }
        withExtendedLifetime(action) {
            for _ in 0..<128 {
                CFRunLoopSourceSignal(source)
                _ = CFRunLoopRunInMode(.defaultMode, 0.25, false)
            }
        }
        XCTAssertEqual(delays.count, 128)
        let sorted = delays.sorted()
        if sorted.count == 128 {
            print(String(format: "same-runloop synthetic samples %d, median %.3f ms, p95 %.3f ms, max %.3f ms",
                         sorted.count, sorted[64], sorted[121], sorted[127]))
        }
    }
}
