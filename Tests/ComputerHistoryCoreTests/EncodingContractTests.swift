import Foundation
import XCTest
@testable import ComputerHistoryCore

/// 落盘编码契约。这些行为由 88 段真实样本全量实测得出，任何一条被破坏都会
/// 让重建产物无法与官方数据比对。
final class EncodingContractTests: XCTestCase {

    private func encodeToString(_ record: EventStreamRecord) throws -> String {
        String(decoding: try EventStreamJSON.makeEncoder().encode(record), as: UTF8.self)
    }

    /// 可选字段为 nil 时必须**省略键**，绝不写 null（226 个真实事件含缺失键，0 个 null）。
    func testNilOptionalsAreOmittedNotNulled() throws {
        let r = EventStreamRecord(
            id: 1,
            timestamp: Date(timeIntervalSince1970: 0),
            kind: .sessionStarted)
        let s = try encodeToString(r)
        XCTAssertFalse(s.contains("null"), "不应出现 null：\(s)")
        XCTAssertFalse(s.contains("app"), "nil 的 app 不应出现")
        XCTAssertFalse(s.contains("window"), "nil 的 window 不应出现")
        XCTAssertFalse(s.contains("ax"), "nil 的 ax 不应出现")
        XCTAssertTrue(s.contains("\"kind\":\"session.started\""))
        XCTAssertTrue(s.contains("\"id\":1"))
    }

    /// 时间戳为严格秒级 RFC3339，无小数秒（18 951 个真实时间戳全部如此）。
    func testTimestampIsSecondPrecisionRFC3339() throws {
        let r = EventStreamRecord(id: 7, timestamp: Date(timeIntervalSince1970: 0),
                                  kind: .sessionEnded)
        let s = try encodeToString(r)
        XCTAssertTrue(s.contains("\"timestamp\":\"1970-01-01T00:00:00Z\""), s)
    }

    /// 数组字段为空（默认值）时省略键——实测 keyboard.modifiers 出现时 100% 非空。
    func testEmptyArraysAreOmitted() throws {
        let r = EventStreamRecord(
            id: 2,
            timestamp: Date(timeIntervalSince1970: 0),
            kind: .keyboardShortcut,
            keyboard: EventStreamKeyboardInteraction(keyEquivalent: "c", modifiers: []))
        let s = try encodeToString(r)
        XCTAssertFalse(s.contains("modifiers"), "空 modifiers 不应出现：\(s)")
        XCTAssertTrue(s.contains("\"keyEquivalent\":\"c\""))
    }

    func testNonEmptyArraysAreWritten() throws {
        let r = EventStreamRecord(
            id: 3,
            timestamp: Date(timeIntervalSince1970: 0),
            kind: .keyboardShortcut,
            keyboard: EventStreamKeyboardInteraction(keyEquivalent: "c",
                                                     modifiers: ["command"]))
        let s = try encodeToString(r)
        XCTAssertTrue(s.contains("\"modifiers\":[\"command\"]"), s)
    }

    /// `app.secureInput` 缺键须能解码，且语义是**未知**而非 false。
    ///
    /// 实测 18 951 个事件里该键仅出现 2 次；官方编码时省略默认值，
    /// 而本实现无从查询该状态，故以 nil 表示未知并省略键——不用 false 冒充已知。
    func testSecureInputAbsentMeansUnknown() throws {
        let json = #"{"id":4,"timestamp":"1970-01-01T00:00:00Z","kind":"mouse.click","app":{"name":"X"}}"#
        let r = try EventStreamJSON.makeDecoder().decode(
            EventStreamRecord.self, from: Data(json.utf8))
        XCTAssertNil(r.app?.secureInput, "缺键应解码为 nil（未知）")
        XCTAssertEqual(r.app?.name, "X")
        // 未知时编码同样省略该键
        let s = try encodeToString(r)
        XCTAssertFalse(s.contains("secureInput"), "未知状态不应写出该键：\(s)")
    }

    /// 两个 ax.mode 都必须能往返。
    func testAXTreeModesRoundTrip() throws {
        for mode in [EventStreamAXTree.Mode.diffFromPrevious, .fullTree] {
            let r = EventStreamRecord(
                id: 5, timestamp: Date(timeIntervalSince1970: 0),
                kind: .windowChanged,
                ax: EventStreamAXTree(mode: mode, text: "0 窗口"))
            let s = try encodeToString(r)
            XCTAssertTrue(s.contains("\"mode\":\"\(mode.rawValue)\""), s)
            let back = try EventStreamJSON.makeDecoder().decode(
                EventStreamRecord.self, from: Data(s.utf8))
            XCTAssertEqual(back.ax?.mode, mode)
        }
    }
}
