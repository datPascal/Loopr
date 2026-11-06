import Foundation

/// What a finished exercise earned for next time.
public struct ProgressionDecision: Equatable, Sendable {
    public enum Reason: String, CaseIterable, Sendable {
        /// The template has no progression rule.
        case noRule
        /// A bodyweight line done with no added load and no assistance has nothing to change.
        case bodyweight
        /// Time and distance lines keep their target. The person raises it.
        case otherMeasure
        /// No load was logged or planned, so there is nothing to add to.
        case noLoad
        /// Every set was skipped or none were logged.
        case noWorkingSets
        /// Fewer working sets than planned, so the session did not hit the plan.
        case setsIncomplete
        /// At least one working set stayed under the target reps. One low set blocks the increase.
        case belowTarget
        /// Every working set reached the target.
        case targetReached
    }

    public let earned: Bool
    public let reason: Reason
    public let incrementKg: Double
    /// The load to start the next session at. Nil unless the increase was earned.
    public let nextLoadKg: Double?
    /// The reps to start the next session at. Nil unless the increase was earned.
    public let nextReps: Int?
    /// For an assisted bodyweight line, the assistance to start the next session at: one increment less. 0 means
    /// none is needed any more. Nil unless the step was earned on an assisted line.
    public var nextAssistKg: Double? = nil

    public var message: String {
        switch reason {
        case .noRule: "No progression rule on this exercise."
        case .bodyweight: "Bodyweight sets with no added load or assistance keep the same target."
        case .otherMeasure: "Timed and distance sets keep the same target."
        case .noLoad: "No load logged yet, so nothing to add to."
        case .noWorkingSets: "No working sets last time."
        case .setsIncomplete: "Last time did not finish every planned set. Same load again."
        case .belowTarget: "One set stayed under the target reps. Same load again."
        case .targetReached:
            nextAssistKg != nil ? "Every set hit the target last time. Take \(Self.format(incrementKg)) kg less assist."
                : "Every set hit the target last time. Add \(Self.format(incrementKg)) kg."
        }
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}

/// Decides whether a finished exercise earns a heavier load. Pure value logic.
public enum ProgressionEvaluator {
    /// - Parameters:
    ///   - planned: The plan the exercise ran under, with any recovery adjustment applied.
    ///   - performed: The sets logged for it. Skipped sets and warm-ups are ignored.
    ///
    /// Double progression needs every working set at the top of the rep range (`repsMax`).
    /// Linear needs every working set at the bottom of the range (`repsMin`), the planned reps.
    /// Both need at least `planned.sets` working sets. The next load is the heaviest working
    /// load plus the increment, and the next reps restart at `repsMin`.
    ///
    /// A bodyweight line follows the same rule when it has a load to change: an added load (a weighted dip) grows
    /// by the increment, and assistance (a band pull-up) shrinks by it, from the least assistance used, down to none.
    public static func evaluate(rule: ProgressionRule, planned: TemplateExercise, performed: [LoggedSet]) -> ProgressionDecision {
        let increment = rule.incrementKg ?? 0
        func blocked(_ reason: ProgressionDecision.Reason) -> ProgressionDecision {
            .init(earned: false, reason: reason, incrementKg: increment, nextLoadKg: nil, nextReps: nil)
        }
        let target: Int
        switch rule {
        case .none: return blocked(.noRule)
        case .doubleProgression: target = planned.repsMax
        case .linear: target = planned.repsMin
        }
        var assisted = false
        switch planned.measure {
        case .weight: break
        case .bodyweight:
            assisted = performed.contains { $0.isWorking && ($0.assistKg ?? 0) > 0 }
                || (!performed.contains { $0.isWorking } && (planned.assistKg ?? 0) > 0)
            let added = !assisted && (performed.contains { $0.isWorking && ($0.loadKg ?? 0) > 0 } || (planned.loadKg ?? 0) > 0)
            guard assisted || added else { return blocked(.bodyweight) }
        case .time, .distance: return blocked(.otherMeasure)
        }
        let working = performed.filter { $0.isWorking && $0.reps > 0 }
        guard !working.isEmpty else { return blocked(.noWorkingSets) }
        guard working.count >= planned.sets else { return blocked(.setsIncomplete) }
        if assisted {
            guard working.allSatisfy({ $0.reps >= target }) else { return blocked(.belowTarget) }
            let least = working.map { $0.assistKg ?? 0 }.min() ?? 0
            var decision = ProgressionDecision(earned: true, reason: .targetReached, incrementKg: increment, nextLoadKg: nil,
                                               nextReps: planned.repsMin)
            decision.nextAssistKg = max(least - increment, 0)
            return decision
        }
        let heaviest = working.compactMap(\.loadKg).filter { $0 > 0 }.max() ?? planned.loadKg.flatMap { $0 > 0 ? $0 : nil }
        guard let base = heaviest else { return blocked(.noLoad) }
        guard working.allSatisfy({ $0.reps >= target }) else { return blocked(.belowTarget) }
        return .init(earned: true, reason: .targetReached, incrementKg: increment, nextLoadKg: base + increment, nextReps: planned.repsMin)
    }
}
