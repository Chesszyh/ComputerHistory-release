import Foundation
import XCTest
@testable import ComputerHistoryCore

/// 记忆生成的测试：段摘要、文件格式与记忆链。
final class MemoryGenerationTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(_ offset: TimeInterval,
                        kind: EventStreamEventKind = .windowChanged,
                        bundle: String? = "com.example.app",
                        appName: String? = "示例应用",
                        title: String? = nil,
                        url: String? = nil,
                        text: String? = nil,
                        id: Int = 1) -> EventStreamRecord {
        EventStreamRecord(
            id: id,
            timestamp: t0.addingTimeInterval(offset),
            kind: kind,
            app: bundle.map { EventStreamApp(name: appName, bundleIdentifier: $0) },
            window: (title != nil || url != nil)
                ? EventStreamWindow(title: title, url: url) : nil,
            mouse: nil,
            keyboard: text.map { EventStreamKeyboardInteraction(text: $0) },
            selection: nil,
            ax: nil)
    }

    // MARK: - 段摘要

    /// 按应用聚合，事件数降序。
    func testDigestAggregatesByApplication() {
        let events = [
            record(0, bundle: "com.a", appName: "A", id: 1),
            record(1, bundle: "com.b", appName: "B", id: 2),
            record(2, bundle: "com.a", appName: "A", id: 3),
            record(3, bundle: "com.a", appName: "A", id: 4),
        ]
        let digest = SegmentDigest.make(events: events, segmentID: "seg")
        XCTAssertEqual(digest.activities.count, 2)
        XCTAssertEqual(digest.activities[0].bundleIdentifier, "com.a")
        XCTAssertEqual(digest.activities[0].eventCount, 3)
        XCTAssertEqual(digest.applications, ["com.a", "com.b"], "frontmatter 用字典序")
    }

    /// 点击、快捷键、输入分别归类。
    func testDigestCountsInteractionKinds() {
        let events = [
            record(0, kind: .mouseClick, id: 1),
            record(1, kind: .mouseClick, id: 2),
            record(2, kind: .mouseContextMenu, id: 3),
            record(3, kind: .keyboardShortcut, id: 4),
            record(4, kind: .keyboardTextInput, text: "你好", id: 5),
            record(5, kind: .keyboardTextInput, text: "world", id: 6),
        ]
        let digest = SegmentDigest.make(events: events, segmentID: "seg")
        let a = digest.activities[0]
        XCTAssertEqual(a.clickCount, 3, "右键菜单计入点击")
        XCTAssertEqual(a.shortcutCount, 1)
        XCTAssertEqual(a.typedTexts, ["你好", "world"])
    }

    /// 窗口标题与 URL 去重且保持出现顺序。
    func testDigestDeduplicatesTitlesAndURLs() {
        let events = [
            record(0, title: "T1", url: "https://a.test/", id: 1),
            record(1, title: "T2", url: "https://b.test/", id: 2),
            record(2, title: "T1", url: "https://a.test/", id: 3),
        ]
        let digest = SegmentDigest.make(events: events, segmentID: "seg")
        XCTAssertEqual(digest.activities[0].windowTitles, ["T1", "T2"])
        XCTAssertEqual(digest.activities[0].urls, ["https://a.test/", "https://b.test/"])
    }

    /// 无应用字段的事件被忽略，不产生空条目。
    func testDigestSkipsEventsWithoutApplication() {
        let events = [record(0, bundle: nil, appName: nil, id: 1)]
        let digest = SegmentDigest.make(events: events, segmentID: "seg")
        XCTAssertTrue(digest.activities.isEmpty)
    }

    // MARK: - 文件格式

    /// 文件名沿用官方形状，且同一段稳定可重复。
    func testFileNameIsStableAndOfficialShaped() {
        let id = "2026-10-11T17-20-00Z"
        let name = MemoryWriter.fileName(segmentID: id)
        XCTAssertEqual(name, MemoryWriter.fileName(segmentID: id), "同段应稳定")
        XCTAssertTrue(name.hasPrefix(id + "-"), "应以段时间开头：\(name)")
        XCTAssertTrue(name.hasSuffix("-10min-memory-summary.md"), "实际：\(name)")
        // 4 位码
        let code = name.dropFirst(id.count + 1).prefix(4)
        XCTAssertEqual(code.count, 4)
        XCTAssertTrue(code.allSatisfy(\.isLetter))
    }

    /// 带 UUID 后缀的段与基础段应得到不同文件名，避免互相覆盖。
    func testSuffixedSegmentGetsDistinctFile() {
        let base = MemoryWriter.fileName(segmentID: "2026-10-13T04-00-00Z")
        let suffixed = MemoryWriter.fileName(
            segmentID: "2026-10-13T04-00-00Z_4D08EBD2-0DF4-4253-9879-A2BCDC790737")
        XCTAssertNotEqual(base, suffixed)
        // 两者都以同一时间戳开头——与官方命名一致
        XCTAssertTrue(suffixed.hasPrefix("2026-10-13T04-00-00Z-"))
    }

    /// frontmatter 三字段齐全，applications 为字典序数组。
    func testFrontmatterShape() {
        let digest = SegmentDigest.make(
            events: [record(0, bundle: "com.b", appName: "乙", id: 1),
                     record(1, bundle: "com.a", appName: "甲", id: 2)],
            segmentID: "seg")
        let md = MemoryWriter.render(digest: digest, eventsPath: "/tmp/events.jsonl")
        XCTAssertTrue(md.hasPrefix("---\n"))
        XCTAssertTrue(md.contains("\napplications: [com.a, com.b]\n"))
        XCTAssertTrue(md.contains("## Memory summary"))
        XCTAssertTrue(md.contains("## Recording summary"))
        XCTAssertTrue(md.contains("## Citations"))
    }

    /// 标题不应重复应用名——窗口标题常自带 `… - 应用名`。
    func testTitleDoesNotRepeatApplicationName() {
        let events = [record(0, appName: "Google Chrome",
                             title: "某页面 - Google Chrome", id: 1)]
        let digest = SegmentDigest.make(events: events, segmentID: "seg")
        XCTAssertEqual(MemoryWriter.title(for: digest), "Google Chrome：某页面")
    }

    /// 窗口标题去掉应用名后为空时，只用应用名。
    func testTitleFallsBackWhenWindowEqualsAppName() {
        let events = [record(0, appName: "访达", title: " - 访达", id: 1)]
        let digest = SegmentDigest.make(events: events, segmentID: "seg")
        XCTAssertEqual(MemoryWriter.title(for: digest), "访达")
    }

    /// 窗口标题恰好等于应用名时不应产生「ChatGPT：ChatGPT」。
    func testTitleNotDuplicatedWhenWindowEqualsAppName() {
        let events = [record(0, appName: "ChatGPT", title: "ChatGPT", id: 1)]
        let digest = SegmentDigest.make(events: events, segmentID: "seg")
        XCTAssertEqual(MemoryWriter.title(for: digest), "ChatGPT")
    }

    /// Citations 引用事件文件；有前一份记忆时一并引用，形成链。
    func testCitationsChain() {
        let digest = SegmentDigest.make(events: [record(0, id: 1)], segmentID: "seg")
        let solo = MemoryWriter.render(digest: digest, eventsPath: "/tmp/e.jsonl")
        XCTAssertTrue(solo.contains("- /tmp/e.jsonl"))
        XCTAssertFalse(solo.contains("prev.md"))

        let chained = MemoryWriter.render(digest: digest, eventsPath: "/tmp/e.jsonl",
                                          previousMemoryPath: "/tmp/prev.md")
        XCTAssertTrue(chained.contains("- /tmp/e.jsonl"))
        XCTAssertTrue(chained.contains("- /tmp/prev.md"))
    }

    /// 无模型时写明本节未经模型归纳，不假装已归纳。
    func testFactOnlyModeIsLabelled() {
        let digest = SegmentDigest.make(events: [record(0, id: 1)], segmentID: "seg")
        let md = MemoryWriter.render(digest: digest, eventsPath: "/tmp/e.jsonl")
        XCTAssertTrue(md.contains("不作特征归纳"))

        let withNote = MemoryWriter.render(digest: digest, eventsPath: "/tmp/e.jsonl",
                                           modelNote: "接口超时")
        XCTAssertTrue(withNote.contains("接口超时"))
    }

    /// 模型补写时不再由本地补 Relevant prior context，避免出现两个同名小节。
    func testEnrichmentDoesNotDuplicateSections() {
        let digest = SegmentDigest.make(events: [record(0, id: 1)], segmentID: "seg")
        let enrichment = "### Relevant prior context\n无此前记录。\n\n### 本次活动\n测试。"
        let md = MemoryWriter.render(digest: digest, eventsPath: "/tmp/e.jsonl",
                                     previousMemoryPath: "/tmp/prev.md",
                                     enrichment: enrichment)
        let count = md.components(separatedBy: "### Relevant prior context").count - 1
        XCTAssertEqual(count, 1, "应只有模型产出的那一个小节")
    }

    /// 反引号会破坏 Markdown 行内代码，需转义。
    func testEscapeStripsBackticks() {
        XCTAssertEqual(MemoryWriter.escape("a`b`c"), "a'b'c")
    }

    // MARK: - 生成器

    /// 未封口的段（缺 metadata.json）不参与生成。
    func testOnlySealedSegmentsAreGenerated() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ch-gen-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let segRoot = root.appendingPathComponent("segments")
        for id in ["2026-10-11T10-00-00Z", "2026-10-11T10-10-00Z"] {
            try FileManager.default.createDirectory(
                at: segRoot.appendingPathComponent(id), withIntermediateDirectories: true)
        }
        // 只给第一个封口
        try "{}".write(to: segRoot.appendingPathComponent("2026-10-11T10-00-00Z/metadata.json"),
                       atomically: true, encoding: .utf8)

        let gen = MemoryGenerator(rootDirectory: root,
                                  memoriesDirectory: root.appendingPathComponent("memories"))
        XCTAssertEqual(gen.completedSegmentIDs(), ["2026-10-11T10-00-00Z"])
    }

    /// 空段不生成记忆，也不算失败。
    func testEmptySegmentIsSkipped() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ch-empty-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("segments/2026-10-11T10-00-00Z")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "{}".write(to: dir.appendingPathComponent("metadata.json"),
                       atomically: true, encoding: .utf8)
        try "".write(to: dir.appendingPathComponent("events.jsonl"),
                     atomically: true, encoding: .utf8)

        let gen = MemoryGenerator(rootDirectory: root,
                                  memoriesDirectory: root.appendingPathComponent("memories"))
        XCTAssertThrowsError(try gen.generate(segmentID: "2026-10-11T10-00-00Z"))
        XCTAssertTrue(gen.generateMissing().isEmpty)
    }

    /// 已有记忆默认不重写，避免重复消耗用量。
    func testExistingMemoryIsNotRegenerated() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ch-skip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("segments/2026-10-11T10-00-00Z")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "{}".write(to: dir.appendingPathComponent("metadata.json"),
                       atomically: true, encoding: .utf8)
        let json = try EventStreamJSON.makeEncoder().encode(record(0, id: 1))
        try (String(decoding: json, as: UTF8.self) + "\n")
            .write(to: dir.appendingPathComponent("events.jsonl"),
                   atomically: true, encoding: .utf8)

        let memories = root.appendingPathComponent("memories")
        let gen = MemoryGenerator(rootDirectory: root, memoriesDirectory: memories)
        let first = try gen.generate(segmentID: "2026-10-11T10-00-00Z")
        let second = try gen.generate(segmentID: "2026-10-11T10-00-00Z")
        XCTAssertEqual(first.memoryURL, second.memoryURL)
        XCTAssertFalse(second.usedModel)
        XCTAssertTrue(gen.generateMissing().isEmpty, "已生成的不应重复生成")
    }

    /// 缺少密钥时明确报错，不静默降级。
    func testClientRequiresAPIKey() {
        XCTAssertThrowsError(try DeepSeekClient.fromEnvironment([:]))
        XCTAssertNoThrow(try DeepSeekClient.fromEnvironment(["DEEPSEEK_API_KEY": "k"]))
    }
}

/// 六小时汇总的测试。
final class SixHourSummaryTests: XCTestCase {

    /// 6 小时桶对齐到 00/06/12/18 时。
    func testBucketAlignment() {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.locale = Locale(identifier: "en_US_POSIX")

        func bucket(_ s: String) -> String {
            let d = f.date(from: s)!
            return f.string(from: MemoryGenerator.sixHourBucket(for: d))
        }
        XCTAssertEqual(bucket("2026-10-06 00:00"), "2026-10-06 00:00")
        XCTAssertEqual(bucket("2026-10-06 05:59"), "2026-10-06 00:00")
        XCTAssertEqual(bucket("2026-10-06 06:00"), "2026-10-06 06:00")
        XCTAssertEqual(bucket("2026-10-06 11:59"), "2026-10-06 06:00")
        XCTAssertEqual(bucket("2026-10-06 12:00"), "2026-10-06 12:00")
        XCTAssertEqual(bucket("2026-10-06 23:59"), "2026-10-06 18:00")
    }

    /// 6 小时文件名用 6h 粒度后缀与对齐后的时间。
    func testSixHourFileName() {
        let name = MemoryWriter.fileName(segmentID: "2026-10-06T12-00-00Z",
                                         granularity: "6h")
        XCTAssertTrue(name.hasPrefix("2026-10-06T12-00-00Z-"))
        XCTAssertTrue(name.hasSuffix("-6h-memory-summary.md"), name)
    }

    /// 模型给出的标题应替换掉由主导应用推导的标题。
    func testTitleOverrideWins() {
        let digest = SegmentDigest.make(
            events: [EventStreamRecord(
                id: 1, timestamp: Date(timeIntervalSince1970: 1_800_000_000),
                kind: .windowChanged,
                app: EventStreamApp(name: "QQ", bundleIdentifier: "com.tencent.qq"),
                window: EventStreamWindow(title: "QQ"), mouse: nil,
                keyboard: nil, selection: nil, ax: nil)],
            segmentID: "seg")
        let md = MemoryWriter.render(digest: digest, eventsPath: "/tmp/e.jsonl",
                                     granularity: "6h",
                                     titleOverride: "逆向 Computer History 分析")
        XCTAssertTrue(md.contains("title: 逆向 Computer History 分析"))
        XCTAssertFalse(md.contains("title: QQ"))
    }

    /// 6h 描述不能说成「本段约 N 分钟」——桶内通常只有部分时间有活动。
    func testSixHourDescriptionMentionsRecordedSpan() {
        let digest = SegmentDigest.make(
            events: [EventStreamRecord(
                id: 1, timestamp: Date(timeIntervalSince1970: 1_800_000_000),
                kind: .windowChanged,
                app: EventStreamApp(name: "A", bundleIdentifier: "com.a"),
                window: nil, mouse: nil, keyboard: nil, selection: nil, ax: nil)],
            segmentID: "seg")
        let md = MemoryWriter.render(digest: digest, eventsPath: "/tmp/e.jsonl",
                                     granularity: "6h")
        XCTAssertTrue(md.contains("六小时时段内共"), md)
        XCTAssertTrue(md.contains("首末事件跨度"), md)
        XCTAssertFalse(md.contains("本段约"))
    }

    /// 模型输出里的 TITLE 行被切出，正文不含该行。
    func testSplitTitle() {
        let (t1, b1) = MemoryGenerator.splitTitle("TITLE: 主题\n\n### 整体走向\n内容")
        XCTAssertEqual(t1, "主题")
        XCTAssertEqual(b1, "### 整体走向\n内容")

        // 无 TITLE 行时原样返回，由调用方回退
        let (t2, b2) = MemoryGenerator.splitTitle("### 整体走向\n内容")
        XCTAssertNil(t2)
        XCTAssertEqual(b2, "### 整体走向\n内容")

        // 空标题视作缺失
        let (t3, _) = MemoryGenerator.splitTitle("TITLE:   \n正文")
        XCTAssertNil(t3)
    }

    /// 合并摘要：同类活动相加，窗口标题与 URL 去重保序。
    func testDigestMerging() {
        func make(_ seg: String, bundle: String, title: String,
                  clicks: Int, text: String?) -> SegmentDigest {
            var events: [EventStreamRecord] = []
            for i in 0..<clicks {
                events.append(EventStreamRecord(
                    id: i + 1,
                    timestamp: Date(timeIntervalSince1970: 1_800_000_000 + Double(i)),
                    kind: .mouseClick,
                    app: EventStreamApp(name: bundle, bundleIdentifier: bundle),
                    window: EventStreamWindow(title: title), mouse: nil,
                    keyboard: nil, selection: nil, ax: nil))
            }
            if let text {
                events.append(EventStreamRecord(
                    id: 99, timestamp: Date(timeIntervalSince1970: 1_800_000_100),
                    kind: .keyboardTextInput,
                    app: EventStreamApp(name: bundle, bundleIdentifier: bundle),
                    window: EventStreamWindow(title: title), mouse: nil,
                    keyboard: EventStreamKeyboardInteraction(text: text),
                    selection: nil, ax: nil))
            }
            return SegmentDigest.make(events: events, segmentID: seg)
        }
        let a = make("s1", bundle: "com.a", title: "T1", clicks: 2, text: "hi")
        let b = make("s2", bundle: "com.a", title: "T2", clicks: 3, text: "yo")
        let c = make("s3", bundle: "com.b", title: "T1", clicks: 1, text: nil)

        let merged = SegmentDigest.merging([a, b, c], bucketID: "bucket")
        XCTAssertEqual(merged.eventCount, a.eventCount + b.eventCount + c.eventCount)
        XCTAssertEqual(merged.activities.count, 2)
        let top = merged.activities[0]
        XCTAssertEqual(top.bundleIdentifier, "com.a", "事件多者在前")
        XCTAssertEqual(top.clickCount, 5, "点击应相加")
        XCTAssertEqual(top.typedTexts, ["hi", "yo"])
        XCTAssertEqual(top.windowTitles, ["T1", "T2"], "去重且保序")
    }
}
