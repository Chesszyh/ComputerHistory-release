import AppKit
import ApplicationServices
import ComputerHistoryCore
import Darwin

private let title = "Synthetic AX timeout fixture"
private let focus = "SYNTHETIC FOCUSED VALUE"
private let sentinel = "SYNTHETIC AX BODY"

@MainActor
private final class BlockingField: NSTextField {
    var gate: URL?
    override func accessibilityHelp() -> String? {
        if let gate, FileManager.default.fileExists(atPath: gate.appendingPathExtension("arm").path) {
            try? FileManager.default.removeItem(at: gate.appendingPathExtension("arm"))
            try? Data("help".utf8).write(to: gate.appendingPathExtension("tripped"), options: .atomic)
            raise(SIGSTOP)
        }
        return "Synthetic field help"
    }
}

@main
struct Probe {
    @MainActor static func main() throws {
        let args = CommandLine.arguments
        if args[1] == "active" {
            print(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)
            return
        }
        if args[1] == "activate" {
            let target = NSRunningApplication(processIdentifier: Int32(args[2])!)
            if #available(macOS 14.0, *) { _ = target?.activate() }
            else { _ = target?.activate(options: [.activateIgnoringOtherApps]) }
            return
        }
        if args[1] == "fixture" {
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            let window = NSWindow(contentRect: NSRect(x: 170, y: 170, width: 435, height: 230),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = title
            let focused = NSTextField(frame: NSRect(x: 20, y: 165, width: 385, height: 28))
            focused.stringValue = focus
            let body = NSTextField(labelWithString: sentinel)
            body.frame = NSRect(x: 20, y: 125, width: 385, height: 30)
            let blocker = BlockingField(frame: NSRect(x: 20, y: 80, width: 385, height: 24))
            blocker.gate = URL(fileURLWithPath: args[2])
            blocker.stringValue = "SYNTHETIC MID-TREE CONTROL"
            window.contentView!.addSubview(focused)
            window.contentView!.addSubview(body)
            window.contentView!.addSubview(blocker)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            window.makeFirstResponder(focused)
            app.activate(ignoringOtherApps: true)
            if (InputTap.secondsSinceLastInput ?? 0) >= AwayPeriods.idleThreshold,
               let location = CGEvent(source: nil)?.location {
                CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: location,
                        mouseButton: .left)?.post(tap: .cghidEventTap)
            }
            let ready = URL(fileURLWithPath: args[2]).appendingPathExtension("ready")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { try? Data().write(to: ready) }
            withExtendedLifetime(window) { app.run() }
            return
        }
        guard AXIsProcessTrusted() else {
            print("SKIP: test executable needs Accessibility permission")
            exit(77)
        }
        if args[1] == "permission" { return }
#if AX_TIMEOUT_MENUBAR
        if args[1] == "watch-menu" {
            let root = URL(fileURLWithPath: args[2])
            let pid = Int32(args[3])!
            _ = NSApplication.shared
            let model = StatusModel(root: root)
            defer { model.shutdown() }
            for (label, expected) in [("menu-ready", title), ("menu-unavailable", nil), ("menu-recovered", title)] {
                let deadline = ContinuousClock.now + .seconds(10)
                while FrontmostApplication.current()?.processIdentifier != pid || model.frontWindow != expected {
                    guard ContinuousClock.now < deadline else { fatalError("Menu did not reach \(label)") }
                    model.refreshLive()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
                }
                try Data().write(to: root.appendingPathComponent(label), options: .atomic)
            }
            return
        }
#endif
        let pid = Int32(args[2])!
        if args[3] == "collector" {
            try AccessibilityMessaging.configure(for: .collector)
        } else if args[3] == "menubar" {
            try AccessibilityMessaging.configure(for: .menubar)
        } else if let duration = Float(args[3]) {
            let status = AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), duration)
            guard status == .success else { fatalError("AX timeout setup failed: \(status.rawValue)") }
        }
        let begin = ProcessInfo.processInfo.systemUptime
        let target = EventStreamApp(name: title, processIdentifier: pid, bundleIdentifier: "test.ax.timeout")
        var result: [String: Any] = [:]
        switch args[1] {
        case "raw":
            var focused: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute as CFString, &focused)
            result["status"] = status.rawValue
        case "window":
            let window = FrontmostApplication.window(pid: pid)
            result["expectedTitle"] = window?.title == title
        case "focus":
            let observation = FrontmostApplication.focusedElementObservation(for: target)
            result["expectedValue"] = observation.value == focus
        case "activation":
            var activation = AccessibilityActivation()
            activation.prepare(pid: pid)
        case "tree":
            let roots = AXTreeReader.read(pid: pid, maxNodes: 24, maxDepth: 8)
            result["roots"] = roots.count
            result["expectedBody"] = UIElementRenderTree.text(roots).contains(sentinel)
        default: fatalError("Unknown operation")
        }
        result["ms"] = (ProcessInfo.processInfo.systemUptime - begin) * 1000
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }
}
