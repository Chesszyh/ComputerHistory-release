import Foundation

/// 文本输入聚合。
///
/// ## 为什么不能用键码映射
///
/// 实测样本里 `keyboard.text` 含**拼音串**（如 `ganjue zhecankgu qishi meism xinyi`），
/// 长度中位 6、最长 88。逐键映射需要自己处理键盘布局、输入法候选与提交，
/// 中文场景基本不可行。
///
/// ## 为什么不能直接读控件全值
///
/// 聚焦元素的 `kAXValueAttribute` 返回**整个字段内容**（实测 TextEdit 里打完
/// 三次输入后读到的是一次累积的长串）。把它记为 `text_input` 会与官方语义不符——
/// 官方每条只记本次输入的片段。
///
/// 另一条路 `kAXSelectedTextAttribute` 在无选中时返回空串，同样拿不到插入文本。
///
/// ## 采用的做法：完整字符的公共前后缀差分
///
/// 首次观察建立基线，后续变化段按输入停顿聚合。值差分无法区分
/// 用户输入与程序化改写；不可编辑的屏幕缓冲不产出输入事件。
public final class TextInputTracker {

    /// 静默多久算一次输入结束。样本中位间隔 3 秒，取略小的 2.5 秒，
    /// 使连续输入自然合并、停顿即切块。
    public static let defaultIdleThreshold: TimeInterval = 2.5

    private let idleThreshold: TimeInterval
    private var lastValue: String?
    private var lastCaret: Int?
    /// 已累积但尚未 flush 的输入片段。
    private var pending = ""
    private var lastChangeAt: Date?

    /// 上一次观察的焦点元素身份。用于识别同一应用内的控件切换。
    private var lastFocusIdentity: Int?

    public init(idleThreshold: TimeInterval = defaultIdleThreshold) {
        self.idleThreshold = idleThreshold
    }

    /// 一次观察：聚焦元素的文本与光标位置。
    public struct Observation: Equatable, Sendable {
        public var value: String?
        /// 光标位置（UTF-16 偏移，与 AX 的 CFRange 一致）。nil 表示应用未暴露。
        ///
        /// 仅作诊断参考：实测其 `location` 不可靠（输入法上屏时可能报 0），
        /// 差异判定不使用该值。
        public var caret: Int?
        /// 该值是否可当作编辑缓冲。
        ///
        /// 为 false 时（终端屏幕等）**不产出** `text_input`：值差分无法证明
        /// 新增内容来自键盘，命令输出会被误记为输入。宁可不记也不记错。
        public var isEditableBuffer: Bool

        /// 焦点元素的稳定身份，用于识别**同一应用内**的控件切换。
        ///
        /// 不能用对象指针：实测跨次查询一致率为 0/1417。用 `CFHash` 加出现序号，
        /// 与树遍历所用的身份同一机制（实测跨帧一致率 1417/1417）。
        public var focusIdentity: Int?

        public init(value: String?, caret: Int? = nil,
                    isEditableBuffer: Bool = true, focusIdentity: Int? = nil) {
            self.value = value
            self.caret = caret
            self.isEditableBuffer = isEditableBuffer
            self.focusIdentity = focusIdentity
        }
    }

    /// 喂入一次观察。返回应当作为一条 `keyboard.text_input` 落盘的文本（无则 nil）。
    public func observe(_ obs: Observation, at now: Date) -> String? {
        // 焦点切到**另一个控件**时重建基线。只看前台应用不够：同一应用内从
        // 已有 "hello" 的输入框切到已有 "world" 的输入框，值差分会把 "world"
        // 记成用户输入。
        if let id = obs.focusIdentity, id != lastFocusIdentity {
            let out = flush(reason: .focusChanged)
            lastValue = nil
            lastCaret = nil
            lastFocusIdentity = id
            if let value = obs.value { lastValue = value }
            lastChangeAt = now
            return out
        }

        guard let value = obs.value else {
            // 目标不可读（Electron 应用、失焦、隐私输入）：视为中断。
            lastValue = nil
            lastCaret = nil
            return flush(reason: .targetLost)
        }

        // 值不像编辑缓冲（终端屏幕网格）：不产出 text_input。
        // 值差分无法证明新增内容来自键盘，命令输出会被误记为输入。
        guard obs.isEditableBuffer else {
            lastValue = value
            lastCaret = obs.caret
            return flush(reason: .unattributable)
        }

        guard let prevValue = lastValue else {
            // 首次观察（或刚从无效状态恢复）只建立基线：
            // 字段里可能已有内容，记成输入会凭空造数据。
            lastValue = value
            lastCaret = obs.caret
            lastChangeAt = now
            return nil
        }
        guard value != prevValue else { return flushIfIdle(now: now) }

        // 用公共前后缀求变化段。**不依赖光标位置**——实测其 `location` 不可靠：
        // 输入法上屏时可能报告 0（`value=…hello, caret=0`），据此判定会漏记。
        let change = Self.change(from: prevValue, to: value)

        defer {
            lastValue = value
            lastCaret = obs.caret
        }

        switch change {
        case .inserted(let text) where !text.isEmpty:
            pending += Self.sanitize(text)
            lastChangeAt = now
            return flushIfIdle(now: now)

        case .deleted:
            // 删除不是输入；更新基线即可。
            lastChangeAt = now
            return flushIfIdle(now: now)

        case .replaced(let newText):
            // 变化段两侧不匹配（输入法上屏把拼音换成汉字、或程序化改写）。
            // 两者在值层面同形，无法区分，故采取：吐出已积累的旧内容，
            // 并把新值作为新的累积起点——新值本身是当前控件内容，
            // 与"本次键入"高度相关；若有后续键入会继续追加，停顿后一并落盘。
            let out = flush(reason: .replaced)
            pending = Self.sanitize(newText)
            lastChangeAt = now
            return out

        case .inserted:
            return flushIfIdle(now: now)
        }
    }

    /// 去掉终端网格的 NUL 填充，保留 Unicode 格式字符（如 emoji 连接符）。
    ///
    /// 终端把屏幕表示为定宽网格，命令区用 NUL 补齐（实测 iTerm：
    /// `"~ ❯ whoami\0\0\0…01:19:01\nexample-user\n\n"`）。NUL 是渲染伪影，
    /// 不是用户输入。
    ///
    /// **只删控制字符，不动其它任何字符**——空格与换行可能是用户真的输入的，
    /// 实测官方数据里就有以空格结尾的片段（`"算了, "`），折叠或裁剪会改变内容。
    static func sanitize(_ s: String) -> String {
        String(s.unicodeScalars.filter { scalar in
            if scalar == "\n" || scalar == "\t" { return true }
            return scalar.properties.generalCategory != .control
        })
    }

    /// 两段文本的差异。
    enum Change: Equatable {
        /// 新值 = 旧值前缀 + 插入段 + 旧值后缀。插入段非空。
        case inserted(String)
        /// 新值是旧值的真子集（纯删除）。
        case deleted
        /// 中间被替换：插入段与删除段都存在，且不是纯插入。
        case replaced(String)
    }

    /// 按**公共前后缀**求变化。这是文本差异的通用做法，不依赖光标，
    /// 因而对输入法上屏、程序化改写、光标不可用等情形都成立。
    ///
    /// 判据：设旧值 `p`、新值 `n`，取公共前缀长度 `pre`、公共后缀长度 `suf`
    /// （后缀不越过前缀）。若 `pre + suf >= p.count`，则新值只是旧值的扩展，
    /// 插入段为 `n[pre ..< n.count - suf]`；若 `pre + suf >= n.count`，则是纯删除；
    /// 否则为替换。
    static func change(from prev: String, to next: String) -> Change {
        let p = Array(prev), n = Array(next)

        var pre = 0
        while pre < p.count, pre < n.count, p[pre] == n[pre] { pre += 1 }

        var suf = 0
        while suf < (p.count - pre), suf < (n.count - pre),
              p[p.count - 1 - suf] == n[n.count - 1 - suf] { suf += 1 }

        let insertedCount = n.count - pre - suf
        let deletedCount = p.count - pre - suf

        if insertedCount > 0, deletedCount == 0 {
            return .inserted(String(n[pre..<(n.count - suf)]))
        }
        if insertedCount == 0, deletedCount > 0 {
            return .deleted
        }
        if insertedCount == 0, deletedCount == 0 {
            return .deleted   // 值相等的情形已在调用方排除
        }
        return .replaced(String(n[pre..<(n.count - suf)]))
    }

    private func flushIfIdle(now: Date) -> String? {
        guard let last = lastChangeAt, !pending.isEmpty else { return nil }
        guard now.timeIntervalSince(last) >= idleThreshold else { return nil }
        return flush(reason: .idle)
    }

    /// 立即吐出已积累文本。
    @discardableResult
    public func flush(reason: FlushReason = .explicit) -> String? {
        defer { pending = ""; lastChangeAt = nil }
        return pending.isEmpty ? nil : pending
    }

    /// 丢弃基线。切换前台应用或聚焦控件时调用，避免把新控件的内容当增量。
    public func resetBaseline() {
        lastValue = nil
        lastCaret = nil
        lastChangeAt = nil
        lastFocusIdentity = nil
    }

    public enum FlushReason: Sendable {
        case idle            // 输入停顿
        case targetLost      // 聚焦目标不可读
        case focusChanged    // 焦点切到同一应用内的另一个控件
        case unattributable  // 值不是编辑缓冲，无法归因到键盘
        case replaced        // 输入法上屏：替换为新内容
        case indeterminate   // 无法判定插入内容
        case explicit        // 调用方要求
    }
}
