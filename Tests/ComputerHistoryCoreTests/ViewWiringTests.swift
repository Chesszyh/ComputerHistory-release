import Foundation
import XCTest

/// 界面接线检查。
///
/// 这个用例存在的理由：前端源文件被整体重写过一次，而后续改动是照着旧结构写的，
/// 替换字符串没匹配上却构建通过——于是「设置区」与「详情页」两个视图定义了却从未
/// 被引用，功能静默消失。编译器和单元测试都发现不了，因为它们只关心已引用的代码。
///
/// 静态扫源做粗检：任何一个 `struct X: View` 都应在别处被构造。
final class ViewWiringTests: XCTestCase {

    /// 允许不被引用的视图：仅作为容器被 SwiftUI 直接使用的入口。
    private let allowedOrphans: Set<String> = [
        "ComputerHistoryMenuBarApp",   // @main 入口
        "StatusPanel",                 // MenuBarExtra 直接构造
    ]

    func testNoOrphanedViews() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ComputerHistoryCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 仓库根
        let menubar = root.appendingPathComponent("Sources/computer-history-menubar")

        let files = try FileManager.default.contentsOfDirectory(
            at: menubar, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "找不到托盘源文件")

        let pattern = try NSRegularExpression(pattern: #"^struct\s+(\w+)\s*:\s*View"#,
                                              options: [.anchorsMatchLines])
        var orphans: [String] = []

        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            for match in pattern.matches(in: text, range: range) {
                guard let nameRange = Range(match.range(at: 1), in: text) else { continue }
                let name = String(text[nameRange])
                if allowedOrphans.contains(name) { continue }
                // 构造点是「名字紧跟左括号」。定义行是 `struct X: View`，
                // 名字后面跟的是冒号，因此不会被算进来。
                let constructions = text.components(separatedBy: "\(name)(").count - 1
                if constructions <= 0 {
                    orphans.append("\(name)（\(file.lastPathComponent)）")
                }
            }
        }

        XCTAssertTrue(orphans.isEmpty,
                      "以下视图被定义了但从未构造，功能不会生效：\(orphans.joined(separator: "、"))")
    }

    /// 反向检查：模型上被视图使用的能力应当真的存在构造点。
    /// 目前只覆盖设置区与详情页这两个曾静默失效的入口。
    func testKnownEntryPointsAreWired() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let panel = root.appendingPathComponent(
            "Sources/computer-history-menubar/StatusPanel.swift")
        let text = try String(contentsOf: panel, encoding: .utf8)

        for entry in ["SettingsSection(model:", "DetailPane(content:"] {
            XCTAssertTrue(text.contains(entry),
                          "\(entry) 未接线——对应的界面不会出现")
        }
    }
}
