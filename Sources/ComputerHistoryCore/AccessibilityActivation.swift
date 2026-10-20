import AppKit
import ApplicationServices

/// Chromium and Electron expose document trees only after an accessibility client connects.
public struct AccessibilityActivation {
    private struct Connection {
        var launchedAt: Date?
        var checkedAt: Date
        var ready: Bool
    }
    private var connections: [Int32: Connection] = [:]
    public init() {}

    mutating func prepare(pid: Int32, launchedAt: Date?, now: Date,
                          activate: () -> Bool) {
        if let existing = connections[pid], existing.launchedAt == launchedAt,
           now.timeIntervalSince(existing.checkedAt) < (existing.ready ? 30 : 1) { return }
        let ready = activate()
        connections[pid] = Connection(launchedAt: launchedAt, checkedAt: now, ready: ready)
    }

    public mutating func prepare(pid: Int32, now: Date = Date()) {
        let running = NSRunningApplication(processIdentifier: pid)
        prepare(pid: pid, launchedAt: running?.launchDate, now: now) {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 1)
            let role = AXTreeReader.copyString(app, kAXRoleAttribute as String)
            // Chrome can report unsupported for the enhanced setter after scheduling activation.
            // Keep requests apart: its full-document mode is enabled after a two-second debounce.
            for attribute in ["AXEnhancedUserInterface", "AXManualAccessibility"] {
                if AXTreeReader.copyBool(app, attribute) != true {
                    _ = AXUIElementSetAttributeValue(app, attribute as CFString, kCFBooleanTrue)
                }
            }
            return role != nil
        }
        connections = connections.filter { NSRunningApplication(processIdentifier: $0.key) != nil }
    }
}
