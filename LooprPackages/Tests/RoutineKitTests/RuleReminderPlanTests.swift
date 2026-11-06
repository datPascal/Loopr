import DomainKit
import Foundation
import RoutineKit
import StorageKit
import Testing

/// ICP round 4, Q1b and Q5: which days a rule's reminder fires on. A daily rule repeats; a rule that is not daily stays
/// quiet once its period's count is met; a running test's off nights get no reminder.
struct RuleReminderPlanTests {
    /// Wed 15 Nov 2023.
    private let wednesday = DayIdentity(year: 2023, month: 11, day: 15)

    private func day(_ number: Int, month: Int = 11) -> DayIdentity { DayIdentity(year: 2023, month: month, day: number) }

    private let magnesium = ProtocolRule(key: "magnesium", title: "Magnesium", group: .supplements, timeOfDayMinutes: 1_290)
    private let sauna = ProtocolRule(key: "sauna", title: "Sauna", timeOfDayMinutes: 1_080, cadence: .timesAWeek(3))
    private let zone2 = ProtocolRule(key: "zone-2-week", title: "Zone 2, 150 min a week", group: .fitness,
                                     target: RuleTarget(kind: .atLeast, metric: "zone2Minutes", value: 150, unit: "min"),
                                     timeOfDayMinutes: 1_050, source: .band, cadence: RuleCadence(unit: .week))
    private let drinks = ProtocolRule(key: "drinks", title: "At most 3 drinks a week", group: .food,
                                      target: RuleTarget(kind: .atMost, metric: "alcoholDrinks", value: 3),
                                      timeOfDayMinutes: 1_200, source: .food, cadence: RuleCadence(unit: .week))
    private let panel = ProtocolRule(key: "blood-panel", title: "Blood panel", group: .tests, timeOfDayMinutes: 540,
                                     cadence: RuleCadence(unit: .month, every: 3))

    @Test func aDailyRuleRepeatsOnItsDays() {
        #expect(RuleReminderPlan.plan(for: magnesium, today: wednesday, progress: nil, tests: []) == .repeating([]))
        let gym = ProtocolRule(key: "gym", title: "Gym", timeOfDayMinutes: 1_080, cadence: .on([.friday, .monday]))
        #expect(RuleReminderPlan.plan(for: gym, today: wednesday, progress: nil, tests: []) == .repeating([.monday, .friday]))
    }

    /// Q5: "3 times a week" reminds every day until the third, then nothing until Monday.
    @Test func aWeeklyCountRemindsDailyUntilMetThenWaitsForMonday() {
        #expect(RuleReminderPlan.plan(for: sauna, today: wednesday, progress: .times(done: 2, target: 3), tests: []) == .repeating([]))
        #expect(RuleReminderPlan.plan(for: sauna, today: wednesday, progress: nil, tests: []) == .repeating([]),
                "nothing known never silences a reminder")
        let met = RuleReminderPlan.plan(for: sauna, today: wednesday, progress: .times(done: 3, target: 3), tests: [])
        #expect(met == .days((20...26).map { day($0) }), "next week, Monday to Sunday")
        // Met on a Sunday: the quiet ends the next day.
        let sunday = RuleReminderPlan.plan(for: sauna, today: day(19), progress: .times(done: 3, target: 3), tests: [])
        #expect(sunday == .days((20...26).map { day($0) }))
    }

    /// Q5: what a source checked counts. 150 band minutes meet "150 min a week"; an "at most" rule never ends early.
    @Test func aWeeklyAmountFromASourceCountsAndAnUpperLimitNeverEndsEarly() {
        let open = RuleReminderPlan.plan(for: zone2, today: wednesday, progress: .amount(measured: 112, target: 150, unit: "min"), tests: [])
        #expect(open == .repeating([]))
        let unread = RuleReminderPlan.plan(for: zone2, today: wednesday, progress: .amount(measured: nil, target: 150, unit: "min"), tests: [])
        #expect(unread == .repeating([]), "no reading is not zero and not done")
        let met = RuleReminderPlan.plan(for: zone2, today: wednesday, progress: .amount(measured: 160, target: 150, unit: "min"), tests: [])
        #expect(met == .days((20...26).map { day($0) }))
        let limit = RuleReminderPlan.plan(for: drinks, today: wednesday, progress: .amount(measured: 4, target: 3, unit: nil), tests: [])
        #expect(limit == .repeating([]))
    }

    /// A rule every 3 months, done on 2 Nov, is quiet until 2 Feb, then reminds daily again.
    @Test func aLongerPeriodWaitsForTheNextDueDay() {
        let due = DayIdentity(year: 2024, month: 2, day: 2)
        let done = RuleReminderPlan.plan(for: panel, today: wednesday, progress: .due(lastDone: day(2), next: due), tests: [])
        #expect(done == .days((0..<7).compactMap { due.adding(days: $0) }))
        let never = RuleReminderPlan.plan(for: panel, today: wednesday, progress: .due(lastDone: nil, next: nil), tests: [])
        #expect(never == .repeating([]))
        let overdue = RuleReminderPlan.plan(for: panel, today: wednesday, progress: .due(lastDone: day(2, month: 8), next: day(2)), tests: [])
        #expect(overdue == .repeating([]), "a due day already here keeps the daily reminder")
    }

    /// Q1b: alternate nights from Monday 13 Nov. Wednesday is night 3 (on), Thursday an off night, and so on. The test's
    /// 14 nights end on Sunday 26 Nov, after the plan's week.
    @Test func aRunningTestsOffNightsGetNoReminder() {
        let test = ExperimentSchedule(design: .alternatingDays, washout: 0, plannedNights: 14, startDay: day(13))
        let plan = RuleReminderPlan.plan(for: magnesium, today: wednesday, progress: nil, tests: [test])
        #expect(plan == .days([day(15), day(17), day(19), day(21)]))
        // A test that ends inside the week hands the last days back to the rule's own repeat.
        let ending = ExperimentSchedule(design: .alternatingDays, washout: 0, plannedNights: 4, startDay: day(13))
        #expect(RuleReminderPlan.plan(for: magnesium, today: wednesday, progress: nil, tests: [ending])
                == .days([day(15), day(17), day(18), day(19), day(20), day(21)]))
        // A test that is over, or not this rule's, changes nothing.
        let over = ExperimentSchedule(design: .alternatingDays, washout: 0, plannedNights: 2, startDay: day(1))
        #expect(RuleReminderPlan.plan(for: magnesium, today: wednesday, progress: nil, tests: [over]) == .repeating([]))
    }

    /// A washout night after a switch to off is left out too; one after a switch to on is reminded.
    @Test func washoutNightsFollowTheirArm() {
        // Blocks of 3 from Monday 13 Nov with one washout night: on 13 to 15, off 16 (washout) to 18, on 19 (washout) to 21.
        let test = ExperimentSchedule(design: .blocks(length: 3), washout: 1, plannedNights: 12, startDay: day(13))
        let plan = RuleReminderPlan.plan(for: magnesium, today: wednesday, progress: nil, tests: [test])
        #expect(plan == .days([day(15), day(19), day(20), day(21)]))
    }

    @Test func onlyARuleThePersonTicksTakesAnswers() {
        #expect(RuleReminderPlan.takesAnswers(magnesium))
        #expect(!RuleReminderPlan.takesAnswers(zone2))
    }
}

/// ICP round 4, SEN and VET: an answer from a rule reminder is marked as one, survives the day's next evaluation, and an
/// answer changed in the app loses the mark. Checks written before the mark existed decode unchanged.
struct RuleCheckAnswerOriginTests {
    private final class Context {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RuleCheckOrigin-\(UUID().uuidString)")
        let database: StorageDatabase
        let store: RoutineStore
        init() throws {
            database = try StorageDatabase(url: root.appendingPathComponent("routine.sqlite"), applicationVersion: "origin-tests")
            store = RoutineStore(database: database)
        }
        deinit { try? database.databasePool.close(); try? FileManager.default.removeItem(at: root) }
    }

    private let zone = TimeZone(identifier: "UTC")!
    private let day = DayIdentity(year: 2023, month: 11, day: 14)
    private let created = Date(timeIntervalSince1970: 1_699_900_000)
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func rules() -> [ProtocolRule] {
        [ProtocolRule(key: "magnesium", title: "Magnesium", group: .supplements, timeOfDayMinutes: 1_290, isEvening: true),
         ProtocolRule(key: "screens", title: "Screens off", timeOfDayMinutes: 1_305, isEvening: true)]
    }

    @Test func aCheckWrittenBeforeTheMarkExistedDecodesUnchanged() throws {
        let old = """
            {"day":{"day":14,"era":1,"month":11,"year":2023},"overriddenByPerson":false,"recordedAt":721692800,
             "ruleKey":"magnesium","source":"manual","state":"kept","version":1}
            """
        let check = try JSONDecoder().decode(RuleCheck.self, from: Data(old.utf8))
        #expect(check.answeredFrom == nil && check.state == .kept)
        let future = old.replacingOccurrences(of: "\"version\":1", with: "\"version\":1,\"answeredFrom\":\"watch\"")
        #expect(try JSONDecoder().decode(RuleCheck.self, from: Data(future.utf8)).answeredFrom == nil, "an origin this build does not know")
        let marked = try RuleCheck(ruleKey: "magnesium", day: day, version: 1, state: .kept, source: .manual, recordedAt: now,
                                   answeredFrom: .reminder)
        #expect(try JSONDecoder().decode(RuleCheck.self, from: try JSONEncoder().encode(marked)) == marked)
        #expect(!String(decoding: try JSONEncoder().encode(check), as: UTF8.self).contains("answeredFrom"),
                "an unmarked check keeps its old shape")
    }

    @Test func aReminderAnswerKeepsItsMarkUntilTheAppChangesIt() throws {
        let context = try Context()
        let id = ProtocolID()
        try context.store.createProtocol(RoutineProtocol(id: id, name: "Mine", createdAt: created), rules: rules())
        let evaluation = RoutineDayEvaluation(store: context.store)
        _ = try evaluation.tick(ruleKey: "magnesium", day: day, at: now, answeredFrom: .reminder)
        _ = try evaluation.override(ruleKey: "screens", day: day, state: .skipped, at: now, answeredFrom: .reminder)
        _ = try evaluation.evaluate(day: day, now: now, timeZone: zone, sources: RoutineSourceSnapshots())
        let stored = try context.store.checks(protocolID: id, day: day)
        #expect(stored.map(\.answeredFrom) == [.reminder, .reminder], "the next evaluation keeps both marks")
        #expect(stored.map(\.state) == [.kept, .skipped])

        _ = try evaluation.override(ruleKey: "screens", day: day, state: .kept, at: now)
        #expect(try context.store.check(protocolID: id, ruleKey: "screens", day: day)?.answeredFrom == nil,
                "an answer changed in the app is the app's")
        _ = try evaluation.untick(ruleKey: "magnesium", day: day, now: now, timeZone: zone, sources: RoutineSourceSnapshots())
        _ = try evaluation.tick(ruleKey: "magnesium", day: day, at: now)
        #expect(try context.store.check(protocolID: id, ruleKey: "magnesium", day: day)?.answeredFrom == nil)
    }
}
