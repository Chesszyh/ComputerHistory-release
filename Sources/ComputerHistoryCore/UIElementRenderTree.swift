import Foundation

/// 一棵可供渲染与差分的 Accessibility 树。
///
/// 对应官方 `ComputerUseCore.UIElementRender<ID>`：每个节点有稳定身份 `id`、
/// 落盘用的 `elementID`（连续编号）、`text`（role 与属性拼成的行内容）、
/// 可选 `detailText`，以及子节点。
///
/// 渲染规则由 88 段真实产物反推（`fullTree` 163 416 行）：
///   - 行 = `<TAB×depth><elementID> <text>`；`detailText` 非空时以空格续接。
///   - `elementID` 按**深度优先**顺序从 0 连续编号。
///   - `text` 自身可含换行（多行值），这些续行**不带缩进**原样落盘。
///
/// ## 身份语义（差分正确性的关键）
///
/// 官方的 `id` 是元素的**语义身份**，与它在树中的遍历序号无关；`elementID`
/// 才是遍历序号。两者混用会导致差分爆炸：树中任何一处增删都会让其后所有节点的
/// 序号改变，于是整棵子树被判为"移除 + 新增"。
///
/// 采集端以 AX 对象哈希提供 `id`；没有 AX 句柄的树可显式调用
/// `assignSemanticIdentity` 生成路径身份。差分保留调用方传入的身份。
public struct UIElementRender: Equatable, Sendable {
    /// 跨帧身份，由采集端或路径身份生成器提供，非遍历序号。
    public var id: Int
    /// 该节点的身份路径，形如 `0:窗口/1:container/2:按钮#0`。仅用于诊断与测试。
    public var identityPath: String?
    /// 落盘的连续编号。为 nil 时由渲染器按深度优先分配。
    public var elementID: Int?
    /// 行主体，通常是 role（可含多行）。
    public var text: String
    /// 行尾附加信息（属性串）。为空则不追加。
    public var detailText: String?
    public var children: [UIElementRender]
    public var accessibilityRole: String?

    public init(
        id: Int,
        identityPath: String? = nil,
        elementID: Int? = nil,
        text: String,
        detailText: String? = nil,
        children: [UIElementRender] = [],
        accessibilityRole: String? = nil
    ) {
        self.id = id
        self.identityPath = identityPath
        self.elementID = elementID
        self.text = text
        self.detailText = detailText
        self.children = children
        self.accessibilityRole = accessibilityRole
    }
}

/// 渲染选项。对应官方 `UIElementRenderLineOptions`（OptionSet，实测成员见 schema）。
public struct UIElementRenderLineOptions: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// 不输出 `detailText`。
    public static let withoutDetailText = UIElementRenderLineOptions(rawValue: 1 << 0)
    /// 不输出行首的 `elementID`。
    public static let withoutElementID = UIElementRenderLineOptions(rawValue: 1 << 1)
    /// 不展开新增子树。
    public static let withoutInsertionSubtree = UIElementRenderLineOptions(rawValue: 1 << 2)
    /// 不展开移除子树。
    public static let withoutRemovalSubtree = UIElementRenderLineOptions(rawValue: 1 << 3)
}

public enum UIElementRenderTree {

    /// 按语义路径为整棵树写回 `id` 与 `identityPath`。
    ///
    /// **采集路径不使用本方法**：`AXTreeReader` 直接按 `CFHash` 写入精确身份
    /// （跨帧实测 1417/1417 一致）。本方法保留给两类场景——由渲染文本反解出的树
    /// （无 AX 句柄可用），以及不依赖 Accessibility 的单元测试。
    /// 其身份基于「同 role 第几个」，在同 role 兄弟插入时会让后续节点身份顺延。
    ///
    /// 身份路径 = 各层「depth:role#同role序号」用 `/` 连接，例如
    /// `0:窗口/1:container/2:按钮#0`。取序号而非绝对位置，是为了让**不同 role**
    /// 的兄弟增删不影响已有节点的身份；同 role 的兄弟插在最前时，其后的同 role
    /// 节点身份仍会整体后移，这是该方案的已知边界。
    ///
    /// 用 role（而非 title/value）参与身份，因为 title/value 是**可变内容**——
    /// 把它们算进身份会让"标题变了"被判定为"旧节点移除 + 新节点新增"，
    /// 而正确语义是"同一节点内容变化"。
    ///
    /// 返回新数组，不修改入参。
    public static func assignSemanticIdentity(_ roots: [UIElementRender]) -> [UIElementRender] {
        func walk(_ nodes: [UIElementRender], depth: Int,
                  parentPath: String) -> [UIElementRender] {
            // 统计每个 role 在当前层已出现的次数，作为该节点的序号。
            var seenByRole: [String: Int] = [:]
            return nodes.map { node in
                let role = roleToken(of: node)
                let ordinal = seenByRole[role, default: 0]
                seenByRole[role] = ordinal + 1
                let step = "\(depth):\(role)#\(ordinal)"
                let path = parentPath.isEmpty ? step : parentPath + "/" + step

                var out = node
                out.identityPath = path
                out.id = stableHash(path)
                out.children = walk(node.children, depth: depth + 1, parentPath: path)
                return out
            }
        }
        return walk(roots, depth: 0, parentPath: "")
    }

    /// 身份路径上的 role 片段：取行主体的首个词，去掉其中可能干扰的空格与 TAB。
    static func roleToken(of node: UIElementRender) -> String {
        let firstLine = node.text.split(separator: "\n", maxSplits: 1,
                                        omittingEmptySubsequences: false).first ?? ""
        let firstWord = firstLine.split(separator: " ", maxSplits: 1,
                                        omittingEmptySubsequences: true).first ?? ""
        return firstWord.isEmpty ? "?" : String(firstWord)
    }

    /// FNV-1a：稳定、无依赖，跨进程与跨运行一致（`Hasher` 每进程随机播种，不可用）。
    static func stableHash(_ s: String) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        // 折叠进 Int 正区间，避免极端值影响排序稳定性。
        return Int(truncatingIfNeeded: hash & 0x7fff_ffff_ffff_ffff)
    }

    /// 按深度优先顺序写入连续 `elementID`。
    ///
    /// 渲染前调用。与 `assignSemanticIdentity` 分工明确：前者是**渲染序号**，
    /// 后者是**跨帧身份**。混用两者会导致差分爆炸（见 `UIElementRender` 文档）。
    public static func assignElementIDs(_ roots: [UIElementRender]) -> [UIElementRender] {
        var counter = 0
        func number(_ node: UIElementRender) -> UIElementRender {
            var n = node
            n.elementID = counter
            counter += 1
            n.children = node.children.map(number)
            return n
        }
        return roots.map(number)
    }


    /// 渲染整棵树为 `fullTree` 形态的行序列。
    ///
    /// `indentCharacter` 固定为 TAB——二进制中 `UIElementRenderTree.lines(indent:)`
    /// 的实参是 `0x09`，与样本实测一致。
    public static func lines(
        _ roots: [UIElementRender],
        indent: Character = "\t",
        options: UIElementRenderLineOptions = []
    ) -> [String] {
        var out: [String] = []
        var counter = 0
        func walk(_ node: UIElementRender, depth: Int) {
            let eid = node.elementID ?? counter
            counter += 1
            out.append(line(for: node, elementID: eid, depth: depth,
                            indent: indent, options: options))
            for child in node.children {
                walk(child, depth: depth + 1)
            }
        }
        for root in roots { walk(root, depth: 0) }
        return out
    }

    public static func text(
        _ roots: [UIElementRender],
        indent: Character = "\t",
        options: UIElementRenderLineOptions = []
    ) -> String {
        lines(roots, indent: indent, options: options).joined(separator: "\n")
    }

    /// 单行渲染：`<TAB×depth>[elementID ]text[ detailText]`。
    static func line(
        for node: UIElementRender,
        elementID: Int,
        depth: Int,
        indent: Character,
        options: UIElementRenderLineOptions
    ) -> String {
        var s = String(repeating: indent, count: depth)
        if !options.contains(.withoutElementID) {
            s += "\(elementID) "
        }
        s += node.text
        if !options.contains(.withoutDetailText), let detail = node.detailText, !detail.isEmpty {
            s += " " + detail
        }
        return s
    }
}
