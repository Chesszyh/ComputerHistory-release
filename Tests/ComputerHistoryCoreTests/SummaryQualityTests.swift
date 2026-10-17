import XCTest
@testable import ComputerHistoryCore

final class SummaryQualityTests: XCTestCase {
    private let app = EventStreamApp(name: "Chrome", bundleIdentifier: "com.google.Chrome")

    func testSparseTreeDoesNotBecomeActivityContent() {
        let event = EventStreamRecord(id: 1, timestamp: Date(), kind: .windowChanged,
            app: .init(name: "Music", bundleIdentifier: "example.music"),
            ax: .init(mode: .fullTree, text: "0 标准窗口\n\t1 菜单项 (disabled) ID: _zoomBottom:\n\t2 菜单项 ID: selectNextTab:"))
        let material = ActivityEvidence.material(events: [event], segmentID: "fixture")
        XCTAssertFalse(material.contains("0 标准窗口"))
        XCTAssertFalse(material.contains("_zoomBottom"))
        XCTAssertFalse(material.contains("selectNextTab"))
        XCTAssertTrue(material.contains("未读取到有效正文"))
    }

    func testChatChromeAndNavigationDoNotDisplaceConversation() {
        let events = [
            EventStreamRecord(id: 1, timestamp: Date(), kind: .mouseClick, app: app,
                mouse: .init(target: .init(role: "AXTextArea", description: "询问 ChatGPT"))),
            EventStreamRecord(id: 2, timestamp: Date(), kind: .keyboardShortcut, app: app,
                keyboard: .init(keyEquivalent: "Left", modifiers: ["function"])),
            EventStreamRecord(id: 3, timestamp: Date(), kind: .windowChanged, app: app,
                ax: .init(mode: .fullTree, text: "0 标准窗口\n\t1 文本框 Value: 询问 ChatGPT\n\t2 按钮 重新生成回复\n\t3 文本 回答已完成\n\t4 文本 讨论训练计划和击打节奏"))]
        let material = ActivityEvidence.material(events: events, segmentID: "fixture")
        XCTAssertFalse(material.contains("点击：询问 ChatGPT"))
        XCTAssertFalse(material.contains("按键："))
        XCTAssertFalse(material.contains("重新生成回复"))
        XCTAssertFalse(material.contains("回答已完成"))
        XCTAssertTrue(material.contains("讨论训练计划和击打节奏"))
    }

    func testLongEditedContentRetainsEndingAndLiteralPromptWords() {
        let text = String(repeating: "训练过程记录。", count: 90) + "结束时准确率约九成。询问 ChatGPT"
        let event = EventStreamRecord(id: 1, timestamp: Date(), kind: .keyboardTextInput,
            app: app, keyboard: .init(text: text, textEvidence: .editedValue))
        let material = ActivityEvidence.material(events: [event], segmentID: "fixture")
        XCTAssertTrue(material.contains("结束时准确率约九成。询问 ChatGPT"))
    }

    func testLongEarlyTextDoesNotConsumeLaterFileResult() {
        let events = (0..<24).map { n in
            EventStreamRecord(id: n, timestamp: Date(timeIntervalSince1970: Double(n)),
                kind: .keyboardTextInput, app: app,
                keyboard: .init(text: n == 23 ? "文档导出完成" : String(repeating: "合成内容", count: 600),
                                textEvidence: .editedValue))
        }
        let material = ActivityEvidence.material(events: events, segmentID: "fixture", characterBudget: 8000)
        XCTAssertTrue(material.contains("文档导出完成"))
        XCTAssertLessThanOrEqual(material.count, 8000)
    }

    func testIndentedTerminalContentSurvivesStructureFiltering() {
        let event = EventStreamRecord(id: 1, timestamp: Date(), kind: .windowChanged,
            app: .init(name: "Terminal"), ax: .init(mode: .fullTree,
                text: "0 文本 Value: terminal output\n\tprint('retained')\n\tindented continuation\n1 标准窗口"))
        let material = ActivityEvidence.material(events: [event], segmentID: "fixture")
        XCTAssertTrue(material.contains("print('retained')"))
        XCTAssertTrue(material.contains("indented continuation"))
        XCTAssertFalse(material.contains("1 标准窗口"))
    }

    func testUncertainChatHintIsOmittedButGenuineEditedWordsRemain() {
        let hint = EventStreamRecord(id: 1, timestamp: Date(), kind: .keyboardTextInput,
            app: app, keyboard: .init(text: "询问 ChatGPT", textEvidence: .uncertainValueChange))
        let digest = SegmentDigest.make(events: [hint], segmentID: "fixture")
        XCTAssertFalse(MemoryGenerator.userPrompt(digest: digest, events: [hint], priorMemory: nil).contains("询问 ChatGPT"))
        var edited = hint
        edited.keyboard?.textEvidence = .editedValue
        XCTAssertTrue(ActivityEvidence.material(events: [edited], segmentID: "fixture").contains("询问 ChatGPT"))
    }
}
