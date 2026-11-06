import Foundation
import RoutineKit
import Testing
import TrainKit
import WorkoutKit

/// The Train overview on a fixed Australia/Perth clock. Today is Tuesday 2023-11-14, which is
/// week 3 of the fixture program that starts on Monday 2023-10-30.
struct TrainOverviewModelTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Perth") ?? .gmt
        return calendar
    }()

    private func at(_ day: String, hour: Int = 10) -> Date {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        return Self.calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: hour)) ?? .distantPast
    }

    private var now: Date { at("2023-11-14") }

    // MARK: Fixture

    private func line(_ name: String, sets: Int = 4, load: Double? = 60) -> TemplateExercise {
        .init(exercise: ExerciseRef(key: name.lowercased().replacingOccurrences(of: " ", with: "-"), name: name),
              sets: sets, repsMin: 6, repsMax: 8, loadKg: load, restSeconds: 150)
    }

    private static let arms = UUID()
    private let upperA = WorkoutTemplate(name: "Upper A", weekdays: [.tuesday], exercises: [
        .init(exercise: ExerciseRef(key: "bench", name: "Bench press"), sets: 4, repsMin: 6, repsMax: 8, loadKg: 80, restSeconds: 150),
        .init(exercise: ExerciseRef(key: "pull-up", name: "Pull-up"), sets: 4, repsMin: 6, repsMax: 8, restSeconds: 150),
        .init(exercise: ExerciseRef(key: "row", name: "Barbell row"), sets: 4, repsMin: 6, repsMax: 8, loadKg: 70, restSeconds: 150),
        .init(exercise: ExerciseRef(key: "ohp", name: "Overhead press"), sets: 3, repsMin: 8, repsMax: 10, loadKg: 40, restSeconds: 120),
        .init(exercise: ExerciseRef(key: "curl", name: "Dumbbell curl"), sets: 4, repsMin: 10, repsMax: 12, loadKg: 14, restSeconds: 0, supersetGroup: Self.arms),
        .init(exercise: ExerciseRef(key: "pushdown", name: "Cable triceps pushdown"), sets: 3, repsMin: 12, repsMax: 12, loadKg: 25, restSeconds: 120,
              supersetGroup: Self.arms)
    ], progression: .doubleProgression(incrementKg: 2.5), recoveryRule: RecoveryRule())
    private let lowerA = WorkoutTemplate(name: "Lower A", weekdays: [.monday], exercises: [
        .init(exercise: ExerciseRef(key: "squat", name: "Back squat"), sets: 4, repsMin: 6, repsMax: 8, loadKg: 100, restSeconds: 180)
    ], recoveryRule: RecoveryRule())
    private let lowerB = WorkoutTemplate(name: "Lower B", weekdays: [.thursday], exercises: [
        .init(exercise: ExerciseRef(key: "rdl", name: "Romanian deadlift"), sets: 4, repsMin: 8, repsMax: 10, loadKg: 90, restSeconds: 150),
        .init(exercise: ExerciseRef(key: "lunge", name: "Walking lunge"), sets: 3, repsMin: 10, repsMax: 12, loadKg: 20, restSeconds: 90)
    ], recoveryRule: RecoveryRule())
    private let upperB = WorkoutTemplate(name: "Upper B", weekdays: [.saturday], exercises: [
        .init(exercise: ExerciseRef(key: "ohp", name: "Overhead press"), sets: 4, repsMin: 6, repsMax: 8, loadKg: 40, restSeconds: 150)
    ], recoveryRule: RecoveryRule())
    private let zone2 = WorkoutTemplate(name: "Zone 2", kind: .cardio, weekdays: [.wednesday],
                                        cardio: CardioTarget(activity: .run, minutes: 45, zone: 2))

    private var templates: [WorkoutTemplate] { [upperA, lowerA, lowerB, upperB, zone2] }

    private var week: [ProgramSlot] {
        [ProgramSlot(weekday: .monday, templateID: lowerA.id, tag: "LA"),
         ProgramSlot(weekday: .tuesday, templateID: upperA.id, tag: "UA"),
         ProgramSlot(weekday: .wednesday, templateID: zone2.id, tag: "Z2"),
         ProgramSlot(weekday: .thursday, templateID: lowerB.id, tag: "LB"),
         ProgramSlot(weekday: .saturday, templateID: upperB.id, tag: "UB")]
    }

    private let blockID = UUID()
    private let marathonID = UUID()

    private var strengthBlock: Program {
        Program(id: blockID, name: "Strength block", status: .active, startDay: "2023-10-30", weeks: Array(repeating: week, count: 8))
    }

    private var halfMarathon: Program {
        Program(id: marathonID, name: "Half marathon", status: .paused, startDay: "2023-09-04",
                weeks: Array(repeating: [ProgramSlot(weekday: .sunday, templateID: zone2.id)], count: 12))
    }

    /// 3,200 + 3,600 + 1,620 = 8,420 kg.
    private func lowerASession(day: String = "2023-11-13", workoutID: UUID? = UUID()) throws -> TrainSession {
        let start = at(day, hour: 17)
        func exercise(_ name: String, sets: Int, kg: Double, reps: Int) -> SessionExercise {
            let planned = line(name, sets: sets, load: kg)
            let logged = (0..<sets).map { LoggedSet(loadKg: kg, reps: reps, loggedAt: start.addingTimeInterval(Double($0) * 200)) }
            return SessionExercise(planned: planned, status: .done, sets: logged)
        }
        return try TrainSession(workoutID: workoutID, templateID: lowerA.id, name: "Lower A", programWeek: 3, startedAt: start,
            timeZoneIdentifier: "Australia/Perth", endedAt: start.addingTimeInterval(62 * 60), status: .completed, recoveryAtStart: 70,
            exercises: [exercise("Back squat", sets: 4, kg: 100, reps: 8), exercise("Romanian deadlift", sets: 4, kg: 90, reps: 10),
                        exercise("Leg press", sets: 3, kg: 60, reps: 9)])
    }

    private func recovery(_ today: Double?, window: Double = 63) -> [RecoveryReading] {
        let days = ["2023-11-06", "2023-11-07", "2023-11-08", "2023-11-09", "2023-11-10", "2023-11-11", "2023-11-12", "2023-11-13"]
        var readings = days.map { RecoveryReading(localDay: $0, score: window) }
        if let today { readings.append(RecoveryReading(localDay: "2023-11-14", score: today)) }
        return readings
    }

    private func overview(templates: [WorkoutTemplate]? = nil, programs: [Program]? = nil, sessions: [TrainSession]? = nil,
                          recovery: [RecoveryReading]? = nil, strain: [ExpectedStrain.Sample] = [], swapped: UUID? = nil) throws -> TrainOverview {
        TrainOverviewModel(TrainOverviewInput(
            now: now, calendar: Self.calendar, templates: templates ?? self.templates,
            programs: programs ?? [strengthBlock, halfMarathon], sessions: try sessions ?? [lowerASession()],
            recovery: recovery ?? self.recovery(79), strainSamples: strain, swappedTemplateID: swapped)).overview
    }

    private func plan(_ overview: TrainOverview) throws -> TrainTodayPlan {
        guard case .plan(let plan) = overview.today else { throw Failure.notAPlan }
        return plan
    }

    private enum Failure: Error { case notAPlan }

    // MARK: Week strip

    @Test func weekStripFollowsTheProgramAndMarksFinishedDays() throws {
        let strip = try overview().week
        #expect(strip.map(\.localDay) == ["2023-11-13", "2023-11-14", "2023-11-15", "2023-11-16", "2023-11-17", "2023-11-18", "2023-11-19"])
        #expect(strip.map(\.letter) == ["M", "T", "W", "T", "F", "S", "S"])
        #expect(strip.map(\.numeral) == ["13", "14", "15", "16", "17", "18", "19"])
        #expect(strip.map(\.caption) == ["Done", "Upper A", "Zone 2", "Lower B", "Rest", "Upper B", "Rest"])
        #expect(strip.map(\.isDone) == [true, false, false, false, false, false, false])
        #expect(strip.map(\.isToday) == [false, true, false, false, false, false, false])
        #expect(strip[1].id == "train-day-2023-11-14")
        #expect(strip[1].spokenLabel == "Tuesday 14 November, Upper A, today")
        #expect(strip[0].spokenLabel == "Monday 13 November, done")
        #expect(strip[4].spokenLabel == "Friday 17 November, rest")
        #expect(strip[1].templateID == upperA.id && strip[4].templateID == nil)
    }

    /// R1-DES-15: the strip's dots read the names done and still planned each day.
    @Test func weekDaysKnowWhatWasDoneAndWhatIsStillPlanned() throws {
        let strip = try overview().week
        #expect(strip[0].doneNames == ["Lower A"] && strip[0].plannedNames.isEmpty)
        #expect(strip[1].doneNames.isEmpty && strip[1].plannedNames == ["Upper A"] && strip[1].plannedCount == 1)
        #expect(strip[4].plannedNames.isEmpty && !strip[4].isSkipped)
    }

    @Test func weekStripFallsBackToTemplateWeekdaysWithoutAProgram() throws {
        let result = try overview(programs: [], sessions: [])
        #expect(result.week.map(\.caption) == ["Lower A", "Upper A", "Zone 2", "Lower B", "Rest", "Upper B", "Rest"])
        #expect(result.showsWeekStrip)
        #expect(result.headerMeta == nil)
    }

    /// R3-OPT-6: the protocol's every-day Zone 2 shows on every day of the week, not only on the program's Zone 2 day,
    /// and today's card says where it sits beside the lift.
    @Test func theDailyZone2RuleShowsOnTheWeekAndTodaysCard() throws {
        let rule = ProtocolRule(key: "zone-2", title: "Zone 2, 45 min", group: .fitness,
                                target: RuleTarget(kind: .atLeast, metric: DoseTargets.zone2MinutesMetric, value: 45, unit: "min"),
                                timeOfDayMinutes: 17 * 60 + 30, source: .band)
        let zone2Rule = try #require(TrainDailyZone2(rules: [rule]))
        #expect(zone2Rule.minutes == 45 && zone2Rule.startMinute == 17 * 60 + 30)
        let weekly = ProtocolRule(key: "z2w", title: "Zone 2 minutes", target: RuleTarget(kind: .atLeast, metric: DoseTargets.zone2MinutesMetric,
                                  value: 180, unit: "min"), cadence: RuleCadence(unit: .week))
        #expect(TrainDailyZone2(rules: [weekly]) == nil)

        var slots = week
        slots[1] = ProgramSlot(weekday: .tuesday, templateID: upperA.id, tag: "UA", startMinute: 18 * 60 + 30)
        let block = Program(id: blockID, name: "Strength block", status: .active, startDay: "2023-10-30",
                            weeks: Array(repeating: slots, count: 8))
        let result = TrainOverviewModel(TrainOverviewInput(
            now: now, calendar: Self.calendar, templates: templates, programs: [block], sessions: try [lowerASession()],
            recovery: recovery(79), dailyZone2: zone2Rule)).overview
        #expect(result.week.map(\.caption) == ["Done", "2 sessions", "Zone 2", "2 sessions", "Zone 2", "2 sessions", "Zone 2"])
        #expect(result.week[1].spokenLabel == "Tuesday 14 November, Upper A and Zone 2, 45 min, today")
        #expect(result.week[1].plannedNames == ["Upper A", "Zone 2, 45 min"])
        // Monday's Lower A is done; the daily Zone 2 is still planned beside it.
        #expect(result.week[0].doneNames == ["Lower A"] && result.week[0].plannedNames == ["Zone 2, 45 min"])
        let today = try plan(result)
        #expect(today.dailyNote == "Your protocol has Zone 2, 45 min at 17:30, before Upper A.")
        // On the card the rule is a chip, not a sentence (blueprint 6.2).
        #expect(today.dailyChip == "Zone 2, 45 min at 17:30")
        #expect(TrainOverviewModel.zone2Note(zone2Rule, sessionStart: 18 * 60, sessionName: "Upper A")
                == "Your protocol has Zone 2, 45 min at 17:30, overlapping Upper A.")
    }

    @Test func twoTemplatesOnOneDayShowACount() throws {
        let extra = WorkoutTemplate(name: "Mobility", weekdays: [.tuesday], exercises: lowerB.exercises)
        let result = try overview(templates: [upperA, extra], programs: [], sessions: [])
        #expect(result.week[1].caption == "2 sessions")
    }

    @Test func weekStripHidesWhenNothingIsPlannedOrDone() throws {
        let loose = WorkoutTemplate(name: "Loose", exercises: upperA.exercises)
        let result = try overview(templates: [loose], programs: [], sessions: [])
        #expect(!result.showsWeekStrip)
        #expect(result.today == .rest(next: nil))
        #expect(result.week.count == 7)
    }

    @Test func aSkippedSessionIsNamedAsSkipped() throws {
        var program = strengthBlock
        program.rules.missed = .skip
        // Nothing finished on Monday, so Lower A is missed and dropped.
        let result = try overview(programs: [program], sessions: [])
        #expect(result.week[0].caption == "Skipped")
        #expect(!result.week[0].isDone)
    }

    // MARK: Today and recovery

    @Test func todayShowsUpperAWithItsSummaryAndRecovery() throws {
        let today = try plan(overview())
        #expect(today.name == "Upper A" && today.templateID == upperA.id)
        #expect(today.detail == "6 exercises · about 55 min")
        #expect(today.summary == "6 exercises · about 55 min" && !today.recoveryAdjusts && today.dailyChip == nil)
        #expect(today.recoveryShown == 79 && today.recoveryScore == 79)
        #expect(today.recoveryMessage == "Recovery is 79, so go as planned.")
        #expect(today.programID == blockID)
        #expect(today.programWeek == 3)
        #expect(!today.isSwapped && !today.isLight && today.scheduleNote == nil)
    }

    @Test func highRecoveryGoesAsPlanned() throws {
        let today = try plan(overview(recovery: recovery(67)))
        #expect(today.recoveryMessage == "Recovery is 67, so go as planned.")
    }

    @Test func lowRecoveryOffersTheLighterVersion() throws {
        let today = try plan(overview(recovery: recovery(31)))
        #expect(today.recoveryShown == 31)
        #expect(today.recoveryMessage == "Recovery is 31. The lighter version drops one set per lift.")
        // A change to the session is the one reason the card shows a sentence.
        #expect(today.recoveryAdjusts)
    }

    @Test func recoveryExactlyAtTheThresholdChangesNothing() throws {
        let today = try plan(overview(recovery: recovery(34)))
        #expect(today.recoveryMessage == "Recovery is 34, so go as planned.")
    }

    @Test func noRecoveryReadingIsSaidPlainly() throws {
        let today = try plan(overview(recovery: recovery(nil)))
        #expect(today.recoveryScore == nil && today.recoveryShown == nil)
        #expect(today.recoveryMessage == "No recovery reading yet. Go as planned or lighten it yourself.")
    }

    @Test func yesterdaysScoreIsNotTodays() throws {
        // Only Monday has a reading, so today has none.
        let today = try plan(overview(recovery: [RecoveryReading(localDay: "2023-11-13", score: 90)]))
        #expect(today.recoveryScore == nil)
    }

    @Test func cardioHasNoRecoveryMessage() throws {
        let cardioToday = WorkoutTemplate(name: "Zone 2", kind: .cardio, weekdays: [.tuesday],
                                          cardio: CardioTarget(activity: .run, minutes: 45, zone: 2))
        let today = try plan(overview(templates: [cardioToday], programs: [], sessions: []))
        #expect(today.kind == .cardio && today.recoveryMessage == nil)
        #expect(today.detail == "45 min · zone 2")
    }

    @Test func expectedStrainComesFromTheLastSessionsOfThatTemplate() throws {
        let samples = [
            ExpectedStrain.Sample(templateID: upperA.id, endedAt: at("2023-11-07"), strain: 11),
            ExpectedStrain.Sample(templateID: upperA.id, endedAt: at("2023-10-31"), strain: 10.6),
            ExpectedStrain.Sample(templateID: lowerA.id, endedAt: at("2023-11-13"), strain: 15)
        ]
        let withHistory = try plan(overview(strain: samples))
        #expect(withHistory.detail.hasSuffix("expected strain 10.8"))
        // Strain stays out of the card's one line (R1-NEW-09).
        #expect(withHistory.summary == "6 exercises · about 55 min")
        let single = try plan(overview(strain: [samples[0]]))
        #expect(single.detail.hasSuffix("expected strain 11"))
        let none = try plan(overview())
        #expect(!none.detail.contains("expected strain"))
    }

    @Test func aLightWeekExplainsItself() throws {
        let today = try plan(overview(recovery: recovery(79, window: 46)))
        #expect(today.isLight)
        #expect(today.scheduleNote == "Week 3 is lighter. Recovery averaged 46 over the last 7 days.")
    }

    @Test func swappingShowsTheChosenTemplateAndOffersTheRest() throws {
        let result = try overview(swapped: lowerB.id)
        let today = try plan(result)
        #expect(today.templateID == lowerB.id && today.isSwapped && today.programID == nil && today.scheduleNote == nil)
        #expect(result.swapChoices.map(\.name).contains("Upper A"))
        #expect(!result.swapChoices.map(\.name).contains("Lower B"))
        #expect(result.swapChoices.count == 4)
        #expect(result.todayTemplateID == lowerB.id)
    }

    @Test func swapChoicesExcludeTheSessionShown() throws {
        let result = try overview()
        #expect(result.swapChoices.map(\.name) == ["Lower A", "Lower B", "Upper B", "Zone 2"])
    }

    @Test func aFinishedSessionTodayShowsDoneWhenNothingElseIsPlanned() throws {
        let finished = try lowerASession(day: "2023-11-14")
        let onlyLower = Program(name: "Strength block", status: .active, startDay: "2023-10-30",
                                weeks: Array(repeating: [ProgramSlot(weekday: .tuesday, templateID: lowerA.id)], count: 8))
        let result = try overview(programs: [onlyLower], sessions: [finished])
        guard case .done(let summary) = result.today else { throw Failure.notAPlan }
        #expect(summary.name == "Lower A" && summary.detail == "62 min · 8,420 kg")
        #expect(result.week[1].isDone && result.week[1].caption == "Done")
    }

    @Test func aRestDayNamesTheNextSession() throws {
        let fridayLess = Program(name: "Strength block", status: .active, startDay: "2023-10-30",
            weeks: Array(repeating: [ProgramSlot(weekday: .thursday, templateID: lowerB.id)], count: 8))
        let result = try overview(programs: [fridayLess], sessions: [])
        #expect(result.today == .rest(next: "Lower B on Thursday"))
    }

    // MARK: Programs

    @Test func programsShowProgressAndStatus() throws {
        let programs = try overview().programs
        #expect(programs.map(\.name) == ["Strength block", "Half marathon"])
        let block = programs[0]
        #expect(block.slug == "strength-block" && block.status == .active)
        #expect(block.caption == "8 weeks · 5 days a week")
        #expect(block.value == "3" && block.valueUnit == "of 8" && block.progress == 3.0 / 8.0)
        #expect(block.spokenLabel == "Strength block, week 3 of 8, 8 weeks · 5 days a week")
        let paused = programs[1]
        #expect(paused.caption == "Paused" && paused.progress == nil && paused.value == nil)
        #expect(paused.slug == "half-marathon")
    }

    @Test func headerNamesTheWeekOfTheRunningProgram() throws {
        #expect(try overview().headerMeta == "Week 3 of 8 · Strength block")
        #expect(try overview(programs: [halfMarathon]).headerMeta == nil)
    }

    @Test func draftsAndArchivedProgramsNeverShow() throws {
        var draft = strengthBlock
        draft.status = .draft
        var archived = halfMarathon
        archived.status = .archived
        let result = try overview(programs: [draft, archived])
        #expect(result.programs.isEmpty && result.headerMeta == nil)
    }

    @Test func aProgramThatHasNotStartedSaysWhen() throws {
        var later = strengthBlock
        later.startDay = "2023-11-20"
        let row = try overview(programs: [later]).programs[0]
        #expect(row.caption == "8 weeks · starts 20 Nov" && row.progress == nil)
    }

    @Test func aProgramPastItsLastWeekIsFinished() throws {
        var earlier = strengthBlock
        earlier.startDay = "2023-08-28"
        let row = try overview(programs: [earlier]).programs[0]
        #expect(row.caption == "8 weeks · finished" && row.progress == 1 && row.value == "8")
    }

    @Test func rowSlugsAreUnique() throws {
        let second = Program(name: "Strength block", status: .paused, startDay: "2023-01-02", weeks: [week])
        let result = try overview(programs: [strengthBlock, second])
        #expect(result.programs.map(\.slug) == ["strength-block", "strength-block-2"])
        #expect(TrainOverviewModel.slug("  Push / Pull! 5x5 ") == "push-pull-5x5")
        #expect(TrainOverviewModel.slug("!!!") == "untitled")
    }

    // MARK: Templates

    @Test func templatesListTheirExercises() throws {
        let rows = try overview().templates
        #expect(rows.map(\.name) == ["Lower A", "Lower B", "Upper A", "Upper B", "Zone 2"])
        let upper = try #require(rows.first { $0.name == "Upper A" })
        #expect(upper.slug == "upper-a" && upper.caption == "Bench press, Pull-up and 4 more")
        #expect(try #require(rows.first { $0.name == "Lower B" }).caption == "Romanian deadlift and Walking lunge")
        #expect(try #require(rows.first { $0.name == "Lower A" }).caption == "Back squat")
        #expect(try #require(rows.first { $0.name == "Zone 2" }).caption == "45 min · zone 2")
        #expect(upper.spokenLabel.hasPrefix("Upper A, 6 exercises, about "))
    }

    // MARK: This week

    @Test func thisWeekListsFinishedSessionsWithTonnage() throws {
        let finished = try lowerASession()
        let result = try overview(sessions: [finished])
        let summary = try #require(result.thisWeek.first)
        #expect(result.thisWeek.count == 1)
        #expect(summary.name == "Lower A" && summary.minutes == 62 && summary.tonnageKg == 8_420)
        #expect(summary.caption.hasPrefix("Mon 13 Nov · 62 min"), "\(summary.caption)")
        #expect(summary.caption.hasSuffix("8,420 kg"), "\(summary.caption)")
        #expect(summary.spokenLabel == "Lower A, 62 minutes, 8,420 kilograms lifted")
        #expect(result.sessionsByWorkoutID[try #require(finished.workoutID)] == summary)
    }

    /// R1-LIFT-13: rows carry a date, so Earlier reads "Tue 7 Nov".
    @Test func sessionsCarryTheirDayAndTheOverviewItsCalendar() throws {
        let result = try overview()
        #expect(result.thisWeek.first?.dayLabel == "Mon 13 Nov")
        #expect(TrainOverviewModel.dayLabel(localDay: "2023-11-07") == "Tue 7 Nov")
        #expect(TrainOverviewModel.dayLabel(localDay: "not a day") == "")
        #expect(result.calendar.timeZone.identifier == "Australia/Perth")
    }

    @Test func sessionsOutsideTheWeekStayOutOfThisWeekButKeepTheirTonnage() throws {
        let old = try lowerASession(day: "2023-11-07")
        let result = try overview(sessions: [old])
        #expect(result.thisWeek.isEmpty)
        #expect(result.sessionsByWorkoutID.count == 1)
    }

    @Test func skippedSetsDoNotCountTowardTonnage() throws {
        var finished = try lowerASession()
        finished.exercises[0].sets[0] = LoggedSet(loadKg: nil, reps: 0, loggedAt: finished.startedAt, skipped: true)
        let summary = try #require(try overview(sessions: [finished]).thisWeek.first)
        #expect(summary.tonnageKg == 8_420 - 800)
    }

    @Test func abandonedAndActiveSessionsAreNotThisWeeksWork() throws {
        var active = try lowerASession()
        active.status = .abandoned
        let result = try overview(sessions: [active])
        #expect(result.thisWeek.isEmpty && !result.week[0].isDone)
    }

    // MARK: Empty state

    @Test func withNoProgramAndNoTemplateTheOverviewIsEmpty() throws {
        let result = try overview(templates: [], programs: [], sessions: [], recovery: [])
        #expect(result.isEmpty && !result.showsWeekStrip && result.week.isEmpty)
        #expect(result.today == .none)
        #expect(result.programs.isEmpty && result.templates.isEmpty && result.thisWeek.isEmpty && result.headerMeta == nil)
    }

    @Test func aSavedTemplateEndsTheEmptyState() throws {
        let saved = WorkoutTemplate(name: "Upper A", weekdays: [.tuesday], exercises: upperA.exercises)
        let result = try overview(templates: [saved], programs: [], sessions: [])
        #expect(!result.isEmpty)
        #expect(result.templates.map(\.name) == ["Upper A"])
        #expect(try plan(result).name == "Upper A")
    }
}
