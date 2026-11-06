import Foundation
import Testing
@testable import TrainKit

/// Measures per exercise line (reps and weight, bodyweight with added or assisted load, time, distance),
/// set tags, and what each does to validation, bests, volume, the live model, the summary and the CSV.
struct SetMeasureTests {
    private let start = TrainFixture.date
    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    private let plank = ExerciseRef(key: "Plank", name: "Plank")
    private let carry = ExerciseRef(key: "Farmers_Walk", name: "Farmer's walk")
    private let pullUp = ExerciseRef(key: "Pullups", name: "Pull-up")

    private func hold(sets: Int = 3, seconds: Int = 45) -> TemplateExercise {
        TemplateExercise(exercise: plank, sets: sets, repsMin: 1, repsMax: 1, measure: .time, targetSeconds: seconds, restSeconds: 60)
    }

    private func walk(sets: Int = 3) -> TemplateExercise {
        TemplateExercise(exercise: carry, sets: sets, repsMin: 1, repsMax: 1, loadKg: 32, measure: .distance, targetMetres: 40,
                         restSeconds: 90)
    }

    private func assisted(sets: Int = 3, assist: Double = 20) -> TemplateExercise {
        TemplateExercise(exercise: pullUp, sets: sets, repsMin: 6, repsMax: 8, measure: .bodyweight, assistKg: assist, restSeconds: 120)
    }

    private func session(_ lines: [SessionExercise], daysAgo: Double, name: String = "Lower A") throws -> TrainSession {
        let began = start.addingTimeInterval(-daysAgo * 86_400)
        return try TrainSession(name: name, startedAt: began, timeZoneIdentifier: TrainFixture.zone,
                                endedAt: began.addingTimeInterval(3_000), status: .completed, exercises: lines)
    }

    private func line(_ plan: TemplateExercise, _ sets: [LoggedSet]) -> SessionExercise {
        SessionExercise(planned: plan, status: .done, sets: sets)
    }

    private func live(_ exercises: [TemplateExercise], history: [TrainSession] = []) throws -> TrainLiveModel {
        try TrainLiveModel(setup: TrainLiveSetup(template: WorkoutTemplate(name: "Lower A", exercises: exercises), history: history,
                                                 timeZoneIdentifier: TrainFixture.zone), now: start)
    }

    // MARK: Decoding old payloads

    @Test func anOldTemplateLineDecodesItsLoadKindAsTheMeasure() throws {
        let id = UUID()
        func json(_ kind: String?) -> Data {
            let kindField = kind.map { "\"loadKind\": \"\($0)\"," } ?? ""
            return Data("""
            {"id": "\(id.uuidString)", "exercise": {"key": "Pullups", "name": "Pull-up"}, "sets": 4, "repsMin": 6, "repsMax": 8,
             \(kindField) "restSeconds": 150, "note": ""}
            """.utf8)
        }
        let bodyweight = try JSONDecoder().decode(TemplateExercise.self, from: json("bodyweight"))
        #expect(bodyweight.measure == .bodyweight && bodyweight.loadKind == .bodyweight && bodyweight.assistKg == nil)
        let weight = try JSONDecoder().decode(TemplateExercise.self, from: json("weight"))
        #expect(weight.measure == .weight && weight.targetSeconds == nil)
        #expect(try JSONDecoder().decode(TemplateExercise.self, from: json(nil)).measure == .weight)
        try bodyweight.validate()
    }

    @Test func aNewTemplateLineStillWritesLoadKindForOlderBuilds() throws {
        let line = hold()
        let data = try JSONEncoder().encode(line)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["loadKind"] as? String == "weight")
        #expect(object["measure"] as? String == "time")
        #expect(object["targetSeconds"] as? Int == 45)
        #expect(try JSONDecoder().decode(TemplateExercise.self, from: data) == line)
    }

    @Test func anOldSessionPayloadDecodesWithNoSecondsMetresAssistOrTag() throws {
        let original = try TrainFixture.session()
        var payload = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        // Strip every key an old build never wrote.
        var exercises = try #require(payload["exercises"] as? [[String: Any]])
        for index in exercises.indices {
            var planned = try #require(exercises[index]["planned"] as? [String: Any])
            for key in ["measure", "assistKg", "targetSeconds", "targetMetres"] { planned.removeValue(forKey: key) }
            exercises[index]["planned"] = planned
            var sets = exercises[index]["sets"] as? [[String: Any]] ?? []
            for set in sets.indices { for key in ["seconds", "metres", "assistKg", "tag"] { sets[set].removeValue(forKey: key) } }
            exercises[index]["sets"] = sets
        }
        payload["exercises"] = exercises
        let decoded = try JSONDecoder().decode(TrainSession.self, from: JSONSerialization.data(withJSONObject: payload))
        try decoded.validate()
        #expect(decoded == original)
        #expect(decoded.exercises[0].sets.allSatisfy { $0.seconds == nil && $0.metres == nil && $0.assistKg == nil && $0.tag == nil })
    }

    // MARK: Default measure

    @Test func theDefaultMeasureComesFromCategoryEquipmentAndName() {
        func measure(_ name: String, _ category: String = "strength", _ equipment: String? = nil) -> TrainSetMeasure {
            TrainSetMeasure.defaultMeasure(name: name, category: category, equipment: equipment)
        }
        #expect(measure("Plank", "strength", "body only") == .time)
        #expect(measure("Side Plank") == .time)
        #expect(measure("Side Bridge", "strength", "body only") == .time)
        #expect(measure("Dead hang", "strength", "other") == .time)
        #expect(measure("L-sit") == .time)
        #expect(measure("Hollow hold", "strength", "body only") == .time)
        #expect(measure("Wall sit") == .time)
        #expect(measure("Hamstring Stretch", "stretching", "body only") == .time)
        #expect(measure("Farmer's Walk", "strongman", "other") == .distance)
        #expect(measure("Rickshaw Carry", "strongman") == .distance)
        #expect(measure("Sled Push", "strongman") == .distance)
        #expect(measure("Sled Row", "strength", "other") == .weight, "a sled row is reps")
        #expect(measure("Hang Clean", "olympic weightlifting", "barbell") == .weight, "a lift from the hang is not a hold")
        #expect(measure("Hanging Leg Raise", "strength", "body only") == .bodyweight)
        #expect(measure("Push Up to Side Plank", "strength", "body only") == .bodyweight)
        #expect(measure("Pullups", "strength", "body only") == .bodyweight)
        #expect(measure("Barbell Bench Press", "strength", "barbell") == .weight)
    }

    @Test func anExerciseAddedToATemplateTakesItsDefaultMeasureAndTarget() throws {
        var model = TemplateBuilderModel.blank()
        let addedPlank = model.addExercise(ExerciseDefinition(key: "Plank", name: "Plank", category: "strength", equipment: "body only"))
        let addedWalk = model.addExercise(ExerciseDefinition(key: "Farmers_Walk", name: "Farmer's Walk", category: "strongman", equipment: "other"))
        let plankID = try #require(addedPlank)
        let walkID = try #require(addedWalk)
        #expect(model.exercise(id: plankID)?.measure == .time && model.exercise(id: plankID)?.targetSeconds == 30)
        #expect(model.exercise(id: walkID)?.measure == .distance && model.exercise(id: walkID)?.targetMetres == 40)
        #expect(TemplateBuilderFormat.spec(try #require(model.exercise(id: plankID))) == "3 × 0:30")
    }

    // MARK: Validation

    @Test func validationFollowsTheMeasure() throws {
        let set = { (reps: Int, seconds: Int?, metres: Double?, load: Double?, assist: Double?) in
            LoggedSet(loadKg: load, reps: reps, loggedAt: self.start, seconds: seconds, metres: metres, assistKg: assist)
        }
        try set(0, 45, nil, nil, nil).validate(measure: .time)
        try set(0, nil, 40, 32, nil).validate(measure: .distance)
        try set(150, nil, nil, nil, nil).validate(measure: .bodyweight)
        try set(8, nil, nil, nil, 20).validate(measure: .bodyweight)
        #expect(throws: TrainError.invalidRecord) { try set(150, nil, nil, 80, nil).validate(measure: .weight) }
        #expect(throws: TrainError.invalidRecord) { try set(8, nil, nil, 10, 20).validate(measure: .bodyweight) }
        #expect(throws: TrainError.invalidRecord) { try set(0, nil, nil, nil, nil).validate(measure: .time) }
        #expect(throws: TrainError.invalidRecord) { try set(0, nil, nil, 32, nil).validate(measure: .distance) }
        #expect(throws: TrainError.invalidRecord) { try set(8, nil, nil, nil, 20).validate(measure: .weight) }
        var line = assisted()
        line.repsMax = 500
        try line.validate()
        line.loadKg = 10
        #expect(throws: TrainError.invalidRecord) { try line.validate() }
    }

    // MARK: Warm-ups

    @Test func warmUpsCountForNothing() throws {
        let bench = TrainFixture.line(TrainFixture.bench)
        let sets = [LoggedSet(loadKg: 40, reps: 10, loggedAt: at(0), tag: .warmUp),
                    LoggedSet(loadKg: 60, reps: 5, loggedAt: at(60), tag: .warmUp),
                    LoggedSet(loadKg: 80, reps: 8, loggedAt: at(200)),
                    LoggedSet(loadKg: 70, reps: 10, loggedAt: at(400), tag: .drop)]
        let finished = try session([line(bench, sets)], daysAgo: 0)
        #expect(finished.tonnageKg == 80 * 8 + 70 * 10)
        #expect(finished.countedSets.count == 2 && finished.warmUpSetCount == 2 && finished.hasWorkingSet)
        let history = ExerciseHistory(sessions: [finished])
        #expect(history.exercises[0].entries[0].sets.count == 2 && history.exercises[0].entries[0].warmUpCount == 2)
        let warmUpsOnly = try session([line(bench, Array(sets.prefix(2)))], daysAgo: 0)
        #expect(!warmUpsOnly.hasWorkingSet && warmUpsOnly.tonnageKg == 0)
        #expect(TrainSummaryModel(session: warmUpsOnly).weekLine.contains("does not count"))
        #expect(DoseSession(trainSession: warmUpsOnly) == nil, "warm-ups earn no strength dot")
        #expect(DoseSession(trainSession: finished) != nil)
        #expect(PersonalBestEvaluator.bestValues(exerciseKey: TrainFixture.bench.key, in: [warmUpsOnly]) == nil)
        // A warm-up never feeds the next set's suggestion.
        let prefill = SetPrefill.resolve(setIndex: 2, planned: bench, progression: .none, thisSession: Array(sets.prefix(2)), lastSession: nil)
        #expect(prefill.loadKg == 80 && prefill.source == .template)
        // Nor progression: two working sets of four planned is incomplete.
        let decision = ProgressionEvaluator.evaluate(rule: .doubleProgression(incrementKg: 2.5), planned: bench, performed: sets)
        #expect(decision.reason == .setsIncomplete)
    }

    // MARK: Bests

    @Test func eachMeasureSetsItsOwnBests() throws {
        let older = try session([
            line(hold(), [LoggedSet(loadKg: nil, reps: 0, loggedAt: at(-86_400 * 7), seconds: 40)]),
            line(walk(), [LoggedSet(loadKg: 28, reps: 0, loggedAt: at(-86_400 * 7 + 60), metres: 40)]),
            line(assisted(), [LoggedSet(loadKg: nil, reps: 8, loggedAt: at(-86_400 * 7 + 120), assistKg: 25)])
        ], daysAgo: 7)
        var today = try session([
            line(hold(), [LoggedSet(loadKg: nil, reps: 0, loggedAt: at(0), seconds: 55),
                          LoggedSet(loadKg: nil, reps: 0, loggedAt: at(60), seconds: 90, tag: .warmUp)]),
            line(walk(), [LoggedSet(loadKg: 32, reps: 0, loggedAt: at(120), metres: 45)]),
            line(assisted(), [LoggedSet(loadKg: nil, reps: 7, loggedAt: at(180), assistKg: 17.5)])
        ], daysAgo: 0)
        let bests = PersonalBestEvaluator.evaluate(session: today, history: [older])
        func best(_ metric: PersonalBest.Metric) -> PersonalBest? { bests.first { $0.metric == metric } }
        #expect(best(.longestHold)?.value == 55 && best(.longestHold)?.previousValue == 40, "the 90 s warm-up does not count")
        #expect(best(.longestDistance)?.value == 45 && best(.longestDistance)?.previousValue == 40)
        #expect(best(.leastAssistance)?.value == 17.5 && best(.leastAssistance)?.previousValue == 25, "less help is better")
        #expect(best(.estimatedOneRepMax) == nil && best(.heaviestLoad) == nil, "no estimate outside weight sets")
        today.bests = bests
        let summary = TrainSummaryModel(session: today)
        #expect(summary.headline == .held(seconds: 55))
        #expect(summary.weekLine == "Counts as 1 strength session this week.")
        #expect(summary.bests.contains { $0.metricTitle == "Least assistance" && $0.valueText == "17.5 kg assist" && $0.previousText == "Was 25 kg assist" })
        #expect(summary.bests.contains { $0.metricTitle == "Longest hold" && $0.valueText == "0:55" })
    }

    @Test func aBodyweightSetWithAddedLoadIsNoOneRepMax() throws {
        let dip = TemplateExercise(exercise: ExerciseRef(key: "dip", name: "Dip"), sets: 3, repsMin: 6, repsMax: 8, measure: .bodyweight)
        let first = try session([line(dip, [LoggedSet(loadKg: 10, reps: 8, loggedAt: at(-86_400))])], daysAgo: 1)
        let second = try session([line(dip, [LoggedSet(loadKg: 15, reps: 6, loggedAt: at(0))])], daysAgo: 0)
        let bests = PersonalBestEvaluator.evaluate(session: second, history: [first])
        #expect(bests.map(\.metric) == [.mostAddedLoad])
        #expect(TrainSummaryModel.valueText(.mostAddedLoad, 15) == "+15 kg")
    }

    // MARK: Live model

    @Test func timeDistanceAndAssistedSetsLogInTheirOwnUnits() throws {
        var model = try live([hold(sets: 2), walk(sets: 1), assisted(sets: 1)])
        #expect(model.currentPrefill?.seconds == 45 && model.currentPrefill?.reps == 0)
        let held = try model.logSet(TrainSetValues(loadKg: 0, reps: 0, seconds: 50), now: at(10))
        #expect(held.seconds == 50 && held.reps == 0 && held.loadKg == nil)
        #expect(model.currentPrefill?.seconds == 50, "the next hold starts from the last one")
        #expect(throws: TrainLiveError.invalidValue) { try model.logSet(TrainSetValues(seconds: 0), now: at(20)) }
        try model.logSet(TrainSetValues(seconds: 40), now: at(80))
        #expect(model.currentPrefill?.metres == 40 && model.currentPrefill?.loadKg == 32)
        let walked = try model.logSet(TrainSetValues(loadKg: 32, metres: 40, assistKg: 5), now: at(200))
        #expect(walked.metres == 40 && walked.assistKg == nil, "assistance belongs to bodyweight only")
        #expect(model.currentPrefill?.assistKg == 20)
        #expect(throws: TrainLiveError.invalidValue) { try model.logSet(TrainSetValues(loadKg: 10, reps: 8, assistKg: 20), now: at(300)) }
        let pulled = try model.logSet(TrainSetValues(reps: 150, assistKg: 20), now: at(300))
        #expect(pulled.reps == 150, "bodyweight goes to 1,000 reps")
        #expect(model.loggedSummary == "4 sets, 1:30 held, 40 m covered")
        let finished = try model.finish(now: at(400))
        try finished.validate()
        #expect(TrainSummaryModel(session: finished).headline == .held(seconds: 90))
    }

    @Test func aSetIsMarkedARecordOnlyAfterItBeatsABest() throws {
        let before = try session([line(hold(), [LoggedSet(loadKg: nil, reps: 0, loggedAt: at(-86_400), seconds: 50)])], daysAgo: 1)
        var model = try live([hold(sets: 3)], history: [before])
        try model.logSet(TrainSetValues(seconds: 45), now: at(10))
        try model.logSet(TrainSetValues(seconds: 55), now: at(100))
        try model.logSet(TrainSetValues(seconds: 55), now: at(200))
        #expect(model.tableRows(forExerciseAt: 0).map(\.isRecord) == [false, true, false], "an equal hold is not a record")
        var first = try live([hold(sets: 1)])
        try first.logSet(TrainSetValues(seconds: 30), now: at(10))
        #expect(first.tableRows(forExerciseAt: 0).map(\.isRecord) == [false], "a first time is a baseline")
    }

    @Test func aTagCanBeSetAndClearedOnALoggedSet() throws {
        var model = try live([TrainFixture.line(TrainFixture.bench)])
        try model.logSet(loadKg: 40, reps: 10, now: at(0))
        try model.setTag(.warmUp, exerciseIndex: 0, setIndex: 0)
        #expect(model.tableRows(forExerciseAt: 0)[0].tag == .warmUp && model.countedSetCount == 0)
        #expect(model.loggedSummary == nil)
        try model.setTag(nil, exerciseIndex: 0, setIndex: 0)
        #expect(model.countedSetCount == 1)
        try model.skipSet(now: at(60))
        #expect(throws: TrainLiveError.noSuchSet) { try model.setTag(.drop, exerciseIndex: 0, setIndex: 1) }
    }

    @Test func theMeasureCanChangeOnlyBeforeTheFirstSet() throws {
        var model = try live([TrainFixture.line(ExerciseRef(key: "hang", name: "Hang"), sets: 2)])
        try model.setMeasure(.time, forExerciseAt: 0)
        #expect(model.measure(ofExerciseAt: 0) == .time && model.currentPrefill?.seconds == 30 && model.currentPrefill?.loadKg == nil)
        try model.logSet(TrainSetValues(seconds: 30), now: at(0))
        #expect(throws: TrainLiveError.measureLocked) { try model.setMeasure(.weight, forExerciseAt: 0) }
    }

    @Test func theRestCardAsksAboutTheLastSetAndSuggestsTheLastRPE() throws {
        let bench = TrainFixture.line(TrainFixture.bench)
        let before = try session([line(bench, [LoggedSet(loadKg: 80, reps: 8, rpe: 8.5, loggedAt: at(-86_400))])], daysAgo: 1, name: "Upper A")
        var model = try live([bench], history: [before])
        try model.logSet(loadKg: 80, reps: 8, now: at(10))
        #expect(model.lastLoggedPosition == .init(exerciseIndex: 0, setIndex: 0))
        #expect(model.suggestedRPE(exerciseIndex: 0, setIndex: 0) == 8.5, "last session's RPE")
        try model.setRPE(7, exerciseIndex: 0, setIndex: 0)
        try model.logSet(loadKg: 80, reps: 8, now: at(200))
        #expect(model.suggestedRPE(exerciseIndex: 0, setIndex: 1) == 7, "today's RPE wins")
    }

    @Test func anAddedExerciseTakesItsMeasureFromTheLibraryOrLastTime() throws {
        var model = try TrainLiveModel(setup: .freeform(timeZoneIdentifier: TrainFixture.zone), now: start)
        try model.addExercise(ExerciseDefinition(key: "Plank", name: "Plank", category: "strength", equipment: "body only"))
        #expect(model.measure(ofExerciseAt: 0) == .time && model.currentPrefill?.seconds == 30)
        let before = try session([line(assisted(), [LoggedSet(loadKg: nil, reps: 7, loggedAt: at(-86_400), assistKg: 20)])], daysAgo: 1)
        var again = try TrainLiveModel(setup: .freeform(history: [before], timeZoneIdentifier: TrainFixture.zone), now: start)
        try again.addExercise(ExerciseDefinition(key: "Pullups", name: "Pullups", category: "strength", equipment: "body only"))
        #expect(again.currentPrefill?.assistKg == 20 && again.currentPrefill?.reps == 7)
        #expect(again.lastTimeSummary(forExerciseAt: 0) == "Last time 20 kg assist × 7")
    }

    @MainActor
    @Test func theDraftKeepsOnlyTheLoadItsToggleSays() {
        var draft = TrainLiveSession.Draft(loadKg: 10, reps: 8, assistKg: 20, bodyweightLoad: .assisted)
        #expect(draft.values(for: .bodyweight) == TrainSetValues(reps: 8, assistKg: 20))
        draft.bodyweightLoad = .added
        #expect(draft.values(for: .bodyweight) == TrainSetValues(loadKg: 10, reps: 8))
        draft.bodyweightLoad = .none
        #expect(draft.values(for: .bodyweight) == TrainSetValues(reps: 8))
        #expect(TrainLiveSession.Draft(loadKg: 0, reps: 0, seconds: 45).values(for: .time) == TrainSetValues(loadKg: 0, reps: 0, seconds: 45))
    }

    // MARK: Text

    @Test func setTextWritesAssistanceAndAddedLoadInWords() {
        #expect(TrainSetFormat.set(TrainSetValues(reps: 8, assistKg: 20), measure: .bodyweight) == "20 kg assist × 8")
        #expect(TrainSetFormat.set(TrainSetValues(loadKg: 10, reps: 6), measure: .bodyweight) == "+10 kg × 6")
        #expect(TrainSetFormat.set(TrainSetValues(reps: 12), measure: .bodyweight) == "12 reps")
        #expect(TrainSetFormat.bodyweight(addedKg: nil, assistKg: 17.5) == "17.5 kg assist")
        #expect(TrainSetFormat.bodyweight(addedKg: 10, assistKg: nil) == "+10 kg")
        #expect(TrainSetFormat.bodyweight(addedKg: nil, assistKg: nil) == "Bodyweight")
        #expect(TrainSetFormat.set(TrainSetValues(seconds: 45), measure: .time) == "0:45")
        #expect(TrainSetFormat.set(TrainSetValues(loadKg: 32, metres: 40), measure: .distance) == "40 m at 32 kg")
        #expect(TrainSetFormat.spoken(TrainSetValues(reps: 8, assistKg: 20), measure: .bodyweight) == "20 kilograms of assistance, 8 reps")
        #expect(TemplateBuilderFormat.spec(assisted(sets: 4)) == "4 × 6–8 · 20 kg assist")
        #expect(TemplateBuilderFormat.spec(walk()) == "3 × 40 m · 32 kg")
        #expect(TemplateBuilderFormat.spokenLabel(hold(), includeRest: false) == "Plank, 3 sets of 45 seconds")
        #expect(!TrainSetFormat.set(TrainSetValues(reps: 8, assistKg: 20), measure: .bodyweight).contains("\u{2014}"))
        #expect(!TrainSetFormat.set(TrainSetValues(reps: 8, assistKg: 20), measure: .bodyweight).contains("\u{2212}"))
    }

    @Test func theCSVCarriesTheMeasureSecondsMetresAssistAndTag() throws {
        let finished = try session([
            line(hold(), [LoggedSet(loadKg: nil, reps: 0, loggedAt: at(0), seconds: 45, tag: .warmUp)]),
            line(walk(), [LoggedSet(loadKg: 32, reps: 0, loggedAt: at(60), metres: 40)]),
            line(assisted(), [LoggedSet(loadKg: nil, reps: 8, loggedAt: at(120), assistKg: 20)])
        ], daysAgo: 0)
        let lines = TrainCSV.sets([finished]).split(separator: "\r\n").map(String.init)
        #expect(lines[1].hasSuffix(",Plank,time,45,,,warm_up"))
        #expect(lines[2].hasSuffix(",Farmers_Walk,distance,,40,,"))
        #expect(lines[3].hasSuffix(",Pullups,bodyweight,,,20,"))
        #expect(lines[3].contains(",8,,,no,"), "no estimated 1RM outside weight sets")
    }

    @Test func theEditorWritesTargetsInTheMeasuresUnit() throws {
        var model = TemplateBuilderModel(template: WorkoutTemplate(name: "Upper A", exercises: [TrainFixture.line(pullUp)]))
        let id = model.exercises[0].id
        var editor = try #require(model.editorDraft(for: id))
        editor.measure = .bodyweight
        editor.bodyweightLoad = .assisted
        editor.assistKg = 25
        editor.setRepsMax(300)
        model.apply(editor, to: id)
        var line = try #require(model.exercise(id: id))
        #expect(line.measure == .bodyweight && line.assistKg == 25 && line.loadKg == nil && line.repsMax == 300)
        #expect(model.problem == nil)
        editor = try #require(model.editorDraft(for: id))
        #expect(editor.bodyweightLoad == .assisted && editor.assistKg == 25)
        editor.measure = .time
        editor.targetSeconds = 60
        model.apply(editor, to: id)
        line = try #require(model.exercise(id: id))
        #expect(line.measure == .time && line.targetSeconds == 60 && line.assistKg == nil && line.loadKg == nil)
        #expect(model.problem == nil)
    }
}
