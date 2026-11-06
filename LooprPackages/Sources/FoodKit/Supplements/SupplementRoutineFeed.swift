import DomainKit
import Foundation
import RoutineKit

/// The metric names a Protocol rule uses to read taken ticks. RoutineKit stores a rule's `target.metric` as a free
/// string, so these names are the vocabulary for rules of group `supplements` whose check source is Food.
///
/// - `supplement_taken:<itemKey>`: 1 when every due dose of that item is taken, 0 when any is skipped.
/// - `supplements_all_taken`: 1 when every due supplement dose is taken, 0 when any is skipped.
/// - `supplement_adherence`: taken doses over due doses, only once every due dose has a record.
/// - `medication_taken:<itemKey>` and `medication_all_taken`: the same for the medication lane, never mixed in.
///
/// A dose with no record gives no reading, so the check stays `unknown`. It is never counted as missed.
public enum SupplementMetric {
    // The names are RoutineKit's vocabulary (`RoutineMetric` and `RoutineItemMetric`), so RuleEvaluator reads them.
    public static let takenPrefix = RoutineItemMetric.Kind.supplementTaken.rawValue + String(RoutineItemMetric.separator)
    public static let allTaken = RoutineMetric.supplementsAllTaken.rawValue
    public static let adherence = RoutineMetric.supplementAdherence.rawValue
    public static let medicationTakenPrefix = RoutineItemMetric.Kind.medicationTaken.rawValue + String(RoutineItemMetric.separator)
    public static let medicationAllTaken = RoutineMetric.medicationAllTaken.rawValue

    public static func taken(itemKey: String, lane: StackLane = .supplement) -> String {
        (lane == .supplement ? takenPrefix : medicationTakenPrefix) + itemKey
    }
    public static func allTaken(lane: StackLane) -> String { lane == .supplement ? allTaken : medicationAllTaken }

    /// "At least 1": the item counts as kept on a day its reading is 1.
    public static func target(itemKey: String, lane: StackLane = .supplement) -> RuleTarget {
        RuleTarget(kind: .atLeast, metric: taken(itemKey: itemKey, lane: lane), value: 1)
    }
    public static func allTakenTarget(lane: StackLane = .supplement) -> RuleTarget {
        RuleTarget(kind: .atLeast, metric: allTaken(lane: lane), value: 1)
    }

    /// A rule for one item, or for the whole lane when `itemKey` is nil. Group `supplements`, source Food.
    public static func rule(key: RuleKey, title: String, itemKey: String?, lane: StackLane = .supplement,
                            timeOfDayMinutes: Int? = nil, isEvening: Bool = false) -> ProtocolRule {
        ProtocolRule(key: key, title: title, group: .supplements,
            target: itemKey.map { target(itemKey: $0, lane: lane) } ?? allTakenTarget(lane: lane),
            timeOfDayMinutes: timeOfDayMinutes, source: .food, isEvening: isEvening)
    }

    /// Whether a metric name belongs to this vocabulary.
    public static func isSupplementMetric(_ metric: String) -> Bool {
        metric.hasPrefix(takenPrefix) || metric.hasPrefix(medicationTakenPrefix)
            || [allTaken, adherence, medicationAllTaken].contains(metric)
    }
}

/// One day's measured value for one metric, as a Protocol source reading.
public struct SupplementReading: Equatable, Sendable {
    public let metric: String
    /// 1 or 0 for the taken metrics, a fraction from 0 to 1 for adherence.
    public let value: Double
    public let localDay: String
    /// Readings come from the Food tab's stack.
    public var source: CheckSource { .food }
}

public enum SupplementRoutineFeed {
    /// The readings one day's ticks give for one lane. An item appears only when its due doses are decided: all
    /// taken (1) or at least one skipped (0). Doses still not recorded and none skipped give nothing.
    public static func readings(for day: StackDay) -> [SupplementReading] {
        var result: [SupplementReading] = []
        func reading(_ metric: String, _ value: Double) {
            result.append(SupplementReading(metric: metric, value: value, localDay: day.localDay))
        }
        func decided(_ doses: [StackDoseEntry]) -> Double? {
            if doses.isEmpty { return nil }
            if doses.contains(where: { $0.state.isSkipped }) { return 0 }
            return doses.allSatisfy { $0.state.isTaken } ? 1 : nil
        }
        var order: [UUID] = []
        for dose in day.doses where !order.contains(dose.itemID) { order.append(dose.itemID) }
        let byItem = Dictionary(grouping: day.doses, by: \.itemID)
        for id in order {
            guard let doses = byItem[id], let value = decided(doses) else { continue }
            reading(SupplementMetric.taken(itemKey: doses[0].itemKey, lane: day.lane), value)
        }
        if let value = decided(day.doses) { reading(SupplementMetric.allTaken(lane: day.lane), value) }
        if day.lane == .supplement, let fraction = SupplementAdherence.fraction(day) { reading(SupplementMetric.adherence, fraction) }
        return result
    }

    /// The reading a rule's metric names, or nil when the day does not decide it.
    public static func reading(forMetric metric: String, in readings: [SupplementReading]) -> SupplementReading? {
        readings.first { $0.metric == metric }
    }

    /// The Protocol check one rule gets from a day's readings: `kept` or `missed` against the rule's target, or
    /// `unknown` with no measured value when no reading decides it. Nil for a rule this vocabulary does not own
    /// (another source, or a metric of another kind).
    public static func check(rule: ProtocolRule, version: Int, localDay: String, readings: [SupplementReading],
                             recordedAt: Date) throws -> RuleCheck? {
        guard rule.source == .food, let metric = rule.target.metric, SupplementMetric.isSupplementMetric(metric) else { return nil }
        guard let identity = DayIdentity(routineDayKey: localDay) else { throw RoutineError.invalidCheck }
        guard let found = Self.reading(forMetric: metric, in: readings.filter { $0.localDay == localDay }) else {
            return try RuleCheck(ruleKey: rule.key, day: identity, version: version, state: .unknown, source: .food, recordedAt: recordedAt)
        }
        let target = rule.target.value ?? 1
        let kept: Bool
        switch rule.target.kind {
        case .done: kept = found.value >= 1
        case .atLeast: kept = found.value >= target
        case .atMost: kept = found.value <= target
        case .exactly: kept = found.value == target
        }
        return try RuleCheck(ruleKey: rule.key, day: identity, version: version, state: kept ? .kept : .missed, source: .food,
                             measuredValue: found.value, recordedAt: recordedAt)
    }
}

extension SupplementRoutineFeed {
    /// One day's readings of both lanes as RoutineKit snapshot readings, for the Food source. Lane-wide metrics go to
    /// `readings`, one item's to `itemReadings`. A dose with no tick, a paused item and an item not due add nothing.
    public static func snapshotReadings(supplements: StackDay, medication: StackDay)
        -> (readings: [RoutineMetric: MetricReading], items: [RoutineItemMetric: MetricReading]) {
        var readings: [RoutineMetric: MetricReading] = [:]
        var items: [RoutineItemMetric: MetricReading] = [:]
        for reading in Self.readings(for: supplements) + Self.readings(for: medication) where reading.value.isFinite {
            if let metric = RoutineMetric(rawValue: reading.metric) { readings[metric] = .measured(reading.value) }
            else if let item = RoutineItemMetric(rawValue: reading.metric) { items[item] = .measured(reading.value) }
        }
        return (readings, items)
    }
}

/// The per-day adherence value an experiment's intervention rule key can read.
public enum SupplementAdherence {
    /// Taken doses over due doses. Nil unless every due dose has a record, because a missing record is not a skipped
    /// dose and a partly recorded day would overstate or understate adherence.
    public static func fraction(_ day: StackDay) -> Double? {
        guard day.isFullyRecorded else { return nil }
        return Double(day.takenDoses) / Double(day.dueDoses)
    }

    /// The value for any metric of the vocabulary on one day: the taken metrics give 1 or 0, adherence a fraction.
    /// Nil when the day does not decide it, so an experiment skips the day instead of counting a zero.
    public static func value(forMetric metric: String, day: StackDay) -> Double? {
        if metric == SupplementMetric.adherence { return day.lane == .supplement ? fraction(day) : nil }
        return SupplementRoutineFeed.reading(forMetric: metric, in: SupplementRoutineFeed.readings(for: day))?.value
    }
}
