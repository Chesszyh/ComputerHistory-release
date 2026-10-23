import SwiftUI
import AppKit
import ComputerHistoryCore

struct SettingsRegression {
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
        func click(_ point: NSPoint) { nativeTestClick(window: window, point: point) }
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
        let command = root.appendingPathComponent("synthetic-command")
        try "#!/bin/sh\nprintf '%s\\n' \"$@\" >> \"\(root.appendingPathComponent("commands.txt").path)\"\n".write(to: command, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
        let model = StatusModel(root: root, commandExecutable: command)
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
        func snapshot(_ name: String) throws {
            guard let directory = ProcessInfo.processInfo.environment["COMPUTER_HISTORY_TEST_SCREENSHOTS"] else { return }
            panel.layoutSubtreeIfNeeded()
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-l", String(window.windowNumber), URL(fileURLWithPath: directory).appendingPathComponent(name + ".png").path]
            capture.standardError = FileHandle.nullDevice
            try capture.run()
            capture.waitUntilExit()
            precondition(capture.terminationStatus == 0, "Explicit synthetic-window screenshot failed")
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
        stage("timeline mode and recalculation choices")
        model.settingsTab = .timeline
        model.loadTimelineSettings()
        model.timelineMode = .fixedTenMinutes
        settle()
        saveByClick()
        precondition(try! SummarySettings.load(root: root).timelineMode == .fixedTenMinutes)
        precondition(model.showsTimelineRecalculation && !model.timelineRebuilding)
        try snapshot("timeline-mode")
        model.recalculateTimeline(.none)
        precondition(!FileManager.default.fileExists(atPath: root.appendingPathComponent("commands.txt").path), "No recalculation must launch no process")
        for scope in [StatusModel.TimelineRecalculation.today, .all] {
            model.recalculateTimeline(scope)
            let deadline = Date().addingTimeInterval(5)
            while model.timelineRebuilding && Date() < deadline { settle() }
            precondition(!model.timelineRebuilding && model.timelineSettingsError == nil)
        }
        let arguments = try String(contentsOf: root.appendingPathComponent("commands.txt"), encoding: .utf8)
        precondition(arguments.components(separatedBy: "--overwrite").count == 3)
        precondition(arguments.components(separatedBy: "--day").count == 2)
        try "#!/bin/sh\necho $$ > \"\(root.appendingPathComponent("owned-command.pid").path)\"\nexec /bin/sleep 30\n".write(to: command, atomically: true, encoding: .utf8)
        model.recalculateTimeline(.all)
        settle()
        let ownedPID = Int32(try String(contentsOf: root.appendingPathComponent("owned-command.pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        model.cancelTimelineRecalculation()
        let cancelDeadline = Date().addingTimeInterval(4)
        while model.timelineRebuilding && Date() < cancelDeadline { settle() }
        precondition(!model.timelineRebuilding && kill(ownedPID, 0) == -1, "Cancel must reap the owned command")
        stage("manual summary editing and explicit selection")
        let memories = root.appendingPathComponent("memories")
        try FileManager.default.createDirectory(at: memories, withIntermediateDirectories: true)
        for minute in [0, 10] {
            let name = String(format: "2020-01-01T00-%02d-00Z-ABCD-10min-memory-summary.md", minute)
            try "---\ntitle: Synthetic activity \(minute)\ndescription: 核对合成文档章节。\n---".write(to: memories.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        model.showsSummarySettings = false
        model.refreshAll(); settle(); settle()
        let items = model.timelineGroups.flatMap(\.items).filter { !$0.memoryFiles.isEmpty }
        precondition(items.count == 2 && model.canEditSummary(items[0]))
        model.editSummary(items[0]); settle()
        precondition(model.editingSummary != nil)
        model.editedTitle = ""; model.saveSummaryEdit()
        precondition(model.editError != nil && model.editingSummary != nil)
        model.editedTitle = "校对报告"; model.editedSummary = "补全合成报告的缺失章节。"
        settle(); try snapshot("summary-editor")
        // Exercise the actual editor's default save button.
        click(NSPoint(x: 342, y: 26)); settle(); settle()
        precondition(model.editingSummary == nil)
        let edited = model.timelineGroups.flatMap(\.items).first { $0.id == items[0].id }!
        precondition(edited.title == "校对报告" && edited.manualEdit == true)
        let clipboard = NSPasteboard.general.string(forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let clipboard { NSPasteboard.general.setString(clipboard, forType: .string) }
        }
        model.toggleSummarySelection()
        model.selectSummary(edited); model.selectSummary(items[1])
        settle(); try snapshot("summary-selection")
        model.copySelectedSummaries()
        let copied = NSPasteboard.general.string(forType: .string)!
        precondition(copied.contains("校对报告") && copied.contains(items[1].title) && copied.contains("2020-01-01"))
        precondition(!copied.contains("Synthetic summary"), "Unselected summary must stay out of clipboard")
        model.selectSummary(items[1]); model.copySelectedSummaries()
        precondition(!NSPasteboard.general.string(forType: .string)!.contains(items[1].title))
        model.toggleSummarySelection()
        model.editSummary(edited); model.saveSummaryEdit(restore: true); settle(); settle()
        precondition(try! TimelineEdits.load(root: root).entries.isEmpty)
        var continuous = try SummarySettings.load(root: root); continuous.timelineMode = .continuous
        try continuous.save(root: root); model.refreshAll(); settle(); settle()
        precondition(!model.canEditSummary(items[0]), "Continuous mode must not expose editing")
        model.showsSummarySettings = true
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
        print("PASS: full-row request disclosure, native model/collector editing, model-group persistence and swap, rendered summary deletion and trash restoration, timeline mode and scoped recalculation, cancellation, native summary editing, selected copy, save buttons, validation, and malformed-file preservation")
    }
}
