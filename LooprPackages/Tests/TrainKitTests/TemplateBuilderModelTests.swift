import Foundation
import StorageKit
import Testing
import TrainKit

struct TemplateBuilderModelTests {
    private let date = TrainFixture.date
    private let en = Locale(identifier: "en_US")

    private func definition(_ key: String, _ name: String, equipment: String? = "barbell") -> ExerciseDefinition {
        ExerciseDefinition(key: key, name: name, category: "strength", equipment: equipment, primaryMuscles: ["chest"])
    }

    /// A model with four exercises A, B, C, D and a name, loaded as a saved template.
    private func loaded(names: [String] = ["A", "B", "C", "D"]) -> TemplateBuilderModel {
        let lines = names.map { TemplateExercise(exercise: ExerciseRef(key: $0.lowercased(), name: $0), sets: 3, repsMin: 8, repsMax: 10, loadKg: 40, restSeconds: 90) }
        return TemplateBuilderModel(template: WorkoutTemplate(revision: 1, name: "Upper A", exercises: lines))
    }

    private func saveError(_ model: inout TemplateBuilderModel, _ handler: @escaping TemplateBuilderModel.SaveHandler) async -> Error? {
        do { try await model.save(using: handler); return nil } catch { return error }
    }

    private func ids(_ model: TemplateBuilderModel) -> [String] { model.exercises.map(\.exercise.name) }

    private func id(_ model: TemplateBuilderModel, _ name: String) -> UUID {
        model.exercises.first { $0.exercise.name == name }!.id
    }

    /// Every superset in the list is contiguous and has at least two members.
    private func supersetsAreSound(_ model: TemplateBuilderModel) -> Bool {
        var closed = Set<UUID>()
        var open: UUID?
        var counts: [UUID: Int] = [:]
        for line in model.exercises {
            guard let group = line.supersetGroup else { if let open { closed.insert(open) }; open = nil; continue }
            if group != open {
                if let open { closed.insert(open) }
                if closed.contains(group) { return false }
                open = group
            }
            counts[group, default: 0] += 1
        }
        return counts.values.allSatisfy { $0 >= 2 } && (try? model.draft.validate()) != nil
    }

    // MARK: Dirty tracking

    @Test func aBlankTemplateIsCleanUntilSomethingChanges() {
        var model = TemplateBuilderModel.blank()
        #expect(model.isNew && !model.isDirty)
        model.name = "Push"
        #expect(model.isDirty)
        model.name = ""
        #expect(!model.isDirty)
    }

    @Test func editsMakeTheModelDirtyAndRevertingThemMakesItCleanAgain() {
        var model = loaded()
        #expect(!model.isDirty)
        model.bandRestCue.toggle()
        #expect(model.isDirty)
        model.bandRestCue.toggle()
        #expect(!model.isDirty)
        model.moveDown(id(model, "A"))
        #expect(model.isDirty)
        model.moveUp(id(model, "A"))
        #expect(!model.isDirty)
    }

    @Test func titleFollowsTheNameAndFallsBackWhileItIsBlank() {
        var model = TemplateBuilderModel.blank()
        #expect(model.title == "New workout")
        model.name = "  Pull day "
        #expect(model.title == "Pull day")
    }

    // MARK: Validation

    @Test func validationNamesWhatToFixInOrder() {
        var model = TemplateBuilderModel.blank()
        #expect(model.problem == .nameMissing && !model.canSave)
        #expect(model.problem?.message == "Name this workout to save it.")
        model.name = "   "
        #expect(model.problem == .nameMissing)
        model.name = "Push"
        #expect(model.problem == .noExercises)
        #expect(model.problem?.message == "Add at least one exercise to save this workout.")
        model.addExercise(definition("bench", "Bench press"))
        #expect(model.problem == nil && model.canSave)
    }

    @Test func validationFlagsAnOutOfRangeExerciseByName() {
        var model = loaded()
        var editor = model.editorDraft(for: id(model, "B"))!
        editor.sets = 3
        model.apply(editor, to: id(model, "B"))
        #expect(model.problem == nil)
        // Written around the editor's clamps to simulate a record loaded with a bad value.
        var template = model.draft
        template.exercises[1].sets = 99
        let broken = TemplateBuilderModel(template: template)
        #expect(broken.problem == .invalidExercise("B"))
        #expect(broken.problem?.message.contains("B") == true)
    }

    @Test func aWorkoutHoldsAtMostFortyExercises() {
        var model = TemplateBuilderModel.blank()
        model.name = "Big"
        for index in 0..<40 { #expect(model.addExercise(definition("e\(index)", "Exercise \(index)")) != nil) }
        #expect(!model.canAddExercise)
        #expect(model.addExercise(definition("extra", "Extra")) == nil)
        #expect(model.exercises.count == 40 && model.problem == nil)
    }

    @Test func cardioTemplatesNeedNoExercises() {
        var model = TemplateBuilderModel(template: TrainFixture.cardio())
        #expect(!model.isStrength && model.problem == nil)
        model.name = ""
        #expect(model.problem == .nameMissing)
        #expect(!model.canAddExercise)
    }

    @Test func savingAnInvalidDraftThrowsTheProblemAndNeverCallsStorage() async {
        var model = TemplateBuilderModel.blank()
        let calls = Counter()
        let failure = await saveError(&model) { template in await calls.bump(); return template }
        #expect(failure as? TemplateBuilderModel.Problem == .nameMissing)
        #expect(await calls.value == 0)
    }

    // MARK: Adding and removing

    @Test func addedExercisesStartWithUsableNumbersAndBodyOnlyStartsAsBodyweight() throws {
        var model = TemplateBuilderModel.blank()
        let addedBench = model.addExercise(definition("bench", "Bench press"))
        let addedDip = model.addExercise(definition("dip", "Dip", equipment: "body only"))
        let bench = try #require(addedBench)
        let dip = try #require(addedDip)
        let benchLine = try #require(model.exercise(id: bench))
        #expect(benchLine.sets == 3 && benchLine.repsMin == 8 && benchLine.repsMax == 12 && benchLine.restSeconds == 90)
        #expect(benchLine.loadKind == .weight && benchLine.loadKg == nil)
        #expect(model.exercise(id: dip)?.loadKind == .bodyweight)
        #expect(model.exercises.map(\.exercise.key) == ["bench", "dip"])
    }

    @Test func removingAMemberOfAPairDissolvesTheSuperset() {
        var model = loaded()
        model.linkWithNext(id(model, "B"))
        #expect(model.isLinkedWithNext(id(model, "B")))
        model.removeExercise(id: id(model, "C"))
        #expect(ids(model) == ["A", "B", "D"])
        #expect(model.exercises.allSatisfy { $0.supersetGroup == nil })
        #expect(supersetsAreSound(model))
    }

    @Test func removingFromALargerSupersetKeepsTheRestTogether() {
        var model = loaded()
        model.linkWithNext(id(model, "A"))
        model.linkWithNext(id(model, "B"))
        model.removeExercise(id: id(model, "B"))
        #expect(ids(model) == ["A", "C", "D"])
        #expect(model.isLinkedWithNext(id(model, "A")))
        #expect(model.blocks.map(\.exerciseIDs.count) == [2, 1])
        #expect(supersetsAreSound(model))
    }

    // MARK: Reordering

    @Test func moveUpAndDownShiftOneBlockAndStopAtTheEnds() {
        var model = loaded()
        #expect(!model.canMoveUp(id(model, "A")) && model.canMoveDown(id(model, "A")))
        #expect(model.canMoveUp(id(model, "D")) && !model.canMoveDown(id(model, "D")))
        model.moveUp(id(model, "A"))
        model.moveDown(id(model, "D"))
        #expect(ids(model) == ["A", "B", "C", "D"])
        model.moveDown(id(model, "A"))
        #expect(ids(model) == ["B", "A", "C", "D"])
        model.moveUp(id(model, "D"))
        #expect(ids(model) == ["B", "A", "D", "C"])
    }

    @Test func aSupersetMovesAsOneBlockAndStaysAdjacent() {
        var model = loaded(names: ["A", "B", "C", "D", "E"])
        model.linkWithNext(id(model, "B"))          // B and C
        model.moveDown(id(model, "A"))              // A jumps over the whole pair
        #expect(ids(model) == ["B", "C", "A", "D", "E"])
        #expect(model.isLinkedWithNext(id(model, "B")) && supersetsAreSound(model))
        model.moveDown(id(model, "C"))              // either member moves the pair
        #expect(ids(model) == ["A", "B", "C", "D", "E"])
        model.moveDown(id(model, "B"))
        #expect(ids(model) == ["A", "D", "B", "C", "E"])
        model.moveUp(id(model, "E"))                // E jumps over the whole pair
        #expect(ids(model) == ["A", "D", "E", "B", "C"])
        #expect(supersetsAreSound(model))
    }

    @Test func movingAnExerciseNeverSplitsASuperset() {
        var model = loaded(names: ["A", "B", "C", "D"])
        model.linkWithNext(id(model, "B"))
        for _ in 0..<4 {
            model.moveUp(id(model, "D"))
            #expect(supersetsAreSound(model))
        }
        #expect(ids(model) == ["D", "A", "B", "C"])
        for _ in 0..<4 {
            model.moveDown(id(model, "D"))
            #expect(supersetsAreSound(model))
        }
        #expect(ids(model) == ["A", "B", "C", "D"])
    }

    @Test func dropMovesTheDraggedBlockToTheTargetPosition() {
        var model = loaded(names: ["A", "B", "C", "D", "E"])
        model.linkWithNext(id(model, "D"))          // D and E
        model.move(id(model, "A"), onto: id(model, "D"))   // down: lands after the target block
        #expect(ids(model) == ["B", "C", "D", "E", "A"])
        model.move(id(model, "E"), onto: id(model, "B"))   // dragging a member drags the pair
        #expect(ids(model) == ["D", "E", "B", "C", "A"])
        model.move(id(model, "B"), onto: id(model, "B"))
        #expect(ids(model) == ["D", "E", "B", "C", "A"])
        #expect(supersetsAreSound(model))
    }

    // MARK: Supersets

    @Test func linkingAndUnlinkingBuildsAndSplitsGroups() {
        var model = loaded(names: ["A", "B", "C", "D"])
        #expect(!model.canLinkWithNext(id(model, "D")))
        model.linkWithNext(id(model, "A"))
        #expect(model.isLinkedWithNext(id(model, "A")) && model.isLinkedWithPrevious(id(model, "B")))
        model.linkWithNext(id(model, "B"))          // grows the pair to three
        #expect(model.blocks.map(\.exerciseIDs.count) == [3, 1])
        model.unlinkFromNext(id(model, "B"))        // C leaves; A and B stay paired
        #expect(model.blocks.map(\.exerciseIDs.count) == [2, 1, 1])
        model.unlinkFromNext(id(model, "A"))
        #expect(model.exercises.allSatisfy { $0.supersetGroup == nil })
        #expect(supersetsAreSound(model))
    }

    @Test func linkingTwoNeighbouringSupersetsMergesThem() {
        var model = loaded(names: ["A", "B", "C", "D"])
        model.linkWithNext(id(model, "A"))
        model.linkWithNext(id(model, "C"))
        #expect(model.blocks.map(\.exerciseIDs.count) == [2, 2])
        model.linkWithNext(id(model, "B"))
        #expect(model.blocks.map(\.exerciseIDs.count) == [4])
        #expect(supersetsAreSound(model))
        model.unlinkFromNext(id(model, "B"))
        #expect(model.blocks.map(\.exerciseIDs.count) == [2, 2])
    }

    // MARK: Exercise editor

    @Test func theEditorDraftCarriesTheNumbersAndTheNeighbours() throws {
        var model = loaded()
        model.linkWithNext(id(model, "B"))
        let draft = try #require(model.editorDraft(for: id(model, "B")))
        #expect(draft.sets == 3 && draft.repsMin == 8 && draft.repsMax == 10 && draft.loadKg == 40 && draft.restSeconds == 90)
        #expect(draft.hasPrevious && draft.hasNext && !draft.linkedWithPrevious && draft.linkedWithNext)
        let first = try #require(model.editorDraft(for: id(model, "A")))
        #expect(!first.hasPrevious && first.hasNext)
        #expect(model.editorDraft(for: UUID()) == nil)
    }

    @Test func applyingTheEditorWritesSetsRepsLoadRestAndNote() throws {
        var model = loaded()
        let target = id(model, "A")
        var editor = try #require(model.editorDraft(for: target))
        editor.sets = 5
        editor.setRepsMin(6)
        editor.setRepsMax(8)
        editor.loadKg = 82.5
        editor.restSeconds = 150
        editor.note = "Pause on the chest"
        model.apply(editor, to: target)
        let line = try #require(model.exercise(id: target))
        #expect(line.sets == 5 && line.repsMin == 6 && line.repsMax == 8 && line.loadKg == 82.5)
        #expect(line.restSeconds == 150 && line.note == "Pause on the chest")
        #expect(model.problem == nil)
    }

    @Test func repRangeBoundsPushEachOtherInsteadOfCrossing() {
        var editor = ExerciseEditorDraft(sets: 3, repsMin: 8, repsMax: 10, loadKg: 0, loadKind: .weight, restSeconds: 60, note: "")
        editor.setRepsMin(12)
        #expect(editor.repsMin == 12 && editor.repsMax == 12)
        editor.setRepsMax(5)
        #expect(editor.repsMin == 5 && editor.repsMax == 5)
        editor.setRepsMin(0)
        #expect(editor.repsMin == 1)
        editor.setRepsMax(500)
        #expect(editor.repsMax == 100)
    }

    @Test func applyClampsOutOfRangeNumbersAndBodyweightDropsTheLoad() throws {
        var model = loaded()
        let target = id(model, "A")
        var editor = try #require(model.editorDraft(for: target))
        editor.sets = 0
        editor.restSeconds = 99_999
        editor.loadKg = 5_000
        model.apply(editor, to: target)
        var line = try #require(model.exercise(id: target))
        #expect(line.sets == 1 && line.restSeconds == 3_600 && line.loadKg == 1_000)
        #expect(model.problem == nil)
        editor.loadKind = .bodyweight
        model.apply(editor, to: target)
        line = try #require(model.exercise(id: target))
        #expect(line.loadKind == .bodyweight && line.loadKg == nil)
        editor.loadKind = .weight
        editor.loadKg = 0
        model.apply(editor, to: target)
        #expect(model.exercise(id: target)?.loadKg == nil)
    }

    @Test func applyingTheEditorCanLinkAndUnlinkNeighbours() throws {
        var model = loaded()
        let b = id(model, "B")
        var editor = try #require(model.editorDraft(for: b))
        editor.linkedWithPrevious = true
        editor.linkedWithNext = true
        model.apply(editor, to: b)
        #expect(model.blocks.map(\.exerciseIDs.count) == [3, 1])
        #expect(supersetsAreSound(model))
        editor = try #require(model.editorDraft(for: b))
        #expect(editor.linkedWithPrevious && editor.linkedWithNext)
        editor.linkedWithPrevious = false
        model.apply(editor, to: b)
        #expect(model.blocks.map(\.exerciseIDs.count) == [1, 2, 1])
        editor = try #require(model.editorDraft(for: b))
        editor.linkedWithNext = false
        model.apply(editor, to: b)
        #expect(model.exercises.allSatisfy { $0.supersetGroup == nil })
    }

    @Test func theEditorMovesItsBlockAndStopsAtTheEnds() throws {
        var model = loaded(names: ["A", "B", "C", "D"])
        model.linkWithNext(id(model, "B"))
        var editor = try #require(model.editorDraft(for: id(model, "A")))
        #expect(editor.blockIndex == 0 && editor.blockCount == 3 && !editor.canMoveUp && editor.canMoveDown && !editor.isInSuperset)
        editor.moveUp()
        #expect(editor.blockShift == 0)
        editor.moveDown()
        editor.moveDown()
        editor.moveDown()
        #expect(editor.blockShift == 2 && editor.pendingBlockIndex == 2 && !editor.canMoveDown)
        model.apply(editor, to: id(model, "A"))
        #expect(ids(model) == ["B", "C", "D", "A"] && supersetsAreSound(model))
        var pair = try #require(model.editorDraft(for: id(model, "C")))
        #expect(pair.isInSuperset && pair.blockIndex == 0)
        pair.moveDown()
        model.apply(pair, to: id(model, "C"))
        #expect(ids(model) == ["D", "B", "C", "A"] && supersetsAreSound(model))
    }

    // MARK: Rules

    @Test func theRecoveryToggleKeepsItsThresholdAndNewTemplatesStartOff() {
        var model = TemplateBuilderModel.blank()
        #expect(!model.recoveryEnabled && model.draft.recoveryRule == nil)
        model.recoveryEnabled = false
        #expect(model.draft.recoveryRule == nil && !model.isDirty)
        model.recoveryEnabled = true
        #expect(model.draft.recoveryRule == RecoveryRule(enabled: true, belowScore: 34, setsRemoved: 1))
        model.recoveryEnabled = false
        #expect(model.draft.recoveryRule == RecoveryRule(enabled: false, belowScore: 34, setsRemoved: 1))
        model = TemplateBuilderModel(template: WorkoutTemplate(name: "X", recoveryRule: RecoveryRule(enabled: true, belowScore: 40, setsRemoved: 2)))
        model.recoveryEnabled = false
        model.recoveryEnabled = true
        #expect(model.draft.recoveryRule == RecoveryRule(enabled: true, belowScore: 40, setsRemoved: 2))
    }

    @Test func weekdaysStaySortedAndUnique() {
        var model = TemplateBuilderModel.blank()
        model.weekdays = [.saturday, .tuesday, .saturday]
        #expect(model.draft.weekdays == [.tuesday, .saturday])
        #expect(model.weekdays == [.tuesday, .saturday])
    }

    // MARK: Saving and storage

    @Test func rulesAndEditsSurviveASaveThroughTheStoreAndARevisionBump() async throws {
        let context = try TrainTestDatabase()
        let store = context.store
        let date = self.date
        let handler: TemplateBuilderModel.SaveHandler = { @Sendable template in try store.saveTemplate(template, at: date) }

        var model = TemplateBuilderModel.blank()
        model.name = "  Upper A "
        model.weekdays = [.saturday, .tuesday]
        let addedBench = model.addExercise(definition("bench", "Bench press"))
        let bench = try #require(addedBench)
        _ = model.addExercise(definition("incline", "Incline press"))
        _ = model.addExercise(definition("row", "Chest-supported row"))
        _ = model.addExercise(definition("raise", "Lateral raise"))
        var editor = try #require(model.editorDraft(for: bench))
        editor.sets = 4
        editor.setRepsMin(6)
        editor.setRepsMax(8)
        editor.loadKg = 80
        editor.restSeconds = 150
        model.apply(editor, to: bench)
        model.linkWithNext(id(model, "Incline press"))
        model.moveDown(bench)
        model.progression = .doubleProgression(incrementKg: 2.5)
        model.recoveryEnabled = true
        model.bandRestCue = false
        #expect(model.isDirty && model.isNew)

        try await model.save(using: handler)
        #expect(!model.isDirty && !model.isNew)
        #expect(model.original.revision == 1 && model.draft.revision == 1 && model.draft.name == "Upper A")

        let stored = try #require(try store.template(id: model.draft.id))
        #expect(stored == model.draft)
        #expect(stored.weekdays == [.tuesday, .saturday])
        #expect(stored.exercises.map(\.exercise.name) == ["Incline press", "Chest-supported row", "Bench press", "Lateral raise"])
        #expect(stored.exercises[0].supersetGroup != nil && stored.exercises[0].supersetGroup == stored.exercises[1].supersetGroup)
        #expect(stored.exercises[2].sets == 4 && stored.exercises[2].repsMin == 6 && stored.exercises[2].repsMax == 8)
        #expect(stored.exercises[2].loadKg == 80 && stored.exercises[2].restSeconds == 150)
        #expect(stored.progression == .doubleProgression(incrementKg: 2.5))
        #expect(stored.recoveryRule == RecoveryRule(enabled: true, belowScore: 34, setsRemoved: 1))
        #expect(stored.bandRestCue == false)

        // A second edit saves against revision 1 and lands as revision 2.
        model.progression = .linear(incrementKg: 5)
        model.recoveryEnabled = false
        model.bandRestCue = true
        try await model.save(using: handler)
        let again = try #require(try store.template(id: model.draft.id))
        #expect(again.revision == 2 && again.progression == .linear(incrementKg: 5) && again.bandRestCue)
        #expect(again.recoveryRule?.enabled == false)
        #expect(try store.templates().count == 1)
    }

    @Test func aStaleModelCannotOverwriteNewerWorkAndStaysDirty() async throws {
        let context = try TrainTestDatabase()
        let store = context.store
        let date = self.date
        let handler: TemplateBuilderModel.SaveHandler = { @Sendable template in try store.saveTemplate(template, at: date) }
        let saved = try store.saveTemplate(TrainFixture.template(), at: date)
        var first = TemplateBuilderModel(template: saved)
        var second = TemplateBuilderModel(template: saved)
        first.name = "Upper A heavy"
        try await first.save(using: handler)
        second.name = "Overwrite"
        let failure = await saveError(&second, handler)
        #expect(failure as? TrainError == .staleRevision)
        #expect(second.isDirty && second.draft.revision == 1)
        #expect(try store.template(id: saved.id)?.name == "Upper A heavy")
    }

    @Test func savingAnUnchangedExistingTemplateWritesNothing() async throws {
        let calls = Counter()
        var model = loaded()
        try await model.save { template in await calls.bump(); return template }
        #expect(await calls.value == 0)
        model.bandRestCue.toggle()
        try await model.save { template in await calls.bump(); var stored = template; stored.revision += 1; return stored }
        #expect(await calls.value == 1 && !model.isDirty && model.original.revision == 2)
    }

    @Test func aSavedTemplateReopensWithTheSameDraft() async throws {
        let context = try TrainTestDatabase()
        let store = context.store
        let date = self.date
        var model = TemplateBuilderModel(template: try store.saveTemplate(TrainFixture.template(), at: date))
        model.linkWithNext(model.exercises[0].id)
        try await model.save { @Sendable template in try store.saveTemplate(template, at: date) }
        let reopened = TemplateBuilderModel(template: try #require(try store.template(id: model.draft.id)))
        #expect(reopened.draft == model.draft && !reopened.isDirty)
        #expect(reopened.blocks.map(\.exerciseIDs.count) == [2, 1])
        try reopened.draft.validate()
    }

    // MARK: Wording

    @Test func exerciseRowTextMatchesTheRowContract() {
        let bench = TemplateExercise(exercise: ExerciseRef(key: "b", name: "Bench press"), sets: 4, repsMin: 6, repsMax: 8, loadKg: 80, restSeconds: 150)
        #expect(TemplateBuilderFormat.spec(bench, locale: en) == "4 × 6–8 · 80 kg")
        #expect(TemplateBuilderFormat.restText(bench) == "2:30")
        #expect(TemplateBuilderFormat.spokenLabel(bench, locale: en) == "Bench press, 4 sets of 6 to 8 reps, at 80 kilograms, rest 2 minutes 30 seconds")
        let curl = TemplateExercise(exercise: ExerciseRef(key: "c", name: "Cable curl"), sets: 3, repsMin: 12, repsMax: 12, loadKg: 22.5, restSeconds: 60)
        #expect(TemplateBuilderFormat.spec(curl, locale: en) == "3 × 12 · 22.5 kg")
        #expect(TemplateBuilderFormat.restText(curl) == "1:00")
        #expect(TemplateBuilderFormat.spokenLabel(curl, includeRest: false, locale: en) == "Cable curl, 3 sets of 12 reps, at 22.5 kilograms")
        let pullUp = TemplateExercise(exercise: ExerciseRef(key: "p", name: "Pull-up"), sets: 1, repsMin: 5, repsMax: 5, loadKind: .bodyweight, restSeconds: 0)
        #expect(TemplateBuilderFormat.spec(pullUp, locale: en) == "1 × 5 · Bodyweight")
        #expect(TemplateBuilderFormat.restText(pullUp) == nil)
        #expect(TemplateBuilderFormat.spokenLabel(pullUp, locale: en) == "Pull-up, 1 set of 5 reps, bodyweight")
        let unloaded = TemplateExercise(exercise: ExerciseRef(key: "u", name: "Row"), sets: 3, repsMin: 8, repsMax: 8)
        #expect(TemplateBuilderFormat.spec(unloaded, locale: en) == "3 × 8")
    }

    @Test func summaryAndRuleWording() {
        #expect(TemplateBuilderFormat.exerciseSummary(TemplateSummary(exerciseCount: 0, totalSets: 0, estimatedMinutes: 0)) == "No exercises yet")
        #expect(TemplateBuilderFormat.exerciseSummary(TemplateSummary(exerciseCount: 1, totalSets: 3, estimatedMinutes: 12)) == "1 exercise, about 12 min")
        #expect(TemplateBuilderFormat.exerciseSummary(TemplateSummary(exerciseCount: 6, totalSets: 20, estimatedMinutes: 55)) == "6 exercises, about 55 min")
        #expect(TemplateBuilderFormat.progressionSummary(.doubleProgression(incrementKg: 2.5), locale: en) == "Add 2.5 kg when every set reaches the top of the range")
        #expect(TemplateBuilderFormat.progressionSummary(.none, locale: en) == "No automatic increase. You choose each load.")
        #expect(TemplateBuilderFormat.progressionSummary(.linear(incrementKg: 5), locale: en).hasPrefix("Add 5 kg after each session"))
        #expect(TemplateBuilderFormat.recoverySummary(RecoveryRule()) == "One set fewer per lift below 34")
        #expect(TemplateBuilderFormat.recoverySummary(RecoveryRule(enabled: true, belowScore: 40, setsRemoved: 2)) == "2 sets fewer per lift below 40")
        #expect(TemplateBuilderFormat.rest(seconds: 90) == "1:30" && TemplateBuilderFormat.rest(seconds: 5) == "0:05")
        #expect(ExerciseEquipment.bodyOnly.displayName == "Body only")
        #expect(TemplateBuilderFormat.capitalized("lower back") == "Lower back")
    }

    @Test func copyHasNoEmDashesOrExclamationMarks() {
        let messages: [String] = [
            TemplateBuilderModel.Problem.nameMissing.message, TemplateBuilderModel.Problem.noExercises.message,
            TemplateBuilderModel.Problem.tooManyExercises.message, TemplateBuilderModel.Problem.invalidExercise("Row").message,
            TemplateBuilderModel.Problem.invalid.message,
            TemplateBuilderFormat.progressionSummary(.none), TemplateBuilderFormat.progressionSummary(.linear(incrementKg: 2.5)),
            TemplateBuilderFormat.progressionSummary(.doubleProgression(incrementKg: 2.5)),
            TemplateBuilderFormat.recoverySummary(RecoveryRule())
        ]
        for message in messages { #expect(!message.contains("—") && !message.contains("!")) }
    }
}

private actor Counter {
    private(set) var value = 0
    func bump() { value += 1 }
}
