import Foundation
import XCTest
@testable import ComputerHistoryCore

/// 并发与归属唯一性的测试。
///
/// 这两类问题都不会让构建失败、也不会让已有用例变红，但会在界面上表现为
/// 「同一时段出现三条完全相同的内容」。
final class ConcurrencyTests: XCTestCase {

    private func tempRoot() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ch-lock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 同一把锁不能被获取两次。
    func testLockIsExclusive() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let url = GenerationLock.lockURL("narrative", root: root)

        let first = try XCTUnwrap(ProcessLock(url: url))
        XCTAssertNil(ProcessLock(url: url), "同一进程内第二次获取也应失败")
        first.release()
        // 释放后可以再次获取
        let second = ProcessLock(url: url)
        XCTAssertNotNil(second)
        second?.release()
    }

    func testRepeatedReleaseCannotUnlockAnotherOwner() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let url = GenerationLock.lockURL("memorize", root: root)
        var first = try XCTUnwrap(ProcessLock(url: url)) as ProcessLock?
        first?.release()
        let second = try XCTUnwrap(ProcessLock(url: url))
        first?.release()
        first = nil
        XCTAssertNil(ProcessLock(url: url), "released owner must not unlock a reused descriptor")
        withExtendedLifetime(second) {}
    }

    /// 锁文件记录持有者 pid，便于排查。
    func testLockRecordsHolder() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let url = GenerationLock.lockURL("memorize", root: root)
        let lock = try XCTUnwrap(ProcessLock(url: url))
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("pid \(getpid())"), "锁文件应记录持有者：\(text)")
        lock.release()
    }

    /// 记忆生成与叙述生成使用不同的锁，可以并行。
    func testDifferentTasksUseDifferentLocks() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let memo = ProcessLock(url: GenerationLock.lockURL("memorize", root: root))
        let narr = ProcessLock(url: GenerationLock.lockURL("narrative", root: root))
        XCTAssertNotNil(memo)
        XCTAssertNotNil(narr, "叙述生成不应被记忆生成的锁挡住")
        memo?.release(); narr?.release()
    }

    // MARK: - 归属唯一性

    private func makeSources(_ count: Int, base: Date) -> [MemoryIndex.Entry] {
        (0..<count).map { i in
            let id = String(format: "2026-10-14T%02d-00-00Z", i)
            return MemoryIndex.Entry(
                fileURL: URL(fileURLWithPath: "/tmp/\(id)-AAAA-10min-memory-summary.md"),
                startedAt: base.addingTimeInterval(Double(i) * 600),
                sourceSegmentID: id, granularity: "10min",
                title: "T\(i)", summary: "s", applications: ["com.a"],
                body: "", sections: [])
        }
    }

    /// **同一来源不得被两条认领**。
    ///
    /// 增量模式下可认领的来源可能只有一份，而模型仍会输出多条。若允许共享，
    /// 多条会得到同一来源集合、算出同一个 id，在 ForEach 里重复渲染。
    func testSourceClaimedAtMostOnce() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let sources = makeSources(3, base: base)
        // 模型把同一份来源拆成三条
        let text = """
        ## [S1] 第一件事
        一。

        ## [S1] 第二件事
        二。

        ## [S1] 第三件事
        三。
        """
        let items = NarrativeGenerator.parseItems(text, sources: sources,
                                                  claimed: [sources[0]])
        XCTAssertTrue(items.isEmpty, "重复认领使整批结果无效")
    }

    /// 多条条目不得共享同一个 id。
    func testItemIDsAreUnique() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let sources = makeSources(3, base: base)
        let text = """
        ## [S1] 活动甲
        内容甲。

        ## [S2] 活动乙
        内容乙。

        ## [S3] 活动丙
        内容丙。
        """
        let items = NarrativeGenerator.parseItems(text, sources: sources)
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(Set(items.map(\.id)).count, 3,
                       "id 必须唯一，否则 ForEach 会渲染错乱")
    }

    func testIncrementalCannotClaimEarlierSources() {
        let sources = makeSources(4, base: Date(timeIntervalSince1970: 1_800_000_000))
        let invalid = NarrativeGenerator.parseItems("## [S1] 前文\n内容。", sources: sources, claimed: [sources[3]])
        XCTAssertTrue(invalid.isEmpty)
        let valid = NarrativeGenerator.parseItems("## [S4] 新增\n内容。", sources: sources, claimed: [sources[3]])
        XCTAssertEqual(valid.first?.sourceMemories, [sources[3].id])
    }

    /// 覆盖范围连续时，各条按序分到各自的来源。
    func testSequentialClaimPartitionsSources() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let sources = makeSources(4, base: base)
        let text = """
        ## [S1,S2] 甲
        一。

        ## [S3,S4] 乙
        二。
        """
        let items = NarrativeGenerator.parseItems(text, sources: sources)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].sourceMemories.count, 2, "第一条应覆盖前两份")
        XCTAssertEqual(items[1].sourceMemories.count, 2, "第二条应覆盖后两份")
        let all = items.flatMap(\.sourceMemories)
        XCTAssertEqual(Set(all).count, 4)
        XCTAssertEqual(all.count, 4, "不得重复计入")
    }
}
