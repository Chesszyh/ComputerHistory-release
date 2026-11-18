import Foundation
import Darwin
import CryptoKit
import XCTest
@testable import ComputerHistoryCore

final class ModelBudgetIndexTests: XCTestCase {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("budget-index-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        return cal
    }

    private func date(_ year: Int = 2026, _ month: Int = 11, _ day: Int = 2,
                      hour: Int = 0, minute: Int = 0) -> Date {
        calendar.date(from: .init(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func request(_ id: String, _ amount: Double?, currency: String = "CNY", at: Date? = nil,
                         fallbackOf: String? = nil, retryOf: String? = nil) -> ModelRequest {
        ModelRequest(id: id, startedAt: at ?? date(), model: "synthetic", endpoint: "https://example.invalid",
                     task: "10min", sources: [], status: amount == nil ? "running" : "success",
                     system: "synthetic-system-body", input: "synthetic-input-body",
                     output: "synthetic-output-body",
                     pricing: .init(currency: currency, inputPerMillion: 1, cachedInputPerMillion: 0, outputPerMillion: 1),
                     estimatedCost: amount, fallbackOf: fallbackOf, retryOf: retryOf)
    }

    private func totals(_ root: URL, currency: String = "CNY") throws -> ModelBudgetIndex.Totals {
        try ModelBudgetIndex.totals(root: root, currency: currency, at: date(hour: 12), calendar: calendar)
    }

    func testRebuildUsesAuthoritativeChargesAcrossDayMonthAndCurrencyBoundaries() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(try totals(root), .init())
        let requests = ModelRequest.ledgerDirectory(root: root)
        try FileManager.default.createDirectory(at: requests, withIntermediateDirectories: true)
        let fixtures = [
            request("primary", 2), request("retry", 1, retryOf: "primary"),
            request("fallback", 0.5, fallbackOf: "primary"),
            request("first-of-month", 4, at: date(2026, 11, 1)),
            request("previous-month", 100, at: date(2026, 10, 31, hour: 23, minute: 59)),
            request("next-month", 200, at: date(2026, 12, 1)),
            request("previous-year", 400, at: date(2025, 11, 2)),
            request("other-currency", 800, currency: "USD"), request("unknown", nil),
        ]
        for fixture in fixtures {
            // Simulate the older numeric timestamp encoding and the absence of any derived index.
            let source = requests.appendingPathComponent(fixture.id + ".json")
            try JSONEncoder().encode(fixture).write(to: source)
            try FileManager.default.setAttributes([.modificationDate: date(2026, 10, 5)], ofItemAtPath: source.path)
        }
        XCTAssertEqual(try totals(root), .init(daily: 3.5, monthly: 7.5))
        let url = ModelBudgetIndex.fileURL(root: root)
        let saved = String(decoding: try Data(contentsOf: url).dropFirst(SHA256.Digest.byteCount), as: UTF8.self)
        XCTAssertTrue(saved.contains("other-currency.json"))
        XCTAssertFalse(saved.contains("synthetic-input-body"))
        XCTAssertFalse(saved.contains("synthetic-system-body"))
        XCTAssertFalse(saved.contains("synthetic-output-body"))
        let stamp = try XCTUnwrap(FileStamp(url))
        XCTAssertEqual(try totals(root, currency: "USD"), .init(daily: 800, monthly: 800))
        XCTAssertEqual(FileStamp(url), stamp, "A stable lookup must reuse the published index")
    }

    func testReplacementDeletionAndAnInPlaceEditWithRestoredMtime() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try request("same-id", nil).save(root: root)
        try request("independent", 1).save(root: root)
        XCTAssertEqual(try totals(root), .init(daily: 1, monthly: 1))
        try request("same-id", 2).save(root: root)
        XCTAssertEqual(try totals(root), .init(daily: 3, monthly: 3))
        try request("same-id", 4).save(root: root)
        XCTAssertEqual(try totals(root), .init(daily: 5, monthly: 5))

        let dir = ModelRequest.ledgerDirectory(root: root)
        let file = dir.appendingPathComponent("same-id.json")
        var before = stat()
        XCTAssertEqual(stat(file.path, &before), 0)
        let original = try String(contentsOf: file, encoding: .utf8)
        let edited = original.replacingOccurrences(of: "\"estimatedCost\":4", with: "\"estimatedCost\":9")
        XCTAssertNotEqual(original, edited)
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data(edited.utf8))
        try handle.close()
        var dates = [before.st_atimespec, before.st_mtimespec]
        XCTAssertEqual(utimensat(AT_FDCWD, file.path, &dates, 0), 0)
        var after = stat()
        XCTAssertEqual(stat(file.path, &after), 0)
        XCTAssertEqual(before.st_ino, after.st_ino)
        XCTAssertEqual(before.st_size, after.st_size)
        XCTAssertEqual(before.st_mtimespec.tv_sec, after.st_mtimespec.tv_sec)
        XCTAssertEqual(before.st_mtimespec.tv_nsec, after.st_mtimespec.tv_nsec)
        XCTAssertEqual(try totals(root), .init(daily: 10, monthly: 10))

        try FileManager.default.removeItem(at: dir.appendingPathComponent("independent.json"))
        XCTAssertEqual(try totals(root), .init(daily: 9, monthly: 9))
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(try totals(root), .init())
    }

    func testCorruptOrUnwritableIndexRebuildsAndCorruptLedgerFailsClosed() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try request("charged", 2).save(root: root)
        let url = ModelBudgetIndex.fileURL(root: root)
        XCTAssertEqual(try totals(root), .init(daily: 2, monthly: 2))
        try Data("{".utf8).write(to: url)
        try request("charged", 4).save(root: root)
        XCTAssertEqual(try totals(root), .init(daily: 4, monthly: 4))
        let goodIndex = try Data(contentsOf: url)
        let payload = goodIndex.dropFirst(SHA256.Digest.byteCount)
        let damaged = String(decoding: payload, as: UTF8.self)
            .replacingOccurrences(of: "\"estimatedCost\":4", with: "\"estimatedCost\":0")
        XCTAssertNotEqual(Data(damaged.utf8), payload)
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(damaged.utf8)) as? [String: Any])
        try (goodIndex.prefix(SHA256.Digest.byteCount) + Data(damaged.utf8)).write(to: url, options: .atomic)
        XCTAssertEqual(try totals(root), .init(daily: 4, monthly: 4))

        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let blocker = url.appendingPathComponent("keep")
        try Data().write(to: blocker)
        try request("charged", 8).save(root: root)
        XCTAssertEqual(try totals(root), .init(daily: 8, monthly: 8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: blocker.path))
        let source = ModelRequest.ledgerDirectory(root: root).appendingPathComponent("charged.json")
        try Data("{".utf8).write(to: source, options: .atomic)
        XCTAssertThrowsError(try totals(root)) { error in
            XCTAssertTrue(String(describing: error).contains("charged.json"))
        }
    }

    func testConcurrentWriterReplacementsAndRecoveryAfterWorkerExit() throws {
        let environment = ProcessInfo.processInfo.environment
        if let operation = environment["COMPUTER_HISTORY_BUDGET_TEST_OPERATION"],
           let path = environment["COMPUTER_HISTORY_BUDGET_TEST_ROOT"] {
            let root = URL(fileURLWithPath: path)
            let ready = root.appendingPathComponent(operation + ".ready")
            if operation == "interrupted" {
                try request("pending", 4).save(root: root)
                try ModelRequest.withLedgerLock(root: root) {
                    try Data().write(to: ready)
                    Thread.sleep(forTimeInterval: 8)
                }
            } else {
                try Data().write(to: ready)
                for index in 0..<4 {
                    let id = operation + String(index)
                    try request(id, nil).save(root: root)
                    try request(id, 1).save(root: root)
                    _ = try totals(root)
                }
            }
            return
        }

        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try request("pending", nil).save(root: root)
        XCTAssertEqual(try totals(root), .init())
        var children: [Process] = []
        defer {
            for process in children where process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }
        func launch(_ operation: String) throws -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["xctest", "-XCTest",
                "ComputerHistoryCoreTests.ModelBudgetIndexTests/testConcurrentWriterReplacementsAndRecoveryAfterWorkerExit",
                Bundle(for: ModelBudgetIndexTests.self).bundleURL.path]
            process.environment = environment.merging([
                "COMPUTER_HISTORY_BUDGET_TEST_OPERATION": operation,
                "COMPUTER_HISTORY_BUDGET_TEST_ROOT": root.path
            ]) { _, new in new }
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            children.append(process)
            return process
        }
        func waitUntil(_ predicate: () -> Bool) throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while !predicate() {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw POSIXError(.ETIMEDOUT) }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }

        try ModelRequest.withLedgerLock(root: root) {
            _ = try launch("first")
            _ = try launch("second")
            try waitUntil {
                ["first", "second"].allSatisfy {
                    FileManager.default.fileExists(atPath: root.appendingPathComponent($0 + ".ready").path)
                }
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: ModelRequest.ledgerDirectory(root: root).path)
                .filter { $0.hasSuffix(".json") }, ["pending.json"])
        }
        try waitUntil { children.allSatisfy { !$0.isRunning } }
        XCTAssertEqual(children.map(\.terminationStatus), [0, 0])
        XCTAssertEqual(try totals(root), .init(daily: 8, monthly: 8))

        let interrupted = try launch("interrupted")
        try waitUntil { FileManager.default.fileExists(atPath: root.appendingPathComponent("interrupted.ready").path) }
        XCTAssertEqual(kill(interrupted.processIdentifier, SIGKILL), 0)
        try waitUntil { !interrupted.isRunning }
        XCTAssertEqual(interrupted.terminationReason, .uncaughtSignal)
        XCTAssertEqual(try totals(root), .init(daily: 12, monthly: 12))
    }
}
