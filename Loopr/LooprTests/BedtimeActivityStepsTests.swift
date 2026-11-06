import DomainKit
import Foundation
import RoutineKit
import Testing

@testable import Loopr

/// The evening rules as steps: which rules, in what order, what counts as done, and what never reaches the lock screen.
struct BedtimeActivityStepsTests {
    private let calendar = BedtimeActivityWindowTests.calendar()
    private let day = DayIdentity(year: 2026, month: 10, day: 24)

    private var evening: BedtimeEvening {
        BedtimeActivityWindow.evening(
            startingOn: BedtimeActivityWindowTests.date(2026, 10, 24, 9, in: calendar),
            bedtimeMinute: 22 * 60 + 30, calendar: calendar)!
    }

    private func rule(_ key: String, _ title: String, minute: Int? = nil, evening: Bool = true) -> ProtocolRule {
        ProtocolRule(key: RuleKey(rawValue: key), title: title, group: .sleep, timeOfDayMinutes: minute, isEvening: evening)
    }

    private func check(_ key: String, _ state: CheckState, value: Double? = nil) throws -> RuleCheck {
        try RuleCheck(ruleKey: RuleKey(rawValue: key), day: day, version: 1, state: state,
                      source: value == nil ? .manual : .food, measuredValue: value,
                      recordedAt: BedtimeActivityWindowTests.date(2026, 10, 24, 19, in: calendar))
    }

    @Test
    func onlyEveningRulesBecomeStepsAndTheInBedRuleIsLeftOut() {
        let inBed = ProtocolRule(key: "in-bed", title: "In bed by 22:30", group: .sleep,
                                 target: RuleTarget(kind: .atMost, metric: RoutineMetric.inBedTime.rawValue, value: 1_350),
                                 source: .band, isEvening: true)
        let steps = BedtimeActivitySteps.steps(
            rules: [rule("zone2", "Zone 2 session", evening: false), rule("wind", "Wind-down", minute: 1_305), inBed],
            checks: [], evening: evening, calendar: calendar)
        #expect(steps.map(\.title) == ["Wind-down"])
    }

    @Test
    func stepsFollowTheClockWithAfterMidnightLastAndUntimedRulesAtTheEnd() {
        let steps = BedtimeActivitySteps.steps(
            rules: [rule("screens", "Screens off"), rule("late", "Lights out", minute: 30), rule("wind", "Wind-down", minute: 1_305),
                    rule("kitchen", "Kitchen closed", minute: 1_100), rule("tie", "Tea", minute: 1_305)],
            checks: [], evening: evening, calendar: calendar)
        #expect(steps.map(\.title) == ["Kitchen closed", "Wind-down", "Tea", "Lights out", "Screens off"])
        #expect(steps.first?.minuteOfDay == 1_100)
        #expect(steps.last?.minuteOfDay == nil && steps.last?.at == nil)
        // 00:30 belongs to the next calendar day.
        #expect(steps[3].at == BedtimeActivityWindowTests.date(2026, 10, 25, 0, 30, in: calendar))
        #expect(steps[0].at == BedtimeActivityWindowTests.date(2026, 10, 24, 18, 20, in: calendar))
    }

    @Test
    func doneComesFromKeptChecksAndEveryOtherStateIsStillToDo() throws {
        let rules = [rule("a", "Kitchen closed", minute: 1_100), rule("b", "Wind-down", minute: 1_305),
                     rule("c", "Screens off", minute: 1_340), rule("d", "Read", minute: 1_345)]
        let steps = BedtimeActivitySteps.steps(
            rules: rules,
            checks: [try check("a", .kept), try check("b", .pending), try check("c", .unknown)],
            evening: evening, calendar: calendar)
        #expect(steps.map(\.status) == [.done, .pending, .pending, .pending])
        #expect(steps.map(\.isDone) == [true, false, false, false])
    }

    @Test
    func aMissedRuleLeavesTheListSoItIsNeverTheNextStepAllNight() throws {
        let rules = [rule("a", "Kitchen closed", minute: 1_100), rule("b", "Wind-down", minute: 1_305)]
        let steps = BedtimeActivitySteps.steps(rules: rules, checks: [try check("a", .missed)], evening: evening, calendar: calendar)
        #expect(steps.map(\.title) == ["Wind-down"])
        let state = BedtimeActivitySteps.contentState(steps: steps, evening: evening,
                                                      now: BedtimeActivityWindowTests.date(2026, 10, 24, 20, in: calendar))
        #expect(state.nextStep?.title == "Wind-down")
    }

    @Test
    func theNextStepIsTheFirstPendingOne() throws {
        let rules = [rule("a", "Kitchen closed", minute: 1_100), rule("b", "Wind-down", minute: 1_305), rule("c", "Screens off")]
        let steps = BedtimeActivitySteps.steps(rules: rules, checks: [try check("a", .kept)], evening: evening, calendar: calendar)
        let state = BedtimeActivitySteps.contentState(steps: steps, evening: evening,
                                                      now: BedtimeActivityWindowTests.date(2026, 10, 24, 19, 49, in: calendar))
        #expect(state.nextStep?.id == "b")
        #expect(state.doneCount == 1)
        let allDone = BedtimeActivitySteps.contentState(
            steps: BedtimeActivitySteps.steps(rules: rules, checks: try ["a", "b", "c"].map { try check($0, .kept) },
                                              evening: evening, calendar: calendar),
            evening: evening, now: BedtimeActivityWindowTests.date(2026, 10, 24, 19, 49, in: calendar))
        #expect(allDone.nextStep == nil)
    }

    @Test
    func progressRunsFromEighteenToBedtimeAndStaysInRange() {
        func progress(_ hour: Int, _ minute: Int, day: Int = 24) -> Double {
            BedtimeActivitySteps.contentState(
                steps: [], evening: evening,
                now: BedtimeActivityWindowTests.date(2026, 10, day, hour, minute, in: calendar)).progress
        }
        #expect(progress(17, 0) == 0)
        #expect(progress(18, 0) == 0)
        #expect(abs(progress(20, 15) - 0.5) < 1e-9)
        #expect(progress(22, 30) == 1)
        #expect(progress(23, 30) == 1)
    }

    @Test
    func theContentStateCarriesNoHealthValues() throws {
        // A kept food rule with a measured amount: the step keeps the title and the tick, not the number.
        let rules = [rule("protein", "Protein by dinner", minute: 1_100)]
        let steps = BedtimeActivitySteps.steps(rules: rules, checks: [try check("protein", .kept, value: 62.5)],
                                               evening: evening, calendar: calendar)
        let state = BedtimeActivitySteps.contentState(steps: steps, evening: evening,
                                                      now: BedtimeActivityWindowTests.date(2026, 10, 24, 19, in: calendar))
        let json = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        #expect(!json.contains("62.5"))
        #expect(!json.lowercased().contains("measured"))
        #expect(!json.lowercased().contains("heart"))
        #expect(steps.first?.title == "Protein by dinner")
        #expect(steps.first?.isDone == true)
    }

    @Test
    func theContentStateRoundTripsAndKeepsEightStepsAtMost() throws {
        let many = (0..<12).map { rule("r\($0)", "Step \($0)", minute: 1_080 + $0) }
        let steps = BedtimeActivitySteps.steps(rules: many, checks: [], evening: evening, calendar: calendar)
        #expect(steps.count == BedtimeActivitySteps.maximumSteps)
        let state = BedtimeActivitySteps.contentState(steps: steps, evening: evening,
                                                      now: BedtimeActivityWindowTests.date(2026, 10, 24, 19, in: calendar))
        let decoded = try JSONDecoder().decode(LooprBedtimeActivityAttributes.ContentState.self, from: JSONEncoder().encode(state))
        #expect(decoded == state)
        #expect(try JSONEncoder().encode(state).count < 4_096)
    }

    @Test
    func theLockScreenShowsTheLastDoneStepThenWhatIsAhead() {
        typealias Step = LooprBedtimeActivityAttributes.ContentState.Step
        let steps = [Step(id: "a", title: "A", minuteOfDay: nil, at: nil, status: .done),
                     Step(id: "b", title: "B", minuteOfDay: nil, at: nil, status: .done),
                     Step(id: "c", title: "C", minuteOfDay: nil, at: nil, status: .pending),
                     Step(id: "d", title: "D", minuteOfDay: nil, at: nil, status: .pending),
                     Step(id: "e", title: "E", minuteOfDay: nil, at: nil, status: .pending)]
        let state = LooprBedtimeActivityAttributes.ContentState(steps: steps, nextStep: steps[2], progress: 0.4)
        #expect(state.visibleSteps(limit: 3).map(\.id) == ["b", "c", "d"])
        #expect(state.visibleSteps(limit: 10).map(\.id) == ["a", "b", "c", "d", "e"])
        let done = LooprBedtimeActivityAttributes.ContentState(steps: steps.map {
            Step(id: $0.id, title: $0.title, minuteOfDay: nil, at: nil, status: .done)
        }, nextStep: nil, progress: 1)
        #expect(done.visibleSteps(limit: 3).map(\.id) == ["c", "d", "e"])
    }
}
