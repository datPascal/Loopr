import Foundation

// Fitness round 2 (R2-WOD-09): after a WOD is saved the log says it once. The score, where it sits against your
// best of the same name and scaling ("21 s off your best, 4:58"), and what it added to the week.

/// The short result the WOD log shows after a save.
public struct WODSaveSummary: Equatable, Sendable {
    /// Where a result sits against earlier ones with the same name and scaling.
    public enum Standing: Equatable, Sendable {
        /// Nothing earlier to compare with.
        case first
        case newBest(previous: WODResult)
        case tiedBest
        case behind(best: WODResult)
    }

    public let result: WODResult
    /// Nil without a name or a score: there is nothing to compare.
    public let standing: Standing?
    /// True when the session falls in the current week.
    public let inCurrentWeek: Bool

    public init(result: WODResult, earlier: [WorkoutRecord], inCurrentWeek: Bool) {
        self.result = result
        self.inCurrentWeek = inCurrentWeek
        guard result.score != nil, let key = result.historyKey else { standing = nil; return }
        let pool = earlier.compactMap { record -> WODResult? in
            guard record.state == .completed, let wod = record.wod, wod.historyKey == key, wod.scaling == result.scaling,
                  wod.score != nil else { return nil }
            return wod
        }
        let best = pool.reduce(WODResult?.none) { best, next in
            guard let best else { return next }
            return next.beats(best) ? next : best
        }
        guard let best else { standing = .first; return }
        if result.beats(best) { standing = .newBest(previous: best) }
        else if best.beats(result) { standing = .behind(best: best) }
        else { standing = .tiedBest }
    }

    /// True for a new best.
    public var isPR: Bool {
        if case .newBest = standing { return true }
        return false
    }

    /// "Fran, 4:37 Rx", or "WOD, 12 rounds + 4 Scaled" without a name.
    public var title: String {
        [result.name ?? "WOD", result.scoreLine].compactMap { $0 }.joined(separator: ", ")
    }

    /// "New best, 21 s faster than 4:58.", "21 s off your best, 4:58.", "Your first Fran on record."
    public var standingLine: String? {
        guard let standing else { return nil }
        let name = result.name ?? "WOD"
        let scaled = result.scaling == .scaled ? "Scaled " : ""
        switch standing {
        case .first:
            return "Your first \(scaled)\(name) on record."
        case .tiedBest:
            return "Ties your best."
        case .newBest(let previous):
            if let gap = Self.gap(result, previous), let text = previous.score?.text {
                return "New best, \(gap) \(result.score?.kind == .time ? "faster" : "more") than \(text)."
            }
            return "New best. Your last best was \(previous.score?.text ?? "unscored")."
        case .behind(let best):
            guard let text = best.score?.text else { return nil }
            if let gap = Self.gap(best, result) { return "\(gap) off your best, \(text)." }
            return "Your best is \(text)."
        }
    }

    /// What a WOD adds to the weekly dose. The dose counts a WOD as a strength session (`DoseSessionKind`).
    public var weekLine: String {
        inCurrentWeek ? "Counts as 1 strength session this week." : "Counts as 1 strength session in the week you did it."
    }

    /// How far `better` is ahead of `worse`, when both scores are the same kind and the gap reads plainly:
    /// "21 s", "1:05", "12 reps", "5 kg". Nil for rounds and reps, where reps per round are unknown.
    static func gap(_ better: WODResult, _ worse: WODResult) -> String? {
        guard let high = better.score, let low = worse.score, high.kind == low.kind, !better.capped, !worse.capped else {
            return nil
        }
        switch high.kind {
        case .time:
            let seconds = (low.seconds ?? 0) - (high.seconds ?? 0)
            guard seconds > 0 else { return nil }
            return seconds < 60 ? "\(seconds) s" : WODScore.clock(seconds)
        case .reps:
            let reps = (high.reps ?? 0) - (low.reps ?? 0)
            return reps > 0 ? "\(reps) \(reps == 1 ? "rep" : "reps")" : nil
        case .load:
            let kilograms = (high.kilograms ?? 0) - (low.kilograms ?? 0)
            guard kilograms > 0 else { return nil }
            return "\(kilograms.formatted(.number.precision(.fractionLength(0...1)))) kg"
        case .roundsAndReps:
            return nil
        }
    }
}
