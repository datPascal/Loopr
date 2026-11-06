import Foundation

/// What the summary shows for a finished session. Pure value logic.
///
/// The hero's headline follows what was done: volume for lifts, time held for a session of holds,
/// distance for carries, reps for bodyweight work. A line says what the session adds to the week.
/// Then hairline metric rows and the personal bests.
public struct TrainSummaryModel: Equatable, Sendable {
    public struct Best: Equatable, Sendable, Identifiable {
        /// Position in the list, which names the row: `train-summary-pb-<index>`.
        public let index: Int
        public let exerciseName: String
        /// "Estimated 1RM", "Heaviest load", "Best set", "Longest hold" and the like.
        public let metricTitle: String
        /// "101 kg"
        public let valueText: String
        /// "Was 99 kg". Nil on a first time.
        public let previousText: String?
        /// The set behind a best set: "80 kg × 8". Nil for the other metrics.
        public let setText: String?
        /// True when it beat an earlier record. A first performance is a baseline, not a new best.
        public let isNewBest: Bool
        /// True for values worked out from reps, not lifted.
        public let isEstimated: Bool

        public var id: Int { index }
        public var identifier: String { "train-summary-pb-\(index)" }

        public var spokenLabel: String {
            var parts = [exerciseName, "\(metricTitle) \(valueText)"]
            if let setText { parts.append(setText) }
            if isEstimated { parts.append("estimated") }
            parts.append(isNewBest ? "new best" : "first time")
            if let previousText { parts.append(previousText) }
            return parts.joined(separator: ", ")
        }
    }

    public let name: String
    public let durationSeconds: TimeInterval
    public let tonnageKg: Double
    public let setCount: Int
    public let exercisesDone: Int
    public let exercisesSkipped: Int
    public let exercisesSwapped: Int
    public let exerciseCount: Int
    public let bests: [Best]
    public let workoutID: UUID?
    public let sessionID: UUID
    public let warmUpSetCount: Int
    public let holdSeconds: Int
    public let metres: Double
    /// Reps across working bodyweight sets.
    public let bodyweightReps: Int
    /// True when the session has a working set, so it counts as a strength session this week.
    public let countsTowardWeek: Bool

    /// What the hero leads with.
    public enum Headline: Equatable, Sendable {
        case volume(kg: Double)
        case held(seconds: Int)
        case distance(metres: Double)
        case reps(Int)
        case sets(Int)
    }

    public init(session: TrainSession) {
        sessionID = session.id
        workoutID = session.workoutID
        name = session.name
        durationSeconds = max(0, (session.endedAt ?? session.startedAt).timeIntervalSince(session.startedAt))
        tonnageKg = session.tonnageKg
        setCount = session.countedSets.count
        warmUpSetCount = session.warmUpSetCount
        holdSeconds = session.totalHoldSeconds
        metres = session.totalMetres
        bodyweightReps = session.exercises.filter { $0.planned.measure == .bodyweight }.flatMap(\.sets).filter(\.isWorking)
            .reduce(0) { $0 + $1.reps }
        countsTowardWeek = session.hasWorkingSet || session.warmUpSetCount == 0
        exerciseCount = session.exercises.count
        exercisesDone = session.exercises.filter { $0.status == .done }.count
        exercisesSkipped = session.exercises.filter { $0.status == .skipped }.count
        exercisesSwapped = session.exercises.filter { $0.swappedFrom != nil }.count
        let sets = Dictionary(session.exercises.flatMap(\.sets).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // New bests come first. Baselines follow, in the order the exercises were done.
        let ordered = session.bests.filter(\.isNewBest) + session.bests.filter { !$0.isNewBest }
        bests = ordered.enumerated().map { index, best in
            var setText: String?
            if best.metric == .bestSetVolume, let set = sets[best.setID], let load = set.loadKg {
                setText = "\(TrainLiveFormat.kilograms(load)) kg × \(set.reps)"
            }
            let title = Self.title(best.metric)
            let value = Self.valueText(best.metric, best.value)
            let previous = best.previousValue.map { "Was \(Self.valueText(best.metric, $0))" }
            return Best(index: index, exerciseName: best.exerciseName, metricTitle: title, valueText: value,
                        previousText: previous, setText: setText, isNewBest: best.isNewBest,
                        isEstimated: best.metric.isEstimated)
        }
    }

    public var newBestCount: Int { bests.filter(\.isNewBest).count }

    public static func title(_ metric: PersonalBest.Metric) -> String {
        switch metric {
        case .estimatedOneRepMax: "Estimated 1RM"
        case .heaviestLoad: "Heaviest load"
        case .bestSetVolume: "Best set"
        case .mostReps: "Most reps"
        case .mostAddedLoad: "Most added weight"
        case .leastAssistance: "Least assistance"
        case .longestHold: "Longest hold"
        case .longestDistance: "Longest distance"
        }
    }

    /// "101 kg", "12 reps", "+10 kg", "20 kg assist", "1:05", "60 m".
    public static func valueText(_ metric: PersonalBest.Metric, _ value: Double) -> String {
        switch metric {
        case .estimatedOneRepMax: "\(Int(value.rounded())) kg"
        case .heaviestLoad, .bestSetVolume: "\(TrainLiveFormat.kilograms(value)) kg"
        case .mostReps: "\(Int(value.rounded())) reps"
        case .mostAddedLoad: "+\(TrainLiveFormat.kilograms(value)) kg"
        case .leastAssistance: "\(TrainLiveFormat.kilograms(value)) kg assist"
        case .longestHold: TrainSetFormat.seconds(Int(value.rounded()))
        case .longestDistance: TrainSetFormat.metres(value)
        }
    }

    /// Volume when anything was lifted, else time held, else distance, else bodyweight reps, else sets.
    public var headline: Headline {
        if tonnageKg > 0 { return .volume(kg: tonnageKg) }
        if holdSeconds > 0 { return .held(seconds: holdSeconds) }
        if metres > 0 { return .distance(metres: metres) }
        if bodyweightReps > 0 { return .reps(bodyweightReps) }
        return .sets(setCount)
    }

    /// The headline as a number, a unit and a caption: ("2,560", "kg", "lifted").
    public var headlineParts: (value: String, unit: String?, caption: String) {
        switch headline {
        case .volume(let kg): (TrainLiveFormat.kilograms(kg.rounded()), "kg", "lifted")
        case .held(let seconds): (TrainSetFormat.seconds(seconds), nil, "held")
        case .distance(let metres):
            metres >= 1_000 ? (TrainLiveFormat.kilograms((metres / 100).rounded() / 10), "km", "covered")
                : (TrainLiveFormat.kilograms(metres), "m", "covered")
        case .reps(let reps): ("\(reps)", "reps", "at body weight")
        case .sets(let count): ("\(count)", count == 1 ? "set" : "sets", "logged")
        }
    }

    /// What the session adds to the week.
    public var weekLine: String {
        countsTowardWeek ? "Counts as 1 strength session this week."
            : "You logged only warm-ups, so this does not count toward your week."
    }

    /// "1:05" for the time held row.
    public var holdText: String { TrainSetFormat.seconds(holdSeconds) }

    /// "120 m" for the distance row.
    public var distanceText: String { TrainSetFormat.metres(metres) }

    /// "18" or "18, plus 3 warm-ups".
    public var setsText: String {
        warmUpSetCount == 0 ? "\(setCount)" : "\(setCount), plus \(warmUpSetCount) \(warmUpSetCount == 1 ? "warm-up" : "warm-ups")"
    }

    /// "2,560" for the volume row.
    public var volumeText: String { TrainLiveFormat.kilograms(tonnageKg.rounded()) }

    /// "4 done, 1 skipped, 1 swapped", or "6 done".
    public var exercisesText: String {
        var parts = ["\(exercisesDone) done"]
        if exercisesSkipped > 0 { parts.append("\(exercisesSkipped) skipped") }
        if exercisesSwapped > 0 { parts.append("\(exercisesSwapped) swapped") }
        return parts.joined(separator: ", ")
    }
}
