import Foundation
import StorageKit
import Testing
import TrainKit
import WorkoutKit

struct TrainStoreTests {
    private let date = TrainFixture.date

    // MARK: Templates

    @Test func templateSurvivesReopenAndKeepsEveryField() throws {
        let context = try TrainTestDatabase()
        let saved = try context.store.saveTemplate(TrainFixture.template(), at: date)
        #expect(saved.revision == 1 && saved.createdAt == date && saved.updatedAt == date)
        try context.database.databasePool.close()
        let reopened = try StorageDatabase(path: context.database.path, applicationVersion: "train-tests")
        defer { try? reopened.databasePool.close() }
        let store = TrainStore(database: reopened)
        #expect(try store.template(id: saved.id) == saved)
        #expect(try store.templates() == [saved])
        #expect(saved.exercises.map(\.exercise.name) == ["Barbell bench press", "Bent over row", "Cable triceps pushdown"])
        #expect(saved.progression == .doubleProgression(incrementKg: 2.5))
        #expect(saved.recoveryRule == RecoveryRule(enabled: true, belowScore: 34, setsRemoved: 1))
        #expect(saved.totalSets == 11)
    }

    @Test func cardioTemplateRoundTrips() throws {
        let context = try TrainTestDatabase()
        let saved = try context.store.saveTemplate(TrainFixture.cardio(), at: date)
        #expect(try context.store.template(id: saved.id)?.cardio == CardioTarget(activity: .run, minutes: 45, zone: 2))
    }

    @Test func templateSaveRejectsAStaleRevisionAndAMissingRecord() throws {
        let context = try TrainTestDatabase()
        let first = try context.store.saveTemplate(TrainFixture.template(), at: date)
        var edited = first
        edited.name = "Upper A heavy"
        let second = try context.store.saveTemplate(edited, at: date.addingTimeInterval(60))
        #expect(second.revision == 2 && second.createdAt == date && second.updatedAt == date.addingTimeInterval(60))
        var stale = first
        stale.name = "Overwrite"
        #expect(throws: TrainError.staleRevision) { try context.store.saveTemplate(stale, at: date) }
        #expect(try context.store.template(id: first.id)?.name == "Upper A heavy")
        // A new template must start at revision 0; a revision with no stored row means it was deleted elsewhere.
        let ghost = TrainFixture.template(revision: 3)
        #expect(throws: TrainError.missingRecord) { try context.store.saveTemplate(ghost, at: date) }
        let fresh = TrainFixture.template(id: first.id, revision: 0)
        #expect(throws: TrainError.staleRevision) { try context.store.saveTemplate(fresh, at: date) }
        #expect(try context.database.tableRowCounts()["workout_template"] == 1)
    }

    @Test func templateDeleteChecksRevision() throws {
        let context = try TrainTestDatabase()
        let saved = try context.store.saveTemplate(TrainFixture.template(), at: date)
        #expect(throws: TrainError.staleRevision) { try context.store.deleteTemplate(id: saved.id, expectedRevision: 9) }
        try context.store.deleteTemplate(id: saved.id, expectedRevision: saved.revision)
        #expect(try context.store.templates().isEmpty)
        #expect(throws: TrainError.missingRecord) { try context.store.deleteTemplate(id: saved.id, expectedRevision: saved.revision) }
    }

    @Test func invalidTemplatesNeverReachTheDatabase() throws {
        let context = try TrainTestDatabase()
        var emptyName = TrainFixture.template(); emptyName.name = "  "
        var inverted = TrainFixture.template(); inverted.exercises[0].repsMin = 9
        var negativeLoad = TrainFixture.template(); negativeLoad.exercises[0].loadKg = -5
        var unsortedDays = TrainFixture.template(); unsortedDays.weekdays = [.friday, .tuesday]
        var cardioWithoutTarget = TrainFixture.cardio(); cardioWithoutTarget.cardio = nil
        var strengthWithTarget = TrainFixture.template(); strengthWithTarget.cardio = .init(activity: .run, minutes: 30)
        var badIncrement = TrainFixture.template(); badIncrement.progression = .linear(incrementKg: 0)
        for value in [emptyName, inverted, negativeLoad, unsortedDays, cardioWithoutTarget, strengthWithTarget, badIncrement] {
            #expect(throws: TrainError.invalidRecord) { try context.store.saveTemplate(value, at: date) }
        }
        #expect(try context.database.tableRowCounts()["workout_template"] == 0)
    }

    @Test func supersetMembersMustBeAdjacentAndPaired() throws {
        let context = try TrainTestDatabase()
        let group = UUID()
        var adjacent = TrainFixture.template()
        adjacent.exercises = [TrainFixture.line(TrainFixture.bench, group: group), TrainFixture.line(TrainFixture.row, group: group), TrainFixture.line(TrainFixture.pushdown)]
        #expect(throws: Never.self) { try context.store.saveTemplate(adjacent, at: date) }
        var apart = adjacent
        apart.exercises = [TrainFixture.line(TrainFixture.bench, group: group), TrainFixture.line(TrainFixture.pushdown), TrainFixture.line(TrainFixture.row, group: group)]
        #expect(throws: TrainError.invalidRecord) { try context.store.saveTemplate(apart, at: date) }
        var alone = adjacent
        alone.exercises = [TrainFixture.line(TrainFixture.bench, group: group), TrainFixture.line(TrainFixture.row)]
        #expect(throws: TrainError.invalidRecord) { try context.store.saveTemplate(alone, at: date) }
    }

    // MARK: Programs and custom exercises

    @Test func programSurvivesReopenWithAdjustmentsAndRejectsStaleSaves() throws {
        let context = try TrainTestDatabase()
        let template = try context.store.saveTemplate(TrainFixture.template(), at: date)
        let saved = try context.store.saveProgram(TrainFixture.program(templateID: template.id), at: date)
        #expect(saved.revision == 1 && saved.weekCount == 8 && saved.templateIDs == [template.id])
        try context.database.databasePool.close()
        let reopened = try StorageDatabase(path: context.database.path, applicationVersion: "train-tests")
        defer { try? reopened.databasePool.close() }
        let store = TrainStore(database: reopened)
        #expect(try store.program(id: saved.id) == saved)
        #expect(try store.program(id: saved.id)?.adjustments.first?.reason == "Recovery averaged 46 over the last 7 days.")
        var paused = saved; paused.status = .paused
        let updated = try store.saveProgram(paused, at: date.addingTimeInterval(1))
        #expect(updated.revision == 2)
        #expect(throws: TrainError.staleRevision) { try store.saveProgram(paused, at: date) }
        #expect(try reopened.readString(sql: "SELECT status FROM workout_program") == "paused")
    }

    @Test func earlyLightDecisionsSurviveTheProgramPayload() throws {
        let context = try TrainTestDatabase()
        let template = try context.store.saveTemplate(TrainFixture.template(), at: date)
        var program = TrainFixture.program(templateID: template.id)
        program.adjustments = [
            .init(kind: .earlyLightWeek, week: 3, reason: "Week 3 is lighter. Recovery averaged 49 over the last 7 days.",
                  recoveryScore: 49, daysWithReadings: 7, createdAt: date),
            .init(kind: .earlyLightDeclined, week: 4, reason: "Week 4 stays as planned. Recovery averaged 52 over the last 7 days.",
                  recoveryScore: 52, daysWithReadings: 6, createdAt: date.addingTimeInterval(60)),
            .init(kind: .earlyLightDeclined, week: 5, reason: "Week 5 stays as planned. Only 2 of the last 7 days had a recovery reading.",
                  recoveryScore: nil, daysWithReadings: 2, createdAt: date.addingTimeInterval(120))
        ]
        let saved = try context.store.saveProgram(program, at: date)
        try context.database.databasePool.close()
        let reopened = try StorageDatabase(path: context.database.path, applicationVersion: "train-tests")
        defer { try? reopened.databasePool.close() }
        let loaded = try TrainStore(database: reopened).program(id: saved.id)
        #expect(loaded == saved)
        #expect(loaded?.adjustments.map(\.kind) == [.earlyLightWeek, .earlyLightDeclined, .earlyLightDeclined])
        #expect(loaded?.adjustments[1].recoveryScore == 52 && loaded?.adjustments[1].daysWithReadings == 6)
        #expect(loaded?.adjustments[2].recoveryScore == nil && loaded?.adjustments[2].daysWithReadings == 2)
        // The JSON itself round-trips, and a payload written before the field existed still decodes.
        let encoded = try JSONEncoder().encode(program.adjustments[1])
        #expect(try JSONDecoder().decode(ProgramAdjustment.self, from: encoded) == program.adjustments[1])
        let legacy = Data(#"{"id":"\#(UUID().uuidString)","kind":"earlyLightWeek","week":2,"reason":"Recovery averaged 46 over the last 7 days.","recoveryScore":46,"createdAt":0}"#.utf8)
        let decoded = try JSONDecoder().decode(ProgramAdjustment.self, from: legacy)
        #expect(decoded.daysWithReadings == nil && decoded.recoveryScore == 46)
    }

    @Test func aDeclinedAdjustmentNeedsAWeek() throws {
        let context = try TrainTestDatabase()
        var program = TrainFixture.program(templateID: UUID())
        program.adjustments = [.init(kind: .earlyLightDeclined, week: nil, reason: "Week stays as planned.", createdAt: date)]
        #expect(throws: TrainError.invalidRecord) { try context.store.saveProgram(program, at: date) }
        program.adjustments = [.init(kind: .earlyLightDeclined, week: 2, reason: "Week 2 stays as planned.", daysWithReadings: 31, createdAt: date)]
        #expect(throws: TrainError.invalidRecord) { try context.store.saveProgram(program, at: date) }
    }

    @Test func invalidProgramsAreRejected() throws {
        let context = try TrainTestDatabase()
        let id = UUID()
        var twoOnADay = TrainFixture.program(templateID: id)
        twoOnADay.weeks[0].append(ProgramSlot(weekday: .tuesday, templateID: id))
        var badStart = TrainFixture.program(templateID: id); badStart.startDay = "2023-02-30"
        var noWeeks = TrainFixture.program(templateID: id); noWeeks.weeks = []
        var lateAdjustment = TrainFixture.program(templateID: id)
        lateAdjustment.adjustments = [.init(kind: .earlyLightWeek, week: 9, reason: "Too late.", createdAt: date)]
        for value in [twoOnADay, badStart, noWeeks, lateAdjustment] {
            #expect(throws: TrainError.invalidRecord) { try context.store.saveProgram(value, at: date) }
        }
    }

    @Test func customExerciseRoundTripsAndChecksRevision() throws {
        let context = try TrainTestDatabase()
        let saved = try context.store.saveCustomExercise(TrainFixture.custom())
        #expect(saved.revision == 1 && saved.origin == .custom)
        #expect(try context.store.customExercise(key: saved.key) == saved)
        #expect(throws: TrainError.staleRevision) { try context.store.saveCustomExercise(TrainFixture.custom(revision: 0).withKey(saved.key)) }
        #expect(throws: TrainError.invalidRecord) {
            try context.store.saveCustomExercise(.init(key: "barbell-bench-press", name: "Bench", category: "strength"))
        }
        try context.store.deleteCustomExercise(key: saved.key, expectedRevision: 1)
        #expect(try context.store.customExercises().isEmpty)
    }

    // MARK: Sessions and sets

    @Test func sessionAndSetsSurviveReopenInOrder() throws {
        let context = try TrainTestDatabase()
        let saved = try context.store.saveSession(try TrainFixture.session(workoutID: UUID()))
        #expect(saved.revision == 1 && saved.localDay == TrainFixture.day)
        #expect(try context.database.tableRowCounts()["workout_set"] == 3)
        try context.database.databasePool.close()
        let reopened = try StorageDatabase(path: context.database.path, applicationVersion: "train-tests")
        defer { try? reopened.databasePool.close() }
        let store = TrainStore(database: reopened)
        let loaded = try #require(try store.session(id: saved.id))
        #expect(loaded == saved)
        #expect(loaded.exercises[0].sets.map(\.reps) == [8, 7, 0])
        #expect(loaded.exercises[0].sets[1].rpe == 8.5 && loaded.exercises[0].sets[1].edited)
        #expect(loaded.exercises[1].sets.isEmpty)
        #expect(try store.session(workoutID: #require(saved.workoutID))?.id == saved.id)
        #expect(try store.sessions(localDay: TrainFixture.day) == [saved])
        #expect(try store.sessions(localDay: "2023-11-16").isEmpty)
    }

    @Test func resavingASessionReplacesItsSetsAndRejectsStaleCopies() throws {
        let context = try TrainTestDatabase()
        let first = try context.store.saveSession(try TrainFixture.session(status: .active))
        var next = first
        next.exercises[0].sets.removeLast()
        next.exercises[1].sets = [LoggedSet(loadKg: 60, reps: 10, loggedAt: date.addingTimeInterval(900), prefillSource: .manual)]
        let second = try context.store.saveSession(next)
        #expect(second.revision == 2)
        #expect(try context.database.tableRowCounts()["workout_set"] == 3)
        #expect(try context.store.session(id: first.id)?.exercises[1].sets.map(\.loadKg) == [60])
        #expect(throws: TrainError.staleRevision) { try context.store.saveSession(next) }
        #expect(try context.store.session(id: first.id) == second)
    }

    @Test func skippedSetsDoNotCountTowardTonnage() throws {
        let session = try TrainFixture.session()
        #expect(session.countedSets.count == 2)
        #expect(session.tonnageKg == 80 * 8 + 80 * 7)
    }

    @Test func invalidSessionsAreRejected() throws {
        let context = try TrainTestDatabase()
        var badRPE = try TrainFixture.session(); badRPE.exercises[0].sets[0].rpe = 8.3
        var zeroReps = try TrainFixture.session(); zeroReps.exercises[0].sets[0].reps = 0
        var skippedWithReps = try TrainFixture.session(); skippedWithReps.exercises[0].sets[2].reps = 5
        var completedWithoutEnd = try TrainFixture.session(); completedWithoutEnd.endedAt = nil
        var endsBeforeStart = try TrainFixture.session(); endsBeforeStart.endedAt = date.addingTimeInterval(-1)
        var duplicateSet = try TrainFixture.session()
        duplicateSet.exercises[0].sets[1] = duplicateSet.exercises[0].sets[0]
        for value in [badRPE, zeroReps, skippedWithReps, completedWithoutEnd, endsBeforeStart, duplicateSet] {
            #expect(throws: TrainError.invalidRecord) { try context.store.saveSession(value) }
        }
        #expect(throws: TrainError.invalidRecord) {
            try TrainSession(name: "Upper A", startedAt: date, timeZoneIdentifier: "Not/AZone")
        }
        #expect(try context.database.tableRowCounts()["workout_session"] == 0)
    }

    @Test func personalBestsMustPointAtASetInTheSameSession() throws {
        let context = try TrainTestDatabase()
        var session = try TrainFixture.session()
        let set = session.exercises[0].sets[0]
        session.bests = [PersonalBest(exerciseKey: TrainFixture.bench.key, exerciseName: TrainFixture.bench.name, metric: .estimatedOneRepMax,
                                      value: 101.3, previousValue: nil, isBaseline: true, achievedAt: set.loggedAt, sessionID: session.id, setID: set.id)]
        let saved = try context.store.saveSession(session)
        #expect(try context.store.session(id: saved.id)?.bests == session.bests)
        var stray = saved
        stray.bests[0] = PersonalBest(exerciseKey: "x", exerciseName: "X", metric: .heaviestLoad, value: 1, isBaseline: true,
                                       achievedAt: date, sessionID: saved.id, setID: UUID())
        #expect(throws: TrainError.invalidRecord) { try context.store.saveSession(stray) }
        var baselineWithPrevious = saved
        baselineWithPrevious.bests[0].previousValue = 90
        #expect(throws: TrainError.invalidRecord) { try context.store.saveSession(baselineWithPrevious) }
    }

    @Test func recentSessionsComeNewestFirstAndFilterByStatus() throws {
        let context = try TrainTestDatabase()
        let old = try context.store.saveSession(try TrainFixture.session(startedAt: date.addingTimeInterval(-7 * 86_400)))
        let recent = try context.store.saveSession(try TrainFixture.session(startedAt: date))
        _ = try context.store.saveSession(try TrainFixture.session(startedAt: date.addingTimeInterval(86_400), status: .active))
        #expect(try context.store.recentSessions(limit: 5).map(\.id) == [recent.id, old.id])
        #expect(try context.store.recentSessions(limit: 1).map(\.id) == [recent.id])
        #expect(try context.store.recentSessions(limit: 5, status: nil).count == 3)
        #expect(try context.store.sessions().map(\.id).count == 3)
    }

    // MARK: Lifecycle

    @Test func deleteDayRemovesThatDaysSessionsAndSetsButKeepsPlans() throws {
        let context = try TrainTestDatabase()
        let template = try context.store.saveTemplate(TrainFixture.template(), at: date)
        _ = try context.store.saveProgram(TrainFixture.program(templateID: template.id), at: date)
        _ = try context.store.saveCustomExercise(TrainFixture.custom())
        let target = try context.store.saveSession(try TrainFixture.session())
        let other = try context.store.saveSession(try TrainFixture.session(startedAt: date.addingTimeInterval(2 * 86_400)))
        try context.store.deleteDay(target.localDay)
        #expect(try context.store.sessions().map(\.id) == [other.id])
        #expect(try context.database.tableRowCounts()["workout_set"] == 3)
        #expect(try context.database.readInteger(sql: "SELECT COUNT(*) FROM workout_set WHERE session_id = ?", arguments: [target.id.uuidString]) == 0)
        #expect(try context.store.templates().count == 1 && context.store.programs().count == 1 && context.store.customExercises().count == 1)
    }

    @Test func deleteAllEmptiesEveryTrainTable() throws {
        let context = try TrainTestDatabase()
        let template = try context.store.saveTemplate(TrainFixture.template(), at: date)
        _ = try context.store.saveProgram(TrainFixture.program(templateID: template.id), at: date)
        _ = try context.store.saveCustomExercise(TrainFixture.custom())
        _ = try context.store.saveSession(try TrainFixture.session())
        try context.store.deleteAll()
        let counts = try context.database.tableRowCounts()
        for table in TrainStorageSchema.tableNames { #expect(counts[table] == 0, "\(table)") }
    }

    @Test func archiveRoundTripRestoresEverythingThroughJSON() throws {
        let context = try TrainTestDatabase()
        let template = try context.store.saveTemplate(TrainFixture.template(), at: date)
        _ = try context.store.saveTemplate(TrainFixture.cardio(), at: date)
        _ = try context.store.saveProgram(TrainFixture.program(templateID: template.id), at: date)
        _ = try context.store.saveCustomExercise(TrainFixture.custom())
        _ = try context.store.saveSession(try TrainFixture.session(templateID: template.id))
        let archive = try context.store.exportArchive()
        #expect(archive.templates.count == 2 && archive.programs.count == 1 && archive.customExercises.count == 1 && archive.sessions.count == 1)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let decoded = try JSONDecoder().decode(TrainArchive.self, from: encoder.encode(archive))
        #expect(decoded == archive)
        try context.store.deleteAll()
        #expect(try context.store.exportArchive() == TrainArchive())
        try context.store.restore(decoded)
        #expect(try context.store.exportArchive() == archive)
        #expect(try context.store.sessions().first?.exercises[0].sets.count == 3)
    }

    @Test func dayArchiveCarriesOnlyThatDaysSessions() throws {
        let context = try TrainTestDatabase()
        let template = try context.store.saveTemplate(TrainFixture.template(), at: date)
        _ = try context.store.saveProgram(TrainFixture.program(templateID: template.id), at: date)
        let target = try context.store.saveSession(try TrainFixture.session())
        _ = try context.store.saveSession(try TrainFixture.session(startedAt: date.addingTimeInterval(86_400)))
        let archive = try context.store.exportArchive(localDay: target.localDay)
        #expect(archive.sessions == [target] && archive.templates.isEmpty && archive.programs.isEmpty && archive.customExercises.isEmpty)
        #expect(try context.store.exportArchive(localDay: "2024-02-02") == TrainArchive())
    }

    @Test func restoreReplacesExistingDataAndRollsBackOnInsertFailure() throws {
        let context = try TrainTestDatabase()
        let kept = try context.store.saveTemplate(TrainFixture.template(name: "Keep me"), at: date)
        let other = try TrainTestDatabase()
        let incoming = try other.store.saveTemplate(TrainFixture.template(name: "Incoming"), at: date)
        let archive = try other.store.exportArchive()
        try context.database.write { db in
            try db.execute(sql: "CREATE TRIGGER deny_train_insert BEFORE INSERT ON workout_template WHEN NEW.name = 'Incoming' BEGIN SELECT RAISE(ABORT, 'restore failure'); END")
        }
        #expect(throws: (any Error).self) { try context.store.restore(archive) }
        #expect(try context.store.templates() == [kept])
        try context.database.write { db in try db.execute(sql: "DROP TRIGGER deny_train_insert") }
        try context.store.restore(archive)
        #expect(try context.store.templates() == [incoming])
    }

    @Test func invalidArchivesAreRejectedBeforeAnythingIsDeleted() throws {
        let context = try TrainTestDatabase()
        let kept = try context.store.saveTemplate(TrainFixture.template(), at: date)
        var duplicate = kept
        duplicate.revision = 1
        let duplicated = TrainArchive(templates: [kept, duplicate])
        #expect(throws: TrainError.invalidRecord) { try context.store.restore(duplicated) }
        #expect(throws: TrainError.unsupportedVersion(9)) { try context.store.restore(TrainArchive(schemaVersion: 9)) }
        let unsaved = TrainArchive(templates: [TrainFixture.template()])
        #expect(throws: TrainError.invalidRecord) { try context.store.restore(unsaved) }
        #expect(try context.store.templates() == [kept])
        let json = Data(#"{"schemaVersion":1,"templates":[],"sessions":[{"bad":true}]}"#.utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(TrainArchive.self, from: json) }
    }

    @Test func sessionPayloadRejectsALocalDayThatDisagreesWithItsClock() throws {
        let session = try TrainFixture.session()
        let encoded = try JSONEncoder().encode(session)
        let tampered = String(decoding: encoded, as: UTF8.self).replacingOccurrences(of: TrainFixture.day, with: "2023-11-16")
        #expect(throws: TrainError.invalidRecord) { try JSONDecoder().decode(TrainSession.self, from: Data(tampered.utf8)) }
    }

    // MARK: Day helpers

    @Test func dayHelpersAgreeWithTheCalendar() throws {
        #expect(TrainDay.weekday(of: "2023-11-14") == .tuesday)
        #expect(TrainDay.weekday(of: "2023-10-30") == .monday)
        #expect(TrainDay.weekday(of: "2023-11-19") == .sunday)
        #expect(TrainDay.isValid("2024-02-29") && !TrainDay.isValid("2023-02-29") && !TrainDay.isValid("2023-2-9"))
        #expect(TrainDay.adding(days: 7, to: "2023-10-30") == "2023-11-06")
        #expect(TrainDay.adding(days: -1, to: "2024-03-01") == "2024-02-29")
        #expect(throws: TrainError.invalidRecord) { try TrainDay.string(at: date, timeZoneIdentifier: "Nowhere/Land") }
        #expect(try TrainDay.string(at: date, timeZoneIdentifier: "Australia/Perth") == "2023-11-15")
    }

    @Test func trainRouteIsHashableForNavigationPaths() {
        let id = UUID()
        let routes: Set<TrainRoute> = [.template(nil), .template(id), .program(id), .live, .summary(id), .libraryPicker, .template(id)]
        #expect(routes.count == 6)
    }
}

private extension ExerciseDefinition {
    /// A fresh custom exercise reusing an existing key, as a stale editor copy would.
    func withKey(_ key: String) -> ExerciseDefinition {
        ExerciseDefinition(key: key, name: name, category: category, equipment: equipment, primaryMuscles: primaryMuscles, origin: .custom, revision: revision)
    }
}
