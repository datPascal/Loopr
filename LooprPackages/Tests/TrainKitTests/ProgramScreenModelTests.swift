import DesignSystem
import Foundation
import Testing
@testable import TrainKit

/// What the Program screen shows (mockup 13), on the fixture Strength block. Alex, Australia/Perth, Tuesday 2023-11-14.
struct ProgramScreenModelTests {
    private typealias T = ProgramTemplates
    private let programID = UUID(uuidString: "7A0460FE-0000-4000-8000-000000000011") ?? UUID()

    private var perth: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Perth") ?? .gmt
        return calendar
    }

    private let now = Date(timeIntervalSince1970: 1_699_927_200)

    private func block(status: ProgramStatus = .active, request: String? = "Get stronger at bench and squat", rules: ProgramRules = .init(),
                       adjustments: [ProgramAdjustment] = []) -> Program {
        Program(id: programID, revision: 1, name: "Strength block", request: request, source: .agent, status: status,
                startDay: "2023-10-30", weeks: T.weeks(count: 8, full: true), rules: rules, adjustments: adjustments)
    }

    private func model(_ program: Program? = nil, sessions: [TrainSession] = [], denied: Bool = false) -> ProgramScreenModel {
        ProgramScreenModel(ProgramScreenInput(program: program ?? block(), templates: T.all, sessions: sessions, now: now, calendar: perth,
                                              calendarDenied: denied))
    }

    private func squat(_ load: Double, _ reps: Int) -> TemplateExercise {
        TemplateExercise(exercise: ExerciseRef(key: "Barbell_Squat", name: "Back squat"), sets: 4, repsMin: reps, repsMax: reps, loadKg: load)
    }

    private func session(day: Int, week: Int, program: UUID? = nil, load: Double, reps: Int, status: TrainSessionStatus = .completed,
                         skipped: Bool = false) throws -> TrainSession {
        let start = Date(timeIntervalSince1970: 1_698_600_000 + Double(day) * 86_400)
        let sets = skipped ? [LoggedSet(loadKg: nil, reps: 0, loggedAt: start, skipped: true)]
            : (0..<4).map { LoggedSet(loadKg: load, reps: reps, loggedAt: start.addingTimeInterval(Double($0) * 200)) }
        return try TrainSession(templateID: T.lowerA.id, name: "Lower A", programID: program ?? programID, programWeek: week, startedAt: start,
                                timeZoneIdentifier: "Australia/Perth", endedAt: start.addingTimeInterval(3_600), status: status,
                                exercises: [SessionExercise(planned: squat(load, reps), status: skipped ? .skipped : .done, sets: sets)])
    }

    // MARK: Header and grid

    @Test func headerNamesTheWeeksAndWhichAreLighter() {
        let result = model()
        #expect(result.title == "Strength block" && result.weeksTitle == "8 weeks")
        #expect(result.lightWeeks == [4, 7] && result.lighterCaption == "Weeks 4 and 7 are lighter")
        #expect(result.request == "Get stronger at bench and squat" && !result.isDraft)
    }

    @Test func lighterCaptionReadsNaturallyForEveryCount() {
        #expect(ProgramScreenModel.lighterCaption([]) == "No lighter weeks")
        #expect(ProgramScreenModel.lighterCaption([5]) == "Week 5 is lighter")
        #expect(ProgramScreenModel.lighterCaption([4, 7]) == "Weeks 4 and 7 are lighter")
        #expect(ProgramScreenModel.lighterCaption([2, 4, 7]) == "Weeks 2, 4 and 7 are lighter")
    }

    @Test func aWeekIsLightOnlyWhenEveryStrengthSlotIsLight() {
        let byID = Dictionary(uniqueKeysWithValues: T.all.map { ($0.id, $0) })
        func week(_ kinds: [ProgramSlotKind], cardio: ProgramSlotKind? = nil) -> [ProgramSlot] {
            var slots = kinds.enumerated().map { ProgramSlot(weekday: TrainWeekday(rawValue: $0.offset + 1) ?? .monday, templateID: T.upper.id, kind: $0.element) }
            if let cardio { slots.append(ProgramSlot(weekday: .sunday, templateID: T.zone.id, kind: cardio)) }
            return slots
        }
        let program = Program(name: "X", startDay: "2023-10-30", weeks: [
            week([.light, .light]),                    // 1: light
            week([.light, .normal]),                   // 2: one normal strength slot
            week([.light, .heavy]),                    // 3: heavy
            week([.light, .light], cardio: .normal),   // 4: light, cardio does not count
            [ProgramSlot(weekday: .sunday, templateID: T.zone.id, kind: .light)], // 5: cardio only
            []                                         // 6: nothing planned
        ])
        #expect(ProgramScreenModel.lightWeeks(of: program, templates: byID) == [1, 4])
    }

    @Test func gridHasEightWeeksWithNamesTypesAndTodayOutlined() {
        let result = model()
        #expect(result.grid.map(\.label) == (1...8).map { "W\($0)" })
        let weekThree = result.grid[2].days
        // Names, not codes, in the cells (R2-NEW-13), and a type per day (R2-VET-12).
        #expect(weekThree.map { $0?.spokenName } == ["Lower A", "Upper A", "Zone 2", "Lower B", nil, "Upper B", nil])
        #expect(weekThree.map { $0?.type } == [.strength, .strength, .easy, .strength, nil, .strength, nil])
        #expect(weekThree.map { $0?.intensity } == [.normal, .normal, .normal, .heavy, nil, .heavy, nil])
        #expect(weekThree.map { $0?.isCurrent } == [false, true, false, false, nil, false, nil])
        #expect(result.grid.flatMap(\.days).compactMap { $0 }.filter(\.isCurrent).count == 1)
        // Zone 2 stays easy in a light week. Strength slots turn light.
        #expect(result.grid[3].days.map { $0?.intensity } == [.light, .light, .normal, .light, nil, .light, nil])
        #expect(result.types == [.easy, .strength] && result.hasHeavy && result.hasLight)
    }

    @Test func hardDaysThatTouchGetANote() {
        func day(_ type: ProgramSessionType, _ intensity: ProgramSlotKind = .normal) -> ProgramScreenModel.Day {
            ProgramScreenModel.Day(name: "", spokenName: "", type: type, intensity: intensity, isCurrent: false)
        }
        let every = ProgramScreenModel.Week(number: 1, days: [nil, day(.hard), day(.strength, .heavy), nil, nil, nil, day(.long)])
        let once = ProgramScreenModel.Week(number: 2, days: [nil, day(.hard), day(.easy), day(.hard), day(.hard), nil, nil])
        let quiet = ProgramScreenModel.Week(number: 3, days: [nil, day(.hard), day(.easy), nil, nil, nil, nil])
        #expect(ProgramScreenModel.hardDayNote([quiet]) == nil)
        #expect(ProgramScreenModel.hardDayNote([every, once, quiet])
            == "Tue and Wed are both hard in week 1. Thu and Fri are both hard in week 2.")
        #expect(ProgramScreenModel.hardDayNote([every]) == "Tue and Wed are both hard.")
        #expect(ProgramScreenModel.shortName("Lower A") == "Lower A" && ProgramScreenModel.shortName("4x4 intervals") == "4x4")
    }

    @Test func codeFallsBackToInitials() {
        func code(_ name: String, tag: String? = nil) -> String {
            let template = WorkoutTemplate(name: name)
            return ProgramScreenModel.code(for: ProgramSlot(weekday: .monday, templateID: template.id, tag: tag), template: template)
        }
        #expect(code("Upper A") == "UA" && code("Zone 2") == "Z2" && code("Squat") == "SQ" && code("Push pull legs") == "PP")
        #expect(code("Upper A", tag: "MAX") == "MAX")
        #expect(ProgramScreenModel.code(for: ProgramSlot(weekday: .monday, templateID: UUID()), template: nil) == "?")
    }

    @Test func aDraftHasNoCurrentDayAndNoHistory() {
        let result = model(block(status: .draft))
        #expect(result.isDraft && result.soFar == nil)
        #expect(result.grid.flatMap(\.days).allSatisfy { $0?.isCurrent != true })
        #expect(result.calendarLocked && !result.calendarOn && result.calendarNote == "Available after you accept the plan.")
        #expect(ProgramScreenModel.draftMessage == "Draft from Ask. Nothing is scheduled until you accept it.")
    }

    @Test func blankRequestShowsNoHero() {
        #expect(model(block(request: "  ")).request == nil && model(block(request: nil)).request == nil)
    }

    // MARK: Rules

    @Test func rulesReadFromTheProgram() {
        let result = model()
        #expect(result.earlyLightOn && result.earlyLight.subtitle == "When 7-day recovery averages under 50")
        #expect(result.missedRule == .moveBack && result.missed.subtitle == "Move the week back, never double up")
        let skip = model(block(rules: ProgramRules(earlyLightWeek: false, earlyLightBelowScore: 45, earlyLightMinDays: 5, earlyLightWindowDays: 10, missed: .skip)))
        #expect(!skip.earlyLightOn && skip.earlyLight.subtitle == "When 10-day recovery averages under 45")
        #expect(skip.missed.subtitle == "Skip it and carry on")
    }

    @Test func calendarStatesOffOnAndDenied() {
        let off = model()
        #expect(!off.calendarOn && !off.calendarLocked && !off.calendarDenied && off.calendarNote == nil && off.calendarTitle == "Add to Calendar")
        let on = model(block(rules: ProgramRules(calendarExport: true)))
        #expect(on.calendarOn && on.calendarNote == nil)
        let denied = model(block(rules: ProgramRules(calendarExport: true)), denied: true)
        #expect(!denied.calendarOn && denied.calendarDenied)
        #expect(denied.calendarNote == "Calendar access is off. Turn it on in Settings to add sessions.")
    }

    @Test func changesListRecordedRuleDecisionsNewestFirst() {
        let earlier = ProgramAdjustment(kind: .earlyLightWeek, week: 2, reason: "Week 2 is lighter. Recovery averaged 46 over the last 7 days.",
                                        recoveryScore: 46, daysWithReadings: 7, createdAt: Date(timeIntervalSince1970: 100))
        let declined = ProgramAdjustment(kind: .earlyLightDeclined, week: 3, reason: "Week 3 stays as planned.", createdAt: Date(timeIntervalSince1970: 300))
        let moved = ProgramAdjustment(kind: .movedSession, week: 3, weekday: .tuesday, movedToWeekday: .friday,
                                      reason: "Moved from Tuesday so no day has two sessions.", createdAt: Date(timeIntervalSince1970: 200))
        #expect(model(block(adjustments: [earlier, declined, moved])).changes == [moved.reason, earlier.reason])
        #expect(model().changes.isEmpty)
    }

    // MARK: So far

    @Test func sessionsDoneComesFromStoredSessionsAgainstPlannedSessionsDue() throws {
        // Weeks 1 and 2 hold ten sessions, and Monday and Tuesday of week 3 make twelve by today.
        #expect(ProgramScreenModel.dueSessions(program: block(), today: "2023-11-14") == 12)
        #expect(ProgramScreenModel.dueSessions(program: block(), today: "2023-10-29") == 0)
        #expect(ProgramScreenModel.dueSessions(program: block(), today: "2024-03-01") == 40)
        let sessions = [try session(day: 0, week: 1, load: 100, reps: 6), try session(day: 14, week: 3, load: 100, reps: 8)]
        #expect(model(sessions: sessions).soFar?.sessionsValue == "2 of 12")
        #expect(model().soFar?.sessionsValue == "0 of 12" && model().soFar?.liftTitle == nil)
    }

    @Test func otherProgramsActiveSessionsAndSkipsDoNotCount() throws {
        let sessions = [
            try session(day: 0, week: 1, load: 100, reps: 6),
            try session(day: 1, week: 1, program: UUID(), load: 100, reps: 6),
            try session(day: 2, week: 1, load: 100, reps: 6, status: .abandoned)
        ]
        #expect(model(sessions: sessions).soFar?.sessionsValue == "1 of 12")
    }

    @Test func estimatedMaxMovesFromTheFirstSessionToTheBest() throws {
        // 100 kg for 6 is 120 kg by Epley. 100 kg for 8 is 126.7, shown as 127.
        let sessions = [try session(day: 14, week: 3, load: 100, reps: 8), try session(day: 0, week: 1, load: 100, reps: 6)]
        let soFar = try #require(model(sessions: sessions).soFar)
        #expect(soFar.liftTitle == "Back squat, estimated max" && soFar.liftValue == "120 → 127 kg")
        #expect(soFar.liftSpoken == "Back squat, estimated max, 120 to 127 kilograms")
        #expect(abs(PersonalBestEvaluator.estimatedOneRepMax(loadKg: 100, reps: 6) - 120) < 1e-9)
    }

    @Test func oneSessionShowsOneValueAndNoSkippedSetsCount() throws {
        let one = try #require(model(sessions: [try session(day: 0, week: 1, load: 100, reps: 6)]).soFar)
        #expect(one.liftValue == "120 kg")
        #expect(model(sessions: [try session(day: 0, week: 1, load: 0, reps: 1, skipped: true)]).soFar?.liftTitle == nil)
    }

    @Test func theLiftThatRoseMostIsTheHeadline() throws {
        let press = TemplateExercise(exercise: ExerciseRef(key: "press", name: "Overhead press"), sets: 3, repsMin: 5, repsMax: 5, loadKg: 40)
        func line(_ load: Double, _ reps: Int) -> SessionExercise {
            let at = Date(timeIntervalSince1970: 1_698_600_000)
            return SessionExercise(planned: press, status: .done, sets: [LoggedSet(loadKg: load, reps: reps, loggedAt: at)])
        }
        func made(_ day: Double, load: Double, reps: Int) throws -> TrainSession {
            let start = Date(timeIntervalSince1970: 1_698_600_000 + day * 86_400)
            return try TrainSession(name: "Upper A", programID: programID, startedAt: start, timeZoneIdentifier: "Australia/Perth",
                                    endedAt: start.addingTimeInterval(3_000), status: .completed, exercises: [line(load, reps)])
        }
        // Press 40 kg for 5 is 46.7, then 50 kg for 5 is 58.3. A rise of 11.7 beats the squat's 6.7.
        let sessions = [try made(0, load: 40, reps: 5), try session(day: 0, week: 1, load: 100, reps: 6),
                        try made(14, load: 50, reps: 5), try session(day: 14, week: 3, load: 100, reps: 8)]
        #expect(model(sessions: sessions).soFar?.liftTitle == "Overhead press, estimated max")
        #expect(model(sessions: sessions).soFar?.liftValue == "47 → 58 kg")
    }
}
