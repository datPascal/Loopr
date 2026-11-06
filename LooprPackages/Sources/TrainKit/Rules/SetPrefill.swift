import Foundation

/// The suggested values on the set screen, and where they came from.
public struct SetPrefill: Equatable, Sendable {
    public enum Source: String, CaseIterable, Sendable {
        case template, lastSession, progression, thisSession

        /// The value stored on a `LoggedSet`.
        public var loggedSetSource: LoggedSet.PrefillSource {
            switch self {
            case .template: .template
            case .lastSession: .lastSession
            case .progression: .progression
            case .thisSession: .previousSet
            }
        }
    }

    public let loadKg: Double?
    public let reps: Int
    public let source: Source
    public let seconds: Int?
    public let metres: Double?
    public let assistKg: Double?

    public init(loadKg: Double?, reps: Int, source: Source, seconds: Int? = nil, metres: Double? = nil, assistKg: Double? = nil) {
        self.loadKg = loadKg; self.reps = reps; self.source = source
        self.seconds = seconds; self.metres = metres; self.assistKg = assistKg
    }

    init(_ set: LoggedSet, source: Source) {
        self.init(loadKg: set.loadKg, reps: set.reps, source: source, seconds: set.seconds, metres: set.metres, assistKg: set.assistKg)
    }

    /// The suggestion as values to log.
    public var values: TrainSetValues {
        TrainSetValues(loadKg: loadKg, reps: reps, seconds: seconds, metres: metres, assistKg: assistKg)
    }

    /// Picks the suggestion for the next set of one exercise.
    ///
    /// Order: the last working set already logged for this exercise in this session, else
    /// the last completed session of the exercise (progression first when that session earned
    /// it, otherwise the working set at the same place), else the template. Warm-ups never feed it,
    /// so a light warm-up does not drag the first working set down.
    ///
    /// - Parameters:
    ///   - setIndex: Zero-based index of the set about to be logged.
    ///   - planned: The exercise line for this session.
    ///   - progression: The template's rule.
    ///   - thisSession: Sets already logged for this exercise in this session.
    ///   - lastSession: This exercise as performed in its last completed session, if any.
    public static func resolve(setIndex: Int, planned: TemplateExercise, progression: ProgressionRule,
                               thisSession: [LoggedSet], lastSession: SessionExercise?) -> SetPrefill {
        let measure = planned.measure
        func usable(_ set: LoggedSet) -> Bool { set.isWorking && (measure.countsReps ? set.reps > 0 : true) }
        if let previous = thisSession.last(where: usable) {
            return .init(previous, source: .thisSession)
        }
        if let last = lastSession, last.planned.measure == measure {
            let decision = ProgressionEvaluator.evaluate(rule: progression, planned: last.planned, performed: last.sets)
            if decision.earned, let reps = decision.nextReps {
                let reps = min(max(reps, planned.repsMin), planned.repsMax)
                if let assist = decision.nextAssistKg {
                    return .init(loadKg: nil, reps: reps, source: .progression, assistKg: assist > 0 ? assist : nil)
                }
                if let load = decision.nextLoadKg { return .init(loadKg: load, reps: reps, source: .progression) }
            }
            // Warm-ups logged today shift the index: the first working set matches last time's first working set.
            let workingIndex = setIndex - thisSession.filter { !$0.skipped && $0.tag == .warmUp }.count
            // A skipped set keeps its place, so it has nothing to copy and the template fills in.
            let lastTime = last.sets.filter { $0.tag != .warmUp }
            if lastTime.indices.contains(workingIndex), usable(lastTime[workingIndex]) {
                return .init(lastTime[workingIndex], source: .lastSession)
            }
        }
        switch measure {
        case .weight:
            return .init(loadKg: planned.loadKg, reps: planned.repsMin, source: .template)
        case .bodyweight:
            return .init(loadKg: planned.assistKg == nil ? planned.loadKg : nil, reps: planned.repsMin, source: .template,
                         assistKg: planned.assistKg)
        case .time:
            return .init(loadKg: planned.loadKg, reps: 0, source: .template, seconds: planned.plannedSeconds)
        case .distance:
            return .init(loadKg: planned.loadKg, reps: 0, source: .template, metres: planned.plannedMetres)
        }
    }
}
