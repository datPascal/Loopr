import Foundation
import Testing
import TrainKit

/// The program rules on a fixed Australia/Perth calendar. Week 3 of the fixture program starts on Monday 2023-11-13.
struct ProgramSchedulerTests {
    private let upper = UUID()
    private let lower = UUID()
    private let scheduler = ProgramScheduler(calendar: Self.perthCalendar)

    private static var perthCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Perth") ?? .gmt
        return calendar
    }

    /// A Perth wall-clock instant on a local day.
    private func at(_ day: String, hour: Int = 9) -> Date {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        return Self.perthCalendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: hour)) ?? .distantPast
    }

    private func program(rules: ProgramRules = .init(), week: [ProgramSlot]? = nil, weeks: Int = 8, startDay: String = "2023-10-30",
                         status: ProgramStatus = .active, adjustments: [ProgramAdjustment] = []) -> Program {
        let slots = week ?? [ProgramSlot(weekday: .monday, templateID: upper, kind: .normal, tag: "UA"),
                             ProgramSlot(weekday: .wednesday, templateID: lower, kind: .heavy, tag: "LA"),
                             ProgramSlot(weekday: .friday, templateID: upper, kind: .normal, tag: "UA")]
        return Program(name: "Strength block", source: .manual, status: status, startDay: startDay,
                       weeks: Array(repeating: slots, count: weeks), rules: rules, adjustments: adjustments)
    }

    private let weekBefore = ["2023-11-06", "2023-11-07", "2023-11-08", "2023-11-09", "2023-11-10", "2023-11-11", "2023-11-12"]

    private func readings(_ days: [String], _ score: Double) -> [RecoveryReading] { days.map { RecoveryReading(localDay: $0, score: score) } }

    private func context(_ day: String, hour: Int = 9, recovery: [RecoveryReading] = [], completed: [CompletedSession] = [],
                         exempt: Set<UUID> = []) -> ProgramScheduler.Context {
        .init(now: at(day, hour: hour), recovery: recovery, completed: completed, lightExemptTemplateIDs: exempt)
    }

    /// The session moves in a plan, ignoring early light week decisions.
    private func moves(_ plan: WeekPlan) -> [ProgramAdjustment] { plan.newAdjustments.filter { $0.kind == .movedSession } }

    private func saved(_ program: Program, _ plan: WeekPlan) -> Program {
        var copy = program
        copy.adjustments += plan.newAdjustments
        return copy
    }

    // MARK: Early light week

    @Test func recoveryAverageOf49TurnsTheWeekLight() {
        let plan = scheduler.evaluate(program: program(), week: 3, context: context("2023-11-13", recovery: readings(weekBefore, 49)))
        #expect(plan.earlyLight == .triggered(average: 49, daysUsed: 7))
        #expect(plan.sessions.map(\.kind) == [.light, .light, .light])
        #expect(plan.sessions.map(\.plannedKind) == [.normal, .heavy, .normal])
        #expect(plan.newAdjustments.count == 1)
        let adjustment = plan.newAdjustments[0]
        #expect(adjustment.kind == .earlyLightWeek && adjustment.week == 3 && adjustment.recoveryScore == 49)
        #expect(adjustment.reason == "Week 3 is lighter. Recovery averaged 49 over the last 7 days.")
        #expect(plan.sessions.allSatisfy { $0.reasons == [.earlyLightWeek(week: 3, averageRecovery: 49, windowDays: 7)] })
    }

    @Test func recoveryAverageOf50LeavesTheWeekAlone() {
        let plan = scheduler.evaluate(program: program(), week: 3, context: context("2023-11-13", recovery: readings(weekBefore, 50)))
        #expect(plan.earlyLight == .notTriggered(average: 50, daysUsed: 7))
        #expect(plan.sessions.map(\.kind) == [.normal, .heavy, .normal])
        // "Not lighter" is stored too, so the week is never decided again.
        #expect(plan.newAdjustments.count == 1)
        let declined = plan.newAdjustments[0]
        #expect(declined.kind == .earlyLightDeclined && declined.week == 3 && declined.recoveryScore == 50 && declined.daysWithReadings == 7)
        #expect(declined.createdAt == at("2023-11-13"))
        #expect(declined.reason == "Week 3 stays as planned. Recovery averaged 50 over the last 7 days.")
    }

    @Test func aMeanJustUnderFiftyTriggersAndShowsAsFortyNine() {
        let scores = zip(weekBefore, [50, 50, 50, 50, 50, 50, 49]).map { RecoveryReading(localDay: $0, score: Double($1)) }
        let plan = scheduler.evaluate(program: program(), week: 3, context: context("2023-11-13", recovery: scores))
        guard case .triggered(let average, _) = plan.earlyLight else { Issue.record("expected a trigger"); return }
        #expect(average < 50)
        #expect(plan.newAdjustments.first?.reason == "Week 3 is lighter. Recovery averaged 49 over the last 7 days.")
    }

    @Test func fewerThanFiveRecoveryDaysLeaveTheWeekAsPlannedAndStoreThat() {
        let plan = scheduler.evaluate(program: program(), week: 3, context: context("2023-11-13", recovery: readings(Array(weekBefore.prefix(4)), 10)))
        #expect(plan.earlyLight == .notEnoughDays(present: 4, needed: 5))
        #expect(plan.sessions.map(\.kind) == [.normal, .heavy, .normal])
        #expect(plan.newAdjustments.count == 1)
        let declined = plan.newAdjustments[0]
        #expect(declined.kind == .earlyLightDeclined && declined.week == 3 && declined.daysWithReadings == 4 && declined.recoveryScore == 10)
        #expect(declined.reason == "Week 3 stays as planned. Only 4 of the last 7 days had a recovery reading.")
        let none = scheduler.evaluate(program: program(), week: 3, context: context("2023-11-13"))
        #expect(none.newAdjustments.first?.recoveryScore == nil && none.newAdjustments.first?.daysWithReadings == 0)
        let five = scheduler.evaluate(program: program(), week: 3, context: context("2023-11-13", recovery: readings(Array(weekBefore.prefix(5)), 10)))
        #expect(five.earlyLight == .triggered(average: 10, daysUsed: 5))
    }

    @Test func readingsOutsideTheSevenDayWindowAreIgnored() {
        let stale = readings(["2023-11-01", "2023-11-02", "2023-11-03", "2023-11-04", "2023-11-05"], 10)
        let plan = scheduler.evaluate(program: program(), week: 3, context: context("2023-11-13", recovery: stale))
        #expect(plan.earlyLight == .notEnoughDays(present: 0, needed: 5))
        // Today's own reading is not part of the window either.
        let today = scheduler.evaluate(program: program(), week: 3, context: context("2023-11-13", recovery: readings(Array(weekBefore.prefix(4)) + ["2023-11-13"], 10)))
        #expect(today.earlyLight == .notEnoughDays(present: 4, needed: 5))
    }

    @Test func theDecisionIsMadeOnceAndStaysStable() {
        let original = program()
        let first = scheduler.evaluate(program: original, week: 3, context: context("2023-11-13", recovery: readings(weekBefore, 49)))
        let stored = saved(original, first)
        // Recomputing with much better recovery on the same day keeps the light week and adds nothing.
        let again = scheduler.evaluate(program: stored, week: 3, context: context("2023-11-13", recovery: readings(weekBefore, 95)))
        #expect(again.sessions == first.sessions)
        #expect(again.newAdjustments.isEmpty)
        #expect(again.earlyLight == .alreadyLight(average: 49))
        // Later the same day with no readings at all, still light.
        let later = scheduler.evaluate(program: stored, week: 3, context: context("2023-11-13", hour: 22))
        #expect(later.sessions == first.sessions)
        #expect(later.newAdjustments.isEmpty)
        // The next week is decided on its own.
        let weekThree = ["2023-11-13", "2023-11-14", "2023-11-15", "2023-11-16", "2023-11-17", "2023-11-18", "2023-11-19"]
        let nextWeek = scheduler.evaluate(program: stored, week: 4, context: context("2023-11-20", recovery: readings(weekThree, 80)))
        #expect(nextWeek.earlyLight == .notTriggered(average: 80, daysUsed: 7))
        #expect(nextWeek.sessions.map(\.kind) == [.normal, .heavy, .normal])
    }

    @Test func openingFirstOnDayThreeStillLightensAQualifyingWeek() {
        // Wednesday. Newer, higher readings do not matter: the window is the seven days before Monday.
        let recent = readings(["2023-11-13", "2023-11-14", "2023-11-15"], 95)
        let plan = scheduler.evaluate(program: program(), week: 3, context: context("2023-11-15", recovery: readings(weekBefore, 49) + recent))
        #expect(plan.earlyLight == .triggered(average: 49, daysUsed: 7))
        #expect(plan.sessions.map(\.kind) == [.light, .light, .light])
        #expect(plan.newAdjustments.first { $0.kind == .earlyLightWeek }?.recoveryScore == 49)
        // The same week opened on Monday gives the same decision.
        let monday = scheduler.evaluate(program: program(), week: 3, context: context("2023-11-13", recovery: readings(weekBefore, 49)))
        #expect(monday.earlyLight == plan.earlyLight)
        // Opened on the last day of the week still decides it.
        let sunday = scheduler.evaluate(program: program(), week: 3, context: context("2023-11-19", recovery: readings(weekBefore, 49)))
        #expect(sunday.earlyLight == plan.earlyLight)
    }

    @Test func aWeekIsNotDecidedBeforeItsFirstSlotDay() {
        let preview = scheduler.evaluate(program: program(), week: 3, context: context("2023-11-12", recovery: readings(weekBefore, 10)))
        #expect(preview.earlyLight == .notDueYet)
        #expect(preview.sessions.map(\.kind) == [.normal, .heavy, .normal] && preview.newAdjustments.isEmpty)
    }

    @Test func theDecisionFollowsTheFirstStrengthSlot() {
        // Monday is cardio and exempt, so the first strength slot is Wednesday and the window ends on 2023-11-14.
        let fiveDays = readings(["2023-11-08", "2023-11-09", "2023-11-10", "2023-11-11", "2023-11-12"], 40)
        let early = scheduler.evaluate(program: program(), week: 3, context: context("2023-11-14", recovery: fiveDays, exempt: [upper]))
        #expect(early.earlyLight == .notDueYet)
        let due = scheduler.evaluate(program: program(), week: 3, context: context("2023-11-15", recovery: fiveDays, exempt: [upper]))
        #expect(due.earlyLight == .triggered(average: 40, daysUsed: 5))
        let allExempt = scheduler.evaluate(program: program(), week: 3, context: context("2023-11-15", recovery: fiveDays, exempt: [upper, lower]))
        #expect(allExempt.earlyLight == .notDueYet && allExempt.newAdjustments.allSatisfy { $0.kind == .movedSession })
    }

    @Test func aDeclinedWeekIsStoredAndNeverDecidedAgain() {
        let original = program()
        let first = scheduler.evaluate(program: original, week: 3, context: context("2023-11-13", recovery: readings(weekBefore, 50)))
        #expect(first.earlyLight == .notTriggered(average: 50, daysUsed: 7))
        let stored = saved(original, first)
        // Much lower recovery afterwards, on the same day or later, does not flip the week.
        let lower = readings(weekBefore, 10)
        for day in ["2023-11-13", "2023-11-14", "2023-11-17"] {
            let again = scheduler.evaluate(program: stored, week: 3, context: context(day, recovery: lower))
            #expect(again.earlyLight == .alreadyDeclined(average: 50, daysWithReadings: 7))
            #expect(again.sessions.allSatisfy { $0.plannedKind == $0.kind })
            #expect(!again.newAdjustments.contains { $0.kind == .earlyLightWeek || $0.kind == .earlyLightDeclined })
        }
    }

    @Test func aWeekWithTooFewReadingsIsNotReDecidedOnLaterData() {
        let original = program()
        let first = scheduler.evaluate(program: original, week: 3, context: context("2023-11-13", recovery: readings(Array(weekBefore.prefix(3)), 10)))
        let stored = saved(original, first)
        // The missing readings arrive late. The window is the same seven days, but the week was already settled.
        let later = scheduler.evaluate(program: stored, week: 3, context: context("2023-11-15", recovery: readings(weekBefore, 10)))
        #expect(later.earlyLight == .alreadyDeclined(average: 10, daysWithReadings: 3))
        #expect(later.sessions.allSatisfy { $0.plannedKind == $0.kind })
        #expect(!later.newAdjustments.contains { $0.kind == .earlyLightWeek || $0.kind == .earlyLightDeclined })
    }

    @Test func aDecisionStaysPutAfterRecomputingWithMovesToo() {
        let original = program()
        let first = scheduler.evaluate(program: original, week: 3, context: context("2023-11-15", recovery: readings(weekBefore, 49)))
        let stored = saved(original, first)
        let again = scheduler.evaluate(program: stored, week: 3, context: context("2023-11-15", hour: 21, recovery: readings(weekBefore, 80)))
        #expect(again.sessions == first.sessions && again.newAdjustments.isEmpty)
    }

    @Test func theRuleCanBeSwitchedOff() {
        let off = program(rules: ProgramRules(earlyLightWeek: false))
        let plan = scheduler.evaluate(program: off, week: 3, context: context("2023-11-13", recovery: readings(weekBefore, 10)))
        #expect(plan.earlyLight == .ruleOff && plan.newAdjustments.isEmpty)
        #expect(plan.sessions.map(\.kind) == [.normal, .heavy, .normal])
    }

    @Test func exemptTemplatesStayAsPlanned() {
        let plan = scheduler.evaluate(program: program(), week: 3, context: context("2023-11-13", recovery: readings(weekBefore, 30), exempt: [lower]))
        #expect(plan.sessions.map(\.kind) == [.light, .heavy, .light])
        #expect(plan.sessions[1].reasons.isEmpty)
    }

    // MARK: Missed sessions

    @Test func moveBackPutsAMissedSessionOnTheNextFreeDay() {
        let plan = scheduler.evaluate(program: program(), week: 3, context: context("2023-11-14"))
        #expect(plan.sessions.map(\.localDay) == ["2023-11-14", "2023-11-15", "2023-11-17"])
        let moved = plan.sessions[0]
        #expect(moved.originalWeekday == .monday && moved.plannedLocalDay == "2023-11-13" && moved.isMoved)
        #expect(moved.reasons == [.movedBack(from: .monday)] && moved.status == .scheduled)
        #expect(moved.reasons[0].message == "Moved from Monday so no day has two sessions.")
        #expect(moves(plan).count == 1)
        let adjustment = moves(plan)[0]
        #expect(adjustment.kind == .movedSession && adjustment.week == 3 && adjustment.weekday == .monday && adjustment.movedToWeekday == .tuesday)
    }

    @Test func moveBackNeverPutsTwoSessionsOnOneDay() {
        // Monday and Wednesday are missed on Thursday. Friday is taken, so they land on Thursday and Saturday.
        let plan = scheduler.evaluate(program: program(), week: 3, context: context("2023-11-16"))
        let days = plan.sessions.map(\.localDay)
        #expect(Set(days).count == days.count)
        #expect(days == ["2023-11-16", "2023-11-17", "2023-11-18"])
        #expect(plan.sessions.map(\.originalWeekday) == [.monday, .friday, .wednesday])
        // From Wednesday, the Wednesday slot itself is still ahead, so Monday moves to Thursday.
        let wednesday = scheduler.evaluate(program: program(), week: 3, context: context("2023-11-15"))
        #expect(wednesday.sessions.map(\.localDay) == ["2023-11-15", "2023-11-16", "2023-11-17"])
        #expect(wednesday.sessions.map(\.originalWeekday) == [.wednesday, .monday, .friday])
        #expect(Set(wednesday.sessions.map(\.localDay)).count == 3)
    }

    @Test func aMovedSessionStaysWhereItWasPutWhenPlannedAgain() {
        let original = program()
        let first = scheduler.evaluate(program: original, week: 3, context: context("2023-11-15"))
        let stored = saved(original, first)
        let same = scheduler.evaluate(program: stored, week: 3, context: context("2023-11-15", hour: 20))
        #expect(same.sessions == first.sessions && same.newAdjustments.isEmpty)
        let before = scheduler.evaluate(program: stored, week: 3, context: context("2023-11-14"))
        #expect(before.sessions.first { $0.originalWeekday == .monday }?.localDay == "2023-11-16")
    }

    @Test func aFinishedSessionDayIsNeverDoubledEither() {
        // Wednesday's lower session was done in the morning, so its day is taken even though its slot is closed.
        let done = [CompletedSession(localDay: "2023-11-15", templateID: lower, programWeek: 3)]
        let plan = scheduler.evaluate(program: program(), week: 3, context: context("2023-11-15", hour: 15, completed: done))
        let monday = plan.sessions.first { $0.originalWeekday == .monday }
        #expect(monday?.localDay == "2023-11-16")
        #expect(plan.sessions.first { $0.originalWeekday == .wednesday }?.status == .completed)
    }

    @Test func completedSessionsAreNotMissed() {
        let done = [CompletedSession(localDay: "2023-11-13", templateID: upper, programWeek: 3)]
        let plan = scheduler.evaluate(program: program(), week: 3, context: context("2023-11-14", completed: done))
        #expect(plan.sessions.first { $0.originalWeekday == .monday }?.status == .completed)
        #expect(plan.sessions.first { $0.originalWeekday == .monday }?.localDay == "2023-11-13")
        #expect(moves(plan).isEmpty)
        // One finished upper session covers only one of the two upper slots.
        let later = scheduler.evaluate(program: program(), week: 3, context: context("2023-11-18", completed: done))
        #expect(later.sessions.filter { $0.status == .completed }.count == 1)
    }

    @Test func noFreeDayLeftMeansTheMissedSessionIsDropped() {
        let crowded = [ProgramSlot(weekday: .monday, templateID: upper), ProgramSlot(weekday: .sunday, templateID: lower)]
        let plan = scheduler.evaluate(program: program(week: crowded), week: 3, context: context("2023-11-19"))
        let monday = plan.sessions.first { $0.originalWeekday == .monday }
        #expect(monday?.status == .skipped && monday?.reasons == [.noFreeDay(weekday: .monday)])
        #expect(moves(plan).isEmpty)
        #expect(plan.sessions.first { $0.originalWeekday == .sunday }?.status == .scheduled)
    }

    @Test func skipDropsTheMissedSessionAndCarriesOn() {
        let skipping = program(rules: ProgramRules(missed: .skip))
        let plan = scheduler.evaluate(program: skipping, week: 3, context: context("2023-11-14"))
        let monday = plan.sessions.first { $0.originalWeekday == .monday }
        #expect(monday?.status == .skipped && monday?.localDay == "2023-11-13" && monday?.reasons == [.missedSkipped(weekday: .monday)])
        #expect(moves(plan).isEmpty)
        #expect(plan.sessions.filter { $0.status == .scheduled }.map(\.localDay) == ["2023-11-15", "2023-11-17"])
        #expect(monday?.reasons[0].message == "Skipped Monday's session and carried on.")
        let mondayPlan = scheduler.resolve(day: "2023-11-13", program: skipping, context: context("2023-11-14"))
        #expect(mondayPlan.sessions.map(\.status) == [.skipped])
        let tuesday = scheduler.resolve(day: "2023-11-14", program: skipping, context: context("2023-11-14"))
        #expect(tuesday.sessions.isEmpty && tuesday.reasons == [.restDay])
    }

    @Test func todaysSessionIsNotMissedYet() {
        let plan = scheduler.evaluate(program: program(), week: 3, context: context("2023-11-13", hour: 23))
        #expect(plan.sessions.allSatisfy { $0.status == .scheduled && !$0.isMoved })
        #expect(moves(plan).isEmpty)
    }

    // MARK: Day resolution

    @Test func aDayResolvesToItsWeekAndSlot() {
        let day = scheduler.resolve(day: "2023-11-15", program: program(), context: context("2023-11-12"))
        #expect(day.week == 3 && day.sessions.count == 1)
        #expect(day.sessions[0].templateID == lower && day.sessions[0].plannedKind == .heavy && day.sessions[0].tag == "LA")
        #expect(day.reasons.isEmpty)
        let rest = scheduler.resolve(day: "2023-11-14", program: program(), context: context("2023-11-12"))
        #expect(rest.week == 3 && rest.sessions.isEmpty && rest.reasons == [.restDay])
        #expect(rest.reasons[0].message == "Nothing planned.")
    }

    @Test func daysOutsideTheProgramHaveNoWeek() {
        let before = scheduler.resolve(day: "2023-10-29", program: program(), context: context("2023-10-29"))
        #expect(before.week == nil && before.reasons == [.beforeStart] && before.sessions.isEmpty)
        // Eight weeks from 2023-10-30 end on 2023-12-24.
        let last = scheduler.resolve(day: "2023-12-24", program: program(), context: context("2023-12-24"))
        #expect(last.week == 8)
        let after = scheduler.resolve(day: "2023-12-25", program: program(), context: context("2023-12-25"))
        #expect(after.week == nil && after.reasons == [.afterEnd])
    }

    @Test func onlyActiveProgramsSchedule() {
        for status in [ProgramStatus.draft, .paused, .completed, .archived] {
            let plan = scheduler.resolve(day: "2023-11-15", program: program(status: status), context: context("2023-11-15"))
            #expect(plan.sessions.isEmpty && plan.reasons == [.notActive])
            #expect(scheduler.evaluate(program: program(status: status), week: 3, context: context("2023-11-15")).sessions.isEmpty)
        }
    }

    @Test func weeksCountInBlocksOfSevenDaysFromTheStartDay() {
        #expect(scheduler.week(containing: "2023-10-30", in: program()) == 1)
        #expect(scheduler.week(containing: "2023-11-05", in: program()) == 1)
        #expect(scheduler.week(containing: "2023-11-06", in: program()) == 2)
        #expect(scheduler.week(containing: "2023-10-29", in: program()) == nil)
        #expect(scheduler.week(containing: "not a day", in: program()) == nil)
        // A program that starts on a Wednesday puts Monday at the end of each block.
        let offset = program(startDay: "2023-11-01")
        let plan = scheduler.evaluate(program: offset, week: 1, context: context("2023-10-31"))
        #expect(plan.sessions.map(\.localDay) == ["2023-11-01", "2023-11-03", "2023-11-06"])
        #expect(plan.sessions.map(\.originalWeekday) == [.wednesday, .friday, .monday])
    }

    @Test func localDayUsesThePerthCalendar() {
        // 2023-11-14 22:13:20 UTC is already the 15th in Perth.
        #expect(scheduler.localDay(for: TrainFixture.date) == "2023-11-15")
        #expect(scheduler.localDay(for: at("2023-11-15", hour: 0)) == "2023-11-15")
        #expect(scheduler.localDay(for: at("2023-11-15", hour: 23)) == "2023-11-15")
    }
}
