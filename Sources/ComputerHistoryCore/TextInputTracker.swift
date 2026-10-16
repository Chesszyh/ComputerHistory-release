import Foundation

/// 跟踪完整字符的新增编辑区域；删除和替换会更新尚未输出的内容。
/// 值变化不能单独证明用户输入，输出保留输入活动的归因证据。
public final class TextInputTracker {

    /// 静默多久算一次输入结束。样本中位间隔 3 秒，取略小的 2.5 秒，
    /// 使连续输入自然合并、停顿即切块。
    public static let defaultIdleThreshold: TimeInterval = 2.5

    private let idleThreshold: TimeInterval
    private var baselineValue: String?
    private var lastValue: String?
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
        public var role: String?
        public var subrole: String?
        public var valueSettable: Bool?
        public var placeholder: String?
        public var selectionLength: Int?
        /// nil 表示应用没有公开组合状态，不能当作已完成输入法上屏。
        public var hasMarkedText: Bool?
        public var hasInputActivity: Bool?
        public var isPlaceholder: Bool

        public init(value: String?, caret: Int? = nil,
                    isEditableBuffer: Bool = true, focusIdentity: Int? = nil,
                    role: String? = nil, subrole: String? = nil,
                    valueSettable: Bool? = nil, placeholder: String? = nil,
                    selectionLength: Int? = nil, hasMarkedText: Bool? = nil,
                    hasInputActivity: Bool? = nil, isPlaceholder: Bool = false) {
            self.value = value
            self.caret = caret
            self.isEditableBuffer = isEditableBuffer
            self.focusIdentity = focusIdentity
            self.role = role
            self.subrole = subrole
            self.valueSettable = valueSettable
            self.placeholder = placeholder
            self.selectionLength = selectionLength
            self.hasMarkedText = hasMarkedText
            self.hasInputActivity = hasInputActivity
            self.isPlaceholder = isPlaceholder
        }
    }

    public struct Fragment: Equatable, Sendable {
        public var text: String
        public var evidence: TextEvidence
        public var replaces: [String] = []
        var emissionID: Int = 0
    }
    private struct Cell {
        var character: Character
        var edit: Int?
        var evidence: TextEvidence
        var reference: String? = nil
        var replaces: Set<String> = []
        var emittedFragment: Int? = nil
        var originalRange: Range<Int>? = nil
    }
    private var cells: [Cell] = []
    private var baselineCells: [Cell] = []
    private var nextEdit = 0
    private var nextEmission = 0
    private var composing = false

    /// 输出独立编辑片段；不同位置的编辑保持各自的文本和顺序。
    public func observe(_ obs: Observation, at now: Date) -> [Fragment] {
        if obs.focusIdentity != lastFocusIdentity {
            let out = flush()
            establish(obs, now: now)
            return out
        }
        guard let value = obs.value, obs.isEditableBuffer, !obs.isPlaceholder else {
            let out = flush()
            establish(obs, now: now)
            return out
        }
        guard let previous = lastValue else {
            establish(obs, now: now)
            return []
        }
        composing = obs.hasMarkedText == true
        guard previous != value else { return flushIfIdle(now: now) }
        let old = Array(previous), new = Array(value)
        var prefix = 0, suffix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - suffix - 1] == new[new.count - suffix - 1] { suffix += 1 }
        let removed = prefix..<(old.count - suffix)
        let inserted = new[prefix..<(new.count - suffix)]
        // 沿用相邻待输出区域的身份；既有正文仍保留 nil，不会夹入输入片段。
        let nearby = cells[removed].compactMap(\.edit).first
            ?? (prefix > 0 ? cells[prefix - 1].edit : nil)
            ?? (removed.upperBound < cells.count ? cells[removed.upperBound].edit : nil)
        nextEdit += 1
        let edit = nearby ?? nextEdit
        let evidence: TextEvidence = obs.hasInputActivity == true && !composing
            ? .editedValue : .uncertainValueChange
        let replaced = Set(cells[removed].compactMap(\.reference))
            .union(cells[removed].flatMap(\.replaces))
        let oldCells = Array(cells[removed])
        let ranges = oldCells.compactMap(\.originalRange)
        var originalRange = ranges.isEmpty ? nil : ranges.map(\.lowerBound).min()!..<ranges.map(\.upperBound).max()!
        if oldCells.isEmpty {
            let lower = cells[..<prefix].compactMap(\.originalRange).last?.upperBound ?? 0
            let upper = cells[removed.upperBound...].compactMap(\.originalRange).first?.lowerBound ?? baselineCells.count
            if lower < upper { originalRange = lower..<upper }
        }
        var replacement = inserted.enumerated().map { index, character -> Cell in
            let range = oldCells.count == inserted.count ? oldCells[index].originalRange : originalRange
            if let range, range.count == 1, baselineCells[range.lowerBound].character == character {
                return baselineCells[range.lowerBound]
            }
            return Cell(character: character, edit: edit, evidence: evidence,
                        replaces: replaced, originalRange: range)
        }
        // 同一替换区域整体撤销时恢复原有身份，不能把原正文重新记为输入。
        if let range = originalRange,
           !cells[..<removed.lowerBound].contains(where: { $0.originalRange == range }),
           !cells[removed.upperBound...].contains(where: { $0.originalRange == range }),
           String(baselineCells[range].map(\.character)) == String(inserted) {
            replacement = Array(baselineCells[range])
        }
        cells.replaceSubrange(removed, with: replacement)
        lastValue = value
        if value == baselineValue {
            cells = baselineCells
        }
        lastChangeAt = now
        return []
    }

    private func establish(_ obs: Observation, now: Date) {
        lastFocusIdentity = obs.focusIdentity
        lastValue = obs.isEditableBuffer && !obs.isPlaceholder ? obs.value : nil
        baselineValue = lastValue
        cells = (lastValue ?? "").enumerated().map {
            Cell(character: $0.element, edit: nil, evidence: .uncertainValueChange, originalRange: $0.offset..<($0.offset + 1))
        }
        baselineCells = cells
        composing = obs.hasMarkedText == true
        lastChangeAt = now
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

    private func flushIfIdle(now: Date) -> [Fragment] {
        guard !composing, let last = lastChangeAt,
              now.timeIntervalSince(last) >= idleThreshold else { return [] }
        return flush()
    }

    @discardableResult
    public func flush() -> [Fragment] {
        var currentID: Int?
        var runs: [(id: Int, fragment: Fragment)] = []
        var text = ""
        var evidence = TextEvidence.editedValue
        var replaces: Set<String> = []
        var indices: [Int] = []
        func emit() {
            let clean = Self.sanitize(text)
            if !clean.isEmpty, let currentID {
                nextEmission += 1
                runs.append((currentID, .init(text: clean, evidence: evidence, replaces: replaces.sorted(), emissionID: nextEmission)))
                for index in indices { cells[index].emittedFragment = nextEmission }
            }
            for index in indices { cells[index].edit = nil }
            indices = []
            text = ""
            replaces = []
            evidence = .editedValue
        }
        for index in cells.indices {
            let cell = cells[index]
            if cell.edit != currentID { emit(); currentID = cell.edit }
            guard cell.edit != nil else { continue }
            indices.append(index)
            text.append(cell.character)
            replaces.formUnion(cell.replaces)
            if cell.evidence == .uncertainValueChange || composing { evidence = .uncertainValueChange }
        }
        emit()
        let fragments = runs.enumerated().sorted {
            $0.element.id == $1.element.id ? $0.offset < $1.offset : $0.element.id < $1.element.id
        }.map { $0.element.fragment }
        for index in cells.indices { cells[index].originalRange = index..<(index + 1) }
        baselineCells = cells
        baselineValue = lastValue
        lastChangeAt = nil
        return fragments
    }

    /// 事件写出后登记来源，后续覆盖可在派生摘要中降低旧片段的归因强度。
    func acknowledge(_ fragment: Fragment, reference: String) {
        for index in cells.indices where cells[index].emittedFragment == fragment.emissionID {
            cells[index].reference = reference
            cells[index].replaces = []
            cells[index].emittedFragment = nil
        }
        baselineCells = cells
    }

    /// 暂停与上下文边界丢弃待输出编辑；恢复时只建立新基线。
    public func resetBaseline() {
        lastValue = nil
        baselineValue = nil
        lastChangeAt = nil
        lastFocusIdentity = nil
        cells = []
        baselineCells = []
        composing = false
    }

}
