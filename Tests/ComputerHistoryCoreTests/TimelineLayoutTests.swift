import Foundation
import XCTest
@testable import ComputerHistoryCore

final class TimelineLayoutTests: XCTestCase {
    private func item(_ id: String, _ start: Double, _ end: Double) -> TrayTimelineItem {
        .init(id: id, timestamp: Date(timeIntervalSince1970: start), title: id, summary: "Synthetic activity",
              apps: [], isNarrative: true, memoryFiles: [], coveredCount: 1, eventCount: nil,
              endTimestamp: Date(timeIntervalSince1970: end))
    }

    func testCrossWindowActivitiesDoNotFoldLaterStartTimes() {
        let base = 13 * 3600.0 + 50 * 60
        let counts = [5, 5, 8, 5, 7, 6, 4, 3]
        let input = counts.enumerated().flatMap { window, count in
            let start = base + Double(window * 600)
            return (0..<count).map { offset in
                item("\(window)-\(offset)", start, start + (offset == 0 ? 1200 : 600))
            }
        }
        let cards = TimelineLayout.cards(input)
        XCTAssertEqual(cards.map(\.timestamp), counts.indices.reversed().map {
            Date(timeIntervalSince1970: base + Double($0 * 600))
        })
        XCTAssertEqual(cards.map { $0.leafItems.count }, Array(counts.reversed()))
        XCTAssertEqual(cards.last?.title, "0-0")
        XCTAssertEqual(cards.last?.summary, "0-1；0-2；0-3")
        XCTAssertEqual(cards.last?.endTimestamp, cards.last?.timestamp)
        XCTAssertEqual(cards.last?.leafItems.first, input.first)
        XCTAssertEqual(TimelineLayout.cards(cards), cards)
    }

    func testNestedActivitiesKeepTheirOwnCardsAndOriginalTimeRanges() {
        let input = [item("outer", 0, 30), item("inner", 5, 10), item("intersecting", 15, 40)]
        XCTAssertEqual(TimelineLayout.cards(input), Array(input.reversed()))
    }

    func testTouchingIntervalsRemainSeparateButZeroLengthTiesFold() {
        let cards = TimelineLayout.cards([item("A", 0, 10), item("B", 10, 20), item("C", 30, 30), item("D", 30, 30)])
        XCTAssertEqual(cards.count, 3)
        XCTAssertEqual(cards[0].children?.count, 2)
        XCTAssertEqual(cards[1].id, "B")
    }

    func testPassivePeriodsAreHiddenWithoutHidingActiveOrDegradedEvidence() {
        var passive = item("passive", 0, 90)
        passive.noClearActivity = true
        var legacy = item("legacy", 90, 95)
        legacy.title = ActivityEvidence.noActivityTitle
        var degraded = item("degraded", 100, 110)
        degraded.title = ActivityEvidence.inputDegradedTitle
        let active = item("active", 105, 120)
        let cards = TimelineLayout.cards([passive, legacy, degraded, active])
        XCTAssertEqual(cards.map(\.id), ["active", "degraded"])
    }

    func testContainerIdentitySurvivesAddingAnActivityWithTheSameStart() {
        let initial = TimelineLayout.cards([item("A", 0, 20), item("B", 0, 10)])
        let updated = TimelineLayout.cards([item("A", 0, 20), item("B", 0, 10), item("C", 0, 25)])
        XCTAssertEqual(initial[0].id, updated[0].id)
        XCTAssertEqual(updated[0].leafItems.count, 3)
    }

    func testSameTimeHeadingUsesFirstSourceFragment() {
        var first = item("Z-first", 0, 10)
        first.sourceActivities = ["source-a": [1]]
        var later = item("A-later", 0, 20)
        later.sourceActivities = ["source-a": [2], "source-b": [1]]
        let card = TimelineLayout.cards([later, first])[0]
        XCTAssertEqual(card.title, "Z-first")
        XCTAssertEqual(card.summary, "A-later")
    }

    func testGeneratedIntervalsKeepUniqueIncreasingStartsAndEveryActivity() {
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
            }
            for card in ascending {
                XCTAssertTrue(card.leafItems.allSatisfy { $0.timestamp == card.timestamp })
            }
            XCTAssertEqual(Set(ascending.flatMap(\.leafItems).map(\.id)), Set(input.map(\.id)))
            XCTAssertEqual(ascending.flatMap(\.leafItems).count, input.count)
        }
    }

    func testDeletingContainerDeletesItsChildrenAtomicallyAndKeepsAwayRecord() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var away = item("away", 0, 10); away.isAway = true
        let card = try XCTUnwrap(TimelineLayout.cards([away, item("A", 0, 0), item("B", 0, 2)]).first)
        try TimelineDeletions.delete(card, root: root)
        let trash = try TimelineDeletions.load(root: root)
        XCTAssertEqual(trash.ids, ["narrative:A", "narrative:B"])
        XCTAssertEqual(trash.records.count, 2)
        for record in trash.records { try TimelineDeletions.restore(id: record.id, root: root) }
        XCTAssertTrue(try TimelineDeletions.load(root: root).ids.isEmpty)
    }
}
