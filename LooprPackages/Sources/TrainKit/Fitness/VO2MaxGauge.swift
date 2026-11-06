import AnalyticsKit
import Foundation

// DEC-12.14 and DEC-02.10: the VO2 max gauge on Fitness. The value follows the Cardio Age rule in
// docs/LOOPR_AGE.md: the median of eligible samples over 42 days, with at least three samples on distinct days
// spanning at least 14 days. The window, count and span come from `VO2MaxSourceSelector`, so the gauge and
// Cardio Age cannot drift apart. Cardio Age itself is untouched.

/// One dated VO2 max sample with where it came from.
public struct VO2MaxReading: Equatable, Sendable {
    public let value: Double
    public let date: Date
    /// What the person sees, such as "Apple Watch".
    public let sourceLabel: String
    /// True for a wrist-device estimate. A lab or max-effort test is not one.
    public let isConsumerEstimate: Bool

    public init(value: Double, date: Date, sourceLabel: String, isConsumerEstimate: Bool = false) {
        self.value = value; self.date = date; self.sourceLabel = sourceLabel; self.isConsumerEstimate = isConsumerEstimate
    }

    /// The same eligibility Cardio Age uses: authorised, compatible, valid, and a max or submax exercise test.
    /// Nil for a sample that fails it. Only a max exercise test is not a consumer estimate.
    public init?(healthKit sample: HealthKitVO2MaxSample, sourceLabel: String? = nil) {
        guard sample.authorized, sample.compatibleSource, sample.isValid,
              let type = sample.testType, type == .maxExercise || type == .predictionSubMaxExercise else { return nil }
        self.init(value: sample.vo2max, date: sample.sampledAt, sourceLabel: sourceLabel ?? sample.sourceIdentifier,
                  isConsumerEstimate: type != .maxExercise)
    }
}

/// The median of the readings that qualify at one date.
public struct VO2MaxMedian: Equatable, Sendable {
    public let value: Double
    public let asOf: Date
    public let sampleDates: [Date]
    /// Distinct source labels of the readings used, sorted.
    public let sourceLabels: [String]
    public let includesConsumerEstimate: Bool

    /// Nil when fewer than three samples on distinct days, or the first and last are under 14 days apart.
    public static func make(readings: [VO2MaxReading], asOf: Date, calendar: Calendar) -> VO2MaxMedian? {
        let rule = VO2MaxSourceSelector()
        let used = readings
            .filter { $0.value.isFinite && $0.value > 0 && $0.date <= asOf && asOf.timeIntervalSince($0.date) <= rule.healthKitWindow }
            .sorted { $0.date < $1.date }
        let days = Set(used.map { calendar.dateComponents([.era, .year, .month, .day], from: $0.date) })
        guard used.count >= rule.minimumHealthKitSamples, days.count >= rule.minimumHealthKitSamples,
              let first = used.first?.date, let last = used.last?.date,
              last.timeIntervalSince(first) >= rule.minimumHealthKitSpan else { return nil }
        let sorted = used.map(\.value).sorted()
        let middle = sorted.count / 2
        let median = sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        return VO2MaxMedian(value: median, asOf: asOf, sampleDates: used.map(\.date),
                            sourceLabels: Array(Set(used.map(\.sourceLabel))).sorted(),
                            includesConsumerEstimate: used.contains(where: \.isConsumerEstimate))
    }
}

public enum VO2MaxBandID: String, CaseIterable, Sendable {
    case belowP10, p10ToP25, p25ToP50, p50ToP75, aboveP75
}

/// One stretch of the gauge. A value on a boundary belongs to the band above it, as in
/// `CardioFitnessThresholds.level(for:)`.
public struct VO2MaxBand: Equatable, Sendable {
    public let id: VO2MaxBandID
    /// What the gauge says about a value in this band, such as "top half".
    public let label: String
    /// Nil for the lowest band.
    public let lowerBound: Double?
    /// Nil for the highest band.
    public let upperBound: Double?

    public func contains(_ value: Double) -> Bool {
        (lowerBound.map { value >= $0 } ?? true) && (upperBound.map { value < $0 } ?? true)
    }
}

public enum VO2MaxGaugeAbsence: Equatable, Sendable {
    case needsAge
    case needsReferenceGroup
    /// FRIEND publishes no reference outside ages 20 to 79.
    case unsupportedAge
    case notEnoughSamples
}

public struct VO2MaxGauge: Equatable, Sendable {
    /// ml/kg/min.
    public let value: Double
    /// The five bands, lowest first, cut at the FRIEND 10th, 25th, 50th and 75th percentiles for the person's age
    /// decade and reference group.
    public let bands: [VO2MaxBand]
    public let band: VO2MaxBand
    public let percentiles: FriendPercentileRow
    /// The median for the window that ended one year ago. Nil with too few samples then.
    public let lastYearValue: Double?
    /// Current minus last year. Nil unless both exist.
    public let changeOverTwelveMonths: Double?
    public let sourceLabels: [String]
    public let sampleDates: [Date]
    /// True when a wrist-device estimate is part of the value, so the screen shows the caveat.
    public let showsConsumerEstimateCaveat: Bool

    public static let consumerEstimateCaveat = "Watch estimates can be about 13 to 15% off, so Loopr reads the trend."

    public static func make(readings: [VO2MaxReading], now: Date, age: Int?, group: FriendReferenceGroup?,
                            table: CardioFitnessLevelTable = .friend2015, calendar: Calendar) -> Outcome {
        guard let age else { return .absent(.needsAge) }
        guard let group else { return .absent(.needsReferenceGroup) }
        guard let row = table.rows.first(where: { $0.group == group && ($0.ageLower...$0.ageUpper).contains(age) }) else {
            return .absent(.unsupportedAge)
        }
        guard let current = VO2MaxMedian.make(readings: readings, asOf: now, calendar: calendar) else {
            return .absent(.notEnoughSamples)
        }
        // Last year's needle and the change come from the one year rule the Data tab's year card reads too.
        let previous = VO2MaxYearChange.make(readings: readings, now: now, calendar: calendar)?.yearAgo
        let bands = Self.bands(for: row)
        guard let band = bands.first(where: { $0.contains(current.value) }) else { return .absent(.notEnoughSamples) }
        return .gauge(VO2MaxGauge(value: current.value, bands: bands, band: band, percentiles: row,
            lastYearValue: previous?.value, changeOverTwelveMonths: previous.map { current.value - $0.value },
            sourceLabels: current.sourceLabels, sampleDates: current.sampleDates,
            showsConsumerEstimateCaveat: current.includesConsumerEstimate))
    }

    public enum Outcome: Equatable, Sendable {
        case gauge(VO2MaxGauge)
        case absent(VO2MaxGaugeAbsence)

        public var gauge: VO2MaxGauge? {
            if case .gauge(let gauge) = self { gauge } else { nil }
        }
    }

    static func bands(for row: FriendPercentileRow) -> [VO2MaxBand] {
        [
            VO2MaxBand(id: .belowP10, label: "bottom tenth", lowerBound: nil, upperBound: row.p10),
            VO2MaxBand(id: .p10ToP25, label: "bottom quarter", lowerBound: row.p10, upperBound: row.p25),
            VO2MaxBand(id: .p25ToP50, label: "lower half", lowerBound: row.p25, upperBound: row.p50),
            VO2MaxBand(id: .p50ToP75, label: "top half", lowerBound: row.p50, upperBound: row.p75),
            VO2MaxBand(id: .aboveP75, label: "top quarter", lowerBound: row.p75, upperBound: nil)
        ]
    }
}

/// VO2 max this year against last, as one rule for every tab: the 42-day median today (`VO2MaxMedian`, the gauge's
/// value and Cardio Age's input) against the same median a year earlier. The Fitness gauge's "Up 2.6 in 12 months"
/// and the Data tab's year card both read it, so the two tabs never show two VO2 max values or two changes (R3-OPT-3).
public struct VO2MaxYearChange: Equatable, Sendable {
    public let current: VO2MaxMedian
    /// Nil when a year ago had too few readings for a median.
    public let yearAgo: VO2MaxMedian?

    public var change: Double? { yearAgo.map { current.value - $0.value } }

    /// Nil when today's window has too few readings for a median.
    public static func make(readings: [VO2MaxReading], now: Date, calendar: Calendar) -> VO2MaxYearChange? {
        guard let current = VO2MaxMedian.make(readings: readings, asOf: now, calendar: calendar) else { return nil }
        let yearAgo = calendar.date(byAdding: .year, value: -1, to: now)
            .flatMap { VO2MaxMedian.make(readings: readings, asOf: $0, calendar: calendar) }
        return VO2MaxYearChange(current: current, yearAgo: yearAgo)
    }
}
