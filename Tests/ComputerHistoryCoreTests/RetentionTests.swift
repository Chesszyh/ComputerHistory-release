import Foundation
import XCTest
@testable import ComputerHistoryCore

/// 保留策略与配置持久化的测试。
///
/// 长期后台运行时磁盘与配置都必须可控：实测约 1.3 MB/分钟（≈1.9 GB/天），
/// 不做清理会填满磁盘。
final class RetentionTests: XCTestCase {

    private func tempRoot() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ch-ret-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 造一个 segment 目录，含指定大小的 events.jsonl。
    @discardableResult
    private func makeSegment(_ root: URL, _ id: String, bytes: Int) throws -> URL {
        let dir = root.appendingPathComponent("segments").appendingPathComponent(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let payload = String(repeating: "x", count: max(0, bytes - 1)) + "\n"
        try payload.write(to: dir.appendingPathComponent("events.jsonl"),
                          atomically: true, encoding: .utf8)
        return dir
    }

    /// 超量时从最旧开始删，且**永远保留最新的一个**。
    func testPruneRemovesOldestAndKeepsNewest() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let ids = ["2026-10-11T10-00-00Z", "2026-10-11T10-10-00Z", "2026-10-11T10-20-00Z"]
        for id in ids { try makeSegment(root, id, bytes: 1000) }

        // 上限只够放一个段
        let report = SegmentPruner.prune(
            rootDirectory: root,
            retention: .init(maxTotalBytes: 1500, maxAgeDays: 0))
        XCTAssertEqual(report.removedSegments, 2)
        XCTAssertGreaterThan(report.freedBytes, 0)

        let left = try FileManager.default.contentsOfDirectory(
            atPath: root.appendingPathComponent("segments").path).sorted()
        XCTAssertEqual(left, ["2026-10-11T10-20-00Z"], "应保留最新的段")
    }

    /// 超龄按**目录名**判断，而不是文件修改时间。
    func testPruneByAgeUsesDirectoryName() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try makeSegment(root, "2020-01-01T00-00-00Z", bytes: 100)
        try makeSegment(root, "2020-01-01T00-10-00Z", bytes: 100)
        try makeSegment(root, "2030-01-01T00-00-00Z", bytes: 100)

        let now = Date(timeIntervalSince1970: 1_900_000_000)   // 2030 年附近
        let report = SegmentPruner.prune(
            rootDirectory: root,
            retention: .init(maxTotalBytes: 0, maxAgeDays: 30), now: now)
        XCTAssertEqual(report.removedSegments, 2, "2020 年的两段应超龄")
        let left = try FileManager.default.contentsOfDirectory(
            atPath: root.appendingPathComponent("segments").path).sorted()
        XCTAssertEqual(left, ["2030-01-01T00-00-00Z"])
    }

    /// 只有一个段时绝不删除——否则刚开始采集就把正在写的段删掉。
    func testNeverRemovesTheOnlySegment() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try makeSegment(root, "2020-01-01T00-00-00Z", bytes: 10_000)
        let report = SegmentPruner.prune(
            rootDirectory: root,
            retention: .init(maxTotalBytes: 1, maxAgeDays: 1),
            now: Date(timeIntervalSince1970: 1_900_000_000))
        XCTAssertEqual(report.removedSegments, 0)
    }

    /// 目录名解析不出时间的外部内容不主动删除。
    func testUnparseableDirectoryIsKept() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try makeSegment(root, "not-a-timestamp", bytes: 100)
        try makeSegment(root, "2030-01-01T00-00-00Z", bytes: 100)
        let report = SegmentPruner.prune(
            rootDirectory: root,
            retention: .init(maxTotalBytes: 0, maxAgeDays: 30),
            now: Date(timeIntervalSince1970: 1_900_000_000))
        XCTAssertEqual(report.removedSegments, 0)
    }

    // MARK: - 配置

    /// 配置文件缺失时返回默认值并写出模板。
    func testConfigGeneratesTemplateWhenMissing() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let cfg = try CollectorConfig.load(rootDirectory: root)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: CollectorConfig.fileURL(rootDirectory: root).path))
        XCTAssertFalse(cfg.policy.blocklist.isEmpty, "默认应屏蔽凭据类应用")
    }

    /// 配置往返：写出再读回，字段一致。
    func testConfigRoundTrip() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        var cfg = CollectorConfig()
        cfg.maxNodesPerSnapshot = 1234
        cfg.retention.maxTotalBytes = 4096
        cfg.retention.maxAgeDays = 7
        cfg.policy.blocklist = [.application("com.example.secret"), .domain("example.com")]
        cfg.policy.defaultURLBehavior = .doNotObserve
        try cfg.jsonData().write(to: CollectorConfig.fileURL(rootDirectory: root))

        let back = try CollectorConfig.load(rootDirectory: root)
        XCTAssertEqual(back.maxNodesPerSnapshot, 1234)
        XCTAssertEqual(back.retention.maxTotalBytes, 4096)
        XCTAssertEqual(back.retention.maxAgeDays, 7)
        XCTAssertEqual(back.policy.defaultURLBehavior, .doNotObserve)
        XCTAssertEqual(back.policy.blocklist.count, 2)
    }

    func testCorruptConfigFailsWithoutReplacingPrivacyPolicy() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let original = "{ invalid privacy policy"
        let url = CollectorConfig.fileURL(rootDirectory: root)
        try original.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try CollectorConfig.load(rootDirectory: root))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original)
    }

    /// 缺字段时取默认值，保证旧配置在新版本下仍可用。
    func testPartialConfigUsesDefaults() throws {
        let data = Data(#"{"maxNodesPerSnapshot": 77}"#.utf8)
        let cfg = try CollectorConfig.decode(from: data)
        XCTAssertEqual(cfg.maxNodesPerSnapshot, 77)
        XCTAssertEqual(cfg.retention.maxAgeDays, 2, "未提供的字段应取默认")
    }
}
