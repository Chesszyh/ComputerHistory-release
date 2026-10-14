import Foundation
import Combine
import AppKit
import ComputerHistoryCore

/// 托盘应用的状态源。
///
/// 分两个刷新节奏：当前活动每秒更新（跟随前台应用），
/// 采集状态与记忆索引每 10 秒更新（读磁盘，没必要更频繁）。
@MainActor
final class StatusModel: ObservableObject {

    /// 此刻的前台应用与窗口。
    @Published private(set) var frontApp: String = "—"
    @Published private(set) var frontBundleID: String?
    @Published private(set) var frontWindow: String?
    @Published private(set) var frontSince: Date = Date()
    /// 采集器最近一次写入事件的时间。
    @Published private(set) var lastEventAt: Date?

    @Published private(set) var status: CollectorStatus
    @Published private(set) var memories: MemoryIndex
    /// 第三层：面向扫读的叙述条目。为空时时间线回退到记忆标题。
    @Published private(set) var narrative: ActivityNarrative

    /// 运行状态区的展开状态。默认收起——它是排查用的，不是日常要看的信息。
    @Published var showsRuntimeDetails = false
    /// 运行开关（记录 / 总结）。
    @Published private(set) var control: CollectorControl
    /// 登录自启动是否已登记。
    @Published private(set) var loginItemEnabled: Bool
    /// 设置区展开状态。
    @Published var showsSettings = false
    /// 刚复制过的那一条。按条目记录——共用一个布尔会让所有行同时显示对勾。
    @Published private(set) var copiedItemID: String?
    /// 刚复制过全文。
    @Published private(set) var copiedDetail = false
    /// 刚请求过立即生成。
    @Published private(set) var flushRequested = false
    /// 侧栏详情。为 nil 时面板保持单栏宽度。
    @Published var detail: DetailContent?
    /// 原地展开概要的行 id 集合。
    @Published var expandedRows: Set<String> = []
    /// 时间线展示条数上限，避免菜单过长。
    @Published var timelineLimit = 12

    private var cancellables = Set<AnyCancellable>()
    private let root: URL

    init(root: URL = CollectorStatus.defaultRoot) {
        self.root = root
        self.status = CollectorStatus.read(root: root)
        self.memories = MemoryIndex.load(from: root.appendingPathComponent("memories"))
        self.narrative = ActivityNarrative.load(root: root)
        self.control = CollectorControl.load(root: root)
        self.loginItemEnabled = LoginItem.isEnabled
        startTimers()
    }

    private func startTimers() {
        // 当前活动：每秒一次，只读 AX 的聚焦窗口，开销很小。
        Timer.publish(every: 1, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.refreshLive() }
            .store(in: &cancellables)

        // 采集状态与记忆：每 10 秒一次。
        Timer.publish(every: 10, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.refreshSlow() }
            .store(in: &cancellables)
    }

    func refreshLive() {
        let app = FrontmostApplication.current()
        let bundle = app?.bundleIdentifier
        if bundle != frontBundleID {
            frontBundleID = bundle
            frontSince = Date()
        }
        frontApp = app?.name ?? app?.bundleIdentifier ?? "—"
        frontWindow = FrontmostApplication.frontWindow(for: app)?.title
    }

    func refreshSlow() {
        status = CollectorStatus.read(root: root)
        memories = MemoryIndex.load(from: root.appendingPathComponent("memories"))
        narrative = ActivityNarrative.load(root: root)
        lastEventAt = status.data.lastWriteAt
        // 开关可能被命令行或另一个托盘实例改动，随慢速刷新一并对齐。
        control = CollectorControl.load(root: root)
        loginItemEnabled = LoginItem.isEnabled
    }

    func refreshAll() {
        refreshLive()
        refreshSlow()
    }

    // MARK: - 菜单栏图标

    /// 图标反映采集状态：正常、停滞、未运行。
    var menuBarSymbol: String {
        if !status.process.running { return "clock.badge.xmark" }
        if status.isStalled { return "clock.badge.exclamationmark" }
        return "clock.arrow.circlepath"
    }

    var stateLabel: String {
        if !status.process.running { return "未采集" }
        if status.isStalled { return "已停滞" }
        return "采集中"
    }

    var stateColor: StatusColor {
        if !status.process.running { return .secondary }
        if status.isStalled { return .warning }
        return .ok
    }

    enum StatusColor { case ok, warning, secondary }

    // MARK: - 展示辅助

    /// 「3 秒前」这类相对时间。
    func relativeLabel(_ date: Date?) -> String {
        guard let date else { return "—" }
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 5 { return "刚刚" }
        if seconds < 60 { return "\(seconds) 秒前" }
        if seconds < 3600 { return "\(seconds / 60) 分钟前" }
        if seconds < 86400 { return "\(seconds / 3600) 小时前" }
        return "\(seconds / 86400) 天前"
    }

    /// 当前窗口已持续多久。
    var frontDurationLabel: String {
        relativeLabel(frontSince).replacingOccurrences(of: "前", with: "")
    }

    /// 时间线的一条，已归一为展示形态。
    struct TimelineItem: Identifiable {
        var id: String
        var timestamp: Date
        var title: String
        var summary: String
        var apps: [String]
        /// 是否来自模型归纳的叙述层。
        var isNarrative: Bool
        /// 该条覆盖的记忆文件。叙述条目可能覆盖多份，故为列表。
        var memoryFiles: [URL]
        /// 覆盖的段数。叙述条目合并多段时会大于 1。
        var coveredCount: Int
        /// 事件数；叙述条目不带该信息，为 nil。
        var eventCount: Int?
        /// 覆盖范围里最后一段的起始时刻。
        ///
        /// 合并条目横跨多段，只显示起始时刻会让后续时段看起来像丢了——
        /// 实测 17:20 的条目覆盖到 17:40，但下一条显示 17:50，
        /// 使用者会以为 17:30 与 17:40 没有被总结。
        var endTimestamp: Date

        /// 是否有可展开的详情。
        var hasDetail: Bool { !memoryFiles.isEmpty }
    }

    /// 侧栏详情的数据。
    struct DetailContent: Identifiable {
        var id: String
        var title: String
        var timestamp: Date
        var apps: [String]
        var files: [MemoryFile]

        struct MemoryFile: Identifiable {
            var id: String { url.lastPathComponent }
            var url: URL
            var title: String
            var granularity: String
            var sections: [(heading: String, content: String)]
        }
    }

    /// 时间线按天分组。
    ///
    /// **先把叙述层与记忆层按天合并、排序，最后才截断**。此前的顺序是
    /// 「先填叙述、填满即止，再补没有叙述的天」，结果是昨天的叙述占满上限后
    /// 今天的记录完全不可见，同一天里未被叙述覆盖的记忆也看不到。
    var timelineGroups: [(day: String, items: [TimelineItem])] {
        // ① 两层的条目都归到各自的日期，便于合并。
        var byDay: [String: [TimelineItem]] = [:]
        var narrativeCovered: Set<String> = []

        for group in narrative.groupedByDay() {
            for item in group.items {
                let files = item.sourceMemories.compactMap { memoryURL(for: $0) }
                for name in item.sourceMemories { narrativeCovered.insert(name) }
                byDay[group.day, default: []].append(TimelineItem(
                    id: item.id, timestamp: item.timestamp, title: item.title,
                    summary: item.summary, apps: item.apps,
                    isNarrative: true, memoryFiles: files,
                    coveredCount: max(1, item.sourceMemories.count),
                    eventCount: nil,
                    endTimestamp: item.sourceMemories
                        .compactMap { Self.segmentTime(fromMemoryName: $0) }.max()
                        ?? item.timestamp))
            }
        }
        // ② 记忆层补齐叙述未覆盖的段——不是「没有叙述的天」才补。
        for group in memories.groupedByDay() {
            for entry in group.entries where !narrativeCovered.contains(entry.id) {
                let exists = FileManager.default.fileExists(atPath: entry.fileURL.path)
                byDay[group.day, default: []].append(TimelineItem(
                    id: entry.id, timestamp: entry.startedAt, title: entry.title,
                    summary: entry.summary, apps: entry.applications,
                    isNarrative: false,
                    memoryFiles: exists ? [entry.fileURL] : [],
                    coveredCount: 1, eventCount: nil,
                    endTimestamp: entry.startedAt))
            }
        }

        // ③ 每天内部按时间倒序，天与天之间也倒序。
        let days = byDay.keys.sorted(by: >)
        var result: [(day: String, items: [TimelineItem])] = []
        var remaining = timelineLimit
        for day in days {
            guard remaining > 0 else { break }
            let sorted = byDay[day]!.sorted { $0.timestamp > $1.timestamp }
            let taken = Array(sorted.prefix(remaining))
            remaining -= taken.count
            result.append((day, taken))
        }
        return result
    }

    /// 从记忆文件名解析出所属段的起始时刻。
    ///
    /// 文件名形如 `2026-10-14T09-30-00Z-XXXX-10min-memory-summary.md`；
    /// 用固定宽度截取而不是按 `-` 切分——基准段与带 UUID 后缀的段前缀相同，
    /// 切分得到的段数不一致。
    static func segmentTime(fromMemoryName name: String) -> Date? {
        guard name.count >= 20 else { return nil }
        let stamp = String(name.prefix(20))          // 2026-10-14T09-30-00Z
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: stamp)
    }

    func memoryURL(for fileName: String?) -> URL? {
        guard let fileName else { return nil }
        let url = root.appendingPathComponent("memories").appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func dayLabel(_ day: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        guard let date = f.date(from: day) else { return day }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "今天" }
        if cal.isDateInYesterday(date) { return "昨天" }
        let out = DateFormatter()
        out.dateFormat = "M 月 d 日"
        out.locale = Locale(identifier: "zh_CN")
        return out.string(from: date)
    }

    // MARK: - 动作

    func openDataDirectory() {
        NSWorkspace.shared.open(root)
    }

    func openLog() {
        let log = root.appendingPathComponent("collector.log")
        if FileManager.default.fileExists(atPath: log.path) {
            NSWorkspace.shared.open(log)
        }
    }

    func open(url: URL) {
        NSWorkspace.shared.open(url)
    }

    // MARK: - 复制

    /// 复制一条活动记录的标题与摘要。
    ///
    /// 不带时刻与来源——贴给别人时那两项是噪声，需要时侧栏里有完整文档可复制。
    func copySummary(of item: TimelineItem) {
        writeToPasteboard("\(item.title)\n\n\(item.summary)")
        copiedItemID = item.id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            if copiedItemID == item.id { copiedItemID = nil }
        }
    }

    /// 复制某条记录对应的记忆文档全文（含分节标题）。
    func copyDetail() {
        guard let detail = detail else { return }
        var parts: [String] = []
        for file in detail.files {
            if detail.files.count > 1 { parts.append("# \(file.title)") }
            for section in file.sections {
                parts.append("## \(section.heading)")
                parts.append(section.content)
            }
        }
        writeToPasteboard(parts.joined(separator: "\n\n"))
        copiedDetail = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            copiedDetail = false
        }
    }

    /// 复制一天的全部活动记录。
    func copyDay(_ day: String, items: [TimelineItem]) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        let body = items.map { "[\(f.string(from: $0.timestamp))] \($0.title)\n\($0.summary)" }
            .joined(separator: "\n\n")
        writeToPasteboard("\(day)\n\n\(body)")
    }

    private func writeToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// 请求监督进程立即跑一轮生成。
    ///
    /// 托盘不自己调用模型——密钥在监督进程的环境里，且生成任务已有一套串行与
    /// 批量控制。这里只置一个标记，由监督进程消费。
    func requestFlush() {
        do {
            try CollectorControl.update(root: root, flushRequested: true)
        } catch {
            NSLog("写入立即生成请求失败：\(error)")
            return
        }
        flushRequested = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            flushRequested = false
        }
    }

    // MARK: - 运行开关

    /// 修改记录开关。写入失败时回读磁盘上的真实值，不留下与实际不符的界面状态。
    func setRecording(_ enabled: Bool) {
        do {
            try CollectorControl.update(root: root, recording: enabled)
        } catch {
            NSLog("写入运行开关失败：\(error)")
        }
        control = CollectorControl.load(root: root)
    }

    func setSummarizing(_ enabled: Bool) {
        do {
            try CollectorControl.update(root: root, summarizing: enabled)
        } catch {
            NSLog("写入运行开关失败：\(error)")
        }
        control = CollectorControl.load(root: root)
    }

    /// 登记或取消登录自启动。
    func setLoginItem(_ enabled: Bool) {
        if enabled {
            guard let exe = CollectorSupervisor.currentExecutablePath() else { return }
            try? LoginItem.enable(executablePath: exe)
        } else {
            LoginItem.disable()
        }
        loginItemEnabled = LoginItem.isEnabled
    }

    // MARK: - 行内展开与侧栏详情

    /// 切换某一行的概要展开状态。展开的内容留在原地，不改变布局层级。
    func toggleExpanded(_ id: String) {
        if expandedRows.contains(id) { expandedRows.remove(id) }
        else { expandedRows.insert(id) }
    }

    func isExpanded(_ id: String) -> Bool { expandedRows.contains(id) }

    /// 在侧栏打开该条对应的记忆文档。
    ///
    /// 读本地文件并解析分节，不调用外部程序——此前是交给默认 Markdown 阅读器，
    /// 每看一次就多开一个软件。
    func openDetail(for item: TimelineItem) {
        let files = item.memoryFiles.compactMap(Self.parseMemoryFile)
        guard !files.isEmpty else { return }
        detail = DetailContent(id: item.id, title: item.title,
                               timestamp: item.timestamp, apps: item.apps,
                               files: files)
    }

    func closeDetail() { detail = nil }

    /// 解析记忆文件为可分节渲染的形态。
    static func parseMemoryFile(_ url: URL) -> DetailContent.MemoryFile? {
        guard let entry = MemoryIndex.parse(fileURL: url) else { return nil }
        return DetailContent.MemoryFile(
            url: url, title: entry.title, granularity: entry.granularity,
            sections: entry.sections)
    }

    func copyRecentSummary() {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        let text = timelineGroups.flatMap(\.items).prefix(20)
            .map { "[\(f.string(from: $0.timestamp))] \($0.title)\n\($0.summary)" }
            .joined(separator: "\n\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
