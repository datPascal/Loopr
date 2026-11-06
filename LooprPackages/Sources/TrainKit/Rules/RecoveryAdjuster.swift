import Foundation

/// The result of checking a session plan against the recovery score.
public struct RecoveryAdjustment: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        /// No rule on the template, or the rule is switched off.
        case ruleOff
        /// There is no recovery reading, so the plan stays as written.
        case noReading
        /// The score is at or above the threshold. `score` is rounded down to a whole number.
        case atOrAboveThreshold(score: Int)
        /// The score is below the threshold and sets were removed.
        case belowThreshold(score: Int, setsPerLift: Int)
        /// The score is below the threshold but every lift is already at one set.
        case alreadyMinimal(score: Int)
    }

    public let reason: Reason
    /// The exercises with the adjustment applied. Equal to the input when nothing changed.
    public let exercises: [TemplateExercise]
    /// Sets removed across all exercises.
    public let totalSetsRemoved: Int
    /// The score the decision used, if there was a reading.
    public let score: Double?

    public var isAdjusted: Bool { totalSetsRemoved > 0 }

    public var message: String {
        switch reason {
        case .ruleOff: "Recovery adjustment is off for this session."
        case .noReading: "No recovery reading yet. Go as planned or lighten it yourself."
        case .atOrAboveThreshold(let score): "Recovery is \(score), so go as planned."
        case .belowThreshold(let score, let setsPerLift):
            "Recovery is \(score). The lighter version drops \(setsPerLift == 1 ? "one set" : "\(setsPerLift) sets") per lift."
        case .alreadyMinimal(let score): "Recovery is \(score), but every lift is already down to one set."
        }
    }

    /// A record of the change for `TrainSession.appliedAdjustments`. Nil when nothing was removed.
    public func programAdjustment(createdAt: Date, id: UUID = UUID()) -> ProgramAdjustment? {
        guard isAdjusted else { return nil }
        return ProgramAdjustment(id: id, kind: .setsRemoved, setsRemoved: totalSetsRemoved, reason: message,
                                 recoveryScore: score, createdAt: createdAt)
    }
}

/// Lightens a session when recovery is low. Pure value logic.
public enum RecoveryAdjuster {
    /// Below `rule.belowScore` removes `rule.setsRemoved` sets from every lift, never going under
    /// one set. A score exactly at the threshold changes nothing, and so does a missing reading.
    public static func adjust(exercises: [TemplateExercise], rule: RecoveryRule?, score: Double?) -> RecoveryAdjustment {
        func unchanged(_ reason: RecoveryAdjustment.Reason) -> RecoveryAdjustment {
            .init(reason: reason, exercises: exercises, totalSetsRemoved: 0, score: score)
        }
        guard let rule, rule.enabled else { return unchanged(.ruleOff) }
        guard let score, score.isFinite else { return unchanged(.noReading) }
        let shown = Int(score.rounded(.down))
        guard score < Double(rule.belowScore) else { return unchanged(.atOrAboveThreshold(score: shown)) }
        var removed = 0
        let adjusted = exercises.map { line -> TemplateExercise in
            var copy = line
            copy.sets = max(1, line.sets - rule.setsRemoved)
            removed += line.sets - copy.sets
            return copy
        }
        guard removed > 0 else { return unchanged(.alreadyMinimal(score: shown)) }
        return .init(reason: .belowThreshold(score: shown, setsPerLift: rule.setsRemoved), exercises: adjusted,
                     totalSetsRemoved: removed, score: score)
    }

    public static func adjust(template: WorkoutTemplate, score: Double?) -> RecoveryAdjustment {
        adjust(exercises: template.exercises, rule: template.recoveryRule, score: score)
    }
}
