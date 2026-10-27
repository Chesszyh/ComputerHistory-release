import AppKit

@MainActor func nativeTestClick(window: NSWindow, point: NSPoint, clickCount: Int = 1) {
    let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 1, clickCount: clickCount, pressure: 1)!
    let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 2, clickCount: clickCount, pressure: 0)!
    // Native controls can consume mouseUp in a nested tracking loop before mouseDown returns.
    NSApplication.shared.postEvent(up, atStart: true)
    window.sendEvent(down)
    if let pending = NSApplication.shared.nextEvent(matching: .leftMouseUp, until: .distantPast,
            inMode: .default, dequeue: true) {
        window.sendEvent(pending)
    }
}
