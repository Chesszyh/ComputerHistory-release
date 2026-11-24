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
        var marked = false
        var reference: String? = nil
        var replaces: Set<String> = []
        var emittedFragment: Int? = nil
        var originalRange: Range<Int>? = nil
    }
    // Unedited text shares the baseline string. Only edited characters need provenance.
    private enum Span {
        case original(Range<Int>)
        case edited(Cell)

        var count: Int {
            if case let .original(range) = self { return range.count }
            return 1
        }
        var originalRange: Range<Int>? {
            switch self {
            case .original(let range): return range
            case .edited(let cell): return cell.originalRange
            }
        }
        var cell: Cell? {
            if case let .edited(cell) = self { return cell }
            return nil
        }
    }
    private var spans: [Span] = []
    private var baselineSpans: [Span] = []

    private static func split(_ spans: inout [Span], at offset: Int) -> Int {
        var position = 0
        for i in spans.indices {
            if position == offset { return i }
            let end = position + spans[i].count
            if offset < end, case .original(let range) = spans[i] {
                let middle = range.lowerBound + offset - position
                spans.replaceSubrange(i...i, with: [.original(range.lowerBound..<middle), .original(middle..<range.upperBound)])
                return i + 1
            }
            position = end
        }
        return spans.endIndex
    }

    private func baselineSlice(_ range: Range<Int>) -> [Span] {
        // Baseline spans are rebased into ascending, disjoint ranges on every flush.
        var low = 0, high = baselineSpans.count
        while low < high {
            let mid = low + (high - low) / 2
            if baselineSpans[mid].originalRange!.upperBound <= range.lowerBound { low = mid + 1 }
            else { high = mid }
        }
        var result: [Span] = []
        for span in baselineSpans[low...] {
            let source = span.originalRange!
            guard source.lowerBound < range.upperBound else { break }
            if case .original = span { result.append(.original(source.clamped(to: range))) }
            else { result.append(span) }
        }
        return result
    }

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
        if let marked = obs.hasMarkedText {
            composing = marked
            if !marked {
                for i in spans.indices {
                    guard var cell = spans[i].cell, cell.marked else { continue }
                    cell.marked = false
                    if obs.hasInputActivity == true { cell.evidence = .editedValue }
                    spans[i] = .edited(cell)
                }
            }
        }
        guard previous != value else { return flushIfIdle(now: now) }
        var left = previous.startIndex, right = value.startIndex, prefix = 0
        while left < previous.endIndex, right < value.endIndex, previous[left] == value[right] {
            previous.formIndex(after: &left)
            value.formIndex(after: &right)
            prefix += 1
        }
        var oldEnd = previous.endIndex, newEnd = value.endIndex
        while oldEnd > left, newEnd > right {
            let oldLast = previous.index(before: oldEnd), newLast = value.index(before: newEnd)
            guard previous[oldLast] == value[newLast] else { break }
            oldEnd = oldLast
            newEnd = newLast
        }
        let removedCount = previous.distance(from: left, to: oldEnd)
        let first = Self.split(&spans, at: prefix)
        let end = Self.split(&spans, at: prefix + removedCount)
        let removed = spans[first..<end]
        let nearby = removed.lazy.compactMap { $0.cell?.edit }.first
            ?? spans[..<first].last?.cell?.edit ?? spans[end...].first?.cell?.edit
        nextEdit += 1
        let edit = nearby ?? nextEdit
        let evidence: TextEvidence = obs.hasInputActivity == true && !composing
            ? .editedValue : .uncertainValueChange
        var replaced: Set<String> = []
        for case let .edited(cell) in removed {
            if let reference = cell.reference { replaced.insert(reference) }
            replaced.formUnion(cell.replaces)
        }
        let ranges = removed.compactMap(\.originalRange)
        var originalRange: Range<Int>?
        if let lower = ranges.map(\.lowerBound).min(), let upper = ranges.map(\.upperBound).max() {
            originalRange = lower..<upper
        } else if removed.isEmpty {
            let lower = spans[..<first].reversed().lazy.compactMap(\.originalRange).first?.upperBound ?? 0
            let upper = spans[end...].lazy.compactMap(\.originalRange).first?.lowerBound ?? baselineValue?.count ?? 0
            if lower < upper { originalRange = lower..<upper }
        }
        let inserted = value[right..<newEnd]
        let baseline = baselineValue ?? ""
        var baselineOffset = 0, baselineIndex = baseline.startIndex
        func originalText(_ range: Range<Int>) -> Substring {
            baseline.formIndex(&baselineIndex, offsetBy: range.lowerBound - baselineOffset)
            baselineOffset = range.lowerBound
            return baseline[baselineIndex..<baseline.index(baselineIndex, offsetBy: range.count)]
        }
        var replacement: [Span] = []
        if let range = originalRange, range.count == inserted.count,
           !spans[..<first].contains(where: { $0.originalRange == range }),
           !spans[end...].contains(where: { $0.originalRange == range }),
           originalText(range) == inserted {
            replacement = baselineSlice(range)
        } else {
            // A same-length replacement can restore individual previously emitted characters.
            let aligned = removedCount == inserted.count
            var cursor = inserted.startIndex
            func append(_ character: Character, range: Range<Int>?) {
                if let range, range.count == 1, originalText(range).first == character {
                    let restored = baselineSlice(range)
                    if case .original = restored.first, case .original(let last) = replacement.last,
                       last.upperBound == range.lowerBound {
                        replacement[replacement.count - 1] = .original(last.lowerBound..<range.upperBound)
                    } else {
                        replacement += restored
                    }
                } else {
                    replacement.append(.edited(Cell(character: character, edit: edit, evidence: evidence,
                        marked: composing, replaces: replaced, originalRange: range)))
                }
            }
            if aligned {
                for span in removed {
                    switch span {
                    case .original(let range):
                        for offset in range {
                            append(inserted[cursor], range: offset..<(offset + 1))
                            inserted.formIndex(after: &cursor)
                        }
                    case .edited(let cell):
                        append(inserted[cursor], range: cell.originalRange)
                        inserted.formIndex(after: &cursor)
                    }
                }
            } else {
                for character in inserted { append(character, range: originalRange) }
            }
        }
        spans.replaceSubrange(first..<end, with: replacement)
        lastValue = value
        if value == baselineValue { spans = baselineSpans }
        lastChangeAt = now
        return []
    }

    private func establish(_ obs: Observation, now: Date) {
        lastFocusIdentity = obs.focusIdentity
        lastValue = obs.isEditableBuffer && !obs.isPlaceholder ? obs.value : nil
        baselineValue = lastValue
        let count = lastValue?.count ?? 0
        spans = count == 0 ? [] : [.original(0..<count)]
        baselineSpans = spans
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
            }
            for index in indices {
                guard var cell = spans[index].cell else { continue }
                if !clean.isEmpty { cell.emittedFragment = nextEmission }
                cell.edit = nil
                spans[index] = .edited(cell)
            }
            indices = []
            text = ""
            replaces = []
            evidence = .editedValue
        }
        for index in spans.indices {
            guard let cell = spans[index].cell else { emit(); currentID = nil; continue }
            // A segment boundary may flush committed text, but cannot commit the marked tail.
            if cell.marked { emit(); currentID = nil; continue }
            if cell.edit != currentID { emit(); currentID = cell.edit }
            guard cell.edit != nil else { continue }
            indices.append(index)
            text.append(cell.character)
            replaces.formUnion(cell.replaces)
            if cell.evidence == .uncertainValueChange { evidence = .uncertainValueChange }
        }
        emit()
        let fragments = runs.enumerated().sorted {
            $0.element.id == $1.element.id ? $0.offset < $1.offset : $0.element.id < $1.element.id
        }.map { $0.element.fragment }
        var rebased: [Span] = []
        var offset = 0
        for span in spans {
            let end = offset + span.count
            if var cell = span.cell, cell.edit != nil || cell.emittedFragment != nil || cell.reference != nil {
                cell.originalRange = offset..<end
                rebased.append(.edited(cell))
            } else if case .original(let previous) = rebased.last {
                rebased[rebased.count - 1] = .original(previous.lowerBound..<end)
            } else {
                rebased.append(.original(offset..<end))
            }
            offset = end
        }
        spans = rebased
        baselineSpans = spans
        baselineValue = lastValue
        lastChangeAt = nil
        return fragments
    }

    /// 事件写出后登记来源，后续覆盖可在派生摘要中降低旧片段的归因强度。
    func acknowledge(_ fragment: Fragment, reference: String) {
        for index in spans.indices {
            guard var cell = spans[index].cell, cell.emittedFragment == fragment.emissionID else { continue }
            cell.reference = reference
            cell.replaces = []
            cell.emittedFragment = nil
            spans[index] = .edited(cell)
        }
        baselineSpans = spans
    }

    /// 暂停与上下文边界丢弃待输出编辑；恢复时只建立新基线。
    public func resetBaseline() {
        lastValue = nil
        baselineValue = nil
        lastChangeAt = nil
        lastFocusIdentity = nil
        spans = []
        baselineSpans = []
        composing = false
    }

}
