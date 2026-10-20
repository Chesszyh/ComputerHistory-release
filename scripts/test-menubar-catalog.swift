import SwiftUI
import AppKit
import ComputerHistoryCore

struct CatalogRegression {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let endpoint = URL(string: ProcessInfo.processInfo.environment["COMPUTER_HISTORY_CATALOG_TEST_URL"]!)!
        try ModelSettings(baseURL: endpoint, model: "synthetic-alpha", requiresAPIKey: false).save(root: root)
        let model = StatusModel(root: root)
        defer { model.shutdown() }
        model.openSummarySettings()
        model.settingsTab = .model
        let panel = NSHostingView(rootView: StatusPanel(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 640), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = panel
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.2)); panel.layoutSubtreeIfNeeded() }
        func fields(_ parent: NSView) -> [NSTextField] {
            (parent as? NSTextField).map { [$0] } ?? parent.subviews.flatMap(fields)
        }
        model.fetchModelCatalog(groupID: model.editingGroupID)
        let deadline = Date().addingTimeInterval(5)
        while model.modelGroups[0].catalogLoading && Date() < deadline { settle() }
        settle()
        precondition(model.modelGroups[0].availableModels.map(\.id) == ["synthetic-alpha", "synthetic-beta"])
        precondition(model.modelGroups[0].availableModels[0].effort?.supported_levels == ["vendor-low", "vendor-max"])
        precondition(!fields(panel).contains { $0.placeholderString == "deepseek-flash" }, "Fetched models must use the model selector")
        precondition(fields(panel).contains { $0.placeholderString == "留空使用服务默认值" }, "Effort must remain freely editable")
        model.modelGroups[0].manualModel = true
        settle()
        precondition(fields(panel).contains { $0.placeholderString == "deepseek-flash" }, "Manual model entry must remain available")
        guard let urlField = fields(panel).first(where: { $0.placeholderString == "https://api.deepseek.com" }) else { fatalError("Missing endpoint field") }
        urlField.stringValue = endpoint.appendingPathComponent("other").absoluteString
        urlField.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: urlField))
        settle()
        precondition(model.modelGroups[0].availableModels.isEmpty, "Changing endpoint must discard the old provider's model catalog")
        print("PASS: model catalog fetch, provider effort metadata, native selector/manual fallback, and clearing metadata on endpoint changes")
    }
}
