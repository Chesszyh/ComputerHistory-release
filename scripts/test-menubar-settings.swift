import SwiftUI
import AppKit
import ComputerHistoryCore

@main struct SettingsRegression {
    @MainActor static func main() throws {
        DispatchQueue.global().asyncAfter(deadline: .now() + 90) {
            FileHandle.standardError.write(Data("FAIL: native settings regression exceeded 90 seconds\n".utf8))
            exit(1)
        }
        func stage(_ name: String) { print("SETTINGS: " + name); fflush(stdout) }
        stage("request disclosure")
        _ = NSApplication.shared
        let host = NSHostingView(rootView: RequestDisclosure(title: "原始输入", text: "Synthetic request payload\nSecond line")
            .padding(14).frame(width: 380))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: host.fittingSize.height),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        func click(_ point: NSPoint) {
            let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 2, clickCount: 1, pressure: 0)!
            // AppKit controls can run a nested tracking loop inside mouseDown.
            NSApplication.shared.postEvent(up, atStart: true)
            window.sendEvent(down)
            if let pending = NSApplication.shared.nextEvent(matching: .leftMouseUp, until: .distantPast,
                    inMode: .default, dequeue: true) {
                window.sendEvent(pending)
            }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let before = host.fittingSize.height
        click(NSPoint(x: 330, y: window.contentLayoutRect.height / 2))
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
        stage("load synthetic settings")
        let model = StatusModel(root: root)
        defer { model.shutdown() }
        model.loadConfigurationDrafts()
        stage("OCR application checkboxes")
        model.collectorDraft.windowTextApplications = ["example.synthetic-ocr"]
        let ocrHost = NSHostingView(rootView: ApplicationListEditor(
            apps: Binding(get: { model.collectorDraft.windowTextApplications }, set: { model.collectorDraft.windowTextApplications = $0 }),
            disabledApps: Binding(get: { model.collectorDraft.windowTextDisabledApplications }, set: { model.collectorDraft.windowTextDisabledApplications = $0 }))
            .frame(width: 340))
        window.contentView = ocrHost
        window.setContentSize(NSSize(width: 340, height: ocrHost.fittingSize.height))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        func clickOCRCheckbox() {
            click(NSPoint(x: 15, y: window.contentLayoutRect.height - 12))
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        }
        clickOCRCheckbox()
        precondition(model.collectorDraft.windowTextDisabledApplications == ["example.synthetic-ocr"], "OCR checkbox must disable the listed application")
        model.saveCollectorConfiguration()
        precondition(try! CollectorConfig.load(rootDirectory: root).windowTextDisabledApplications == ["example.synthetic-ocr"])
        clickOCRCheckbox()
        precondition(model.collectorDraft.windowTextDisabledApplications.isEmpty, "OCR checkbox must re-enable the application")
        model.saveCollectorConfiguration()
        precondition(try! CollectorConfig.load(rootDirectory: root).windowTextApplications == ["example.synthetic-ocr"])
        stage("native model form")
        model.openSummarySettings()
        model.settingsTab = .model
        let panel = NSHostingView(rootView: StatusPanel(model: model).environment(\.colorScheme, .dark))
        window.contentView = panel
        window.setContentSize(NSSize(width: 380, height: 640))
        window.appearance = NSAppearance(named: .darkAqua)
        stage("model form hosted")
        func settle() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            panel.layoutSubtreeIfNeeded()
        }
        func fields(_ parent: NSView) -> [NSTextField] {
            (parent as? NSTextField).map { [$0] } ?? parent.subviews.flatMap(fields)
        }
        func edit(_ id: String, value: String) {
            let placeholders = ["model-name": "deepseek-flash", "model-reasoning": "留空使用服务默认值", "collector-days": "0 表示不按天数清理"]
            guard let field = fields(panel).first(where: { $0.placeholderString == placeholders[id] }) else {
                fatalError("Missing settings field: \(id)")
            }
            field.stringValue = value
            field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
            settle()
        }
        func saveByClick() {
            click(NSPoint(x: 342, y: 25))
            settle()
        }
        settle()
        stage("model form settled")
        edit("model-name", value: "edited-in-form")
        precondition(model.modelGroups[0].settings.model == "edited-in-form", "Native model field must update the draft")
        stage("model name edited")
        saveByClick()
        stage("model form saved")
        precondition(try! ModelSettings.load(root: root)?.model == "edited-in-form", "Save button must persist the model form")
        precondition(model.modelSettingsError == nil)
        edit("model-reasoning", value: "provider-custom-level")
        saveByClick()
        precondition(try! ModelSettings.load(root: root)?.reasoningEffort == "provider-custom-level")
        edit("model-reasoning", value: "")
        saveByClick()
        precondition(try! ModelSettings.load(root: root)?.reasoningEffort == nil, "Blank effort must remain unspecified")
        stage("model group persistence")
        let originalID = model.primaryGroupID
        model.addModelGroup()
        let newID = model.editingGroupID
        model.modelGroups[1].name = "Synthetic second source"
        model.modelGroups[1].settings.model = "second-source"
        model.modelGroups[1].settings.requiresAPIKey = false
        model.primaryGroupID = newID
        model.fallbackGroupID = originalID
        model.saveModelConfiguration()
        precondition(model.modelSettingsError == nil)
        precondition(try! ModelSettings.load(root: root)?.model == "second-source")
        precondition(try! ModelSettings.load(root: root)?.fallback?.model == "edited-in-form")
        model.loadConfigurationDrafts()
        precondition(model.modelGroups.count == 2 && model.primaryGroupID == newID)
        precondition(model.modelGroups[0].settings.model == "edited-in-form", "Changing selection must retain other groups")
        stage("summary deletion and trash")
        try ActivityNarrative(items: [.init(id: "synthetic-delete", timestamp: Date(), title: "Synthetic summary",
            summary: "Synthetic duplicate", apps: [], sourceMemories: [])]).save(root: root)
        model.refreshAll()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let deletionItem = model.timelineGroups.flatMap(\.items).first!
        let deletionHost = NSHostingView(rootView: SummaryDetails(item: deletionItem, model: model).frame(width: 360))
        window.contentView = deletionHost
        window.setContentSize(NSSize(width: 380, height: deletionHost.fittingSize.height))
        settle()
        click(NSPoint(x: 40, y: window.contentLayoutRect.height - 18))
        settle()
        precondition(try! TimelineDeletions.load(root: root).ids.contains(deletionItem.deletionID), "Rendered delete button must persist deletion")
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        precondition(model.deletedSummaries.first!.item.summary == deletionItem.summary)
        let record = model.deletedSummaries.first!
        let trashCard = NSHostingView(rootView: TrashRecordCard(record: record, model: model).frame(width: 352))
        window.contentView = trashCard
        window.setContentSize(NSSize(width: 352, height: trashCard.fittingSize.height))
        settle()
        func clickTrashAction(x: CGFloat) {
            click(NSPoint(x: x, y: 20))
            settle()
        }
        clickTrashAction(x: 30)
        precondition(try! TimelineDeletions.load(root: root).ids.isEmpty, "Rendered restore button must restore deleted messages")
        model.deleteTimelineItem(deletionItem)
        settle()
        clickTrashAction(x: 310)
        precondition(try! TimelineDeletions.load(root: root).purgedIDs.contains(deletionItem.deletionID), "Rendered purge button must remove the message permanently from trash")

        model.showsTrash = false
        precondition(try! TimelineDeletions.load(root: root).records.isEmpty, "Purged entries must leave the trash")
        window.contentView = panel
        window.setContentSize(NSSize(width: 380, height: 640))
        stage("collector form")
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
        stage("backup settings")
        model.settingsTab = .backup
        settle()
        model.backupRepository = "example/synthetic-private"
        model.backupEnabled = true
        saveByClick()
        precondition(try! BackupSettings.load(root: root)?.enabled == true, "Backup settings save button must persist enabled state")
        model.setBackupEnabled(false)
        precondition(try! BackupSettings.load(root: root)?.enabled == false, "Quick toggle must persist disabled state")
        precondition(!model.effectiveBackupEnabled)
        print("PASS: full-row request disclosure, native model/collector editing, model-group persistence and swap, rendered summary deletion and trash restoration, save buttons, validation, and malformed-file preservation")
    }
}
