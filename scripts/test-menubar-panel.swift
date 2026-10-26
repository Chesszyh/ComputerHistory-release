import SwiftUI
import AppKit
import Combine
import ComputerHistoryCore

struct HistoryRegression {
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
        let clock = Date(timeIntervalSince1970: 1_600_000_000)
        precondition(model.relativeLabel(clock, now: clock.addingTimeInterval(13)) == "13 秒前")
        precondition(model.relativeLabel(clock, now: clock.addingTimeInterval(14)) == "14 秒前")
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        var redundantPublications = 0
        let versionSubscription = model.$contentVersion.dropFirst().sink { _ in redundantPublications += 1 }
        let healthSubscription = model.$modelFailure.dropFirst().sink { _ in redundantPublications += 1 }
        let backupSubscription = model.$effectiveBackupEnabled.dropFirst().sink { _ in redundantPublications += 1 }
        model.refreshSlow()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        precondition(redundantPublications == 0, "Unchanged refresh must not publish identical view state")
        withExtendedLifetime((versionSubscription, healthSubscription, backupSubscription)) {}
        let dates = (0..<1000).map { Date(timeIntervalSince1970: Double($0 * 600)) }
        let baselineStart = ProcessInfo.processInfo.systemUptime
        let baseline = dates.map { date in
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            return formatter.string(from: date)
        }
        let baselineTime = ProcessInfo.processInfo.systemUptime - baselineStart
        let cachedStart = ProcessInfo.processInfo.systemUptime
        let cached = dates.map { model.timeLabel($0) }
        let cachedTime = ProcessInfo.processInfo.systemUptime - cachedStart
        precondition(baseline == cached, "Formatter reuse must preserve displayed times")
        print("PERF: 1000 row times, new formatter \(baselineTime)s, reused formatter \(cachedTime)s; unchanged publications \(redundantPublications)")
        model.shutdown()
        let view = NSHostingView(rootView: StatusPanel(model: model).environment(\.colorScheme, .dark))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 640), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view
        window.orderFront(nil)
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
            window.layoutIfNeeded()
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
            "Continuous scrolling must reach all history; got \(model.timelineLimit), document \(document.bounds), visible \(scroll.contentView.bounds), current document \(String(describing: scroll.documentView?.bounds)), attached \(scroll.window != nil)")
        advance()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        precondition(model.timelineLimit == 120, "The end must not load beyond the available history")
        let clipboard = NSPasteboard.general.string(forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let clipboard { NSPasteboard.general.setString(clipboard, forType: .string) }
        }
        let allItems = model.timelineGroups.flatMap(\.items)
        model.timelineLimit = 12
        model.toggleSummarySelection()
        model.selectSummary(allItems.first!); model.selectSummary(allItems.last!)
        model.copySelectedSummaries()
        let copied = NSPasteboard.general.string(forType: .string)!
        precondition(copied.contains("整理项目文档 1\n") && copied.contains("整理项目文档 120\n"))
        precondition(!copied.contains("整理项目文档 2\n"), "Copy must include selected entries across pages, without unselected entries")
        let memoryDirectory = root.appendingPathComponent("memories")
        try! FileManager.default.createDirectory(at: memoryDirectory, withIntermediateDirectories: true)
        let memory = memoryDirectory.appendingPathComponent("2020-01-01T10-00-00Z-ABCD-10min-memory-summary.md")
        try! "---\ntitle: Synthetic\ndescription: Counts\n---\n## Memory summary\n### 本次活动\n- **迁移示例项目**：保留提交历史，核对目标目录。\n- **查看压缩结果**：核对初测数据，再检查迁移后的测试结果。\n- **查看天气**：短暂查看天气页面。\n- **阅读示例论文**：核对研究方法与实验结果。".write(to: memory, atomically: true, encoding: .utf8)
        var activity = ActivityNarrative.Item(id: "shared-source", timestamp: Date(), title: "迁移示例项目", summary: "核对迁移目录与测试结果。", apps: [], sourceMemories: [memory.lastPathComponent])
        activity.sourceActivities = [memory.lastPathComponent: [1, 2, 3]]
        activity.sourceSteps = [memory.lastPathComponent: [2]]
        activity.sourceIncidental = [memory.lastPathComponent: [3]]
        var paper = ActivityNarrative.Item(id: "paper", timestamp: activity.timestamp, title: "阅读示例论文", summary: "核对研究方法与实验结果。", apps: [], sourceMemories: [memory.lastPathComponent])
        paper.sourceActivities = [memory.lastPathComponent: [4]]
        try! ActivityNarrative(items: [activity, paper]).save(root: root)
        let detailsModel = StatusModel(root: root)
        defer { detailsModel.shutdown() }
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        let row = detailsModel.timelineGroups.flatMap(\.items).first!
        precondition(row.children?.count == 2, "Same-time activities must share one container")
        detailsModel.copySummary(of: row)
        let groupCopy = NSPasteboard.general.string(forType: .string)!
        precondition(groupCopy.contains("迁移示例项目") && groupCopy.contains("阅读示例论文"), "Copy must retain all folded activities")
        detailsModel.toggleExpanded(row.id)
        let details = NSHostingView(rootView: TimelineRow(item: row, model: detailsModel).padding(8).frame(width: 380))
        window.contentView = details
        window.setContentSize(NSSize(width: 380, height: 620))
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        details.layoutSubtreeIfNeeded()
        precondition(details.fittingSize.height > 180, "Expanded interval must show its child activities")
        if let directory = ProcessInfo.processInfo.environment["COMPUTER_HISTORY_TEST_SCREENSHOTS"] {
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-l", String(window.windowNumber), URL(fileURLWithPath: directory).appendingPathComponent("source-activity-details.png").path]
            try! capture.run()
            capture.waitUntilExit()
            precondition(capture.terminationStatus == 0, "Synthetic window capture failed")
        }
        let aside = ActivityFragment.details(files: [memory], activities: activity.sourceIncidental)
        let disclosure = NSHostingView(rootView: IncidentalActivities(details: aside, count: 1, collapsible: true).padding(14).frame(width: 340))
        window.contentView = disclosure
        window.setContentSize(NSSize(width: 340, height: disclosure.fittingSize.height))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let collapsedHeight = disclosure.fittingSize.height
        nativeTestClick(window: window, point: NSPoint(x: 250, y: window.contentLayoutRect.height / 2))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        precondition(disclosure.fittingSize.height > collapsedHeight + 20, "The incidental row must expand when clicking beyond its text")
        window.orderOut(nil)
        print("PASS: bounded initial page, no loading near the top, incremental loading through 120 records, stable end, and selected copy across pages")
    }
}
