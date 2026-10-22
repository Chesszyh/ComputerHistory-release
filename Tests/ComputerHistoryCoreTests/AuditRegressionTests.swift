import Foundation
import XCTest
@testable import ComputerHistoryCore

/// 针对终审报告所指出问题的反例测试。
///
/// 这些用例的共同点：**构造真实调用链与失败状态，而不是理想输入**。
/// 此前测试全绿却漏掉这些问题，正是因为只覆盖了理想路径。
final class AuditRegressionTests: XCTestCase {

    private func tempRoot() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ch-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 造一个已封口的段，首条事件在指定时刻。
    @discardableResult
    private func writeSegment(_ root: URL, id: String, firstEvent: Date,
                              eventCount: Int = 3) throws -> URL {
        let dir = root.appendingPathComponent("segments").appendingPathComponent(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var lines = ""
        for i in 0..<eventCount {
            let record = EventStreamRecord(
                id: i + 1, timestamp: firstEvent.addingTimeInterval(Double(i)),
                kind: .windowChanged,
                app: EventStreamApp(name: "A", bundleIdentifier: "com.a"),
                window: nil, mouse: nil, keyboard: nil, selection: nil, ax: nil)
            lines += String(decoding: try EventStreamJSON.makeEncoder().encode(record),
                            as: UTF8.self) + "\n"
        }
        try lines.write(to: dir.appendingPathComponent("events.jsonl"),
                        atomically: true, encoding: .utf8)
        try "{}".write(to: dir.appendingPathComponent("metadata.json"),
                       atomically: true, encoding: .utf8)
        return dir
    }

    /// 写一份记忆，可指定它引用的前一份。
    private func writeMemory(_ root: URL, segmentID: String, title: String,
                             previous: String? = nil) throws {
        let dir = root.appendingPathComponent("memories")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var text = """
        ---
        title: \(title)
        description: 描述
        applications: [com.a]
        ---

        ## Memory summary

        ### 本次活动
        内容。

        ## Citations

        - \(root.path)/segments/\(segmentID)/events.jsonl

        """
        if let previous { text += "- \(previous)\n" }
        try text.write(to: dir.appendingPathComponent(
            MemoryWriter.fileName(segmentID: segmentID)),
            atomically: true, encoding: .utf8)
    }

    private func memoryName(_ segmentID: String) -> String {
        MemoryWriter.fileName(segmentID: segmentID)
    }

    private func generator(_ root: URL) -> MemoryGenerator {
        MemoryGenerator(rootDirectory: root,
                        memoriesDirectory: root.appendingPathComponent("memories"))
    }

    func testRewritingOneSegmentUsesOnlyItsPredecessor() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let ids = ["2026-10-14T00-00-00Z", "2026-10-14T00-10-00Z", "2026-10-14T00-20-00Z"]
        for (index, id) in ids.enumerated() {
            try writeSegment(root, id: id, firstEvent: base.addingTimeInterval(Double(index) * 600))
        }
        let gen = generator(root)
        XCTAssertEqual(gen.generateMissing().count, 3)
        for (index, id) in ids.enumerated() {
            let previous = gen.previousMemoryPath(before: id)
            XCTAssertEqual(previous.map { URL(fileURLWithPath: $0).lastPathComponent },
                           index == 0 ? nil : memoryName(ids[index - 1]))
            _ = try gen.generate(segmentID: id, previousMemoryPath: previous, overwrite: true)
        }
        XCTAssertTrue(gen.validateChain().isEmpty)
        XCTAssertEqual(gen.generateMissing(overwrite: true).count, 3)
        XCTAssertTrue(gen.validateChain().isEmpty)
    }

    // MARK: - 链条时序

    /// **同一时间窗内重启产生的段必须按真实事件时间排序。**
    ///
    /// 目录名的 UUID 后缀字典序与事件先后无关。实测 `…_9716D8E3`（事件 08:05:41）
    /// 排在 `…_257A7455`（事件 08:09:19）之后；按目录名建链会引用未来记录。
    func testOrderingUsesEventTimeNotDirectoryName() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        // 目录名字典序：base < 257A < 2C79 < 9716，但事件顺序完全不同。
        try writeSegment(root, id: "2026-10-14T08-00-00Z", firstEvent: base)
        try writeSegment(root, id: "2026-10-14T08-00-00Z_9716D8E3-2A35-427B-BEC1-CCE8D4142D15",
                         firstEvent: base.addingTimeInterval(300))
        try writeSegment(root, id: "2026-10-14T08-00-00Z_2C7902E6-EE8F-44A2-8817-8238ED91EBA0",
                         firstEvent: base.addingTimeInterval(600))
        try writeSegment(root, id: "2026-10-14T08-00-00Z_257A7455-3878-4E51-BCF8-EC88560F94D3",
                         firstEvent: base.addingTimeInterval(900))

        let ordered = generator(root).orderedSegments()
        // 无 `_` 时取 "(基准)"，避免把整个 ID 误当后缀。
        let suffixes = ordered.map { order -> String in
            let parts = order.segmentID.split(separator: "_")
            return parts.count > 1 ? String(parts[1]) : "(基准)"
        }
        XCTAssertEqual(suffixes, ["(基准)", "9716D8E3-2A35-427B-BEC1-CCE8D4142D15",
                                  "2C7902E6-EE8F-44A2-8817-8238ED91EBA0",
                                  "257A7455-3878-4E51-BCF8-EC88560F94D3"],
                       "应按事件时间而非目录名排序")
    }

    /// 自引用、未来引用、成环都必须被检出。
    func testValidatorCatchesBrokenChains() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0..<3 {
            try writeSegment(root, id: "2026-10-14T0\(i)-00-00Z",
                             firstEvent: base.addingTimeInterval(Double(i) * 600))
        }
        let n0 = memoryName("2026-10-14T00-00-00Z")
        let n1 = memoryName("2026-10-14T01-00-00Z")
        let n2 = memoryName("2026-10-14T02-00-00Z")
        let memDir = root.appendingPathComponent("memories")

        // 自引用
        try writeMemory(root, segmentID: "2026-10-14T00-00-00Z", title: "A",
                        previous: memDir.appendingPathComponent(n0).path)
        XCTAssertTrue(generator(root).validateChain()
            .contains { $0.kind == .selfReference })

        // 未来引用：00:00 引用 02:00
        try writeMemory(root, segmentID: "2026-10-14T00-00-00Z", title: "A",
                        previous: memDir.appendingPathComponent(n2).path)
        XCTAssertTrue(generator(root).validateChain()
            .contains { $0.kind == .futureReference })

        // 成环：01:00 → 02:00 → 01:00
        try writeMemory(root, segmentID: "2026-10-14T00-00-00Z", title: "A")
        try writeMemory(root, segmentID: "2026-10-14T01-00-00Z", title: "B",
                        previous: memDir.appendingPathComponent(n2).path)
        try writeMemory(root, segmentID: "2026-10-14T02-00-00Z", title: "C",
                        previous: memDir.appendingPathComponent(n1).path)
        XCTAssertTrue(generator(root).validateChain()
            .contains { $0.kind == .cycle })
    }

    /// 时序正确的链条应通过校验。
    func testWellOrderedChainPasses() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0..<3 {
            try writeSegment(root, id: "2026-10-14T0\(i)-00-00Z",
                             firstEvent: base.addingTimeInterval(Double(i) * 600))
        }
        let memDir = root.appendingPathComponent("memories")
        try writeMemory(root, segmentID: "2026-10-14T00-00-00Z", title: "A")
        try writeMemory(root, segmentID: "2026-10-14T01-00-00Z", title: "B",
                        previous: memDir.appendingPathComponent(
                            memoryName("2026-10-14T00-00-00Z")).path)
        try writeMemory(root, segmentID: "2026-10-14T02-00-00Z", title: "C",
                        previous: memDir.appendingPathComponent(
                            memoryName("2026-10-14T01-00-00Z")).path)
        XCTAssertTrue(generator(root).validateChain().isEmpty)
    }

    // MARK: - 叙述来源

    /// 合并后的条目必须记录**完整**的来源集合，而不只是首段。
    func testMergedItemRecordsAllSources() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0..<4 {
            try writeSegment(root, id: "2026-10-14T0\(i)-00-00Z",
                             firstEvent: base.addingTimeInterval(Double(i) * 600))
        }
        let memDir = root.appendingPathComponent("memories")
        try FileManager.default.createDirectory(at: memDir, withIntermediateDirectories: true)
        var sources: [MemoryIndex.Entry] = []
        for i in 0..<4 {
            let id = "2026-10-14T0\(i)-00-00Z"
            try writeMemory(root, segmentID: id, title: "T\(i)")
            sources.append(try XCTUnwrap(MemoryIndex.parse(
                fileURL: memDir.appendingPathComponent(memoryName(id)))))
        }
        sources.sort { $0.startedAt < $1.startedAt }

        // 两条：第一条覆盖前 3 段，第二条覆盖最后 1 段
        let text = """
        ## [S1,S2,S3] 合并前三段
        摘要一。

        ## [S4] 第四段
        摘要二。
        """
        let items = NarrativeGenerator.parseItems(text, sources: sources)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].sourceMemories.count, 3, "合并条目应记录全部三段来源")
        XCTAssertEqual(items[1].sourceMemories.count, 1)
        // 来源并集应覆盖全部段
        let all = Set(items.flatMap(\.sourceMemories))
        XCTAssertEqual(all.count, 4)
    }

    /// 乱序输出时，覆盖范围不得让最后一条吞掉前面的来源。
    func testOutOfOrderOutputDoesNotSwallowSources() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0..<3 {
            try writeSegment(root, id: "2026-10-14T0\(i)-00-00Z",
                             firstEvent: base.addingTimeInterval(Double(i) * 600))
        }
        let memDir = root.appendingPathComponent("memories")
        try FileManager.default.createDirectory(at: memDir, withIntermediateDirectories: true)
        var sources: [MemoryIndex.Entry] = []
        for i in 0..<3 {
            let id = "2026-10-14T0\(i)-00-00Z"
            try writeMemory(root, segmentID: id, title: "T\(i)")
            sources.append(try XCTUnwrap(MemoryIndex.parse(
                fileURL: memDir.appendingPathComponent(memoryName(id)))))
        }
        sources.sort { $0.startedAt < $1.startedAt }

        // 逆序输出：先最晚，再最早，最后中间
        let text = """
        ## [S3] 第三段
        三。

        ## [S1] 第一段
        一。

        ## [S2] 第二段
        二。
        """
        let items = NarrativeGenerator.parseItems(text, sources: sources)
        let all = items.flatMap(\.sourceMemories)
        XCTAssertEqual(Set(all).count, 3, "三条来源都应被覆盖且不重复：\(all)")
        XCTAssertEqual(all.count, 3, "不得有来源被重复计入")
    }

    // MARK: - 六小时依赖

    /// 十分钟记忆未齐时不得生成六小时汇总——否则会永久缺段
    /// （写出后仅凭文件存在就跳过，新增来源也不会更新）。
    func testSixHourWaitsForDependencies() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        // 同一 6 小时桶内的两段
        try writeSegment(root, id: "2026-10-14T00-00-00Z", firstEvent: base)
        try writeSegment(root, id: "2026-10-14T00-10-00Z",
                         firstEvent: base.addingTimeInterval(600))
        let memDir = root.appendingPathComponent("memories")
        try FileManager.default.createDirectory(at: memDir, withIntermediateDirectories: true)
        // 只为其中一段写记忆
        try writeMemory(root, segmentID: "2026-10-14T00-00-00Z", title: "A")

        let gen = generator(root)
        // 桶按**段时间**（段 ID 解析出的对齐时刻）划分，不是事件时间。
        let segmentStart = try XCTUnwrap(
            SegmentClock.date(fromSegmentID: "2026-10-14T00-00-00Z"))
        let bucket = MemoryGenerator.sixHourBucket(for: segmentStart)
        XCTAssertThrowsError(try gen.generateSixHour(bucket: bucket)) { error in
            guard case MemoryGenerator.GenerateError.dependenciesMissing(_, let missing) = error
            else { return XCTFail("应报依赖缺失，实际 \(error)") }
            XCTAssertEqual(missing, ["2026-10-14T00-10-00Z"])
        }
    }

    // MARK: - 统计准确性

    /// 大文件也必须计入事件数——按大小跳过会静默漏计。
    func testLargeSegmentIsCounted() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("segments/2026-10-14T00-00-00Z")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 约 10 MiB，超过此前 8 MiB 的跳过阈值
        var line = String(repeating: "x", count: 900)
        line = #"{"id":1,"timestamp":"2026-10-14T00:00:00Z","kind":"window.changed","ax":{"mode":"fullTree","text":"\#(line)"}}"#
        var body = ""
        let targetBytes = 10 * 1024 * 1024
        while body.utf8.count < targetBytes { body += line + "\n" }
        try body.write(to: dir.appendingPathComponent("events.jsonl"),
                       atomically: true, encoding: .utf8)
        try "{}".write(to: dir.appendingPathComponent("metadata.json"),
                       atomically: true, encoding: .utf8)

        let status = CollectorStatus.read(root: root)
        let expected = body.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        XCTAssertEqual(status.data.eventCount, expected,
                       "大文件不得被跳过")
        XCTAssertFalse(status.data.eventCountIncomplete)
    }

    /// 待补写量按**集合差**计算，不拿两个总数相减。
    ///
    /// 同窗重启会产生多个段而记忆文件名基于基准 ID，口径不同会算错。
    func testPendingCountUsesSetDifference() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        try writeSegment(root, id: "2026-10-14T00-00-00Z", firstEvent: base)
        try writeSegment(root, id: "2026-10-14T00-00-00Z_AAAA1111-0000-0000-0000-000000000001",
                         firstEvent: base.addingTimeInterval(300))
        // 只为基准段写记忆
        try writeMemory(root, segmentID: "2026-10-14T00-00-00Z", title: "A")

        let status = CollectorStatus.read(root: root)
        XCTAssertEqual(status.data.sealedSegmentIDs.count, 2)
        XCTAssertEqual(status.memories.pendingSegments, 1,
                       "带后缀的段尚无记忆，应计为待补写")
    }

    /// 未封口的段不计入待补写——生成记忆会漏掉后续内容。
    func testUnsealedSegmentNotCountedAsPending() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let dir = try writeSegment(root, id: "2026-10-14T00-00-00Z",
                                   firstEvent: Date(timeIntervalSince1970: 1_800_000_000))
        try FileManager.default.removeItem(at: dir.appendingPathComponent("metadata.json"))
        let status = CollectorStatus.read(root: root)
        XCTAssertTrue(status.data.sealedSegmentIDs.isEmpty)
        XCTAssertEqual(status.memories.pendingSegments, 0)
    }

    // MARK: - 日志边界

    /// 运行期日志截断：原地保留尾部，不改变文件身份。
    func testLogBoundEnforcedInPlace() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("collector.log")
        var body = ""
        for i in 0..<5000 { body += "line \(i) padding padding padding\n" }
        try body.write(to: log, atomically: true, encoding: .utf8)
        let inode = try FileManager.default.attributesOfItem(atPath: log.path)[.systemFileNumber] as? Int

        let maxBytes = 4096
        XCTAssertTrue(CollectorSupervisor.enforceLogBound(at: log, maxBytes: maxBytes))
        let size = try FileManager.default.attributesOfItem(atPath: log.path)[.size] as? Int ?? 0
        XCTAssertLessThanOrEqual(size, maxBytes)
        // 原文件被截断而非替换：inode 不变，进程持有的描述符仍然有效。
        let inodeAfter = try FileManager.default.attributesOfItem(atPath: log.path)[.systemFileNumber] as? Int
        XCTAssertEqual(inode, inodeAfter, "应原地截断，不换文件")

        // 保留下来的必须是完整的行
        let text = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(text.hasSuffix("\n"), "尾部应是完整行")
        XCTAssertTrue(text.contains("line 4999"), "应保留最近的内容")
    }

    /// 未超限时不动作。
    func testLogBoundLeavesSmallLogsAlone() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("small.log")
        try "tiny\n".write(to: log, atomically: true, encoding: .utf8)
        XCTAssertFalse(CollectorSupervisor.enforceLogBound(at: log, maxBytes: 4096))
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "tiny\n")
    }
}
