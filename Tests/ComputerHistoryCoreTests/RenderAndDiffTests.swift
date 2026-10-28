import Foundation
import XCTest
@testable import ComputerHistoryCore

/// 渲染器与差分器的往返测试。
///
/// 核心不变式：**渲染器产出的文本，必须能被解析器按同一文法读回**。
/// 采集层要"产出"而不只是"解析"同形的 ax.text，这条性质是它的正确性依据。
final class RenderAndDiffTests: XCTestCase {

    /// 基础树：显式 id，保证各变体之间稳定可配对。
    /// 不变量——`base` 的每棵子树在变体中要么完整保留、要么整体替换，
    /// 以免出现"同一 id 换了内容"这种在本实现里被表达为增+删的情形。
    private func baseTree() -> [UIElementRender] {
        [
            UIElementRender(id: 1, text: "标准窗口", detailText: "标题, ID: main",
                children: [
                    UIElementRender(id: 2, text: "container", children: [
                        UIElementRender(id: 3, text: "按钮", detailText: "(disabled) 返回"),
                        UIElementRender(id: 4, text: "文本",
                                        detailText: "Value: 10月9日周五, ID: LargeDate"),
                    ]),
                    UIElementRender(id: 5, text: "滚动区", children: [
                        UIElementRender(id: 6, text: "文本", detailText: "电池 85%"),
                    ]),
                ])
        ]
    }

    /// 在上面的基础上追加一棵新子树（id 9 / 10 未被占用）。
    private func withAddedPanel() -> [UIElementRender] {
        var t = baseTree()
        t[0].children.append(
            UIElementRender(id: 9, text: "新面板", children: [
                UIElementRender(id: 10, text: "按钮", detailText: "确定"),
            ]))
        return t
    }

    /// 在上面的基础上移除整棵"滚动区"子树（id 5 / 6）。
    private func withRemovedScroller() -> [UIElementRender] {
        var t = baseTree()
        t[0].children.removeLast()
        return t
    }

    // 构造一棵有代表性的树：混合 role、属性、多行值与嵌套。
    private func makeTree() -> [UIElementRender] {
        [
            UIElementRender(
                id: 1, text: "标准窗口", detailText: "标题, ID: main",
                children: [
                    UIElementRender(id: 2, text: "container", children: [
                        UIElementRender(id: 3, text: "按钮", detailText: "(disabled) 返回"),
                        UIElementRender(id: 4, text: "文本",
                                        detailText: "Value: 10月9日周五, ID: LargeDate"),
                    ]),
                    UIElementRender(id: 5, text: "滚动区", children: [
                        UIElementRender(id: 6, text: "文本", detailText: "电池 85%"),
                    ]),
                ])
        ]
    }

    /// elementID 按深度优先从 0 连续编号。
    func testElementIDsAreDepthFirstContiguous() {
        let text = UIElementRenderTree.text(makeTree())
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 6)
        for (expected, line) in lines.enumerated() {
            let parsed = AXTextParser.parseLine(line, mode: .fullTree)
            guard case let .element(nil, _, eid, _, _) = parsed else {
                return XCTFail("第 \(expected) 行未解析为元素行：\(line)")
            }
            XCTAssertEqual(eid, expected, "elementID 应为深度优先连续编号：\(line)")
        }
    }

    /// 渲染结果必须能被解析器读回，且深度/role/detail 完全一致。
    func testRenderParsesBackToSameTree() {
        let tree = makeTree()
        let text = UIElementRenderTree.text(tree)
        let parsed = AXTextParser.parse(text, mode: .fullTree)

        var flat: [(depth: Int, role: String, detail: String?)] = []
        func flatten(_ nodes: [UIElementRender], _ d: Int) {
            for n in nodes {
                flat.append((d, n.text, n.detailText))
                flatten(n.children, d + 1)
            }
        }
        flatten(tree, 0)

        let elements = parsed.compactMap { line -> (Int, String, String?)? in
            guard case let .element(nil, d, _, role, detail) = line else { return nil }
            return (d, role, detail)
        }
        XCTAssertEqual(elements.count, flat.count)
        for (got, want) in zip(elements, flat) {
            XCTAssertEqual(got.0, want.depth, "深度不一致：\(got)")
            XCTAssertEqual(got.1, want.role, "role 不一致：\(got)")
            XCTAssertEqual(got.2, want.detail, "detail 不一致：\(got)")
        }
    }

    /// 多行值原样保留，其续行不带缩进。
    func testMultilineTextPreserved() {
        let tree = [UIElementRender(id: 1, text: "文本",
                                    detailText: "Value: 第一行\n第二行\n第三行")]
        let text = UIElementRenderTree.text(tree)
        XCTAssertEqual(text, "0 文本 Value: 第一行\n第二行\n第三行")
    }

    // MARK: - 差分

    /// 未变的树差值应只含上下文行，无新增、无移除摘要。
    func testIdenticalTreesProduceOnlyContext() throws {
        let tree = baseTree()
        let lines = try XCTUnwrap(UIElementRenderDifference.lines(from: tree, to: tree))
        if lines.contains(where: { $0.hasPrefix("+") }) {
            print("DIFF-DEBUG 自身差分产出：")
            for l in lines { print("  \(l.debugDescription)") }
            print("DIFF-DEBUG 编号后：")
            for n in UIElementRenderTree.assignElementIDs(tree) {
                print("  id=\(n.id) eid=\(String(describing: n.elementID)) text=\(n.text)")
            }
        }
        XCTAssertFalse(lines.contains { $0.hasPrefix("+") }, "不应有新增行")
        XCTAssertFalse(lines.contains { $0.hasPrefix("Removed element IDs:") }, "不应有移除头")
        XCTAssertTrue(lines.allSatisfy { $0.hasPrefix("~") }, "应全为上下文行")
    }

    /// 新增子树逐层展开，行首为 `+`，且缩进正确。
    func testAddedSubtreeIsFullyExpanded() throws {
        let lines = try XCTUnwrap(
            UIElementRenderDifference.lines(from: baseTree(), to: withAddedPanel()))

        let added = lines.filter { $0.hasPrefix("+") }
        XCTAssertEqual(added.count, 2, "新增子树应展开两层")
        XCTAssertTrue(added[0].contains("新面板"))
        XCTAssertTrue(added[1].hasPrefix("+\t\t"), "子节点深度 2，应为 2 个 TAB，实际：\(added[1])")
    }

    /// 移除默认折叠为摘要头，不逐行输出 `-`。
    func testRemovedSubtreeFoldsIntoHeader() throws {
        let lines = try XCTUnwrap(
            UIElementRenderDifference.lines(from: baseTree(), to: withRemovedScroller()))

        let header = try XCTUnwrap(lines.first { $0.hasPrefix("Removed element IDs:") })
        XCTAssertFalse(lines.contains { $0.hasPrefix("-") },
                       "移除应折叠，不应出现 '-' 行")
        // 摘要头应覆盖被移除子树的所有 elementID
        XCTAssertTrue(header.contains("4-5") || header.contains("4") || header.contains("5"),
                      "摘要头应含被移除的 elementID：\(header)")
    }

    /// 超预算时返回 nil —— 这是 `fullTree` 在段中间出现的成因。
    func testBudgetExceededReturnsNil() {
        let before = makeTree()
        var tree = makeTree()
        for i in 100..<200 {
            tree[0].children.append(UIElementRender(id: i, text: "新增\(i)"))
        }
        XCTAssertNil(UIElementRenderDifference.lines(from: before, to: tree, lineBudget: 10),
                     "超预算应返回 nil 以便调用方回退整树")
        XCTAssertNotNil(UIElementRenderDifference.lines(from: before, to: tree,
                                                        ignoreLineBudget: true,
                                                        lineBudget: 10),
                        "ignoreLineBudget 应绕过预算")
    }

    /// 差分行必须能被解析器按 diffFromPrevious 文法读回。
    func testDiffOutputParsesAsDiffMode() throws {
        let lines = try XCTUnwrap(
            UIElementRenderDifference.lines(from: baseTree(), to: withAddedPanel()))
        let text = lines.joined(separator: "\n")
        let parsed = AXTextParser.parse(text, mode: .diffFromPrevious)

        var sawHeader = false, sawAddition = false, sawContext = false
        for line in parsed {
            switch line {
            case .removedElementIDs: sawHeader = true
            case let .element(marker, _, _, _, _):
                if marker == "+" { sawAddition = true }
                if marker == "~" { sawContext = true }
            default: break
            }
        }
        XCTAssertTrue(sawContext, "应含上下文行")
        XCTAssertTrue(sawAddition, "应含新增行")
        XCTAssertFalse(sawHeader, "本例无移除，不应有摘要头")
    }

    /// ID 区间压缩格式：与样本中 `22, 27-113` 同形。
    func testRangeCompression() {
        XCTAssertEqual(UIElementRenderDifference.formatRanges([22, 27, 28, 29]), "22, 27-29")
        XCTAssertEqual(UIElementRenderDifference.formatRanges([5]), "5")
        XCTAssertEqual(UIElementRenderDifference.formatRanges([1, 2, 3, 7]), "1-3, 7")
        XCTAssertEqual(UIElementRenderDifference.formatRanges([3, 1, 2]), "1-3", "应去重并排序")
        // 解析回来必须一致
        let s = UIElementRenderDifference.formatRanges([22, 27, 28, 29])
        let (ranges, singles) = AXTextParser.parseRanges(s)
        XCTAssertEqual(singles, [22])
        XCTAssertEqual(ranges, [27...29])
    }

    // MARK: - LCS

    func testLongestCommonSubsequence() {
        XCTAssertEqual(UIElementRenderDifference.longestCommonSubsequence([1, 2, 3], [1, 2, 3]).count, 3)
        XCTAssertEqual(UIElementRenderDifference.longestCommonSubsequence([1], [1]).count, 1)
        XCTAssertEqual(UIElementRenderDifference.longestCommonSubsequence([], [1]).count, 0)
        let ab = UIElementRenderDifference.longestCommonSubsequence([1, 2, 3], [1, 3])
        XCTAssertEqual(ab.map(\.0), [0, 2])
        XCTAssertEqual(ab.map(\.1), [0, 1])
    }

    func testLongestCommonSubsequenceHandlesLargeIdenticalListsWithoutQuadraticWork() {
        let ids = Array(0..<5_000)
        let result = UIElementRenderDifference.longestCommonSubsequence(ids, ids)
        XCTAssertEqual(result.count, ids.count)
        XCTAssertEqual(result.first?.0, 0)
        XCTAssertEqual(result.last?.0, ids.count - 1)
        XCTAssertEqual(result.map(\.0), result.map(\.1))
    }

    func testLongestCommonSubsequencePreservesLocalizedChangesAtLargeEdges() {
        let before = Array(0..<3_000)
        var after = before
        after.insert(-1, at: 1_500)
        let result = UIElementRenderDifference.longestCommonSubsequence(before, after)
        XCTAssertEqual(result.count, before.count)
        XCTAssertEqual(result.first?.0, 0)
        XCTAssertEqual(result.first?.1, 0)
        XCTAssertEqual(result.last?.0, 2_999)
        XCTAssertEqual(result.last?.1, 3_000)
    }

    func testLongestCommonSubsequenceBoundsMemoryForPathologicalSiblingLists() {
        let before = Array(0..<2_100)
        let after = Array((0..<2_100).reversed())
        let result = UIElementRenderDifference.longestCommonSubsequence(before, after)
        XCTAssertFalse(result.isEmpty)
        XCTAssertTrue(zip(result, result.dropFirst()).allSatisfy {
            $0.0.0 < $0.1.0 && $0.0.1 < $0.1.1
        }, "LCS pairs must remain strictly increasing")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(before[result[0].0], after[result[0].1])
    }

    func testWideSlidingListKeepsExactCompactDiff() {
        let before = (0..<2_100).map { UIElementRender(id: $0, text: "row-\($0)") }
        let after = (1...2_100).map { UIElementRender(id: $0, text: "row-\($0)") }
        let matches = UIElementRenderDifference.longestCommonSubsequence(before.map(\.id), after.map(\.id))
        XCTAssertEqual(matches.count, 2_099)
        let lines = UIElementRenderDifference.lines(from: before, to: after, includesUnchangedContext: false)
        XCTAssertEqual(lines?.count, 2)
        XCTAssertEqual(lines?.first, "Removed element IDs: 0")
        XCTAssertEqual(lines?.last, "+2099 row-2100")
    }

    func testLargeUniqueListsKeepOptimalMatchesAcrossReorderings() {
        let permutations = [[5, 4, 3, 2, 1, 0], [2, 3, 0, 4, 1, 5], [1, 2, 3, 4, 5, 0], [0, 2, 4, 1, 3, 5]]
        for permutation in permutations {
            let small = Array(0..<6)
            var lengths = [[Int]](repeating: [Int](repeating: 0, count: 7), count: 7)
            for i in small.indices {
                for j in permutation.indices {
                    lengths[i + 1][j + 1] = small[i] == permutation[j] ? lengths[i][j] + 1
                        : max(lengths[i][j + 1], lengths[i + 1][j])
                }
            }
            let before = [-1] + small + Array(10_000..<12_000)
            let after = [-2] + permutation + Array(20_000..<22_000)
            let matches = UIElementRenderDifference.longestCommonSubsequence(before, after)
            XCTAssertEqual(matches.count, lengths[6][6])
            XCTAssertTrue(matches.allSatisfy { before[$0.0] == after[$0.1] })
            XCTAssertTrue(zip(matches, matches.dropFirst()).allSatisfy {
                $0.0.0 < $0.1.0 && $0.0.1 < $0.1.1
            })
        }
    }

    func testLargeDuplicateIDListsRetainExactMatches() {
        let before = [0] + [Int](repeating: 7, count: 2_100) + [1]
        let after = [2] + [Int](repeating: 7, count: 2_100) + [3]
        let matches = UIElementRenderDifference.longestCommonSubsequence(before, after)
        XCTAssertEqual(matches.count, 2_100)
        XCTAssertTrue(matches.allSatisfy { before[$0.0] == after[$0.1] })
        XCTAssertTrue(zip(matches, matches.dropFirst()).allSatisfy {
            $0.0.0 < $0.1.0 && $0.0.1 < $0.1.1
        })
    }

    // MARK: - 选项

    func testRenderOptionsSuppressParts() {
        let tree = [UIElementRender(id: 1, text: "按钮", detailText: "确定")]
        XCTAssertEqual(
            UIElementRenderTree.text(tree, options: [.withoutDetailText]), "0 按钮")
        XCTAssertEqual(
            UIElementRenderTree.text(tree, options: [.withoutElementID]), "按钮 确定")
    }
}
