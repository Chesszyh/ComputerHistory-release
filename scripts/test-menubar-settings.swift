import SwiftUI
import AppKit
import ComputerHistoryCore

@main struct SettingsRegression {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: RequestDisclosure(title: "原始输入", text: "Synthetic request payload\nSecond line")
            .padding(14).frame(width: 380))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: host.fittingSize.height),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let before = host.fittingSize.height
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: 330, y: window.contentLayoutRect.height / 2),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
            window.sendEvent(event)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        precondition(host.fittingSize.height > before + 20, "Clicking empty space at the right of a request disclosure must expand it")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try ModelSettings(baseURL: URL(string: "http://127.0.0.1:1234/v1")!, model: "synthetic-model",
            requiresAPIKey: false).save(root: root)
        var config = CollectorConfig()
        config.policy.blocklist = [.application("com.apple.Passwords")]
        try config.jsonData().write(to: CollectorConfig.fileURL(rootDirectory: root))
        let model = StatusModel(root: root)
        defer { model.shutdown() }
        model.openSummarySettings()
        model.settingsTab = .model
        let panel = NSHostingView(rootView: StatusPanel(model: model).environment(\.colorScheme, .dark))
        window.setContentSize(NSSize(width: 380, height: 640))
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = panel
        func settle() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            panel.layoutSubtreeIfNeeded()
        }
        func fields(_ parent: NSView) -> [NSTextField] {
            (parent as? NSTextField).map { [$0] } ?? parent.subviews.flatMap(fields)
        }
        func edit(_ id: String, value: String) {
            let placeholders = ["model-name": "deepseek-flash", "collector-days": "0 表示不按天数清理"]
            guard let field = fields(panel).first(where: { $0.placeholderString == placeholders[id] }) else {
                fatalError("Missing settings field: \(id)")
            }
            field.stringValue = value
            field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
            settle()
        }
        func saveByClick() {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: 342, y: 25), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
                window.sendEvent(event)
            }
            settle()
        }
        settle()
        edit("model-name", value: "edited-in-form")
        precondition(model.modelDraft.model == "edited-in-form", "Native model field must update the draft")
        saveByClick()
        precondition(try! ModelSettings.load(root: root)?.model == "edited-in-form", "Save button must persist the model form")
        precondition(model.modelSettingsError == nil)
        model.settingsTab = .collector
        settle()
        edit("collector-days", value: "6")
        precondition(model.collectorDraft.maxAgeDays == "6", "Native retention field must update the draft")
        saveByClick()
        precondition(try! CollectorConfig.load(rootDirectory: root).retention.maxAgeDays == 6, "Save button must persist the collector form")
        edit("collector-days", value: "invalid")
        saveByClick()
        precondition(model.collectorSettingsError != nil, "Invalid values must remain visible as a form error")
        precondition(try! CollectorConfig.load(rootDirectory: root).retention.maxAgeDays == 6, "Invalid edits must not overwrite valid settings")
        try Data("invalid JSON".utf8).write(to: CollectorConfig.fileURL(rootDirectory: root))
        model.loadConfigurationDrafts()
        precondition(!model.collectorConfigurationLoaded && model.collectorSettingsError != nil)
        model.saveCollectorConfiguration()
        precondition(try! String(contentsOf: CollectorConfig.fileURL(rootDirectory: root), encoding: .utf8) == "invalid JSON",
            "A failed load must not silently replace a user's configuration")
        print("PASS: full-row request disclosure, native model/collector editing, save buttons, validation, and malformed-file preservation")
    }
}
