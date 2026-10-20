import Foundation
import XCTest
@testable import ComputerHistoryCore

final class TimestampTests: XCTestCase {
    func testDefaultTimestampUsesSystemTimeZone() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let local = ISO8601DateFormatter()
        local.timeZone = .current
        XCTAssertEqual(EventStreamJSON.timestampString(from: date), local.string(from: date))
    }

    func testOffsetAndFractionalSecondsPreserveTheInstant() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000.125)
        for hours in [8, -5, 0] {
            let string = EventStreamJSON.timestampString(from: date,
                timeZone: TimeZone(secondsFromGMT: hours * 3600)!, preservingSubseconds: true)
            let json = "{\"id\":1,\"kind\":\"window.changed\",\"timestamp\":\"" + string + "\"}"
            let event = try EventStreamJSON.makeDecoder().decode(EventStreamRecord.self, from: Data(json.utf8))
            XCTAssertEqual(event.timestamp.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.001)
        }
        XCTAssertEqual(EventStreamJSON.timestampString(from: date, timeZone: TimeZone(secondsFromGMT: 8 * 3600)!),
                       "2027-01-15T16:00:00+08:00")
    }

    func testRequestWritesReadableDatesAndAwayReadsLegacyDates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let date = Date(timeIntervalSince1970: 1_800_000_000.125)
        let request = ModelRequest(id: "synthetic", startedAt: date,
            model: "synthetic", endpoint: "http://127.0.0.1", task: "10min", sources: [], status: "success", system: "", input: "")
        try request.save(root: root)
        let file = root.appendingPathComponent("requests/synthetic.json")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(object["startedAt"] as? String, EventStreamJSON.timestampString(from: date, preservingSubseconds: true))
        XCTAssertEqual(try ModelRequest.load(url: file).startedAt.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.001)
        var away = AwayPeriods(startedAt: date)
        try JSONEncoder().encode(away).write(to: root.appendingPathComponent("away.json"))
        XCTAssertEqual(AwayPeriods.load(root: root).startedAt, date)
        away.periods = [.init(start: date, end: date.addingTimeInterval(60))]
        try away.save(root: root)
        XCTAssertEqual(AwayPeriods.load(root: root).periods, away.periods)
    }

    func testRequestReaderAcceptsLegacyNumericAndOffsetDates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("request.json")
        var request = ModelRequest(id: "synthetic", startedAt: Date(timeIntervalSinceReferenceDate: 123.125),
            model: "synthetic", endpoint: "http://127.0.0.1", task: "10min", sources: [], status: "success", system: "", input: "")
        try JSONEncoder().encode(request).write(to: file)
        XCTAssertEqual(try ModelRequest.load(url: file).startedAt, request.startedAt)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            let f = ISO8601DateFormatter(); f.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
            try c.encode(f.string(from: date))
        }
        request.startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try encoder.encode(request).write(to: file)
        XCTAssertEqual(try ModelRequest.load(url: file).startedAt, request.startedAt)
    }
}
