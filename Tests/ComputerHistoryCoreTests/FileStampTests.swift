import Foundation
import XCTest
@testable import ComputerHistoryCore

final class FileStampTests: XCTestCase {
    func testAtomicReplacementWithUnchangedSizeAndTimeChangesIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("synthetic.json")
        try Data("old".utf8).write(to: file)
        let fixedTime = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: fixedTime], ofItemAtPath: file.path)
        let before = try XCTUnwrap(FileStamp(file))
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(before.size, 3)
        XCTAssertEqual(before.modified, fixedTime)
        XCTAssertEqual(before.inode, (attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
        XCTAssertEqual(before.modified.timeIntervalSince1970,
                       (attributes[.modificationDate] as! Date).timeIntervalSince1970, accuracy: 0.000001)
        try Data("new".utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: before.modified], ofItemAtPath: file.path)
        let after = try XCTUnwrap(FileStamp(file))
        XCTAssertEqual(after.size, before.size)
        XCTAssertEqual(after.modified, before.modified)
        XCTAssertNotEqual(after.inode, before.inode)
        XCTAssertNotEqual(after, before)
        try FileManager.default.removeItem(at: file)
        XCTAssertNil(FileStamp(file))
    }
}
