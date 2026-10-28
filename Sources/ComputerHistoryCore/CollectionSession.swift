import Foundation
import CoreGraphics

/// 采集会话：把输入事件与 AX 树组装成 `EventStreamRecord`，按 10 分钟切段落盘。
///
/// 与真实服务的行为对齐点（均由 88 段样本 + 反编译确认）：
///   - 事件 `id` 在**会话内**自增、跨 segment 连续，会话重启后归 1。
///   - 段按钟表对齐到 10 分钟边界；`startedAt` 是边界值，段内首个事件可显著晚于它。
///   - 超出行预算的差分**回退为整树**（`fullTree`），这正是样本中该模式在段中间出现的成因。
///   - 命中抑制策略的事件只累加 `suppressedEventCount`，不落主文件。
///
/// 线程约束：所有公开方法须在同一线程调用（CLI 中即主 runloop 线程），
/// 因为 `CGEventTap` 回调与 `SegmentWriter` 都不是线程安全的。
public final class CollectionSession {

    public struct Configuration: Sendable {
        /// 落盘根目录；其下生成 `segments/<id>/{events.jsonl,metadata.json}`。
        public var rootDirectory: URL
        /// AX 树单帧节点上限。
        public var maxNodesPerSnapshot: Int
        /// 是否在抑制命中时仍统计（关闭后 `suppressedEventCount` 恒为 0）。
        public var tracksSuppression: Bool
        /// 观测策略。
        public var policy: ObservationPolicy
        /// 落盘保留策略。
        public var retention: CollectorConfig.Retention
        public var windowTextApplications: [String]
        public var windowTextDisabledApplications: [String]
        public var activityWatchEnabled: Bool

        public init(
            rootDirectory: URL,
            maxNodesPerSnapshot: Int = 4000,
            tracksSuppression: Bool = true,
            policy: ObservationPolicy = .init(),
            retention: CollectorConfig.Retention = .init(),
            windowTextApplications: [String] = [],
            windowTextDisabledApplications: [String] = [],
            activityWatchEnabled: Bool = false
        ) {
            self.rootDirectory = rootDirectory
            self.maxNodesPerSnapshot = maxNodesPerSnapshot
            self.tracksSuppression = tracksSuppression
            self.policy = policy
            self.retention = retention
            self.windowTextApplications = windowTextApplications
            self.windowTextDisabledApplications = windowTextDisabledApplications
            self.activityWatchEnabled = activityWatchEnabled
        }

        /// 由配置文件构造。
        public init(rootDirectory: URL, config: CollectorConfig,
                    tracksSuppression: Bool = true) {
            self.init(rootDirectory: rootDirectory,
                      maxNodesPerSnapshot: config.maxNodesPerSnapshot,
                      tracksSuppression: tracksSuppression,
                      policy: config.policy,
                      retention: config.retention,
                      windowTextApplications: config.windowTextApplications,
                      windowTextDisabledApplications: config.windowTextDisabledApplications,
                      activityWatchEnabled: config.activityWatchEnabled)
        }
    }

    private var activityWatchSince = Date()
    private var activityWatchCursor: Date?
    private var accessibilityActivation = AccessibilityActivation()
    private(set) var frontmostSampleInFlight = false
    private var frontmostSampleEpoch = 0
    private var frontmostSampleContext: FrontmostSnapshotContext?
    private var config: Configuration
    private var writer: SegmentWriter?
    private var nextID = 1
    /// 上一帧已编号的树，直接用于差分；避免"渲染再反解"的绕行。
    private var previousTree: [UIElementRender]?
    private var lastSnapshotText: String?
    private var treeContext: EventStreamWindow?
    private var treeApp: EventStreamApp?
    private var isRunning = false
    public struct WindowTextContext: Sendable, Equatable {
        public var app: EventStreamApp
        public var window: EventStreamWindow?
        var epoch: Int
    }
    public private(set) var windowTextContext: WindowTextContext?
    private var windowTextEpoch = 0
    private var lastWindowText: (context: WindowTextContext, text: String)?
    private var away: AwayPeriods
    public var isAway: Bool { away.startedAt != nil }

    public func applyConfiguration(_ updated: CollectorConfig) {
        frontmostSampleEpoch += 1
        activityWatchSince = Date()
        activityWatchCursor = nil
        // 策略变化后丢弃旧缓冲，避免把新名单排除的文本写入历史。
        windowTextEpoch += 1
        windowTextContext = nil
        lastWindowText = nil
        textTracker.resetBaseline()
        pendingText = []
        textContext = nil
        inputActivity = nil
        previousTree = nil
        lastSnapshotText = nil
        treeApp = nil
        treeContext = nil
        config = Configuration(rootDirectory: config.rootDirectory, config: updated,
                               tracksSuppression: config.tracksSuppression)
    }

    /// 最近一次清理结果，供 CLI 汇报。
    public private(set) var lastPruneReport: PruneReport?

    /// 是否暂停记录。由调用方按运行开关设置——会话本身不读文件，
    /// 保持它与存储布局无关，也便于测试。
    public var isPaused = false {
        didSet {
            guard isPaused != oldValue else { return }
            frontmostSampleEpoch += 1
            if isPaused { finishIdlePeriod(at: Date()) }
            activityWatchSince = Date()
            activityWatchCursor = nil
            // 恢复时必须重新建立基线，避免把暂停期间的编辑补记为输入。
            windowTextEpoch += 1
            windowTextContext = nil
            lastWindowText = nil
            textTracker.resetBaseline()
            pendingText = []
            textContext = nil
            inputActivity = nil
            lastScrollTime = nil
            lastScrollPID = nil
            lastScrollWindowID = nil
            previousTree = nil
            lastSnapshotText = nil
        }
    }

    /// 输入监听是否处于有效状态。由外部采样循环按周期同步。
    public var isInputListeningActive: Bool = true {
        didSet {
            if !isInputListeningActive {
                hadDegradedInputListening = true
            }
        }
    }
    private var hadDegradedInputListening: Bool = false
    public func noteInputListeningInterruption() { hadDegradedInputListening = true }

    /// 文本输入聚合。观察聚焦元素的值变化，按停顿切块。
    private let textTracker = TextInputTracker()
    private struct TextContext {
        var app: EventStreamApp
        var window: EventStreamWindow?
        var focusIdentity: Int?
        var target: EventStreamAXElement?
    }
    private var textContext: TextContext?
    private var pendingText: [(fragment: TextInputTracker.Fragment, context: TextContext)] = []
    private var inputActivity: (pid: Int32?, windowID: UInt32?, url: String?, focus: Int?, at: Date)?
    private var lastScrollTime: Date?
    private var lastScrollPID: Int32?
    private var lastScrollURL: String?
    private var lastScrollWindowID: UInt32?
    private let scrollThrottleInterval: TimeInterval = 1.0

    /// 只记录交互时间与上下文，不保存原始键码或键入内容。
    public func noteInputActivity(at now: Date = Date()) {
        let app = FrontmostApplication.current()
        guard isRunning, !isPaused, observeAvailability(app: app, now: now, idleSeconds: 0) else { return }
        noteInputActivity(processIdentifier: app?.processIdentifier, at: now)
    }

    func noteInputActivity(processIdentifier: Int32?, at now: Date) {
        guard isRunning, !isPaused, !isAway, let context = textContext,
              context.app.processIdentifier == processIdentifier else { return }
        inputActivity = (processIdentifier, context.window?.windowID, context.window?.url, context.focusIdentity, now)
    }

    /// 供外部观察状态。
    public private(set) var currentSegmentID: String?
    public private(set) var totalEventsWritten = 0
    public private(set) var writeFailureCount = 0
    public private(set) var lastWriteError: String?

    public init(configuration: Configuration) {
        self.config = configuration
        self.away = AwayPeriods.load(root: configuration.rootDirectory)
    }

    public var isRecording: Bool { isRunning }

    // MARK: - 生命周期

    /// 开始采集。写一条 `session.started`，并开启第一个 segment。
    public func start(now: Date = Date()) throws {
        guard !isRunning else { return }
        frontmostSampleEpoch += 1
        nextID = 1
        if !isAway { try rotateIfNeeded(now: now, force: true) }
        try EventArchive.recoverUnsealed(root: config.rootDirectory, excluding: currentSegmentID ?? "")
        isRunning = true
        textTracker.resetBaseline()
        pendingText = []
        textContext = nil
        previousTree = nil
        lastSnapshotText = nil
        append(kind: .sessionStarted, at: now, app: nil, window: nil,
               mouse: nil, keyboard: nil, selection: nil, ax: nil)
    }

    /// 结束采集。写 `session.ended` 并封口当前 segment。
    public func stop(now: Date = Date()) throws {
        guard isRunning else { return }
        frontmostSampleEpoch += 1
        windowTextEpoch += 1
        windowTextContext = nil
        lastWindowText = nil
        // 收尾前把未满一个停顿周期的输入落盘，避免丢尾部。
        guard flushTextInput(at: now) else { throw CocoaError(.fileWriteUnknown) }
        textTracker.resetBaseline()
        pendingText = []
        textContext = nil
        if !isPaused, !isAway, !append(kind: .sessionEnded, at: now, app: nil, window: nil,
               mouse: nil, keyboard: nil, selection: nil, ax: nil) {
            throw CocoaError(.fileWriteUnknown)
        }
        defer {
            writer = nil
            currentSegmentID = nil
            isRunning = false
        }
        try writer?.close(endedAt: now, endReason: .stopped, inputListeningDegraded: hadDegradedInputListening)
        finishIdlePeriod(at: now)
    }

    /// 采样一次前台应用与 AX 树，产出 `window.changed`（内容有变化时）。
    ///
    /// 调用频率由外部决定；真实服务在窗口/应用切换时触发。
    public func sampleFrontmost(now: Date = Date(), force: Bool = false) {
        windowTextContext = nil
        guard isRunning, !isPaused else { return }
        guard let app = FrontmostApplication.current(), observeAvailability(app: app, now: now, idleSeconds: InputTap.secondsSinceLastInput) else { return }

        let window = FrontmostApplication.frontWindow(for: app)
        // 命中抑制时直接返回：既为隐私，也省下每帧整棵树的遍历开销。
        // 后台长跑时这是主要的 CPU 成本。
        if config.policy.shouldSuppress(app: app, window: window) {
            if config.tracksSuppression { writer?.noteSuppressed() }
            return
        }

        var roots: [UIElementRender] = []
        if let pid = app.processIdentifier {
            accessibilityActivation.prepare(pid: pid, now: now)
            roots = AXTreeReader.read(pid: pid, maxNodes: config.maxNodesPerSnapshot)
        }

        recordSnapshot(roots: roots, app: app, window: window, now: now, force: force)
        updateWindowTextContext(roots: roots, app: app, window: window)
    }

    struct FrontmostSnapshotContext: Sendable {
        var app: EventStreamApp
        var window: EventStreamWindow?

        func matches(_ other: Self?) -> Bool {
            guard let other else { return false }
            return app.processIdentifier == other.app.processIdentifier
                && app.bundleIdentifier == other.app.bundleIdentifier
                && window?.windowID == other.window?.windowID
                && window?.url == other.window?.url
        }

        @MainActor static func current() -> Self? {
            guard let app = FrontmostApplication.current() else { return nil }
            return Self(app: app, window: FrontmostApplication.frontWindow(for: app))
        }
    }

    @MainActor
    public func sampleFrontmostAsync(now: Date = Date(), force: Bool = false) {
        guard isRunning, !isPaused else { windowTextContext = nil; return }
        let context = FrontmostSnapshotContext.current()
        sampleFrontmostAsync(context: context, now: now, force: force,
            idleSeconds: InputTap.secondsSinceLastInput,
            prepare: {
                if let pid = context?.app.processIdentifier {
                    accessibilityActivation.prepare(pid: pid, now: now)
                }
            },
            read: { AXTreeReader.read(pid: $0, maxNodes: $1) },
            currentContext: { FrontmostSnapshotContext.current() })
    }

    @MainActor
    func sampleFrontmostAsync(
        context: FrontmostSnapshotContext?, now: Date, force: Bool = false,
        idleSeconds: TimeInterval? = nil,
        prepare: () -> Void = {},
        read: @escaping @Sendable (Int32, Int) -> [UIElementRender],
        currentContext: @escaping @MainActor @Sendable () -> FrontmostSnapshotContext?,
        completedAt: @escaping @MainActor @Sendable () -> Date = { Date() }
    ) {
        guard isRunning, !isPaused else { windowTextContext = nil; return }
        if !(context?.matches(frontmostSampleContext) ?? (frontmostSampleContext == nil)) {
            frontmostSampleEpoch += 1
            windowTextContext = nil
        }
        frontmostSampleContext = context
        guard let context,
              observeAvailability(app: context.app, now: now, idleSeconds: idleSeconds) else {
            windowTextContext = nil
            return
        }
        guard !config.policy.shouldSuppress(app: context.app, window: context.window) else {
            windowTextContext = nil
            if config.tracksSuppression { writer?.noteSuppressed() }
            return
        }
        guard !frontmostSampleInFlight, let pid = context.app.processIdentifier else { return }
        prepare()
        let maxNodes = config.maxNodesPerSnapshot
        let epoch = frontmostSampleEpoch
        frontmostSampleInFlight = true
        // Only the value snapshot crosses the worker queue; session state stays on the main actor.
        let complete: @MainActor @Sendable ([UIElementRender]) -> Void = { [weak self] roots in
            guard let self else { return }
            self.frontmostSampleInFlight = false
            guard self.frontmostSampleEpoch == epoch,
                  self.isRunning, !self.isPaused, !self.isAway,
                  let current = currentContext(), context.matches(current),
                  !self.config.policy.shouldSuppress(app: current.app, window: current.window) else { return }
            // Input events can be written while AX is reading, including after a segment boundary.
            let finishedAt = completedAt()
            self.recordSnapshot(roots: roots, app: current.app, window: current.window,
                                now: finishedAt, force: force)
            self.updateWindowTextContext(roots: roots, app: current.app, window: current.window)
        }
        DispatchQueue.global(qos: .utility).async {
            let roots = read(pid, maxNodes)
            DispatchQueue.main.async { complete(roots) }
        }
    }

    func updateWindowTextContext(roots: [UIElementRender], app: EventStreamApp, window: EventStreamWindow?) {
        guard isRunning, !isPaused, !isAway,
              config.windowTextApplications.contains(app.bundleIdentifier ?? ""),
              !config.windowTextDisabledApplications.contains(app.bundleIdentifier ?? ""),
              !config.policy.shouldSuppress(app: app, window: window),
              !AXTreeReader.hasReadableContent(roots) else { windowTextContext = nil; return }
        windowTextContext = WindowTextContext(app: app, window: window, epoch: windowTextEpoch)
    }

    public func recordActivityWatch(_ snapshot: ActivityWatchSnapshot, now: Date = Date()) {
        guard let current = FrontmostApplication.current() else { return }
        recordActivityWatch(snapshot, current: current, now: now)
    }

    func recordActivityWatch(_ snapshot: ActivityWatchSnapshot, current: EventStreamApp, now: Date) {
        guard config.activityWatchEnabled, isRunning, !isPaused, !isAway,
              snapshot.application == current.name || snapshot.application == current.bundleIdentifier else { return }
        let window = EventStreamWindow(title: snapshot.title, url: snapshot.url)
        guard !config.policy.shouldSuppress(app: current, window: window) else { return }
        var evidence = snapshot.evidence
        evidence.startedAt = max(evidence.startedAt, activityWatchSince, activityWatchCursor ?? activityWatchSince)
        evidence.endedAt = min(evidence.endedAt, now)
        guard evidence.endedAt > evidence.startedAt else { return }
        if append(kind: .windowChanged, at: now, app: current, window: window,
                  mouse: nil, keyboard: nil, selection: nil, ax: nil, activityWatch: evidence) {
            activityWatchCursor = evidence.endedAt
        }
    }

    public func recordWindowText(_ result: WindowTextReader.Result, context: WindowTextContext, now: Date = Date()) {
        guard isRunning, !isPaused, !isAway, context == windowTextContext,
              !config.policy.shouldSuppress(app: context.app, window: context.window),
              !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let expired = writer.map { SegmentClock.isExpired($0.startedAt, now: now) } ?? false
        if !expired, let lastWindowText, lastWindowText.context == context, lastWindowText.text == result.text { return }
        var window = context.window ?? EventStreamWindow()
        if let expected = window.windowID, expected != result.windowID { return }
        window.windowID = result.windowID
        let lines = result.text.split(separator: "\n").enumerated().map { index, text in
            "\(index) 文本 Value: \(text)"
        }.joined(separator: "\n")
        if append(kind: .windowChanged, at: now, app: context.app, window: window,
                  mouse: nil, keyboard: nil, selection: nil,
                  ax: .init(mode: .fullTree, text: lines, source: "window_ocr")) {
            lastWindowText = (context, result.text)
        }
    }

    func recordSnapshot(roots: [UIElementRender], app: EventStreamApp,
                        window: EventStreamWindow?, now: Date, force: Bool = false) {
        guard isRunning, !isPaused, observeAvailability(app: app, now: now), !config.policy.shouldSuppress(app: app, window: window) else { return }
        let numbered = UIElementRenderTree.assignElementIDs(roots)
        let treeText = UIElementRenderTree.text(numbered)
        let switched = treeApp?.processIdentifier != app.processIdentifier
            || treeContext?.windowID != window?.windowID || treeContext?.url != window?.url
        let expired = writer.map { SegmentClock.isExpired($0.startedAt, now: now) } ?? false
        if switched || expired {
            previousTree = nil; lastSnapshotText = nil
            windowTextEpoch += 1; windowTextContext = nil; lastWindowText = nil
        }
        treeApp = app; treeContext = window
        let changed = treeText != lastSnapshotText
        // 相同界面只记录一次，输入事件独立保存动作。
        if !force, !changed { return }

        let ax = makeAXTree(current: numbered, currentText: treeText)
        if append(kind: .windowChanged, at: now, app: app, window: window,
                  mouse: nil, keyboard: nil, selection: nil, ax: ax) {
            previousTree = numbered
            lastSnapshotText = treeText
        }
    }

    /// 记录一次鼠标点击。
    public func recordClick(
        button: String,
        clickCount: Int,
        modifiers: [String],
        location: CGPoint? = nil,
        at now: Date = Date()
    ) {
        guard isRunning, !isPaused else { return }
        let app = FrontmostApplication.current()
        guard observeAvailability(app: app, now: now, idleSeconds: 0) else { return }
        let window = FrontmostApplication.frontWindow(for: app)
        recordClick(button: button, clickCount: clickCount, modifiers: modifiers, app: app,
                    window: window, readTarget: {
                        location.flatMap { FrontmostApplication.clickedElement(at: $0, for: app, window: window) }
                    }, at: now)
    }

    func recordClick(button: String, clickCount: Int, modifiers: [String], app: EventStreamApp?,
                     window: EventStreamWindow?, readTarget: () -> EventStreamAXElement?, at now: Date) {
        guard isRunning, !isPaused, observeAvailability(app: app, now: now, idleSeconds: 0),
              allowsInteraction(app: app, window: window) else { return }
        let target = readTarget()
        append(kind: button == "right" ? .mouseContextMenu : .mouseClick, at: now,
               app: app, window: window,
               mouse: EventStreamMouseInteraction(
                   button: button, clickCount: clickCount,
                   modifiers: modifiers, target: target),
               keyboard: nil, selection: nil, ax: nil)
    }

    /// 记录一次触控板/鼠标滚轮滚动。
    public func recordScroll(
        deltaX: Double,
        deltaY: Double,
        modifiers: [String],
        location: CGPoint? = nil,
        at now: Date = Date()
    ) {
        guard isRunning, !isPaused, deltaX != 0 || deltaY != 0 else { return }
        let app = FrontmostApplication.current()
        guard observeAvailability(app: app, now: now, idleSeconds: 0) else { return }
        if lastScrollPID == app?.processIdentifier, let last = lastScrollTime,
           treeApp?.processIdentifier == lastScrollPID, treeContext?.windowID == lastScrollWindowID,
           treeContext?.url == lastScrollURL, now.timeIntervalSince(last) < scrollThrottleInterval { return }
        let window = FrontmostApplication.frontWindow(for: app)
        recordScroll(deltaX: deltaX, deltaY: deltaY, modifiers: modifiers, app: app, window: window,
                     readTarget: {
                         location.flatMap { FrontmostApplication.clickedElement(at: $0, for: app, window: window) }
                     }, at: now)
    }

    func recordScroll(deltaX: Double, deltaY: Double, modifiers: [String], app: EventStreamApp?,
                      window: EventStreamWindow?, readTarget: () -> EventStreamAXElement?, at now: Date) {
        guard isRunning, !isPaused, observeAvailability(app: app, now: now, idleSeconds: 0),
              allowsInteraction(app: app, window: window), deltaX != 0 || deltaY != 0 else { return }

        // 连续滚动进行适度节流（同一应用和窗口内 1.0 秒内只记一次落盘事件），
        // 避免高频滚动手势产生过多冗余事件。
        let pid = app?.processIdentifier
        let winID = window?.windowID
        if let last = lastScrollTime,
           lastScrollPID == pid,
           lastScrollWindowID == winID,
           lastScrollURL == window?.url,
           now.timeIntervalSince(last) < scrollThrottleInterval {
            return
        }
        lastScrollTime = now
        lastScrollPID = pid
        lastScrollWindowID = winID
        lastScrollURL = window?.url

        let target = readTarget()
        append(kind: .mouseScroll, at: now,
               app: app, window: window,
               mouse: EventStreamMouseInteraction(
                   button: "scroll", clickCount: nil,
                   modifiers: modifiers, target: target),
               keyboard: nil, selection: nil, ax: nil)
    }

    /// 记录一次快捷键。
    public func recordShortcut(
        keyEquivalent: String,
        modifiers: [String],
        at now: Date = Date()
    ) {
        guard isRunning, !isPaused else { return }
        let app = FrontmostApplication.current()
        let window = FrontmostApplication.frontWindow(for: app)
        guard observeAvailability(app: app, now: now, idleSeconds: 0),
              allowsInteraction(app: app, window: window) else { return }
        append(kind: .keyboardShortcut, at: now,
               app: app, window: window, mouse: nil,
               keyboard: EventStreamKeyboardInteraction(
                   keyEquivalent: keyEquivalent, modifiers: modifiers,
                   target: FrontmostApplication.focusedElement()),
               selection: nil, ax: nil)
    }

    /// 记录一次文本输入。
    public func recordTextInput(_ text: String, at now: Date = Date()) {
        guard isRunning, !isPaused, !text.isEmpty else { return }
        let app = FrontmostApplication.current()
        let window = FrontmostApplication.frontWindow(for: app)
        guard observeAvailability(app: app, now: now, idleSeconds: 0),
              allowsInteraction(app: app, window: window) else { return }
        append(kind: .keyboardTextInput, at: now,
               app: app, window: window, mouse: nil,
               keyboard: EventStreamKeyboardInteraction(
                   text: text, target: FrontmostApplication.focusedElement()),
               selection: nil, ax: nil)
    }

    /// 记录一次提交（回车）。
    public func recordSubmit(at now: Date = Date()) {
        guard isRunning, !isPaused else { return }
        let app = FrontmostApplication.current()
        let window = FrontmostApplication.frontWindow(for: app)
        guard observeAvailability(app: app, now: now, idleSeconds: 0),
              allowsInteraction(app: app, window: window) else { return }
        append(kind: .keyboardSubmit, at: now,
               app: app, window: window, mouse: nil,
               keyboard: EventStreamKeyboardInteraction(
                   keyEquivalent: "\r", target: FrontmostApplication.focusedElement()),
               selection: nil, ax: nil)
    }

    /// 轮询一次聚焦元素的文本，按需产出 `keyboard.text_input`。
    ///
    /// 为什么是读值而非映射键码：`keyboard.text` 是输入法提交的文本
    /// （实测含拼音串），逐键映射拿不到输入法结果，中文更无从还原。
    public func sampleTextInput(now: Date = Date()) {
        guard isRunning, !isPaused else { return }
        let app = FrontmostApplication.current()
        guard observeAvailability(app: app, now: now) else { return }

        sampleTextInput(app: app, window: FrontmostApplication.frontWindow(for: app),
                        readFocused: { FrontmostApplication.focusedTextSnapshot(for: app) }, now: now)
    }

    func sampleTextInput(app: EventStreamApp?, window: EventStreamWindow?,
                         readFocused: () -> (TextInputTracker.Observation, EventStreamAXElement?),
                         now: Date) {
        guard isRunning, !isPaused else { return }
        guard observeAvailability(app: app, now: now), retryPendingText(at: now) else { return }
        guard let app else {
            guard flushTextInput(at: now) else { return }
            textTracker.resetBaseline()
            pendingText = []
            textContext = nil
            return
        }
        if textContext?.app.bundleIdentifier != app.bundleIdentifier
            || textContext?.app.processIdentifier != app.processIdentifier
            || textContext?.window?.windowID != window?.windowID
            || textContext?.window?.url != window?.url {
            guard flushTextInput(at: now) else { return }
            textTracker.resetBaseline()
            pendingText = []
            textContext = nil
        }
        // 必须在读取控件值之前判断，屏蔽内容不能进入输入缓冲。
        if config.policy.shouldSuppress(app: app, window: window) {
            if config.tracksSuppression { writer?.noteSuppressed() }
            textTracker.resetBaseline()
            pendingText = []
            textContext = nil
            return
        }
        var (obs, target) = readFocused()
        if textContext?.focusIdentity != obs.focusIdentity {
            guard flushTextInput(at: now) else { return }
            textTracker.resetBaseline()
            pendingText = []
            textContext = nil
        }
        if obs.hasInputActivity == nil, let inputActivity {
            let age = now.timeIntervalSince(inputActivity.at)
            obs.hasInputActivity = inputActivity.pid == app.processIdentifier
                && inputActivity.windowID == window?.windowID && inputActivity.url == window?.url
                && inputActivity.focus == obs.focusIdentity && age >= 0 && age <= 2
        }
        // 明确 placeholder 仅在没有编辑活动时排除；真正键入相同文字仍保留。
        if let placeholder = obs.placeholder, !placeholder.isEmpty,
           obs.value == placeholder, obs.hasInputActivity != true {
            obs.isPlaceholder = true
        }
        let context = TextContext(app: app, window: window,
                                  focusIdentity: obs.focusIdentity, target: target)
        textContext?.app = app
        textContext?.window = window
        let fragments = textTracker.observe(obs, at: now)
        pendingText = fragments.map { ($0, textContext ?? context) }
        _ = retryPendingText(at: now)
        textContext = context
    }

    @discardableResult
    private func flushTextInput(at now: Date) -> Bool {
        guard retryPendingText(at: now) else { return false }
        let fragments = textTracker.flush()
        if let context = textContext { pendingText = fragments.map { ($0, context) } }
        return retryPendingText(at: now)
    }

    private func retryPendingText(at now: Date) -> Bool {
        // Do not consume more observations while this one flush is awaiting persistence.
        while let pending = pendingText.first {
            guard writeTextInput(pending.fragment, context: pending.context, at: now) else { return false }
            pendingText.removeFirst()
        }
        return true
    }

    private func writeTextInput(_ fragment: TextInputTracker.Fragment, context: TextContext, at now: Date) -> Bool {
        guard !fragment.text.isEmpty else { return true }
        let eventID = nextID
        let written = append(kind: .keyboardTextInput, at: now,
               app: context.app, window: context.window, mouse: nil,
               keyboard: EventStreamKeyboardInteraction(text: fragment.text, textEvidence: fragment.evidence,
                                                        focusIdentity: context.focusIdentity, textReplaces: fragment.replaces, target: context.target),
               selection: nil, ax: nil)
        if written, let segment = currentSegmentID {
            textTracker.acknowledge(fragment, reference: "\(segment)#\(eventID)")
        }
        return written
    }

    /// 记录一次文本选中变化。
    public func recordSelection(_ selection: EventStreamSelection, at now: Date = Date()) {
        guard isRunning, !isPaused else { return }
        let app = FrontmostApplication.current()
        guard observeAvailability(app: app, now: now) else { return }
        append(kind: .selectionChanged, at: now,
               app: app, window: FrontmostApplication.frontWindow(for: app), mouse: nil, keyboard: nil,
               selection: selection, ax: nil)
    }

    @discardableResult
    func observeAvailability(app: EventStreamApp?, now: Date, idleSeconds: TimeInterval? = nil) -> Bool {
        guard !isPaused else { return false }
        var changed = false
        let reason: AwayPeriods.Reason?
        if AwayPeriods.isLoginWindow(app) { reason = .locked }
        else if let idleSeconds, idleSeconds.isFinite, idleSeconds >= AwayPeriods.idleThreshold { reason = .idle }
        else if away.startedAt != nil && (app == nil || (away.startedReason == .idle && idleSeconds == nil)) {
            return false
        } else { reason = nil }
        let currentReason = away.startedAt.map { _ in away.startedReason ?? .locked }
        if reason != currentReason, let start = away.startedAt {
            away.periods.append(.init(start: start, end: max(start, now), reason: away.startedReason))
            away.startedAt = nil
            away.startedReason = nil
            changed = true
        }
        if let reason, away.startedAt == nil {
            windowTextEpoch += 1; windowTextContext = nil; lastWindowText = nil
            flushTextInput(at: now)
            away.startedAt = now
            away.startedReason = reason
            changed = true
            do {
                try writer?.close(endedAt: now, endReason: nil, inputListeningDegraded: hadDegradedInputListening)
                writer = nil
                currentSegmentID = nil
            } catch {
                FileHandle.standardError.write(Data("封口离开前的事件段失败：\(error)\n".utf8))
            }
        }
        if changed {
            frontmostSampleEpoch += 1
            textTracker.resetBaseline()
            pendingText = []
            textContext = nil
            inputActivity = nil
            previousTree = nil
            lastSnapshotText = nil
            do { try away.save(root: config.rootDirectory) }
            catch { FileHandle.standardError.write(Data("保存离开时段失败：\(error)\n".utf8)) }
        }
        return !isAway
    }

    private func finishIdlePeriod(at now: Date) {
        guard away.startedReason == .idle, let start = away.startedAt else { return }
        away.periods.append(.init(start: start, end: max(start, now), reason: .idle))
        away.startedAt = nil
        away.startedReason = nil
        do { try away.save(root: config.rootDirectory) }
        catch { FileHandle.standardError.write(Data("保存无操作时段失败：\(error)\n".utf8)) }
    }

    // MARK: - 内部

    private func allowsInteraction(app: EventStreamApp?, window: EventStreamWindow?) -> Bool {
        guard config.policy.shouldSuppress(app: app, window: window) else { return true }
        if config.tracksSuppression { writer?.noteSuppressed() }
        return false
    }

    /// 生成差分 ax：有上一帧则为 `diffFromPrevious`，否则整树。
    /// 超预算时 `lines(...)` 返回 nil，回退为整树——与实测行为一致。
    private func makeAXTree(current: [UIElementRender],
                            currentText: String) -> EventStreamAXTree? {
        guard !current.isEmpty else { return nil }
        guard let previous = previousTree, !previous.isEmpty else {
            return EventStreamAXTree(mode: .fullTree, text: currentText)
        }
        if let diff = UIElementRenderDifference.lines(from: previous, to: current, includesUnchangedContext: false) {
            return EventStreamAXTree(mode: .diffFromPrevious,
                                     text: diff.joined(separator: "\n"))
        }
        // 预算超限：回退整树
        return EventStreamAXTree(mode: .fullTree, text: currentText)
    }

    @discardableResult
    private func append(
        kind: EventStreamEventKind,
        at date: Date,
        app: EventStreamApp?,
        window: EventStreamWindow?,
        mouse: EventStreamMouseInteraction?,
        keyboard: EventStreamKeyboardInteraction?,
        selection: EventStreamSelection?,
        ax: EventStreamAXTree?,
        activityWatch: ActivityWatchEvidence? = nil
    ) -> Bool {
        // 暂停期间一律不写入。输入事件由事件监听回调触发，不经过采样入口，
        // 因此这里也要挡一次。
        guard !isPaused, !isAway else { return false }

        // 抑制判定：命中则只计数，不落主文件。
        if kind != .sessionStarted, kind != .sessionEnded,
           config.policy.shouldSuppress(app: app, window: window) {
            if config.tracksSuppression { writer?.noteSuppressed() }
            return false
        }
        do {
            try rotateIfNeeded(now: date, force: false)
            guard let writer else { return false }
            let record = EventStreamRecord(
                id: nextID, timestamp: date, kind: kind,
                app: app, window: window, mouse: mouse,
                keyboard: keyboard, selection: selection, ax: ax, activityWatch: activityWatch)
            try writer.append(record)
            nextID += 1
            totalEventsWritten += 1
            if lastWriteError != nil {
                FileHandle.standardError.write(Data("事件写入已恢复。\n".utf8))
                lastWriteError = nil
            }
            return true
        } catch {
            writeFailureCount += 1
            lastWriteError = String(describing: error)
            previousTree = nil
            lastSnapshotText = nil
            lastWindowText = nil
            FileHandle.standardError.write(
                "写入事件失败：\(error)\n".data(using: .utf8)!)
            return false
        }
    }

    /// 按需切段。跨过 10 分钟边界时封口旧段、开新段。
    private func rotateIfNeeded(now: Date, force: Bool) throws {
        if !force, let writer,
           !SegmentClock.isExpired(writer.startedAt, now: now) {
            return
        }
        if let writer {
            try writer.close(endedAt: now, endReason: nil, inputListeningDegraded: hadDegradedInputListening)
        }
        let w = try SegmentWriter(rootDirectoryURL: config.rootDirectory, start: now)
        writer = w
        currentSegmentID = w.segmentID
        hadDegradedInputListening = !isInputListeningActive
        previousTree = nil
        lastSnapshotText = nil

        // 借轮转时机清理旧段：后台长跑时轮转每 10 分钟一次，足够及时，
        // 又不必额外起定时器。清理失败不影响采集。
        let report = SegmentPruner.prune(rootDirectory: config.rootDirectory,
                                        retention: config.retention, now: now,
                                        activeSegmentID: w.segmentID)
        if report.removedWithoutSummary > 0 {
            FileHandle.standardError.write("保留上限已淘汰 \(report.removedWithoutSummary) 个未完成总结的段。\n".data(using: .utf8)!)
        }
        lastPruneReport = report.removedSegments > 0 || !report.failures.isEmpty ? report : nil
        for failure in report.failures {
            FileHandle.standardError.write(
                "清理失败（\(failure.operation.rawValue)）：\(failure.directory.path)：\(failure.message)\n".data(using: .utf8)!)
        }
    }
}
