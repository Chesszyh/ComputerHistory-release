import SwiftUI
import AppKit
import ComputerHistoryCore

@main struct PanelRegression {
    @MainActor static func main() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try! ActivityNarrative(items: (0..<48).map { n in
            .init(id: "synthetic-\(n)", timestamp: Date().addingTimeInterval(Double(-n * 600)),
                title: "整理项目文档 \(n + 1)", summary: "在编辑器中核对说明并更新项目文档。",
                apps: ["example.editor"], sourceMemories: [])
        }).save(root: root)
        _ = NSApplication.shared
        let model = StatusModel(root: root)
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        model.shutdown()
        let view = NSHostingView(rootView: StatusPanel(model: model).environment(\.colorScheme, .dark))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 640), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        func scrollView(_ parent: NSView) -> NSScrollView? {
            if let scroll = parent as? NSScrollView { return scroll }
            return parent.subviews.compactMap { scrollView($0) }.first
        }
        precondition(model.timelineLimit == 12 && model.timelineCount == 48, "Initial page must remain bounded")
        for expected in [24, 36, 48, 48] {
            guard let scroll = scrollView(view), let document = scroll.documentView else {
                fatalError("History scroll view is missing")
            }
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            precondition(model.timelineLimit == expected, "Scrolling must load exactly one page and stop at the end")
        }
        print("PASS: history starts at 12 and scrolls through 24, 36, 48 without loading beyond the end")
    }
}
