import Foundation
import XCTest
@testable import ComputerHistoryCore

/// 语义身份与差分体量的测试。
///
/// 背景：早期实现用**遍历序号**做跨帧配对，导致树中任何一处增删都让其后所有节点
/// 序号改变，整棵子树被判为"移除 + 新增"。实测差分行数 456~1139，
/// 而官方样本中位数仅 17 行。本组测试锁定修复后的行为。
final class SemanticIdentityTests: XCTestCase {

    // 三层结构，每层多个同 role 兄弟——便于验证增删的影响范围。
    private func window(rows: [String], buttons: [String] = []) -> [UIElementRender] {
        UIElementRenderTree.assignSemanticIdentity([
            UIElementRender(id: 0, text: "窗口", children: [
                UIElementRender(id: 0, text: "container", children:
                    rows.map { t in
                        UIElementRender(id: 0, text: "文本", detailText: "Value: \(t)")
                    } + buttons.map { b in
                        UIElementRender(id: 0, text: "按钮", detailText: b)
                    }),
            ]),
        ])
    }

    private func ids(of roots: [UIElementRender]) -> [Int] {
        var out: [Int] = []
        func walk(_ ns: [UIElementRender]) {
            for n in ns { out.append(n.id); walk(n.children) }
        }
        walk(UIElementRenderTree.assignSemanticIdentity(roots))
        return out
    }

    private func paths(of roots: [UIElementRender]) -> [String] {
        var out: [String] = []
        func walk(_ ns: [UIElementRender]) {
            for n in ns { out.append(n.identityPath ?? "?"); walk(n.children) }
        }
        walk(UIElementRenderTree.assignSemanticIdentity(roots))
        return out
    }

    // MARK: - 身份稳定性

    /// 身份路径是完整层级路径，按深度与 role 序号派生，可读且确定。
    func testIdentityPathShape() {
        let p = paths(of: window(rows: ["a", "b"]))
        XCTAssertEqual(p, [
            "0:窗口#0",
            "0:窗口#0/1:container#0",
            "0:窗口#0/1:container#0/2:文本#0",
            "0:窗口#0/1:container#0/2:文本#1",
        ])
    }

    /// **核心性质**：在末尾追加同 role 兄弟，已有节点的身份不变。
    func testAppendingSiblingKeepsExistingIdentities() {
        let before = ids(of: window(rows: ["a", "b"]))
        let after = ids(of: window(rows: ["a", "b", "c"]))
        XCTAssertEqual(Array(after.prefix(before.count)), before,
                       "追加兄弟不应改变已有节点身份")
        XCTAssertEqual(after.count, before.count + 1)
    }

    /// 追加**不同 role** 的兄弟，已有节点身份完全不变（序号按 role 分别计）。
    func testAppendingDifferentRoleKeepsAllIdentities() {
        let before = ids(of: window(rows: ["a", "b"]))
        let after = ids(of: window(rows: ["a", "b"], buttons: ["确定"]))
        XCTAssertEqual(Array(after.prefix(before.count)), before)
    }

    /// 身份与遍历序号是**两件事**：身份稳定，序号随位置变化。
    func testIdentityIsIndependentOfElementID() {
        func flatten(_ roots: [UIElementRender]) -> [UIElementRender] {
            var out: [UIElementRender] = []
            func walk(_ ns: [UIElementRender]) {
                for n in ns { out.append(n); walk(n.children) }
            }
            walk(UIElementRenderTree.assignElementIDs(
                UIElementRenderTree.assignSemanticIdentity(roots)))
            return out
        }
        let before = flatten(window(rows: ["a", "b"]))
        let after = flatten(window(rows: ["a", "b", "c"]))

        XCTAssertGreaterThan(before.count, 3, "前置条件：应有至少 4 个节点")
        XCTAssertGreaterThan(after.count, 3)
        // 第 4 个节点（文本#1）身份不变，遍历序号也仍是 3
        XCTAssertEqual(before[3].id, after[3].id, "身份应稳定")
        XCTAssertEqual(before[3].elementID, 3)
        XCTAssertEqual(after[3].elementID, 3)
        // 新增的第 5 个节点身份与已有节点都不同
        XCTAssertFalse(before.map(\.id).contains(after[4].id))
    }

    /// 哈希跨调用稳定（`Hasher` 每进程随机播种，故不能用它）。
    func testHashIsStableAcrossCalls() {
        let a = UIElementRenderTree.stableHash("0:窗口/1:container")
        let b = UIElementRenderTree.stableHash("0:窗口/1:container")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, UIElementRenderTree.stableHash("0:窗口/1:其它"))
        XCTAssertGreaterThanOrEqual(a, 0, "应折叠进非负区间")
    }

    // MARK: - 差分体量

    /// 大树上只改一个文本值：差分不应随树规模膨胀。
    ///
    /// 这是本组测试的核心。修复前用遍历序号配对，一次位置变化会让其后所有节点
    /// 身份改变，差分随之接近全树规模（实测线上 456~1139 行）。
    func testSingleValueChangeDoesNotScaleWithTree() throws {
        let n = 60
        let rows = (0..<n).map { "row\($0)" }
        var changed = rows
        changed[n / 2] = "CHANGED"

        let lines = try XCTUnwrap(
            UIElementRenderDifference.lines(from: window(rows: rows),
                                            to: window(rows: changed)))
        // 上下文行是刻意的（与官方一致），但**不应**出现成片的 ± 增删。
        let additions = lines.filter { $0.hasPrefix("+") }.count
        let removals = lines.filter { $0.hasPrefix("-") }.count
        XCTAssertLessThanOrEqual(additions, 2, "只应新增被改动的节点：\(additions)")
        XCTAssertLessThanOrEqual(removals, 1, "只应移除被改动的旧节点：\(removals)")
        // 总行数应接近树规模而非其两倍
        XCTAssertLessThanOrEqual(lines.count, n + 6,
                                 "输出 \(lines.count) 行，树规模约 \(n + 3) 行")
    }

    /// 追加兄弟时，差分只应涉及新增节点，不应重报已有节点。
    func testAppendingSiblingDoesNotReAddExisting() throws {
        let before = window(rows: ["a", "b", "c"])
        let after = window(rows: ["a", "b", "c", "d"])

        let lines = try XCTUnwrap(UIElementRenderDifference.lines(from: before, to: after))
        let added = lines.filter { $0.hasPrefix("+") }
        XCTAssertEqual(added.count, 1, "只应新增一个节点：\(lines)")
        XCTAssertTrue(added[0].contains("Value: d"))
    }

    /// 移除不同 role 的兄弟：只报该节点，不波及同 role 的其它节点。
    func testRemovingDifferentRoleSiblingIsIsolated() throws {
        let before = window(rows: ["a", "b"], buttons: ["确定"])
        let after = window(rows: ["a", "b"])

        let lines = try XCTUnwrap(UIElementRenderDifference.lines(from: before, to: after))
        let removedHeader = lines.first { $0.hasPrefix("Removed element IDs:") }
        XCTAssertNotNil(removedHeader, "移除应产生摘要头")
        // 文本节点不应被误报为移除
        XCTAssertFalse(removedHeader!.contains("2-"),
                       "只应移除按钮，摘要头：\(removedHeader!)")
    }

    /// 未变的树差值只含上下文行。
    func testUnchangedTreeYieldsOnlyContext() throws {
        let tree = window(rows: ["a", "b", "c"])
        let lines = try XCTUnwrap(UIElementRenderDifference.lines(from: tree, to: tree))
        XCTAssertTrue(lines.allSatisfy { $0.hasPrefix("~") }, "实际：\(lines)")
        XCTAssertEqual(lines.count, 5, "应输出全部 5 个节点作为上下文")
    }
}
