import Foundation

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

        public init(
            rootDirectory: URL,
            maxNodesPerSnapshot: Int = 4000,
            tracksSuppression: Bool = true,
            policy: ObservationPolicy = .init(),
            retention: CollectorConfig.Retention = .init()
        ) {
            self.rootDirectory = rootDirectory
            self.maxNodesPerSnapshot = maxNodesPerSnapshot
            self.tracksSuppression = tracksSuppression
            self.policy = policy
            self.retention = retention
        }

        /// 由配置文件构造。
        public init(rootDirectory: URL, config: CollectorConfig,
                    tracksSuppression: Bool = true) {
            self.init(rootDirectory: rootDirectory,
                      maxNodesPerSnapshot: config.maxNodesPerSnapshot,
                      tracksSuppression: tracksSuppression,
                      policy: config.policy,
                      retention: config.retention)
        }
    }

    private let config: Configuration
    private var writer: SegmentWriter?
    private var nextID = 1
    /// 上一帧已编号的树，直接用于差分；避免"渲染再反解"的绕行。
    private var previousTree: [UIElementRender]?
    private var lastSnapshotText: String?
    private var isRunning = false

    /// 最近一次清理结果，供 CLI 汇报。
    public private(set) var lastPruneReport: PruneReport?

    /// 是否暂停记录。由调用方按运行开关设置——会话本身不读文件，
    /// 保持它与存储布局无关，也便于测试。
    public var isPaused = false {
        didSet {
            guard isPaused != oldValue else { return }
            // 恢复时必须重新建立基线，避免把暂停期间的编辑补记为输入。
            textTracker.resetBaseline()
            textContext = nil
            previousTree = nil
            lastSnapshotText = nil
            pendingDiff = nil
        }
    }

    /// 已算出但尚未归入事件的差分。
    ///
    /// 输入事件（点击/按键）与 AX 采样是两条独立来源，若不排队，
    /// 同一帧的差分要么被丢掉、要么被重复计算。这里让它**只被消费一次**，
    /// 与官方一致——样本中点击事件 89.7% 携带真实差分。
    private var pendingDiff: EventStreamAXTree?

    /// 文本输入聚合。观察聚焦元素的值变化，按停顿切块。
    private let textTracker = TextInputTracker()
    private struct TextContext {
        var app: EventStreamApp
        var window: EventStreamWindow?
        var focusIdentity: Int?
        var target: EventStreamAXElement?
    }
    private var textContext: TextContext?

    /// 供外部观察状态。
    public private(set) var currentSegmentID: String?
    public private(set) var totalEventsWritten = 0

    public init(configuration: Configuration) {
        self.config = configuration
    }

    public var isRecording: Bool { isRunning }

    // MARK: - 生命周期

    /// 开始采集。写一条 `session.started`，并开启第一个 segment。
    public func start(now: Date = Date()) throws {
        guard !isRunning else { return }
        nextID = 1
        try rotateIfNeeded(now: now, force: true)
        isRunning = true
        textTracker.resetBaseline()
        textContext = nil
        previousTree = nil
        lastSnapshotText = nil
        pendingDiff = nil
        append(kind: .sessionStarted, at: now, app: nil, window: nil,
               mouse: nil, keyboard: nil, selection: nil, ax: nil)
    }

    /// 结束采集。写 `session.ended` 并封口当前 segment。
    public func stop(now: Date = Date()) throws {
        guard isRunning else { return }
        // 收尾前把未满一个停顿周期的输入落盘，避免丢尾部。
        flushTextInput(at: now)
        textTracker.resetBaseline()
        textContext = nil
        append(kind: .sessionEnded, at: now, app: nil, window: nil,
               mouse: nil, keyboard: nil, selection: nil, ax: nil)
        defer {
            writer = nil
            currentSegmentID = nil
            isRunning = false
        }
        try writer?.close(endedAt: now, endReason: .stopped)
    }

    /// 采样一次前台应用与 AX 树，产出 `window.changed`（内容有变化时）。
    ///
    /// 调用频率由外部决定；真实服务在窗口/应用切换时触发。
    public func sampleFrontmost(now: Date = Date(), force: Bool = false) {
        guard isRunning, !isPaused else { return }
        guard let app = FrontmostApplication.current() else { return }

        let window = FrontmostApplication.frontWindow(for: app)
        // 命中抑制时直接返回：既为隐私，也省下每帧整棵树的遍历开销。
        // 后台长跑时这是主要的 CPU 成本。
        if config.policy.shouldSuppress(app: app, window: window) {
            if config.tracksSuppression { writer?.noteSuppressed() }
            return
        }

        var numbered: [UIElementRender] = []
        var treeText = ""
        if let pid = app.processIdentifier {
            let roots = AXTreeReader.read(pid: pid, maxNodes: config.maxNodesPerSnapshot)
            // 身份由 AXTreeReader 直接按 CFHash 写入（跨帧稳定，见该文件说明）；
            // 这里只需补上落盘用的遍历序号。若在此重算身份会覆盖掉精确值。
            numbered = UIElementRenderTree.assignElementIDs(roots)
            treeText = UIElementRenderTree.text(numbered)
        }

        let changed = treeText != lastSnapshotText
        // 未变化则不产出 window.changed，避免静默期刷屏；但差分仍要刷新，
        // 因为输入事件会异步取用它。
        if !force, !changed { return }

        let ax = makeAXTree(current: numbered, currentText: treeText)
        previousTree = numbered
        lastSnapshotText = treeText
        // 持有本帧差分供输入事件取用；window.changed 自己带这一份。
        pendingDiff = ax
        append(kind: .windowChanged, at: now, app: app, window: window,
               mouse: nil, keyboard: nil, selection: nil, ax: ax)
    }

    /// 记录一次鼠标点击。
    public func recordClick(
        button: String,
        clickCount: Int,
        modifiers: [String],
        at now: Date = Date()
    ) {
        guard isRunning, !isPaused else { return }
        let app = FrontmostApplication.current()
        let target = FrontmostApplication.focusedElement()
        append(kind: button == "right" ? .mouseContextMenu : .mouseClick, at: now,
               app: app, window: FrontmostApplication.frontWindow(for: app),
               mouse: EventStreamMouseInteraction(
                   button: button, clickCount: clickCount,
                   modifiers: modifiers, target: target),
               keyboard: nil, selection: nil, ax: consumeDiff())
    }

    /// 记录一次快捷键。
    public func recordShortcut(
        keyEquivalent: String,
        modifiers: [String],
        at now: Date = Date()
    ) {
        guard isRunning, !isPaused else { return }
        let app = FrontmostApplication.current()
        append(kind: .keyboardShortcut, at: now,
               app: app, window: FrontmostApplication.frontWindow(for: app), mouse: nil,
               keyboard: EventStreamKeyboardInteraction(
                   keyEquivalent: keyEquivalent, modifiers: modifiers,
                   target: FrontmostApplication.focusedElement()),
               selection: nil, ax: consumeDiff())
    }

    /// 记录一次文本输入。
    public func recordTextInput(_ text: String, at now: Date = Date()) {
        guard isRunning, !isPaused, !text.isEmpty else { return }
        let app = FrontmostApplication.current()
        append(kind: .keyboardTextInput, at: now,
               app: app, window: FrontmostApplication.frontWindow(for: app), mouse: nil,
               keyboard: EventStreamKeyboardInteraction(
                   text: text, target: FrontmostApplication.focusedElement()),
               selection: nil, ax: nil)
    }

    /// 记录一次提交（回车）。
    public func recordSubmit(at now: Date = Date()) {
        guard isRunning, !isPaused else { return }
        let app = FrontmostApplication.current()
        append(kind: .keyboardSubmit, at: now,
               app: app, window: FrontmostApplication.frontWindow(for: app), mouse: nil,
               keyboard: EventStreamKeyboardInteraction(
                   keyEquivalent: "\r", target: FrontmostApplication.focusedElement()),
               selection: nil, ax: consumeDiff())
    }

    /// 轮询一次聚焦元素的文本，按需产出 `keyboard.text_input`。
    ///
    /// 为什么是读值而非映射键码：`keyboard.text` 是输入法提交的文本
    /// （实测含拼音串），逐键映射拿不到输入法结果，中文更无从还原。
    public func sampleTextInput(now: Date = Date()) {
        guard isRunning, !isPaused else { return }
        let app = FrontmostApplication.current()

        sampleTextInput(app: app, window: FrontmostApplication.frontWindow(for: app),
                        readFocused: { FrontmostApplication.focusedTextSnapshot(for: app) }, now: now)
    }

    func sampleTextInput(app: EventStreamApp?, window: EventStreamWindow?,
                         readFocused: () -> (TextInputTracker.Observation, EventStreamAXElement?),
                         now: Date) {
        guard isRunning, !isPaused else { return }
        guard let app else {
            flushTextInput(at: now)
            textTracker.resetBaseline()
            textContext = nil
            return
        }
        if textContext?.app.bundleIdentifier != app.bundleIdentifier
            || textContext?.app.processIdentifier != app.processIdentifier
            || textContext?.window?.windowID != window?.windowID
            || textContext?.window?.url != window?.url {
            flushTextInput(at: now)
            textTracker.resetBaseline()
            textContext = nil
        }
        // 必须在读取控件值之前判断，屏蔽内容不能进入输入缓冲。
        if config.policy.shouldSuppress(app: app, window: window) {
            if config.tracksSuppression { writer?.noteSuppressed() }
            textTracker.resetBaseline()
            textContext = nil
            return
        }
        let (obs, target) = readFocused()
        if textContext?.focusIdentity != obs.focusIdentity {
            flushTextInput(at: now)
            textTracker.resetBaseline()
            textContext = nil
        }
        let context = TextContext(app: app, window: window,
                                  focusIdentity: obs.focusIdentity, target: target)
        textContext?.app = app
        textContext?.window = window
        if let text = textTracker.observe(obs, at: now) {
            writeTextInput(text, context: textContext ?? context, at: now)
        }
        textContext = context
    }

    private func flushTextInput(at now: Date) {
        if let tail = textTracker.flush(), let context = textContext {
            writeTextInput(tail, context: context, at: now)
        }
    }

    private func writeTextInput(_ text: String, context: TextContext, at now: Date) {
        guard !text.isEmpty else { return }
        append(kind: .keyboardTextInput, at: now,
               app: context.app, window: context.window, mouse: nil,
               keyboard: EventStreamKeyboardInteraction(text: text, target: context.target),
               selection: nil, ax: nil)
    }

    /// 记录一次文本选中变化。
    public func recordSelection(_ selection: EventStreamSelection, at now: Date = Date()) {
        guard isRunning, !isPaused else { return }
        let app = FrontmostApplication.current()
        append(kind: .selectionChanged, at: now,
               app: app, window: FrontmostApplication.frontWindow(for: app), mouse: nil, keyboard: nil,
               selection: selection, ax: nil)
    }

    // MARK: - 内部

    /// 生成差分 ax：有上一帧则为 `diffFromPrevious`，否则整树。
    /// 超预算时 `lines(...)` 返回 nil，回退为整树——与实测行为一致。
    private func makeAXTree(current: [UIElementRender],
                            currentText: String) -> EventStreamAXTree? {
        guard !current.isEmpty else { return nil }
        guard let previous = previousTree, !previous.isEmpty else {
            return EventStreamAXTree(mode: .fullTree, text: currentText)
        }
        if let diff = UIElementRenderDifference.lines(from: previous, to: current) {
            return EventStreamAXTree(mode: .diffFromPrevious,
                                     text: diff.joined(separator: "\n"))
        }
        // 预算超限：回退整树
        return EventStreamAXTree(mode: .fullTree, text: currentText)
    }

    /// 取出并清空待处理差分。同一帧只被一个事件消费，避免重复携带。
    private func consumeDiff() -> EventStreamAXTree? {
        defer { pendingDiff = nil }
        return pendingDiff
    }

    private func append(
        kind: EventStreamEventKind,
        at date: Date,
        app: EventStreamApp?,
        window: EventStreamWindow?,
        mouse: EventStreamMouseInteraction?,
        keyboard: EventStreamKeyboardInteraction?,
        selection: EventStreamSelection?,
        ax: EventStreamAXTree?
    ) {
        // 暂停期间一律不写入。输入事件由事件监听回调触发，不经过采样入口，
        // 因此这里也要挡一次。
        guard !isPaused else { return }

        // 抑制判定：命中则只计数，不落主文件。
        if config.policy.shouldSuppress(app: app, window: window) {
            if config.tracksSuppression { writer?.noteSuppressed() }
            return
        }
        do {
            try rotateIfNeeded(now: date, force: false)
            guard let writer else { return }
            let record = EventStreamRecord(
                id: nextID, timestamp: date, kind: kind,
                app: app, window: window, mouse: mouse,
                keyboard: keyboard, selection: selection, ax: ax)
            try writer.append(record)
            nextID += 1
            totalEventsWritten += 1
        } catch {
            FileHandle.standardError.write(
                "写入事件失败：\(error)\n".data(using: .utf8)!)
        }
    }

    /// 按需切段。跨过 10 分钟边界时封口旧段、开新段。
    private func rotateIfNeeded(now: Date, force: Bool) throws {
        if !force, let writer,
           !SegmentClock.isExpired(writer.startedAt, now: now) {
            return
        }
        if let writer {
            try writer.close(endedAt: now, endReason: nil)
        }
        let w = try SegmentWriter(rootDirectoryURL: config.rootDirectory, start: now)
        writer = w
        currentSegmentID = w.segmentID

        // 借轮转时机清理旧段：后台长跑时轮转每 10 分钟一次，足够及时，
        // 又不必额外起定时器。清理失败不影响采集。
        let report = SegmentPruner.prune(rootDirectory: config.rootDirectory,
                                        retention: config.retention, now: now,
                                        activeSegmentID: w.segmentID)
        lastPruneReport = report.removedSegments > 0 || !report.failures.isEmpty ? report : nil
        for failure in report.failures {
            FileHandle.standardError.write(
                "清理失败（\(failure.operation.rawValue)）：\(failure.directory.path)：\(failure.message)\n".data(using: .utf8)!)
        }
    }
}
