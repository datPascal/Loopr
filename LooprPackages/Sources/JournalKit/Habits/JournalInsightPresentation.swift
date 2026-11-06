import Foundation

public enum JournalInsightTarget: String, CaseIterable, Identifiable, Sendable, Hashable {
    case recovery = "Recovery", hrv = "HRV", deepSleep = "Deep sleep", restingHeartRate = "Resting heart rate", mood = "Mood"
    public var id: String { rawValue }
    public var metric: HabitOutcomeMetricID {
        switch self {
        case .recovery: .recoveryScore
        case .hrv: .hrvRMSSD
        case .deepSleep: .deepSleepMinutes
        case .restingHeartRate: .restingHeartRate
        case .mood: .mood
        }
    }
}

public struct JournalInsightRow: Identifiable, Sendable {
    public var id: HabitID { definition.id }
    public let definition: HabitDefinition
    public let target: JournalInsightTarget
    public let metric: HabitMetricEstimate?
    public var sample: HabitMetricSample? { metric?.sample }
    public var status: HabitInsightStatus { sample?.status ?? .unavailable }
    public var difference: Double? {
        switch status {
        case .earlySignal: metric?.rawDifference
        case .clearAssociation, .noClearAssociation, .enoughData: metric?.adjustedDifference
        default: nil
        }
    }
    public init(definition: HabitDefinition, target: JournalInsightTarget, estimate: HabitImpactEstimate?) {
        self.definition = definition; self.target = target
        self.metric = estimate?.metric(target.metric)
    }
    public var detail: String {
        switch status {
        case .unavailable: return "No eligible \(target.rawValue.lowercased()) comparison yet."
        case .collecting: return "Not enough days yet."
        case .cannotSeparate: return "These answers overlap with another habit."
        case .stale: return "Not enough recent days. Last result \(sample?.validThrough.habitKey ?? "unavailable")."
        default:
            guard let comparison else { return "The comparison could not be calculated." }
            return "\(comparison) the day after Yes answers."
        }
    }
    public var summary: String {
        if status == .collecting, let sample { return "Not enough days yet · \(sample.yesCount) with" }
        return comparison.map { "\($0)." } ?? detail
    }
    private var comparison: String? {
        guard let difference, difference.isFinite else { return nil }
        let amount = abs(difference).formatted(.number.precision(.fractionLength(0...1)))
        let unit = target.metric.unit.label
        let change = difference == 0 ? "was the same" : "was \(amount) \(unit) \(difference > 0 ? "higher" : "lower")"
        return "\(target.rawValue) \(change)"
    }
    public var evidence: String {
        let label: String = switch status {
        case .clearAssociation: "Clear link"
        case .earlySignal: "Early signal, small sample"
        case .noClearAssociation: "No clear link"
        case .cannotSeparate: "Cannot separate"
        case .stale: "Stale comparison"
        case .enoughData: "Comparison"
        case .collecting, .unavailable: "Collecting"
        }
        guard let sample else { return label }
        return "\(label) · \(sample.yesCount) days with, \(sample.noCount) without"
    }
}

public extension HabitMetricUnitID {
    var label: String {
        switch self {
        case .scorePoints: "points"
        case .milliseconds: "ms"
        case .beatsPerMinute: "bpm"
        case .minutes: "min"
        case .percentagePoints: "percentage points"
        }
    }
}
