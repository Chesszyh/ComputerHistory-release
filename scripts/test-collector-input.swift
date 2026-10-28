import AppKit
import ApplicationServices
import ComputerHistoryCore

@main struct CollectorInputTest {
    @MainActor static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }

    @MainActor static func run() throws {
        let app = NSApplication.shared
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--fixture" {
            app.setActivationPolicy(.regular)
            let window = NSWindow(contentRect: NSRect(x: 180, y: 180, width: 480, height: 240),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Synthetic collector input test"
            let field = NSTextField(frame: NSRect(x: 30, y: 150, width: 400, height: 24))
            field.stringValue = "SYNTHETIC FOCUSED FIELD"
            field.setAccessibilityIdentifier("synthetic-focus")
            let button = NSButton(title: "SYNTHETIC HIT BUTTON", target: nil, action: nil)
            button.frame = NSRect(x: 100, y: 60, width: 260, height: 40)
            button.setAccessibilityIdentifier("synthetic-hit")
            window.contentView!.addSubview(field)
            window.contentView!.addSubview(button)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            app.activate(ignoringOtherApps: true)
            window.makeFirstResponder(field)
            let point = window.convertPoint(toScreen: NSPoint(x: button.frame.midX, y: button.frame.midY))
            let data = try JSONSerialization.data(withJSONObject: ["x": point.x,
                "y": NSScreen.screens[0].frame.maxY - point.y])
            try data.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
            let observed = URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathExtension("observed")
            let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 6, let cgEvent = event.cgEvent {
                    let postedAt = Double(cgEvent.getIntegerValueField(.eventSourceUserData)) / 1_000_000
                    let delay = Date().timeIntervalSince1970 - postedAt
                    try? Data(String(delay).utf8).write(to: observed)
                }
                return event
            }
            withExtendedLifetime((window, monitor)) { app.run() }
            return
        }
        guard AXIsProcessTrusted() else {
            print("SKIP: collector input GUI test requires Accessibility permission for panel-test")
            exit(77)
        }
        app.setActivationPolicy(.accessory)
        let original = NSWorkspace.shared.frontmostApplication
        let cursor = CGEvent(source: nil)?.location
        defer {
            if let cursor { CGWarpMouseCursorPosition(cursor) }
            original?.activate(options: [])
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let geometry = root.appendingPathComponent("fixture.json")
        let fixture = Process()
        fixture.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        fixture.arguments = ["--fixture", geometry.path]
        fixture.standardOutput = FileHandle.nullDevice
        fixture.standardError = FileHandle.nullDevice
        try fixture.run()
        defer { if fixture.isRunning { fixture.terminate(); fixture.waitUntilExit() } }
        func pump(_ seconds: Double = 0.1) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain: "CollectorInputTest", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: geometry.path) {
                if #available(macOS 14.0, *) {
                    NSRunningApplication(processIdentifier: fixture.processIdentifier)?.activate()
                } else {
                    NSRunningApplication(processIdentifier: fixture.processIdentifier)?.activate(options: .activateIgnoringOtherApps)
                }
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == fixture.processIdentifier { break }
            }
            pump()
        }
        try require(NSWorkspace.shared.frontmostApplication?.processIdentifier == fixture.processIdentifier,
            "Synthetic fixture did not become frontmost")
        var focused = FrontmostApplication.focusedElement()
        let focusDeadline = Date().addingTimeInterval(3)
        while Date() < focusDeadline && focused?.value != "SYNTHETIC FOCUSED FIELD" {
            pump(0.1)
            focused = FrontmostApplication.focusedElement()
        }
        try require(focused?.value == "SYNTHETIC FOCUSED FIELD", "Synthetic field did not receive keyboard focus")
        let point = try JSONSerialization.jsonObject(with: Data(contentsOf: geometry)) as! [String: Double]
        let location = CGPoint(x: point["x"]!, y: point["y"]!)
        CGWarpMouseCursorPosition(location)
        pump(0.1)
        let passiveTap = InputTap { _ in }
        try passiveTap.start()
        defer { passiveTap.stop() }
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(50)) {
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: 6, keyDown: down)!
                event.setIntegerValueField(.eventSourceUserData,
                    value: Int64(Date().timeIntervalSince1970 * 1_000_000))
                event.post(tap: .cghidEventTap)
            }
        }
        // The fixture has its own runloop; it must receive input while this listener is blocked.
        Thread.sleep(forTimeInterval: 0.6)
        let observed = geometry.appendingPathExtension("observed")
        let delay = (try? String(contentsOf: observed, encoding: .utf8)).flatMap(Double.init)
        try require(delay != nil && delay! >= 0 && delay! < 0.2,
                    "Collector runloop blocked input delivery: \(delay.map(String.init(describing:)) ?? "no delivery")")
        passiveTap.stop()
        pump()
        print("PASS: blocked collector runloop leaves fixture input delivery at \(Int(delay! * 1_000))ms")
        let session = CollectionSession(configuration: .init(rootDirectory: root))
        try session.start()
        let segment = session.currentSegmentID!
        var keyActions: [InputKey.Action] = []
        let tap = InputTap { event in
            MainActor.assumeIsolated {
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == fixture.processIdentifier else { return }
                switch event {
                case .leftMouseDown(let count, let flags, let location):
                    session.recordClick(button: "left", clickCount: count,
                        modifiers: ModifierNames.names(from: flags), location: location)
                case .scroll(let dx, let dy, let flags, let location):
                    session.recordScroll(deltaX: dx, deltaY: dy,
                        modifiers: ModifierNames.names(from: flags), location: location)
                case .keyDown(let code, let flags, _):
                    let action = InputKey.action(for: code, flags: flags)
                    keyActions.append(action)
                    if action == .shortcut {
                        session.recordShortcut(keyEquivalent: InputKey.name(for: code), modifiers: ModifierNames.names(from: flags))
                    }
                default: break
                }
            }
        }
        try tap.start()
        defer { tap.stop() }
        try require(tap.isEnabled, "Event tap must be enabled after start")
        try require(tap.ensureActive(), "Event tap ensureActive failed")
        for flags: CGEventFlags in [[], .maskShift] {
            for type: CGEventType in [.leftMouseDown, .leftMouseUp] {
                let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: .left)!
                event.flags = flags
                event.setIntegerValueField(.mouseEventClickState, value: 1)
                event.post(tap: .cghidEventTap)
                pump()
            }
        }
        let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -5, wheel2: 0, wheel3: 0)!
        scroll.location = location
        scroll.post(tap: .cghidEventTap)
        pump()
        for flags: CGEventFlags in [.maskShift, .maskCommand] {
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)!
                event.flags = flags
                event.post(tap: .cghidEventTap)
                pump()
            }
        }
        try session.stop()
        let records = try EventArchive.readEvents(at: root.appendingPathComponent("segments/\(segment)/events.jsonl"))
        let clicks = records.compactMap(\.mouse).filter { $0.button != "scroll" }
        try require(clicks.count == 2, "System event tap did not deliver both clicks")
        try require(clicks.allSatisfy { $0.target?.identifier == "synthetic-hit" }, "Click target did not identify the hit button")
        try require(clicks[1].modifiers == ["shift"], "Mouse modifiers were lost")
        let scrolls = records.filter { $0.kind == .mouseScroll }
        try require(scrolls.count == 1, "System event tap did not record scroll event")
        try require(keyActions == [.text, .shortcut], "Shift character or Command shortcut was misclassified")
        try require(records.filter { $0.kind == .keyboardShortcut }.count == 1, "Incorrect shortcut count")
        print("PASS: system event tap, mouse hit target distinct from keyboard focus, modified click, scroll wheel, Shift character and Command shortcut")
    }
}
