import Foundation

/// Four overnight signals. Oxygen remains decodable only for old alert history.
public enum OvernightVitalMetric: String, Codable, Sendable, CaseIterable, Hashable, Comparable {
    case restingHeartRate = "resting_heart_rate"
    case heartRateVariability = "rmssd"
    case respiratoryRate = "respiratory_rate"
    case skinTemperatureDeviation = "skin_temperature_deviation"
    case oxygenSaturation = "oxygen_saturation"

    public static var monitored: [Self] { [.restingHeartRate, .heartRateVariability, .respiratoryRate, .skinTemperatureDeviation] }
    public static func < (lhs: Self, rhs: Self) -> Bool { allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)! }
    public var minimumHalfWidth: Double {
        switch self {
        case .restingHeartRate: 3
        case .heartRateVariability: 0
        case .respiratoryRate: 1
        case .skinTemperatureDeviation: 0.3
        case .oxygenSaturation: 2
        }
    }
    public var relativeHalfWidth: Double { self == .heartRateVariability ? 0.15 : 0 }
    public var name: String {
        switch self {
        case .restingHeartRate: "Resting heart rate"
        case .heartRateVariability: "HRV"
        case .respiratoryRate: "Breathing rate"
        case .skinTemperatureDeviation: "Skin temperature"
        case .oxygenSaturation: "Blood oxygen"
        }
    }
}

public struct OvernightVitalsNight: Codable, Equatable, Sendable {
    public let night: String
    /// Skin temperature is the settled nightly wrist value in °C, not its deviation.
    public let values: [OvernightVitalMetric: Double]
    public init(night: String, values: [OvernightVitalMetric: Double]) { self.night = night; self.values = values }
}

public struct OvernightVitalRange: Codable, Equatable, Sendable {
    public let metric: OvernightVitalMetric
    public let median: Double
    public let low: Double
    public let high: Double
    public let nights: Int
    public func contains(_ value: Double) -> Bool { value >= low && value <= high }
}

public enum OvernightVitalDirection: String, Codable, Sendable, Equatable { case higher, lower }
public struct OvernightVitalOutlier: Codable, Equatable, Sendable {
    public let metric: OvernightVitalMetric
    public let value: Double
    public let range: OvernightVitalRange
    public let direction: OvernightVitalDirection
}

public struct OvernightVitalAssessment: Codable, Equatable, Sendable {
    public enum State: String, Codable, Equatable, Sendable { case within, above, below, learning, unavailable }
    public let metric: OvernightVitalMetric
    public let value: Double?
    public let delta: Double?
    public let usualRange: OvernightVitalRange?
    public let state: State
    public let scorableNights: Int
    public let requiredNights: Int
    public var learningProgress: String { "\(min(scorableNights, requiredNights)) of \(requiredNights) nights" }
    public var outlier: OvernightVitalOutlier? {
        guard let value, let usualRange, state == .above || state == .below else { return nil }
        return .init(metric: metric, value: value, range: usualRange, direction: state == .above ? .higher : .lower)
    }
}

/// Produced by the canonical display derivation once and persisted with that day.
public struct OvernightVitalsAssessment: Codable, Equatable, Sendable {
    public let night: String
    public let signals: [OvernightVitalAssessment]
    public let isFlagged: Bool
    public let algorithmVersion: String
    public var outliers: [OvernightVitalOutlier] { signals.compactMap(\.outlier) }
    public var triggeringSignals: [OvernightVitalMetric] { outliers.map(\.metric) }
}

public struct OvernightVitalsCheckState: Codable, Equatable, Sendable {
    public var lastEvaluatedNight: String?
    public var lastNotifiedNight: String?
    public var lastNotifiedMetrics: [OvernightVitalMetric]
    /// Remains true until an observed unflagged night or calendar gap ends the episode.
    public var episodeNotified: Bool?
    public var lastAssessmentFingerprint: String?
    public init(lastEvaluatedNight: String? = nil, lastNotifiedNight: String? = nil,
                lastNotifiedMetrics: [OvernightVitalMetric] = [], episodeNotified: Bool? = nil, lastAssessmentFingerprint: String? = nil) {
        self.lastEvaluatedNight = lastEvaluatedNight; self.lastNotifiedNight = lastNotifiedNight
        self.lastNotifiedMetrics = lastNotifiedMetrics; self.episodeNotified = episodeNotified
        self.lastAssessmentFingerprint = lastAssessmentFingerprint
    }
    public static let initial = OvernightVitalsCheckState()
}

public struct OvernightVitalsParameters: Equatable, Sendable {
    public var minimumNights: Int
    public var trailingNights: Int
    public var madMultiplier: Double
    public var minimumOutliers: Int
    public init(minimumNights: Int = 14, trailingNights: Int = 30, madMultiplier: Double = 2.5,
                minimumOutliers: Int = 2) {
        self.minimumNights = minimumNights; self.trailingNights = trailingNights
        self.madMultiplier = madMultiplier; self.minimumOutliers = minimumOutliers
    }
    public static let standard = OvernightVitalsParameters()
}

public struct OvernightVitalsResult: Equatable, Sendable {
    public enum Decision: Equatable, Sendable { case notify, quiet(String) }
    public let night: String
    public let ranges: [OvernightVitalRange]
    public let outliers: [OvernightVitalOutlier]
    public let decision: Decision
    public let nextState: OvernightVitalsCheckState
    public var shouldNotify: Bool { decision == .notify }
}

public enum OvernightVitalsCheck {
    public static let algorithmVersion = "loopr.overnight-check.v2.four-signals"

    public static func typicalRange(metric: OvernightVitalMetric, values: [Double],
                                    parameters: OvernightVitalsParameters = .standard) -> OvernightVitalRange? {
        let recent = Array(values.suffix(parameters.trailingNights)).filter(\.isFinite)
        // The current scorable night is included in the learning count, but never in the range.
        guard recent.count + 1 >= parameters.minimumNights, let center = median(recent) else { return nil }
        let mad = median(recent.map { abs($0 - center) }) ?? 0
        let width = max(parameters.madMultiplier * 1.4826 * mad, metric.minimumHalfWidth,
                        metric.relativeHalfWidth * abs(center))
        return .init(metric: metric, median: center, low: center - width, high: center + width, nights: recent.count)
    }

    public static func assessment(nights: [OvernightVitalsNight], calendar: Calendar,
                                  parameters: OvernightVitalsParameters = .standard) -> OvernightVitalsAssessment? {
        var byDay: [String: OvernightVitalsNight] = [:]
        for night in nights where date(night.night, calendar: calendar) != nil { byDay[night.night] = night }
        let sorted = byDay.values.sorted { $0.night < $1.night }
        guard let latest = sorted.last, let when = date(latest.night, calendar: calendar),
              let floor = calendar.date(byAdding: .day, value: -parameters.trailingNights, to: when) else { return nil }
        let prior = sorted.dropLast().filter { night in
            guard let day = date(night.night, calendar: calendar) else { return false }
            return day >= floor && day < when
        }
        let signals = OvernightVitalMetric.monitored.map { metric -> OvernightVitalAssessment in
            let value = latest.values[metric].flatMap { $0.isFinite ? $0 : nil }
            var history = prior.compactMap { $0.values[metric] }.filter(\.isFinite)
            if metric == .skinTemperatureDeviation, let center = median(history) {
                history = history.filter { (30...45).contains($0) && abs($0 - center) <= SkinTemperatureAnalytics.fitArtifactCelsius }
            }
            let count = history.count + (value == nil ? 0 : 1)
            let contactJump = metric == .skinTemperatureDeviation && history.count >= 3 && value.map { v in median(history).map { abs(v - $0) > SkinTemperatureAnalytics.fitArtifactCelsius } ?? false } == true
            let range = value == nil || contactJump ? nil : typicalRange(metric: metric, values: history, parameters: parameters)
            let state: OvernightVitalAssessment.State
            if value == nil || contactJump { state = .unavailable }
            else if let range, let value { state = value > range.high ? .above : value < range.low ? .below : .within }
            else { state = .learning }
            return .init(metric: metric, value: contactJump ? nil : value, delta: contactJump || (metric == .skinTemperatureDeviation && count < 4) ? nil : value.flatMap { v in median(history).map { v - $0 } },
                usualRange: range, state: state, scorableNights: count, requiredNights: parameters.minimumNights)
        }
        let hasRecovery = signals.contains { $0.metric != .skinTemperatureDeviation && $0.value != nil }
        return .init(night: latest.night, signals: signals,
            isFlagged: hasRecovery && signals.compactMap(\.outlier).count >= parameters.minimumOutliers,
            algorithmVersion: algorithmVersion)
    }

    /// Notification policy over the same cached daily assessments Today reads.
    public static func evaluate(assessments: [OvernightVitalsAssessment], state: OvernightVitalsCheckState,
                                calendar: Calendar) -> OvernightVitalsResult? {
        let sorted = assessments.sorted { $0.night < $1.night }
        guard let latest = sorted.last else { return nil }
        var next = state
        // Older saved states lack an explicit episode flag. Keep their notified
        // edge until an observed clear night or calendar gap ends the episode.
        if next.episodeNotified == nil { next.episodeNotified = state.lastNotifiedNight != nil }
        let previous = sorted.dropLast().last
        let fingerprint = latest.algorithmVersion + "|previous:\(previous?.night ?? "nil"):\(previous?.isFlagged.description ?? "nil")|" + latest.signals.map {
            "\($0.metric.rawValue):\($0.state.rawValue):\($0.value.map(String.init(describing:)) ?? "nil"):\($0.usualRange?.low.description ?? "nil"):\($0.usualRange?.high.description ?? "nil")"
        }.joined(separator: "|")
        if let evaluated = state.lastEvaluatedNight,
           evaluated > latest.night || (evaluated == latest.night && state.lastAssessmentFingerprint == fingerprint) {
            return .init(night: latest.night, ranges: latest.signals.compactMap(\.usualRange), outliers: latest.outliers,
                decision: .quiet("already evaluated"), nextState: next)
        }
        let consecutive = previous.map { isNextNight(latest.night, after: $0.night, calendar: calendar) } ?? false
        // If launches were skipped, an unflagged intervening assessment still clears the edge.
        let intervening = sorted.filter { $0.night > (state.lastEvaluatedNight ?? "") && $0.night < latest.night }
        let relevant = sorted.filter { $0.night >= (state.lastEvaluatedNight ?? "") }
        let missingBoundary = state.lastEvaluatedNight.map { evaluated in
            guard let first = relevant.first, first.night > evaluated else { return false }
            return !isNextNight(first.night, after: evaluated, calendar: calendar)
        } ?? false
        let hasGap = missingBoundary || zip(relevant, relevant.dropFirst()).contains { !isNextNight($0.1.night, after: $0.0.night, calendar: calendar) }
        if !consecutive || hasGap || previous?.isFlagged != true || intervening.contains(where: { !$0.isFlagged }) {
            next.episodeNotified = false
        }
        next.lastEvaluatedNight = latest.night
        next.lastAssessmentFingerprint = fingerprint
        let decision: OvernightVitalsResult.Decision
        if !latest.isFlagged {
            next.episodeNotified = false; decision = .quiet("night within range or still learning")
        } else if !consecutive || previous?.isFlagged != true {
            decision = .quiet("first flagged night")
        } else if next.episodeNotified == true || state.lastNotifiedNight == latest.night {
            decision = .quiet("episode already notified")
        } else {
            decision = .notify; next.episodeNotified = true
            next.lastNotifiedNight = latest.night; next.lastNotifiedMetrics = latest.triggeringSignals
        }
        return .init(night: latest.night, ranges: latest.signals.compactMap(\.usualRange), outliers: latest.outliers,
            decision: decision, nextState: next)
    }

    /// Compatibility for sources of synthetic nightly inputs. Production reads cached assessments.
    public static func evaluate(nights: [OvernightVitalsNight], state: OvernightVitalsCheckState,
                                calendar: Calendar, parameters: OvernightVitalsParameters = .standard) -> OvernightVitalsResult? {
        let sorted = nights.sorted { $0.night < $1.night }
        let assessments = sorted.indices.compactMap { assessment(nights: Array(sorted.prefix($0 + 1)), calendar: calendar, parameters: parameters) }
        return evaluate(assessments: assessments, state: state, calendar: calendar)
    }

    static func isNextNight(_ night: String, after prior: String, calendar: Calendar) -> Bool {
        guard let a = date(prior, calendar: calendar), let b = date(night, calendar: calendar) else { return false }
        return calendar.dateComponents([.day], from: a, to: b).day == 1
    }
    static func date(_ night: String, calendar: Calendar) -> Date? {
        let parts = night.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        let result = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        guard let result else { return nil }
        let check = calendar.dateComponents([.year, .month, .day], from: result)
        return check.year == parts[0] && check.month == parts[1] && check.day == parts[2] ? result : nil
    }

    /// When a morning notice may go out: not before the person's usual wake
    /// time, never before `earliest` (the end of quiet hours), and never in
    /// the past.
    ///
    /// - Parameters:
    ///   - usualWakeMinute: typical wake time, minutes after local midnight.
    ///   - earliestMinute: the earliest the caller allows, minutes after local
    ///     midnight, usually the end of quiet hours.
    public static func deliveryDate(
        now: Date,
        usualWakeMinute: Int?,
        earliestMinute: Int,
        calendar: Calendar
    ) -> Date {
        let minute = max(usualWakeMinute ?? earliestMinute, earliestMinute)
        let startOfDay = calendar.startOfDay(for: now)
        let target = calendar.date(byAdding: .minute, value: minute, to: startOfDay) ?? now
        return max(target, now)
    }

    /// The median of the wake times of recent main sleeps, in minutes after
    /// local midnight. Nil below three nights.
    public static func usualWakeMinute(wakeTimes: [Date], calendar: Calendar) -> Int? {
        let minutes = wakeTimes.suffix(14).map { date -> Double in
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            return Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
        }
        guard minutes.count >= 3, let value = median(minutes) else { return nil }
        return Int(value.rounded())
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}

/// Rate limit for the cardio fitness notice. The estimate itself belongs to
/// the vitals work; this only decides whether a "low range" result may be
/// announced. Apple sends its equivalent at most once every four months.
public enum CardioFitnessNoticeGate {
    public static let minimumMonthsBetweenNotices = 4

    public static func mayNotify(lastNotifiedAt: Date?, now: Date, calendar: Calendar) -> Bool {
        guard let lastNotifiedAt else { return true }
        guard let allowed = calendar.date(byAdding: .month, value: minimumMonthsBetweenNotices,
                                          to: lastNotifiedAt) else { return false }
        return now >= allowed
    }
}
