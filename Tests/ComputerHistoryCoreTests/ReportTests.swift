import XCTest
@testable import ComputerHistoryCore

final class ReportTests: XCTestCase {
    let zone = TimeZone(identifier: "Asia/Shanghai")!
    func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    @discardableResult func memory(_ root: URL, id: String = "2026-10-18T10-00-00Z", activity: String = "合成任务 👨‍👩‍👧‍👦 é") throws -> URL {
        let file = root.appendingPathComponent("memories/" + MemoryWriter.fileName(segmentID: id))
        try ActivityExport.write("""
        ---
        title: Synthetic
        description: synthetic summary
        generation: model
        applications: [com.example.synthetic]
        ---
        ## Memory summary
        ### Relevant prior context
        PRIVATE PRIOR CONTEXT
        ### Important non-obvious context about the user
        PRIVATE PROFILE
        ### 本次活动
        \(activity)
        ## Recording summary
        ### 时序证据
        RAW EVIDENCE
        ## Citations
        /synthetic/private/path/events.jsonl
        """, to: file)
        return file
    }
    func testLocalDayAndMondayWeekAcrossYearAndDST() throws {
        let date = try ReportPeriod.parseDay("2026-10-19", timeZone: zone)
        let day = ReportPeriod(kind: .daily, date: date, timeZone: zone)
        XCTAssertEqual(day.end.timeIntervalSince(day.start), 86400)
        XCTAssertEqual(ReportPeriod(kind: .weekly, date: date, timeZone: zone).key, "2026-10-19")
        XCTAssertEqual(ReportPeriod(kind: .weekly, date: try ReportPeriod.parseDay("2026-10-18", timeZone: zone), timeZone: zone).key, "2026-10-12")
        XCTAssertEqual(ReportPeriod(kind: .weekly, date: try ReportPeriod.parseDay("2027-01-01", timeZone: zone), timeZone: zone).key, "2026-12-28")
        let us = TimeZone(identifier: "America/Los_Angeles")!
        let dst = ReportPeriod(kind: .daily, date: try ReportPeriod.parseDay("2026-03-08", timeZone: us), timeZone: us)
        XCTAssertEqual(dst.end.timeIntervalSince(dst.start), 23 * 3600)
        XCTAssertFalse(day.contains(day.end))
        XCTAssertThrowsError(try ReportPeriod.parseDay("2026-02-30"))
        XCTAssertThrowsError(try ReportPeriod.parseDay("../2026"))
    }
    func testPortableMaterialIsCompleteAndExcludesInternalSections() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let long = String(repeating: "长内容👩🏽‍💻", count: 5000)
        try memory(root, activity: long)
        let period = ReportPeriod(kind: .daily, date: try ReportPeriod.parseDay("2026-10-18", timeZone: zone), timeZone: zone)
        let text = try ActivityExport.aiMaterial(root: root, period: period)
        XCTAssertTrue(text.contains(long))
        for excluded in ["PRIVATE PRIOR", "PRIVATE PROFILE", "RAW EVIDENCE", "/synthetic/private"] { XCTAssertFalse(text.contains(excluded)) }
        let chunks = ReportGenerator.chunks(long, limit: 1000)
        XCTAssertEqual(chunks.map { $0.trimmingCharacters(in: .newlines) }.joined(), long)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 1001 })
        try ActivityExport.refresh(root: root, timeZone: zone)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("exports/activities/2026-10-18.md").path))
    }
    func testPreviewFinalizationAndLateSourcesRegenerate() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        try memory(root)
        let period = ReportPeriod(kind: .daily, date: try ReportPeriod.parseDay("2026-10-18", timeZone: zone), timeZone: zone)
        let gen = ReportGenerator(root: root, client: nil)
        let preview = try gen.generate(period: period, now: period.start.addingTimeInterval(70000))
        XCTAssertTrue(preview.preview)
        let final = try gen.generate(period: period, now: period.end)
        XCTAssertFalse(final.preview)
        let unchanged = try gen.generate(period: period, now: period.end.addingTimeInterval(60))
        XCTAssertEqual(final.generatedAt, unchanged.generatedAt)
        try memory(root, id: "2026-10-18T11-00-00Z", activity: "late material")
        let updated = try gen.generate(period: period, now: period.end.addingTimeInterval(120))
        XCTAssertTrue(updated.material.contains("late material"))
        XCTAssertNotEqual(updated.generatedAt, final.generatedAt)
    }
    func testOpenAndMissingSegmentsBlockFinalReport() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        try memory(root)
        let period = ReportPeriod(kind: .daily, date: try ReportPeriod.parseDay("2026-10-18", timeZone: zone), timeZone: zone)
        let segment = root.appendingPathComponent("segments/2026-10-18T12-00-00Z")
        try FileManager.default.createDirectory(at: segment, withIntermediateDirectories: true)
        let gen = ReportGenerator(root: root, client: nil)
        XCTAssertThrowsError(try gen.generate(period: period, now: period.end))
        try Data("{}".utf8).write(to: segment.appendingPathComponent("metadata.json"))
        XCTAssertThrowsError(try gen.generate(period: period, now: period.end))
        try memory(root, id: segment.lastPathComponent)
        XCTAssertNoThrow(try gen.generate(period: period, now: period.end))
    }
    func testReportFillsOnlyMissingAndFailedMemoriesInPeriod() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let period = ReportPeriod(kind: .daily, date: try ReportPeriod.parseDay("2020-01-05", timeZone: zone), timeZone: zone)
        let ids = ["2020-01-05T10-00-00Z", "2020-01-05T10-00-00Z_AAAA1111-0000-0000-0000-000000000001", "2020-01-05T11-00-00Z", "2020-01-06T10-00-00Z"]
        for id in ids {
            let date = SegmentClock.date(fromSegmentID: id)!
            let event = EventStreamRecord(id: 1, timestamp: date, kind: .windowChanged,
                app: .init(name: "Synthetic Editor", bundleIdentifier: "example.editor"))
            let directory = root.appendingPathComponent("segments/" + id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try EventStreamJSON.makeEncoder().encode(event).write(to: directory.appendingPathComponent("events.jsonl"))
            let metadata = EventStreamMetadata(id: id, startedAt: date, endedAt: date.addingTimeInterval(60), endReason: nil,
                eventCount: 1, suppressedEventCount: 0, eventsPath: directory.appendingPathComponent("events.jsonl").path, firstEventAt: date)
            try EventStreamJSON.makeEncoder().encode(metadata)
                .write(to: directory.appendingPathComponent("metadata.json"))
        }
        let good = try memory(root, id: ids[2], activity: "保留已有优质摘要")
        let original = try Data(contentsOf: good)
        let failed = root.appendingPathComponent("memories/" + MemoryWriter.fileName(segmentID: ids[1]))
        try ActivityExport.write("---\ntitle: Failed\ngeneration: failed\n---\n", to: failed)
        let generator = ReportGenerator(root: root, client: nil)
        _ = try generator.generate(period: period, now: period.end)
        for id in ids.prefix(3) {
            let file = root.appendingPathComponent("memories/" + MemoryWriter.fileName(segmentID: id))
            XCTAssertTrue(MemoryGenerator.hasUsableMemory(at: file))
            XCTAssertEqual(MemoryIndex.parse(fileURL: file)?.sourceSegmentID, id)
        }
        let restarted = MemoryIndex.parse(fileURL: failed)!
        XCTAssertEqual(restarted.firstEventAt, SegmentClock.date(fromSegmentID: ids[1]))
        XCTAssertEqual(try Data(contentsOf: good), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("memories/" + MemoryWriter.fileName(segmentID: ids[3])).path))
        XCTAssertEqual(CollectorStatus.read(root: root).memories.pendingSegments, 1)
    }

    func testAutomaticReportsDiscoverDaysWithNoMemoriesYet() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let id = "2020-01-05T10-00-00Z"
        let date = SegmentClock.date(fromSegmentID: id)!
        let directory = root.appendingPathComponent("segments/" + id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let event = EventStreamRecord(id: 1, timestamp: date, kind: .windowChanged)
        try EventStreamJSON.makeEncoder().encode(event).write(to: directory.appendingPathComponent("events.jsonl"))
        try Data("{\"eventCount\":1}".utf8).write(to: directory.appendingPathComponent("metadata.json"))
        XCTAssertGreaterThan(try ReportGenerator(root: root, client: nil).generateMissing(), 0)
        let period = ReportPeriod(kind: .daily, date: date)
        XCTAssertNotNil(try ActivityReport.load(root: root, period: period))
    }
    func testWeeklyRequiresCompletedDailyAndChangesWithDaily() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        try memory(root)
        let day = ReportPeriod(kind: .daily, date: try ReportPeriod.parseDay("2026-10-18", timeZone: zone), timeZone: zone)
        let week = ReportPeriod(kind: .weekly, date: day.start, timeZone: zone)
        let gen = ReportGenerator(root: root, client: nil)
        XCTAssertThrowsError(try gen.generate(period: week, now: week.end, fillDailyDependencies: false))
        _ = try gen.generate(period: day, now: day.end)
        let report = try gen.generate(period: week, now: week.end)
        XCTAssertTrue(report.material.contains("2026-10-18 日报"))
        try memory(root, activity: "corrected activity")
        XCTAssertThrowsError(try gen.generate(period: week, now: week.end.addingTimeInterval(60), fillDailyDependencies: false))
        _ = try gen.generate(period: day, now: day.end.addingTimeInterval(60))
        XCTAssertTrue(try gen.generate(period: week, now: week.end.addingTimeInterval(60)).material.contains("corrected activity"))
    }
    func testPendingOlderDaysDoNotStarveLaterReports() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        for day in ["2020-01-01", "2020-01-02", "2020-01-03"] {
            let file = try memory(root, id: "\(day)T10-00-00Z")
            let text = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(of: "generation: model", with: "generation: failed")
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
        try memory(root, id: "2020-01-04T10-00-00Z")
        let gen = ReportGenerator(root: root, client: nil)
        XCTAssertThrowsError(try gen.generateMissing(dailyLimit: 1))
        let later = ReportPeriod(kind: .daily, date: try ReportPeriod.parseDay("2020-01-04"))
        XCTAssertNotNil(try ActivityReport.load(root: root, period: later))
    }

    func testBackupDefaultsDisabledAndMalformedSettingsPreserved() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(try BackupSettings.load(root: root))
        XCTAssertNil(try GitHubBackup(root: root).sync(automatic: true).lastSuccess)
        XCTAssertThrowsError(try GitHubBackup(root: root).sync())
        for repo in ["", "../bad", "owner/repo/extra", "-owner/repo"] {
            XCTAssertThrowsError(try BackupSettings(repository: repo).save(root: root))
        }
        try BackupSettings(repository: "example/private-backup", enabled: false).save(root: root)
        XCTAssertNil(try GitHubBackup(root: root).sync(automatic: true).lastSuccess)
        let file = root.appendingPathComponent("backup.json")
        try Data("bad".utf8).write(to: file)
        XCTAssertThrowsError(try BackupSettings.load(root: root))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "bad")
    }
}
