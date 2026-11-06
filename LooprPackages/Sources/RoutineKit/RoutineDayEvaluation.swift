import DomainKit
import Foundation

/// The day in four counts and one share.
public struct RoutineDaySummary: Equatable, Sendable {
    public let protocolID: ProtocolID
    public let version: Int
    public let day: DayIdentity
    public let kept: Int
    public let missed: Int
    public let pending: Int
    public let unknown: Int
    /// Rules the person skipped for the day. Neither kept nor missed.
    public let skipped: Int

    public var total: Int { kept + missed + pending + unknown + skipped }
    /// Rules with a verdict. Pending, unknown and skipped rules are not in it.
    public var decided: Int { kept + missed }
    /// Kept rules over decided rules. Nil when nothing is decided, so a day of unknowns never reads as 0 percent.
    public var keptShare: Double? { decided == 0 ? nil : Double(kept) / Double(decided) }

    public init(protocolID: ProtocolID, version: Int, day: DayIdentity, checks: [RuleCheck]) {
        self.protocolID = protocolID; self.version = version; self.day = day
        kept = checks.filter { $0.state == .kept }.count
        missed = checks.filter { $0.state == .missed }.count
        pending = checks.filter { $0.state == .pending }.count
        unknown = checks.filter { $0.state == .unknown }.count
        skipped = checks.filter { $0.state == .skipped }.count
    }
}

public struct RoutineDayResult: Equatable, Sendable {
    public let summary: RoutineDaySummary
    /// One check per rule of the version that is due on the day, in the version's rule order, as stored. A day the
    /// person overrode shows their decision.
    public let checks: [RuleCheck]
    /// Why each unknown rule is unknown, for a rule the sources decided this time.
    public let unknownReasons: [RuleKey: UnknownReason]
}

/// Evaluates the active protocol for a day and stores the result. Every decision is in `RuleEvaluator`; this type
/// gathers the day's checks and ticks, stores what the evaluator says and counts.
public struct RoutineDayEvaluation: Sendable {
    private let store: RoutineStore
    public init(store: RoutineStore) { self.store = store }

    /// Evaluates every rule of the active protocol as it stood on `day` (the version in force: the newest created on or
    /// before the day's end), or of `version` when given. Returns nil when
    /// there is no active protocol. A rule the person overrode keeps their decision. A manual rule is kept when its
    /// stored check is a tick or `sources.manual` ticks it.
    @discardableResult
    public func evaluate(day: DayIdentity, now: Date, timeZone: TimeZone, sources: RoutineSourceSnapshots,
                         version: ProtocolVersion? = nil) throws -> RoutineDayResult? {
        guard let active = try store.activeProtocol() else { return nil }
        let protocolID = active.routineProtocol.id
        let context = try RoutineEvaluationContext(day: day, now: now, timeZone: timeZone)
        let version = try version ?? versionInForce(protocolID: protocolID, dayEnd: context.clock.end, newest: active.latestVersion)
        guard version.protocolID == protocolID else { throw RoutineError.missingVersion }

        let stored = try store.checks(protocolID: protocolID, day: day)
        var ticked = sources.manual.ticked
        var values = sources.manual.values
        // A tick from a rule reminder stays marked as one when the day is evaluated again.
        var origins: [RuleKey: AnswerOrigin] = [:]
        for check in stored where check.source == .manual && check.state == .kept && !check.overriddenByPerson {
            ticked.insert(check.ruleKey)
            if let value = check.measuredValue, values[check.ruleKey] == nil { values[check.ruleKey] = value }
            if let origin = check.answeredFrom { origins[check.ruleKey] = origin }
        }
        let complete = sources.replacingManual(RoutineManualSnapshot(ticked: ticked, values: values))

        var checks: [RuleCheck] = []
        var reasons: [RuleKey: UnknownReason] = [:]
        // A rule on chosen weekdays makes no check on its off days (ICP R1-HAB-02).
        for rule in version.rules where rule.isDue(on: day) {
            let outcome = RuleEvaluator.evaluate(rule, context: context, sources: complete)
            let origin = outcome.source == .manual && outcome.state == .kept ? origins[rule.key] : nil
            checks.append(try RuleCheck(ruleKey: rule.key, day: day, version: version.number, state: outcome.state,
                                        source: outcome.source, measuredValue: outcome.measuredValue, recordedAt: now,
                                        answeredFrom: origin))
            if let reason = outcome.reason { reasons[rule.key] = reason }
        }
        let recorded = try store.recordChecks(checks, protocolID: protocolID)
        for check in recorded where check.overriddenByPerson { reasons[check.ruleKey] = nil }
        return RoutineDayResult(summary: RoutineDaySummary(protocolID: protocolID, version: version.number, day: day, checks: recorded),
                                checks: recorded, unknownReasons: reasons)
    }

    /// The rules a day is scored against: the newest version created on or before the day's end. A day from before the
    /// protocol existed, such as migrated history, uses the first version. Today uses the newest.
    private func versionInForce(protocolID: ProtocolID, dayEnd: Date, newest: ProtocolVersion) throws -> ProtocolVersion {
        if let inForce = try store.versionInForce(protocolID: protocolID, at: dayEnd) { return inForce }
        return try store.version(protocolID: protocolID, number: 1) ?? newest
    }

    /// Records a tick on a manual rule: a kept check from the source `manual`, with the amount the person typed, if any.
    /// A tick on a day the person marked missed replaces that decision.
    @discardableResult
    public func tick(ruleKey: RuleKey, day: DayIdentity, at date: Date, value: Double? = nil,
                     answeredFrom: AnswerOrigin? = nil) throws -> RuleCheck {
        guard let active = try store.activeProtocol() else { throw RoutineError.missingProtocol }
        let protocolID = active.routineProtocol.id
        let existing = try store.check(protocolID: protocolID, ruleKey: ruleKey, day: day)
        let version = existing?.version ?? active.latestVersion.number
        guard let rule = try store.version(protocolID: protocolID, number: version)?.rule(for: ruleKey) else {
            throw RoutineError.unknownRule(ruleKey)
        }
        guard rule.source == .manual else { throw RoutineError.notManualRule(ruleKey) }
        let tick = try RuleCheck(ruleKey: ruleKey, day: day, version: version, state: .kept, source: .manual,
                                 measuredValue: value, recordedAt: date, answeredFrom: answeredFrom)
        if existing?.overriddenByPerson == true {
            _ = try store.removeCheck(protocolID: protocolID, ruleKey: ruleKey, day: day)
        }
        return try store.recordCheck(tick, protocolID: protocolID)
    }

    /// Today's hold-to-tick: ticks a manual rule unless the day already holds the person's kept decision for it. Returns
    /// the stored tick, or nil when the rule was already kept, in which case nothing is written. A second hold on the
    /// same day therefore changes nothing, not even the recorded time.
    @discardableResult
    public func tickOnce(ruleKey: RuleKey, day: DayIdentity, at date: Date) throws -> RuleCheck? {
        guard let active = try store.activeProtocol() else { throw RoutineError.missingProtocol }
        if let existing = try store.check(protocolID: active.routineProtocol.id, ruleKey: ruleKey, day: day),
           existing.state == .kept, existing.source == .manual {
            return nil
        }
        return try tick(ruleKey: ruleKey, day: day, at: date)
    }

    /// Takes back a person's decision on one rule, a tick or an override, and evaluates the day again. The rule goes
    /// back to what its source says: pending, or unknown once the day is over.
    public func untick(ruleKey: RuleKey, day: DayIdentity, now: Date, timeZone: TimeZone,
                       sources: RoutineSourceSnapshots) throws -> RoutineDayResult? {
        guard let active = try store.activeProtocol() else { return nil }
        let protocolID = active.routineProtocol.id
        guard let existing = try store.check(protocolID: protocolID, ruleKey: ruleKey, day: day) else {
            return try evaluate(day: day, now: now, timeZone: timeZone, sources: sources)
        }
        guard existing.source == .manual else { throw RoutineError.notManualRule(ruleKey) }
        _ = try store.removeCheck(protocolID: protocolID, ruleKey: ruleKey, day: day)
        return try evaluate(day: day, now: now, timeZone: timeZone, sources: sources)
    }

    /// A person marks a rule kept, missed or skipped over whatever a source said. It survives every later evaluation, and
    /// `untick` takes it back.
    @discardableResult
    public func override(ruleKey: RuleKey, day: DayIdentity, state: CheckState, at date: Date,
                         answeredFrom: AnswerOrigin? = nil) throws -> RuleCheck {
        guard let active = try store.activeProtocol() else { throw RoutineError.missingProtocol }
        return try store.overrideCheck(protocolID: active.routineProtocol.id, ruleKey: ruleKey, day: day, state: state, at: date,
                                       answeredFrom: answeredFrom)
    }
}
