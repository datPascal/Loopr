import Foundation
import WorkoutKit

/// The older two-way split of an exercise line. `TrainSetMeasure` replaced it; it stays so code and
/// payloads that name it keep working.
public enum TrainLoadKind: String, CaseIterable, Codable, Sendable {
    case weight, bodyweight
}

/// One exercise line in a template. Array order is display and performance order;
/// superset members share a `supersetGroup` and sit next to each other.
public struct TemplateExercise: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var exercise: ExerciseRef
    public var sets: Int
    public var repsMin: Int
    public var repsMax: Int
    /// The planned load. For bodyweight, the load added on a belt or vest. For time and distance, an optional
    /// load carried or worn.
    public var loadKg: Double?
    /// What a set of this exercise records.
    public var measure: TrainSetMeasure
    /// Kilograms of assistance, for an assisted bodyweight exercise.
    public var assistKg: Double?
    /// The planned hold for a time exercise.
    public var targetSeconds: Int?
    /// The planned distance for a distance exercise.
    public var targetMetres: Double?
    public var restSeconds: Int
    public var supersetGroup: UUID?
    public var note: String

    /// The hold a time exercise starts from when no target is set.
    public static let defaultTargetSeconds = 30
    /// The distance a distance exercise starts from when no target is set.
    public static let defaultTargetMetres = 40.0

    /// - Parameter measure: Wins over `loadKind` when given. Without it, `loadKind` picks weight or bodyweight.
    public init(id: UUID = UUID(), exercise: ExerciseRef, sets: Int = 3, repsMin: Int = 8, repsMax: Int = 8,
                loadKg: Double? = nil, loadKind: TrainLoadKind = .weight, measure: TrainSetMeasure? = nil,
                assistKg: Double? = nil, targetSeconds: Int? = nil, targetMetres: Double? = nil, restSeconds: Int = 90,
                supersetGroup: UUID? = nil, note: String = "") {
        self.id = id; self.exercise = exercise; self.sets = sets; self.repsMin = repsMin; self.repsMax = repsMax
        self.loadKg = loadKg; self.measure = measure ?? (loadKind == .bodyweight ? .bodyweight : .weight)
        self.assistKg = assistKg; self.targetSeconds = targetSeconds; self.targetMetres = targetMetres
        self.restSeconds = restSeconds; self.supersetGroup = supersetGroup; self.note = note
    }

    /// Weight or bodyweight, for code written before measures. Setting `.weight` on a time or distance line
    /// keeps its measure.
    public var loadKind: TrainLoadKind {
        get { measure == .bodyweight ? .bodyweight : .weight }
        set {
            if newValue == .bodyweight { measure = .bodyweight } else if measure == .bodyweight { measure = .weight }
        }
    }

    /// The hold to aim for, falling back to 30 seconds.
    public var plannedSeconds: Int { targetSeconds ?? Self.defaultTargetSeconds }
    /// The distance to aim for, falling back to 40 metres.
    public var plannedMetres: Double { targetMetres ?? Self.defaultTargetMetres }

    public func validate() throws {
        try exercise.validate()
        guard (1...TrainLimits.maxSets).contains(sets), (1...measure.maxReps).contains(repsMin),
              (repsMin...measure.maxReps).contains(repsMax), TrainLimits.validLoad(loadKg), TrainLimits.validLoad(assistKg),
              targetSeconds.map({ (1...TrainLimits.maxSetSeconds).contains($0) }) ?? true,
              TrainLimits.validMetres(targetMetres),
              (0...TrainLimits.maxRestSeconds).contains(restSeconds),
              TrainLimits.validText(note, limit: TrainLimits.note, allowEmpty: true) else { throw TrainError.invalidRecord }
        if measure != .bodyweight, let assistKg, assistKg > 0 { throw TrainError.invalidRecord }
        if let assistKg, assistKg > 0, let loadKg, loadKg > 0 { throw TrainError.invalidRecord }
    }

    // A payload from before measures has `loadKind` and none of the new keys. `loadKind` is still written,
    // so an older build reads a weight or bodyweight line the same way.
    private enum CodingKeys: String, CodingKey {
        case id, exercise, sets, repsMin, repsMax, loadKg, loadKind, measure, assistKg, targetSeconds, targetMetres
        case restSeconds, supersetGroup, note
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try values.decodeIfPresent(TrainLoadKind.self, forKey: .loadKind) ?? .weight
        try self.init(id: values.decode(UUID.self, forKey: .id), exercise: values.decode(ExerciseRef.self, forKey: .exercise),
                      sets: values.decode(Int.self, forKey: .sets), repsMin: values.decode(Int.self, forKey: .repsMin),
                      repsMax: values.decode(Int.self, forKey: .repsMax), loadKg: values.decodeIfPresent(Double.self, forKey: .loadKg),
                      loadKind: kind, measure: values.decodeIfPresent(TrainSetMeasure.self, forKey: .measure),
                      assistKg: values.decodeIfPresent(Double.self, forKey: .assistKg),
                      targetSeconds: values.decodeIfPresent(Int.self, forKey: .targetSeconds),
                      targetMetres: values.decodeIfPresent(Double.self, forKey: .targetMetres),
                      restSeconds: values.decode(Int.self, forKey: .restSeconds),
                      supersetGroup: values.decodeIfPresent(UUID.self, forKey: .supersetGroup),
                      note: values.decodeIfPresent(String.self, forKey: .note) ?? "")
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(exercise, forKey: .exercise)
        try values.encode(sets, forKey: .sets)
        try values.encode(repsMin, forKey: .repsMin)
        try values.encode(repsMax, forKey: .repsMax)
        try values.encodeIfPresent(loadKg, forKey: .loadKg)
        try values.encode(loadKind, forKey: .loadKind)
        try values.encode(measure, forKey: .measure)
        try values.encodeIfPresent(assistKg, forKey: .assistKg)
        try values.encodeIfPresent(targetSeconds, forKey: .targetSeconds)
        try values.encodeIfPresent(targetMetres, forKey: .targetMetres)
        try values.encode(restSeconds, forKey: .restSeconds)
        try values.encodeIfPresent(supersetGroup, forKey: .supersetGroup)
        try values.encode(note, forKey: .note)
    }
}

extension TemplateExercise {
    /// A fresh line for a library or custom exercise, with the measure its category, equipment and name suggest.
    public static func starting(_ definition: ExerciseDefinition, sets: Int = 3, repsMin: Int = 8, repsMax: Int = 12,
                                restSeconds: Int = 90) -> TemplateExercise {
        let measure = TrainSetMeasure.defaultMeasure(for: definition)
        return TemplateExercise(exercise: definition.reference, sets: sets, repsMin: repsMin, repsMax: repsMax, loadKg: nil,
                                measure: measure,
                                targetSeconds: measure == .time ? defaultTargetSeconds : nil,
                                targetMetres: measure == .distance ? defaultTargetMetres : nil,
                                restSeconds: restSeconds)
    }
}

public enum ProgressionRule: Codable, Equatable, Hashable, Sendable {
    /// No automatic change to load or reps.
    case none
    /// Add reps until every set reaches the top of the range, then add `incrementKg`.
    case doubleProgression(incrementKg: Double)
    /// Add `incrementKg` after every session that hits the planned sets and reps.
    case linear(incrementKg: Double)

    public static let defaultIncrementKg = 2.5

    public var incrementKg: Double? {
        switch self {
        case .none: nil
        case .doubleProgression(let value), .linear(let value): value
        }
    }

    func validate() throws {
        if let incrementKg, !(incrementKg.isFinite && incrementKg > 0 && incrementKg <= 50) { throw TrainError.invalidRecord }
    }
}

/// When recovery is low, take sets off before the session starts. The score is the
/// 0 to 100 recovery value; there is no adjustment without a reading.
public struct RecoveryRule: Codable, Equatable, Hashable, Sendable {
    public var enabled: Bool
    public var belowScore: Int
    public var setsRemoved: Int

    public init(enabled: Bool = true, belowScore: Int = 34, setsRemoved: Int = 1) {
        self.enabled = enabled; self.belowScore = belowScore; self.setsRemoved = setsRemoved
    }

    func validate() throws {
        guard (1...100).contains(belowScore), (1...5).contains(setsRemoved) else { throw TrainError.invalidRecord }
    }
}

public enum WorkoutTemplateKind: String, CaseIterable, Codable, Sendable {
    case strength, cardio
}

public struct CardioTarget: Codable, Equatable, Hashable, Sendable {
    public var activity: ActivityType
    public var minutes: Int
    /// Heart-rate zone 1 to 5, or nil for no zone target.
    public var zone: Int?

    public init(activity: ActivityType, minutes: Int, zone: Int? = nil) {
        self.activity = activity; self.minutes = minutes; self.zone = zone
    }

    func validate() throws {
        guard (1...600).contains(minutes), zone.map({ (1...5).contains($0) }) ?? true else { throw TrainError.invalidRecord }
    }
}

public struct WorkoutTemplate: Codable, Equatable, Sendable, Identifiable {
    public let schemaVersion: Int
    public let id: UUID
    /// 0 means never saved. The store bumps it on every successful save and
    /// rejects a save whose revision differs from the stored one.
    public var revision: Int
    public var name: String
    public var kind: WorkoutTemplateKind
    public var weekdays: [TrainWeekday]
    public var exercises: [TemplateExercise]
    public var progression: ProgressionRule
    public var recoveryRule: RecoveryRule?
    public var bandRestCue: Bool
    public var cardio: CardioTarget?
    public var source: TrainRecordSource
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), revision: Int = 0, name: String, kind: WorkoutTemplateKind = .strength,
                weekdays: [TrainWeekday] = [], exercises: [TemplateExercise] = [], progression: ProgressionRule = .none,
                recoveryRule: RecoveryRule? = nil, bandRestCue: Bool = true, cardio: CardioTarget? = nil,
                source: TrainRecordSource = .manual, createdAt: Date = Date(timeIntervalSince1970: 0),
                updatedAt: Date = Date(timeIntervalSince1970: 0), schemaVersion: Int = TrainRecordSchema.currentVersion) {
        self.schemaVersion = schemaVersion; self.id = id; self.revision = revision; self.name = name; self.kind = kind
        self.weekdays = weekdays; self.exercises = exercises; self.progression = progression
        self.recoveryRule = recoveryRule; self.bandRestCue = bandRestCue; self.cardio = cardio; self.source = source
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    /// Sets across every exercise at their planned count.
    public var totalSets: Int { exercises.reduce(0) { $0 + $1.sets } }

    public func validate() throws {
        guard schemaVersion >= 1 else { throw TrainError.invalidRecord }
        guard schemaVersion <= TrainLimits.currentSchemaVersion else { throw TrainError.unsupportedVersion(schemaVersion) }
        guard revision >= 0, TrainLimits.validText(name, limit: TrainLimits.name),
              createdAt.timeIntervalSince1970.isFinite, updatedAt.timeIntervalSince1970.isFinite,
              weekdays == Array(Set(weekdays)).sorted() else { throw TrainError.invalidRecord }
        try progression.validate()
        try recoveryRule?.validate()
        switch kind {
        case .strength:
            guard cardio == nil, exercises.count <= TrainLimits.maxExercisesPerTemplate else { throw TrainError.invalidRecord }
        case .cardio:
            guard exercises.isEmpty, let cardio else { throw TrainError.invalidRecord }
            try cardio.validate()
        }
        guard Set(exercises.map(\.id)).count == exercises.count else { throw TrainError.invalidRecord }
        for exercise in exercises { try exercise.validate() }
        try validateSupersets()
    }

    /// Members of one superset must be adjacent, and a group needs at least two members.
    private func validateSupersets() throws {
        var closed = Set<UUID>()
        var openGroup: UUID?
        var counts: [UUID: Int] = [:]
        for exercise in exercises {
            guard let group = exercise.supersetGroup else { if let openGroup { closed.insert(openGroup) }; openGroup = nil; continue }
            if group != openGroup {
                if let openGroup { closed.insert(openGroup) }
                guard !closed.contains(group) else { throw TrainError.invalidRecord }
                openGroup = group
            }
            counts[group, default: 0] += 1
        }
        guard counts.values.allSatisfy({ $0 >= 2 }) else { throw TrainError.invalidRecord }
    }
}
