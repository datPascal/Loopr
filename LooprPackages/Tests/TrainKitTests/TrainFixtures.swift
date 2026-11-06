import Foundation
import StorageKit
import TrainKit
import WorkoutKit

/// A throwaway SQLite database per test. Fixtures use the name Alex and Australia/Perth.
final class TrainTestDatabase {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("TrainKitTests-\(UUID().uuidString)")
    let database: StorageDatabase
    var store: TrainStore { TrainStore(database: database) }
    init() throws { database = try StorageDatabase(url: root.appendingPathComponent("train.sqlite"), applicationVersion: "train-tests") }
    deinit { try? database.databasePool.close(); try? FileManager.default.removeItem(at: root) }
}

enum TrainFixture {
    /// Tuesday 2023-11-14 22:13:20 UTC, which is Wednesday 2023-11-15 in Perth.
    static let date = Date(timeIntervalSince1970: 1_700_000_000)
    static let zone = "Australia/Perth"
    static let day = "2023-11-15"

    static let bench = ExerciseRef(key: "barbell-bench-press", name: "Barbell bench press")
    static let row = ExerciseRef(key: "bent-over-row", name: "Bent over row")
    static let pushdown = ExerciseRef(key: "cable-triceps-pushdown", name: "Cable triceps pushdown")

    static func line(_ ref: ExerciseRef, sets: Int = 4, group: UUID? = nil) -> TemplateExercise {
        .init(exercise: ref, sets: sets, repsMin: 6, repsMax: 8, loadKg: 80, restSeconds: 150, supersetGroup: group)
    }

    static func template(id: UUID = UUID(), name: String = "Upper A", revision: Int = 0) -> WorkoutTemplate {
        .init(id: id, revision: revision, name: name, weekdays: [.tuesday, .friday],
              exercises: [line(bench), line(row), line(pushdown, sets: 3)],
              progression: .doubleProgression(incrementKg: 2.5), recoveryRule: .init(), bandRestCue: true)
    }

    static func cardio(name: String = "Zone 2") -> WorkoutTemplate {
        .init(name: name, kind: .cardio, weekdays: [.thursday], cardio: .init(activity: .run, minutes: 45, zone: 2))
    }

    static func program(templateID: UUID, id: UUID = UUID(), revision: Int = 0, status: ProgramStatus = .active) -> Program {
        let week = [ProgramSlot(weekday: .tuesday, templateID: templateID, kind: .normal, tag: "UA"),
                    ProgramSlot(weekday: .friday, templateID: templateID, kind: .heavy, tag: "UA")]
        return .init(id: id, revision: revision, name: "Strength block", request: "Eight weeks, four days, lighter weeks 4 and 7",
                     source: .agent, status: status, startDay: "2023-10-30", weeks: Array(repeating: week, count: 8),
                     rules: .init(calendarExport: true),
                     adjustments: [.init(kind: .earlyLightWeek, week: 5, reason: "Recovery averaged 46 over the last 7 days.", recoveryScore: 46, createdAt: date)])
    }

    static func custom(revision: Int = 0) -> ExerciseDefinition {
        var value = ExerciseDefinition.custom(id: UUID(), name: "Sled push", equipment: "sled", primaryMuscles: ["quadriceps"])
        value.revision = revision
        return value
    }

    static func session(id: UUID = UUID(), startedAt: Date = date, status: TrainSessionStatus = .completed,
                        workoutID: UUID? = nil, templateID: UUID? = nil) throws -> TrainSession {
        let sets = [
            LoggedSet(loadKg: 80, reps: 8, rpe: 7, loggedAt: startedAt.addingTimeInterval(120), prefillSource: .template),
            LoggedSet(loadKg: 80, reps: 7, rpe: 8.5, loggedAt: startedAt.addingTimeInterval(300), prefillSource: .previousSet, edited: true),
            LoggedSet(loadKg: nil, reps: 0, loggedAt: startedAt.addingTimeInterval(480), prefillSource: .previousSet, skipped: true)
        ]
        let benchLine = SessionExercise(planned: line(bench), status: .done, sets: sets)
        let rowLine = SessionExercise(planned: line(row), status: .pending)
        return try TrainSession(id: id, workoutID: workoutID, templateID: templateID, name: "Upper A", programWeek: 3,
            startedAt: startedAt, timeZoneIdentifier: zone, endedAt: status == .active ? nil : startedAt.addingTimeInterval(3_600),
            status: status, recoveryAtStart: 79, exercises: [benchLine, rowLine])
    }
}
