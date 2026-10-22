import Foundation
import XCTest
@testable import ComputerHistoryCore

/// 前端叙述层的测试：条目解析、时刻回填与缓存。
final class NarrativeTests: XCTestCase {

    private func tempRoot() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ch-narr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 造一份十分钟记忆。
    @discardableResult
    private func writeMemory(_ dir: URL, segmentID: String,
                             title: String, summary: String,
                             apps: [String] = []) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let text = """
        ---
        title: \(title)
        description: \(summary)
        applications: [\(apps.joined(separator: ", "))]
        ---

        ## Memory summary

        ### 本次活动
        细节内容。
        """
        let url = dir.appendingPathComponent(
            MemoryWriter.fileName(segmentID: segmentID))
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func entries(_ dir: URL) -> [MemoryIndex.Entry] {
        MemoryIndex.load(from: dir).entries.sorted { $0.startedAt < $1.startedAt }
    }

    func testSameWindowSourcesUseUniqueNumbersAndValidateCompleteClaims() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("memories")
        for suffix in ["", "_" + UUID().uuidString, "_" + UUID().uuidString] {
            try writeMemory(dir, segmentID: "2026-10-14T08-00-00Z" + suffix, title: suffix, summary: "Synthetic")
        }
        let sources = entries(dir)
        XCTAssertEqual(Set(sources.map { $0.timeLabel() }).count, 1)
        let merged = NarrativeGenerator.parseItems("## [S1,S2,S3] 合并\n完整摘要。", sources: sources)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.title, "合并")
        XCTAssertEqual(Set(merged.flatMap(\.sourceMemories)), Set(sources.map(\.id)))
        let split = NarrativeGenerator.parseItems("## [S3] 后段\n三。\n## [S1,S2] 前段\n一二。", sources: sources)
        XCTAssertEqual(split.map { $0.sourceMemories.count }, [1, 2])
        XCTAssertEqual(split.first?.sourceMemories, [sources[2].id])
        XCTAssertEqual(split.last?.sourceMemories, [sources[0].id, sources[1].id])
        for text in ["## [S1] 遗漏\n摘要", "## [S1,S2,S4] 不存在\n摘要",
                     "## [S1,S1,S2,S3] 重复\n摘要", "## [S1,S2] 一\n摘要\n## [S2,S3] 二\n摘要"] {
            XCTAssertTrue(NarrativeGenerator.parseItems(text, sources: sources).isEmpty, text)
        }
        let subset = NarrativeGenerator.parseItems("## [S2,S3] 本批\n摘要", sources: sources, claimed: Array(sources[1...]))
        XCTAssertEqual(subset.flatMap(\.sourceMemories), Array(sources[1...]).map(\.id))
    }

    func testSourceRevisionRefreshesOnlyAffectedItemsAndKeepsIdentity() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("memories")
        let first = try writeMemory(dir, segmentID: "2026-10-14T08-00-00Z", title: "OLD", summary: "old")
        try writeMemory(dir, segmentID: "2026-10-14T08-10-00Z", title: "UNCHANGED", summary: "same")
        let day = try XCTUnwrap(MemoryIndex.parse(fileURL: first)).dayLabel()
        let generator = NarrativeGenerator(rootDirectory: root, client: nil)
        _ = try generator.generate(day: day)
        let before = ActivityNarrative.load(root: root)
        try writeMemory(dir, segmentID: "2026-10-14T08-00-00Z", title: "CORRECTED", summary: "new")
        let outcome = try generator.generate(day: day)
        XCTAssertEqual(outcome.newItems, 1)
        let after = ActivityNarrative.load(root: root)
        XCTAssertTrue(after.items.contains { $0.title == "CORRECTED" })
        XCTAssertEqual(after.items.first { $0.title == "UNCHANGED" }, before.items.first { $0.title == "UNCHANGED" })
        XCTAssertEqual(after.items.first { $0.title == "CORRECTED" }?.id, before.items.first { $0.title == "OLD" }?.id)
        XCTAssertEqual(try generator.generate(day: day).newItems, 0)
    }

    func testRevisedMergedItemKeepsDeletionAndRestoreAcrossSplit() async throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("memories")
        let first = try writeMemory(dir, segmentID: "2026-10-14T08-00-00Z", title: "OLD", summary: "old")
        try writeMemory(dir, segmentID: "2026-10-14T08-10-00Z", title: "SECOND", summary: "same")
        let sources = entries(dir)
        let merged = ActivityNarrative.Item(id: "legacy-merged", timestamp: sources[0].startedAt,
            title: "Merged", summary: "Old result", apps: [], sourceMemories: sources.map(\.id))
        try ActivityNarrative(items: [merged]).save(root: root)
        let loader = TraySnapshotLoader()
        let before = await loader.load(root: root)
        let row = try XCTUnwrap(before.groups.flatMap(\.items).first)
        try TimelineDeletions.delete(row, root: root)
        try writeMemory(dir, segmentID: "2026-10-14T08-00-00Z", title: "CORRECTED", summary: "new")
        let day = try XCTUnwrap(MemoryIndex.parse(fileURL: first)).dayLabel()
        _ = try NarrativeGenerator(rootDirectory: root, client: nil).generate(day: day)
        let hidden = await loader.load(root: root)
        XCTAssertTrue(hidden.groups.isEmpty)
        try TimelineDeletions.restore(id: row.deletionID, root: root)
        let restored = await loader.load(root: root)
        XCTAssertEqual(restored.groups.flatMap(\.items).count, 2, "Restored snapshot must not duplicate its replacements")
        XCTAssertTrue(restored.groups.flatMap(\.items).contains { $0.title == "CORRECTED" })
        try TimelineDeletions.delete(row, root: root)
        try TimelineDeletions.purge(id: row.deletionID, root: root)
        let purged = await TraySnapshotLoader().load(root: root)
        XCTAssertTrue(purged.groups.isEmpty)
    }

    // MARK: - 解析

    /// 编号决定来源，输出顺序不会改变时间与应用归属。
    ///
    /// 这是关键性质：模型会合并同任务的段，按下标回填会得到与内容矛盾的时间。
    func testDeclaredTimeMapsBackToSource() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let memDir = root.appendingPathComponent("memories")
        try writeMemory(memDir, segmentID: "2026-10-14T08-00-00Z",
                        title: "A", summary: "a", apps: ["com.a"])
        try writeMemory(memDir, segmentID: "2026-10-14T08-10-00Z",
                        title: "B", summary: "b", apps: ["com.b"])
        let src = entries(memDir)

        // 声明各自的时刻，且**输出顺序与源顺序相反**——只有这样才检验得出
        // 是「按声明时刻溯源」还是「按下标回填」。
        let earlier = src[0].timeLabel()
        let later = src[1].timeLabel()
        let text = """
        ## [S2] 后发生的事
        第二段的摘要。

        ## [S1] 先发生的事
        第一段的摘要。
        """
        let items = NarrativeGenerator.parseItems(text, sources: src)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].timestamp, src[1].startedAt,
                       "应按声明时刻溯源（\(later) → 第二段）")
        XCTAssertEqual(items[0].apps, ["com.b"])
        XCTAssertEqual(items[1].timestamp, src[0].startedAt,
                       "应按声明时刻溯源（\(earlier) → 第一段）")
        XCTAssertEqual(items[1].apps, ["com.a"])
    }

    /// 缺少编号时不能猜测来源。
    func testMissingSourceNumberRejected() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let memDir = root.appendingPathComponent("memories")
        try writeMemory(memDir, segmentID: "2026-10-14T08-00-00Z", title: "A", summary: "a")
        let src = entries(memDir)
        let items = NarrativeGenerator.parseItems("## 没有时刻的标题\n摘要内容。", sources: src)
        XCTAssertTrue(items.isEmpty)
    }

    /// 展示时间不能代替来源编号。
    func testTimeWithoutSourceNumberRejected() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let memDir = root.appendingPathComponent("memories")
        try writeMemory(memDir, segmentID: "2026-10-14T08-00-00Z", title: "A", summary: "a")
        let src = entries(memDir)
        let items = NarrativeGenerator.parseItems("## 23:59 不存在这个时刻\n摘要。", sources: src)
        XCTAssertTrue(items.isEmpty)
    }

    /// 空摘要的条目被丢弃——只有标题没有内容对扫读没有价值。
    func testEmptySummaryDropped() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let memDir = root.appendingPathComponent("memories")
        try writeMemory(memDir, segmentID: "2026-10-14T08-00-00Z", title: "A", summary: "a")
        let src = entries(memDir)
        let items = NarrativeGenerator.parseItems("## [S1] 只有标题\n", sources: src)
        XCTAssertTrue(items.isEmpty)
    }

    // MARK: - 缓存

    /// 缓存往返：写入后读回一致。
    func testCacheRoundTrip() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let item = ActivityNarrative.Item(
            id: "abc", timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            title: "标题", summary: "摘要", apps: ["com.a"], sourceMemories: ["m.md"])
        let narrative = ActivityNarrative(generatedAt: Date(), items: [item])
        try narrative.save(root: root)

        let back = ActivityNarrative.load(root: root)
        XCTAssertEqual(back.items.count, 1)
        XCTAssertEqual(back.items[0].title, "标题")
        XCTAssertEqual(back.items[0].apps, ["com.a"])
    }

    /// 缓存缺失或损坏时返回空而不抛错——托盘应能正常显示其余部分。
    func testMissingOrCorruptCacheYieldsEmpty() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(ActivityNarrative.load(root: root).items.isEmpty)

        try "这不是 JSON".write(to: ActivityNarrative.fileURL(root: root),
                             atomically: true, encoding: .utf8)
        XCTAssertTrue(ActivityNarrative.load(root: root).items.isEmpty)
    }

    /// 按天分组，新的在前。
    func testGroupedByDay() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let items = [
            ActivityNarrative.Item(id: "1", timestamp: day, title: "早",
                                   summary: "s", apps: [], sourceMemories: []),
            ActivityNarrative.Item(id: "2", timestamp: day.addingTimeInterval(600),
                                   title: "晚", summary: "s", apps: [], sourceMemories: []),
        ]
        let groups = ActivityNarrative(generatedAt: day, items: items).groupedByDay()
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].items.map(\.title), ["晚", "早"])
    }

    // MARK: - 无模型回退

    /// 无模型时用记忆的标题与描述充当条目，不假装已归纳。
    func testFallbackWithoutModel() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let memDir = root.appendingPathComponent("memories")
        let url = try writeMemory(memDir, segmentID: "2026-10-14T08-00-00Z",
                                  title: "记忆标题", summary: "记忆描述",
                                  apps: ["com.a"])
        let day = try XCTUnwrap(MemoryIndex.parse(fileURL: url)).dayLabel()

        let gen = NarrativeGenerator(rootDirectory: root, client: nil)
        let outcome = try gen.generate(day: day, overwrite: true)
        XCTAssertFalse(outcome.usedModel)
        XCTAssertEqual(outcome.newItems, 1)
        XCTAssertEqual(outcome.totalItems, 1)

        let saved = ActivityNarrative.load(root: root)
        XCTAssertEqual(saved.items.first?.title, "记忆标题")
        XCTAssertEqual(saved.items.first?.summary, "记忆描述")
    }

    /// 增量：第二次生成只处理新增来源，无新增时零开销。
    ///
    /// 此前每轮重算全天，一轮两万余 tokens 且随当天累积越来越慢，
    /// 把生成周期撑长，记忆与叙述双双落后于采集。
    func testIncrementalSkipsAlreadyCoveredSources() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let memDir = root.appendingPathComponent("memories")
        let url = try writeMemory(memDir, segmentID: "2026-10-14T08-00-00Z",
                                  title: "记忆标题", summary: "记忆描述")
        let day = try XCTUnwrap(MemoryIndex.parse(fileURL: url)).dayLabel()
        let gen = NarrativeGenerator(rootDirectory: root, client: nil)

        let first = try gen.generate(day: day, overwrite: true)
        XCTAssertEqual(first.newItems, 1)

        // 无新增：不应再产出，且计入 newItems 为 0
        let second = try gen.generate(day: day)
        XCTAssertEqual(second.newItems, 0, "已覆盖的来源不应重复归纳")
        XCTAssertEqual(second.totalItems, 1, "总数仍应报告")
    }

    /// 没有源记忆的日期明确报错。
    func testNoSourcesThrows() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let gen = NarrativeGenerator(rootDirectory: root, client: nil)
        XCTAssertThrowsError(try gen.generate(day: "2026-01-01"))
    }
}
