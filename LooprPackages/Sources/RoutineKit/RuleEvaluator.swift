import DomainKit
import Foundation

/// Why a rule is unknown. None of these is a miss.
public enum UnknownReason: String, Codable, Sendable {
    case sourceSwitchedOff
    case accessDenied
    case sourceUnavailable
    /// The source is on but reported nothing for this metric by the end of the day.
    case noData
    /// The source reported some of the figure. What it held does not settle the rule.
    case partialData
    /// A manual rule nobody ticked.
    case notTicked
    /// A source-checked rule with a weekly or monthly cadence. The day view cannot score it. A rule on chosen weekdays
    /// is daily and is scored on the days it is due.
    case longerPeriod
    /// The rule names a metric that is not in the vocabulary, belongs to another source, or lacks its target value.
    case unsupportedRule
}

/// The result of one rule on one day, before it is stored.
public struct RuleOutcome: Equatable, Sendable {
    public let state: CheckState
    public let source: CheckSource
    /// The partial or final figure the source measured. Nil when it measured nothing.
    public let measuredValue: Double?
    /// Set for `unknown`.
    public let reason: UnknownReason?
}

/// "Now" and the day being checked. `nowMinutes` is the wall-clock time in the day's own minutes, so 1440 and above
/// means the day is over.
public struct RoutineEvaluationContext: Sendable {
    public let clock: RoutineDayClock
    public let now: Date
    public let nowMinutes: Double

    public init(day: DayIdentity, now: Date, timeZone: TimeZone) throws {
        guard let clock = RoutineDayClock(day: day, timeZone: timeZone) else { throw RoutineError.invalidCheck }
        self.clock = clock; self.now = now; nowMinutes = clock.minutes(of: now)
    }

    public var day: DayIdentity { clock.day }
}

/// Decides one rule from the source snapshot for its day. Pure: the same rule, day, instant and snapshot give the same
/// outcome. A rule is kept, missed, pending (could still change) or unknown (the source cannot say). A missing reading
/// is never read as a No.
///
/// A rule's time is when the person is reminded. It never decides a result. A time-of-day metric uses the target
/// value as its limit, so "last meal by 18:30" is judged against 18:30 and not against the reminder.
public enum RuleEvaluator {
    private static let tolerance = 1e-6
    private static let dayMinutes = 1_440.0

    public static func evaluate(_ rule: ProtocolRule, context: RoutineEvaluationContext,
                                sources: RoutineSourceSnapshots) -> RuleOutcome {
        let source = rule.source
        func outcome(_ state: CheckState, _ value: Double? = nil, _ reason: UnknownReason? = nil) -> RuleOutcome {
            RuleOutcome(state: state, source: source, measuredValue: value, reason: reason)
        }
        if source == .manual { return manual(rule, context: context, sources: sources, outcome: outcome) }

        if let cadence = rule.cadence, !cadence.isDaily { return outcome(.unknown, nil, .longerPeriod) }
        if let name = rule.target.metric, let item = RoutineItemMetric(rawValue: name) {
            return evaluate(item, rule: rule, context: context, sources: sources, outcome: outcome)
        }
        guard let name = rule.target.metric, let metric = RoutineMetric(rawValue: name), metric.source == source,
              let snapshot = sources.snapshot(for: source) else { return outcome(.unknown, nil, .unsupportedRule) }
        let target = rule.target.value
        if rule.target.kind != .done && target?.isFinite != true { return outcome(.unknown, nil, .unsupportedRule) }

        switch snapshot.access(for: metric) {
        case .available: break
        case .switchedOff: return outcome(.unknown, nil, .sourceSwitchedOff)
        case .denied: return outcome(.unknown, nil, .accessDenied)
        case .unavailable: return outcome(.unknown, nil, .sourceUnavailable)
        }

        let now = context.nowMinutes
        let settled = now >= dayMinutes + metric.settleDelayMinutes
        let silent = settled ? outcome(.unknown, nil, .noData) : outcome(.pending)
        guard let reading = snapshot.readings[metric] else { return silent }
        switch reading {
        case .noEvents:
            // Only an event metric can say "none happened". Anything else is a malformed snapshot.
            guard metric.isEventTime else { return silent }
            return rule.target.kind == .atMost ? outcome(.kept) : outcome(.missed)
        case .measured(let amount):
            guard amount.isFinite, amount >= 0 else { return silent }
            return compare(kind: rule.target.kind, target: target ?? 0, amount: amount, isFloor: false, metric: metric,
                           now: now, outcome: outcome)
        case .atLeast(let amount):
            guard amount.isFinite, amount >= 0 else { return silent }
            return compare(kind: rule.target.kind, target: target ?? 0, amount: amount, isFloor: true, metric: metric,
                           now: now, outcome: outcome)
        }
    }

    /// An item metric such as `supplement_taken:vitamin-d3`. It is a settled tick: a reading decides the rule when it
    /// arrives, and no reading is pending until the day ends and unknown after, never missed.
    private static func evaluate(_ item: RoutineItemMetric, rule: ProtocolRule, context: RoutineEvaluationContext,
                                 sources: RoutineSourceSnapshots,
                                 outcome: (CheckState, Double?, UnknownReason?) -> RuleOutcome) -> RuleOutcome {
        guard item.source == rule.source, let snapshot = sources.snapshot(for: item.source) else { return outcome(.unknown, nil, .unsupportedRule) }
        let target = rule.target.value
        if rule.target.kind != .done && target?.isFinite != true { return outcome(.unknown, nil, .unsupportedRule) }
        switch snapshot.access(for: item.kind.lane) {
        case .available: break
        case .switchedOff: return outcome(.unknown, nil, .sourceSwitchedOff)
        case .denied: return outcome(.unknown, nil, .accessDenied)
        case .unavailable: return outcome(.unknown, nil, .sourceUnavailable)
        }
        guard let amount = snapshot.itemReadings[item]?.amount else {
            return context.nowMinutes >= dayMinutes ? outcome(.unknown, nil, .noData) : outcome(.pending, nil, nil)
        }
        return settled(kind: rule.target.kind, target: target ?? 0, amount: amount, strict: false, outcome: outcome)
    }

    private static func settled(kind: RuleTargetKind, target: Double, amount: Double, strict: Bool,
                                outcome: (CheckState, Double?, UnknownReason?) -> RuleOutcome) -> RuleOutcome {
        let kept: Bool
        switch kind {
        case .done: kept = amount > 0
        case .atLeast: kept = amount >= target
        case .atMost: kept = strict ? amount < target : amount <= target
        case .exactly: kept = abs(amount - target) <= tolerance
        }
        return outcome(kept ? .kept : .missed, amount, nil)
    }

    private static func compare(kind: RuleTargetKind, target: Double, amount: Double, isFloor: Bool, metric: RoutineMetric,
                                now: Double, outcome: (CheckState, Double?, UnknownReason?) -> RuleOutcome) -> RuleOutcome {
        let dayOver = now >= dayMinutes
        // A floor can prove a minimum or a breach. It cannot prove "at most" or "exactly".

        if metric.nature == .settled {
            return settled(kind: kind, target: target, amount: amount, strict: metric.atMostIsStrict, outcome: outcome)
        }

        switch kind {
        case .done, .atLeast:
            let met = kind == .done ? amount > 0 : amount >= target
            if met { return outcome(.kept, amount, nil) }
            if !dayOver { return outcome(.pending, amount, nil) }
            return isFloor ? outcome(.unknown, amount, .partialData) : outcome(.missed, amount, nil)
        case .atMost:
            if amount > target { return outcome(.missed, amount, nil) }
            // A later meal or drink could still cross the limit. A time limit closes at the limit, a quantity at midnight.
            let closesAt = metric.isTimeOfDay ? min(target, dayMinutes) : dayMinutes
            if now < closesAt { return outcome(.pending, amount, nil) }
            return isFloor ? outcome(.unknown, amount, .partialData) : outcome(.kept, amount, nil)
        case .exactly:
            if amount > target + tolerance { return outcome(.missed, amount, nil) }
            if !dayOver { return outcome(.pending, amount, nil) }
            if isFloor { return outcome(.unknown, amount, .partialData) }
            return outcome(abs(amount - target) <= tolerance ? .kept : .missed, amount, nil)
        }
    }

    private static func manual(_ rule: ProtocolRule, context: RoutineEvaluationContext, sources: RoutineSourceSnapshots,
                               outcome: (CheckState, Double?, UnknownReason?) -> RuleOutcome) -> RuleOutcome {
        if sources.manual.ticked.contains(rule.key) {
            let value = sources.manual.values[rule.key].flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            return outcome(.kept, value, nil)
        }
        // Nobody ticked it. The day can still be ticked until it ends, and afterwards the gap is not a No.
        return context.nowMinutes >= 1_440 ? outcome(.unknown, nil, .notTicked) : outcome(.pending, nil, nil)
    }
}
