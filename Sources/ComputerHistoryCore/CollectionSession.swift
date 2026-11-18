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

    struct ContentReaders {
        typealias TreeRead = @Sendable (FrontmostSnapshotContext, Int, @escaping () -> Bool) -> [UIElementRender]?
        var currentApp = FrontmostApplication.current
        var window: (EventStreamApp, AccessibilityRead) -> ObservedWindow? = { app, access in
            FrontmostApplication.observedWindow(pid: app.processIdentifier, access: access)
        }
        var inputWindowMatches: (EventStreamApp, ObservedWindow, AccessibilityRead) -> Bool = FrontmostApplication.focusedWindowMatches
        var tree: TreeRead = { context, limit, isAllowed in
            guard let reference = context.observedWindow?.reference else { return nil }
            return AXTreeReader.snapshot(window: reference, maxNodes: limit, isAllowed: isAllowed)
        }
        var focusedText = FrontmostApplication.focusedTextSnapshot(for:window:access:)
        var focusedTarget = FrontmostApplication.focusedElement(for:window:access:)
        var clickedTarget = FrontmostApplication.clickedElement(at:for:window:access:)
        var idleSeconds: () -> TimeInterval? = { InputTap.secondsSinceLastInput }
        var prepare: (inout AccessibilityActivation, Int32, Date, AccessibilityRead) -> Void = { state, pid, now, access in
            state.prepare(pid: pid, now: now, access: access)
        }
    }

    private let readers: ContentReaders
    private let secureInput: SecureInputMonitor
    private var appliedSecureInputEpoch = 0

    public func canSampleContent() -> Bool {
        let state = secureInput.refresh()
        if appliedSecureInputEpoch != state.epoch {
            appliedSecureInputEpoch = state.epoch
            invalidateContent()
        }
        return isRunning && !isPaused && !isSystemSleeping && !state.enabled
    }

    private var activityWatchSince = Date()
    private var activityWatchCursor: Date?
    private var accessibilityActivation = AccessibilityActivation()
    private(set) var frontmostSampleInFlight = false
    private var frontmostSampleEpoch = 0
    private var frontmostSampleContext: FrontmostSnapshotContext?
    private var windowEpoch = 0
    private var config: Configuration
    private var writer: SegmentWriter?
    private var nextID = 1
    /// 上一帧已编号的树，直接用于差分；避免"渲染再反解"的绕行。
    private var previousTree: [UIElementRender]?
    private var lastSnapshotText: String?
    private var treeContext: FrontmostSnapshotContext?
    private var isRunning = false
    public struct WindowTextContext: Sendable, Equatable {
        public var app: EventStreamApp
        public var window: EventStreamWindow?
        var epoch: Int

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.epoch == rhs.epoch && lhs.app.processIdentifier == rhs.app.processIdentifier
                && lhs.app.bundleIdentifier == rhs.app.bundleIdentifier
                && lhs.window?.windowID == rhs.window?.windowID && lhs.window?.url == rhs.window?.url
        }
    }
    public private(set) var windowTextContext: WindowTextContext?
    private var windowTextEpoch = 0
    private var lastWindowText: (context: WindowTextContext, text: String)?
    private var away: AwayPeriods
    public private(set) var isSystemSleeping = false
    public var isAway: Bool { away.startedAt != nil }

    public func applyConfiguration(_ updated: CollectorConfig) {
        invalidateContent()
        config = Configuration(rootDirectory: config.rootDirectory, config: updated,
                               tracksSuppression: config.tracksSuppression)
    }

    private func invalidateAXSnapshot() {
        frontmostSampleEpoch += 1
        windowTextEpoch += 1
        windowTextContext = nil
        lastWindowText = nil
        previousTree = nil
        lastSnapshotText = nil
        treeContext = nil
    }

    private func invalidateContent() {
        invalidateAXSnapshot()
        frontmostSampleContext = nil
        activityWatchSince = Date()
        activityWatchCursor = nil
        textTracker.resetBaseline()
        pendingText = []
        textContext = nil
        inputActivity = nil
        lastScroll = nil
    }

    /// 最近一次清理结果，供 CLI 汇报。
    public private(set) var lastPruneReport: PruneReport?

    /// 是否暂停记录。由调用方按运行开关设置——会话本身不读文件，
    /// 保持它与存储布局无关，也便于测试。
    public var isPaused = false {
        didSet {
            guard isPaused != oldValue else { return }
            if isPaused { finishIdlePeriod(at: Date()) }
            invalidateContent()
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
        var owner: FrontmostSnapshotContext
        var epoch: Int
        var focusIdentity: Int?
        var target: EventStreamAXElement?
    }
    private var textContext: TextContext?
    private var pendingText: [(fragment: TextInputTracker.Fragment, context: TextContext)] = []
    private var inputActivity: (owner: FrontmostSnapshotContext, focus: Int?, at: Date)?
    private var lastScroll: (owner: FrontmostSnapshotContext, at: Date)?
    private let scrollThrottleInterval: TimeInterval = 1.0

    /// 只记录交互时间与上下文，不保存原始键码或键入内容。
    public func noteInputActivity(at now: Date = Date()) {
        guard canSampleContent() else { return }
        let app = readers.currentApp()
        guard observeAvailability(app: app, now: now, idleSeconds: 0),
              let baseline = textContext, baseline.epoch == windowEpoch,
              let window = baseline.owner.observedWindow else { return }
        guard let app, baseline.owner.app.processIdentifier == app.processIdentifier,
              baseline.owner.app.bundleIdentifier == app.bundleIdentifier else {
            observeWindow(nil)
            return
        }
        let access = contentAccess()
        let matches = readers.inputWindowMatches(app, window, access)
        guard accept(access), matches else {
            // Wait for the next observation after a switch or a failed window query.
            observeWindow(nil)
            return
        }
        noteInputActivity(in: baseline.owner, at: now)
    }

    func noteInputActivity(in owner: FrontmostSnapshotContext?, at now: Date) {
        guard canSampleContent(), !isAway, let baseline = textContext,
              baseline.epoch == windowEpoch, owner?.matches(baseline.owner) == true else { return }
        inputActivity = (baseline.owner, baseline.focusIdentity, now)
    }

    /// 供外部观察状态。
    public private(set) var currentSegmentID: String?
    public private(set) var totalEventsWritten = 0
    public private(set) var writeFailureCount = 0
    public private(set) var lastWriteError: String?

    public convenience init(configuration: Configuration) {
        self.init(configuration: configuration, readers: .init(), secureInput: FrontmostApplication.secureInputState)
    }

    init(configuration: Configuration, readers: ContentReaders, secureInput: @escaping @Sendable () -> Bool) {
        self.config = configuration
        self.readers = readers
        self.secureInput = SecureInputMonitor(read: secureInput)
        self.away = AwayPeriods.load(root: configuration.rootDirectory)
        self.isSystemSleeping = away.systemSleep == true
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
        _ = canSampleContent()
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

    private func contentAccess() -> AccessibilityRead {
        let monitor = secureInput
        let state = monitor.refresh()
        return AccessibilityRead { !state.enabled && monitor.refresh() == state }
    }

    private func accept(_ access: AccessibilityRead) -> Bool {
        guard canSampleContent() else { return false }
        if access.communicationFailed { invalidateAXSnapshot() }
        return access.canRead
    }

    /// 采样一次前台应用与 AX 树，产出 `window.changed`（内容有变化时）。
    ///
    /// 调用频率由外部决定；真实服务在窗口/应用切换时触发。
    public func sampleFrontmost(now: Date = Date(), force: Bool = false) {
        windowTextContext = nil
        guard canSampleContent() else { return }
        guard let app = readers.currentApp(), observeAvailability(app: app, now: now, idleSeconds: readers.idleSeconds()) else { return }

        let access = contentAccess()
        guard let context = readContext(for: app, access: access) else { return }
        // 命中抑制时直接返回：既为隐私，也省下每帧整棵树的遍历开销。
        // 后台长跑时这是主要的 CPU 成本。
        if config.policy.shouldSuppress(app: app, window: context.window) {
            if config.tracksSuppression { writer?.noteSuppressed() }
            return
        }

        var roots: [UIElementRender] = []
        if let pid = app.processIdentifier {
            readers.prepare(&accessibilityActivation, pid, now, access)
            guard accept(access) else { return }
            if context.hasWindowIdentity {
                guard let tree = readers.tree(context, config.maxNodesPerSnapshot, { access.canRead }) else {
                    invalidateAXSnapshot()
                    return
                }
                roots = tree
            }
        }

        guard accept(access) else { return }
        recordSnapshot(roots: roots, context: context, now: now, force: force)
        updateWindowTextContext(roots: roots, app: app, window: context.window)
    }

    struct FrontmostSnapshotContext: Sendable {
        var app: EventStreamApp
        var observedWindow: ObservedWindow?

        init(app: EventStreamApp, observedWindow: ObservedWindow?) {
            self.app = app
            self.observedWindow = observedWindow
        }

        init(app: EventStreamApp, window: EventStreamWindow?) {
            self.init(app: app, observedWindow: window.map { .init(details: $0) })
        }

        var window: EventStreamWindow? { observedWindow?.details }
        var hasWindowIdentity: Bool { observedWindow?.hasIdentity == true }

        func matches(_ other: Self?) -> Bool {
            guard sameApp(as: other) else { return false }
            return observedWindow?.matches(other?.observedWindow) == true
        }

        func sameUnresolvedApp(as other: Self?) -> Bool {
            !hasWindowIdentity && other?.hasWindowIdentity == false && sameApp(as: other)
                && window?.url == other?.window?.url
        }

        private func sameApp(as other: Self?) -> Bool {
            guard let other else { return false }
            return app.processIdentifier == other.app.processIdentifier && app.bundleIdentifier == other.app.bundleIdentifier
        }
    }

    private func observeWindow(_ context: FrontmostSnapshotContext?) {
        let same = context.map { $0.matches(frontmostSampleContext) || $0.sameUnresolvedApp(as: frontmostSampleContext) }
            ?? (frontmostSampleContext == nil)
        if !same {
            invalidateAXSnapshot()
            windowEpoch += 1
            inputActivity = nil
        }
        frontmostSampleContext = context
    }

    private func readContext(for app: EventStreamApp?, access: AccessibilityRead) -> FrontmostSnapshotContext? {
        let observed = app.flatMap { readers.window($0, access) }
        guard accept(access) else {
            if access.communicationFailed { observeWindow(nil) }
            return nil
        }
        let context = app.map { FrontmostSnapshotContext(app: $0, observedWindow: observed) }
        observeWindow(context)
        return context
    }

    private func frontmostContext() -> FrontmostSnapshotContext? {
        guard canSampleContent() else { return nil }
        let app = readers.currentApp()
        guard app?.secureInput != true else { return nil }
        return readContext(for: app, access: contentAccess())
    }

    @MainActor
    public func sampleFrontmostAsync(now: Date = Date(), force: Bool = false) {
        _ = pollFrontmost(now: now, force: force, includeText: false, debugText: false)
    }

    @MainActor
    public func pollFrontmost(now: Date = Date(), debugText: Bool = false)
        -> (app: EventStreamApp, observation: TextInputTracker.Observation)? {
        pollFrontmost(now: now, force: false, includeText: true, debugText: debugText)
    }

    @MainActor
    private func pollFrontmost(now: Date, force: Bool, includeText: Bool, debugText: Bool)
        -> (app: EventStreamApp, observation: TextInputTracker.Observation)? {
        guard canSampleContent() else { return nil }
        let app = readers.currentApp()
        let idleSeconds = readers.idleSeconds()
        let access = contentAccess()
        guard observeAvailability(app: app, now: now, idleSeconds: idleSeconds) else { return nil }
        let context = readContext(for: app, access: access)
        guard access.canRead else { return nil }
        sampleFrontmostAsync(context: context, now: now, force: force, idleSeconds: idleSeconds,
            prepare: { pid in
                readers.prepare(&accessibilityActivation, pid, now, access)
                return accept(access)
            },
            read: readers.tree, currentContext: { [weak self] in self?.frontmostContext() })
        guard includeText, access.canRead else { return nil }
        let observation = sampleTextInput(context: context,
            readFocused: { readFocusedText(context: context, access: access) }, now: now)
        guard debugText, let app, let observation, canSampleContent(), access.canRead else { return nil }
        return (app, observation)
    }

    @MainActor
    func sampleFrontmostAsync(
        context: FrontmostSnapshotContext?, now: Date, force: Bool = false,
        idleSeconds: TimeInterval? = nil,
        prepare: (Int32) -> Bool = { _ in true },
        read: @escaping ContentReaders.TreeRead,
        currentContext: @escaping @MainActor @Sendable () -> FrontmostSnapshotContext?,
        completedAt: @escaping @MainActor @Sendable () -> Date = { Date() }
    ) {
        guard canSampleContent() else { windowTextContext = nil; return }
        observeWindow(context)
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
        guard !frontmostSampleInFlight else { return }
        if let pid = context.app.processIdentifier, !prepare(pid) { return }
        guard canSampleContent() else { return }
        guard context.hasWindowIdentity else {
            recordSnapshot(roots: [], context: context, now: now, force: force)
            return
        }
        let maxNodes = config.maxNodesPerSnapshot
        let epoch = frontmostSampleEpoch
        let monitor = secureInput
        let secureState = monitor.refresh()
        guard !secureState.enabled else { return }
        frontmostSampleInFlight = true
        // The worker reads the captured window proxy. Session state stays on the main actor.
        let complete: @MainActor @Sendable ([UIElementRender]?) -> Void = { [weak self] roots in
            guard let self else { return }
            self.frontmostSampleInFlight = false
            guard self.canSampleContent(), self.frontmostSampleEpoch == epoch, !self.isAway else { return }
            guard let roots else {
                self.invalidateAXSnapshot()
                return
            }
            guard let current = currentContext(), context.matches(current),
                  self.canSampleContent(), self.frontmostSampleEpoch == epoch,
                  !self.config.policy.shouldSuppress(app: current.app, window: current.window) else { return }
            // Input events can be written while AX is reading, including after a segment boundary.
            let finishedAt = completedAt()
            self.recordSnapshot(roots: roots, context: current, now: finishedAt, force: force)
            self.updateWindowTextContext(roots: roots, app: current.app, window: current.window)
        }
        DispatchQueue.global(qos: .utility).async {
            let isAllowed = { monitor.refresh() == secureState }
            let roots = isAllowed() ? read(context, maxNodes, isAllowed) : nil
            DispatchQueue.main.async { complete(roots) }
        }
    }

    func updateWindowTextContext(roots: [UIElementRender], app: EventStreamApp, window: EventStreamWindow?) {
        guard canSampleContent(), !isAway, window?.windowID != nil,
              config.windowTextApplications.contains(app.bundleIdentifier ?? ""),
              !config.windowTextDisabledApplications.contains(app.bundleIdentifier ?? ""),
              !config.policy.shouldSuppress(app: app, window: window),
              !AXTreeReader.hasReadableContent(roots) else { windowTextContext = nil; return }
        windowTextContext = WindowTextContext(app: app, window: window, epoch: windowTextEpoch)
    }

    public func recordActivityWatch(_ snapshot: ActivityWatchSnapshot, now: Date = Date()) {
        guard canSampleContent(), let current = readers.currentApp() else { return }
        recordActivityWatch(snapshot, current: current, now: now)
    }

    func recordActivityWatch(_ snapshot: ActivityWatchSnapshot, current: EventStreamApp, now: Date) {
        guard config.activityWatchEnabled, canSampleContent(), !isAway,
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

    public func allowsWindowTextSampling(_ context: WindowTextContext) -> Bool {
        canSampleContent() && !isAway && context == windowTextContext
            && readers.currentApp()?.processIdentifier == context.app.processIdentifier
    }

    public func acceptsWindowTextResult(_ context: WindowTextContext) -> Bool {
        guard allowsWindowTextSampling(context), let current = frontmostContext() else { return false }
        let owner = FrontmostSnapshotContext(app: context.app, window: context.window)
        return current.matches(owner) && context == windowTextContext
    }

    public func recordWindowText(_ result: WindowTextReader.Result, context: WindowTextContext, now: Date = Date()) {
        guard canSampleContent(), !isAway, context == windowTextContext,
              !config.policy.shouldSuppress(app: context.app, window: context.window),
              !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let expired = writer.map { SegmentClock.isExpired($0.startedAt, now: now) } ?? false
        if !expired, let lastWindowText, lastWindowText.context == context, lastWindowText.text == result.text { return }
        guard let window = context.window, window.windowID == result.windowID else { return }
        let lines = result.text.split(separator: "\n").enumerated().map { index, text in
            "\(index) 文本 Value: \(text)"
        }.joined(separator: "\n")
        if append(kind: .windowChanged, at: now, app: context.app, window: window,
                  mouse: nil, keyboard: nil, selection: nil,
                  ax: .init(mode: .fullTree, text: lines, source: "window_ocr")) {
            lastWindowText = (context, result.text)
        }
    }

    func recordSnapshot(roots: [UIElementRender], context: FrontmostSnapshotContext, now: Date, force: Bool = false) {
        let app = context.app, window = context.window
        guard canSampleContent(), observeAvailability(app: app, now: now), !config.policy.shouldSuppress(app: app, window: window) else { return }
        let numbered = UIElementRenderTree.assignElementIDs(roots)
        let treeText = UIElementRenderTree.text(numbered)
        let expired = writer.map { SegmentClock.isExpired($0.startedAt, now: now) } ?? false
        if !force, !expired, treeText.isEmpty, lastSnapshotText == "", context.sameUnresolvedApp(as: treeContext) { return }
        if !context.matches(treeContext) || expired {
            previousTree = nil; lastSnapshotText = nil
            windowTextEpoch += 1; windowTextContext = nil; lastWindowText = nil
        }
        treeContext = context
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
        guard canSampleContent() else { return }
        let app = readers.currentApp()
        guard observeAvailability(app: app, now: now, idleSeconds: 0) else { return }
        let access = contentAccess()
        let context = readContext(for: app, access: access)
        guard access.canRead else { return }
        let window = context?.window
        recordClick(button: button, clickCount: clickCount, modifiers: modifiers, app: app,
                    window: window, readTarget: {
                        let target = location.flatMap { readers.clickedTarget($0, app, context?.observedWindow, access) }
                        if button == "left", target != nil { noteInputActivity(in: context, at: now) }
                        return target
                    }, at: now)
    }

    func recordClick(button: String, clickCount: Int, modifiers: [String], app: EventStreamApp?,
                     window: EventStreamWindow?, readTarget: () -> EventStreamAXElement?, at now: Date) {
        guard canSampleContent(), observeAvailability(app: app, now: now, idleSeconds: 0),
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
        guard canSampleContent(), deltaX != 0 || deltaY != 0 else { return }
        let app = readers.currentApp()
        guard observeAvailability(app: app, now: now, idleSeconds: 0) else { return }
        let access = contentAccess()
        let context = readContext(for: app, access: access)
        guard access.canRead else { return }
        recordScroll(deltaX: deltaX, deltaY: deltaY, modifiers: modifiers, context: context,
                     readTarget: {
                         location.flatMap { readers.clickedTarget($0, app, context?.observedWindow, access) }
                     }, at: now)
    }

    func recordScroll(deltaX: Double, deltaY: Double, modifiers: [String], context: FrontmostSnapshotContext?,
                      readTarget: () -> EventStreamAXElement?, at now: Date) {
        let app = context?.app, window = context?.window
        guard canSampleContent(), observeAvailability(app: app, now: now, idleSeconds: 0),
              allowsInteraction(app: app, window: window), deltaX != 0 || deltaY != 0 else { return }

        // 连续滚动进行适度节流（同一应用和窗口内 1.0 秒内只记一次落盘事件），
        // 避免高频滚动手势产生过多冗余事件。
        if let lastScroll, context?.matches(lastScroll.owner) == true,
           now.timeIntervalSince(lastScroll.at) < scrollThrottleInterval { return }
        lastScroll = context.map { ($0, now) }

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
        guard canSampleContent() else { return }
        let app = readers.currentApp()
        guard observeAvailability(app: app, now: now, idleSeconds: 0) else { return }
        let access = contentAccess()
        let context = readContext(for: app, access: access)
        let window = context?.window
        guard access.canRead, allowsInteraction(app: app, window: window) else { return }
        noteInputActivity(in: context, at: now)
        append(kind: .keyboardShortcut, at: now,
               app: app, window: window, mouse: nil,
               keyboard: EventStreamKeyboardInteraction(
                   keyEquivalent: keyEquivalent, modifiers: modifiers,
                   target: readers.focusedTarget(app, context?.observedWindow, access)),
               selection: nil, ax: nil)
    }

    /// 记录一次文本输入。
    public func recordTextInput(_ text: String, at now: Date = Date()) {
        guard canSampleContent(), !text.isEmpty else { return }
        let app = readers.currentApp()
        guard observeAvailability(app: app, now: now, idleSeconds: 0) else { return }
        let access = contentAccess()
        let context = readContext(for: app, access: access)
        let window = context?.window
        guard access.canRead, allowsInteraction(app: app, window: window) else { return }
        append(kind: .keyboardTextInput, at: now,
               app: app, window: window, mouse: nil,
               keyboard: EventStreamKeyboardInteraction(
                   text: text, target: readers.focusedTarget(app, context?.observedWindow, access)),
               selection: nil, ax: nil)
    }

    /// 记录一次提交（回车）。
    public func recordSubmit(at now: Date = Date()) {
        guard canSampleContent() else { return }
        let app = readers.currentApp()
        guard observeAvailability(app: app, now: now, idleSeconds: 0) else { return }
        let access = contentAccess()
        let context = readContext(for: app, access: access)
        let window = context?.window
        guard access.canRead, allowsInteraction(app: app, window: window) else { return }
        noteInputActivity(in: context, at: now)
        append(kind: .keyboardSubmit, at: now,
               app: app, window: window, mouse: nil,
               keyboard: EventStreamKeyboardInteraction(
                   keyEquivalent: "\r", target: readers.focusedTarget(app, context?.observedWindow, access)),
               selection: nil, ax: nil)
    }

    public func debugTextObservation() -> (app: EventStreamApp?, observation: TextInputTracker.Observation)? {
        guard canSampleContent(), !isAway else { return nil }
        let app = readers.currentApp()
        guard app?.secureInput != true else { return nil }
        let access = contentAccess()
        let context = readContext(for: app, access: access)
        guard access.canRead, !config.policy.shouldSuppress(app: app, window: context?.window),
              let (observation, _) = readFocusedText(context: context, access: access) else { return nil }
        return (app, observation)
    }

    /// 轮询一次聚焦元素的文本，按需产出 `keyboard.text_input`。
    ///
    /// 为什么是读值而非映射键码：`keyboard.text` 是输入法提交的文本
    /// （实测含拼音串），逐键映射拿不到输入法结果，中文更无从还原。
    public func sampleTextInput(now: Date = Date()) {
        guard canSampleContent() else { return }
        let app = readers.currentApp()
        guard observeAvailability(app: app, now: now) else { return }

        let access = contentAccess()
        let context = readContext(for: app, access: access)
        guard access.canRead else { return }
        sampleTextInput(context: context, readFocused: { readFocusedText(context: context, access: access) }, now: now)
    }

    private func readFocusedText(context: FrontmostSnapshotContext?, access: AccessibilityRead)
        -> (TextInputTracker.Observation, EventStreamAXElement?)? {
        guard let context, context.hasWindowIdentity else { return nil }
        let snapshot = readers.focusedText(context.app, context.observedWindow, access)
        return accept(access) ? snapshot : nil
    }

    @discardableResult
    func sampleTextInput(context owner: FrontmostSnapshotContext?,
                         readFocused: () -> (TextInputTracker.Observation, EventStreamAXElement?)?,
                         now: Date) -> TextInputTracker.Observation? {
        guard canSampleContent(), observeAvailability(app: owner?.app, now: now), retryPendingText(at: now) else { return nil }
        observeWindow(owner)
        if textContext?.epoch != windowEpoch || owner?.matches(textContext?.owner) != true {
            guard flushTextInput(at: now) else { return nil }
            textTracker.resetBaseline()
            pendingText = []
            textContext = nil
        }
        guard let owner, owner.hasWindowIdentity else { return nil }
        // 必须在读取控件值之前判断，屏蔽内容不能进入输入缓冲。
        if config.policy.shouldSuppress(app: owner.app, window: owner.window) {
            if config.tracksSuppression { writer?.noteSuppressed() }
            textTracker.resetBaseline()
            pendingText = []
            textContext = nil
            return nil
        }
        guard canSampleContent(), let (snapshot, target) = readFocused(), canSampleContent() else { return nil }
        var obs = snapshot
        if textContext?.focusIdentity != obs.focusIdentity {
            guard flushTextInput(at: now) else { return nil }
            textTracker.resetBaseline()
            pendingText = []
            textContext = nil
        }
        if obs.hasInputActivity == nil, let inputActivity {
            let age = now.timeIntervalSince(inputActivity.at)
            obs.hasInputActivity = owner.matches(inputActivity.owner) && inputActivity.focus == obs.focusIdentity
                && age >= 0 && age <= 2
        }
        // 明确 placeholder 仅在没有编辑活动时排除；真正键入相同文字仍保留。
        if let placeholder = obs.placeholder, !placeholder.isEmpty,
           obs.value == placeholder, obs.hasInputActivity != true {
            obs.isPlaceholder = true
        }
        let context = TextContext(owner: owner, epoch: windowEpoch,
                                  focusIdentity: obs.focusIdentity, target: target)
        textContext?.owner = owner
        let fragments = textTracker.observe(obs, at: now)
        pendingText = fragments.map { ($0, textContext ?? context) }
        _ = retryPendingText(at: now)
        textContext = context
        return obs
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
            let epoch = appliedSecureInputEpoch
            let written = writeTextInput(pending.fragment, context: pending.context, at: now)
            if appliedSecureInputEpoch != epoch { return true }
            guard written else { return false }
            pendingText.removeFirst()
        }
        return true
    }

    private func writeTextInput(_ fragment: TextInputTracker.Fragment, context: TextContext, at now: Date) -> Bool {
        guard !fragment.text.isEmpty else { return true }
        let eventID = nextID
        let written = append(kind: .keyboardTextInput, at: now,
               app: context.owner.app, window: context.owner.window, mouse: nil,
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
        guard canSampleContent() else { return }
        let app = readers.currentApp()
        guard observeAvailability(app: app, now: now) else { return }
        let access = contentAccess()
        let context = readContext(for: app, access: access)
        guard access.canRead else { return }
        append(kind: .selectionChanged, at: now,
               app: app, window: context?.window, mouse: nil, keyboard: nil,
               selection: selection, ax: nil)
    }

    public func observePower(_ event: SystemPowerObserver.Event) {
        guard isRunning else { return }
        switch event {
        case .willSleep(let at):
            guard !isSystemSleeping else { return }
            if !isPaused {
                away.systemSleep = true
                updateAwayPeriod(to: .locked, at: at, saveWhenUnchanged: true)
            }
            isSystemSleeping = true
        case .didWake:
            guard isSystemSleeping else { return }
            isSystemSleeping = false
            if away.systemSleep == true {
                // Keep the interval open until foreground availability is known; the screen can still be locked.
                away.systemSleep = nil
                saveAway()
            }
        }
    }

    @discardableResult
    func observeAvailability(app: EventStreamApp?, now: Date, idleSeconds: TimeInterval? = nil) -> Bool {
        guard canSampleContent(), app?.secureInput != true else { return false }
        let reason: AwayPeriods.Reason?
        if AwayPeriods.isLoginWindow(app) { reason = .locked }
        else if let idleSeconds, idleSeconds.isFinite, idleSeconds >= AwayPeriods.idleThreshold { reason = .idle }
        else if isAway && (app == nil || (away.startedReason == .idle && idleSeconds == nil)) { return false }
        else { reason = nil }
        updateAwayPeriod(to: reason, at: now)
        return !isAway
    }

    private func updateAwayPeriod(to reason: AwayPeriods.Reason?, at now: Date, saveWhenUnchanged: Bool = false) {
        let currentReason = away.startedAt.map { _ in away.startedReason ?? .locked }
        guard reason != currentReason else {
            if saveWhenUnchanged { saveAway() }
            return
        }
        if let start = away.startedAt {
            away.periods.append(.init(start: start, end: max(start, now), reason: away.startedReason))
            away.startedAt = nil
            away.startedReason = nil
        }
        if let reason {
            _ = flushTextInput(at: now)
            away.startedAt = now
            away.startedReason = reason
            do {
                try writer?.close(endedAt: now, endReason: nil, inputListeningDegraded: hadDegradedInputListening)
                writer = nil
                currentSegmentID = nil
            } catch {
                FileHandle.standardError.write(Data("封口离开前的事件段失败：\(error)\n".utf8))
            }
        }
        invalidateContent()
        saveAway()
    }

    private func saveAway() {
        do { try away.save(root: config.rootDirectory) }
        catch { FileHandle.standardError.write(Data("保存离开时段失败：\(error)\n".utf8)) }
    }

    private func finishIdlePeriod(at now: Date) {
        guard away.startedReason == .idle, let start = away.startedAt else { return }
        away.periods.append(.init(start: start, end: max(start, now), reason: .idle))
        away.startedAt = nil
        away.startedReason = nil
        saveAway()
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
        if kind != .sessionStarted, kind != .sessionEnded {
            guard canSampleContent(), app?.secureInput != true else { return false }
            if config.policy.shouldSuppress(app: app, window: window) {
                if config.tracksSuppression { writer?.noteSuppressed() }
                return false
            }
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
