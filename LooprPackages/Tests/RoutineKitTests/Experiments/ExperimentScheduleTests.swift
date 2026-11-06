import DomainKit
import Foundation
import Testing
@testable import RoutineKit

struct ExperimentScheduleTests {
    private func roles(_ experiment: Experiment) -> [ExperimentNightRole] { experiment.schedule.nights.map(\.role) }

    @Test func alternatingDaysAlternateOnAndOffFromNightOne() throws {
        let experiment = try ExpFixtures.experiment(planned: 6)
        #expect(roles(experiment) == [.on, .off, .on, .off, .on, .off])
        #expect(experiment.schedule.nights.map(\.number) == [1, 2, 3, 4, 5, 6])
        #expect(experiment.schedule.nights.first?.day == ExpFixtures.startDay)
        #expect(experiment.schedule.includedNightCount(for: .on) == 3)
        #expect(experiment.schedule.includedNightCount(for: .off) == 3)
    }

    @Test func blocksRunOnThenOffInTheStatedLength() throws {
        let experiment = try ExpFixtures.experiment(design: .blocks(length: 7), minimum: 7, planned: 28)
        let expected: [ExperimentNightRole] = Array(repeating: .on, count: 7) + Array(repeating: .off, count: 7)
            + Array(repeating: .on, count: 7) + Array(repeating: .off, count: 7)
        #expect(roles(experiment) == expected)
        #expect(ExperimentCopy.designLine(.blocks(length: 7)) == "Blocks of 7 nights, decided before night 1")
    }

    @Test func beforeAndAfterRunsTheBaselinePeriodThenTheIntervention() throws {
        let experiment = try ExpFixtures.experiment(design: .beforeAndAfter(baselineNights: 5), minimum: 5, planned: 12)
        #expect(roles(experiment) == Array(repeating: .off, count: 5) + Array(repeating: .on, count: 7))
        #expect(ExperimentCopy.designLine(.beforeAndAfter(baselineNights: 5)) == "Before and after, 5 nights first, decided before night 1")
        #expect(ExperimentCopy.designLine(.alternatingDays) == "Alternating days in a fixed order, not random, decided before night 1")
    }

    @Test func washoutNightsFollowEachSwitchAndNeverTheStart() throws {
        let experiment = try ExpFixtures.experiment(design: .blocks(length: 7), washout: 2, minimum: 5, planned: 28)
        let nights = experiment.schedule.nights
        #expect(nights.prefix(7).allSatisfy { $0.role == .on })
        #expect(nights[7].role == .washout(.off) && nights[8].role == .washout(.off))
        #expect(nights[9...13].allSatisfy { $0.role == .off })
        #expect(nights[14].role == .washout(.on) && nights[15].role == .washout(.on))
        #expect(nights[16...20].allSatisfy { $0.role == .on })
        #expect(nights[21].role == .washout(.off) && nights[22].role == .washout(.off))
        #expect(experiment.schedule.includedNightCount(for: .on) == 12)
        #expect(experiment.schedule.includedNightCount(for: .off) == 10)
    }

    @Test func beforeAndAfterWashoutLeavesTheFirstInterventionNights() throws {
        let experiment = try ExpFixtures.experiment(design: .beforeAndAfter(baselineNights: 7), washout: 2, minimum: 5, planned: 14)
        #expect(roles(experiment) == Array(repeating: .off, count: 7) + [.washout(.on), .washout(.on)]
                + Array(repeating: .on, count: 5))
    }

    @Test func daysOutsideThePlanAreOutside() throws {
        // Four alternating nights give 2 on and 2 off, so the plan's minimum has to be 2.
        let experiment = try ExpFixtures.experiment(minimum: 2, planned: 4)
        let schedule = experiment.schedule
        #expect(schedule.role(on: ExpFixtures.night(-1)) == .outside)
        #expect(schedule.role(on: ExpFixtures.night(0)) == .on)
        #expect(schedule.role(on: ExpFixtures.night(3)) == .off)
        #expect(schedule.role(on: ExpFixtures.night(4)) == .outside)
        #expect(schedule.nightNumber(on: ExpFixtures.night(2)) == 3)
        #expect(schedule.nightNumber(on: ExpFixtures.night(9)) == nil)

        let stopped = try ExpFixtures.experiment(planned: 10, status: .stopped, endDay: ExpFixtures.night(3))
        #expect(stopped.schedule.role(on: ExpFixtures.night(3)) == .off)
        #expect(stopped.schedule.role(on: ExpFixtures.night(4)) == .outside)
        #expect(stopped.stoppedEarly)
    }

    @Test func aWashoutThatSwallowsABlockIsRefused() {
        #expect(throws: ExperimentError.invalidWashout) { try ExpFixtures.start(design: .alternatingDays, washout: 1) }
        #expect(throws: ExperimentError.invalidWashout) { try ExpFixtures.start(design: .blocks(length: 3), washout: 3, minimum: 2, planned: 24) }
        #expect(throws: ExperimentError.invalidWashout) { try ExpFixtures.start(washout: -1) }
        #expect(throws: ExperimentError.invalidWashout) {
            try ExpFixtures.start(design: .beforeAndAfter(baselineNights: 6), washout: 4, minimum: 2, planned: 10)
        }
    }

    @Test func aPlanThatCannotReachTheMinimumIsRefused() {
        #expect(throws: ExperimentError.planCannotReachMinimum(.on)) { try ExpFixtures.start(minimum: 8, planned: 14) }
        #expect(throws: ExperimentError.planCannotReachMinimum(.off)) {
            try ExpFixtures.start(design: .blocks(length: 7), washout: 2, minimum: 6, planned: 14)
        }
        #expect(throws: ExperimentError.invalidDesign) { try ExpFixtures.start(design: .blocks(length: 0)) }
        #expect(throws: ExperimentError.invalidDesign) { try ExpFixtures.start(design: .beforeAndAfter(baselineNights: 14), planned: 14) }
        #expect(throws: ExperimentError.minimumNightsTooLow) { try ExpFixtures.start(minimum: 1) }
        #expect(throws: ExperimentError.plannedNightsTooLow) { try ExpFixtures.start(planned: 1) }
    }

    // MARK: Clocks and time zones

    @Test func theScheduleHoldsAcrossTheAutumnClockChange() throws {
        // Europe/Berlin goes back on 2026-10-25, a 25 hour day. Counting 86,400 second days would drift an hour.
        let start = ExpFixtures.day(2026, 10, 22)
        let experiment = Experiment(start: try ExpFixtures.start(planned: 8, startDay: start))
        let schedule = experiment.schedule
        #expect(start.days(until: ExpFixtures.day(2026, 10, 26)) == 4)
        #expect(schedule.role(on: ExpFixtures.day(2026, 10, 24)) == .on)
        #expect(schedule.role(on: ExpFixtures.day(2026, 10, 25)) == .off)
        #expect(schedule.role(on: ExpFixtures.day(2026, 10, 26)) == .on)

        let calendar = ExperimentCalendar(calendar: ExpFixtures.calendar("Europe/Berlin"))
        // 02:30 happens twice that night, at 00:30 UTC and again at 01:30 UTC. Both belong to the 24th's night.
        #expect(calendar.nightDay(sleepStart: ExpFixtures.instant("2026-10-25T00:30:00Z")) == ExpFixtures.day(2026, 10, 24))
        #expect(calendar.nightDay(sleepStart: ExpFixtures.instant("2026-10-25T01:30:00Z")) == ExpFixtures.day(2026, 10, 24))
        #expect(calendar.nightDay(sleepStart: ExpFixtures.instant("2026-10-25T22:30:00Z")) == ExpFixtures.day(2026, 10, 25))
    }

    @Test func theScheduleHoldsAcrossTheSpringClockChange() throws {
        // Europe/Berlin jumps forward on 2026-03-29, a 23 hour day.
        let start = ExpFixtures.day(2026, 3, 27)
        let experiment = Experiment(start: try ExpFixtures.start(planned: 6, startDay: start))
        #expect(experiment.schedule.role(on: ExpFixtures.day(2026, 3, 28)) == .off)
        #expect(experiment.schedule.role(on: ExpFixtures.day(2026, 3, 29)) == .on)
        #expect(experiment.schedule.role(on: ExpFixtures.day(2026, 3, 30)) == .off)
        #expect(ExpFixtures.day(2026, 3, 28).days(until: ExpFixtures.day(2026, 3, 30)) == 2)

        let calendar = ExperimentCalendar(calendar: ExpFixtures.calendar("Europe/Berlin"))
        // 01:30 CET on the 29th is the 28th's night. 23:30 CEST that evening is the 29th's.
        #expect(calendar.nightDay(sleepStart: ExpFixtures.instant("2026-03-29T00:30:00Z")) == ExpFixtures.day(2026, 3, 28))
        #expect(calendar.nightDay(sleepStart: ExpFixtures.instant("2026-03-29T21:30:00Z")) == ExpFixtures.day(2026, 3, 29))
    }

    @Test func aNightBelongsToTheLocalDayItStartsOn() {
        let calendar = ExperimentCalendar(calendar: ExpFixtures.calendar("Europe/Berlin"))
        // 23:30 on the 14th and 00:40 on the 15th are the same night.
        #expect(calendar.nightDay(sleepStart: ExpFixtures.instant("2026-10-14T21:30:00Z")) == ExpFixtures.day(2026, 10, 14))
        #expect(calendar.nightDay(sleepStart: ExpFixtures.instant("2026-10-14T22:40:00Z")) == ExpFixtures.day(2026, 10, 14))
        // 11:59 still counts for the day before, 12:00 starts that day's evening.
        #expect(calendar.nightDay(sleepStart: ExpFixtures.instant("2026-10-15T09:59:00Z")) == ExpFixtures.day(2026, 10, 14))
        #expect(calendar.nightDay(sleepStart: ExpFixtures.instant("2026-10-15T10:00:00Z")) == ExpFixtures.day(2026, 10, 15))
        // A month boundary.
        #expect(calendar.nightDay(sleepStart: ExpFixtures.instant("2026-10-31T23:30:00Z")) == ExpFixtures.day(2026, 10, 31))
        #expect(calendar.nightDay(sleepStart: ExpFixtures.instant("2026-10-31T23:30:00Z").addingTimeInterval(3600)) == ExpFixtures.day(2026, 10, 31))
        let early = ExperimentCalendar(calendar: ExpFixtures.calendar("UTC"), nightCutoffHour: 4)
        #expect(early.nightDay(sleepStart: ExpFixtures.instant("2026-11-01T03:00:00Z")) == ExpFixtures.day(2026, 10, 31))
        #expect(early.nightDay(sleepStart: ExpFixtures.instant("2026-11-01T05:00:00Z")) == ExpFixtures.day(2026, 11, 1))
    }

    @Test func aTimeZoneChangeMovesTonightButNotTheSchedule() throws {
        let experiment = try ExpFixtures.experiment(planned: 14)
        let berlin = ExperimentCalendar(calendar: ExpFixtures.calendar("Europe/Berlin"))
        let losAngeles = ExperimentCalendar(calendar: ExpFixtures.calendar("America/Los_Angeles"))
        // The same instant is the 23rd in Berlin and still the 22nd in Los Angeles.
        let now = ExpFixtures.instant("2026-10-23T05:30:00Z")
        #expect(berlin.tonight(at: now) == ExpFixtures.day(2026, 10, 23))
        #expect(losAngeles.tonight(at: now) == ExpFixtures.day(2026, 10, 22))

        // The schedule is by civil date, so each side reads its own day with no gap and no shift.
        #expect(experiment.schedule.role(on: berlin.tonight(at: now)) == .off)    // night 12, index 11
        #expect(experiment.schedule.role(on: losAngeles.tonight(at: now)) == .on) // night 11, index 10
        #expect(experiment.schedule.nightNumber(on: berlin.tonight(at: now)) == 12)
        #expect(experiment.schedule.nightNumber(on: losAngeles.tonight(at: now)) == 11)
        // A sleep that starts at 23:30 in Los Angeles is that evening's night, whichever zone the phone used to be in.
        #expect(losAngeles.nightDay(sleepStart: ExpFixtures.instant("2026-10-23T06:30:00Z")) == ExpFixtures.day(2026, 10, 22))
    }

    // MARK: What Today says

    @Test func todaySaysWhatTonightIs() {
        #expect(ExperimentCopy.tonight(role: .on, interventionName: "magnesium") == "Tonight is a magnesium night.")
        #expect(ExperimentCopy.tonight(role: .on, interventionName: "Iron") == "Tonight is an iron night.")
        #expect(ExperimentCopy.tonight(role: .off, interventionName: "magnesium") == "Tonight is an off night. No magnesium.")
        #expect(ExperimentCopy.tonight(role: .washout(.on), interventionName: "magnesium")?.hasPrefix("Tonight is a magnesium night.") == true)
        #expect(ExperimentCopy.tonight(role: .washout(.off), interventionName: "magnesium")?.contains("leaves it out") == true)
        #expect(ExperimentCopy.tonight(role: .outside, interventionName: "magnesium") == nil)
        #expect(ExperimentCopy.washoutLine(0) == nil)
        #expect(ExperimentCopy.washoutLine(1) == "1 night left out after each switch")
        #expect(ExperimentCopy.washoutLine(2) == "2 nights left out after each switch")
    }

    @Test func aDesignRoundTripsThroughItsColumns() throws {
        for design in [ExperimentDesign.alternatingDays, .blocks(length: 7), .beforeAndAfter(baselineNights: 5)] {
            #expect(ExperimentDesign(kind: design.kind, length: design.length) == design)
            let decoded = try JSONDecoder().decode(ExperimentDesign.self, from: JSONEncoder().encode(design))
            #expect(decoded == design)
        }
        #expect(ExperimentDesign(kind: "blocks", length: nil) == nil)
        #expect(ExperimentDesign(kind: "random", length: 3) == nil)
    }
}
