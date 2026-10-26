import Foundation
import XCTest
@testable import ComputerHistoryCore

final class TimelineLayoutTests: XCTestCase {
    private func item(_ id: String, _ start: Double, _ end: Double) -> TrayTimelineItem {
        .init(id: id, timestamp: Date(timeIntervalSince1970: start), title: id, summary: "Synthetic activity",
              apps: [], isNarrative: true, memoryFiles: [], coveredCount: 1, eventCount: nil,
              endTimestamp: Date(timeIntervalSince1970: end))
    }

    func testSameTimeAndIntersectingActivitiesFoldWithoutClippingSources() {
        let input = [item("later", 40, 50), item("first", 0, 20), item("nested", 5, 10), item("bridge", 15, 30), item("same", 0, 0)]
        let cards = TimelineLayout.cards(input)
        XCTAssertEqual(cards.count, 2)
        XCTAssertEqual(cards.last?.timestamp, Date(timeIntervalSince1970: 0))
        XCTAssertEqual(cards.last?.endTimestamp, Date(timeIntervalSince1970: 30))
        XCTAssertEqual(cards.last?.children?.count, 4)
        XCTAssertEqual(cards.last!.title, "first(...等4项活动)")
        XCTAssertEqual(cards.flatMap(\.leafItems).first { $0.id == "bridge" }?.endTimestamp, Date(timeIntervalSince1970: 30))
        XCTAssertEqual(TimelineLayout.cards(cards), cards)
    }

    func testTouchingIntervalsRemainSeparateButZeroLengthTiesFold() {
        let cards = TimelineLayout.cards([item("A", 0, 10), item("B", 10, 20), item("C", 30, 30), item("D", 30, 30)])
        XCTAssertEqual(cards.count, 3)
        XCTAssertEqual(cards[0].children?.count, 2)
        XCTAssertEqual(cards[1].id, "B")
    }

    func testAdjacentPassivePeriodsCoalesceWithoutBecomingMultipleActivities() {
        var first = item("passive-1", 0, 600); first.noClearActivity = true
        var second = item("passive-2", 600, 1200); second.noClearActivity = true
        let cards = TimelineLayout.cards([first, second, item("active", 1200, 1800)])
        XCTAssertEqual(cards.count, 2)
        XCTAssertEqual(cards.last?.title, "无明显活动")
        XCTAssertEqual(cards.last?.endTimestamp, Date(timeIntervalSince1970: 1200))
        XCTAssertEqual(cards.last?.children?.count, 2)
    }

    func testContainerIdentitySurvivesAnAdditionalOverlappingActivity() {
        let initial = TimelineLayout.cards([item("A", 0, 20), item("B", 5, 10)])
        let updated = TimelineLayout.cards([item("A", 0, 20), item("B", 5, 10), item("C", 10, 25)])
        XCTAssertEqual(initial[0].id, updated[0].id)
    }

    func testSameTimeHeadingUsesFirstSourceOrderRatherThanAFutureSourceFragment() {
        var first = item("Z-first", 0, 10)
        first.sourceActivities = ["source-a": [1]]
        var later = item("A-later", 0, 20)
        later.sourceActivities = ["source-a": [2], "source-b": [1]]
        XCTAssertTrue(TimelineLayout.cards([later, first])[0].title.hasPrefix("Z-first"))
    }

    func testDeterministicGeneratedIntervalsKeepUniqueIncreasingNonOverlappingTimeAndEveryActivity() {
        var state: UInt64 = 12345
        func random(_ limit: UInt64) -> Double {
            state = state &* 6364136223846793005 &+ 1
            return Double((state >> 32) % limit)
        }
        for run in 0..<100 {
            let input = (0..<60).map { index -> TrayTimelineItem in
                let start = random(4000)
                return item("\(run)-\(index)", start, start + random(80))
            }
            let ascending = TimelineLayout.cards(input.reversed()).reversed()
            XCTAssertEqual(Set(ascending.map(\.timestamp)).count, ascending.count)
            for (left, right) in zip(ascending, ascending.dropFirst()) {
                XCTAssertLessThan(left.timestamp, right.timestamp)
                XCTAssertLessThanOrEqual(left.endTimestamp, right.timestamp)
            }
            XCTAssertEqual(Set(ascending.flatMap(\.leafItems).map(\.id)), Set(input.map(\.id)))
            XCTAssertEqual(ascending.flatMap(\.leafItems).count, input.count)
        }
    }

    func testDeletingContainerDeletesItsChildrenAtomicallyAndKeepsAwayRecord() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var away = item("away", 0, 10); away.isAway = true
        let card = try XCTUnwrap(TimelineLayout.cards([away, item("A", 0, 0), item("B", 1, 2)]).first)
        try TimelineDeletions.delete(card, root: root)
        let trash = try TimelineDeletions.load(root: root)
        XCTAssertEqual(trash.ids, ["narrative:A", "narrative:B"])
        XCTAssertEqual(trash.records.count, 2)
        for record in trash.records { try TimelineDeletions.restore(id: record.id, root: root) }
        XCTAssertTrue(try TimelineDeletions.load(root: root).ids.isEmpty)
    }
}
