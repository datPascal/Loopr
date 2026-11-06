#if DEBUG
import Foundation
import StorageKit
import TrainKit
import WorkoutKit

/// Seeded Train data for `--loopr-train-fixture`. Alex trains in Australia/Perth.
/// The fixture day is Tuesday 2023-11-14, week 3 of the "Strength block" that
/// started on Monday 2023-10-30, so today is Upper A. Everything here goes into
/// a separate temporary SQLite database and an in-memory workout store. It never
/// reaches production storage.
nonisolated enum AppTrainFixtures {
    static let argument = "--loopr-train-fixture"
    /// Adds an agent-built draft program ("Spring base") on top of the fixture. It implies `--loopr-train-fixture`.
    static let draftArgument = "--loopr-train-draft-fixture"

    /// True for `--loopr-train-fixture`, for a variant such as `--loopr-train-fixture=live`, and for the draft fixture.
    static func isRequested(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        arguments.contains { $0 == argument || $0.hasPrefix(argument + "=") || $0 == draftArgument }
    }

    static func isDraftRequested(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        arguments.contains(draftArgument)
    }

    // MARK: Launch arguments

    static let storeArgument = "--loopr-train-fixture-store="
    static let restSecondsArgument = "--loopr-train-fixture-rest-seconds="

    /// The name from `--loopr-train-fixture-store=<name>`, cleaned to letters, digits, dots, dashes and underscores.
    /// A UI test that relaunches passes a name of its own, and the fixture database then outlives the process.
    static func storeName(arguments: [String] = ProcessInfo.processInfo.arguments) -> String? {
        guard let value = arguments.first(where: { $0.hasPrefix(storeArgument) }).map({ String($0.dropFirst(storeArgument.count)) }) else { return nil }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let cleaned = String(value.filter { allowed.contains($0) }.prefix(64))
        // A name made only of dots would point at a parent folder.
        return cleaned.contains(where: { $0 != "." }) ? cleaned : nil
    }

    /// Where a named fixture database lives. Caches survive a relaunch and iOS may clear them when the app is not running.
    static func stableRoot(named name: String) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("LooprTrainFixtureStores", isDirectory: true).appendingPathComponent(name, isDirectory: true)
    }

    /// Seconds from `--loopr-train-fixture-rest-seconds=<n>`. A UI test passes 2 so a whole session stays short.
    static func restSecondsOverride(arguments: [String] = ProcessInfo.processInfo.arguments) -> Int? {
        arguments.first(where: { $0.hasPrefix(restSecondsArgument) })
            .flatMap { Int($0.dropFirst(restSecondsArgument.count)) }
            .map { min(max($0, 0), 3_600) }
    }

    static let zone = TimeZone(identifier: "Australia/Perth") ?? .gmt
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    /// Tuesday 2023-11-14, 10:00 in Perth.
    static let now = Date(timeIntervalSince1970: 1_699_927_200)

    // MARK: Identifiers

    private static func id(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "7A0460FE-0000-4000-8000-%012d", suffix)) ?? UUID()
    }

    static let upperAID = id(1)
    static let lowerAID = id(2)
    static let lowerBID = id(3)
    static let upperBID = id(4)
    static let zoneTwoID = id(5)
    static let strengthBlockID = id(11)
    static let halfMarathonID = id(12)
    static let lowerASessionID = id(21)
    static let priorUpperASessionID = id(22)
    static let firstLowerASessionID = id(23)
    /// Curl and pushdown run as a superset, as on the workout builder mock.
    static let upperAArmsSupersetID = id(41)
    /// Alex's own exercise, so the exercise picker shows Your exercises.
    static let tempoSquatID = id(51)
    /// The linked workout records. WorkoutFixtures use 701 to 703, so these stay clear of them.
    static let lowerAWorkoutID = UUID(uuidString: "00000000-0000-0000-0000-000000000711") ?? UUID()
    static let priorUpperAWorkoutID = UUID(uuidString: "00000000-0000-0000-0000-000000000712") ?? UUID()

    // MARK: Time

    private static func perth(_ year: Int, _ month: Int, _ day: Int, hour: Int = 17, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)) ?? .distantPast
    }

    static let lowerAStart = perth(2023, 11, 13)
    static let lowerAEnd = lowerAStart.addingTimeInterval(62 * 60)
    static let priorUpperAStart = perth(2023, 11, 7)
    static let priorUpperAEnd = priorUpperAStart.addingTimeInterval(58 * 60)

    // MARK: Templates

    private static func exercise(_ key: String, _ name: String, sets: Int, reps: ClosedRange<Int>, kg: Double?,
                                 rest: Int, bodyweight: Bool = false, assistKg: Double? = nil, superset: UUID? = nil) -> TemplateExercise {
        TemplateExercise(exercise: ExerciseRef(key: key, name: name), sets: sets, repsMin: reps.lowerBound, repsMax: reps.upperBound,
                         loadKg: kg, loadKind: bodyweight ? .bodyweight : .weight, assistKg: assistKg, restSeconds: rest,
                         supersetGroup: superset)
    }

    /// A timed hold, such as a plank.
    private static func hold(_ key: String, _ name: String, sets: Int, seconds: Int, rest: Int) -> TemplateExercise {
        TemplateExercise(exercise: ExerciseRef(key: key, name: name), sets: sets, repsMin: 1, repsMax: 1, measure: .time,
                         targetSeconds: seconds, restSeconds: rest)
    }

    /// A carry over a distance, such as a farmer's walk.
    private static func carry(_ key: String, _ name: String, sets: Int, metres: Double, kg: Double, rest: Int) -> TemplateExercise {
        TemplateExercise(exercise: ExerciseRef(key: key, name: name), sets: sets, repsMin: 1, repsMax: 1, loadKg: kg, measure: .distance,
                         targetMetres: metres, restSeconds: rest)
    }

    static var upperA: WorkoutTemplate {
        WorkoutTemplate(id: upperAID, name: "Upper A", weekdays: [.tuesday], exercises: [
            exercise("Barbell_Bench_Press_-_Medium_Grip", "Bench press", sets: 4, reps: 6...8, kg: 80, rest: 150),
            // Band-assisted: the green band takes about 20 kg off.
            exercise("Pullups", "Pull-up", sets: 4, reps: 6...8, kg: nil, rest: 150, bodyweight: true, assistKg: 20),
            exercise("Bent_Over_Barbell_Row", "Barbell row", sets: 4, reps: 6...8, kg: 70, rest: 150),
            exercise("Barbell_Shoulder_Press", "Overhead press", sets: 3, reps: 8...10, kg: 40, rest: 120),
            exercise("Dumbbell_Bicep_Curl", "Dumbbell curl", sets: 4, reps: 10...12, kg: 14, rest: 0, superset: upperAArmsSupersetID),
            exercise("cable-triceps-pushdown", "Cable triceps pushdown", sets: 3, reps: 12...12, kg: 25, rest: 120, superset: upperAArmsSupersetID)
        ], progression: .doubleProgression(incrementKg: 2.5), recoveryRule: RecoveryRule(), bandRestCue: true)
    }

    static var lowerA: WorkoutTemplate {
        WorkoutTemplate(id: lowerAID, name: "Lower A", weekdays: [.monday], exercises: [
            exercise("Barbell_Squat", "Back squat", sets: 4, reps: 6...8, kg: 100, rest: 180),
            exercise("Romanian_Deadlift", "Romanian deadlift", sets: 4, reps: 8...10, kg: 90, rest: 150),
            exercise("Leg_Press", "Leg press", sets: 3, reps: 9...12, kg: 60, rest: 120),
            hold("Plank", "Plank", sets: 3, seconds: 45, rest: 60),
            carry("Farmers_Walk", "Farmer's walk", sets: 3, metres: 40, kg: 32, rest: 90)
        ], progression: .doubleProgression(incrementKg: 2.5), recoveryRule: RecoveryRule(), bandRestCue: true)
    }

    static var lowerB: WorkoutTemplate {
        WorkoutTemplate(id: lowerBID, name: "Lower B", weekdays: [.thursday], exercises: [
            exercise("Front_Barbell_Squat", "Front squat", sets: 4, reps: 5...6, kg: 70, rest: 180),
            exercise("Barbell_Hip_Thrust", "Hip thrust", sets: 4, reps: 8...10, kg: 100, rest: 150),
            exercise("Barbell_Walking_Lunge", "Walking lunge", sets: 3, reps: 10...12, kg: 30, rest: 90),
            exercise("Lying_Leg_Curls", "Lying leg curl", sets: 3, reps: 10...12, kg: 35, rest: 90),
            exercise("Standing_Calf_Raises", "Standing calf raise", sets: 3, reps: 12...15, kg: 60, rest: 60)
        ], progression: .doubleProgression(incrementKg: 2.5), recoveryRule: RecoveryRule(), bandRestCue: true)
    }

    static var upperB: WorkoutTemplate {
        WorkoutTemplate(id: upperBID, name: "Upper B", weekdays: [.saturday], exercises: [
            exercise("Barbell_Shoulder_Press", "Overhead press", sets: 4, reps: 6...8, kg: 45, rest: 150),
            exercise("Chin-Up", "Chin-up", sets: 4, reps: 6...8, kg: nil, rest: 150, bodyweight: true),
            exercise("Incline_Dumbbell_Press", "Incline dumbbell press", sets: 3, reps: 8...10, kg: 28, rest: 120),
            exercise("Seated_Cable_Rows", "Seated cable row", sets: 3, reps: 10...12, kg: 55, rest: 90)
        ], progression: .doubleProgression(incrementKg: 2.5), recoveryRule: RecoveryRule(), bandRestCue: true)
    }

    static var zoneTwo: WorkoutTemplate {
        WorkoutTemplate(id: zoneTwoID, name: "Zone 2", kind: .cardio, weekdays: [.wednesday],
                        cardio: CardioTarget(activity: .run, minutes: 45, zone: 2))
    }

    // MARK: Programs

    /// Eight weeks. Weeks 4 and 7 are lighter, week 3 has heavy lower and upper B days, and week 8 tests
    /// a heavy single on Monday and Thursday (tag MAX).
    static var strengthBlock: Program {
        func week(_ number: Int) -> [ProgramSlot] {
            let light = number == 4 || number == 7
            let heavy = number == 3
            let peak = number == 8
            func kind(_ heavyDay: Bool) -> ProgramSlotKind { light ? .light : heavy && heavyDay ? .heavy : .normal }
            return [
                ProgramSlot(weekday: .monday, templateID: lowerAID, kind: peak ? .heavy : kind(false), tag: peak ? "MAX" : "LA"),
                // 18:30, after the protocol's daily Zone 2 (17:30 to 18:15), so the two never overlap (R3-OPT-6).
                ProgramSlot(weekday: .tuesday, templateID: upperAID, kind: kind(false), tag: "UA", startMinute: 18 * 60 + 30),
                ProgramSlot(weekday: .wednesday, templateID: zoneTwoID, kind: .normal, tag: "Z2"),
                ProgramSlot(weekday: .thursday, templateID: lowerBID, kind: peak ? .heavy : kind(true), tag: peak ? "MAX" : "LB"),
                ProgramSlot(weekday: .saturday, templateID: upperBID, kind: kind(true), tag: "UB")
            ]
        }
        return Program(id: strengthBlockID, name: "Strength block",
                       request: "Eight weeks, four strength days and an easy run, lighter weeks 4 and 7",
                       source: .agent, status: .active, startDay: "2023-10-30", weeks: (1...8).map(week),
                       rules: ProgramRules())
    }

    static var halfMarathon: Program {
        Program(id: halfMarathonID, name: "Half marathon", source: .manual, status: .paused, startDay: "2023-09-04",
                weeks: Array(repeating: [ProgramSlot(weekday: .sunday, templateID: zoneTwoID, tag: "Z2")], count: 12))
    }

    // MARK: Sessions

    private static func loggedSets(_ plan: TemplateExercise, loads: [Double], reps: [Int], start: Date, rpe: [Double?] = [],
                                   assistKg: Double? = nil) -> SessionExercise {
        let sets = zip(loads, reps).enumerated().map { index, pair in
            LoggedSet(loadKg: pair.0 > 0 ? pair.0 : nil, reps: pair.1, rpe: index < rpe.count ? rpe[index] : nil,
                      loggedAt: start.addingTimeInterval(Double(index) * 210), prefillSource: .template, assistKg: assistKg)
        }
        return SessionExercise(planned: plan, status: .done, sets: sets)
    }

    private static func heldSets(_ plan: TemplateExercise, seconds: [Int], start: Date) -> SessionExercise {
        let sets = seconds.enumerated().map { index, value in
            LoggedSet(loadKg: nil, reps: 0, loggedAt: start.addingTimeInterval(Double(index) * 120), prefillSource: .template,
                      seconds: value)
        }
        return SessionExercise(planned: plan, status: .done, sets: sets)
    }

    private static func carriedSets(_ plan: TemplateExercise, metres: [Double], kg: Double, start: Date) -> SessionExercise {
        let sets = metres.enumerated().map { index, value in
            LoggedSet(loadKg: kg, reps: 0, loggedAt: start.addingTimeInterval(Double(index) * 150), prefillSource: .template,
                      metres: value)
        }
        return SessionExercise(planned: plan, status: .done, sets: sets)
    }

    /// Monday 13 November, 62 minutes, 8,420 kg: 3,200 + 3,600 + 1,620. Then planks for 0:45, 0:50 and 0:40, a new
    /// longest hold, and three 40 m farmer's walks at 32 kg. Holds and carries add no volume.
    static func lowerASession() throws -> TrainSession {
        let plan = lowerA.exercises
        return try TrainSession(
            id: lowerASessionID, workoutID: lowerAWorkoutID, templateID: lowerAID, name: "Lower A", programID: strengthBlockID,
            programWeek: 3, startedAt: lowerAStart, timeZoneIdentifier: zone.identifier, endedAt: lowerAEnd, status: .completed,
            recoveryAtStart: 70,
            exercises: [
                loggedSets(plan[0], loads: [100, 100, 100, 100], reps: [8, 8, 8, 8], start: lowerAStart),
                loggedSets(plan[1], loads: [90, 90, 90, 90], reps: [10, 10, 10, 10], start: lowerAStart.addingTimeInterval(1_500)),
                loggedSets(plan[2], loads: [60, 60, 60], reps: [9, 9, 9], start: lowerAStart.addingTimeInterval(3_000)),
                heldSets(plan[3], seconds: [45, 50, 40], start: lowerAStart.addingTimeInterval(3_300)),
                carriedSets(plan[4], metres: [40, 40, 40], kg: 32, start: lowerAStart.addingTimeInterval(3_500))
            ])
    }

    /// Tuesday 7 November. Bench 80 kg for 7, 7, 6, 6 is what the live session shows as "last time". Pull-ups with
    /// the green band, 20 kg of assistance, for 8, 7, 6, 6.
    static func priorUpperASession() throws -> TrainSession {
        let plan = upperA.exercises
        return try TrainSession(
            id: priorUpperASessionID, workoutID: priorUpperAWorkoutID, templateID: upperAID, name: "Upper A", programID: strengthBlockID,
            programWeek: 2, startedAt: priorUpperAStart, timeZoneIdentifier: zone.identifier, endedAt: priorUpperAEnd,
            status: .completed, recoveryAtStart: 64,
            exercises: [
                loggedSets(plan[0], loads: [80, 80, 80, 80], reps: [7, 7, 6, 6], start: priorUpperAStart, rpe: [7, 8, 8.5, 9]),
                loggedSets(plan[1], loads: [0, 0, 0, 0], reps: [8, 7, 6, 6], start: priorUpperAStart.addingTimeInterval(1_000),
                           assistKg: 20),
                loggedSets(plan[2], loads: [70, 70, 70, 70], reps: [8, 8, 7, 7], start: priorUpperAStart.addingTimeInterval(2_000)),
                loggedSets(plan[3], loads: [40, 40, 40], reps: [10, 9, 8], start: priorUpperAStart.addingTimeInterval(3_000)),
                loggedSets(plan[4], loads: [14, 14, 14, 14], reps: [12, 11, 10, 10], start: priorUpperAStart.addingTimeInterval(3_500)),
                loggedSets(plan[5], loads: [25, 25, 25], reps: [12, 12, 11], start: priorUpperAStart.addingTimeInterval(4_000))
            ])
    }

    /// Monday 30 October, week 1. Squat 100 kg for 6 gives an estimated max of 120 kg, so the Program screen
    /// can show how the estimate moved by Lower A in week 3 (100 kg for 8).
    static func firstLowerASession() throws -> TrainSession {
        let plan = lowerA.exercises
        let start = perth(2023, 10, 30)
        return try TrainSession(
            id: firstLowerASessionID, workoutID: nil, templateID: lowerAID, name: "Lower A", programID: strengthBlockID,
            programWeek: 1, startedAt: start, timeZoneIdentifier: zone.identifier, endedAt: start.addingTimeInterval(58 * 60),
            status: .completed, recoveryAtStart: 66,
            exercises: [
                loggedSets(plan[0], loads: [100, 100, 100, 100], reps: [6, 6, 6, 6], start: start),
                loggedSets(plan[1], loads: [90, 90, 90], reps: [10, 10, 10], start: start.addingTimeInterval(1_500)),
                heldSets(plan[3], seconds: [40, 40], start: start.addingTimeInterval(3_000)),
                carriedSets(plan[4], metres: [40, 40], kg: 28, start: start.addingTimeInterval(3_300))
            ])
    }

    /// Writes the plans and the finished sessions.
    static func seed(_ store: TrainStore) throws {
        let date = perth(2023, 10, 28)
        for template in [upperA, lowerA, lowerB, upperB, zoneTwo] { try store.saveTemplate(template, at: date) }
        _ = try store.saveProgram(strengthBlock, at: date)
        _ = try store.saveProgram(halfMarathon, at: date)
        _ = try store.saveSession(firstLowerASession())
        _ = try store.saveSession(priorUpperASession())
        _ = try store.saveSession(lowerASession())
        try store.saveCustomExercise(.custom(id: tempoSquatID, name: "Tempo goblet squat", equipment: "kettlebells",
                                             primaryMuscles: ["quadriceps"], secondaryMuscles: ["glutes"]))
        if isDraftRequested() { try seedDraft(store, at: date) }
    }

    // MARK: Workout records

    private static func workout(id: UUID, key: String, start: Date, end: Date, strain: Double) -> WorkoutRecord {
        WorkoutRecord(
            id: id,
            identity: WorkoutIdentity.make(activity: .strength, sourceKey: key, startedAt: start, endedAt: end),
            activity: .strength, source: .live, state: .completed, createdAt: start, startedAt: start, endedAt: end,
            samples: [WorkoutSample(timestamp: start.addingTimeInterval(600), heartRate: 118, zone: 2, strain: strain * 0.4),
                      WorkoutSample(timestamp: end, heartRate: 126, zone: 3, strain: strain)],
            checkpointNumber: 2, finalizationStage: .activeStateCleared)
    }

    /// The linked records the sessions point at, and Alex's two Apple Health workouts. Added to the fixture workout
    /// store beside `WorkoutFixtures`.
    static var workoutRecords: [WorkoutRecord] {
        [workout(id: lowerAWorkoutID, key: "fixture-train-lower-a", start: lowerAStart, end: lowerAEnd, strain: 12.4),
         workout(id: priorUpperAWorkoutID, key: "fixture-train-upper-a", start: priorUpperAStart, end: priorUpperAEnd, strain: 11)]
            + HealthWorkoutFixtures.records
    }

    // MARK: Recovery

    /// Recovery for the nine days to the fixture day. Today is 79 and the seven days before the
    /// week average 63, so the early light week rule leaves week 3 as planned.
    static let recoveryScores: [(day: String, score: Double)] = [
        ("2023-11-06", 64), ("2023-11-07", 58), ("2023-11-08", 71), ("2023-11-09", 49), ("2023-11-10", 66),
        ("2023-11-11", 73), ("2023-11-12", 61), ("2023-11-13", 70), ("2023-11-14", 79)
    ]
}

/// Recovery history for the Train fixture. Every other metric is empty.
nonisolated struct TrainFixtureMetricHistory: MetricHistoryProviding {
    func series(for key: MetricKey, days: Int, endingOn: Date) async throws -> [MetricHistoryPoint] {
        guard key == .recovery else { return [] }
        let calendar = AppTrainFixtures.calendar
        let start = calendar.startOfDay(for: endingOn)
        let first = calendar.date(byAdding: .day, value: -(max(days, 1) - 1), to: start) ?? start
        return AppTrainFixtures.recoveryScores.compactMap { entry in
            let parts = entry.day.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3,
                  let day = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
                  day >= first, day <= start else { return nil }
            return MetricHistoryPoint(day: day, value: entry.score, source: .band)
        }
    }
}
#endif
