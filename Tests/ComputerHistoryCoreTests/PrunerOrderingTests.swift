import Foundation
import XCTest
@testable import ComputerHistoryCore

private final class OrderedDirectoryFileManager: FileManager, @unchecked Sendable {
    var names: [String] = []

    override func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?,
                                      options mask: FileManager.DirectoryEnumerationOptions = []) throws -> [URL] {
        let entries = try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
        if url.lastPathComponent == "segments" {
            return names.compactMap { name in entries.first { $0.lastPathComponent == name } }
        }
        return entries
    }
}

final class PrunerOrderingTests: XCTestCase {
    private let base = "2026-10-13T02-00-00Z"
    private let low = "00000000-0000-0000-0000-000000000001"
    private let high = "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"

    func testFirstEventOrdersOrdinaryAndUnsealedUUIDSegments() throws {
        let names = [base, base + "_" + high, base + "_" + low]
        let start = SegmentClock.date(fromSegmentID: base)!
        try checkOrders(names: names, timestamps: [start.addingTimeInterval(1), start.addingTimeInterval(2), start.addingTimeInterval(3)],
                        expected: names[2])
    }

    func testMissingAndInvalidEventsUseDeterministicNameFallback() throws {
        let names = [base, base + "_" + high, base + "_" + low]
        try checkOrders(names: names, timestamps: [nil, nil, nil], expected: names[1])
    }

    func testEqualFirstEventTimesUseDeterministicNameFallback() throws {
        let names = [base, base + "_" + high, base + "_" + low]
        let start = SegmentClock.date(fromSegmentID: base)!.addingTimeInterval(1)
        try checkOrders(names: names, timestamps: [start, start, start], expected: names[1])
    }

    func testExplicitActiveSegmentOverridesSameBucketOrder() throws {
        let names = [base, base + "_" + high, base + "_" + low]
        let start = SegmentClock.date(fromSegmentID: base)!
        try checkOrders(names: names, timestamps: [start, start.addingTimeInterval(1), start.addingTimeInterval(2)],
                        expected: names[0], active: names[0])
    }

    func testOutOfBucketEventTimesUseNameFallback() throws {
        let names = [base, base + "_" + high, base + "_" + low]
        let start = SegmentClock.date(fromSegmentID: base)!
        try checkOrders(names: names,
            timestamps: [start.addingTimeInterval(-1), nil, start.addingTimeInterval(600)], expected: names[1])
    }

    private func checkOrders(names: [String], timestamps: [Date?], expected: String, active: String? = nil) throws {
        let orders = [[0, 1, 2], [2, 1, 0], [1, 0, 2], [1, 2, 0], [0, 2, 1], [2, 0, 1]]
        for order in orders {
            let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pruner-order-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            for (index, name) in names.enumerated() {
                let directory = root.appendingPathComponent("segments/\(name)")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let content: String
                if let timestamp = timestamps[index] {
                    let event = EventStreamRecord(id: 1, timestamp: timestamp, kind: .sessionStarted)
                    content = String(decoding: try EventStreamJSON.makeEncoder().encode(event), as: UTF8.self) + "\n"
                } else {
                    content = index == 0 ? "" : "partial record"
                }
                if timestamps[index] != nil || index != 0 {
                    try Data(content.utf8).write(to: directory.appendingPathComponent("events.jsonl"))
                }
            }
            let manager = OrderedDirectoryFileManager()
            manager.names = order.map { names[$0] }
            let report = SegmentPruner.prune(rootDirectory: root,
                retention: .init(maxTotalBytes: 1, maxAgeDays: 0), activeSegmentID: active, fileManager: manager)
            let remaining = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("segments").path)
            XCTAssertEqual(remaining, [expected], "enumeration: \(manager.names)")
            XCTAssertEqual(report.removedSegments, 2)
            XCTAssertTrue(report.failures.isEmpty)
        }
    }
}
