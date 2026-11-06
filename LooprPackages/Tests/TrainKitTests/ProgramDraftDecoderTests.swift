import Foundation
import Testing
import TrainKit

/// Agent drafts: strict decoding, then the state changes the store allows. Alex, Australia/Perth.
struct ProgramDraftDecoderTests {
    private let date = TrainFixture.date
    private let upper = TrainFixture.template(name: "Upper A")
    private let lower = TrainFixture.template(name: "Lower A")

    private func decoder(library: ExerciseLibrary? = nil, templates: [WorkoutTemplate]? = nil) -> ProgramDraftDecoder {
        ProgramDraftDecoder(templates: templates ?? [upper, lower], library: library, defaultStartDay: "2023-11-20")
    }

    private func library() throws -> ExerciseLibrary {
        try ExerciseLibrary(definitions: [
            ExerciseDefinition(key: "Barbell_Squat", name: "Barbell squat", category: "strength", equipment: "barbell")
        ])
    }

    private let valid = """
    {"schemaVersion":1,"name":"Spring base","request":"Three runs and two lifts for four weeks","startDay":"2023-11-20",
     "weeks":[[{"weekday":"monday","template":"lower a","tag":"LA","startTime":"18:00"},
               {"weekday":"WED","template":"Easy ride","kind":"light"}],
              [{"weekday":"tuesday","template":"Upper A"}]],
     "newTemplates":[{"name":"Easy ride","kind":"cardio","cardio":{"activity":"cycle","minutes":40,"zone":2}}],
     "rules":{"earlyLightWeek":false,"missed":"skip"}}
    """

    private func failure(_ json: String, using decoder: ProgramDraftDecoder? = nil) -> ProgramDraftError? {
        do { _ = try (decoder ?? self.decoder()).decode(json); return nil } catch { return error as? ProgramDraftError }
    }

    // MARK: Valid

    @Test func validDraftBecomesAnAgentDraftProgram() throws {
        let program = try decoder().decode(valid)
        #expect(program.status == .draft && program.isDraft)
        #expect(program.source == .agent && program.revision == 0)
        #expect(program.name == "Spring base" && program.startDay == "2023-11-20")
        #expect(program.request == "Three runs and two lifts for four weeks")
        #expect(program.weekCount == 2 && program.weeks[0].map(\.weekday) == [.monday, .wednesday])
        #expect(program.weeks[0][0].templateID == lower.id && program.weeks[0][0].startMinute == 18 * 60 && program.weeks[0][0].tag == "LA")
        #expect(program.weeks[0][1].kind == .light)
        #expect(program.rules.earlyLightWeek == false && program.rules.missed == .skip)
        let pending = try #require(program.pendingTemplates)
        #expect(pending.map(\.name) == ["Easy ride"] && pending[0].kind == .cardio && pending[0].source == .agent)
        #expect(program.weeks[0][1].templateID == pending[0].id)
        try program.validate()
    }

    @Test func aDraftNeverTurnsCalendarExportOn() throws {
        #expect(try decoder().decode(valid).rules.calendarExport == false)
        let withKey = valid.replacingOccurrences(of: "\"missed\":\"skip\"", with: "\"missed\":\"skip\",\"calendarExport\":true")
        #expect(failure(withKey) == .unknownField("rules.calendarExport"))
    }

    @Test func missingStartDayUsesTheDefault() throws {
        let json = """
        {"schemaVersion":1,"name":"Block","weeks":[[{"weekday":"monday","template":"Upper A"}]]}
        """
        let program = try decoder().decode(json)
        #expect(program.startDay == "2023-11-20" && program.pendingTemplates == nil && program.request == nil)
    }

    @Test func newStrengthTemplateResolvesExercisesFromTheLibrary() throws {
        let json = """
        {"schemaVersion":1,"name":"Legs","weeks":[[{"weekday":"monday","template":"Squat day"}]],
         "newTemplates":[{"name":"Squat day","kind":"strength","exercises":[{"exercise":"BARBELL  squat","sets":4,"repsMin":5,"loadKg":100}]}]}
        """
        let program = try decoder(library: library()).decode(json)
        let line = try #require(program.pendingTemplates?.first?.exercises.first)
        #expect(line.exercise.key == "Barbell_Squat" && line.sets == 4 && line.repsMin == 5 && line.repsMax == 5 && line.loadKg == 100)
        #expect(failure(json, using: decoder(library: nil)) == .unknownExercise("BARBELL  squat"))
    }

    // MARK: Rejected

    @Test func unknownTemplateIsRefused() {
        let json = valid.replacingOccurrences(of: "\"template\":\"Upper A\"", with: "\"template\":\"Push day\"")
        #expect(failure(json) == .unknownTemplate("Push day"))
        #expect(failure(json)?.message.contains("Push day") == true)
    }

    @Test func moreThanSevenSlotsAWeekIsRefused() {
        let days = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "monday"]
        let slots = days.map { "{\"weekday\":\"\($0)\",\"template\":\"Upper A\"}" }.joined(separator: ",")
        #expect(failure("{\"schemaVersion\":1,\"name\":\"X\",\"weeks\":[[\(slots)]]}") == .tooManySlots(week: 1, count: 8))
    }

    @Test func twoSessionsOnOneDayAreRefused() {
        let json = """
        {"schemaVersion":1,"name":"X","weeks":[[{"weekday":"monday","template":"Upper A"},{"weekday":"mon","template":"Lower A"}]]}
        """
        #expect(failure(json) == .duplicateWeekday(week: 1, weekday: "mon"))
    }

    @Test func emptyWeeksAndNoWeeksAreRefused() {
        #expect(failure("{\"schemaVersion\":1,\"name\":\"X\",\"weeks\":[]}") == .noWeeks)
        #expect(failure("{\"schemaVersion\":1,\"name\":\"X\",\"weeks\":[[{\"weekday\":\"monday\",\"template\":\"Upper A\"}],[]]}") == .emptyWeek(2))
    }

    @Test func tooManyWeeksAreRefused() {
        let week = "[{\"weekday\":\"monday\",\"template\":\"Upper A\"}]"
        let weeks = Array(repeating: week, count: 53).joined(separator: ",")
        #expect(failure("{\"schemaVersion\":1,\"name\":\"X\",\"weeks\":[\(weeks)]}") == .tooManyWeeks(53))
    }

    @Test func badKindWeekdayTagAndTimeAreRefused() {
        func slot(_ extra: String) -> String {
            "{\"schemaVersion\":1,\"name\":\"X\",\"weeks\":[[{\"weekday\":\"monday\",\"template\":\"Upper A\"\(extra)}]]}"
        }
        #expect(failure(slot(",\"kind\":\"brutal\"")) == .badKind("brutal"))
        #expect(failure(slot(",\"tag\":\"LONGER\"")) == .badTag("LONGER"))
        #expect(failure(slot(",\"startTime\":\"6pm\"")) == .badStartTime("6pm"))
        #expect(failure(slot(",\"startTime\":\"25:00\"")) == .badStartTime("25:00"))
        #expect(failure(slot("").replacingOccurrences(of: "monday", with: "someday")) == .badWeekday("someday"))
    }

    @Test func unknownKeysVersionAndBrokenJSONAreRefused() {
        #expect(failure(valid.replacingOccurrences(of: "\"tag\":\"LA\"", with: "\"tagg\":\"LA\"")) == .unknownField("weeks[0][0].tagg"))
        #expect(failure(valid.replacingOccurrences(of: "\"name\":\"Spring base\"", with: "\"name\":\"Spring base\",\"status\":\"active\"")) == .unknownField("status"))
        #expect(failure(valid.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2")) == .unsupportedVersion(2))
        if case .malformed = failure("not json") {} else { Issue.record("expected malformed") }
        if case .malformed = failure("{\"schemaVersion\":1,\"name\":5,\"weeks\":[]}") {} else { Issue.record("expected malformed") }
        #expect(failure("{\"schemaVersion\":1,\"name\":\"  \",\"weeks\":[]}") == .nameMissing)
        #expect(failure(valid.replacingOccurrences(of: "2023-11-20", with: "2023-02-30")) == .badStartDay("2023-02-30"))
    }

    @Test func templateRulesAreEnforced() {
        // Name already saved, listed twice, never used, wrong kind or activity, missing target.
        func draft(_ templates: String, slotTemplate: String = "Easy ride") -> String {
            "{\"schemaVersion\":1,\"name\":\"X\",\"weeks\":[[{\"weekday\":\"monday\",\"template\":\"\(slotTemplate)\"}]],\"newTemplates\":[\(templates)]}"
        }
        let ride = "{\"name\":\"Easy ride\",\"kind\":\"cardio\",\"cardio\":{\"activity\":\"cycle\",\"minutes\":40}}"
        #expect(failure(draft("{\"name\":\"upper a\",\"kind\":\"cardio\",\"cardio\":{\"activity\":\"run\",\"minutes\":30}}")) == .templateNameTaken("upper a"))
        #expect(failure(draft("\(ride),\(ride)")) == .duplicateNewTemplate("Easy ride"))
        #expect(failure(draft("\(ride),{\"name\":\"Spare\",\"kind\":\"cardio\",\"cardio\":{\"activity\":\"run\",\"minutes\":30}}")) == .unusedTemplate("Spare"))
        #expect(failure(draft("{\"name\":\"Easy ride\",\"kind\":\"swimming\"}")) == .badTemplateKind("swimming"))
        #expect(failure(draft("{\"name\":\"Easy ride\",\"kind\":\"cardio\",\"cardio\":{\"activity\":\"teleport\",\"minutes\":30}}")) == .badActivity("teleport"))
        #expect(failure(draft("{\"name\":\"Easy ride\",\"kind\":\"cardio\"}")) == .templateNeedsCardioTarget("Easy ride"))
        #expect(failure(draft("{\"name\":\"Easy ride\",\"kind\":\"strength\"}")) == .templateNeedsExercises("Easy ride"))
        #expect(failure(draft("{\"name\":\"Easy ride\",\"kind\":\"cardio\",\"cardio\":{\"activity\":\"cycle\",\"minutes\":9000}}")) == .invalidTemplate("Easy ride"))
    }

    @Test func twoSavedTemplatesWithOneNameAreAmbiguous() {
        let twin = TrainFixture.template(name: "Upper A")
        let json = "{\"schemaVersion\":1,\"name\":\"X\",\"weeks\":[[{\"weekday\":\"monday\",\"template\":\"Upper A\"}]]}"
        #expect(failure(json, using: decoder(templates: [upper, twin])) == .ambiguousTemplate("Upper A"))
    }

    // MARK: Accept and discard

    @Test func draftStaysInertUntilAccepted() throws {
        let context = try TrainTestDatabase()
        for template in [upper, lower] { _ = try context.store.saveTemplate(template, at: date) }
        let draft = try context.store.saveProgram(try decoder().decode(valid), at: date)
        #expect(draft.status == .draft && draft.revision == 1)

        // The scheduler ignores it.
        var perth = Calendar(identifier: .gregorian); perth.timeZone = TimeZone(identifier: "Australia/Perth") ?? .gmt
        let scheduler = ProgramScheduler(calendar: perth)
        let monday = perth.date(from: DateComponents(year: 2023, month: 11, day: 20, hour: 9)) ?? .distantPast
        let plan = scheduler.resolve(day: "2023-11-20", program: draft, context: .init(now: monday))
        #expect(plan.sessions.isEmpty && plan.reasons == [.notActive])
        // Calendar export skips it, even with the switch on.
        var exporting = draft
        exporting.rules.calendarExport = true
        let events = TrainCalendarExport.events(for: exporting, templates: [upper, lower] + (draft.pendingTemplates ?? []),
                                                context: .init(now: monday), calendar: perth)
        #expect(events.isEmpty)
        // Its new template is not in the template list yet.
        #expect(try context.store.templates().map(\.name).sorted() == ["Lower A", "Upper A"])
    }

    @Test func acceptSavesPendingTemplatesAndActivatesTheProgram() throws {
        let context = try TrainTestDatabase()
        for template in [upper, lower] { _ = try context.store.saveTemplate(template, at: date) }
        let draft = try context.store.saveProgram(try decoder().decode(valid), at: date)
        let accepted = try context.store.acceptProgramDraft(id: draft.id, expectedRevision: draft.revision, at: date.addingTimeInterval(60))
        #expect(accepted.status == .active && accepted.pendingTemplates == nil && accepted.revision == 2)
        #expect(try context.store.program(id: draft.id) == accepted)
        #expect(try context.store.templates().map(\.name).sorted() == ["Easy ride", "Lower A", "Upper A"])
        // It schedules now.
        var perth = Calendar(identifier: .gregorian); perth.timeZone = TimeZone(identifier: "Australia/Perth") ?? .gmt
        let monday = perth.date(from: DateComponents(year: 2023, month: 11, day: 20, hour: 9)) ?? .distantPast
        let plan = ProgramScheduler(calendar: perth).resolve(day: "2023-11-20", program: accepted, context: .init(now: monday))
        #expect(plan.sessions.map(\.templateID) == [lower.id])
    }

    @Test func acceptRefusesAStaleRevisionANonDraftAndAMissingTemplate() throws {
        let context = try TrainTestDatabase()
        for template in [upper, lower] { _ = try context.store.saveTemplate(template, at: date) }
        let draft = try context.store.saveProgram(try decoder().decode(valid), at: date)
        #expect(throws: TrainError.staleRevision) { try context.store.acceptProgramDraft(id: draft.id, expectedRevision: 0, at: date) }
        #expect(throws: TrainError.missingRecord) { try context.store.acceptProgramDraft(id: UUID(), expectedRevision: 0, at: date) }
        let accepted = try context.store.acceptProgramDraft(id: draft.id, expectedRevision: draft.revision, at: date)
        #expect(throws: TrainError.invalidRecord) { try context.store.acceptProgramDraft(id: draft.id, expectedRevision: accepted.revision, at: date) }
        #expect(throws: TrainError.invalidRecord) { try context.store.discardProgramDraft(id: draft.id, expectedRevision: accepted.revision) }

        // A draft whose saved template was deleted cannot be accepted, and nothing is written.
        let other = TrainFixture.template(name: "Gone")
        let saved = try context.store.saveTemplate(other, at: date)
        let json = "{\"schemaVersion\":1,\"name\":\"Needs gone\",\"weeks\":[[{\"weekday\":\"monday\",\"template\":\"Gone\"}]]}"
        let second = try context.store.saveProgram(try decoder(templates: [saved]).decode(json), at: date)
        try context.store.deleteTemplate(id: saved.id, expectedRevision: saved.revision)
        #expect(throws: TrainError.missingRecord) { try context.store.acceptProgramDraft(id: second.id, expectedRevision: second.revision, at: date) }
        #expect(try context.store.program(id: second.id)?.status == .draft)
    }

    @Test func discardDeletesTheDraftAndItsTemplates() throws {
        let context = try TrainTestDatabase()
        for template in [upper, lower] { _ = try context.store.saveTemplate(template, at: date) }
        let draft = try context.store.saveProgram(try decoder().decode(valid), at: date)
        try context.store.discardProgramDraft(id: draft.id, expectedRevision: draft.revision)
        #expect(try context.store.program(id: draft.id) == nil)
        #expect(try context.store.programs().isEmpty)
        #expect(try context.store.templates().map(\.name).sorted() == ["Lower A", "Upper A"])
    }

    @Test func pendingTemplatesAreOnlyValidOnADraft() throws {
        var program = try decoder().decode(valid)
        program.status = .active
        #expect(throws: TrainError.invalidRecord) { try program.validate() }
        let context = try TrainTestDatabase()
        #expect(throws: TrainError.invalidRecord) { try context.store.saveProgram(program, at: date) }
    }

    @Test func oldProgramPayloadsStillDecodeWithoutNewFields() throws {
        let id = UUID(), templateID = UUID()
        let old = """
        {"schemaVersion":1,"id":"\(id.uuidString)","revision":1,"name":"Old","source":"manual","status":"active","startDay":"2023-10-30",
         "weeks":[[{"weekday":1,"templateID":"\(templateID.uuidString)","kind":"normal","tag":"UA"}]],
         "rules":{"earlyLightWeek":true,"earlyLightBelowScore":50,"earlyLightMinDays":5,"earlyLightWindowDays":7,"missed":"moveBack","calendarExport":false},
         "adjustments":[],"createdAt":0,"updatedAt":0}
        """
        let program = try JSONDecoder().decode(Program.self, from: Data(old.utf8))
        #expect(program.weeks[0][0].startMinute == nil && program.pendingTemplates == nil)
        try program.validate()
    }
}
