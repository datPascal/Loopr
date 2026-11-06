import DomainKit
import Foundation
import JournalKit
import RoutineKit
import XCTest

/// ICP round 1 (R1-NEW-08, R1-HAB-16): the "checked for you" row counts what the sources decided today and names them,
/// and the header reads the day and the rule count.
final class ProtocolAutoFillTests: XCTestCase {
    private typealias Fixture = ProtocolTestData

    func testTheRowCountsTheRulesASourceDecidedAndNamesTheSources() throws {
        let row = try XCTUnwrap(ProtocolAutoFill.checkedForYou(today: Fixture.tuesday, locale: Fixture.locale))
        XCTAssertEqual(row.count, 4)
        XCTAssertEqual(row.title, "4 checked for you")
        XCTAssertEqual(row.detail, "By Food, Fitness and the band.")
        let items = ProtocolAutoFill.items(today: Fixture.tuesday)
        XCTAssertEqual(items.map(\.ruleKey), ["caffeine", "meal", "zone2", "training"])
        XCTAssertEqual(items.map(\.source), [.food, .food, .band, .fitness])
        XCTAssertFalse(items.contains { $0.ruleKey == "light" }, "A manual tick is the person's, not a source's")
    }

    func testAnAnswerThePersonChangedIsCountedAndNamed() throws {
        let today = Fixture.input(14, .today, ["caffeine": .kept, "meal": .missed], overridden: ["meal"])
        let row = try XCTUnwrap(ProtocolAutoFill.checkedForYou(today: today, locale: Fixture.locale))
        XCTAssertEqual(row.title, "2 checked for you")
        XCTAssertEqual(row.detail, "By Food. You changed 1.")
        XCTAssertEqual(ProtocolAutoFill.items(today: today).first { $0.ruleKey == "meal" }?.overridden, true)
    }

    func testBeforeAnySourceAnswersTheRowSaysWhoWill() throws {
        let today = Fixture.input(14, .today, [:], rules: [Fixture.meal, Fixture.zone2, Fixture.light])
        let row = try XCTUnwrap(ProtocolAutoFill.checkedForYou(today: today, locale: Fixture.locale))
        XCTAssertEqual(row.count, 0)
        XCTAssertEqual(row.title, "None checked for you yet")
        XCTAssertEqual(row.detail, "Food and the band check their rules as the day goes on.")
        XCTAssertNil(ProtocolAutoFill.checkedForYou(today: Fixture.input(14, .today, [:], rules: [Fixture.light])),
                     "A protocol of manual rules has no row")
    }

    func testHeaderMetaReadsDayAndRulesWithoutAVersion() {
        XCTAssertEqual(ProtocolTabModel.headerMeta(day: 21, rules: 10), "Day 21 \u{00B7} 10 rules")
        XCTAssertEqual(ProtocolTabModel.headerMeta(day: 0, rules: 1), "Day 1 \u{00B7} 1 rule")
    }
}
