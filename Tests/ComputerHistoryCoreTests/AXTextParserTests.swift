import Foundation
import XCTest
@testable import ComputerHistoryCore

/// 覆盖 `ax.text` 两种模式文法与落盘编码契约的测试。
///
/// 除合成样例外，另有一组**可选**测试在真实样本目录存在时运行
/// （路径见 `RealSampleTests`），作为对官方数据的回归。样本目录属用户本地数据，
/// 不纳入仓库，缺失时跳过。
final class AXTextParserTests: XCTestCase {

    // MARK: - diffFromPrevious

    func testDiffModeMarkersAndDepth() {
        let text = """
        Removed element IDs: 22, 27-113
        ~0 标准窗口 无标题, URL: vn.example
        ~\t1 container
        +\t\t\t7 按钮 (disabled) 返回
        -\t\t8 图像
        """
        let lines = AXTextParser.parse(text, mode: .diffFromPrevious)
        XCTAssertEqual(lines.count, 5)

        guard case let .removedElementIDs(ranges, singles) = lines[0] else {
            return XCTFail("首行应为移除摘要头")
        }
        XCTAssertEqual(singles, [22])
        XCTAssertEqual(ranges, [27...113])

        guard case let .element(m, d, eid, role, detail) = lines[1] else {
            return XCTFail("第 2 行应为元素行")
        }
        XCTAssertEqual(m, "~")
        XCTAssertEqual(d, 0)
        XCTAssertEqual(eid, 0)
        XCTAssertEqual(role, "标准窗口")
        XCTAssertEqual(detail, "无标题, URL: vn.example")

        guard case let .element(m2, d2, eid2, role2, nil) = lines[2] else {
            return XCTFail("第 3 行应无 detail")
        }
        XCTAssertEqual(m2, "~")
        XCTAssertEqual(d2, 1)
        XCTAssertEqual(eid2, 1)
        XCTAssertEqual(role2, "container")

        guard case let .element(m3, d3, eid3, role3, detail3) = lines[3] else {
            return XCTFail("第 4 行应为元素行")
        }
        XCTAssertEqual(m3, "+")
        XCTAssertEqual(d3, 3)
        XCTAssertEqual(eid3, 7)
        XCTAssertEqual(role3, "按钮")
        XCTAssertEqual(detail3, "(disabled) 返回")

        guard case let .element(m4, d4, eid4, _, _) = lines[4] else {
            return XCTFail("第 5 行应为元素行")
        }
        XCTAssertEqual(m4, "-")
        XCTAssertEqual(d4, 2)
        XCTAssertEqual(eid4, 8)
    }

    /// 元素文本自带换行时产生无标记续行，必须与元素行区分。
    func testDiffModeContinuationLines() {
        let text = """
        ~\t14 container Webtime Tracker
        扩展程序
        ChatGPT 长对话工具箱
        """
        let lines = AXTextParser.parse(text, mode: .diffFromPrevious)
        guard case .element = lines[0] else { return XCTFail("首行应为元素行") }
        XCTAssertEqual(lines[1], AXTextLine.continuation("扩展程序"))
        XCTAssertEqual(lines[2], AXTextLine.continuation("ChatGPT 长对话工具箱"))
    }

    /// 空行保留（实测 diffFromPrevious 有 1 187 个空行）。
    func testBlankLinesPreserved() {
        let lines = AXTextParser.parse("~0 窗口\n\n~1 container", mode: .diffFromPrevious)
        XCTAssertEqual(lines[1], AXTextLine.blank)
        XCTAssertEqual(lines.count, 3)
    }

    // MARK: - fullTree

    /// fullTree 无前缀标记，直接 TAB + 元素 ID。
    func testFullTreeHasNoMarker() {
        let text = """
        0 窗口 登录, ID: login
        \t1 菜单按钮 Description: 网络, ID: WiFiMenuButton
        \t2 图像 电池 85%
        \t\t7 Button 显示所有用户
        """
        let lines = AXTextParser.parse(text, mode: .fullTree)
        guard case let .element(m, d, eid, role, detail) = lines[0] else {
            return XCTFail("应为元素行")
        }
        XCTAssertNil(m, "fullTree 不应有标记")
        XCTAssertEqual(d, 0); XCTAssertEqual(eid, 0)
        XCTAssertEqual(role, "窗口"); XCTAssertEqual(detail, "登录, ID: login")

        guard case .element(nil, 1, 1, "菜单按钮", _) = lines[1] else {
            return XCTFail("第 2 行解析错误")
        }
        guard case .element(nil, 2, 7, "Button", _) = lines[3] else {
            return XCTFail("第 4 行深度应为 2")
        }
    }

    /// 关键陷阱：fullTree 中以 `~`/`+`/`-` 开头的行是**终端屏幕内容**，不是差分标记。
    func testFullTreeTerminalContentIsNotTreatedAsMarker() {
        let text = """
        ~ ❯ sudo apt update
        ~53%
        +
        --rm
        """
        let lines = AXTextParser.parse(text, mode: .fullTree)
        for (i, line) in lines.enumerated() {
            if case let .element(m, _, _, _, _) = line {
                XCTAssertNil(m, "第 \(i) 行不应被当作带标记的元素行")
            }
        }
        XCTAssertEqual(lines[0], AXTextLine.continuation("~ ❯ sudo apt update"))
        XCTAssertEqual(lines[1], AXTextLine.continuation("~53%"))
        XCTAssertEqual(lines[3], AXTextLine.continuation("--rm"))
    }

    // MARK: - 区间解析

    func testRemovedIDRangeShapes() {
        // 实测出现过 N、N-N、以及混合逗号列表
        for s in ["13", "27-113", "22, 27-113", "1-2, 5-6, 9-11"] {
            let (r, single) = AXTextParser.parseRanges(s)
            XCTAssertFalse(r.isEmpty && single.isEmpty, "应解析出内容：\(s)")
        }
        let (r2, s2) = AXTextParser.parseRanges("1-2, 5-6, 9-11")
        XCTAssertEqual(r2, [1...2, 5...6, 9...11])
        XCTAssertTrue(s2.isEmpty)
    }
}
