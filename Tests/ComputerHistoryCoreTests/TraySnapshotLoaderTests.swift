import Foundation
import XCTest
@testable import ComputerHistoryCore

final class TraySnapshotLoaderTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func segment(_ root: URL, id: String = "2026-10-16T00-00-00Z", text: String) throws -> URL {
        let dir = root.appendingPathComponent("segments/\(id)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("events.jsonl")
        try Data(text.utf8).write(to: file)
        return file
    }
    func testCountsOnlyAppendedBytesAndRebuildsAfterReplacementOrTruncation() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try segment(root, text: "one\npart")
        let loader = TraySnapshotLoader()
        let first = await loader.load(root: root)
        XCTAssertEqual(first.status.data.eventCount, 2)
        XCTAssertEqual(first.eventBytesRead, 8)
        let unchanged = await loader.load(root: root)
        XCTAssertEqual(unchanged.eventBytesRead, 0)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("ial\nthree".utf8))
        try handle.close()
        let appended = await loader.load(root: root)
        XCTAssertEqual(appended.eventBytesRead, 9)
        XCTAssertEqual(appended.status.data.eventCount, 3)
        try Data("x\n".utf8).write(to: file)
        let truncated = await loader.load(root: root)
        XCTAssertEqual(truncated.status.data.eventCount, 1)
        XCTAssertEqual(truncated.eventBytesRead, 2)
        try Data("a\nb\nc\n".utf8).write(to: file, options: .atomic)
        let replaced = await loader.load(root: root)
        XCTAssertEqual(replaced.status.data.eventCount, 3)
        XCTAssertEqual(replaced.eventBytesRead, 6)
        try FileManager.default.removeItem(at: file.deletingLastPathComponent())
        let deleted = await loader.load(root: root)
        XCTAssertEqual(deleted.status.data.eventCount, 0)
    }
    func testSealedMetadataAndMemoryCacheInvalidate() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try segment(root, text: "a\nb\n")
        let metadata = file.deletingLastPathComponent().appendingPathComponent("metadata.json")
        try Data(#"{"eventCount":2}"#.utf8).write(to: metadata)
        let dir = root.appendingPathComponent("memories")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let memory = dir.appendingPathComponent("2026-10-16T00-00-00Z-1234-10min-memory-summary.md")
        try "---\ntitle: first\ndescription: fixture\napplications: [com.example.app]\n---\n### body\ntext".write(to: memory, atomically: true, encoding: .utf8)
        let loader = TraySnapshotLoader()
        let first = await loader.load(root: root)
        XCTAssertEqual(first.eventBytesRead, 0)
        XCTAssertEqual(first.memoriesParsed, 1)
        XCTAssertEqual(first.status.memories.pendingSegments, 0)
        let unchanged = await loader.load(root: root)
        XCTAssertEqual(unchanged.memoriesParsed, 0)
        XCTAssertEqual(unchanged.groups, first.groups)
        try "---\ntitle: rewritten\ndescription: new fixture\n---".write(to: memory, atomically: true, encoding: .utf8)
        let rewritten = await loader.load(root: root)
        XCTAssertEqual(rewritten.memoriesParsed, 1)
        XCTAssertEqual(rewritten.groups.first?.items.first?.title, "rewritten")
        try Data("invalid".utf8).write(to: metadata)
        let fallback = await loader.load(root: root)
        XCTAssertEqual(fallback.eventBytesRead, 4)
        XCTAssertEqual(fallback.status.data.eventCount, 2)
        let cached = await loader.load(root: root)
        XCTAssertEqual(cached.eventBytesRead, 0)
        try FileManager.default.removeItem(at: memory)
        let deleted = await loader.load(root: root)
        XCTAssertTrue(deleted.groups.isEmpty)
        XCTAssertEqual(deleted.status.memories.pendingSegments, 1)
    }
    func testRefreshRequestsCoalesceAndCanBeCancelled() {
        var state = TrayRefreshState()
        XCTAssertTrue(state.request())
        for _ in 0..<100 { XCTAssertFalse(state.request()) }
        XCTAssertTrue(state.finished())
        XCTAssertFalse(state.finished())
        XCTAssertTrue(state.request())
        state.cancel()
        XCTAssertTrue(state.request())
    }

    func testLargeHistoryBenchmark() async throws {
        guard ProcessInfo.processInfo.environment["COMPUTER_HISTORY_TRAY_BENCHMARK"] == "1" else {
            throw XCTSkip("设置 COMPUTER_HISTORY_TRAY_BENCHMARK=1 运行约 1.5 GiB 合成基准")
        }
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        // 120 段，每段 12.5 MiB；单行仍是本项目能解析的合成事件。
        let event = EventStreamRecord(id: 1, timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            kind: .windowChanged, app: .init(bundleIdentifier: "com.example.fixture"),
            window: .init(title: String(repeating: "x", count: 4096)), mouse: nil, keyboard: nil, selection: nil, ax: nil)
        var line = try EventStreamJSON.makeEncoder().encode(event)
        line.append(10)
        let repetitions = 13_107_200 / line.count
        var block = Data()
        for _ in 0..<repetitions { block.append(line) }
        let memoryDir = root.appendingPathComponent("memories")
        try FileManager.default.createDirectory(at: memoryDir, withIntermediateDirectories: true)
        var names: [String] = []
        for i in 0..<125 {
            let id = SegmentClock.segmentID(for: Date(timeIntervalSince1970: 1_800_000_000 + Double(i) * 600))
            if i < 120 {
                let file = try segment(root, id: id, text: "")
                try block.write(to: file)
                if i < 119 {
                    try Data("{\"eventCount\":\(repetitions)}".utf8).write(to: file.deletingLastPathComponent().appendingPathComponent("metadata.json"))
                }
            }
            let name = "\(id)-1234-10min-memory-summary.md"
            names.append(name)
            try "---\ntitle: Synthetic \(i)\ndescription: fixture\napplications: [com.example.fixture]\n---\n### detail\n\(String(repeating: "fixture ", count: 400))".write(to: memoryDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try ActivityNarrative(items: (0..<72).map { i in
            .init(id: "n\(i)", timestamp: Date(timeIntervalSince1970: 1_800_000_000 + Double(i) * 600),
                  title: "fixture", summary: "synthetic narrative", apps: [], sourceMemories: [names[i]])
        }).save(root: root)
        let before = Date()
        let baseline = CollectorStatus.read(root: root)
        let baselineTime = Date().timeIntervalSince(before)
        let loader = TraySnapshotLoader()
        let coldStart = Date()
        let cold = await loader.load(root: root)
        let coldTime = Date().timeIntervalSince(coldStart)
        let warmStart = Date()
        let warm = await loader.load(root: root)
        let warmTime = Date().timeIntervalSince(warmStart)
        XCTAssertEqual(cold.status.data.eventCount, baseline.data.eventCount)
        XCTAssertEqual(warm.status.data.eventCount, baseline.data.eventCount)
        XCTAssertEqual(warm.eventBytesRead, 0)
        XCTAssertEqual(warm.memoriesParsed, 0)
        print("TRAY_BENCHMARK bytes=\(baseline.data.bytes) baseline_s=\(baselineTime) cold_s=\(coldTime) warm_s=\(warmTime) cold_bytes=\(cold.eventBytesRead) warm_bytes=\(warm.eventBytesRead) cold_parsed=\(cold.memoriesParsed) warm_parsed=\(warm.memoriesParsed)")
    }
}
