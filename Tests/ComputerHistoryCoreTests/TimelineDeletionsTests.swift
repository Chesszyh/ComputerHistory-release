import XCTest
@testable import ComputerHistoryCore

final class TimelineDeletionsTests: XCTestCase {
    func testDeleteDuplicateRefreshRegenerateRestartAndUndo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let memories = root.appendingPathComponent("memories")
        try FileManager.default.createDirectory(at: memories, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = memories.appendingPathComponent("2026-10-16T00-00-00Z-1234-10min-memory-summary.md")
        let memory = "---\ntitle: Synthetic\ndescription: fixture\n---\n### Body\nSynthetic detail"
        try memory.write(to: file, atomically: true, encoding: .utf8)
        let date = Date(timeIntervalSince1970: 1_792_108_800)
        let narrative = ActivityNarrative(items: [
            .init(id: "a", timestamp: date, title: "Source A", summary: "Synthetic", apps: [], sourceMemories: [file.lastPathComponent]),
            .init(id: "b", timestamp: date, title: "Source B", summary: "Synthetic", apps: [], sourceMemories: [file.lastPathComponent])])
        try narrative.save(root: root)
        let loader = TraySnapshotLoader()
        let before = await loader.load(root: root)
        XCTAssertEqual(before.groups.flatMap(\.items).count, 2)
        try TimelineDeletions.delete(before.groups.flatMap(\.items).first { $0.id == "a" }!, root: root)
        let after = await loader.load(root: root)
        XCTAssertEqual(after.groups.flatMap(\.items).map(\.id), ["b"])
        XCTAssertGreaterThan(after.contentVersion, before.contentVersion)
        try narrative.save(root: root)
        let restarted = await TraySnapshotLoader().load(root: root)
        XCTAssertEqual(restarted.groups.flatMap(\.items).map(\.id), ["b"])
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), memory)
        try TimelineDeletions.delete(before.groups.flatMap(\.items).first { $0.id == "b" }!, root: root)
        let empty = await loader.load(root: root)
        XCTAssertTrue(empty.groups.isEmpty, "Deleted narratives must not expose covered memory as a new row")
        try TimelineDeletions.restore(id: "narrative:a", root: root)
        let undone = await loader.load(root: root)
        XCTAssertEqual(undone.groups.flatMap(\.items).map(\.id), ["a"])
        XCTAssertEqual(try TimelineDeletions.load(root: root).records.count, 1)
        try ActivityNarrative().save(root: root)
        let fromSnapshot = await TraySnapshotLoader().load(root: root)
        XCTAssertEqual(fromSnapshot.groups.flatMap(\.items).map(\.id), ["a"], "Restoration must survive loss of the generation cache")
        try TimelineDeletions.purge(id: "narrative:b", root: root)
        let purged = try TimelineDeletions.load(root: root)
        XCTAssertTrue(purged.records.isEmpty)
        XCTAssertTrue(purged.trashEntries(candidates: []).isEmpty)
        XCTAssertThrowsError(try TimelineDeletions.restore(id: "narrative:b", root: root))
        try narrative.save(root: root)
        let regenerated = await TraySnapshotLoader().load(root: root)
        XCTAssertEqual(regenerated.groups.flatMap(\.items).map(\.id), ["a"], "Purged messages must not reappear after generation")

    }

    func testOldDeletionIDsRemainVisibleInTrashAndRestore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"ids":["narrative:old"]}"#.utf8).write(to: root.appendingPathComponent(TimelineDeletions.fileName))
        try ActivityNarrative(items: [.init(id: "old", timestamp: Date(), title: "Legacy deleted summary", summary: "Full text",
            apps: ["synthetic.app"], sourceMemories: [])]).save(root: root)
        let snapshot = await TraySnapshotLoader().load(root: root)
        XCTAssertTrue(snapshot.groups.isEmpty)
        XCTAssertEqual(snapshot.deletedSummaries.first?.item.summary, "Full text")
        let record = try XCTUnwrap(snapshot.deletedSummaries.first)
        try TimelineDeletions.restore(id: record.id, root: root, item: record.item)
        let restored = await TraySnapshotLoader().load(root: root)
        XCTAssertEqual(restored.groups.flatMap(\.items).count, 1)
        XCTAssertTrue(restored.deletedSummaries.isEmpty)
    }

    func testMalformedDeletionFileIsNotOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent(TimelineDeletions.fileName)
        try Data("invalid".utf8).write(to: url)
        XCTAssertThrowsError(try TimelineDeletions.purge(id: "narrative:a", root: root))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "invalid")
    }
}
