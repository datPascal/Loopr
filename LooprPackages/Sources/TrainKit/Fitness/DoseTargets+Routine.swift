import Foundation
import RoutineKit

public extension DoseTargets {
    /// Weekly targets from the active protocol version's rules. A rule counts when its target asks for at least,
    /// or exactly, a positive number under one of the four metric names (`zone2_minutes`, `zone45_minutes`,
    /// `strength_sessions`, `mobility_sessions`):
    /// - a weekly rule (cadence one week, or no cadence with a unit that says week, "min/week") gives its number;
    /// - an every-day rule (no cadence, or one day) gives seven times its number, so "Zone 2, 45 min" every day, as
    ///   the day view scores it, is 315 minutes a week and never 45 (R2-UPG-1, R2-OPT-16);
    /// - a rule over two weeks or a month sets no weekly target.
    /// The first matching rule in the protocol's order wins. A metric with no rule has no target.
    init(rules: [ProtocolRule]) {
        func value(_ metric: String) -> Double? {
            for rule in rules where rule.target.metric == metric {
                guard rule.target.kind == .atLeast || rule.target.kind == .exactly,
                      let value = rule.target.value, value.isFinite, value > 0,
                      let perWeek = Self.timesAWeek(rule) else { continue }
                return value * perWeek
            }
            return nil
        }
        self.init(zone2Minutes: value(Self.zone2MinutesMetric), hardMinutes: value(Self.zone45MinutesMetric),
                  strengthSessions: value(Self.strengthSessionsMetric).map { Int($0.rounded(.up)) },
                  mobilitySessions: value(Self.mobilitySessionsMetric).map { Int($0.rounded(.up)) })
    }

    /// 1 for a weekly rule (its count for "3 times a week"), 7 for an every-day rule (the number of chosen days for a
    /// rule on some weekdays), nil for a longer one.
    private static func timesAWeek(_ rule: ProtocolRule) -> Double? {
        if let cadence = rule.cadence {
            switch (cadence.unit, cadence.every) {
            case (.week, 1): return Double(cadence.timesPerWeek ?? 1)
            case (.day, 1): return Double(cadence.hasChosenDays ? cadence.days.count : 7)
            default: return nil
            }
        }
        if isWeekly(unit: rule.target.unit) { return 1 }
        return 7
    }

    private static func isWeekly(unit: String?) -> Bool {
        guard let unit = unit?.lowercased() else { return false }
        return unit.contains("week") || unit.contains("/wk")
    }
}

// MARK: - Starter week

public extension DoseTargets {
    /// The starter week the empty Fitness tab offers (R2-NEW-06, R2-DES-09, R1-NEW-03): 150 Zone 2 minutes, two
    /// strength sessions and two mobility sessions, each a weekly rule. A common starting point, not a prescription.
    /// The keys and titles are the "Fitness for the long run" template's, so a later switch to it lines up.
    static let starterTargets = DoseTargets(zone2Minutes: 150, strengthSessions: 2, mobilitySessions: 2)

    static var starterRules: [ProtocolRule] {
        func weekly(_ key: String, _ title: String, metric: String, value: Double, unit: String,
                    source: CheckSource) -> ProtocolRule {
            ProtocolRule(key: RuleKey(rawValue: key), title: title, group: .fitness,
                         target: RuleTarget(kind: .atLeast, metric: metric, value: value, unit: unit), source: source,
                         cadence: RuleCadence(unit: .week))
        }
        return [
            weekly("zone-2", "Zone 2, 150 minutes a week", metric: zone2MinutesMetric, value: 150, unit: "min", source: .band),
            weekly("strength", "Two strength sessions a week", metric: strengthSessionsMetric, value: 2, unit: "sessions",
                   source: .fitness),
            weekly("mobility", "Two mobility sessions a week", metric: mobilitySessionsMetric, value: 2, unit: "sessions",
                   source: .fitness)
        ]
    }

    /// The protocol's rules with the starter week after them. A starter rule joins only for a metric the protocol has
    /// no rule for, so nothing the person set is replaced, and a key already in use gets a `starter-` prefix.
    static func addingStarterWeek(to rules: [ProtocolRule]) -> [ProtocolRule] {
        let metrics = Set(rules.compactMap(\.target.metric))
        var keys = Set(rules.map(\.key))
        var result = rules
        for rule in starterRules where !metrics.contains(rule.target.metric ?? "") {
            var key = rule.key
            if keys.contains(key) { key = RuleKey(rawValue: "starter-\(rule.key.rawValue)") }
            keys.insert(key)
            result.append(ProtocolRule(key: key, title: rule.title, group: rule.group, target: rule.target,
                                       timeOfDayMinutes: rule.timeOfDayMinutes, source: rule.source, cadence: rule.cadence))
        }
        return result
    }
}
