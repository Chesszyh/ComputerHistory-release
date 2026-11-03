import Foundation
import XCTest
@testable import ComputerHistoryCore

final class GenerationPowerTests: XCTestCase {
    func testMaintenanceWakeWithClosedLidRemainsBlocked() throws {
        let state = GenerationPowerState(observingSystem: false, lidClosed: { true })
        state.setSleeping(true)
        state.setSleeping(false)
        XCTAssertFalse(state.canGenerate)
        XCTAssertThrowsError(try state.check())
    }

    func testSleepInvalidatesRequestEvenAfterWake() throws {
        let state = GenerationPowerState(observingSystem: false, lidClosed: { false })
        let revision = try XCTUnwrap(state.snapshot())
        state.setSleeping(true)
        XCTAssertFalse(state.canGenerate)
        state.setSleeping(false)
        XCTAssertTrue(state.canGenerate)
        XCTAssertThrowsError(try state.check(revision))
        XCTAssertNoThrow(try state.check())
    }

    func testSleepingDoesNotCreateRequestOrFailedMemory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = GenerationPowerState(observingSystem: false, lidClosed: { true })
        var client = DeepSeekClient(apiKey: "", baseURL: URL(string: "http://127.0.0.1:1")!)
        client.powerState = state
        XCTAssertThrowsError(try client.complete(system: "synthetic", user: "synthetic", recordingAt: root)) {
            guard case DeepSeekClient.ClientError.sleepDeferred = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let segment = "2020-01-01T00-00-00Z"
        let directory = root.appendingPathComponent("segments/" + segment)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let event = EventStreamRecord(id: 1, timestamp: SegmentClock.date(fromSegmentID: segment)!, kind: .mouseClick,
                                      app: .init(name: "Synthetic", bundleIdentifier: "example.synthetic"))
        try (EventStreamJSON.makeEncoder().encode(event) + Data([10])).write(to: directory.appendingPathComponent("events.jsonl"))
        let generator = MemoryGenerator(rootDirectory: root, memoriesDirectory: root.appendingPathComponent("memories"), client: client)
        XCTAssertThrowsError(try generator.generate(segmentID: segment))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("memories").path).isEmpty)
    }

    func testSleepCancelsInflightRequestWithoutFallbackOrHealthFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", """
        import http.server, pathlib, sys, time
        root = pathlib.Path(sys.argv[1])
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                self.rfile.read(int(self.headers['Content-Length']))
                (root/'received').touch()
                time.sleep(10)
            def log_message(self, *_): pass
        server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
        print(server.server_port, flush=True)
        server.serve_forever()
        """, root.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        defer { process.terminate(); process.waitUntilExit() }
        var line = Data()
        while let byte = try pipe.fileHandleForReading.read(upToCount: 1), !byte.isEmpty, byte != Data([10]) { line.append(byte) }
        let port = try XCTUnwrap(Int(String(decoding: line, as: UTF8.self)))
        let url = URL(string: "http://127.0.0.1:\(port)")!
        let config = ModelSettings(baseURL: url, model: "synthetic", requiresAPIKey: false,
            fallback: .init(baseURL: url, model: "synthetic-fallback", requiresAPIKey: false))
        let state = GenerationPowerState(observingSystem: false, lidClosed: { false })
        var client = DeepSeekClient(apiKey: "", baseURL: url, timeout: 3, settings: config)
        client.powerState = state
        let changed = expectation(description: "sleep after request reached server")
        DispatchQueue.global().async {
            let deadline = Date().addingTimeInterval(4)
            while !FileManager.default.fileExists(atPath: root.appendingPathComponent("received").path), Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            state.setSleeping(true)
            state.setSleeping(false)
            changed.fulfill()
        }
        XCTAssertThrowsError(try client.complete(system: "synthetic", user: "synthetic", recordingAt: root)) {
            guard case DeepSeekClient.ClientError.sleepDeferred = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
        wait(for: [changed], timeout: 5)
        let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("requests"), includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(try ModelRequest.load(url: XCTUnwrap(files.first)).status, "deferred")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("model-health.json").path))
    }
}
