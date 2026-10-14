import Foundation
import XCTest
@testable import ComputerHistoryCore

final class CollectorProcessTests: XCTestCase {
    func testIdentityIncludesStartTimeAndExecutable() throws {
        let identity = try XCTUnwrap(CollectorProcessIdentity.read(pid: getpid()))
        XCTAssertTrue(identity.matchesLiveProcess)
        let reused = CollectorProcessIdentity(pid: identity.pid,
            startedSeconds: identity.startedSeconds + 1,
            startedMicroseconds: identity.startedMicroseconds,
            executablePath: identity.executablePath)
        XCTAssertFalse(reused.matchesLiveProcess)
        let other = CollectorProcessIdentity(pid: identity.pid,
            startedSeconds: identity.startedSeconds,
            startedMicroseconds: identity.startedMicroseconds, executablePath: "/bin/sleep")
        XCTAssertFalse(other.matchesLiveProcess)
        XCTAssertNil(CollectorProcessIdentity.read(pid: -1))
    }

    func testInstanceLookupRequiresExpectedExecutable() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("instance-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let lease = try CollectorProcessLease(root: root)
        defer { lease.release() }
        try lease.publish()
        let name = URL(fileURLWithPath: lease.identity.executablePath).lastPathComponent
        XCTAssertEqual(CollectorProcessLease.runningIdentity(root: root, executableName: name), lease.identity)
        XCTAssertNil(CollectorProcessLease.runningIdentity(root: root, executableName: "other-executable"))
        lease.release()
        XCTAssertNil(CollectorProcessLease.runningIdentity(root: root, executableName: name))
    }

    func testLeaseExcludesConcurrentCollectorsAndCanBeReacquired() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lease-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try CollectorProcessLease(root: root)
        try first.publish()
        XCTAssertThrowsError(try CollectorProcessLease(root: root))
        let record = try JSONDecoder().decode(CollectorProcessIdentity.self,
            from: Data(contentsOf: root.appendingPathComponent("collector.pid")))
        XCTAssertEqual(record, first.identity)
        first.release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("collector.pid").path))
        let second = try CollectorProcessLease(root: root)
        second.release()
        first.release()
    }
}
