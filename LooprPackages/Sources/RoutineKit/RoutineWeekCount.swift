import DomainKit
import Foundation

/// The one way Loopr counts a week of rule checks, so the check-in's hero, the weekly review and the share pass give
/// the same number for the same week (DEC-12.12, ICP R2-DES-04, R2-VET-02).
///
/// - One rule on one day is one check. Kept and not kept checks have an answer; the share is kept over answered.
/// - Skipped, not known, pending and missing checks are left out, so a sick day or a day nobody could check never reads
///   as not kept.
/// - Nothing answered means no share, never 0 percent.
public struct RoutineWeekCount: Equatable, Sendable {
    public let kept: Int
    public let missed: Int
    public let skipped: Int
    /// Checks a source could not decide.
    public let unknown: Int

    public init(kept: Int = 0, missed: Int = 0, skipped: Int = 0, unknown: Int = 0) {
        self.kept = kept; self.missed = missed; self.skipped = skipped; self.unknown = unknown
    }

    /// Counts the states as stored. A nil state is a rule with no check that day and counts for nothing.
    public init(states: some Sequence<CheckState?>) {
        var kept = 0, missed = 0, skipped = 0, unknown = 0
        for state in states {
            switch state {
            case .kept?: kept += 1
            case .missed?: missed += 1
            case .skipped?: skipped += 1
            case .unknown?: unknown += 1
            case .pending?, nil: break
            }
        }
        self.init(kept: kept, missed: missed, skipped: skipped, unknown: unknown)
    }

    /// One rule's week as Today and the check-in count it (ICP R4 Q3): a day the rule was not due on adds nothing unless
    /// it has an answer that day, so a "not known" check of a weekly rule already done, or of a blood panel due in
    /// February, never counts. `days` runs in day order inside one week; `lastDone` is the last kept day before it.
    public init(rule: ProtocolRule, days: [(day: DayIdentity, state: CheckState?)], lastDone: DayIdentity? = nil) {
        let counted = RuleDueTest.counted(rule, days: days, lastDone: lastDone)
        self.init(states: zip(days, counted).filter { $0.1 }.map { $0.0.state })
    }

    /// Checks with an answer: kept or not kept.
    public var decided: Int { kept + missed }

    /// The kept share in whole percent, rounded half up. Nil when nothing has an answer.
    public var percent: Int? {
        decided == 0 ? nil : Int((Double(kept) / Double(decided) * 100).rounded())
    }
}
