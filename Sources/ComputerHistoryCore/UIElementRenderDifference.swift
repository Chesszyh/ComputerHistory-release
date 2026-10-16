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
        let common = longestCommonSubsequence(previous.map(\.id), current.map(\.id))
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

    /// 最长公共子序列（按 id）。树规模有限，用标准 DP。
    static func longestCommonSubsequence(_ a: [Int], _ b: [Int]) -> [(Int, Int)] {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        var dp = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1),
                         count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j]
                    ? dp[i + 1][j + 1] + 1
                    : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var out: [(Int, Int)] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] { out.append((i, j)); i += 1; j += 1 }
            else if dp[i + 1][j] >= dp[i][j + 1] { i += 1 }
            else { j += 1 }
        }
        return out
    }
}
