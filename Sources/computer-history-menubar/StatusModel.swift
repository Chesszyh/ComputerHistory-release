import Foundation
import Combine
import AppKit
import ComputerHistoryCore
import SwiftUI

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
    @Published private(set) var reportLoading = false
    @Published var reportMessage: String?
    @Published var reportError: String?
    @Published private(set) var effectiveBackupEnabled = false
    @Published var backupRepository = ""
    @Published var backupEnabled = false
    @Published private(set) var backupLoaded = false
    @Published private(set) var backupMessage = ""
    private var reportTask: Task<Void, Never>?
    private var reportLoadTask: Task<Void, Never>?
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
    enum SettingsTab: String, CaseIterable { case timeline = "时间线", prompts = "提示词", model = "模型", collector = "采集", backup = "备份", access = "授权" }
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
    @Published private(set) var effectiveTimelineMode: SummarySettings.TimelineMode = .continuous
    @Published var timelineMode: SummarySettings.TimelineMode = .continuous
    @Published var showsTimelineRecalculation = false
    @Published private(set) var timelineSettingsLoaded = false
    @Published private(set) var timelineRebuilding = false
    @Published var timelineSettingsMessage: String?
    @Published var timelineSettingsError: String?
    private var timelineTask: Task<Void, Never>?
    @Published var settingsTab: SettingsTab = .prompts
    @Published var modelGroups: [ModelGroupDraft] = []
    @Published var modelEndpoints: [ModelEndpointDraft] = []
    @Published var editingEndpointID = ""
    @Published var editingGroupID = ""
    @Published var primaryGroupID = ""
    @Published var fallbackGroupID = ""
    @Published var modelTasks: [String: ModelTaskConfiguration] = [:]
    @Published var modelTaskTemplates: [ModelTaskTemplate] = []
    @Published var selectedTaskTemplateID = ""
    @Published var taskTemplateName = ""
    @Published var dailyBudget = ""
    @Published var monthlyBudget = ""
    @Published var isSelectingSummaries = false
    @Published var selectedSummaryIDs: Set<String> = []
    @Published var editingSummary: TimelineItem?
    @Published var editedTitle = ""
    @Published var editedSummary = ""
    @Published var editError: String?
    @Published var selectionMessage: String?
    @Published var invalidCorrections = 0
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
    @Published var permissionStatus: PermissionStatus?
    @Published var permissionBusy = false
    @Published var permissionMessage: String?
    private var setupWindow: NSWindow?

    func openPermissionSetup() {
        if let setupWindow { setupWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let contentSize = NSSize(width: 480, height: 560)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "设置 ComputerHistory"
        window.isReleasedWhenClosed = false
        // NSHostingController otherwise derives the window size from the view's compressed fitting size.
        window.contentViewController = NSHostingController(rootView: PermissionSetupPane(model: self)
            .frame(width: contentSize.width, height: contentSize.height))
        window.contentMinSize = contentSize
        window.setContentSize(contentSize)
        window.center(); window.makeKeyAndOrderFront(nil)
        setupWindow = window
        NSApp.activate(ignoringOtherApps: true)
        refreshPermissions()
    }

    func refreshPermissions(request kind: String? = nil) {
        guard !permissionBusy else { return }
        let binary = commandExecutable
        permissionBusy = true
        Task {
            do {
                let status = try await Task.detached {
                    let text = try LocalCommand.run(binary.path, ["permissions"] + (kind.map { ["--request", $0] } ?? []), timeout: 180)
                    return try JSONDecoder().decode(PermissionStatus.self, from: Data(text.utf8))
                }.value
                permissionStatus = status
                if let kind {
                    let pane = ["accessibility": "Privacy_Accessibility", "input": "Privacy_ListenEvent", "screen": "Privacy_ScreenCapture"][kind]!
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane)!)
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                }
            } catch { permissionMessage = String(describing: error) }
            permissionBusy = false
        }
    }

    func restoreCredentialAccess() {
        guard !permissionBusy else { return }
        let binary = commandExecutable, root = root
        permissionBusy = true; permissionMessage = nil
        Task {
            do {
                _ = try await Task.detached {
                    try LocalCommand.run(binary.path, ["model-key", "--authorize", "--all", "--out", root.path], timeout: 300)
                }.value
                permissionMessage = "密钥访问已恢复"
                requestFlush()
            } catch { permissionMessage = String(describing: error) }
            permissionBusy = false
        }
    }

    func startCollectorFromSetup() {
        do {
            try CollectorService.start(executable: commandExecutable, root: root)
            permissionMessage = "后台采集服务已启动"
            refreshAll()
        } catch { permissionMessage = String(describing: error) }
    }

    func finishPermissionSetup() {
        UserDefaults.standard.set(true, forKey: "ComputerHistory.didCompleteSetup")
        setupWindow?.close()
    }

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
    private var historyRequested = false
    private var liveTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var detailRequest = UUID()
    private var stopped = false
    private(set) var panelVisible = false

    func setPanelVisible(_ visible: Bool) {
        guard panelVisible != visible else { return }
        panelVisible = visible
        if visible { refreshAll() }
    }

    init(root: URL = CollectorStatus.defaultRoot, commandExecutable: URL? = nil) {
        self.root = root
        self.commandExecutable = commandExecutable ?? URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("computer-history")
        self.status = .empty(root: root)
        self.control = CollectorControl()
        self.loginItemEnabled = LoginItem.isEnabled
        do { try AccessibilityMessaging.configure(for: .menubar) }
        catch { FileHandle.standardError.write(Data("\(error)。继续使用系统默认等待时间。\n".utf8)) }
        startTimers()
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.shutdown() } }
            .store(in: &cancellables)
        refreshAll(forceHistory: false)
    }

    private func startTimers() {
        // 前台身份留在主线程，跨进程窗口查询由后台 actor 完成。
        Timer.publish(every: 1, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in if self?.panelVisible == true { self?.refreshLive() } }
            .store(in: &cancellables)

        // 采集状态与记忆在后台刷新，复用未变化文件的缓存。
        Timer.publish(every: 3, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.refreshSlow(forceHistory: false) }
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
        guard panelVisible else { return }
        let pid = app?.processIdentifier
        liveTask = Task { [weak self] in
            let window = await TrayWindowReader.shared.read(pid: pid)
            guard let self else { return }
            self.liveTask = nil
            guard !self.stopped, self.control.recording, FrontmostApplication.current()?.processIdentifier == pid else { return }
            if self.frontWindow != window?.title { self.frontWindow = window?.title }
        }
    }

    func refreshSlow(forceHistory: Bool = true) {
        historyRequested = historyRequested || forceHistory
        guard !stopped, refreshState.request() else { return }
        startLoad()
    }

    private func startLoad() {
        let root = root, loader = loader
        let showHistory = panelVisible || historyRequested
        historyRequested = false
        refreshTask = Task { [weak self] in
            if !showHistory {
                let indicator = await loader.indicatorStatus(root: root)
                let control = await Task.detached { CollectorControl.load(root: root) }.value
                guard let self, !self.stopped else { return }
                if !self.panelVisible {
                    var status = self.status
                    status.process = indicator.process
                    status.inputListening = indicator.inputListening
                    status.awayReason = indicator.awayReason
                    status.data.lastWriteAt = indicator.data.lastWriteAt
                    if status != self.status { self.status = status }
                    if self.control != control { self.control = control }
                    self.refreshLive()
                }
                self.finishRefresh()
                return
            }
            let snapshot = await loader.load(root: root)
            let requests = await self?.requestLoader.load(root: root) ?? []
            let health = await Task.detached { ModelHealth.load(root: root) }.value
            let enabled = await Task.detached { (try? BackupSettings.load(root: root))?.enabled ?? false }.value
            guard let self, !self.stopped else { return }
            if self.modelFailure != health?.error { self.modelFailure = health?.error }
            if self.effectiveBackupEnabled != enabled { self.effectiveBackupEnabled = enabled }
            if self.modelRequests != requests { self.modelRequests = requests }
            if self.invalidCorrections != snapshot.invalidCorrections { self.invalidCorrections = snapshot.invalidCorrections }
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
                let ids = Set(snapshot.groups.flatMap(\.items).flatMap { [$0] + $0.leafItems }.map(\.id))
                self.expandedRows.formIntersection(ids)
                self.selectedSummaryIDs.formIntersection(ids)
                if let detail = self.detail, !ids.contains(detail.id) { self.closeDetail() }
            }
            if self.lastEventAt != snapshot.status.data.lastWriteAt { self.lastEventAt = snapshot.status.data.lastWriteAt }
            let login = LoginItem.isEnabled
            if self.loginItemEnabled != login { self.loginItemEnabled = login }
            self.finishRefresh()
        }
    }

    private func finishRefresh() {
        refreshTask = nil
        if refreshState.finished() { startLoad() }
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
        reportLoadTask?.cancel()
        timelineTask?.cancel()
        cancellables.removeAll()
    }

    func refreshAll(forceHistory: Bool = true) {
        refreshLive()
        refreshSlow(forceHistory: forceHistory)
    }

    func openReports() {
        showsReports = true
        loadReports()
    }

    func loadReports() {
        guard !reportBusy else { return }
        let root = root, period = ReportPeriod(kind: reportKind, date: reportDate)
        reportLoadTask?.cancel()
        reportLoading = true; reportError = nil; reportMessage = nil
        reportText = ""; reportMaterial = ""
        reportLoadTask = Task { [weak self] in
            let result = await Task.detached { () -> Result<String, Error> in
                do {
                    let report = try ActivityReport.load(root: root, period: period)
                    return .success(report?.markdown ?? "")
                } catch { return .failure(error) }
            }.value
            guard let self, !self.stopped, !Task.isCancelled else { return }
            switch result {
            case .success(let text): self.reportText = text
            case .failure(let error): self.reportError = String(describing: error)
            }
            self.reportLoading = false
        }
    }

    func generateReport() {
        var arguments = ["report", "--kind", reportKind.rawValue, "--day", ReportPeriod.day(reportDate), "--wait-lock"]
        if !reportText.isEmpty { arguments.append("--overwrite") }
        runReportCommand(arguments, message: "报告已生成")
    }

    func runReportCommand(_ arguments: [String], message: String) {
        guard !reportBusy, !reportLoading else { return }
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
        withReportText(material: material) { model, text in
            model.writeToPasteboard(text)
            model.reportMessage = material ? "已复制给 AI 的材料" : "已复制报告"
        }
    }

    func saveReport(to url: URL, material: Bool) {
        withReportText(material: material) { model, text in
            do {
                try ActivityExport.write(ActivityExport.formatted(text, format: url.pathExtension), to: url)
                model.reportMessage = "已导出 \(url.lastPathComponent)"; model.reportError = nil
            } catch { model.reportError = String(describing: error) }
        }
    }

    private func withReportText(material: Bool, action: @escaping (StatusModel, String) -> Void) {
        guard !reportBusy, !reportLoading else { return }
        if !material || !reportMaterial.isEmpty {
            let text = material ? reportMaterial : reportText
            if !text.isEmpty { action(self, text) }
            return
        }
        let root = root, period = ReportPeriod(kind: reportKind, date: reportDate)
        reportBusy = true; reportError = nil; reportMessage = nil
        reportTask = Task { [weak self] in
            let result = await Task.detached { Result { try ActivityExport.aiMaterial(root: root, period: period) } }.value
            guard let self, !self.stopped, !Task.isCancelled else { return }
            self.reportBusy = false
            switch result {
            case .success(let text):
                self.reportMaterial = text
                action(self, text)
            case .failure(let error): self.reportError = String(describing: error)
            }
        }
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
        if isStalled || status.inputListening?.enabled == false || status.inputListening?.keyboard == false { return "clock.badge.exclamationmark" }
        return "clock.arrow.circlepath"
    }

    var stateLabel: String {
        if !status.process.running { return "未采集" }
        if !control.recording { return "已暂停" }
        if frontBundleID == "com.apple.loginwindow" { return "已离开" }
        if status.inputListening?.enabled == false || status.inputListening?.keyboard == false { return "输入监听异常" }
        if isStalled { return "已停滞" }
        return "采集中"
    }

    var stateColor: StatusColor {
        if !status.process.running { return .secondary }
        if !control.recording || frontBundleID == "com.apple.loginwindow" { return .secondary }
        if isStalled || status.inputListening?.enabled == false || status.inputListening?.keyboard == false { return .warning }
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
            let groups = try ModelGroups.readForEditing(root: root)
            do { _ = try groups.resolved() }
            catch ModelSettings.SettingsError.fallbackPricing {
                modelSettingsError = ModelSettings.SettingsError.fallbackPricing.description
            }
            let editable = try groups.withExplicitEndpoints { [root] id in
                try? ModelAPIKey.load(root: root, groupID: id)
            }
            let previousEndpoints = modelEndpoints
            modelEndpoints = try (editable.endpoints ?? []).map { endpoint in
                var draft = ModelEndpointDraft(endpoint)
                draft.hasStoredAPIKey = try ModelAPIKey.contains(root: root, groupID: endpoint.id)
                if let previous = previousEndpoints.first(where: { $0.id == draft.id && $0.baseURL == draft.baseURL && $0.requiresAPIKey == draft.requiresAPIKey }) {
                    draft.availableModels = previous.availableModels
                }
                return draft
            }
            modelGroups = try editable.groups.map { group in
                ModelGroupDraft(group, endpoint: try editable.endpoint(for: group))
            }
            editingEndpointID = modelGroups.first { $0.id == groups.primaryGroupID }?.endpointID ?? ""
            primaryGroupID = groups.primaryGroupID
            fallbackGroupID = groups.fallbackGroupID ?? ""
            modelTasks = groups.tasks ?? [:]
            modelTaskTemplates = groups.templates ?? []
            selectTaskTemplate(modelTaskTemplates.first {
                $0.primaryGroupID == groups.primaryGroupID && $0.fallbackGroupID == groups.fallbackGroupID
                    && $0.tasks == modelTasks && $0.dailyBudget == groups.dailyBudget && $0.monthlyBudget == groups.monthlyBudget
            }?.id ?? "")
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

    func setModelEndpointAddress(_ address: String, at index: Int) {
        modelEndpoints[index].baseURL = address
        modelEndpoints[index].availableModels = []
        modelEndpoints[index].catalogMessage = nil
    }

    func fetchModelCatalog(endpointID: String) {
        guard let index = modelEndpoints.firstIndex(where: { $0.id == endpointID }),
              !modelEndpoints[index].catalogLoading else { return }
        modelEndpoints[index].catalogLoading = true
        modelEndpoints[index].catalogMessage = nil
        let draft = modelEndpoints[index]
        let primary = modelGroups.first { $0.id == primaryGroupID }?.endpointID
        let fallback = modelGroups.first { $0.id == fallbackGroupID }?.endpointID
        let root = root
        Task {
            do {
                let endpoint = try draft.value()
                let key = try await Task.detached {
                    if !draft.requiresAPIKey { return "" }
                    if !draft.apiKey.isEmpty { return draft.apiKey }
                    if !draft.removesAPIKey, let saved = try ModelAPIKey.load(root: root, groupID: draft.id) { return saved }
                    let env = ProcessInfo.processInfo.environment
                    if draft.id == primary, let key = env["DEEPSEEK_API_KEY"], !key.isEmpty { return key }
                    return draft.id == fallback ? env["COMPUTER_HISTORY_FALLBACK_API_KEY"] ?? "" : ""
                }.value
                let catalog = try await ModelCatalog.fetch(baseURL: endpoint.baseURL, apiKey: key, allowInsecureHTTP: draft.allowInsecureHTTP)
                guard let current = modelEndpoints.firstIndex(where: { $0.id == endpointID }) else { return }
                modelEndpoints[current].catalogLoading = false
                guard modelEndpoints[current].baseURL == draft.baseURL else { return }
                var seen: Set<String> = []
                let entries = catalog.data.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
                modelEndpoints[current].availableModels = entries
                modelEndpoints[current].catalogMessage = entries.isEmpty ? "服务未返回模型，可手动填写。" : "已读取 \(entries.count) 个模型"
            } catch {
                guard let current = modelEndpoints.firstIndex(where: { $0.id == endpointID }) else { return }
                modelEndpoints[current].catalogLoading = false
                guard modelEndpoints[current].baseURL == draft.baseURL else { return }
                modelEndpoints[current].catalogMessage = "未能读取模型列表，可手动填写：\(error)"
            }
        }
    }

    func apiKeyStatus(for endpoint: ModelEndpointDraft) -> String {
        if endpoint.hasStoredAPIKey { return "已保存到系统钥匙串" }
        let environment = ProcessInfo.processInfo.environment
        if modelGroups.first(where: { $0.id == primaryGroupID })?.endpointID == endpoint.id,
           environment["DEEPSEEK_API_KEY"]?.isEmpty == false { return "当前从主模型环境变量读取密钥" }
        if modelGroups.first(where: { $0.id == fallbackGroupID })?.endpointID == endpoint.id,
           environment["COMPUTER_HISTORY_FALLBACK_API_KEY"]?.isEmpty == false { return "当前从备用模型环境变量读取密钥" }
        return "尚未填写密钥"
    }

    func addModelEndpoint() {
        var draft = ModelEndpointDraft(ModelEndpoint(name: "新端点", baseURL: DeepSeekClient.defaultBaseURL))
        draft.baseURL = ""
        modelEndpoints.append(draft)
        editingEndpointID = draft.id
    }

    func removeEditingModelEndpoint() {
        guard !modelGroups.contains(where: { $0.endpointID == editingEndpointID }) else { return }
        modelEndpoints.removeAll { $0.id == editingEndpointID }
        editingEndpointID = modelEndpoints.first?.id ?? ""
    }

    func addModelGroup() {
        guard let endpoint = modelEndpoints.first(where: { $0.id == editingEndpointID }) ?? modelEndpoints.first else { return }
        let group = ModelGroup(name: "新模型", settings: ModelSettings(baseURL: DeepSeekClient.defaultBaseURL,
            model: endpoint.availableModels.first?.id ?? ""))
        var draft = ModelGroupDraft(group)
        draft.endpointID = endpoint.id
        modelGroups.append(draft)
        editingGroupID = group.id
    }

    func removeEditingModelGroup() {
        guard modelGroups.count > 1, modelGroups.contains(where: { $0.id == editingGroupID }) else { return }
        let removedID = editingGroupID
        modelGroups.removeAll { $0.id == removedID }
        if primaryGroupID == removedID { primaryGroupID = modelGroups[0].id }
        if fallbackGroupID == removedID || fallbackGroupID == primaryGroupID { fallbackGroupID = "" }
        for task in Array(modelTasks.keys) where modelTasks[task]?.groupID == removedID {
            modelTasks[task]?.groupID = nil
        }
        for index in modelTaskTemplates.indices {
            modelTaskTemplates[index].removeModel(removedID, replacement: modelGroups[0].id)
        }
        editingGroupID = primaryGroupID
    }

    func selectTaskTemplate(_ id: String) {
        selectedTaskTemplateID = id
        taskTemplateName = modelTaskTemplates.first { $0.id == id }?.name ?? ""
    }

    func applyTaskTemplate() {
        guard let template = modelTaskTemplates.first(where: { $0.id == selectedTaskTemplateID }) else { return }
        primaryGroupID = template.primaryGroupID
        fallbackGroupID = template.fallbackGroupID ?? ""
        modelTasks = template.tasks
        dailyBudget = template.dailyBudget.map(String.init(describing:)) ?? ""
        monthlyBudget = template.monthlyBudget.map(String.init(describing:)) ?? ""
        modelSettingsError = nil
        modelSettingsMessage = "已套用「\(template.name)」，保存后生效"
    }

    func saveTaskTemplate(update: Bool = false, renameOnly: Bool = false) {
        do {
            let name = taskTemplateName.trimmingCharacters(in: .whitespacesAndNewlines)
            let existing = update ? modelTaskTemplates.firstIndex { $0.id == selectedTaskTemplateID } : nil
            guard !name.isEmpty, !modelTaskTemplates.indices.contains(where: { $0 != existing && modelTaskTemplates[$0].name == name }) else {
                throw ConfigurationInputError.invalid("请填写未使用的模板名称。")
            }
            let id: String
            if renameOnly, let existing {
                modelTaskTemplates[existing].name = name
                id = modelTaskTemplates[existing].id
            } else {
                id = existing.map { modelTaskTemplates[$0].id } ?? UUID().uuidString
                let template = try ModelTaskTemplate(id: id, name: name, primaryGroupID: primaryGroupID,
                    fallbackGroupID: fallbackGroupID.isEmpty ? nil : fallbackGroupID, tasks: modelTasks,
                    dailyBudget: modelBudget(dailyBudget), monthlyBudget: modelBudget(monthlyBudget))
                if let existing { modelTaskTemplates[existing] = template }
                else { modelTaskTemplates.append(template) }
            }
            selectTaskTemplate(id)
            modelSettingsError = nil
            modelSettingsMessage = "点击保存以保留模板更改"
        } catch { modelSettingsError = String(describing: error); modelSettingsMessage = nil }
    }

    func removeTaskTemplate() {
        modelTaskTemplates.removeAll { $0.id == selectedTaskTemplateID }
        selectTaskTemplate("")
        modelSettingsError = nil
        modelSettingsMessage = "点击保存以移除模板"
    }

    private func modelBudget(_ text: String) throws -> Double? {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        guard let value = Double(text), value.isFinite, value >= 0 else {
            throw ConfigurationInputError.invalid("预算请填写非负数字，或留空表示不限制。")
        }
        return value
    }

    func saveModelConfiguration() {
        guard modelConfigurationLoaded else { return }
        do {
            let endpoints = try modelEndpoints.map { try $0.value() }
            let groups = try modelGroups.map { draft in
                guard let endpoint = endpoints.first(where: { $0.id == draft.endpointID }) else {
                    throw ConfigurationInputError.invalid("请为「\(draft.name)」选择端点。")
                }
                return try draft.value(endpoint: endpoint)
            }
            let settings = try ModelGroups(groups: groups,
                primaryGroupID: primaryGroupID, fallbackGroupID: fallbackGroupID.isEmpty ? nil : fallbackGroupID,
                dailyBudget: modelBudget(dailyBudget), monthlyBudget: modelBudget(monthlyBudget),
                tasks: modelTasks.isEmpty ? nil : modelTasks, endpoints: endpoints,
                templates: modelTaskTemplates.isEmpty ? nil : modelTaskTemplates)
            try settings.validateForSaving()
            for index in modelEndpoints.indices {
                let endpoint = modelEndpoints[index]
                if !endpoint.apiKey.isEmpty {
                    try ModelAPIKey.save(endpoint.apiKey, root: root, groupID: endpoint.id)
                    modelEndpoints[index].hasStoredAPIKey = true
                } else if endpoint.removesAPIKey {
                    try ModelAPIKey.remove(root: root, groupID: endpoint.id)
                    modelEndpoints[index].hasStoredAPIKey = false
                }
                modelEndpoints[index].apiKey = ""
                modelEndpoints[index].removesAPIKey = false
            }
            try settings.save(root: root)
            modelSettingsError = nil
            modelSettingsMessage = "已保存，下一次总结使用所选模型"
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
            case .access: permissionMessage = message
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
        let items = selectedLeafSummaries
        guard !items.isEmpty else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        writeToPasteboard(items.map { "[\(formatter.string(from: $0.timestamp))] \($0.title)\n\($0.summary)" }.joined(separator: "\n\n"))
        selectionMessage = "已复制 \(items.count) 条摘要"
    }

    var selectedLeafSummaries: [TimelineItem] {
        allTimelineGroups.flatMap(\.items).flatMap { item in
            selectedSummaryIDs.contains(item.id) ? item.leafItems
                : item.leafItems.filter { selectedSummaryIDs.contains($0.id) }
        }.filter { !$0.isAway }.sorted { $0.timestamp < $1.timestamp }
    }

    func relatedSummaries(_ item: TimelineItem) -> [TimelineItem] {
        guard let task = item.taskID else { return [] }
        return allTimelineGroups.flatMap(\.items).flatMap(\.leafItems)
            .filter { $0.id != item.id && $0.taskID == task }.sorted { $0.timestamp < $1.timestamp }
    }

    func correctActivities(_ action: TimelineCorrections.Action, items: [TimelineItem]? = nil) {
        let selected = items ?? selectedLeafSummaries
        guard !selected.isEmpty else { return }
        do {
            let index = MemoryIndex.load(from: root.appendingPathComponent("memories"))
            let groups = selected.filter { $0.isNarrative && !$0.isAway }.map { item -> [TimelineCorrections.Reference] in
                var source = ActivityNarrative.Item(id: item.id, timestamp: item.timestamp, title: item.title,
                    summary: item.summary, apps: item.apps, sourceMemories: item.memoryFiles.map(\.lastPathComponent))
                source.sourceActivities = item.sourceActivities
                return TimelineCorrections.references(source, index: index)
            }.filter { !$0.isEmpty }
            guard !groups.isEmpty, action == .split || groups.count >= 2 else {
                selectionMessage = "请选择至少两项独立活动。"; return
            }
            var corrections = try TimelineCorrections.load(root: root)
            corrections.entries.append(.init(action: action, groups: groups))
            try corrections.save(root: root)
            selectedSummaryIDs.removeAll(); selectionMessage = "已保存活动归属，可撤销。"
            refreshSlow()
        } catch { timelineError = "无法保存活动归属：\(error)" }
    }

    func undoActivityCorrection() {
        do {
            var corrections = try TimelineCorrections.load(root: root)
            guard !corrections.entries.isEmpty else { return }
            corrections.entries.removeLast(); try corrections.save(root: root)
            selectionMessage = "已撤销上次归属修改。"; refreshSlow()
        } catch { timelineError = "无法撤销活动归属：\(error)" }
    }

    func editTaskTitle(_ item: TimelineItem) {
        guard let task = item.taskID else { return }
        let alert = NSAlert(); alert.messageText = "编辑任务名称"
        let field = NSTextField(string: item.taskTitle ?? item.title)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field; alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        do {
            var edits = try TimelineEdits.load(root: root)
            if edits.taskTitles == nil { edits.taskTitles = [:] }
            edits.taskTitles?[task] = title
            for member in [item] + relatedSummaries(item) {
                for anchor in TimelineEdits.taskAnchorKeys(for: member) { edits.taskTitles?[anchor] = title }
            }
            try edits.save(root: root)
            refreshSlow()
        } catch { timelineError = "无法保存任务名称：\(error)" }
    }

    func canEditSummary(_ item: TimelineItem) -> Bool {
        TimelineEdits.key(for: item, mode: effectiveTimelineMode) != nil
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
            guard let key = TimelineEdits.key(for: item, mode: effectiveTimelineMode) else { return }
            let revisions = Dictionary(uniqueKeysWithValues: item.memoryFiles.compactMap { file in
                MemoryIndex.parse(fileURL: file).map { ($0.id, $0.revision) }
            })
            try edits.set(restore ? nil : .init(title: title, summary: summary, revisions: revisions), for: key, root: root)
            editingSummary = nil
            refreshSlow()
        } catch { editError = "无法保存摘要：\(error.localizedDescription)" }
    }

}

/// 默认 AX 超时在本托盘进程生效；AX 对象在此后台 actor 内创建和使用。
private actor TrayWindowReader {
    static let shared = TrayWindowReader()
    func read(pid: Int32?) -> EventStreamWindow? {
        FrontmostApplication.window(pid: pid)
    }
}
