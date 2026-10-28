import Foundation

/// 两棵 `UIElementRender` 树的差分，产出官方 `diffFromPrevious` 形态的行。
///
/// 行文法（由 88 段真实产物反推，见 re/event-schema.md §6）：
///
///     Removed element IDs: 22, 27-113
///     ~0 窗口 标题
///     +\t\t\t7 按钮 (disabled) 返回
///     -\t\t8 图像
///
/// 语义要点：
///   - `~` 未变行——**提供上下文**，官方会输出路径上的未变节点；
///   - `+` 新增子树（含其后代），逐层展开；
///   - `-` 移除子树，**默认折叠**：真实样本 20 万行里 `-` 行仅 165 行，
///     而 `Removed element IDs:` 摘要头有 2 371 行。故移除以摘要头表达为主。
///   - 缩进用 TAB，深度即 TAB 个数。
///
/// 预算机制：超限时 `lines(...)` 返回 nil，调用方回退到输出**整棵树**——
/// 这是 `fullTree` 模式在段中间出现的成因，已在样本中实测到 82 个例证。
public enum UIElementRenderDifference {

    /// 默认行预算。官方数值未从二进制中定位（非字面量），
    /// 这里取一个**高于实测最大差分行数 847** 的值，使行为与观测不冲突。
    /// 调用方可用 `lineBudget` 覆盖。
    public static let defaultLineBudget = 2000

    /// 计算差分行。超预算返回 nil。
    ///
    /// - Parameters:
    ///   - summarizesRemovedElementIDs: 是否把移除折叠成摘要头。二进制调用点该实参
    ///     恒为 `true`（`mov w2, #0x1`），故默认开启。
    public static func lines(
        from previous: [UIElementRender],
        to current: [UIElementRender],
        indent: Character = "\t",
        options: UIElementRenderLineOptions = [],
        summarizesRemovedElementIDs: Bool = true,
        ignoreLineBudget: Bool = false,
        lineBudget: Int = defaultLineBudget,
        includesUnchangedContext: Bool = true
    ) -> [String]? {
        // 跨帧身份由调用方提供；这里只补充落盘的遍历序号。
        let previousNumbered = UIElementRenderTree.assignElementIDs(previous)
        let currentNumbered = UIElementRenderTree.assignElementIDs(current)

        var context: [String] = []
        var additions: [String] = []
        var removedIDs: [Int] = []

        // 从根开始按序比对；未变的根连同其"未变骨架"进入上下文。
        diffChildren(previous: previousNumbered, current: currentNumbered,
                     depth: 0, indent: indent, options: options,
                     context: &context, additions: &additions, removedIDs: &removedIDs)

        var lines: [String] = []
        if summarizesRemovedElementIDs, !removedIDs.isEmpty {
            lines.append("Removed element IDs: " + formatRanges(removedIDs))
        }
        if includesUnchangedContext { lines.append(contentsOf: context) }
        lines.append(contentsOf: additions)

        if !ignoreLineBudget, lines.count > lineBudget { return nil }
        return lines
    }

    /// 逐层配对子序列：按语义身份 `id` 求最长公共子序列，未变者进上下文，
    /// 其余分别记为增/删。`id` 由采集端或文本解析端提供，非遍历序号。
    private static func diffChildren(
        previous: [UIElementRender],
        current: [UIElementRender],
        depth: Int,
        indent: Character,
        options: UIElementRenderLineOptions,
        context: inout [String],
        additions: inout [String],
        removedIDs: inout [Int]
    ) {
        let previousIDs = previous.map(\.id)
        let currentIDs = current.map(\.id)
        // AX identities are stable across snapshots. Unchanged sibling order is the
        // overwhelmingly common case, so avoid allocating an O(n*m) DP matrix just
        // to rediscover the identity pairs. Content changes are still handled below.
        let common: [(Int, Int)]
        if previousIDs.count == currentIDs.count,
           zip(previousIDs, currentIDs).allSatisfy({ $0.0 == $0.1 }) {
            common = previousIDs.indices.map { ($0, $0) }
        } else {
            common = longestCommonSubsequence(previousIDs, currentIDs)
        }
        var oi = 0, ni = 0

        // `common` 是 **索引对**（LCS 返回下标），不是 id 值——早期版本把两者混用，
        // 导致每次比较都判为"全部移除 + 全部新增"。
        for (pi, ci) in common {
            // 配对之前（下标小于 pi/ci）的元素分别为移除与新增
            while oi < pi {
                collectRemoved(previous[oi], ids: &removedIDs)
                oi += 1
            }
            while ni < ci {
                collectAdded(current[ni], depth: depth, indent: indent,
                             options: options, into: &additions)
                ni += 1
            }
            guard pi < previous.count, ci < current.count else { break }

            let oldNode = previous[pi], newNode = current[ci]
            let eid = newNode.elementID ?? 0
            if contentEqual(oldNode, newNode) {
                // 未变：作为上下文输出，并继续比对子节点。
                // 注意要补 `~` 前缀——渲染器的 line(...) 产出的是 fullTree 形态（无前缀）。
                var ctxLine = "~" + String(repeating: indent, count: depth)
                if !options.contains(.withoutElementID) { ctxLine += "\(eid) " }
                ctxLine += newNode.text
                if !options.contains(.withoutDetailText),
                   let d = newNode.detailText, !d.isEmpty {
                    ctxLine += " " + d
                }
                context.append(ctxLine)
                diffChildren(previous: oldNode.children, current: newNode.children,
                             depth: depth + 1, indent: indent, options: options,
                             context: &context, additions: &additions,
                             removedIDs: &removedIDs)
            } else {
                // 同一节点内容变了：按"移除旧的 + 新增新的"表达
                collectRemoved(oldNode, ids: &removedIDs)
                collectAdded(newNode, depth: depth, indent: indent,
                             options: options, into: &additions)
            }
            oi = pi + 1; ni = ci + 1
        }
        while oi < previous.count { collectRemoved(previous[oi], ids: &removedIDs); oi += 1 }
        while ni < current.count {
            collectAdded(current[ni], depth: depth, indent: indent,
                         options: options, into: &additions)
            ni += 1
        }
    }

    private static func contentEqual(_ a: UIElementRender, _ b: UIElementRender) -> Bool {
        a.text == b.text && (a.detailText ?? "") == (b.detailText ?? "")
    }

    /// 新增子树：逐层展开，行首为 `+`。
    private static func collectAdded(
        _ node: UIElementRender,
        depth: Int,
        indent: Character,
        options: UIElementRenderLineOptions,
        into out: inout [String]
    ) {
        if options.contains(.withoutInsertionSubtree) { return }
        let eid = node.elementID ?? 0
        var line = "+" + String(repeating: indent, count: depth)
        if !options.contains(.withoutElementID) { line += "\(eid) " }
        line += node.text
        if !options.contains(.withoutDetailText), let d = node.detailText, !d.isEmpty {
            line += " " + d
        }
        out.append(line)
        for child in node.children {
            collectAdded(child, depth: depth + 1, indent: indent,
                         options: options, into: &out)
        }
    }

    /// 移除子树：默认**只收集 elementID**，由摘要头统一表达。
    private static func collectRemoved(_ node: UIElementRender, ids: inout [Int]) {
        if let eid = node.elementID { ids.append(eid) }
        for child in node.children { collectRemoved(child, ids: &ids) }
    }

    /// 把 ID 集合压缩成 `22, 27-113` 形态。实测摘要头正是这种写法。
    static func formatRanges(_ ids: [Int]) -> String {
        guard !ids.isEmpty else { return "" }
        let sorted = Array(Set(ids)).sorted()
        var parts: [String] = []
        var start = sorted[0], prev = sorted[0]
        for v in sorted.dropFirst() {
            if v == prev + 1 { prev = v; continue }
            parts.append(start == prev ? "\(start)" : "\(start)-\(prev)")
            start = v; prev = v
        }
        parts.append(start == prev ? "\(start)" : "\(start)-\(prev)")
        return parts.joined(separator: ", ")
    }

    /// 最长公共子序列（按 id）。
    static func longestCommonSubsequence(_ a: [Int], _ b: [Int]) -> [(Int, Int)] {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        if a.count == b.count, zip(a, b).allSatisfy({ $0.0 == $0.1 }) {
            return a.indices.map { ($0, $0) }
        }

        // Trim common edges before allocating the DP matrix. This is exact and often
        // makes a small localized insertion/deletion cheap even in a wide sibling list.
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
            suffix += 1
        }

        let aEnd = a.count - suffix
        let bEnd = b.count - suffix
        let aMiddle = Array(a[prefix..<aEnd])
        let bMiddle = Array(b[prefix..<bEnd])
        guard !aMiddle.isEmpty, !bMiddle.isEmpty else {
            var out = (0..<prefix).map { ($0, $0) }
            if suffix > 0 {
                out.append(contentsOf: (0..<suffix).map { (aEnd + $0, bEnd + $0) })
            }
            return out
        }

        // The flat matrix avoids the high per-row allocation overhead of [[Int]].
        // 4 million cells ~= 32 MiB on 64-bit platforms. The identical-prefix/suffix
        // trimming above handles typical browser DOM updates without reaching this cap.
        let (cells, overflow) = (aMiddle.count + 1).multipliedReportingOverflow(by: bMiddle.count + 1)
        let maxCells = 4_000_000
        guard !overflow, cells <= maxCells else {
            let middle = largeLongestCommonSubsequence(aMiddle, bMiddle)
            var out = (0..<prefix).map { ($0, $0) }
            out.append(contentsOf: middle.map { (prefix + $0.0, prefix + $0.1) })
            if suffix > 0 {
                out.append(contentsOf: (0..<suffix).map { (aEnd + $0, bEnd + $0) })
            }
            return out
        }

        let width = bMiddle.count + 1
        var dp = [Int](repeating: 0, count: cells)
        for i in stride(from: aMiddle.count - 1, through: 0, by: -1) {
            let row = i * width
            let nextRow = (i + 1) * width
            for j in stride(from: bMiddle.count - 1, through: 0, by: -1) {
                dp[row + j] = aMiddle[i] == bMiddle[j]
                    ? dp[nextRow + j + 1] + 1
                    : max(dp[nextRow + j], dp[row + j + 1])
            }
        }
        var middle: [(Int, Int)] = []
        var i = 0, j = 0
        while i < aMiddle.count, j < bMiddle.count {
            if aMiddle[i] == bMiddle[j] {
                middle.append((prefix + i, prefix + j))
                i += 1; j += 1
            } else if dp[(i + 1) * width + j] >= dp[i * width + j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        var out = (0..<prefix).map { ($0, $0) }
        out.append(contentsOf: middle)
        if suffix > 0 {
            out.append(contentsOf: (0..<suffix).map { (aEnd + $0, bEnd + $0) })
        }
        return out
    }

    private static func largeLongestCommonSubsequence(_ a: [Int], _ b: [Int]) -> [(Int, Int)] {
        var positions: [Int: Int] = [:]
        for (index, id) in b.enumerated() { positions[id] = index }
        // Unique AX identities reduce exact LCS to a longest increasing sequence of positions.
        guard positions.count == b.count, Set(a).count == a.count else {
            return linearSpaceSubsequence(a[...], b[...])
        }
        let matches = a.enumerated().compactMap { index, id in
            positions[id].map { (index, $0) }
        }
        var tails: [Int] = []
        var tailMatches: [Int] = []
        var predecessors = [Int](repeating: -1, count: matches.count)
        for (index, pair) in matches.enumerated() {
            var low = 0, high = tails.count
            while low < high {
                let mid = low + (high - low) / 2
                if tails[mid] < pair.1 { low = mid + 1 } else { high = mid }
            }
            if low > 0 { predecessors[index] = tailMatches[low - 1] }
            if low == tails.count {
                tails.append(pair.1)
                tailMatches.append(index)
            } else {
                tails[low] = pair.1
                tailMatches[low] = index
            }
        }
        var result: [(Int, Int)] = []
        var index = tailMatches.last ?? -1
        while index >= 0 {
            result.append(matches[index])
            index = predecessors[index]
        }
        return result.reversed()
    }

    private static func linearSpaceSubsequence(_ a: ArraySlice<Int>, _ b: ArraySlice<Int>) -> [(Int, Int)] {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        if a.count == 1 {
            return b.firstIndex(of: a[a.startIndex]).map { [(a.startIndex, $0)] } ?? []
        }
        let split = a.startIndex + a.count / 2
        // Release the score rows before recursing so duplicate IDs also use linear space.
        let offset: Int = {
            let left = subsequenceLengths(a[..<split], b)
            let right = subsequenceLengths(a[split...], b, reversed: true)
            var best = -1, offset = 0
            for index in 0...b.count {
                let length = left[index] + right[b.count - index]
                if length > best { best = length; offset = index }
            }
            return offset
        }()
        let bSplit = b.startIndex + offset
        var result = linearSpaceSubsequence(a[..<split], b[..<bSplit])
        result.append(contentsOf: linearSpaceSubsequence(a[split...], b[bSplit...]))
        return result
    }

    private static func subsequenceLengths(_ a: ArraySlice<Int>, _ b: ArraySlice<Int>,
                                           reversed: Bool = false) -> [Int] {
        let left = reversed ? Array(a.reversed()) : Array(a)
        let right = reversed ? Array(b.reversed()) : Array(b)
        var previous = [Int](repeating: 0, count: right.count + 1)
        var current = previous
        for id in left {
            current[0] = 0
            for (index, other) in right.enumerated() {
                current[index + 1] = id == other ? previous[index] + 1
                    : max(previous[index + 1], current[index])
            }
            swap(&previous, &current)
        }
        return previous
    }

}
