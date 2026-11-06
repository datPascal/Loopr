import Foundation

public struct LoggedSet: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// Where the suggested values on the set screen came from.
    public enum PrefillSource: String, CaseIterable, Codable, Sendable {
        case previousSet, lastSession, template, progression, manual
    }

    public let id: UUID
    /// The load lifted. For a bodyweight exercise, the load added on a belt or vest.
    public var loadKg: Double?
    /// Reps done. A time or distance set may have none.
    public var reps: Int
    /// Rate of perceived exertion, 6 to 10 in half steps. Optional.
    public var rpe: Double?
    public var loggedAt: Date
    public var prefillSource: PrefillSource
    /// True when the person changed the suggested values before logging.
    public var edited: Bool
    /// A skipped set keeps its place in the table but never counts toward volume or bests.
    public var skipped: Bool
    /// Seconds held, for a time set. Nil in payloads written before measures existed.
    public var seconds: Int?
    /// Metres covered, for a distance set.
    public var metres: Double?
    /// Kilograms of assistance taken off body weight: a band or an assisted machine.
    public var assistKg: Double?
    /// Warm-up, drop or failure. Nil is a working set.
    public var tag: Tag?

    public init(id: UUID = UUID(), loadKg: Double?, reps: Int, rpe: Double? = nil, loggedAt: Date,
                prefillSource: PrefillSource = .manual, edited: Bool = false, skipped: Bool = false,
                seconds: Int? = nil, metres: Double? = nil, assistKg: Double? = nil, tag: Tag? = nil) {
        self.id = id; self.loadKg = loadKg; self.reps = reps; self.rpe = rpe; self.loggedAt = loggedAt
        self.prefillSource = prefillSource; self.edited = edited; self.skipped = skipped
        self.seconds = seconds; self.metres = metres; self.assistKg = assistKg; self.tag = tag
    }

    /// The numbers of the set without its bookkeeping.
    public var values: TrainSetValues { TrainSetValues(self) }

    /// Logged and not a warm-up: the sets that count toward volume, bests, progression and the weekly dose.
    public var isWorking: Bool { !skipped && tag != .warmUp }

    public static func isValidRPE(_ value: Double) -> Bool {
        value.isFinite && value >= 6 && value <= 10 && (value * 2).rounded() == value * 2
    }

    /// Checks the set against the measure of its exercise line. A time or distance set may have no reps,
    /// and bodyweight sets go up to 1,000 reps. A set cannot be both loaded and assisted.
    func validate(measure: TrainSetMeasure = .weight) throws {
        guard TrainLimits.validLoad(loadKg), TrainLimits.validLoad(assistKg), TrainLimits.validMetres(metres),
              loggedAt.timeIntervalSince1970.isFinite,
              seconds.map({ (0...TrainLimits.maxSetSeconds).contains($0) }) ?? true,
              rpe.map(Self.isValidRPE) ?? true else { throw TrainError.invalidRecord }
        if skipped {
            guard reps == 0, rpe == nil, tag == nil else { throw TrainError.invalidRecord }
            return
        }
        switch measure {
        case .weight:
            guard (1...TrainLimits.maxReps).contains(reps), assistKg == nil else { throw TrainError.invalidRecord }
        case .bodyweight:
            guard (1...TrainLimits.maxBodyweightReps).contains(reps) else { throw TrainError.invalidRecord }
            if let assistKg, assistKg > 0, let loadKg, loadKg > 0 { throw TrainError.invalidRecord }
        case .time:
            guard let seconds, seconds >= 1, (0...TrainLimits.maxBodyweightReps).contains(reps), assistKg == nil else {
                throw TrainError.invalidRecord
            }
        case .distance:
            guard metres != nil, (0...TrainLimits.maxBodyweightReps).contains(reps), assistKg == nil else {
                throw TrainError.invalidRecord
            }
        }
    }
}

public enum SessionExerciseStatus: String, CaseIterable, Codable, Sendable {
    case pending, done, skipped, swapped
}

public struct SessionExercise: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    /// The exercise actually performed. After a swap this is the replacement.
    public var exercise: ExerciseRef
    /// The plan for this session after any recovery adjustment, including the set count.
    public var planned: TemplateExercise
    public var status: SessionExerciseStatus
    public var swappedFrom: ExerciseRef?
    public var sets: [LoggedSet]

    public init(id: UUID = UUID(), planned: TemplateExercise, exercise: ExerciseRef? = nil,
                status: SessionExerciseStatus = .pending, swappedFrom: ExerciseRef? = nil, sets: [LoggedSet] = []) {
        self.id = id; self.planned = planned; self.exercise = exercise ?? planned.exercise
        self.status = status; self.swappedFrom = swappedFrom; self.sets = sets
    }

    func validate() throws {
        try exercise.validate()
        try planned.validate()
        try swappedFrom?.validate()
        guard sets.count <= TrainLimits.maxSets * 2 else { throw TrainError.invalidRecord }
        if status == .swapped { guard swappedFrom != nil else { throw TrainError.invalidRecord } }
        if status == .skipped { guard sets.allSatisfy(\.skipped) else { throw TrainError.invalidRecord } }
        for set in sets { try set.validate(measure: planned.measure) }
    }
}

public struct PersonalBest: Codable, Equatable, Hashable, Sendable, Identifiable {
    public enum Metric: String, CaseIterable, Codable, Sendable {
        /// Epley estimate. Always shown as an estimate, never as a lifted weight. Weight sets only.
        case estimatedOneRepMax
        case heaviestLoad
        case bestSetVolume
        /// Most reps in one unassisted bodyweight set.
        case mostReps
        /// Most load added to a bodyweight exercise.
        case mostAddedLoad
        /// Least assistance on an assisted bodyweight exercise. Lower is better.
        case leastAssistance
        /// Longest hold, in seconds.
        case longestHold
        /// Longest distance in one set, in metres.
        case longestDistance
    }

    public var id: String { "\(exerciseKey)|\(metric.rawValue)" }
    public let exerciseKey: String
    public var exerciseName: String
    public let metric: Metric
    public var value: Double
    /// The record this one replaced. Nil on a baseline.
    public var previousValue: Double?
    /// The first time an exercise is performed there is nothing to beat, so it sets a baseline, not a "new best".
    public var isBaseline: Bool
    public var achievedAt: Date
    public var sessionID: UUID
    public var setID: UUID

    public init(exerciseKey: String, exerciseName: String, metric: Metric, value: Double, previousValue: Double? = nil,
                isBaseline: Bool, achievedAt: Date, sessionID: UUID, setID: UUID) {
        self.exerciseKey = exerciseKey; self.exerciseName = exerciseName; self.metric = metric; self.value = value
        self.previousValue = previousValue; self.isBaseline = isBaseline; self.achievedAt = achievedAt
        self.sessionID = sessionID; self.setID = setID
    }

    func validate() throws {
        guard !exerciseKey.isEmpty, value.isFinite, value > 0, previousValue.map({ $0.isFinite && $0 > 0 }) ?? true,
              achievedAt.timeIntervalSince1970.isFinite, isBaseline == (previousValue == nil) else { throw TrainError.invalidRecord }
    }
}

public enum TrainSessionStatus: String, CaseIterable, Codable, Sendable {
    case active, completed, abandoned
}

public struct TrainSession: Codable, Equatable, Sendable, Identifiable {
    public let schemaVersion: Int
    public let id: UUID
    /// 0 means never saved. See `WorkoutTemplate.revision`.
    public var revision: Int
    /// The linked `WorkoutRecord` that carries heart rate, strain and the Journal auto-fill.
    public var workoutID: UUID?
    public var templateID: UUID?
    /// Template name at the time of the session.
    public var name: String
    public var programID: UUID?
    public var programWeek: Int?
    public let localDay: String
    public let timeZoneIdentifier: String
    public let startedAt: Date
    public var endedAt: Date?
    public var status: TrainSessionStatus
    /// Recovery score when the session started, or nil when there was no reading.
    public var recoveryAtStart: Double?
    public var appliedAdjustments: [ProgramAdjustment]
    public var exercises: [SessionExercise]
    /// Bests reached in this session, snapshotted when it finished.
    public var bests: [PersonalBest]

    public init(id: UUID = UUID(), revision: Int = 0, workoutID: UUID? = nil, templateID: UUID? = nil, name: String,
                programID: UUID? = nil, programWeek: Int? = nil, startedAt: Date, timeZoneIdentifier: String,
                endedAt: Date? = nil, status: TrainSessionStatus = .active, recoveryAtStart: Double? = nil,
                appliedAdjustments: [ProgramAdjustment] = [], exercises: [SessionExercise] = [], bests: [PersonalBest] = [],
                schemaVersion: Int = TrainRecordSchema.currentVersion) throws {
        self.schemaVersion = schemaVersion; self.id = id; self.revision = revision; self.workoutID = workoutID
        self.templateID = templateID; self.name = name; self.programID = programID; self.programWeek = programWeek
        self.startedAt = startedAt; self.timeZoneIdentifier = timeZoneIdentifier
        localDay = try TrainDay.string(at: startedAt, timeZoneIdentifier: timeZoneIdentifier)
        self.endedAt = endedAt; self.status = status; self.recoveryAtStart = recoveryAtStart
        self.appliedAdjustments = appliedAdjustments; self.exercises = exercises; self.bests = bests
    }

    /// Working sets: skipped sets and warm-ups are excluded.
    public var countedSets: [LoggedSet] { exercises.flatMap(\.sets).filter(\.isWorking) }

    /// Warm-up sets logged. They count for nothing, but the summary says how many there were.
    public var warmUpSetCount: Int { exercises.flatMap(\.sets).filter { !$0.skipped && $0.tag == .warmUp }.count }

    /// Total load lifted, in kilograms: load times reps over working sets. Sets without a load add nothing,
    /// so holds and carries add nothing, and a weighted dip adds the load on the belt.
    public var tonnageKg: Double { countedSets.reduce(0) { $0 + ($1.loadKg ?? 0) * Double($1.reps) } }

    /// Seconds held across working time sets.
    public var totalHoldSeconds: Int {
        exercises.filter { $0.planned.measure == .time }.flatMap(\.sets).filter(\.isWorking).reduce(0) { $0 + ($1.seconds ?? 0) }
    }

    /// Metres covered across working distance sets.
    public var totalMetres: Double {
        exercises.filter { $0.planned.measure == .distance }.flatMap(\.sets).filter(\.isWorking).reduce(0) { $0 + ($1.metres ?? 0) }
    }

    /// True when the session holds at least one working set. A session of warm-ups only earns no strength dot.
    public var hasWorkingSet: Bool { !countedSets.isEmpty }

    public func validate() throws {
        guard schemaVersion >= 1 else { throw TrainError.invalidRecord }
        guard schemaVersion <= TrainLimits.currentSchemaVersion else { throw TrainError.unsupportedVersion(schemaVersion) }
        guard revision >= 0, TrainLimits.validText(name, limit: TrainLimits.name),
              startedAt.timeIntervalSince1970.isFinite,
              try TrainDay.string(at: startedAt, timeZoneIdentifier: timeZoneIdentifier) == localDay,
              programWeek.map({ (1...TrainLimits.maxProgramWeeks).contains($0) }) ?? true,
              recoveryAtStart.map({ $0.isFinite && (0...100).contains($0) }) ?? true,
              exercises.count <= TrainLimits.maxExercisesPerTemplate * 2,
              Set(exercises.map(\.id)).count == exercises.count else { throw TrainError.invalidRecord }
        if let endedAt {
            guard endedAt.timeIntervalSince1970.isFinite, endedAt >= startedAt else { throw TrainError.invalidRecord }
        }
        if status == .completed { guard endedAt != nil else { throw TrainError.invalidRecord } }
        if status == .active { guard endedAt == nil, bests.isEmpty else { throw TrainError.invalidRecord } }
        for exercise in exercises { try exercise.validate() }
        let setIDs = exercises.flatMap(\.sets).map(\.id)
        guard Set(setIDs).count == setIDs.count, Set(bests.map(\.id)).count == bests.count else { throw TrainError.invalidRecord }
        for adjustment in appliedAdjustments { try adjustment.validate() }
        for best in bests {
            try best.validate()
            guard best.sessionID == id, setIDs.contains(best.setID) else { throw TrainError.invalidRecord }
        }
    }

    // `localDay` is derived, so decoding rebuilds it and rejects a payload that disagrees.
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, revision, workoutID, templateID, name, programID, programWeek, localDay, timeZoneIdentifier
        case startedAt, endedAt, status, recoveryAtStart, appliedAdjustments, exercises, bests
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: values.decode(UUID.self, forKey: .id), revision: values.decode(Int.self, forKey: .revision),
            workoutID: values.decodeIfPresent(UUID.self, forKey: .workoutID),
            templateID: values.decodeIfPresent(UUID.self, forKey: .templateID), name: values.decode(String.self, forKey: .name),
            programID: values.decodeIfPresent(UUID.self, forKey: .programID),
            programWeek: values.decodeIfPresent(Int.self, forKey: .programWeek),
            startedAt: values.decode(Date.self, forKey: .startedAt),
            timeZoneIdentifier: values.decode(String.self, forKey: .timeZoneIdentifier),
            endedAt: values.decodeIfPresent(Date.self, forKey: .endedAt), status: values.decode(TrainSessionStatus.self, forKey: .status),
            recoveryAtStart: values.decodeIfPresent(Double.self, forKey: .recoveryAtStart),
            appliedAdjustments: values.decode([ProgramAdjustment].self, forKey: .appliedAdjustments),
            exercises: values.decode([SessionExercise].self, forKey: .exercises), bests: values.decode([PersonalBest].self, forKey: .bests),
            schemaVersion: values.decode(Int.self, forKey: .schemaVersion))
        guard try values.decode(String.self, forKey: .localDay) == localDay else { throw TrainError.invalidRecord }
    }
}
