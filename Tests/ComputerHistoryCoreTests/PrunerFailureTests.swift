import Foundation
import XCTest
@testable import ComputerHistoryCore

private final class FailingRemovalFileManager: FileManager, @unchecked Sendable {
    var failingName = ""
    var attempts: [String] = []
    var partiallyRemove = false
    var measurementFailureName = ""

    override func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?,
                                      options mask: FileManager.DirectoryEnumerationOptions = []) throws -> [URL] {
        if url.lastPathComponent == measurementFailureName { throw CocoaError(.fileReadNoPermission) }
        return try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
    }

    override func removeItem(at url: URL) throws {
        attempts.append(url.lastPathComponent)
        if url.lastPathComponent == failingName {
            if partiallyRemove { try super.removeItem(at: url.appendingPathComponent("events.jsonl")) }
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.removeItem(at: url)
    }
}

final class PrunerFailureTests: XCTestCase {
    func testOldestFailureStillDeletesOtherSegments() throws {
        try checkFailure(ageDays: 0)
    }

    func testAgeFailureRemainsInQuotaAccounting() throws {
        try checkFailure(ageDays: 1)
    }

    func testPartialRemovalFailureReportsActualRemainingBytes() throws {
        try checkFailure(ageDays: 0, partial: true)
    }

    func testIncompleteMeasurementIsReportedWithoutQuotaDeletion() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pruner-measure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = ["2020-01-01T00-00-00Z", "2030-01-01T00-00-00Z"]
        for id in ids {
            let directory = root.appendingPathComponent("segments/\(id)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(repeating: 120, count: 100).write(to: directory.appendingPathComponent("events.jsonl"))
        }
        let manager = FailingRemovalFileManager()
        manager.measurementFailureName = ids[0]
        let report = SegmentPruner.prune(rootDirectory: root,
            retention: .init(maxTotalBytes: 1, maxAgeDays: 0), fileManager: manager)
        XCTAssertNil(report.remainingBytes)
        XCTAssertEqual(report.removedSegments, 0)
        XCTAssertEqual(report.freedBytes, 0)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertEqual(report.failures.first?.operation, .measure)
        XCTAssertTrue(manager.attempts.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("segments").path).sorted(), ids)
    }

    private func checkFailure(ageDays: Int, partial: Bool = false) throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pruner-failure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = ["2020-01-01T00-00-00Z", "2030-01-01T00-00-00Z", "2030-01-01T00-10-00Z"]
        for id in ids {
            let directory = root.appendingPathComponent("segments/\(id)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(repeating: 120, count: 100).write(to: directory.appendingPathComponent("events.jsonl"))
        }
        let manager = FailingRemovalFileManager()
        manager.failingName = ids[0]
        manager.partiallyRemove = partial
        let report = SegmentPruner.prune(rootDirectory: root,
            retention: .init(maxTotalBytes: 200, maxAgeDays: ageDays),
            now: SegmentClock.date(fromSegmentID: ids[1])!, fileManager: manager)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("segments").path).sorted()
        XCTAssertEqual(remaining, [ids[0], ids[2]])
        XCTAssertEqual(report.removedSegments, 1)
        XCTAssertEqual(report.freedBytes, 100)
        XCTAssertTrue(manager.attempts.contains(ids[1]))
        XCTAssertEqual(manager.attempts.filter { $0 == ids[0] }.count, 1)
        XCTAssertEqual(report.remainingBytes, partial ? 100 : 200)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertEqual(report.failures.first?.directory.lastPathComponent, ids[0])
        XCTAssertEqual(report.failures.first?.operation, .remove)
        XCTAssertFalse(report.failures.first?.message.isEmpty ?? true)
        let actual = remaining.reduce(0) { sum, id in
            sum + ((try? Data(contentsOf: root.appendingPathComponent("segments/\(id)/events.jsonl")))?.count ?? 0)
        }
        XCTAssertEqual(report.remainingBytes, actual)
    }
}
