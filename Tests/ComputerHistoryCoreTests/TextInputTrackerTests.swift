import Foundation
import XCTest
@testable import ComputerHistoryCore

/// 文本输入聚合的行为测试。
///
/// 参数依据来自实测：`keyboard.text` 是输入法提交的片段（含拼音串），
/// 长度中位 6、最长 88；相邻事件间隔中位 3 秒。
final class TextInputTrackerTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func obs(_ v: String?, _ c: Int? = nil) -> TextInputTracker.Observation {
        .init(value: v, caret: c, isEditableBuffer: true, focusIdentity: 1)
    }

    /// 首次观察只建立基线——字段里已有的内容不是本次输入。
    func testFirstObservationEstablishesBaselineOnly() {
        let tr = TextInputTracker()
        XCTAssertNil(tr.observe(obs("已有的一段内容"), at: t0))
    }

    /// 连续输入在停顿后作为**一段**吐出，且内容是真增量而非整值。
    func testTypingAccumulatesThenFlushesDelta() {
        let tr = TextInputTracker(idleThreshold: 2.5)
        XCTAssertNil(tr.observe(obs(""), at: t0))
        XCTAssertNil(tr.observe(obs("g"), at: t0.addingTimeInterval(0.2)))
        XCTAssertNil(tr.observe(obs("ga"), at: t0.addingTimeInterval(0.4)))
        XCTAssertNil(tr.observe(obs("gan"), at: t0.addingTimeInterval(0.6)))
        XCTAssertNil(tr.observe(obs("gan"), at: t0.addingTimeInterval(1.0)))
        let out = tr.observe(obs("gan"), at: t0.addingTimeInterval(3.5))
        XCTAssertEqual(out, "gan", "应吐出增量而非控件全值")
    }

    /// **在有既有内容的字段里追加**，也只应记新增部分。
    /// 这是旧实现（直接用控件全值）出错的核心场景。
    func testAppendInNonEmptyFieldRecordsOnlyDelta() {
        let tr = TextInputTracker(idleThreshold: 2.5)
        XCTAssertNil(tr.observe(obs("已有一大段内容"), at: t0))
        XCTAssertNil(tr.observe(obs("已有一大段内容你好"), at: t0.addingTimeInterval(0.3)))
        let out = tr.observe(obs("已有一大段内容你好"), at: t0.addingTimeInterval(3.2))
        XCTAssertEqual(out, "你好", "只应记新增的两个字")
    }

    /// 端到端形态：TextEdit 里输入 `你好, 测试, 测试, test, hello`，
    /// 采样序列按实测诊断日志构造（注意最后一次光标报告为 0，不可依赖）。
    func testRealTextEditSequence() {
        let tr = TextInputTracker(idleThreshold: 2.5)
        let seq: [(String, Int?)] = [
            ("", 0),
            ("你好, ", 4),
            ("你好, ce hi", 9),
            ("你好, 测试, ", 8),
            ("你好, 测试, 测试, ", 12),
            ("你好, 测试, 测试, test", 16),
            ("你好, 测试, 测试, test, ", 18),
            ("你好, 测试, 测试, test, hello", 0),   // 光标不可靠
        ]
        var out: [String] = []
        for (i, (v, c)) in seq.enumerated() {
            if let t = tr.observe(obs(v, c), at: t0.addingTimeInterval(Double(i) * 1.0)) {
                out.append(t)
            }
        }
        if let tail = tr.flush() { out.append(tail) }
        let joined = out.joined()
        XCTAssertTrue(joined.contains("你好"), "应含中文：\(out)")
        XCTAssertTrue(joined.contains("测试"), "应含重复词：\(out)")
        XCTAssertTrue(joined.contains("test"), "应含英文：\(out)")
        XCTAssertTrue(joined.contains("hello"), "应含末段（旧实现会漏掉）：\(out)")
    }

    /// 中文与拼音串原样通过（不做任何转换）。
    func testPinyinAndCJKPassThroughVerbatim() {
        let tr = TextInputTracker(idleThreshold: 2.5)
        XCTAssertNil(tr.observe(obs(""), at: t0))
        let s2 = "ganjue zhecankgu qishi meism xinyi"
        XCTAssertNil(tr.observe(obs(s2), at: t0.addingTimeInterval(0.3)))
        XCTAssertEqual(tr.flush(), s2)
    }

    /// 连续输入期间不应中途吐出，避免逐键刷屏。
    func testContinuousTypingDoesNotFlushEarly() {
        let tr = TextInputTracker(idleThreshold: 2.5)
        _ = tr.observe(obs(""), at: t0)
        var outs: [String] = []
        for i in 1...10 {
            let v = String(repeating: "a", count: i)
            if let o = tr.observe(obs(v), at: t0.addingTimeInterval(Double(i) * 0.3)) {
                outs.append(o)
            }
        }
        XCTAssertTrue(outs.isEmpty, "连续输入期间不应吐出：\(outs)")
    }

    /// 删除不产出文本。
    func testDeletionProducesNothing() {
        let tr = TextInputTracker(idleThreshold: 2.5)
        XCTAssertNil(tr.observe(obs("hello"), at: t0))
        XCTAssertNil(tr.observe(obs("hell"), at: t0.addingTimeInterval(0.3)),
                     "删除不应产出文本")
        XCTAssertNil(tr.flush(), "删除后不应有残留待吐内容")
    }

    /// 失焦时吐出已积累文本并重建基线；新控件既有内容不算输入。
    func testTargetLossFlushesAndRebaselines() {
        let tr = TextInputTracker(idleThreshold: 2.5)
        XCTAssertNil(tr.observe(obs(""), at: t0))
        XCTAssertNil(tr.observe(obs("abc"), at: t0.addingTimeInterval(0.2)))
        XCTAssertEqual(tr.observe(obs(nil), at: t0.addingTimeInterval(0.4)), "abc",
                       "失焦应吐出已积累文本")
        XCTAssertNil(tr.observe(obs("另一个控件里已有的内容"), at: t0.addingTimeInterval(0.6)),
                     "新目标应重新建立基线")
    }

    /// 显式 flush 用于停止采集等边界，保证不丢尾块。
    func testExplicitFlushEmitsRemainder() {
        let tr = TextInputTracker(idleThreshold: 2.5)
        XCTAssertNil(tr.observe(obs(""), at: t0))
        XCTAssertNil(tr.observe(obs("tail"), at: t0.addingTimeInterval(0.2)))
        XCTAssertEqual(tr.flush(), "tail")
        XCTAssertNil(tr.flush(), "重复 flush 不应重复产出")
    }

    /// 中间插入：只记插入的那一段。
    func testMidStringInsertionRecordsOnlyInsertedPart() {
        let tr = TextInputTracker(idleThreshold: 2.5)
        XCTAssertNil(tr.observe(obs("ac"), at: t0))
        XCTAssertNil(tr.observe(obs("abc"), at: t0.addingTimeInterval(0.3)))
        XCTAssertEqual(tr.flush(), "b")
    }

    /// 输入法上屏：拼音被汉字替换，已积累的拼音切块吐出，新值另起一块。
    func testIMECommitKeepsBothSides() {
        let tr = TextInputTracker(idleThreshold: 2.5)
        XCTAssertNil(tr.observe(obs(""), at: t0))
        XCTAssertNil(tr.observe(obs("ni"), at: t0.addingTimeInterval(0.2)))
        let out = tr.observe(obs("你"), at: t0.addingTimeInterval(0.4))
        XCTAssertEqual(out, "ni", "被替换的拼音应切块吐出")
        XCTAssertEqual(tr.flush(), "你", "上屏结果不应丢失")
    }

    // MARK: - 不可归因（终端）

    /// 终端：值是屏幕缓冲（含 NUL），差分无法证明新增内容来自键盘——
    /// 命令回显与命令输出都会让它变化。此处**不产出** text_input。
    func testTerminalBufferProducesNoTextInput() {
        let tr = TextInputTracker(idleThreshold: 2.5)
        XCTAssertNil(tr.observe(.init(value: "Last login: Mon\n$ ", caret: 26,
                                      isEditableBuffer: true), at: t0))
        // 切到终端缓冲
        XCTAssertNil(tr.observe(.init(value: "Last login: Mon\n$ whoami\u{0}\u{0}",
                                      caret: 30, isEditableBuffer: false),
                                at: t0.addingTimeInterval(0.3)))
        // 命令输出追加——不得被记为输入
        XCTAssertNil(tr.observe(.init(value: "Last login: Mon\n$ whoami\u{0}\u{0}\nexample-user\n$ ",
                                      caret: 45, isEditableBuffer: false),
                                at: t0.addingTimeInterval(0.6)))
        XCTAssertNil(tr.flush(), "终端缓冲不应产出任何输入")
    }

    /// 含 NUL 的值不是编辑缓冲。
    func testEditableBufferDetection() {
        XCTAssertTrue(AXTreeReader.isEditableBuffer("hello world"))
        XCTAssertTrue(AXTreeReader.isEditableBuffer("你好, 测试"))
        XCTAssertFalse(AXTreeReader.isEditableBuffer("cmd\u{0}\u{0}"))
    }

    // MARK: - 同一应用内切换控件

    /// 两个**已有内容**的输入框来回切换，不得把对方内容记成输入。
    ///
    /// 只看前台应用不足以发现这种切换——bundleID 未变。
    func testSwitchingFieldsWithinSameAppDoesNotRecordContent() {
        let tr = TextInputTracker(idleThreshold: 2.5)
        // 控件 A，已有 hello
        XCTAssertNil(tr.observe(.init(value: "hello", caret: 5,
                                      isEditableBuffer: true, focusIdentity: 100), at: t0))
        // 切到控件 B，已有 world —— 不得记成输入了 world
        XCTAssertNil(tr.observe(.init(value: "world", caret: 5,
                                      isEditableBuffer: true, focusIdentity: 200),
                                at: t0.addingTimeInterval(0.3)))
        XCTAssertNil(tr.flush(), "切换控件不应产出输入")

        // 在 B 里真正追加才记
        XCTAssertNil(tr.observe(.init(value: "world!", caret: 6,
                                      isEditableBuffer: true, focusIdentity: 200),
                                at: t0.addingTimeInterval(0.6)))
        XCTAssertEqual(tr.flush(), "!")
    }

    /// 切换控件时，前一个控件未 flush 的内容要先落盘并归属正确。
    func testFieldSwitchFlushesPendingFromPreviousField() {
        let tr = TextInputTracker(idleThreshold: 2.5)
        XCTAssertNil(tr.observe(.init(value: "", caret: 0,
                                      isEditableBuffer: true, focusIdentity: 100), at: t0))
        XCTAssertNil(tr.observe(.init(value: "typed-in-A", caret: 10,
                                      isEditableBuffer: true, focusIdentity: 100),
                                at: t0.addingTimeInterval(0.2)))
        let out = tr.observe(.init(value: "other", caret: 5,
                                   isEditableBuffer: true, focusIdentity: 200),
                             at: t0.addingTimeInterval(0.4))
        XCTAssertEqual(out, "typed-in-A", "切换前应吐出 A 中未落盘的内容")
    }

    // MARK: - 程序化改写 / 中断（负例）

    /// 程序自动追加文字不应被记为输入。
    ///
    /// 与"用户输入"在值层面同形，无法区分；本实现按当前策略处理，
    /// 此测试锁定**已知行为**而非正确性——记录该缺口以免误以为已解决。
    func testProgrammaticAppendIsCurrentlyIndistinguishable() {
        let tr = TextInputTracker(idleThreshold: 2.5)
        XCTAssertNil(tr.observe(obs("起始"), at: t0))
        // 程序追加（非用户键入）——当前会被累积
        XCTAssertNil(tr.observe(obs("起始自动补全"), at: t0.addingTimeInterval(0.3)))
        let out = tr.flush()
        XCTAssertEqual(out, "自动补全",
                       "已知缺口：程序化追加与用户输入在值层面同形，当前无法区分")
    }

    /// 采样中断（读不到值）应吐出已积累内容并重建基线。
    func testSamplingInterruptionFlushesAndRebaselines() {
        let tr = TextInputTracker(idleThreshold: 2.5)
        XCTAssertNil(tr.observe(obs(""), at: t0))
        XCTAssertNil(tr.observe(obs("abc"), at: t0.addingTimeInterval(0.2)))
        XCTAssertEqual(tr.observe(obs(nil), at: t0.addingTimeInterval(0.4)), "abc")
        // 恢复后不得把恢复瞬间的内容算作输入
        XCTAssertNil(tr.observe(obs("完全不同的一屏内容"), at: t0.addingTimeInterval(0.6)))
    }

    /// 无障碍属性缺失（value 为 nil）时不得崩溃，也不得凭空产出。
    func testMissingAccessibilityValueProducesNothing() {
        let tr = TextInputTracker(idleThreshold: 2.5)
        for _ in 0..<5 {
            XCTAssertNil(tr.observe(.init(value: nil, caret: nil,
                                          isEditableBuffer: false, focusIdentity: nil), at: t0))
        }
        XCTAssertNil(tr.flush())
    }

    // MARK: - 清洗

    /// NUL 等控制字符应被去掉，但空格与换行必须原样保留。
    func testSanitizeRemovesOnlyControlCharacters() {
        XCTAssertEqual(TextInputTracker.sanitize("whoami\0\0\0"), "whoami")
        XCTAssertEqual(TextInputTracker.sanitize("a\u{01}b"), "ab")
        // 空格与换行是用户可能真的输入的，不得改动
        XCTAssertEqual(TextInputTracker.sanitize("算了, "), "算了, ")
        XCTAssertEqual(TextInputTracker.sanitize("a  b"), "a  b")
        XCTAssertEqual(TextInputTracker.sanitize("l1\nl2"), "l1\nl2")
    }

    // MARK: - 差异算法

    func testChangeClassification() {
        XCTAssertEqual(TextInputTracker.change(from: "ab", to: "abc"), .inserted("c"))
        XCTAssertEqual(TextInputTracker.change(from: "", to: "hi"), .inserted("hi"))
        XCTAssertEqual(TextInputTracker.change(from: "ac", to: "abc"), .inserted("b"))
        XCTAssertEqual(TextInputTracker.change(from: "abc", to: "ab"), .deleted)
        XCTAssertEqual(TextInputTracker.change(from: "abc", to: "xyz"), .replaced("xyz"))
        XCTAssertEqual(TextInputTracker.change(from: "ni", to: "你"), .replaced("你"))
        // 前后缀都要用上：只变中间一个字符
        XCTAssertEqual(TextInputTracker.change(from: "aXc", to: "aYc"), .replaced("Y"))
    }
}
