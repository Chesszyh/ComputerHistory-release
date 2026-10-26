import Foundation
import Combine
import AppKit
import ApplicationServices
import ComputerHistoryCore

/// 托盘应用的状态源。
///
/// 分两个刷新节奏：当前活动每秒更新（跟随前台应用），
/// 采集状态与记忆索引由后台加载器定期刷新。
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
    @Published var showsReports = false
    @Published var reportKind: ReportKind = .daily
    @Published var reportDate = Date()
    @Published private(set) var reportText = ""
    @Published private(set) var reportMaterial = ""
    @Published private(set) var reportBusy = false
    @Published var reportMessage: String?
    @Published var reportError: String?
    @Published private(set) var effectiveBackupEnabled = false
    @Published var backupRepository = ""
    @Published var backupEnabled = false
    @Published private(set) var backupLoaded = false
    @Published private(set) var backupMessage = ""
    private var reportTask: Task<Void, Never>?
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
    enum SettingsTab: String, CaseIterable { case timeline = "时间线", prompts = "提示词", model = "模型", collector = "采集", backup = "备份" }
    enum TimelineRecalculation: CaseIterable {
        case today, all, none
        var label: String {
            switch self { case .today: return "重算当天总结"; case .all: return "重算所有总结"; case .none: return "不重算" }
        }
        func arguments(now: Date = Date()) -> [String] {
            guard self != .none else { return [] }
            return ["narrative", "--overwrite", "--wait-lock"] + (self == .today ? ["--day", ReportPeriod.day(now)] : [])
        }
    }
    @Published private var effectiveTimelineMode: SummarySettings.TimelineMode = .continuous
    @Published var timelineMode: SummarySettings.TimelineMode = .continuous
    @Published var showsTimelineRecalculation = false
    @Published private(set) var timelineSettingsLoaded = false
    @Published private(set) var timelineRebuilding = false
    @Published var timelineSettingsMessage: String?
    @Published var timelineSettingsError: String?
    private var timelineTask: Task<Void, Never>?
    @Published var settingsTab: SettingsTab = .prompts
    @Published var modelGroups: [ModelGroupDraft] = []
    @Published var editingGroupID = ""
    @Published var primaryGroupID = ""
    @Published var fallbackGroupID = ""
    @Published var dailyBudget = ""
    @Published var monthlyBudget = ""
    @Published var isSelectingSummaries = false
    @Published var selectedSummaryIDs: Set<String> = []
    @Published var editingSummary: TimelineItem?
    @Published var editedTitle = ""
    @Published var editedSummary = ""
    @Published var editError: String?
    @Published var selectionMessage: String?
    @Published var timelineError: String?
    @Published var showsTrash = false
    @Published private(set) var deletedSummaries: [TimelineDeletions.Record] = []
    @Published var collectorDraft = CollectorSettingsDraft()
    @Published private(set) var modelFailure: String?
    @Published var modelSettingsError: String?
    @Published var collectorSettingsError: String?
    @Published var modelSettingsMessage: String?
    @Published var collectorSettingsMessage: String?
    @Published private(set) var modelConfigurationLoaded = false
    @Published private(set) var collectorConfigurationLoaded = false
    private let requestLoader = ModelRequestLoader()

    @Published private(set) var contentVersion = 0
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
    private let commandExecutable: URL
    private let loader = TraySnapshotLoader()
    private var refreshTask: Task<Void, Never>?
    private var refreshState = TrayRefreshState()
    private var liveTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var detailRequest = UUID()
    private var stopped = false

    init(root: URL = CollectorStatus.defaultRoot, commandExecutable: URL? = nil) {
        self.root = root
        self.commandExecutable = commandExecutable ?? URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("computer-history")
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

        // 采集状态与记忆在后台刷新，复用未变化文件的缓存。
        Timer.publish(every: 3, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.refreshSlow() }
            .store(in: &cancellables)
    }

    func refreshLive() {
        guard !stopped, control.recording, liveTask == nil else { return }
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
            guard !self.stopped, self.control.recording, FrontmostApplication.current()?.processIdentifier == pid else { return }
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
            let health = await Task.detached { ModelHealth.load(root: root) }.value
            let enabled = await Task.detached { (try? BackupSettings.load(root: root))?.enabled ?? false }.value
            guard let self, !self.stopped else { return }
            if self.modelFailure != health?.error { self.modelFailure = health?.error }
            if self.effectiveBackupEnabled != enabled { self.effectiveBackupEnabled = enabled }
            if self.modelRequests != requests { self.modelRequests = requests }
            if self.status != snapshot.status { self.status = snapshot.status }
            if self.control != snapshot.control { self.control = snapshot.control }
            if self.contentVersion != snapshot.contentVersion { self.contentVersion = snapshot.contentVersion }
            if self.effectiveTimelineMode != snapshot.timelineMode { self.effectiveTimelineMode = snapshot.timelineMode }
            if self.deletedSummaries != snapshot.deletedSummaries { self.deletedSummaries = snapshot.deletedSummaries }
            let count = snapshot.groups.reduce(0) { $0 + $1.items.count }
            if self.timelineCount != count { self.timelineCount = count }
            if self.allTimelineGroups != snapshot.groups {
                self.allTimelineGroups = snapshot.groups
                self.applyTimelineLimit()
                let ids = Set(snapshot.groups.flatMap(\.items).map(\.id))
                self.expandedRows.formIntersection(ids)
                self.selectedSummaryIDs.formIntersection(ids)
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
        reportTask?.cancel()
        timelineTask?.cancel()
        cancellables.removeAll()
    }

    func refreshAll() {
        refreshLive()
        refreshSlow()
    }

    func openReports() {
        showsReports = true
        loadReports()
    }

    func loadReports() {
        guard !reportBusy else { return }
        let root = root, period = ReportPeriod(kind: reportKind, date: reportDate)
        reportBusy = true; reportError = nil; reportMessage = nil
        reportTask = Task { [weak self] in
            let result = await Task.detached { () -> (String, String, BackupSettings?, BackupStatus, String?) in
                do {
                    let settings = try BackupSettings.load(root: root)
                    let report = try ActivityReport.load(root: root, period: period)
                    let material = (try? ActivityExport.aiMaterial(root: root, period: period)) ?? ""
                    return (report?.markdown ?? "", material, settings, BackupStatus.load(root: root), nil)
                } catch { return ("", "", nil, BackupStatus.load(root: root), String(describing: error)) }
            }.value
            guard let self, !self.stopped else { return }
            self.reportText = result.0; self.reportMaterial = result.1
            self.backupRepository = result.2?.repository ?? ""
            self.backupEnabled = result.2?.enabled ?? false
            self.backupLoaded = result.4 == nil
            self.reportError = result.4
            if let error = result.3.error { self.backupMessage = error }
            else if let date = result.3.lastSuccess {
                self.backupMessage = "最近备份：" + date.formatted(date: .abbreviated, time: .shortened)
            } else { self.backupMessage = "尚无成功备份" }
            self.reportBusy = false
        }
    }

    func generateReport() {
        runReportCommand(["report", "--kind", reportKind.rawValue, "--day", ReportPeriod.day(reportDate), "--overwrite"], message: "报告已生成")
    }

    func runReportCommand(_ arguments: [String], message: String) {
        guard !reportBusy else { return }
        let root = root
        let binary = commandExecutable
        reportBusy = true; reportError = nil; reportMessage = nil
        reportTask = Task { [weak self] in
            let error = await Task.detached { () -> String? in
                do {
                    try LocalCommand.run(binary.path, arguments + ["--out", root.path], timeout: 1800)
                    return nil
                } catch { return String(describing: error) }
            }.value
            guard let self, !self.stopped else { return }
            self.reportBusy = false
            if let error { self.reportError = error }
            else {
                self.loadReports()
                self.reportMessage = message
            }
        }
    }

    func copyReport(material: Bool) {
        let text = material ? reportMaterial : reportText
        guard !text.isEmpty else { return }
        writeToPasteboard(text)
        reportMessage = material ? "已复制给 AI 的材料" : "已复制报告"
    }

    func saveReport(to url: URL, material: Bool) {
        do {
            try ActivityExport.write(ActivityExport.formatted(material ? reportMaterial : reportText, format: url.pathExtension), to: url)
            reportMessage = "已导出 \(url.lastPathComponent)"; reportError = nil
        } catch { reportError = String(describing: error) }
    }

    func setBackupEnabled(_ enabled: Bool) {
        do {
            guard var settings = try BackupSettings.load(root: root) else {
                settingsTab = .backup; openSummarySettings()
                reportError = "请先填写独立的 GitHub 私有仓库。"
                return
            }
            settings.enabled = enabled; try settings.save(root: root)
            effectiveBackupEnabled = enabled; backupEnabled = enabled
        } catch {
            settingsTab = .backup; openSummarySettings(); reportError = String(describing: error)
        }
    }

    private func loadBackupSettings() {
        do {
            let settings = try BackupSettings.load(root: root)
            backupRepository = settings?.repository ?? ""; backupEnabled = settings?.enabled ?? false
            effectiveBackupEnabled = backupEnabled; backupLoaded = true
            let status = BackupStatus.load(root: root)
            backupMessage = status.error ?? status.lastSuccess.map { "最近备份：" + $0.formatted(date: .abbreviated, time: .shortened) } ?? "尚无成功备份"
        } catch { backupLoaded = false; reportError = String(describing: error) }
    }

    func saveBackupSettings() {
        guard backupLoaded else { return }
        do {
            if backupRepository.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !backupEnabled {
                if var settings = try BackupSettings.load(root: root) { settings.enabled = false; try settings.save(root: root) }
            } else {
                try BackupSettings(repository: backupRepository.trimmingCharacters(in: .whitespacesAndNewlines), enabled: backupEnabled).save(root: root)
            }
            effectiveBackupEnabled = backupEnabled
            reportMessage = backupEnabled ? "已启用每日私有备份" : "GitHub 备份已关闭"
            reportError = nil
        } catch { reportError = String(describing: error) }
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
    func relativeLabel(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
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

    private static let dayParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        return formatter
    }()
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M 月 d 日"
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .autoupdatingCurrent
        return formatter
    }()
    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        return formatter
    }()

    func timeLabel(_ date: Date) -> String { Self.clockFormatter.string(from: date) }

    func dayLabel(_ day: String) -> String {
        guard let date = Self.dayParser.date(from: day) else { return day }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "今天" }
        if cal.isDateInYesterday(date) { return "昨天" }
        return Self.dayFormatter.string(from: date)
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
        writeToPasteboard(item.leafItems.map { "\($0.title)\n\n\($0.summary)" }.joined(separator: "\n\n"))
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
        let body = items.flatMap(\.leafItems).map { "[\(f.string(from: $0.timestamp))] \($0.title)\n\($0.summary)" }
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
            do { try LoginItem.enable(executablePath: exe) }
            catch {
                let alert = NSAlert()
                alert.messageText = "登录启动设置失败"
                alert.informativeText = String(describing: error)
                alert.runModal()
            }
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
        loadTimelineSettings()
        loadConfigurationDrafts()
        showsSummarySettings = true
    }

    func loadConfigurationDrafts() {
        loadBackupSettings()
        modelSettingsError = nil
        collectorSettingsError = nil
        modelSettingsMessage = nil
        collectorSettingsMessage = nil
        modelConfigurationLoaded = false
        collectorConfigurationLoaded = false
        do {
            let groups = try ModelGroups.load(root: root)
            modelGroups = try groups.groups.map { group in
                var draft = ModelGroupDraft(group)
                if try ModelAPIKey.contains(root: root, groupID: group.id) {
                    draft.hasStoredAPIKey = true
                }
                return draft
            }
            primaryGroupID = groups.primaryGroupID
            fallbackGroupID = groups.fallbackGroupID ?? ""
            editingGroupID = groups.primaryGroupID
            dailyBudget = groups.dailyBudget.map(String.init(describing:)) ?? ""
            monthlyBudget = groups.monthlyBudget.map(String.init(describing:)) ?? ""
            modelConfigurationLoaded = true
        } catch { modelSettingsError = String(describing: error) }
        do {
            collectorDraft = CollectorSettingsDraft(try CollectorConfig.load(rootDirectory: root))
            collectorConfigurationLoaded = true
        }
        catch { collectorSettingsError = String(describing: error) }
    }

    func fetchModelCatalog(groupID: String) {
        guard let index = modelGroups.firstIndex(where: { $0.id == groupID }), !modelGroups[index].catalogLoading else { return }
        modelGroups[index].catalogLoading = true
        modelGroups[index].catalogMessage = nil
        let draft = modelGroups[index]
        let primary = primaryGroupID, fallback = fallbackGroupID, root = root
        Task {
            do {
                guard let url = URL(string: draft.settings.baseURL), ["http", "https"].contains(url.scheme), url.host != nil else {
                    throw ConfigurationInputError.invalid("请先填写完整的服务地址。")
                }
                let key = try await Task.detached {
                    if !draft.settings.requiresAPIKey { return "" }
                    if !draft.apiKey.isEmpty { return draft.apiKey }
                    if !draft.removesAPIKey, let saved = try ModelAPIKey.load(root: root, groupID: draft.id) { return saved }
                    let env = ProcessInfo.processInfo.environment
                    return draft.id == primary ? env["DEEPSEEK_API_KEY"] ?? "" :
                        (draft.id == fallback ? env["COMPUTER_HISTORY_FALLBACK_API_KEY"] ?? "" : "")
                }.value
                let catalog = try await ModelCatalog.fetch(baseURL: url, apiKey: key, allowInsecureHTTP: draft.settings.allowInsecureHTTP)
                guard let current = modelGroups.firstIndex(where: { $0.id == groupID }),
                      modelGroups[current].settings.baseURL == draft.settings.baseURL else {
                    if let current = modelGroups.firstIndex(where: { $0.id == groupID }) { modelGroups[current].catalogLoading = false }
                    return
                }
                var seen: Set<String> = []
                let entries = catalog.data.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
                modelGroups[current].availableModels = entries
                modelGroups[current].manualModel = entries.isEmpty
                modelGroups[current].catalogMessage = entries.isEmpty ? "服务未返回模型，可手动填写。" : "已读取 \(entries.count) 个模型"
                modelGroups[current].catalogLoading = false
                if !entries.isEmpty, modelGroups[current].settings.model.isEmpty { modelGroups[current].settings.model = entries[0].id }
            } catch {
                guard let current = modelGroups.firstIndex(where: { $0.id == groupID }) else { return }
                modelGroups[current].catalogLoading = false
                modelGroups[current].manualModel = true
                modelGroups[current].catalogMessage = "未能读取模型列表，可手动填写：\(error)"
            }
        }
    }

    func apiKeyStatus(for group: ModelGroupDraft) -> String {
        if group.hasStoredAPIKey { return "已保存到系统钥匙串" }
        let environment = ProcessInfo.processInfo.environment
        if group.id == primaryGroupID, environment["DEEPSEEK_API_KEY"]?.isEmpty == false {
            return "当前从主模型环境变量读取密钥"
        }
        if group.id == fallbackGroupID, environment["COMPUTER_HISTORY_FALLBACK_API_KEY"]?.isEmpty == false {
            return "当前从备用模型环境变量读取密钥"
        }
        return "尚未填写密钥"
    }

    func addModelGroup() {
        let group = ModelGroup(name: "新模型组", settings: ModelSettings(
            baseURL: DeepSeekClient.defaultBaseURL, model: DeepSeekClient.defaultModel))
        modelGroups.append(ModelGroupDraft(group))
        editingGroupID = group.id
    }

    func removeEditingModelGroup() {
        guard modelGroups.count > 1, editingGroupID != primaryGroupID, editingGroupID != fallbackGroupID else { return }
        modelGroups.removeAll { $0.id == editingGroupID }
        editingGroupID = primaryGroupID
    }

    func saveModelConfiguration() {
        guard modelConfigurationLoaded else { return }
        do {
            func budget(_ text: String) throws -> Double? {
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
                guard let value = Double(text), value.isFinite, value >= 0 else {
                    throw ConfigurationInputError.invalid("预算请填写非负数字，或留空表示不限制。")
                }
                return value
            }
            let settings = try ModelGroups(groups: modelGroups.map { try $0.value() },
                primaryGroupID: primaryGroupID, fallbackGroupID: fallbackGroupID.isEmpty ? nil : fallbackGroupID,
                dailyBudget: budget(dailyBudget), monthlyBudget: budget(monthlyBudget))
            _ = try settings.resolved()
            for group in modelGroups {
                if !group.apiKey.isEmpty { try ModelAPIKey.save(group.apiKey, root: root, groupID: group.id) }
                else if group.removesAPIKey { try ModelAPIKey.remove(root: root, groupID: group.id) }
            }
            try settings.save(root: root)
            for index in modelGroups.indices {
                if !modelGroups[index].apiKey.isEmpty { modelGroups[index].hasStoredAPIKey = true }
                else if modelGroups[index].removesAPIKey { modelGroups[index].hasStoredAPIKey = false }
                modelGroups[index].apiKey = ""
                modelGroups[index].removesAPIKey = false
            }
            modelSettingsError = nil
            modelSettingsMessage = "已保存，下一次总结使用所选模型组"
        } catch { modelSettingsError = String(describing: error); modelSettingsMessage = nil }
    }

    func deleteTimelineItem(_ item: TimelineItem) {
        guard !item.isAway else { return }
        do {
            try TimelineDeletions.delete(item, root: root)
            expandedRows.remove(item.id)
            timelineError = nil
            refreshAll()
        } catch { timelineError = "删除总结失败：\(error)" }
    }

    func restoreSummary(_ record: TimelineDeletions.Record) {
        do {
            try TimelineDeletions.restore(id: record.id, root: root, item: record.item)
            timelineError = nil
            refreshAll()
        } catch { timelineError = "恢复总结失败：\(error)" }
    }

    func purgeSummary(_ record: TimelineDeletions.Record) {
        do {
            try TimelineDeletions.purge(id: record.id, root: root)
            timelineError = nil
            refreshAll()
        } catch { timelineError = "彻底删除总结失败：\(error)" }
    }

    func saveCollectorConfiguration() {
        guard collectorConfigurationLoaded else { return }
        do {
            let config = try collectorDraft.value()
            try config.jsonData().write(to: CollectorConfig.fileURL(rootDirectory: root), options: .atomic)
            collectorSettingsError = nil
            collectorSettingsMessage = "已保存；运行中的采集器会自动读取"
        } catch { collectorSettingsError = String(describing: error); collectorSettingsMessage = nil }
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

    func loadTimelineSettings() {
        timelineSettingsLoaded = false
        timelineSettingsError = nil
        do {
            timelineMode = try SummarySettings.load(root: root).timelineMode
            timelineSettingsLoaded = true
        } catch { timelineSettingsError = String(describing: error) }
    }

    func saveTimelineSettings() {
        guard timelineSettingsLoaded, !timelineRebuilding else { return }
        do {
            var settings = try SummarySettings.load(root: root)
            settings.timelineMode = timelineMode
            try settings.save(root: root)
            timelineSettingsError = nil
            timelineSettingsMessage = "模式已保存"
            showsTimelineRecalculation = true
            refreshSlow()
        } catch { timelineSettingsError = String(describing: error) }
    }

    func recalculateTimeline(_ scope: TimelineRecalculation) {
        showsTimelineRecalculation = false
        guard !timelineRebuilding else { return }
        guard scope != .none else {
            timelineSettingsMessage = "不重算已有总结；后续按新模式生成"
            return
        }
        let root = root
        let binary = commandExecutable
        let arguments = scope.arguments() + ["--out", root.path]
        timelineRebuilding = true
        timelineSettingsError = nil
        timelineSettingsMessage = scope == .today ? "正在重算当天总结…" : "正在依次重算所有总结…"
        timelineTask = Task { [weak self] in
            let worker = Task.detached { () -> String? in
                do {
                    try LocalCommand.run(binary.path, arguments, timeout: 7200, cancelled: { Task<Never, Never>.isCancelled })
                    return nil
                } catch is CancellationError { return "重算已停止，已完成的部分保留" }
                catch { return String(describing: error) }
            }
            let error = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard let self, !self.stopped else { return }
            self.timelineRebuilding = false
            self.timelineTask = nil
            if let error { self.timelineSettingsError = error; self.timelineSettingsMessage = nil }
            else { self.timelineSettingsMessage = "总结重算完成" }
            self.refreshSlow()
        }
    }

    func cancelTimelineRecalculation() { timelineTask?.cancel() }

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
        func showError(_ message: String) {
            switch settingsTab {
            case .timeline: timelineSettingsError = message
            case .prompts: summarySettingsError = message
            case .model: modelSettingsError = message
            case .collector: collectorSettingsError = message
            case .backup: reportError = message
            }
        }
        if FileManager.default.fileExists(atPath: file.path) {
            if !NSWorkspace.shared.open(file) { showError("无法打开 \(name)，请从数据目录中选择编辑器打开。") }
        } else {
            showError("请先保存设置，再打开 \(name)。")
        }
    }

    func closeDetail() {
        detailRequest = UUID()
        detailTask?.cancel()
        detailTask = nil
        detail = nil
    }

    func toggleSummarySelection() {
        isSelectingSummaries.toggle()
        selectedSummaryIDs.removeAll()
        selectionMessage = nil
    }

    func selectSummary(_ item: TimelineItem) {
        guard !item.isAway else { return }
        if !selectedSummaryIDs.insert(item.id).inserted { selectedSummaryIDs.remove(item.id) }
        selectionMessage = nil
    }

    func copySelectedSummaries() {
        let items = allTimelineGroups.flatMap(\.items).filter { selectedSummaryIDs.contains($0.id) && !$0.isAway }
            .flatMap(\.leafItems)
            .sorted { $0.timestamp < $1.timestamp }
        guard !items.isEmpty else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        writeToPasteboard(items.map { "[\(formatter.string(from: $0.timestamp))] \($0.title)\n\($0.summary)" }.joined(separator: "\n\n"))
        selectionMessage = "已复制 \(items.count) 条摘要"
    }

    func canEditSummary(_ item: TimelineItem) -> Bool {
        effectiveTimelineMode == .fixedTenMinutes && item.children == nil && !item.isAway && item.memoryFiles.count == 1
    }

    func editSummary(_ item: TimelineItem) {
        guard canEditSummary(item) else { return }
        editingSummary = item
        editedTitle = item.title
        editedSummary = item.summary
        editError = nil
    }

    func saveSummaryEdit(restore: Bool = false) {
        guard let item = editingSummary, canEditSummary(item) else { return }
        let title = editedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = editedSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard restore || (!title.isEmpty && !summary.isEmpty) else { editError = "请填写标题和内容。"; return }
        do {
            var edits = try TimelineEdits.load(root: root)
            try edits.set(restore ? nil : .init(title: title, summary: summary), for: item.memoryFiles[0].lastPathComponent, root: root)
            editingSummary = nil
            refreshSlow()
        } catch { editError = "无法保存摘要：\(error.localizedDescription)" }
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
