import SwiftUI
import AppKit
import ComputerHistoryCore

@main struct PanelRegression {
    @MainActor static func main() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try! ActivityNarrative(items: (0..<120).map { n in
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
        precondition(model.timelineLimit == 12 && model.timelineCount == 120, "Initial page must remain bounded")
        guard let scroll = scrollView(view), let document = scroll.documentView else {
            fatalError("History scroll view is missing")
        }
        func advance() {
            let bottom = max(0, document.bounds.height - scroll.contentView.bounds.height)
            let next = min(bottom, scroll.contentView.bounds.minY + 60)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: next))
            scroll.reflectScrolledClipView(scroll.contentView)
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
        advance()
        precondition(model.timelineLimit == 12, "Scrolling near the top must not load older records")
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while model.timelineLimit == 12 && ProcessInfo.processInfo.systemUptime < deadline { advance() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        precondition(model.timelineLimit > 12 && model.timelineLimit < 120,
            "Reaching the bottom must load more without expanding the entire history; got \(model.timelineLimit)")
        while model.timelineLimit < 120 && ProcessInfo.processInfo.systemUptime < deadline {
            let previous = model.timelineLimit
            advance()
            precondition(model.timelineLimit >= previous && model.timelineLimit <= 120)
        }
        precondition(model.timelineLimit == 120,
            "Continuous scrolling must reach all history; got \(model.timelineLimit)")
        advance()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        precondition(model.timelineLimit == 120, "The end must not load beyond the available history")
        print("PASS: bounded initial page, no loading near the top, incremental loading through 120 records, and stable end")
    }
}
