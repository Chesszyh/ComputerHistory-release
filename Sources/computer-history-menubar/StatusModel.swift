import Foundation
import Combine
import AppKit
import ApplicationServices
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
    @Published private(set) var timelineCount = 0
    @Published private(set) var modelRequests: [ModelRequest] = []
    @Published var showsUsage = false
    @Published var requestDetail: ModelRequest?
    @Published var requestError: String?
    @Published var usageFilter = ModelRequestFilter()
    @Published var expandedRequestGroups: Set<String> = []
    @Published var showsSummarySettings = false
    @Published var summaryStage: SummarySettings.Stage = .tenMinute
    @Published var summaryDraft = ""
    @Published var summaryMessage: String?
    @Published var summarySettingsError: String?
    private let requestLoader = ModelRequestLoader()

    private var contentVersion = 0
    @Published private(set) var timelineGroups: [TrayTimelineGroup] = []
    private var allTimelineGroups: [TrayTimelineGroup] = []

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
    @Published var timelineLimit = 12 { didSet { applyTimelineLimit() } }

    private var cancellables = Set<AnyCancellable>()
    private let root: URL
    private let loader = TraySnapshotLoader()
    private var refreshTask: Task<Void, Never>?
    private var refreshState = TrayRefreshState()
    private var liveTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var detailRequest = UUID()
    private var stopped = false

    init(root: URL = CollectorStatus.defaultRoot) {
        self.root = root
        self.status = .empty(root: root)
        self.control = CollectorControl()
        self.loginItemEnabled = LoginItem.isEnabled
        startTimers()
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.shutdown() } }
            .store(in: &cancellables)
        refreshAll()
    }

    private func startTimers() {
        // 前台身份留在主线程，跨进程窗口查询由后台 actor 完成。
        Timer.publish(every: 1, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.refreshLive() }
            .store(in: &cancellables)

        // 采集状态与记忆：每 10 秒一次。
        Timer.publish(every: 10, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.refreshSlow() }
            .store(in: &cancellables)
    }

    func refreshLive() {
        guard !stopped, liveTask == nil else { return }
        let app = FrontmostApplication.current()
        let bundle = app?.bundleIdentifier
        let name = AwayPeriods.isLoginWindow(app) ? "离开电脑" : (app?.name ?? bundle ?? "—")
        if bundle != frontBundleID {
            frontBundleID = bundle
            frontSince = Date()
        }
        if name != frontApp { frontApp = name }
        if AwayPeriods.isLoginWindow(app) { frontWindow = "登录界面 · 暂停采集"; return }
        let pid = app?.processIdentifier
        liveTask = Task { [weak self] in
            let window = await TrayWindowReader.shared.read(pid: pid)
            guard let self else { return }
            self.liveTask = nil
            guard !self.stopped, FrontmostApplication.current()?.processIdentifier == pid else { return }
            if self.frontWindow != window?.title { self.frontWindow = window?.title }
        }
    }

    func refreshSlow() {
        guard !stopped, refreshState.request() else { return }
        startLoad()
    }

    private func startLoad() {
        let root = root, loader = loader
        refreshTask = Task { [weak self] in
            let snapshot = await loader.load(root: root)
            let requests = await self?.requestLoader.load(root: root) ?? []
            guard let self, !self.stopped else { return }
            if self.modelRequests != requests { self.modelRequests = requests }
            if self.status != snapshot.status { self.status = snapshot.status }
            if self.control != snapshot.control { self.control = snapshot.control }
            self.contentVersion = snapshot.contentVersion
            let count = snapshot.groups.reduce(0) { $0 + $1.items.count }
            if self.timelineCount != count { self.timelineCount = count }
            if self.allTimelineGroups != snapshot.groups {
                self.allTimelineGroups = snapshot.groups
                self.applyTimelineLimit()
                let ids = Set(snapshot.groups.flatMap(\.items).map(\.id))
                self.expandedRows.formIntersection(ids)
                if let detail = self.detail, !ids.contains(detail.id) { self.closeDetail() }
            }
            if self.lastEventAt != snapshot.status.data.lastWriteAt { self.lastEventAt = snapshot.status.data.lastWriteAt }
            let login = LoginItem.isEnabled
            if self.loginItemEnabled != login { self.loginItemEnabled = login }
            self.refreshTask = nil
            if self.refreshState.finished() { self.startLoad() }
        }
    }

    private func applyTimelineLimit() {
        var remaining = timelineLimit
        var visible: [TrayTimelineGroup] = []
        for group in allTimelineGroups where remaining > 0 {
            let items = Array(group.items.prefix(remaining))
            remaining -= items.count
            visible.append(TrayTimelineGroup(day: group.day, items: items))
        }
        if timelineGroups != visible { timelineGroups = visible }
    }

    func shutdown() {
        stopped = true
        refreshState.cancel()
        refreshTask?.cancel()
        liveTask?.cancel()
        detailTask?.cancel()
        cancellables.removeAll()
    }

    func refreshAll() {
        refreshLive()
        refreshSlow()
    }

    // MARK: - 菜单栏图标

    var isStalled: Bool {
        status.isStalled && control.recording && frontBundleID != "com.apple.loginwindow"
    }

    /// 图标反映采集状态：正常、停滞、未运行。
    var menuBarSymbol: String {
        if !status.process.running { return "clock.badge.xmark" }
        if !control.recording || frontBundleID == "com.apple.loginwindow" { return "pause.circle" }
        if isStalled { return "clock.badge.exclamationmark" }
        return "clock.arrow.circlepath"
    }

    var stateLabel: String {
        if !status.process.running { return "未采集" }
        if !control.recording { return "已暂停" }
        if frontBundleID == "com.apple.loginwindow" { return "已离开" }
        if isStalled { return "已停滞" }
        return "采集中"
    }

    var stateColor: StatusColor {
        if !status.process.running { return .secondary }
        if !control.recording || frontBundleID == "com.apple.loginwindow" { return .secondary }
        if isStalled { return .warning }
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

    typealias TimelineItem = TrayTimelineItem

    /// 侧栏详情的数据。
    struct DetailContent: Identifiable, Sendable {
        var id: String
        var title: String
        var timestamp: Date
        var apps: [String]
        var files: [MemoryFile]

        struct MemoryFile: Identifiable, Sendable {
            var id: String { url.lastPathComponent }
            var url: URL
            var title: String
            var granularity: String
            var sections: [(heading: String, content: String)]
        }
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
        detailTask?.cancel()
        let request = UUID()
        detailRequest = request
        detail = nil
        let version = contentVersion
        detailTask = Task { [weak self] in
            let files = await Task.detached(priority: .userInitiated) {
                item.memoryFiles.compactMap { url -> DetailContent.MemoryFile? in
                    guard let entry = MemoryIndex.parse(fileURL: url) else { return nil }
                    return DetailContent.MemoryFile(url: url, title: entry.title,
                        granularity: entry.granularity, sections: entry.sections)
                }
            }.value
            guard let self, !self.stopped, !Task.isCancelled,
                  self.detailRequest == request, self.contentVersion == version, !files.isEmpty else { return }
            self.detail = DetailContent(id: item.id, title: item.title,
                timestamp: item.timestamp, apps: item.apps, files: files)
            self.detailTask = nil
        }
    }

    func openRequest(_ record: ModelRequest) {
        detailTask?.cancel()
        let url = root.appendingPathComponent("requests/" + record.id + ".json")
        let request = UUID()
        detailRequest = request
        requestError = nil
        detailTask = Task { [weak self] in
            let result = await Task.detached { () -> Result<ModelRequest, Error> in
                Result { try ModelRequest.load(url: url) }
            }.value
            guard let self, !self.stopped, !Task.isCancelled, self.detailRequest == request else { return }
            switch result {
            case .success(let value): self.requestDetail = value
            case .failure(let error): self.requestError = "读取请求失败：\(error.localizedDescription)"
            }
            self.detailTask = nil
        }
    }

    func closeUsage() {
        detailRequest = UUID()
        detailTask?.cancel()
        detailTask = nil
        requestDetail = nil
        showsUsage = false
    }

    func openSummarySettings() {
        loadSummaryDraft()
        showsSummarySettings = true
    }

    func loadSummaryDraft() {
        summaryMessage = nil
        summarySettingsError = nil
        do { summaryDraft = try SummarySettings.load(root: root)[summaryStage] }
        catch {
            summaryDraft = ""
            summarySettingsError = String(describing: error)
        }
    }

    func saveSummaryDraft() {
        do {
            var settings = try SummarySettings.load(root: root)
            settings[summaryStage] = summaryDraft
            try settings.save(root: root)
            summarySettingsError = nil
            summaryMessage = "已保存，后续生成任务生效"
        } catch { summarySettingsError = String(describing: error); summaryMessage = nil }
    }

    func openConfiguration(_ name: String) {
        let file = root.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: file.path) {
            if !NSWorkspace.shared.open(file) { summarySettingsError = "无法打开 \(name)，请从数据目录中选择编辑器打开。" }
        } else {
            summarySettingsError = "\(name) 尚不存在，可在数据目录中按采集说明创建。"
            NSWorkspace.shared.open(root)
        }
    }

    func closeDetail() {
        detailRequest = UUID()
        detailTask?.cancel()
        detailTask = nil
        detail = nil
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

/// 默认 AX 超时在本托盘进程生效；AX 对象在此后台 actor 内创建和使用。
private actor TrayWindowReader {
    static let shared = TrayWindowReader()
    func read(pid: Int32?) -> EventStreamWindow? {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.2)
        return FrontmostApplication.window(pid: pid)
    }
}
