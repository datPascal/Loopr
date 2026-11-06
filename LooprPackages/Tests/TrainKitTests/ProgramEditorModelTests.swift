import Foundation
import Testing
import TrainKit

struct ProgramEditorModelTests {
    private typealias T = ProgramTemplates
    private let templates = [ProgramTemplates.upper, ProgramTemplates.zone]

    private func blank() -> ProgramEditorModel { .blank(startDay: "2023-11-14", templates: templates, id: UUID()) }

    private func filled() -> ProgramEditorModel {
        var model = blank()
        model.name = "  Strength block  "
        model.apply(ProgramSlotDraft(templateID: T.upper.id, kind: .heavy, tag: "UA", startMinute: 18 * 60), week: 1, weekday: .tuesday)
        model.apply(ProgramSlotDraft(templateID: T.zone.id), week: 1, weekday: .wednesday)
        return model
    }

    // MARK: Blank

    @Test func aBlankProgramNeedsANameAndASessionBeforeItSaves() {
        var model = blank()
        #expect(model.weekCount == 4 && model.isNew && !model.isDirty && model.title == "New program")
        #expect(model.problem == .nameMissing && !model.canSave)
        model.name = "Block"
        #expect(model.problem == .noSessions)
        model.apply(ProgramSlotDraft(templateID: T.upper.id), week: 2, weekday: .friday)
        #expect(model.problem == nil && model.canSave && model.isDirty)
        #expect(model.summary == "4 weeks, 1 session")
    }

    @Test func withoutTemplatesTheEditorSaysToSaveOneFirst() {
        var model = ProgramEditorModel.blank(startDay: "2023-11-14", templates: [])
        model.name = "Block"
        #expect(model.problem == .noTemplates)
        #expect(ProgramEditorModel.Problem.noTemplates.message == "Save a workout first. A program schedules the workouts you have saved.")
    }

    // MARK: Slots

    @Test func slotsKeepOneSessionPerWeekdayInWeekOrder() {
        var model = filled()
        model.apply(ProgramSlotDraft(templateID: T.zone.id, kind: .light), week: 1, weekday: .tuesday)
        let week = model.weeks[0]
        #expect(week.map(\.weekday) == [.tuesday, .wednesday] && week[0].templateID == T.zone.id && week[0].kind == .light && week[0].tag == nil)
        model.apply(ProgramSlotDraft(templateID: T.upper.id), week: 1, weekday: .monday)
        #expect(model.weeks[0].map(\.weekday) == [.monday, .tuesday, .wednesday])
        model.clearSlot(week: 1, weekday: .tuesday)
        #expect(model.slot(week: 1, weekday: .tuesday) == nil && model.weeks[0].count == 2)
    }

    @Test func slotSheetRoundTripsAndTrimsTheTag() {
        var model = filled()
        let draft = model.slotDraft(week: 1, weekday: .tuesday)
        #expect(draft == ProgramSlotDraft(templateID: T.upper.id, kind: .heavy, tag: "UA", startMinute: 1_080))
        #expect(model.slotDraft(week: 1, weekday: .sunday) == ProgramSlotDraft())
        model.apply(ProgramSlotDraft(templateID: T.upper.id, tag: " ABCDE "), week: 1, weekday: .thursday)
        #expect(model.slot(week: 1, weekday: .thursday)?.tag == "ABC")
        model.apply(ProgramSlotDraft(templateID: T.upper.id, tag: "   "), week: 1, weekday: .thursday)
        #expect(model.slot(week: 1, weekday: .thursday)?.tag == nil)
    }

    @Test func unknownTemplatesAndBadTimesAreIgnored() {
        var model = filled()
        model.apply(ProgramSlotDraft(templateID: UUID()), week: 1, weekday: .friday)
        #expect(model.slot(week: 1, weekday: .friday) == nil)
        model.apply(ProgramSlotDraft(templateID: T.upper.id, startMinute: 2_000), week: 1, weekday: .friday)
        #expect(model.slot(week: 1, weekday: .friday)?.startMinute == nil)
        model.apply(ProgramSlotDraft(templateID: T.upper.id), week: 99, weekday: .friday)
        #expect(model.weekCount == 4)
    }

    // MARK: Weeks

    @Test func addingAWeekCopiesTheLastAndSelectsIt() {
        var model = filled()
        model.copyWeekToAll(1)
        model.addWeek()
        #expect(model.weekCount == 5 && model.selectedWeek == 5 && model.weeks[4] == model.weeks[3])
        #expect(model.weeks.allSatisfy { $0 == model.weeks[0] })
    }

    @Test func weekCountStaysBetweenOneAndFiftyTwo() {
        var model = blank()
        for _ in 0..<80 { model.addWeek() }
        #expect(model.weekCount == 52 && !model.canAddWeek)
        for _ in 0..<80 { model.removeWeek(1) }
        #expect(model.weekCount == 1 && !model.canRemoveWeek)
    }

    @Test func removingAWeekShiftsRecordedChangesAndSelection() throws {
        var program = Program(name: "X", status: .active, startDay: "2023-10-30", weeks: Array(repeating: [ProgramSlot(weekday: .monday, templateID: T.upper.id)], count: 5),
                              adjustments: [
                                ProgramAdjustment(kind: .earlyLightWeek, week: 2, reason: "Week 2", createdAt: .now),
                                ProgramAdjustment(kind: .earlyLightWeek, week: 4, reason: "Week 4", createdAt: .now)])
        program.revision = 1
        var model = ProgramEditorModel(program: program, templates: templates)
        model.selectedWeek = 5
        model.removeWeek(2)
        #expect(model.weekCount == 4 && model.selectedWeek == 4)
        #expect(model.draft.adjustments.map(\.week) == [3])
        try model.normalized().validate()
    }

    @Test func normalizedTrimsTheNameAndStaysValid() throws {
        let program = Program(name: "X", status: .active, startDay: "2023-10-30", weeks: [[ProgramSlot(weekday: .monday, templateID: T.upper.id)]])
        var model = ProgramEditorModel(program: program, templates: templates)
        model.name = "  Y "
        #expect(model.normalized().name == "Y")
        try model.normalized().validate()
    }

    // MARK: Rules, start day, saving

    @Test func rulesAndStartDayEdit() {
        var model = blank()
        model.rules.earlyLightWeek = false
        model.rules.missed = .skip
        model.rules.calendarExport = true
        model.startDay = "2023-12-04"
        model.startDay = "not a day"
        #expect(model.startDay == "2023-12-04" && model.rules == ProgramRules(earlyLightWeek: false, missed: .skip, calendarExport: true))
        #expect(model.weekRunText == "Weeks run Monday to Sunday.")
        model.startDay = "2023-12-06"
        #expect(model.weekRunText == "Weeks run Wednesday to Tuesday.")
    }

    @Test func startDayConvertsBothWaysInTheGivenCalendar() throws {
        var perth = Calendar(identifier: .gregorian)
        perth.timeZone = TimeZone(identifier: "Australia/Perth") ?? .gmt
        let date = try #require(ProgramEditorModel.date(fromDay: "2023-11-14", calendar: perth))
        #expect(ProgramEditorModel.day(from: date, calendar: perth) == "2023-11-14")
        #expect(ProgramEditorModel.date(fromDay: "garbage", calendar: perth) == nil)
    }

    @Test func saveSendsTheNormalizedProgramAndKeepsWhatTheStoreReturns() async throws {
        var model = filled()
        try await model.save { program in
            var stored = program
            stored.revision = 1
            return stored
        }
        let saved = model.original
        #expect(saved.name == "Strength block" && saved.revision == 1 && saved.status == .active && saved.source == .manual)
        #expect(!model.isDirty && !model.isNew)
        try saved.validate()
    }

    @Test func saveRefusesAnIncompleteProgramWithoutCallingTheStore() async {
        var model = blank()
        let calls = Counter()
        var refused: ProgramEditorModel.Problem?
        do {
            try await model.save { program in calls.bump(); return program }
        } catch {
            refused = error as? ProgramEditorModel.Problem
        }
        #expect(refused == .nameMissing)
        #expect(calls.value == 0)
    }

    @Test func editingADraftKeepsItADraftAndPrunesUnusedPendingTemplates() throws {
        let extra = TrainFixture.cardio(name: "Easy ride")
        let unused = TrainFixture.cardio(name: "Spare")
        let draft = Program(name: "Spring", source: .agent, status: .draft, startDay: "2023-11-20",
                            weeks: [[ProgramSlot(weekday: .monday, templateID: extra.id)]], pendingTemplates: [extra, unused])
        let model = ProgramEditorModel(program: draft, templates: templates + [extra, unused])
        #expect(model.isDraftProgram)
        let normalized = model.normalized()
        #expect(normalized.status == .draft && normalized.pendingTemplates?.map(\.name) == ["Easy ride"])
        try normalized.validate()
    }

    @Test func clockTextIsTwentyFourHour() {
        #expect(TrainClockText.time(minute: 1_080) == "18:00" && TrainClockText.time(minute: 0) == "00:00" && TrainClockText.time(minute: 5) == "00:05")
        #expect(TrainClockText.time(minute: 99_999) == "23:59" && TrainClockText.time(minute: -4) == "00:00")
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
