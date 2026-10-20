import SwiftUI
import AppKit
import ComputerHistoryCore

struct ReportsRegression {
    @MainActor static func main() throws {
        DispatchQueue.global().asyncAfter(deadline: .now() + 90) {
            FileHandle.standardError.write(Data("FAIL: report panel regression exceeded 90 seconds\n".utf8))
            exit(1)
        }
        func stage(_ name: String) { print("REPORTS: " + name); fflush(stdout) }
        stage("synthetic report and panel")
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let period = ReportPeriod(kind: .daily, date: Date())
        let segment = SegmentClock.segmentID(for: period.start.addingTimeInterval(60))
        try ActivityExport.write("""
        ---
        title: Synthetic task
        description: Synthetic description
        generation: model
        applications: []
        ---
        ## Memory summary
        ### 本次活动
        Synthetic activity for copy and export.
        ## Citations
        /synthetic/private/events.jsonl
        """, to: root.appendingPathComponent("memories/" + MemoryWriter.fileName(segmentID: segment)))
        _ = try ReportGenerator(root: root, client: nil).generate(period: period)
        let model = StatusModel(root: root)
        defer { model.shutdown() }
        model.openReports()
        let view = NSHostingView(rootView: StatusPanel(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 640),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let deadline = Date().addingTimeInterval(5)
        while model.reportBusy && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        view.layoutSubtreeIfNeeded()
        precondition(!model.reportText.isEmpty && model.reportMaterial.contains("Synthetic activity"))
        precondition(!model.backupEnabled && model.backupLoaded)
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        defer {
            pasteboard.clearContents()
            let restored = saved.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            pasteboard.writeObjects(restored)
        }
        func click(_ x: CGFloat, _ y: CGFloat) {
            nativeTestClick(window: window, point: NSPoint(x: x, y: y))
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        // The report action row follows the header and date selectors at the top of the fixed-size panel.
        stage("native copy button")
        click(125, 640 - 104)
        precondition(pasteboard.string(forType: .string) == model.reportText, "Copy report button must copy the entire report")
        model.copyReport(material: true)
        precondition(pasteboard.string(forType: .string) == model.reportMaterial)
        let output = root.appendingPathComponent("output.txt")
        model.saveReport(to: output, material: true)
        let text = try String(contentsOf: output, encoding: .utf8)
        precondition(text.contains("Synthetic activity") && !text.contains("## ") && !text.contains("/synthetic/private"))
        stage("backup settings")
        model.openSummarySettings()
        model.showsReports = false
        model.settingsTab = .backup
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        model.backupRepository = "example/private-data"
        model.backupEnabled = true
        model.saveBackupSettings()
        precondition(try! BackupSettings.load(root: root)?.enabled == true)
        model.backupEnabled = false
        model.saveBackupSettings()
        precondition(try! BackupSettings.load(root: root)?.enabled == false)
        model.showsSummarySettings = false
        model.showsReports = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        stage("back navigation")
        click(30, 617)
        precondition(!model.showsReports, "Back button must return to the timeline")
        print("PASS: report panel, native copy button, complete AI material, TXT export, optional backup settings, and back navigation")
    }
}
