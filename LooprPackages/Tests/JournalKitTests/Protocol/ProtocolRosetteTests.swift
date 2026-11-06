import CoreGraphics
import DomainKit
import Foundation
import JournalKit
import RoutineKit
import XCTest

/// LV-07.1: the rosette's layout and the mapping from checks to dots.
final class ProtocolRosetteTests: XCTestCase {
    private typealias Fixture = ProtocolTestData

    // MARK: Layout

    func testUpToEightDotsShareOneRingAndNineToSixteenSplitOverTwo() {
        for count in 2...8 { XCTAssertEqual(ProtocolRosetteLayout.rings(count: count).inner, 0, "\(count)") }
        XCTAssertEqual(ProtocolRosetteLayout.rings(count: 9).outer, 6)
        XCTAssertEqual(ProtocolRosetteLayout.rings(count: 9).inner, 3)
        XCTAssertEqual(ProtocolRosetteLayout.rings(count: 14).outer, 9)
        XCTAssertEqual(ProtocolRosetteLayout.rings(count: 16).outer, 10)
        XCTAssertEqual(ProtocolRosetteLayout.rings(count: 16).inner, 6)
        for count in 1...16 {
            let rings = ProtocolRosetteLayout.rings(count: count)
            XCTAssertEqual(rings.outer + rings.inner, count)
        }
    }

    func testPositionsMatchTheCountAndAreCappedAtSixteen() {
        let center = CGPoint(x: 25, y: 35)
        for count in 0...16 {
            XCTAssertEqual(ProtocolRosetteLayout.positions(count: count, center: center, radius: 15).count, count)
        }
        XCTAssertEqual(ProtocolRosetteLayout.positions(count: 22, center: center, radius: 15).count, 16)
        XCTAssertEqual(ProtocolRosetteLayout.positions(count: 1, center: center, radius: 15), [center])
    }

    func testTheFirstDotSitsAtTwelveOClockAndDotsOnARingNeverTouch() {
        let center = CGPoint(x: 0, y: 0)
        let eight = ProtocolRosetteLayout.positions(count: 8, center: center, radius: 15)
        XCTAssertEqual(eight[0].x, 0, accuracy: 0.0001)
        XCTAssertEqual(eight[0].y, -15, accuracy: 0.0001)
        XCTAssertGreaterThan(eight[1].x, 0, "Dots run clockwise")
        for count in 2...16 {
            let points = ProtocolRosetteLayout.positions(count: count, center: center, radius: 15)
            let dot = ProtocolRosetteLayout.dotRadius(count: count, radius: 15)
            for (i, a) in points.enumerated() {
                for b in points[(i + 1)...] {
                    XCTAssertGreaterThan(hypot(a.x - b.x, a.y - b.y), dot * 2, "\(count) dots overlap")
                }
            }
        }
    }

    // MARK: State mapping

    func testStatesMapToDotsAndAGapIsNeverAMiss() {
        XCTAssertEqual(ProtocolDotState.from(.kept, phase: .today), .kept)
        XCTAssertEqual(ProtocolDotState.from(.missed, phase: .past), .missed)
        XCTAssertEqual(ProtocolDotState.from(.pending, phase: .today), .pending)
        XCTAssertEqual(ProtocolDotState.from(.unknown, phase: .today), .unknown)
        XCTAssertEqual(ProtocolDotState.from(nil, phase: .today), .pending)
        XCTAssertEqual(ProtocolDotState.from(nil, phase: .past), .unknown)
        XCTAssertEqual(ProtocolDotState.from(.pending, phase: .past), .unknown)
        XCTAssertEqual(ProtocolDotState.from(.skipped, phase: .past), .skipped, "A skip is its own dot, never a miss")
    }

    func testADayDrawsTimedRulesAndDecidedOnesTimedFirst() {
        let dots = ProtocolRosetteRules.dots(for: Fixture.tuesday)
        XCTAssertEqual(dots.map(\.ruleKey.rawValue), ["light", "caffeine", "meal", "magnesium", "screens", "bed", "zone2", "training"])
        XCTAssertEqual(dots.map(\.state), [.kept, .kept, .kept, .pending, .pending, .pending, .kept, .kept])
        XCTAssertFalse(dots.contains { $0.ruleKey == "alcohol" || $0.ruleKey == "stretch" },
                       "An untimed rule shows once it is decided")
    }

    /// ICP R1-DES-05: a day ahead is one small dot in the week view, not a ring of empty outlines.
    func testFutureDaysDrawNoRuleDots() {
        XCTAssertTrue(ProtocolRosetteRules.dots(for: Fixture.input(16, .future, ["zone2": .kept])).isEmpty)
        XCTAssertEqual(ProtocolDayPresentation.make(Fixture.input(16, .future, [:]), week: Fixture.calendar).total, 10,
                       "The spoken count still names every rule ahead")
    }

    func testASkippedUntimedRuleDrawsAndIsSpoken() {
        let today = Fixture.input(14, .today, ["stretch": .skipped, "light": .kept])
        XCTAssertTrue(ProtocolRosetteRules.dots(for: today).contains { $0.ruleKey == "stretch" && $0.state == .skipped })
        XCTAssertEqual(ProtocolDayPresentation.make(today, week: Fixture.calendar).accessibilitySummary,
                       "Today, Tuesday, 1 of 10 rules kept, 8 pending, 1 skipped")
    }

    func testDaysBeforeTheProtocolDrawOnlyStoredChecks() {
        XCTAssertTrue(ProtocolRosetteRules.dots(for: Fixture.input(13, .beforeProtocol, [:])).isEmpty)
        let migrated = ProtocolRosetteRules.dots(for: Fixture.input(13, .beforeProtocol, ["stretch": .kept]))
        XCTAssertEqual(migrated.map(\.ruleKey), ["stretch"])
    }

    func testAProtocolOfMoreThanSixteenRulesDrawsSixteenAndCountsThemAll() {
        let rules = (0..<20).map { ProtocolRule(key: RuleKey(rawValue: "r\($0)"), title: "Rule \($0)", timeOfDayMinutes: 60 + $0) }
        let input = ProtocolDayInput(day: Fixture.day(14), phase: .today, rules: rules.map { ProtocolRuleDay(rule: $0, state: .kept) })
        XCTAssertEqual(ProtocolRosetteRules.dots(for: input).count, 16)
        let day = ProtocolDayPresentation.make(input, week: Fixture.calendar)
        XCTAssertEqual(day.dots.count, 16)
        XCTAssertEqual(day.kept, 20)
    }

    // MARK: Days

    /// ICP R2-UPG-4: the spoken count takes every rule, as the header does, though an open all-day rule draws no dot.
    func testTodaySaysWhatItHoldsAndPulsesUntilEveryRuleIsDecided() {
        let today = ProtocolDayPresentation.make(Fixture.tuesday, week: Fixture.calendar)
        XCTAssertEqual(today.accessibilitySummary, "Today, Tuesday, 5 of 10 rules kept, 5 pending")
        XCTAssertEqual(today.identifierKey, "tuesday")
        XCTAssertEqual(today.letter, "T")
        XCTAssertTrue(today.pulses)
        let done = ProtocolDayPresentation.make(Fixture.input(14, .today, ["light": .kept, "caffeine": .kept, "meal": .missed,
            "magnesium": .kept, "screens": .kept, "bed": .unknown]), week: Fixture.calendar)
        XCTAssertFalse(done.pulses, "A day with no open dot stops pulsing, though an all-day rule is still counting")
        XCTAssertEqual(done.accessibilitySummary, "Today, Tuesday, 4 of 10 rules kept, 1 not kept, 4 pending, 1 not known")
    }

    func testPastFutureAndEarlyDaysReadPlainly() {
        let thursday = ProtocolDayPresentation.make(Fixture.input(16, .past, ["light": .kept, "caffeine": .kept, "meal": .kept,
            "magnesium": .kept, "screens": .kept, "bed": .kept, "zone2": .missed, "training": .missed]), week: Fixture.calendar)
        XCTAssertEqual(thursday.accessibilitySummary, "Thursday, 6 of 10 rules kept, 2 not kept, 2 not known")
        XCTAssertFalse(thursday.pulses)
        XCTAssertEqual(ProtocolDayPresentation.make(Fixture.input(18, .future, [:]), week: Fixture.calendar).accessibilitySummary,
                       "Saturday, 10 rules ahead", "A day ahead counts every rule, as the header does (R3-UPG-6)")
        XCTAssertEqual(ProtocolDayPresentation.make(Fixture.input(13, .beforeProtocol, [:]), week: Fixture.calendar).accessibilitySummary,
                       "Monday, before your protocol started")
    }

    /// ICP R2-OPT-29, R1-DES-12: a tapped day lists every rule with its state, without a week count per row.
    func testADayListsItsRules() {
        let monday = Fixture.input(13, .past, ["light": .kept, "caffeine": .kept, "meal": .kept, "bed": .missed])
        let rows = ProtocolDayRules.rows(for: monday, locale: Locale(identifier: "en_GB"))
        XCTAssertEqual(rows.count, Fixture.rules.count)
        XCTAssertEqual(rows.first { $0.ruleKey == "bed" }?.stateText, "Not kept")
        XCTAssertEqual(rows.first { $0.ruleKey == "stretch" }?.stateText, "Not known")
        let saturday = ProtocolDayRules.rows(for: Fixture.input(18, .future, [:]))
        XCTAssertTrue(saturday.allSatisfy { $0.stateText == "Ahead" && !$0.canChange && $0.detail == nil })
    }

    func testTheDaySheetTitleCarriesTheDate() {
        XCTAssertEqual(Fixture.calendar.dayTitle(Fixture.day(13)), "Monday 13 Nov")
    }

    func testTheWeekRunsMondayToSundayWhateverTheLocale() {
        let sunday = ProtocolWeekCalendar(timeZone: Fixture.zone, locale: Locale(identifier: "en_US"))
        XCTAssertEqual(sunday.week(containing: Fixture.day(19)), (13...19).map(Fixture.day))
        XCTAssertEqual(sunday.week(containing: Fixture.day(13)).first, Fixture.day(13))
        XCTAssertEqual(sunday.isoWeekday(Fixture.day(19)), 7)
        let german = ProtocolWeekCalendar(timeZone: Fixture.zone, locale: Locale(identifier: "de_DE"))
        XCTAssertEqual(german.weekdayName(Fixture.day(14)), "Dienstag")
        XCTAssertEqual(german.identifierKey(Fixture.day(14)), "tuesday", "Identifiers stay the same in every locale")
    }
}
