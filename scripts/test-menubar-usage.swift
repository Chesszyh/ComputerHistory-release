import SwiftUI
import AppKit
import ComputerHistoryCore

@main struct PanelRegression {
    @MainActor static func main() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        for n in 0..<40 {
            let object: [String: Any] = ["id": "request-\(n)", "startedAt": noon.timeIntervalSinceReferenceDate - Double(n * 60),
                "model": "fixture-model", "endpoint": "http://127.0.0.1", "task": "10min",
                "sources": ["synthetic"], "status": "success", "system": "fixture", "input": "fixture", "output": "synthetic result"]
            let record = try! JSONDecoder().decode(ModelRequest.self, from: JSONSerialization.data(withJSONObject: object))
            try! record.save(root: root)
        }
        _ = NSApplication.shared
        let model = StatusModel(root: root)
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        defer { model.shutdown() }
        let view = NSHostingView(rootView: StatusPanel(model: model).environment(\.colorScheme, .dark))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 640), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        func scrollView(_ parent: NSView) -> NSScrollView? {
            if let scroll = parent as? NSScrollView { return scroll }
            return parent.subviews.compactMap { scrollView($0) }.first
        }
        model.showsUsage = true
        let loadDeadline = Date().addingTimeInterval(15)
        while model.modelRequests.count < 40, Date() < loadDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        precondition(model.modelRequests.count == 40, "Fixture requests must load before interaction")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        view.layoutSubtreeIfNeeded()
        func click(_ x: CGFloat, _ y: CGFloat) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
                window.sendEvent(event)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            view.layoutSubtreeIfNeeded()
        }
        guard let listScroll = scrollView(view), let document = listScroll.documentView else {
            fatalError("Usage list scroll view is missing")
        }
        // 折叠状态下最后一个分组标题位于文档底部。按文档坐标定位，避免仪表盘
        // 高度变化后固定的窗口坐标点空；整行都接受点击，不依赖箭头位置。
        let header = document.convert(
            NSPoint(x: document.bounds.width - 20, y: document.bounds.height - 16), to: nil)
        click(header.x, header.y)
        // LazyVStack 的行可能在下一次布局才出现；CI 上固定等待不够。
        let expandDeadline = Date().addingTimeInterval(10)
        while document.bounds.height <= listScroll.contentView.bounds.height + 200,
              Date() < expandDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            view.layoutSubtreeIfNeeded()
        }
        if document.bounds.height <= listScroll.contentView.bounds.height + 200 {
            FileHandle.standardError.write(Data((
                "usage geometry: requests=\(model.modelRequests.count) document=\(document.bounds) "
                + "scroll=\(listScroll.frame) header=\(header) expanded=\(model.expandedRequestGroups)\n").utf8))
        }
        precondition(document.bounds.height > listScroll.contentView.bounds.height + 200,
            "Clicking the group header must expand the request rows")
        listScroll.contentView.scroll(to: NSPoint(x: 0, y: 600))
        listScroll.reflectScrolledClipView(listScroll.contentView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        view.layoutSubtreeIfNeeded()
        let position = listScroll.contentView.bounds.origin
        precondition(position.y > 100, "The list must actually be scrolled before opening detail")
        for _ in 0..<3 {
            model.openRequest(model.modelRequests[10])
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            precondition(model.requestDetail?.id == model.modelRequests[10].id, "The selected request must load its detail")
            click(45, 618)
            precondition(model.requestDetail == nil, "Back must return to the list")
            precondition(scrollView(view) === listScroll, "The original list scroll view must survive detail navigation")
            precondition(document.bounds.height > listScroll.contentView.bounds.height + 200,
                "The request rows must stay expanded after returning")
            precondition(abs(listScroll.contentView.bounds.minY - position.y) < 1,
                "Back must preserve the exact list position")
        }
        model.refreshSlow()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        precondition(abs(listScroll.contentView.bounds.minY - position.y) < 1, "Refresh must preserve list position")
        model.closeUsage()
        model.openSummarySettings()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        precondition(model.summaryDraft == SummarySettings.Stage.tenMinute.defaultPrompt)
        func textView(_ parent: NSView) -> NSTextView? {
            if let editor = parent as? NSTextView { return editor }
            return parent.subviews.compactMap { textView($0) }.first
        }
        guard let editor = textView(view) else { fatalError("Prompt editor must be wired to the settings pane") }
        editor.string = "合成的自定义提示词"
        editor.didChangeText()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        precondition(model.summaryDraft == "合成的自定义提示词", "Editor changes must reach the settings model")
        model.saveSummaryDraft()
        precondition(try! SummarySettings.load(root: root)[.tenMinute] == "合成的自定义提示词")
        model.summaryStage = .narrative
        model.loadSummaryDraft()
        precondition(model.summaryDraft == SummarySettings.Stage.narrative.defaultPrompt)
        model.summaryDraft = "合成活动整理提示词"
        model.saveSummaryDraft()
        model.summaryStage = .tenMinute
        model.loadSummaryDraft()
        precondition(model.summaryDraft == "合成的自定义提示词")
        model.summaryDraft = model.summaryStage.defaultPrompt
        model.saveSummaryDraft()
        let restored = try! SummarySettings.load(root: root)
        precondition(restored.tenMinutePrompt == nil && restored.narrativePrompt == "合成活动整理提示词")
        print("PASS: whole-header mouse click, request navigation, expansion and scroll retention across return/refresh, and prompt editing/save/restore")
    }
}
