import Foundation
import Testing
import TrainKit

/// The scheduler on the whole fixture program: eight weeks from Monday 2023-10-30, five days a week,
/// lighter weeks 4 and 7, heavy Lower B and Upper B in week 3. Alex, Australia/Perth, "now" is Tuesday 14 November.
struct ProgramSchedulerFixtureTests {
    private typealias T = ProgramTemplates

    private var perth: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Perth") ?? .gmt
        return calendar
    }

    private func at(_ day: String, hour: Int = 10) -> Date {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        return perth.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: hour)) ?? .distantPast
    }

    private func program(rules: ProgramRules = .init(), status: ProgramStatus = .active) -> Program {
        Program(name: "Strength block", source: .agent, status: status, startDay: "2023-10-30",
                weeks: T.weeks(count: 8, full: true), rules: rules)
    }

    private let recoveryDays = ["2023-11-06", "2023-11-07", "2023-11-08", "2023-11-09", "2023-11-10", "2023-11-11", "2023-11-12"]
    private let fixtureScores: [Double] = [64, 58, 71, 49, 66, 73, 61]

    private var fixtureRecovery: [RecoveryReading] {
        zip(recoveryDays, fixtureScores).map { RecoveryReading(localDay: $0, score: $1) } + [RecoveryReading(localDay: "2023-11-14", score: 79)]
    }

    private let mondayDone = CompletedSession(localDay: "2023-11-13", templateID: T.lowerA.id, programWeek: 3)

    private func context(_ day: String = "2023-11-14", recovery: [RecoveryReading]? = nil, completed: [CompletedSession]? = nil) -> ProgramScheduler.Context {
        .init(now: at(day), recovery: recovery ?? fixtureRecovery, completed: completed ?? [mondayDone], lightExemptTemplateIDs: [T.zone.id])
    }

    private var scheduler: ProgramScheduler { ProgramScheduler(calendar: perth) }

    // MARK: Week 3

    @Test func weekThreeLaysOutTheFixtureOnRealDays() {
        let plan = scheduler.evaluate(program: program(), week: 3, context: context())
        #expect(plan.sessions.map(\.localDay) == ["2023-11-13", "2023-11-14", "2023-11-15", "2023-11-16", "2023-11-18"])
        #expect(plan.sessions.map(\.templateID) == [T.lowerA.id, T.upper.id, T.zone.id, T.lowerB.id, T.upperB.id])
        #expect(plan.sessions.map(\.kind) == [.normal, .normal, .normal, .heavy, .heavy])
        #expect(plan.sessions.map(\.status) == [.completed, .scheduled, .scheduled, .scheduled, .scheduled])
        #expect(plan.sessions.map(\.startMinute) == [nil, 18 * 60, nil, nil, nil])
        #expect(plan.sessions.allSatisfy { !$0.isMoved })
    }

    @Test func fixtureRecoveryAveragesSixtyThreeSoTheWeekStaysAsPlanned() throws {
        let plan = scheduler.evaluate(program: program(), week: 3, context: context())
        guard case .notTriggered(let average, let days) = plan.earlyLight else { Issue.record("expected notTriggered, got \(plan.earlyLight)"); return }
        #expect(days == 7 && abs(average - 63.142857) < 0.001)
        let adjustment = try #require(plan.newAdjustments.first)
        #expect(plan.newAdjustments.count == 1 && adjustment.kind == .earlyLightDeclined && adjustment.week == 3 && adjustment.daysWithReadings == 7)
    }

    @Test func lowRecoveryMakesTheStrengthDaysLightAndLeavesCardioAlone() throws {
        let low = recoveryDays.map { RecoveryReading(localDay: $0, score: 40) }
        let plan = scheduler.evaluate(program: program(), week: 3, context: context(recovery: low))
        #expect(plan.sessions.map(\.kind) == [.light, .light, .normal, .light, .light])
        #expect(plan.sessions.map(\.plannedKind) == [.normal, .normal, .normal, .heavy, .heavy])
        let adjustment = try #require(plan.newAdjustments.first)
        #expect(adjustment.kind == .earlyLightWeek && adjustment.reason == "Week 3 is lighter. Recovery averaged 40 over the last 7 days.")
        #expect(plan.sessions[1].reasons == [.earlyLightWeek(week: 3, averageRecovery: 40, windowDays: 7)])
    }

    @Test func fewerThanFiveRecoveryDaysDecideNothingAndAreRecorded() {
        let few = Array(recoveryDays.prefix(4)).map { RecoveryReading(localDay: $0, score: 20) }
        let plan = scheduler.evaluate(program: program(), week: 3, context: context(recovery: few))
        #expect(plan.earlyLight == .notEnoughDays(present: 4, needed: 5))
        #expect(plan.sessions.map(\.kind) == [.normal, .normal, .normal, .heavy, .heavy])
        #expect(plan.newAdjustments.map(\.kind) == [.earlyLightDeclined])
    }

    @Test func switchingTheRuleOffLeavesEverythingAsPlanned() {
        let low = recoveryDays.map { RecoveryReading(localDay: $0, score: 10) }
        let plan = scheduler.evaluate(program: program(rules: ProgramRules(earlyLightWeek: false)), week: 3, context: context(recovery: low))
        #expect(plan.earlyLight == .ruleOff && plan.newAdjustments.isEmpty)
        #expect(plan.sessions.map(\.kind) == [.normal, .normal, .normal, .heavy, .heavy])
    }

    @Test func aSavedDecisionIsNeverMadeTwice() {
        let first = scheduler.evaluate(program: program(), week: 3, context: context())
        var saved = program()
        saved.adjustments += first.newAdjustments
        let later = scheduler.evaluate(program: saved, week: 3, context: context("2023-11-14", recovery: recoveryDays.map { RecoveryReading(localDay: $0, score: 5) }))
        #expect(later.newAdjustments.isEmpty)
        #expect(later.sessions.map(\.kind) == first.sessions.map(\.kind))
        #expect(ProgramAdjustmentPlanner.merge(first.newAdjustments, into: saved) == nil)
        let recorded = ProgramAdjustmentPlanner.merge(first.newAdjustments, into: program())
        #expect(recorded?.adjustments.map(\.kind) == [.earlyLightDeclined])
    }

    // MARK: Missed sessions

    @Test func moveBackNeverPutsTwoSessionsOnOneDay() {
        // Thursday 16: Tuesday's Upper A and Wednesday's Zone 2 were not done.
        let plan = scheduler.evaluate(program: program(), week: 3, context: context("2023-11-16"))
        let moved = plan.sessions.filter(\.isMoved)
        let movedIDs = Set(moved.map(\.templateID))
        #expect(movedIDs == Set([T.upper.id, T.zone.id]))
        #expect(plan.sessions.first { $0.templateID == T.upper.id }?.localDay == "2023-11-17")
        let open = plan.sessions.filter { $0.status == .scheduled }.map(\.localDay)
        #expect(Set(open).count == open.count && open.allSatisfy { $0 >= "2023-11-16" })
        #expect(plan.newAdjustments.filter { $0.kind == .movedSession }.count == 2)
    }

    @Test func skipDropsTheMissedSessionsAndKeepsTheRest() {
        let plan = scheduler.evaluate(program: program(rules: ProgramRules(missed: .skip)), week: 3, context: context("2023-11-16"))
        #expect(plan.sessions.filter { $0.status == .skipped }.map(\.templateID).count == 2)
        #expect(plan.sessions.allSatisfy { !$0.isMoved })
        #expect(plan.newAdjustments.filter { $0.kind == .movedSession }.isEmpty)
    }

    @Test func aMovedSessionStaysWhereItWasSaved() {
        let first = scheduler.evaluate(program: program(), week: 3, context: context("2023-11-16"))
        var saved = program()
        saved.adjustments += first.newAdjustments
        let again = scheduler.evaluate(program: saved, week: 3, context: context("2023-11-16"))
        #expect(again.sessions == first.sessions && again.newAdjustments.isEmpty)
    }

    // MARK: Days and edges

    @Test func dayResolutionFindsTodaysSessionWithItsTime() {
        let plan = scheduler.resolve(day: "2023-11-14", program: program(), context: context())
        #expect(plan.week == 3 && plan.sessions.map(\.templateID) == [T.upper.id] && plan.sessions[0].startMinute == 1_080)
        #expect(scheduler.resolve(day: "2023-11-17", program: program(), context: context()).reasons == [.restDay])
    }

    @Test func lighterWeeksFollowTheSlotKinds() {
        let weekFour = scheduler.evaluate(program: program(), week: 4, context: context("2023-11-20"))
        #expect(weekFour.sessions.map(\.kind) == [.light, .light, .normal, .light, .light])
        #expect(weekFour.sessions.allSatisfy { $0.plannedKind == $0.kind })
        let weekSeven = scheduler.evaluate(program: program(), week: 7, context: context("2023-12-11", recovery: []))
        #expect(weekSeven.sessions.map(\.plannedKind) == [.light, .light, .normal, .light, .light])
    }

    @Test func outsideTheProgramAndInactiveProgramsScheduleNothing() {
        #expect(scheduler.resolve(day: "2023-10-29", program: program(), context: context()).reasons == [.beforeStart])
        #expect(scheduler.resolve(day: "2023-12-25", program: program(), context: context()).reasons == [.afterEnd])
        for status in [ProgramStatus.draft, .paused, .completed, .archived] {
            let plan = scheduler.evaluate(program: program(status: status), week: 3, context: context())
            #expect(plan.sessions.isEmpty && plan.reasons == [.notActive])
            #expect(plan.newAdjustments.isEmpty)
        }
    }

    @Test func theWholeProgramRunsEightWeeksAndFortyDaysOfSessions() {
        let all = (1...8).flatMap { scheduler.evaluate(program: program(), week: $0, context: context("2023-10-30", recovery: [], completed: [])).sessions }
        #expect(all.count == 40 && Set(all.map(\.id)).count == 40)
        #expect(all.first?.localDay == "2023-10-30" && all.map(\.localDay).max() == "2023-12-23")
    }
}
