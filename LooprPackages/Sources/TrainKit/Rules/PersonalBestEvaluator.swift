import Foundation

extension PersonalBest.Metric {
    /// True for values that are computed, not lifted. The UI labels these "Estimated".
    public var isEstimated: Bool { self == .estimatedOneRepMax }

    /// True when a smaller value is the better one: less assistance is a stronger pull-up.
    public var lowerIsBetter: Bool { self == .leastAssistance }

    /// The metrics a set of this measure can set. Estimated 1RM, heaviest load and best set are for weight sets only.
    public static func metrics(for measure: TrainSetMeasure) -> [PersonalBest.Metric] {
        switch measure {
        case .weight: [.estimatedOneRepMax, .heaviestLoad, .bestSetVolume]
        case .bodyweight: [.mostReps, .mostAddedLoad, .leastAssistance]
        case .time: [.longestHold]
        case .distance: [.longestDistance]
        }
    }
}

extension PersonalBest {
    /// A real record. A baseline is the first performance, so there was nothing to beat.
    public var isNewBest: Bool { !isBaseline }
}

/// Finds the personal bests a session reached. Pure value logic.
///
/// Warm-up and skipped sets never count. Each exercise line's measure decides which metrics apply, so a
/// plank sets a longest hold and a band pull-up sets least assistance, never an estimated one-rep max.
public enum PersonalBestEvaluator {
    /// Epley estimate of a one-rep max. One rep is the load itself.
    public static func estimatedOneRepMax(loadKg: Double, reps: Int) -> Double {
        reps <= 1 ? loadKg : loadKg * (1 + Double(reps) / 30)
    }

    /// The three metric values of one loaded set.
    public struct SetValues: Equatable, Sendable {
        public let estimatedOneRepMax: Double
        public let heaviestLoad: Double
        public let setVolume: Double

        public func value(for metric: PersonalBest.Metric) -> Double? {
            switch metric {
            case .estimatedOneRepMax: estimatedOneRepMax
            case .heaviestLoad: heaviestLoad
            case .bestSetVolume: setVolume
            default: nil
            }
        }
    }

    /// Nil for a skipped set, a warm-up, a set without reps, or one without a positive load.
    public static func values(of set: LoggedSet) -> SetValues? {
        guard set.isWorking, set.reps > 0, set.assistKg == nil, let load = set.loadKg, load.isFinite, load > 0 else { return nil }
        return .init(estimatedOneRepMax: estimatedOneRepMax(loadKg: load, reps: set.reps), heaviestLoad: load,
                     setVolume: load * Double(set.reps))
    }

    /// The value one set reaches on each metric its measure allows. Empty for warm-ups and skipped sets.
    public static func metricValues(of set: LoggedSet, measure: TrainSetMeasure) -> [PersonalBest.Metric: Double] {
        guard set.isWorking else { return [:] }
        switch measure {
        case .weight:
            guard let values = values(of: set) else { return [:] }
            return [.estimatedOneRepMax: values.estimatedOneRepMax, .heaviestLoad: values.heaviestLoad,
                    .bestSetVolume: values.setVolume]
        case .bodyweight:
            guard set.reps > 0 else { return [:] }
            if let assist = set.assistKg, assist > 0 { return [.leastAssistance: assist] }
            var result: [PersonalBest.Metric: Double] = [.mostReps: Double(set.reps)]
            if let added = set.loadKg, added > 0 { result[.mostAddedLoad] = added }
            return result
        case .time:
            guard let seconds = set.seconds, seconds > 0 else { return [:] }
            return [.longestHold: Double(seconds)]
        case .distance:
            guard let metres = set.metres, metres > 0 else { return [:] }
            return [.longestDistance: metres]
        }
    }

    /// True when `candidate` beats `record` on `metric`. An equal value is not a new best.
    public static func beats(_ candidate: Double, _ record: Double, metric: PersonalBest.Metric) -> Bool {
        metric.lowerIsBetter ? candidate < record - epsilon : candidate > record + epsilon
    }

    /// The best value per metric for one exercise across sessions. Nil when it was never performed.
    public static func bestValues(exerciseKey: String, in sessions: [TrainSession]) -> [PersonalBest.Metric: Double]? {
        var best: [PersonalBest.Metric: Double] = [:]
        for session in sessions {
            for exercise in session.exercises where exercise.exercise.key == exerciseKey && exercise.status != .skipped {
                for set in exercise.sets {
                    for (metric, value) in metricValues(of: set, measure: exercise.planned.measure) {
                        if let current = best[metric], !beats(value, current, metric: metric) { continue }
                        best[metric] = value
                    }
                }
            }
        }
        return best.isEmpty ? nil : best
    }

    /// Bests reached in `session` against the completed sessions in `history` that started earlier.
    ///
    /// - A first performance of an exercise on a metric returns a baseline (`isBaseline`), not a new best.
    /// - Skipped sets, warm-ups and sets with nothing to measure are ignored.
    /// - A value equal to the old record is not a new best.
    /// - Results follow the order of the exercises in the session, then `PersonalBest.Metric.allCases`.
    public static func evaluate(session: TrainSession, history: [TrainSession]) -> [PersonalBest] {
        let prior = history.filter { $0.id != session.id && $0.status == .completed && $0.startedAt < session.startedAt }
        var results: [PersonalBest] = []
        var seen = Set<String>()
        for exercise in session.exercises where exercise.status != .skipped {
            let key = exercise.exercise.key
            guard seen.insert(key).inserted else { continue }
            // One exercise can appear on two lines after a swap, so gather every counted set for the key.
            let sets = session.exercises
                .filter { $0.exercise.key == key && $0.status != .skipped }
                .flatMap { line in line.sets.map { (set: $0, values: metricValues(of: $0, measure: line.planned.measure)) } }
                .filter { !$0.values.isEmpty }
                .sorted { $0.set.loggedAt < $1.set.loggedAt }
            guard !sets.isEmpty else { continue }
            let priorBest = bestValues(exerciseKey: key, in: prior)
            // A baseline for one metric needs the exercise to be new on that metric, not just new overall.
            for metric in PersonalBest.Metric.allCases {
                let candidates = sets.compactMap { entry in entry.values[metric].map { (entry.set, $0) } }
                guard var top = candidates.first else { continue }
                // The earliest set holding the best value wins a tie inside the session.
                for candidate in candidates.dropFirst() where beats(candidate.1, top.1, metric: metric) { top = candidate }
                if let priorValue = priorBest?[metric] {
                    guard beats(top.1, priorValue, metric: metric) else { continue }
                    results.append(.init(exerciseKey: key, exerciseName: exercise.exercise.name, metric: metric, value: top.1,
                                         previousValue: priorValue, isBaseline: false, achievedAt: top.0.loggedAt,
                                         sessionID: session.id, setID: top.0.id))
                } else {
                    results.append(.init(exerciseKey: key, exerciseName: exercise.exercise.name, metric: metric, value: top.1,
                                         previousValue: nil, isBaseline: true, achievedAt: top.0.loggedAt,
                                         sessionID: session.id, setID: top.0.id))
                }
            }
        }
        return results
    }

    private static let epsilon = 1e-9
}
