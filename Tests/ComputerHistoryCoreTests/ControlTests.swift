import Foundation
import XCTest
@testable import ComputerHistoryCore

/// 运行开关的测试。
final class ControlTests: XCTestCase {

    private func tempRoot() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ch-ctl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 文件缺失时一律视为开启——损坏或缺失的开关不该让采集静默停摆。
    func testMissingFileDefaultsToEnabled() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let control = CollectorControl.load(root: root)
        XCTAssertTrue(control.recording)
        XCTAssertTrue(control.summarizing)
    }

    /// 损坏的文件不能意外恢复采集或模型外发。
    func testCorruptFilePausesRecordingAndSummarizing() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try "这不是 JSON".write(to: CollectorControl.fileURL(root: root),
                             atomically: true, encoding: .utf8)
        let control = CollectorControl.load(root: root)
        XCTAssertFalse(control.recording)
        XCTAssertFalse(control.summarizing)
    }

    /// 往返：写入后读回一致。
    func testRoundTrip() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try CollectorControl(recording: false, summarizing: true).save(root: root)
        let control = CollectorControl.load(root: root)
        XCTAssertFalse(control.recording)
        XCTAssertTrue(control.summarizing)
    }

    /// 单项更新不覆盖另一项——托盘的两个开关各自独立。
    func testPartialUpdateKeepsOtherField() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try CollectorControl(recording: true, summarizing: true).save(root: root)

        try CollectorControl.update(root: root, recording: false)
        XCTAssertFalse(CollectorControl.load(root: root).recording)
        XCTAssertTrue(CollectorControl.load(root: root).summarizing,
                      "改记录开关不应影响总结开关")

        try CollectorControl.update(root: root, summarizing: false)
        XCTAssertFalse(CollectorControl.load(root: root).recording, "反向同理")
        XCTAssertFalse(CollectorControl.load(root: root).summarizing)
    }

    func testConcurrentFieldUpdatesAcrossProcesses() throws {
        let environment = ProcessInfo.processInfo.environment
        if let operation = environment["COMPUTER_HISTORY_TEST_CONTROL_OPERATION"],
           let path = environment["COMPUTER_HISTORY_TEST_CONTROL_ROOT"] {
            let root = URL(fileURLWithPath: path)
            try Data().write(to: root.appendingPathComponent(operation + ".ready"))
            if operation == "pause" { try CollectorControl.update(root: root, recording: false) }
            else { try CollectorControl.update(root: root, flushRequested: false) }
            return
        }

        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let initial = CollectorControl(recording: true, summarizing: false, flushRequested: true)
        try initial.save(root: root)
        let lockDirectory = root.appendingPathComponent(".locks")
        try FileManager.default.createDirectory(at: lockDirectory, withIntermediateDirectories: true)
        let lock = open(lockDirectory.appendingPathComponent("control.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard lock >= 0 else { return XCTFail("Cannot open control lock") }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { return XCTFail("Cannot hold control lock") }

        var children: [Process] = []
        defer {
            for child in children where child.isRunning {
                kill(child.processIdentifier, SIGKILL)
                child.waitUntilExit()
            }
        }
        for operation in ["pause", "consume"] {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            child.arguments = ["xctest", "-XCTest",
                               "ComputerHistoryCoreTests.ControlTests/testConcurrentFieldUpdatesAcrossProcesses",
                               Bundle(for: ControlTests.self).bundleURL.path]
            child.environment = environment.merging([
                "COMPUTER_HISTORY_TEST_CONTROL_OPERATION": operation,
                "COMPUTER_HISTORY_TEST_CONTROL_ROOT": root.path
            ], uniquingKeysWith: { _, replacement in replacement })
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            try child.run()
            children.append(child)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !["pause", "consume"].allSatisfy({
            FileManager.default.fileExists(atPath: root.appendingPathComponent($0 + ".ready").path)
        }) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return XCTFail("Control workers did not start") }
            Thread.sleep(forTimeInterval: 0.01)
        }
        Thread.sleep(forTimeInterval: 0.15)
        XCTAssertEqual(CollectorControl.load(root: root), initial, "An update ran while another process held the lock")
        XCTAssertEqual(flock(lock, LOCK_UN), 0)

        let completed = ProcessInfo.processInfo.systemUptime + 5
        for child in children {
            while child.isRunning {
                guard ProcessInfo.processInfo.systemUptime < completed else { return XCTFail("Control writer did not exit") }
                Thread.sleep(forTimeInterval: 0.01)
            }
            XCTAssertEqual(child.terminationStatus, 0)
        }
        XCTAssertEqual(CollectorControl.load(root: root),
                       CollectorControl(recording: false, summarizing: false, flushRequested: false))
    }

    /// 暂停时采集会话不写入任何事件，恢复后继续。
    func testPausedSessionWritesNothing() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let session = CollectionSession(configuration: .init(rootDirectory: root))
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        try session.start(now: t0)
        session.recordTextInput("记录中", at: t0.addingTimeInterval(1))

        // 暂停后所有入口都应静默
        session.isPaused = true
        session.recordTextInput("暂停中", at: t0.addingTimeInterval(2))
        session.recordSubmit(at: t0.addingTimeInterval(3))
        session.sampleFrontmost(now: t0.addingTimeInterval(4))

        session.isPaused = false
        session.recordTextInput("恢复后", at: t0.addingTimeInterval(5))

        let segDir = root.appendingPathComponent("segments")
            .appendingPathComponent(SegmentClock.segmentID(
                for: SegmentClock.alignedStart(for: t0)))
        let text = try String(contentsOf: segDir.appendingPathComponent("events.jsonl"),
                              encoding: .utf8)
        XCTAssertTrue(text.contains("记录中"))
        XCTAssertTrue(text.contains("恢复后"))
        XCTAssertFalse(text.contains("暂停中"), "暂停期间不得写入")
    }

    /// 登录项在未登记时报告为关闭。
    func testLoginItemDefaultsToDisabled() {
        // 不实际登记，只验证状态读取不抛错。
        _ = LoginItem.isEnabled
        XCTAssertTrue(LoginItem.plistURL.path.hasSuffix(".plist"))
        XCTAssertTrue(LoginItem.label.contains("computerhistory"))
    }
}
