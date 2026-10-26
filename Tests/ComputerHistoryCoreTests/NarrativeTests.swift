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

    func testAwayBoundarySeparatesSameBucketRestartsAndClipsLegacyBucketTimes() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("memories")
        try writeMemory(dir, segmentID: "2026-10-14T08-00-00Z", title: "Before", summary: "Before")
        try writeMemory(dir, segmentID: "2026-10-14T08-00-00Z_" + UUID().uuidString, title: "After", summary: "After")
        var sources = entries(dir).sorted { $0.title < $1.title }
        let bucket = sources[0].startedAt
        sources[0].firstEventAt = bucket.addingTimeInterval(360) // After
        sources[1].firstEventAt = bucket.addingTimeInterval(60) // Before
        var away = AwayPeriods()
        away.periods = [.init(start: bucket.addingTimeInterval(180), end: bucket.addingTimeInterval(360))]
        XCTAssertEqual(away.activityGroups(sources).map { $0.map(\.title) }, [["Before"], ["After"]])
        sources[0].firstEventAt = nil
        XCTAssertEqual(away.activityStart(for: sources[0]), bucket)
        away.periods[0].start = bucket.addingTimeInterval(-120)
        XCTAssertEqual(away.activityStart(for: sources[0]), bucket.addingTimeInterval(360))
        away.periods = [.init(start: bucket.addingTimeInterval(-120), end: bucket.addingTimeInterval(60 * 60))]
        XCTAssertEqual(away.activityStart(for: sources[0]), bucket, "A fully absent bucket cannot be relabeled as an event an hour later")
    }

    func testContinuationRetainsSourcesAndRejectsInvalidPriorClaims() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("memories")
        try writeMemory(dir, segmentID: "2026-10-14T08-20-00Z", title: "Task", summary: "New detail", apps: ["example.editor"])
        let sources = entries(dir)
        let prior = ActivityNarrative.Item(id: "prior", timestamp: sources[0].startedAt.addingTimeInterval(-1200),
            title: "Task", summary: "Previous detail", apps: ["example.browser"], sourceMemories: ["first.md", "second.md"])
        let merged = NarrativeGenerator.parseItems("## [P1,S1] Continued task\nPrevious detail and new detail.", sources: sources, priorItems: [prior])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.sourceMemories, ["first.md", "second.md", sources[0].id])
        XCTAssertEqual(merged.first?.timestamp, prior.timestamp)
        XCTAssertEqual(merged.first?.apps, ["example.browser", "example.editor"])
        for text in ["## [P1] Missing new source\nDetail", "## [P2,S1] Unknown prior\nDetail",
                     "## [P1,P1,S1] Duplicate prior\nDetail", "## [P01,S1] Invalid number\nDetail"] {
            XCTAssertTrue(NarrativeGenerator.parseItems(text, sources: sources, priorItems: [prior]).isEmpty, text)
        }
        XCTAssertEqual(NarrativeGenerator.parseItems("## [S1] Separate task\nDifferent theme.", sources: sources, priorItems: [prior]).count, 1)
    }

    func testTaskReturnCannotBridgeAnInterveningTask() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("memories")
        for minute in [0, 10, 20] {
            try writeMemory(dir, segmentID: "2026-10-14T08-\(String(format: "%02d", minute))-00Z", title: "Task", summary: "Synthetic action")
        }
        let sources = entries(dir)
        let interleaved = "## [S1,S3] Return to A\nTask A.\n## [S2] Switch to B\nTask B."
        XCTAssertTrue(NarrativeGenerator.parseItems(interleaved, sources: sources).isEmpty)
        let prior = ActivityNarrative.Item(id: "previous", timestamp: sources[0].startedAt.addingTimeInterval(-600),
            title: "Task A", summary: "Earlier A", apps: [], sourceMemories: ["previous.md"])
        XCTAssertTrue(NarrativeGenerator.parseItems("## [S1] Task B\nSwitch.\n## [P1,S2,S3] Return A\nResume.",
            sources: sources, priorItems: [prior]).isEmpty)
        let linear = NarrativeGenerator.parseItems("## [P1,S1] A\nFirst.\n## [S2] B\nSecond.\n## [S3] Return to A\nThird.", sources: sources, priorItems: [prior])
        XCTAssertEqual(linear.count, 3)
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
        let row = try XCTUnwrap(before.groups.flatMap(\.items).flatMap(\.leafItems).first)
        try TimelineDeletions.delete(row, root: root)
        try writeMemory(dir, segmentID: "2026-10-14T08-00-00Z", title: "CORRECTED", summary: "new")
        let day = try XCTUnwrap(MemoryIndex.parse(fileURL: first)).dayLabel()
        _ = try NarrativeGenerator(rootDirectory: root, client: nil).generate(day: day)
        let hidden = await loader.load(root: root)
        XCTAssertTrue(hidden.groups.isEmpty)
        try TimelineDeletions.restore(id: row.deletionID, root: root)
        let restored = await loader.load(root: root)
        XCTAssertEqual(restored.groups.flatMap(\.items).flatMap(\.leafItems).count, 2, "Restored snapshot must not duplicate its replacements")
        XCTAssertTrue(restored.groups.flatMap(\.items).flatMap(\.leafItems).contains { $0.title == "CORRECTED" })
        try TimelineDeletions.delete(row, root: root)
        try TimelineDeletions.purge(id: row.deletionID, root: root)
        let purged = await TraySnapshotLoader().load(root: root)
        XCTAssertTrue(purged.groups.isEmpty)
    }

    // MARK: - 解析

    func testTaskStepsAndBriefAsidesShareOneCardWithoutLosingAnIndependentTask() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("memories")
        let file = try writeMemory(dir, segmentID: "2026-10-14T08-00-00Z", title: "Window", summary: "Counts")
        let body = "- **迁移项目**：核对目标目录。\n- **压缩初测**：确认压缩结果。\n- **查看天气**：短暂查看天气页面。\n- **补充迁移要求**：保留提交历史。\n- **阅读论文**：讨论独立的研究问题。"
        try String(contentsOf: file, encoding: .utf8).replacingOccurrences(of: "细节内容。", with: body)
            .write(to: file, atomically: true, encoding: .utf8)
        let source = entries(dir)
        let result = NarrativeGenerator.parseItems("## [S1.A1,+S1.A2,~S1.A3,+S1.A4] 迁移项目\n核对目录与压缩结果。\n## [S1.A5] 阅读论文\n讨论研究问题。", sources: source)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.first?.sourceActivities?[source[0].id], [1, 2, 3, 4])
        XCTAssertEqual(result.first?.sourceSteps?[source[0].id], [2, 4])
        XCTAssertEqual(result.first?.sourceIncidental?[source[0].id], [3])
        let main = ActivityFragment.details(files: [file], activities: result.first?.sourceActivities, excluding: result.first?.sourceIncidental)
        XCTAssertTrue(main[0].text.contains("压缩结果"))
        XCTAssertFalse(main[0].text.contains("天气"))
        let aside = ActivityFragment.details(files: [file], activities: result.first?.sourceIncidental)
        XCTAssertTrue(aside[0].text.contains("天气"))
        XCTAssertFalse(aside[0].text.contains("提交历史"))
        for invalid in [
            "## [S1.A1,+S1.A2,+S1.A4] 遗漏穿插\n概览。\n## [S1.A5] 论文\n概览。",
            "## [+S1.A1,+S1.A2,~S1.A3,+S1.A4] 没有主任务的步骤\n概览。\n## [S1.A5] 论文\n概览。",
            "## [S1.A1,+S1.A2,~S1.A3,+S1.A4] 任务\n概览。\n## [~S1.A3,S1.A5] 重复穿插\n概览。"
        ] { XCTAssertTrue(NarrativeGenerator.parseItems(invalid, sources: source).isEmpty) }
        let asides = NarrativeGenerator.parseItems("## [~S1.A1,~S1.A2,~S1.A3,~S1.A4,~S1.A5] 期间的其他活动", sources: source)
        XCTAssertEqual(asides.count, 1)
        XCTAssertTrue(asides[0].isIncidentalOnly)
        XCTAssertTrue(asides[0].summary.contains("天气"))
        XCTAssertTrue(NarrativeGenerator.parseItems("## [P1,+S1.A1,+S1.A2,~S1.A3,+S1.A4,+S1.A5] 无主任务\n概览。", sources: source, priorItems: asides).isEmpty)
        try ActivityNarrative(items: result).save(root: root)
        XCTAssertEqual(ActivityNarrative.load(root: root).items, result)
        let fixed = ActivityNarrative(items: result).separatingAwayPeriods(index: .init(entries: source), away: AwayPeriods(), mode: .fixedTenMinutes)
        XCTAssertEqual(fixed.items.count, 1)
        XCTAssertNil(fixed.items[0].sourceIncidental)
    }

    func testActivitiesInOneMemoryCanBelongToSeparateItems() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("memories")
        let url = try writeMemory(dir, segmentID: "2026-10-14T08-00-00Z", title: "Window", summary: "Counts")
        let text = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "细节内容。", with: "- **审阅文档。**：核对文档中的边界条件。\n- **迁移示例项目**：保留提交历史并核对目录。")
        try text.write(to: url, atomically: true, encoding: .utf8)
        let source = entries(dir)
        let result = NarrativeGenerator.parseItems("## [S1.A1] 审阅文档。\n核对边界。\n## [S1.A2] 迁移示例项目\n核对目录。", sources: source)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.first?.title, "审阅文档")
        XCTAssertEqual(result.map(\.sourceMemories), [[source[0].id], [source[0].id]])
        XCTAssertEqual(Set(result.map(\.id)).count, 2)
        XCTAssertTrue(NarrativeGenerator.parseItems("## [S1.A1] 遗漏任务\n只提文档。", sources: source).isEmpty)
        XCTAssertTrue(NarrativeGenerator.parseItems("## [S1.A1,S1.A2] 混合任务\n压成一条。", sources: source).isEmpty)
        XCTAssertTrue(NarrativeGenerator.parseItems("## [S1] 混合任务\n压成一条。", sources: source).isEmpty)
        XCTAssertTrue(NarrativeGenerator.parseItems("## [S1.A1] 文档\n核对文档。\n## [S1.A2] 项目\n核对目录。", sources: source, mode: .fixedTenMinutes).isEmpty)
        let detail = ActivityFragment.details(files: [url], activities: result.first?.sourceActivities)
        XCTAssertTrue(detail.first?.text.contains("边界条件") == true)
        XCTAssertFalse(detail.first?.text.contains("提交历史") == true)
        let fixed = ActivityNarrative(items: result).separatingAwayPeriods(index: .init(entries: source), away: AwayPeriods(), mode: .fixedTenMinutes)
        XCTAssertEqual(fixed.items.count, 1)
        XCTAssertTrue(fixed.items[0].summary.contains("边界条件"))
        XCTAssertTrue(fixed.items[0].summary.contains("提交历史"))
    }

    func testBriefActivityKeepsItsSpecificTitleAndSummary() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("memories")
        try writeMemory(dir, segmentID: "2026-10-14T08-00-00Z", title: "Window", summary: "Counts")
        let result = NarrativeGenerator.parseItems("## [~S1.A1] 核查预约人数\n你查看预约页面的剩余名额。", sources: entries(dir))
        XCTAssertEqual(result.first?.title, "核查预约人数")
        XCTAssertEqual(result.first?.summary, "你查看预约页面的剩余名额。")
    }

    func testContinuationPromptRehydratesOriginalActivityInsteadOfLossySummary() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("memories")
        let first = try writeMemory(dir, segmentID: "2026-10-14T08-00-00Z", title: "Old", summary: "Counts")
        var original = try String(contentsOf: first, encoding: .utf8)
        original = original.replacingOccurrences(of: "细节内容。", with: "- **核查报告**：保留早期证据 SYNTHETIC_EARLY_RESULT。")
        try original.write(to: first, atomically: true, encoding: .utf8)
        try writeMemory(dir, segmentID: "2026-10-14T08-10-00Z", title: "New", summary: "Counts")
        let source = entries(dir)
        var prior = ActivityNarrative.Item(id: "prior", timestamp: source[0].startedAt, title: "核查报告", summary: "LOSSY_SUMMARY", apps: [], sourceMemories: [source[0].id])
        prior.sourceActivities = [source[0].id: [1]]
        let prompt = NarrativeGenerator.userPrompt(day: source[0].dayLabel(), sources: [source[1]], priorItems: [prior], historySources: source)
        XCTAssertTrue(prompt.contains("SYNTHETIC_EARLY_RESULT"))
        XCTAssertFalse(prompt.contains("LOSSY_SUMMARY"))
        XCTAssertFalse(prompt.contains("摘要：Counts"))
        let full = ActivityFragment.details(files: [first], activities: nil)
        XCTAssertTrue(full.first?.text.contains("SYNTHETIC_EARLY_RESULT") == true)
    }

    func testContinuationPreservesRolesAndDoesNotFeedIncidentalContentToTaskSummary() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("memories")
        let first = try writeMemory(dir, segmentID: "2026-10-14T08-00-00Z", title: "Old", summary: "Counts")
        let body = "- **迁移项目**：SYNTHETIC_MAIN。\n- **核对目录**：SYNTHETIC_STEP。\n- **查看天气**：SYNTHETIC_ASIDE。"
        try String(contentsOf: first, encoding: .utf8).replacingOccurrences(of: "细节内容。", with: body)
            .write(to: first, atomically: true, encoding: .utf8)
        try writeMemory(dir, segmentID: "2026-10-14T08-10-00Z", title: "New", summary: "Counts")
        let source = entries(dir)
        let prior = try XCTUnwrap(NarrativeGenerator.parseItems("## [S1.A1,+S1.A2,~S1.A3] 迁移项目\n核对目标目录。", sources: [source[0]]).first)
        let prompt = NarrativeGenerator.userPrompt(day: source[0].dayLabel(), sources: [source[1]], priorItems: [prior], historySources: source)
        XCTAssertTrue(prompt.contains("SYNTHETIC_STEP"))
        XCTAssertFalse(prompt.contains("SYNTHETIC_ASIDE"))
        let continued = NarrativeGenerator.parseItems("## [P1,+S1.A1] 迁移项目\n继续核对目录。", sources: [source[1]], priorItems: [prior])
        XCTAssertEqual(continued.count, 1)
        XCTAssertEqual(continued[0].sourceIncidental, prior.sourceIncidental)
        XCTAssertEqual(continued[0].sourceSteps?[source[0].id], [2])
        XCTAssertEqual(continued[0].sourceSteps?[source[1].id], [1])
        let incidentalContinuation = NarrativeGenerator.parseItems("## [P1,~S1.A1] 迁移项目\n核对目标目录。", sources: [source[1]], priorItems: [prior])
        XCTAssertTrue(incidentalContinuation.isEmpty, "Only incidental viewing must not extend a previous task")
    }

    func testFragmentOwnershipSurvivesNewAwayBoundaryAndMissingSourceCache() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("memories")
        let first = try writeMemory(dir, segmentID: "2026-10-14T08-00-00Z", title: "First", summary: "Counts")
        let second = try writeMemory(dir, segmentID: "2026-10-14T08-10-00Z", title: "Second", summary: "Counts")
        for (file, activity) in [(first, "- **其他任务**：UNRELATED_FIRST。\n- **迁移项目**：SELECTED_FIRST。"),
                                 (second, "- **迁移项目**：SELECTED_SECOND。\n- **其他任务**：UNRELATED_SECOND。") ] {
            let text = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(of: "细节内容。", with: activity)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
        let source = entries(dir)
        var item = ActivityNarrative.Item(id: "migration", timestamp: source[0].startedAt, title: "迁移项目", summary: "Combined", apps: [], sourceMemories: source.map(\.id))
        item.sourceActivities = [source[0].id: [2], source[1].id: [1]]
        var away = AwayPeriods()
        away.periods = [.init(start: source[0].startedAt.addingTimeInterval(300), end: source[1].startedAt)]
        let separated = ActivityNarrative(items: [item]).separatingAwayPeriods(index: .init(entries: source), away: away)
        XCTAssertEqual(separated.items.count, 2)
        XCTAssertTrue(separated.items.allSatisfy { !$0.summary.contains("UNRELATED") })
        XCTAssertTrue(separated.items.allSatisfy { $0.sourceActivities != nil })
        let unavailable = ActivityNarrative(items: [item]).separatingAwayPeriods(index: .init(entries: []), away: away, mode: .fixedTenMinutes)
        XCTAssertEqual(unavailable.items, [item])
    }

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
        XCTAssertEqual(saved.items.first?.summary, "细节内容。")
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
