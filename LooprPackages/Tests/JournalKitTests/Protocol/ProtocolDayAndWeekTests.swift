import DomainKit
import Foundation
@testable import JournalKit
import RoutineKit
import XCTest

/// ICP round 2, W2: "Skip the rest of today", the pattern line, the share pass's kept line and the one counting
/// function the hero and the weekly review share.
@MainActor final class ProtocolDayAndWeekTests: XCTestCase {
    private typealias Fixture = ProtocolTestData

    // MARK: Skip the rest of today (R2-HAB-02, R2-NEW-06, R2-VET-03, R2-DES-11, R3-DES-04, R3-VET-06, R3-NEW-03)

    func testOnlyTheOpenRulesThePersonAnswersAreSkipped() {
        // Tuesday: Food, the band and Fitness decided four rules and Morning light is ticked. Five are open, and three of
        // them the person answers: No alcohol is Food's and In bed the band's, so those wait for their source.
        XCTAssertEqual(ProtocolSkipDay.openRules(today: Fixture.tuesday).map(\.rawValue), ["magnesium", "screens", "stretch"])
        // Kept, not kept and skipped stay; a source that could not tell keeps its rule.
        let mixed = Fixture.input(14, .today, ["light": .missed, "caffeine": .unknown, "meal": .skipped, "alcohol": .kept,
                                               "zone2": .kept, "training": .kept, "magnesium": .kept, "screens": .skipped,
                                               "bed": .pending])
        XCTAssertEqual(ProtocolSkipDay.openRules(today: mixed).map(\.rawValue), ["stretch"])
        // Another day is never skipped this way.
        XCTAssertEqual(ProtocolSkipDay.openRules(today: Fixture.input(13, .past, [:])), [])
        XCTAssertEqual(ProtocolSkipDay.openRules(today: nil), [])
    }

    func testAnOffNightIsLeftAsTheTestSetIt() {
        let rules = Fixture.rules.map { rule in
            ProtocolRuleDay(rule: rule, state: nil, offNightTest: rule.key == "magnesium" ? "magnesium" : nil)
        }
        let today = ProtocolDayInput(day: Fixture.day(14), phase: .today, rules: rules)
        XCTAssertEqual(ProtocolSkipDay.openRules(today: today).map(\.rawValue), ["light", "screens", "stretch"])
    }

    func testARuleThatIsNotDueTodayIsNotSkipped() {
        // A blood panel every 3 months, done on 1 Nov, is next due on 1 Feb. A walk 3 times a week is due until it is
        // kept 3 times in the week.
        let panel = ProtocolRule(key: "panel", title: "Blood panel", cadence: RuleCadence(unit: .month, every: 3))
        let walk = ProtocolRule(key: "walk", title: "Walk", cadence: .timesAWeek(3))
        let rules = Fixture.rules + [panel, walk]
        var states = Fixture.tuesday.rules.reduce(into: [RuleKey: CheckState]()) { $0[$1.rule.key] = $1.state }
        states["panel"] = .pending
        states["walk"] = .pending
        let tuesday = Fixture.input(14, .today, states, rules: rules)
        let progress: [RuleKey: RuleProgress] = ["panel": .due(lastDone: Fixture.day(1), next: DayIdentity(year: 2024, month: 2, day: 1))]
        let monday = Fixture.input(13, .past, ["walk": .kept], rules: rules)
        XCTAssertEqual(ProtocolSkipDay.openRules(today: tuesday, week: [monday, tuesday], progress: progress).map(\.rawValue),
                       ["magnesium", "screens", "stretch", "walk"], "Not the panel, which waits until February")
        // Three kept days this week (the same day stands in for three here) and the walk is done for the week.
        let done = ProtocolSkipDay.openRules(today: tuesday, week: [monday, monday, monday, tuesday], progress: progress)
        XCTAssertEqual(done.map(\.rawValue), ["magnesium", "screens", "stretch"])
    }

    func testTheActionShowsFromTwoOpenRules() {
        XCTAssertFalse(ProtocolSkipDay.shows(openCount: 0, skipped: nil))
        XCTAssertFalse(ProtocolSkipDay.shows(openCount: 1, skipped: nil), "One open card has its own Skip")
        XCTAssertTrue(ProtocolSkipDay.shows(openCount: 2, skipped: nil))
        XCTAssertTrue(ProtocolSkipDay.shows(openCount: 0, skipped: ProtocolSkippedDay(day: Fixture.day(14), keys: ["light"])),
                      "Undo stays while it can take the skip back")
    }

    func testSkipTheRestOfTodaySkipsOnceAndUndoOpensThemAgain() async {
        let source = SkipSource()
        let model = ProtocolTabModel(source: source, habits: HabitViewModel(store: InMemoryHabitStore()),
                                     timeZone: Fixture.zone, locale: Fixture.locale, now: { Fixture.now })
        await model.load()
        XCTAssertEqual(model.skipDayOpenCount, 3)
        XCTAssertEqual(model.skipDayChecking, "Food and the band keep checking their rules.")
        XCTAssertNil(model.skippedToday)

        await model.skipRestOfToday()
        var calls = await source.calls
        XCTAssertEqual(calls, ["skip magnesium", "skip screens", "skip stretch"])
        XCTAssertEqual(model.skippedToday?.keys.map(\.rawValue), ["magnesium", "screens", "stretch"])
        XCTAssertEqual(model.skipDayOpenCount, 0)
        XCTAssertEqual(model.deck.map(\.key), ["bed"], "In bed is an evening rule the band checks; the deck still asks it")
        // The week's share leaves skipped checks out: Tuesday still counts its four decided rules and Morning light.
        XCTAssertEqual(model.summary?.decided, 5)

        // A rule changed by hand after the skip stays as the person set it when Undo runs.
        await model.setAnswer("screens", day: Fixture.day(14), to: .kept)
        XCTAssertEqual(model.skippedToday?.keys.map(\.rawValue), ["magnesium", "stretch"])

        await model.undoSkipRestOfToday()
        calls = await source.calls
        XCTAssertEqual(Array(calls.suffix(2)), ["clear magnesium", "clear stretch"])
        XCTAssertNil(model.skippedToday)
        XCTAssertEqual(model.skipDayOpenCount, 2, "Screens off stays kept, the rest are open again")
        XCTAssertNil(model.errorMessage)
    }

    func testAFailedSkipSaysSoAndKeepsWhatItDid() async {
        let source = SkipSource(failsOn: "screens")
        let model = ProtocolTabModel(source: source, habits: HabitViewModel(store: InMemoryHabitStore()),
                                     timeZone: Fixture.zone, locale: Fixture.locale, now: { Fixture.now })
        await model.load()
        await model.skipRestOfToday()
        XCTAssertEqual(model.skippedToday?.keys.map(\.rawValue), ["magnesium"], "Undo can take back what was skipped")
        XCTAssertTrue(model.errorMessage?.hasPrefix("Loopr could not skip the rest of today.") == true)
    }

    func testTheWordsSayWhatHappensAndCountTheRules() {
        XCTAssertEqual(ProtocolSkipDay.confirmTitle(count: 5), "Skip 5 rules you answer?")
        XCTAssertEqual(ProtocolSkipDay.confirmTitle(count: 1), "Skip 1 rule you answer?")
        XCTAssertEqual(ProtocolSkipDay.confirmButton(count: 5), "Skip 5 rules")
        XCTAssertEqual(ProtocolSkipDay.confirmButton(count: 1), "Skip 1 rule")
        XCTAssertEqual(ProtocolSkipDay.checkingLine(today: Fixture.tuesday, locale: Fixture.locale),
                       "Food and the band keep checking their rules.")
        let foodOnly = Fixture.input(14, .today, ["light": .kept, "caffeine": .kept, "meal": .kept, "zone2": .kept,
                                                  "training": .kept, "bed": .kept])
        XCTAssertEqual(ProtocolSkipDay.checkingLine(today: foodOnly, locale: Fixture.locale), "Food keeps checking its rules.")
        let settled = Fixture.input(14, .today, ["caffeine": .kept, "meal": .kept, "alcohol": .kept, "zone2": .kept,
                                                 "training": .kept, "bed": .missed])
        XCTAssertNil(ProtocolSkipDay.checkingLine(today: settled, locale: Fixture.locale))
        XCTAssertEqual(ProtocolSkipDay.confirmMessage(checking: "Food and the band keep checking their rules."),
                       "Food and the band keep checking their rules. Skipped rules don't count against your week.")
        XCTAssertEqual(ProtocolSkipDay.confirmMessage(checking: nil), "Skipped rules don't count against your week.")
        XCTAssertEqual(ProtocolSkipDay.doneText(count: 1), "1 rule skipped for today.")
        XCTAssertEqual(ProtocolSkipDay.offerText(count: 3), "Rest today. Loopr can skip the 3 rules you still have to answer.")
        for text in [ProtocolSkipDay.confirmMessage(checking: "Food keeps checking its rules."), ProtocolSkipDay.offerText(count: 2),
                     ProtocolSkipDay.actionTitle, ProtocolSkipDay.confirmTitle(count: 2)] {
            XCTAssertFalse(text.contains("\u{2014}"), "No em dash: \(text)")
        }
    }

    func testFeelingSickAndItsCousinsOfferTheSkip() {
        for title in ["Feeling sick", "Sick today?", "Ill", "Feeling unwell", "Flu or a cold", "Fever"] {
            XCTAssertTrue(ProtocolSkipDay.isSickQuestion(title), title)
        }
        for title in ["Screens in bed", "Still hungry", "Billing day", "Alcohol", "Late caffeine"] {
            XCTAssertFalse(ProtocolSkipDay.isSickQuestion(title), title)
        }
    }

    // MARK: Pattern line (R2-HAB-01, R2-NEW-08, R2-SEN-06)

    // The found line's words are tested in ProtocolPatternLineTests (R3-NEW-02).

    func testWithTooFewNightsTheLineSaysHowManyMoreAtLeast() {
        // The nearest habit has 7 nights with and 7 without: 3 + 3 more before both sides reach 10.
        let toGo = ProtocolPatternSignal.nightsToGo([(with: 7, without: 7), (with: 2, without: 9)], perGroup: 10)
        XCTAssertEqual(toGo, 6)
        let gathering = ProtocolPatternSignal.gathering(nightsToGo: toGo, perGroup: 10)
        XCTAssertEqual(gathering.title, "At least 6 more nights before Loopr can compare your sleep with and without a habit.")
        XCTAssertEqual(gathering.detail, "It needs 10 nights with the habit and 10 without.")
        XCTAssertEqual(ProtocolPatternSignal.gathering(nightsToGo: 1, perGroup: 10).title,
                       "At least 1 more night before Loopr can compare your sleep with and without a habit.")
        // Enough nights and still nothing found, or no habit to count at all.
        XCTAssertEqual(ProtocolPatternSignal.gathering(nightsToGo: 0, perGroup: 10).title,
                       "No clear link between a habit and your sleep yet.")
        XCTAssertNil(ProtocolPatternSignal.nightsToGo([], perGroup: 10))
        XCTAssertEqual(ProtocolPatternSignal.gathering(nightsToGo: nil, perGroup: 10).title,
                       "Loopr compares your sleep once a habit has 10 nights with it and 10 without.")
    }

    func testTheLineWaitsForDayThree() async {
        let signal = ProtocolPatternSignal.found(ProtocolPatternFinding(
            sentence: "On the 9 nights after you logged alcohol, your HRV was 8 ms lower than on the other 14."))
        let early = ProtocolTabModel(source: StaticSource(dayNumber: 2, signal: signal), habits: HabitViewModel(store: InMemoryHabitStore()),
                                     timeZone: Fixture.zone, locale: Fixture.locale, now: { Fixture.now })
        await early.load()
        XCTAssertNil(early.patternSignal, "Day 1 and 2 say only what to do tonight")
        let later = ProtocolTabModel(source: StaticSource(dayNumber: 21, signal: signal), habits: HabitViewModel(store: InMemoryHabitStore()),
                                     timeZone: Fixture.zone, locale: Fixture.locale, now: { Fixture.now })
        await later.load()
        XCTAssertEqual(later.patternSignal, signal)
    }

    // MARK: Share pass (R2-VET-11)

    func testThePassSaysTheWeekAndItsChecks() {
        let file = ProtocolFile(name: "My protocol", version: 2, createdAt: Fixture.now, rules: Fixture.rules)
        let data = Data("pass".utf8)
        XCTAssertEqual(ProtocolPass.make(file: file, data: data, keptPercent: 92, checkCount: 13).keptLine,
                       "Kept 92% this week, 13 checks")
        XCTAssertEqual(ProtocolPass.make(file: file, data: data, keptPercent: 100, checkCount: 1).keptLine,
                       "Kept 100% this week, 1 check")
        XCTAssertEqual(ProtocolPass.make(file: file, data: data, keptPercent: nil, checkCount: 2).keptLine, "2 checks this week")
        XCTAssertEqual(ProtocolPass.make(file: file, data: data, keptPercent: nil, checkCount: 0).keptLine, "No answers this week yet")
        XCTAssertEqual(ProtocolPass.make(file: file, data: data, keptPercent: 92).keptLine, "Kept 92% this week")
        XCTAssertEqual(ProtocolPass.make(file: file, data: data, keptPercent: 92, checkCount: 13).countsAccessibilityLabel,
                       "10 rules, 92 percent kept this week over 13 checks, 0 experiments")
    }

    // MARK: One counting function (R2-DES-04, R2-VET-02)

    func testTheHeroCountsTheWeekAsRoutineWeekCountDoes() {
        let monday: [RuleKey: CheckState] = ["light": .kept, "caffeine": .skipped, "meal": .missed, "alcohol": .unknown,
                                             "zone2": .kept, "training": .kept, "magnesium": .kept, "screens": .kept,
                                             "bed": .missed, "stretch": .kept]
        let week = Fixture.week(monday: monday)
        let summary = ProtocolWeekSummary.make(week: week, calendar: Fixture.calendar, dayNumber: 21)
        let count = RoutineWeekCount(states: week.filter { $0.phase != .future }.flatMap(\.rules).map(\.state))
        XCTAssertEqual(summary.kept, count.kept)
        XCTAssertEqual(summary.decided, count.decided)
        XCTAssertEqual(summary.percent, count.percent)
        XCTAssertEqual(count.skipped, 1)
        XCTAssertEqual(count.unknown, 1)
    }
}

/// Tuesday's rules, applying each write to its own copy of the day. `failsOn` makes one skip throw.
private actor SkipSource: ProtocolTabSource {
    private(set) var calls: [String] = []
    private var states: [RuleKey: CheckState] = ["light": .kept, "caffeine": .kept, "meal": .kept, "alcohol": .pending,
        "zone2": .kept, "training": .kept, "magnesium": .pending, "screens": .pending, "bed": .pending, "stretch": .pending]
    private var overridden: Set<RuleKey> = []
    private let failsOn: RuleKey?

    init(failsOn: RuleKey? = nil) { self.failsOn = failsOn }

    func load(now: Date) async -> ProtocolTabContent {
        let today = ProtocolTestData.input(14, .today, states, overridden: overridden)
        let week = [ProtocolTestData.input(13, .past, [:]), today] + (15...19).map { ProtocolTestData.input($0, .future, [:]) }
        return ProtocolTabContent(routine: .ready(ProtocolRoutineData(
            protocolName: "My protocol", version: 1, versionCreatedAt: now, dayNumber: 21, rules: ProtocolTestData.rules,
            week: week, lastWeek: [], today: ProtocolTestData.day(14), nowMinute: 23 * 60)))
    }

    func tick(_ key: RuleKey, day: DayIdentity, now: Date) async throws {
        calls.append("tick \(key.rawValue)"); states[key] = .kept
    }

    func override(_ key: RuleKey, day: DayIdentity, kept: Bool, now: Date) async throws {
        calls.append("override \(key.rawValue)"); states[key] = kept ? .kept : .missed; overridden.insert(key)
    }

    func skip(_ key: RuleKey, day: DayIdentity, now: Date) async throws {
        if key == failsOn { throw RoutineError.invalidOverride }
        calls.append("skip \(key.rawValue)"); states[key] = .skipped; overridden.insert(key)
    }

    func clear(_ key: RuleKey, day: DayIdentity, now: Date) async throws {
        calls.append("clear \(key.rawValue)"); states[key] = .pending; overridden.remove(key)
    }
}

/// A fixed protocol on a given day, with a pattern line.
private struct StaticSource: ProtocolTabSource {
    let dayNumber: Int
    let signal: ProtocolPatternSignal

    func load(now: Date) async -> ProtocolTabContent {
        let week = [ProtocolTestData.input(13, .past, [:]), ProtocolTestData.tuesday] + (15...19).map { ProtocolTestData.input($0, .future, [:]) }
        return ProtocolTabContent(routine: .ready(ProtocolRoutineData(
            protocolName: "My protocol", version: 1, versionCreatedAt: now, dayNumber: dayNumber, rules: ProtocolTestData.rules,
            week: week, lastWeek: [], today: ProtocolTestData.day(14), nowMinute: 23 * 60)),
            patterns: ProtocolPatternsState(isAvailable: true, lines: [], total: 0, signal: signal))
    }

    func tick(_ key: RuleKey, day: DayIdentity, now: Date) async throws {}
    func override(_ key: RuleKey, day: DayIdentity, kept: Bool, now: Date) async throws {}
    func clear(_ key: RuleKey, day: DayIdentity, now: Date) async throws {}
}
