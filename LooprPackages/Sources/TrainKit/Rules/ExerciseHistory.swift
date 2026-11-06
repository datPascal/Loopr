import Foundation

/// Every exercise the person has logged, with what they did each time. Pure: built from finished sessions.
public struct ExerciseHistory: Equatable, Sendable {
    /// One session's work on one exercise.
    public struct Entry: Equatable, Sendable, Identifiable {
        public let sessionID: UUID
        public let sessionName: String
        public let date: Date
        /// Working sets in order. Skipped sets and warm-ups are left out.
        public let sets: [LoggedSet]
        /// What the sets record on this day's line.
        public let measure: TrainSetMeasure
        /// Warm-up sets done before the work. They count for nothing.
        public let warmUpCount: Int
        /// Epley estimate of the best set. Nil when no set carried a load, and always nil outside weight sets.
        public let estimatedOneRepMax: Double?
        public let heaviestLoad: Double?
        /// Load times reps over the counted sets.
        public let volumeKg: Double
        public let totalReps: Int
        /// Longest hold, for a time exercise.
        public let longestHoldSeconds: Int?
        /// Longest distance in one set, for a distance exercise.
        public let longestMetres: Double?
        /// Least assistance on an assisted bodyweight exercise.
        public let leastAssistKg: Double?
        /// Most load added to a bodyweight exercise.
        public let mostAddedKg: Double?
        public var id: UUID { sessionID }
    }

    /// One exercise across all sessions, newest entry first.
    public struct Exercise: Equatable, Sendable, Identifiable {
        public let key: String
        public let name: String
        public let entries: [Entry]
        public var id: String { key }

        public var lastDone: Date? { entries.first?.date }
        /// The measure of the newest entry.
        public var measure: TrainSetMeasure { entries.first?.measure ?? .weight }
        public var longestHoldSeconds: Int? { entries.compactMap(\.longestHoldSeconds).max() }
        public var longestMetres: Double? { entries.compactMap(\.longestMetres).max() }
        public var leastAssistKg: Double? { entries.compactMap(\.leastAssistKg).min() }
        public var mostAddedKg: Double? { entries.compactMap(\.mostAddedKg).max() }
        public var bestEstimatedOneRepMax: Double? { entries.compactMap(\.estimatedOneRepMax).max() }
        public var heaviestLoad: Double? { entries.compactMap(\.heaviestLoad).max() }
        public var bestSetVolume: Double? {
            weightSets.compactMap { set in set.loadKg.map { $0 * Double(set.reps) } }.max()
        }
        /// The loaded weight set with the most weight times reps.
        public var bestSet: LoggedSet? {
            weightSets.filter { ($0.loadKg ?? 0) > 0 }.max { ($0.loadKg ?? 0) * Double($0.reps) < ($1.loadKg ?? 0) * Double($1.reps) }
        }
        private var weightSets: [LoggedSet] { entries.filter { $0.measure == .weight }.flatMap(\.sets) }
        public var mostReps: Int? { entries.flatMap(\.sets).map(\.reps).max() }
        public var setCount: Int { entries.reduce(0) { $0 + $1.sets.count } }
        /// True when no set ever carried a load, such as pull-ups at body weight.
        public var isBodyweight: Bool { heaviestLoad == nil }
    }

    /// Sorted by when each was last done, newest first.
    public let exercises: [Exercise]

    public init(sessions: [TrainSession]) {
        var byKey: [String: (name: String, named: Date, entries: [Entry])] = [:]
        for session in sessions where session.status == .completed {
            for line in session.exercises where line.status != .skipped {
                let measure = line.planned.measure
                let sets = line.sets.filter { $0.isWorking && (measure.countsReps ? $0.reps > 0 : true) }
                guard !sets.isEmpty else { continue }
                let values = measure == .weight ? sets.compactMap(PersonalBestEvaluator.values(of:)) : []
                let metrics = sets.map { PersonalBestEvaluator.metricValues(of: $0, measure: measure) }
                let entry = Entry(sessionID: session.id, sessionName: session.name, date: session.startedAt, sets: sets,
                                  measure: measure,
                                  warmUpCount: line.sets.filter { !$0.skipped && $0.tag == .warmUp }.count,
                                  estimatedOneRepMax: values.map(\.estimatedOneRepMax).max(),
                                  heaviestLoad: values.map(\.heaviestLoad).max(),
                                  volumeKg: sets.reduce(0) { $0 + ($1.loadKg ?? 0) * Double($1.reps) },
                                  totalReps: sets.reduce(0) { $0 + $1.reps },
                                  longestHoldSeconds: metrics.compactMap { $0[.longestHold] }.max().map { Int($0) },
                                  longestMetres: metrics.compactMap { $0[.longestDistance] }.max(),
                                  leastAssistKg: metrics.compactMap { $0[.leastAssistance] }.min(),
                                  mostAddedKg: metrics.compactMap { $0[.mostAddedLoad] }.max())
                var current = byKey[line.exercise.key] ?? (line.exercise.name, session.startedAt, [])
                // The newest session's name wins, so a renamed custom exercise shows its current name.
                if session.startedAt > current.named { current.name = line.exercise.name; current.named = session.startedAt }
                current.entries.append(entry)
                byKey[line.exercise.key] = current
            }
        }
        exercises = byKey.map { key, value in
            let entries = value.entries.sorted { ($0.date, $0.sessionID.uuidString) > ($1.date, $1.sessionID.uuidString) }
            return Exercise(key: key, name: value.name, entries: entries)
        }
        .sorted { ($0.lastDone ?? .distantPast, $0.name) > ($1.lastDone ?? .distantPast, $1.name) }
    }

    public func exercise(key: String) -> Exercise? { exercises.first { $0.key == key } }

    /// "80 kg × 8, 8, 7" or "82.5 kg × 5, 80 kg × 6" or "12, 10, 9 reps", and for the other measures
    /// "20 kg assist × 8, 7", "0:45, 0:40, 0:40" or "40 m at 32 kg, 40 m at 32 kg".
    public static func setsText(_ sets: [LoggedSet], measure: TrainSetMeasure) -> String {
        switch measure {
        case .weight: return setsText(sets)
        case .bodyweight:
            var groups: [(label: String, reps: [Int])] = []
            for set in sets {
                let label = TrainSetFormat.bodyweight(addedKg: set.loadKg, assistKg: set.assistKg)
                if let last = groups.last, last.label == label { groups[groups.count - 1].reps.append(set.reps) }
                else { groups.append((label, [set.reps])) }
            }
            if groups.count == 1, groups[0].label == TrainSetFormat.bodyweight(addedKg: nil, assistKg: nil) { return groups[0].reps.map(String.init).joined(separator: ", ") + " reps" }
            return groups.map { "\($0.label) × " + $0.reps.map(String.init).joined(separator: ", ") }.joined(separator: ", ")
        case .time, .distance:
            return sets.map { TrainSetFormat.set($0.values, measure: measure) }.joined(separator: ", ")
        }
    }

    /// "80 kg × 8, 8, 7" or "82.5 kg × 5, 80 kg × 6" or "12, 10, 9 reps".
    public static func setsText(_ sets: [LoggedSet]) -> String {
        guard sets.contains(where: { ($0.loadKg ?? 0) > 0 }) else {
            return sets.map { String($0.reps) }.joined(separator: ", ") + " reps"
        }
        var groups: [(load: Double, reps: [Int])] = []
        for set in sets {
            let load = set.loadKg ?? 0
            if let last = groups.last, last.load == load { groups[groups.count - 1].reps.append(set.reps) }
            else { groups.append((load, [set.reps])) }
        }
        return groups.map { group in
            (group.load > 0 ? "\(TrainLiveFormat.kilograms(group.load)) kg × " : "BW × ") + group.reps.map(String.init).joined(separator: ", ")
        }.joined(separator: ", ")
    }
}
