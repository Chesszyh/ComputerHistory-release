import XCTest
@testable import ComputerHistoryCore

final class SummarySettingsTests: XCTestCase {
    func testDefaultsOverridesAndRestoreAcrossReloads() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var settings = try SummarySettings.load(root: root)
        for stage in SummarySettings.Stage.allCases { XCTAssertEqual(settings[stage], stage.defaultPrompt) }
        settings[.tenMinute] = "合成提示词"
        settings[.narrative] = "合成活动整理提示词"
        try settings.save(root: root)
        var loaded = try SummarySettings.load(root: root)
        XCTAssertEqual(loaded[.tenMinute], "合成提示词")
        XCTAssertEqual(loaded[.narrative], "合成活动整理提示词")
        XCTAssertEqual(loaded[.sixHour], MemoryGenerator.sixHourSystemPrompt)
        loaded[.tenMinute] = SummarySettings.Stage.tenMinute.defaultPrompt
        try loaded.save(root: root)
        let restored = try SummarySettings.load(root: root)
        XCTAssertNil(restored.tenMinutePrompt)
        XCTAssertEqual(restored.narrativePrompt, "合成活动整理提示词")
        loaded[.sixHour] = "  \n"
        XCTAssertThrowsError(try loaded.save(root: root))
        XCTAssertEqual(try SummarySettings.load(root: root), restored)
    }

    func testInvalidConfigurationIsReportedWithoutReplacingIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("summary.json")
        for text in ["{", "[]", #"{"tenMinutePrompt":" "}"#, #"{"narrativePrompt":4}"#,
                     #"{"unknown":"ignored?"}"#] {
            try Data(text.utf8).write(to: file)
            XCTAssertThrowsError(try SummarySettings.load(root: root)) { error in
                XCTAssertTrue(String(describing: error).contains("summary.json"))
            }
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), text)
        }
    }
}
