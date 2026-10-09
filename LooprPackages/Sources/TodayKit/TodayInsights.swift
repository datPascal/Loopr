import Foundation
import AnalyticsKit
import DomainKit
import DesignSystem

/// A metric Today can compare with its usual, pin as a tile, or chart.
///
/// Each case maps to one metric-history series (`linkID`), so the value on a
/// tile is the value its detail page ends on.
public enum TodayTrackedMetric: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case hrv
    case restingHeartRate
    case respiratoryRate
    case sleep
    case sleepEfficiency
    case deepSleep
    case remSleep
    case recovery
    case strain
    case stress
    case steps
    case activeEnergy

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .hrv: "HRV"
        case .restingHeartRate: "Resting heart rate"
        case .respiratoryRate: "Breathing rate"
        case .sleep: "Sleep"
        case .sleepEfficiency: "Sleep efficiency"
        case .deepSleep: "Deep sleep"
        case .remSleep: "REM sleep"
        case .recovery: "Recovery"
        case .strain: "Strain"
        case .stress: "Stress"
        case .steps: "Estimated steps"
        case .activeEnergy: "Active energy"
        }
    }

    /// The name on a half-width tile.
    public var shortTitle: String {
        switch self {
        case .restingHeartRate: "Resting HR"
        case .sleepEfficiency: "Efficiency"
        default: title
        }
    }

    public var linkID: String {
        switch self {
        case .hrv: LooprMetricLinkID.rmssd
        case .restingHeartRate: LooprMetricLinkID.restingHeartRate
        case .respiratoryRate: LooprMetricLinkID.respiratoryRate
        case .sleep: LooprMetricLinkID.sleepDuration
        case .sleepEfficiency: LooprMetricLinkID.sleepEfficiency
        case .deepSleep: LooprMetricLinkID.deepSleep
        case .remSleep: LooprMetricLinkID.remSleep
        case .recovery: LooprMetricLinkID.recovery
        case .strain: LooprMetricLinkID.strain
        case .stress: LooprMetricLinkID.stress
        case .steps: LooprMetricLinkID.steps
        case .activeEnergy: LooprMetricLinkID.activeEnergy
        }
    }

    /// The unit word printed after the number, or nil for none.
    public var unit: String? {
        switch self {
        case .hrv: "ms"
        case .restingHeartRate: "bpm"
        case .respiratoryRate: "br/min"
        case .sleepEfficiency: "%"
        case .recovery: nil
        case .activeEnergy: "kcal"
        case .sleep, .deepSleep, .remSleep, .strain, .stress, .steps: nil
        }
    }

    /// True when higher is better, false when lower is, nil when neither.
    /// Drives the colour of the "vs usual" caption (tabs spec, principle 6).
    public var higherIsBetter: Bool? {
        switch self {
        case .hrv, .sleep, .sleepEfficiency, .deepSleep, .remSleep, .recovery, .steps: true
        case .restingHeartRate, .respiratoryRate: false
        // Stress moves with the day; a low reading is not an achievement and
        // a high one is not a warning, so it stays grey.
        case .strain, .stress, .activeEnergy: nil
        }
    }

    public var deltaFormat: LooprDeltaFormat {
        switch self {
        case .sleep, .deepSleep, .remSleep: .duration
        case .respiratoryRate, .strain: .number(digits: 1)
        default: .number(digits: 0)
        }
    }

    /// Nightly metrics count nights while learning; day metrics count days.
    public var learningNoun: String { isNightly ? "nights" : "days" }

    public var isNightly: Bool {
        switch self {
        case .hrv, .restingHeartRate, .respiratoryRate, .sleep, .sleepEfficiency, .deepSleep, .remSleep, .recovery: true
        case .strain, .stress, .steps, .activeEnergy: false
        }
    }

    public var accent: LooprColorToken {
        switch self {
        // The overnight signals share the recovery accent: heart red on a
        // number that went the good way reads as a warning.
        case .hrv, .restingHeartRate, .respiratoryRate, .recovery: .recovery
        case .sleep, .sleepEfficiency, .deepSleep, .remSleep: .sleep
        case .strain: .strain
        case .stress: .stress
        case .steps, .activeEnergy: .movement
        }
    }

    /// Steps and active energy are estimates from wrist motion and heart rate.
    public var isEstimate: Bool { self == .steps || self == .activeEnergy }

    /// The number and its unit as a tile or row prints them: `58` `ms`,
    /// `7 h 42 m`, `8,240`, `14.6` `br/min`.
    public func formatted(_ value: Double) -> (value: String, unit: String?) {
        switch self {
        case .sleep, .deepSleep, .remSleep:
            return (LooprUnitFormatter.duration(minutes: value) ?? "", nil)
        case .respiratoryRate, .strain:
            return (LooprUnitFormatter.number(value, digits: 1) ?? "", unit)
        case .steps, .activeEnergy:
            return (LooprUnitFormatter.number(value.rounded()) ?? "", unit)
        default:
            return (LooprUnitFormatter.number(value.rounded(), digits: 0) ?? "", unit)
        }
    }

    /// The metrics a person can pin, in the order the edit sheet lists them.
    public static let pinnable: [TodayTrackedMetric] = [
        .hrv, .restingHeartRate, .respiratoryRate, .steps, .activeEnergy, .strain, .stress,
        .recovery, .sleep, .sleepEfficiency, .deepSleep, .remSleep
    ]
}

/// The inputs to the recovery score for one day, split by how much each
/// moved it. Built by the app from the same formula the score uses.
public struct TodayRecoveryBreakdown: Equatable, Sendable {
    public enum Signal: String, Sendable, CaseIterable {
        case hrv
        case restingHeartRate
        case respiratoryRate

        public var metric: TodayTrackedMetric {
            switch self {
            case .hrv: .hrv
            case .restingHeartRate: .restingHeartRate
            case .respiratoryRate: .respiratoryRate
            }
        }
    }

    public enum InputStatus: Equatable, Sendable {
        case used
        case noReading
        case learning(have: Int, need: Int)
        case flatBaseline
    }

    public struct Input: Equatable, Sendable, Identifiable {
        public let signal: Signal
        public let status: InputStatus
        public let value: Double?
        public let usual: Double?
        public let baselineNights: Int
        /// The formula's weight before renormalising (0.40, 0.30, 0.20).
        public let weight: Double
        /// The signal's exact term in the composite z.
        public let contribution: Double?
        /// Score points, split in proportion to the terms.
        public let points: Double?

        public var id: String { signal.rawValue }

        public init(signal: Signal, status: InputStatus, value: Double?, usual: Double?, baselineNights: Int,
                    weight: Double, contribution: Double?, points: Double?) {
            self.signal = signal
            self.status = status
            self.value = value
            self.usual = usual
            self.baselineNights = baselineNights
            self.weight = weight
            self.contribution = contribution
            self.points = points
        }
    }

    /// The score this split produces.
    public let score: Double?
    public let isSaturated: Bool
    public let isMeaningful: Bool
    public let inputs: [Input]
    public let nightsNeeded: Int

    public init(score: Double?, isSaturated: Bool, isMeaningful: Bool, inputs: [Input], nightsNeeded: Int) {
        self.score = score
        self.isSaturated = isSaturated
        self.isMeaningful = isMeaningful
        self.inputs = inputs
        self.nightsNeeded = nightsNeeded
    }

    public func input(_ signal: Signal) -> Input? { inputs.first { $0.signal == signal } }

    /// The most earlier nights any signal with a reading has.
    public var nightsSoFar: Int {
        inputs.filter { $0.value != nil && $0.status != .flatBaseline }.map(\.baselineNights).sorted(by: >).dropFirst().first ?? 0
    }

    /// Whether this split explains the score shown on screen: the same score
    /// within rounding. Only then are points shown.
    public func explains(_ displayed: Double?) -> Bool {
        guard let score, let displayed, displayed.isFinite else { return false }
        return abs(score - displayed) <= 1.0
    }
}

/// Whether resting heart rate has been running above usual for more than a
/// night, from the illness CUSUM in AnalyticsKit. Only ever strengthens the
/// heads-up card's wording; it never shows the card on its own.
public enum TodayRestingTrend: String, Sendable, Equatable {
    case usual
    /// Above usual on this night.
    case elevated
    /// Above usual on this night and the one before.
    case persistent
}

/// Minutes in one heart-rate zone for the strain breakdown.
public struct TodayZoneMinutes: Equatable, Sendable, Identifiable {
    public let id: Int
    public let name: String
    public let minutes: Double

    public init(id: Int, name: String, minutes: Double) {
        self.id = id
        self.name = name
        self.minutes = minutes
    }
}

/// What tonight's bedtime line is built from.
public struct TodayTonightInputs: Equatable, Sendable {
    /// Configured sleep need in minutes.
    public let needMinutes: Double?
    /// The wake alarm's time as minutes after midnight, when one is on.
    public let alarmMinute: Int?
    /// The usual wake time Sleep suggests, minutes after midnight.
    public let suggestedWakeMinute: Int?

    public init(needMinutes: Double?, alarmMinute: Int?, suggestedWakeMinute: Int?) {
        self.needMinutes = needMinutes
        self.alarmMinute = alarmMinute
        self.suggestedWakeMinute = suggestedWakeMinute
    }
}

/// Everything around the day's summary that Today needs: history for the
/// "vs usual" comparisons, the recovery split, journal context and tonight.
/// Loaded once per day, off the main actor.
public struct TodayDayContext: Equatable, Sendable {
    public let day: DayIdentity
    /// Local start of `day` in the calendar the history uses.
    public let dayStart: Date
    /// Daily points per metric, ascending, ending on `day` (inclusive).
    public let history: [TodayTrackedMetric: [LooprChartPoint]]
    public let recovery: TodayRecoveryBreakdown?
    public let restingTrend: TodayRestingTrend
    /// Journal behaviours and tags logged for the evening before and the day.
    public let journalFactors: [String]
    /// The strain range that suits the day's recovery. Nil until the mapping
    /// exists; the strain ring then draws no range.
    public let suggestedStrainRange: ClosedRange<Double>?
    public let strainTarget: StrainTarget?
    public let zoneMinutes: [TodayZoneMinutes]
    public let tonight: TodayTonightInputs?
    public let overnightAssessment: OvernightVitalsAssessment?
    public let temperatureMissingReason: String?

    public init(
        day: DayIdentity,
        dayStart: Date,
        history: [TodayTrackedMetric: [LooprChartPoint]],
        recovery: TodayRecoveryBreakdown? = nil,
        restingTrend: TodayRestingTrend = .usual,
        journalFactors: [String] = [],
        suggestedStrainRange: ClosedRange<Double>? = nil,
        strainTarget: StrainTarget? = nil,
        zoneMinutes: [TodayZoneMinutes] = [],
        tonight: TodayTonightInputs? = nil,
        overnightAssessment: OvernightVitalsAssessment? = nil,
        temperatureMissingReason: String? = nil
    ) {
        self.day = day
        self.dayStart = dayStart
        self.history = history
        self.recovery = recovery
        self.restingTrend = restingTrend
        self.journalFactors = journalFactors
        self.suggestedStrainRange = suggestedStrainRange
        self.strainTarget = strainTarget
        self.zoneMinutes = zoneMinutes
        self.tonight = tonight
        self.overnightAssessment = overnightAssessment
        self.temperatureMissingReason = temperatureMissingReason
    }

    /// The metrics the context loader reads history for.
    public static let historyMetrics: [TodayTrackedMetric] = TodayTrackedMetric.allCases
    /// Days of history loaded: enough for the 30-day usual range and the
    /// 30-day recovery trend.
    public static let historyDays = 60

    /// The day's own point for a metric, if the history has one.
    public func value(_ metric: TodayTrackedMetric, calendar: Calendar = .current) -> Double? {
        guard let last = history[metric]?.last, calendar.isDate(last.date, inSameDayAs: dayStart) else { return nil }
        return last.value
    }

    /// The usual range from the 30 days before `day`, or nil while there are
    /// fewer than 14 measured days.
    public func usual(_ metric: TodayTrackedMetric, calendar: Calendar = .current) -> LooprBaselineBand? {
        LooprBaselineBand.trailing(history[metric] ?? [], before: dayStart,
            minimumDays: LooprBaselineBand.minimumDays - (value(metric, calendar: calendar) == nil ? 0 : 1), calendar: calendar)
    }

    /// Measured days in the 30 days before `day`, for "Learning · 3 of 14".
    public func measuredDaysBefore(_ metric: TodayTrackedMetric, calendar: Calendar = .current) -> Int {
        guard let start = calendar.date(byAdding: .day, value: -LooprBaselineBand.windowDays, to: dayStart) else { return 0 }
        return Set((history[metric] ?? []).filter { $0.date >= start && $0.date < dayStart && $0.value.isFinite }
            .map { calendar.startOfDay(for: $0.date) }).count
    }

    /// The latest point strictly before `day`, for a carried recovery.
    public func latestBefore(_ metric: TodayTrackedMetric, withinDays days: Int, calendar: Calendar = .current) -> LooprChartPoint? {
        guard let floor = calendar.date(byAdding: .day, value: -days, to: dayStart) else { return nil }
        return (history[metric] ?? []).last { $0.date < dayStart && $0.date >= floor }
    }
}

/// Reads the context for a day. The app implements it over its metric
/// history, journal, sleep and alarm stores.
public protocol TodayContextRepository: Sendable {
    func context(for day: DayIdentity, summary: TodaySummary?) async throws -> TodayDayContext?
}
