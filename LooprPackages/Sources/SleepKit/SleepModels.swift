import Foundation
import DomainKit
import DesignSystem

public struct SleepSessionSummary: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let start: Date
    public let end: Date
    public let durationMinutes: Int
    public let isMainSleep: Bool
    public let isPartial: Bool
    public let confidence: Double
    public let state: MetricState

    public init(id: String, start: Date, end: Date, durationMinutes: Int, isMainSleep: Bool, isPartial: Bool, confidence: Double, state: MetricState) {
        self.id = id
        self.start = start
        self.end = end
        self.durationMinutes = durationMinutes
        self.isMainSleep = isMainSleep
        self.isPartial = isPartial
        self.confidence = confidence
        self.state = state
    }

    public var durationLabel: String {
        let hours = durationMinutes / 60
        let minutes = durationMinutes % 60
        return "\(hours) h \(minutes) m"
    }
}

public struct SleepMetricValue: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let value: String?
    public let unit: String
    public let numericValue: Double?
    public let numericUnit: SleepMetricUnitID?
    public let state: MetricState
    public let confidence: String?
    public let source: String
    public let algorithmVersion: String?

    public init(id: String, title: String, value: String?, unit: String, state: MetricState, confidence: String? = nil, source: String, algorithmVersion: String? = nil, numericValue: Double? = nil, numericUnit: SleepMetricUnitID? = nil) {
        self.id = id
        self.title = title
        self.value = value
        self.unit = unit
        self.numericValue = numericValue?.isFinite == true ? numericValue : nil
        self.numericUnit = numericUnit
        self.state = state
        self.confidence = confidence
        self.source = source
        self.algorithmVersion = algorithmVersion
    }

    private enum CodingKeys: String, CodingKey { case id, title, value, unit, numericValue, numericUnit, state, confidence, source, algorithmVersion }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        value = try container.decodeIfPresent(String.self, forKey: .value)
        unit = try container.decode(String.self, forKey: .unit)
        let decodedNumeric = try container.decodeIfPresent(Double.self, forKey: .numericValue)
        numericValue = decodedNumeric?.isFinite == true ? decodedNumeric : nil
        numericUnit = try container.decodeIfPresent(SleepMetricUnitID.self, forKey: .numericUnit)
        state = try container.decode(MetricState.self, forKey: .state)
        confidence = try container.decodeIfPresent(String.self, forKey: .confidence)
        source = try container.decode(String.self, forKey: .source)
        algorithmVersion = try container.decodeIfPresent(String.self, forKey: .algorithmVersion)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(value, forKey: .value)
        try container.encode(unit, forKey: .unit)
        try container.encodeIfPresent(numericValue, forKey: .numericValue)
        try container.encodeIfPresent(numericUnit, forKey: .numericUnit)
        try container.encode(state, forKey: .state)
        try container.encodeIfPresent(confidence, forKey: .confidence)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(algorithmVersion, forKey: .algorithmVersion)
    }

    public var accessibilitySummary: String {
        guard let value else { return "\(title). \(state.title). \(state.detail)" }
        return [title, value, unit, confidence, state == .measuredZero ? state.title : nil].compactMap { $0 }.joined(separator: ", ")
    }
}

public enum SleepMetricUnitID: String, Codable, Sendable {
    case minutes
    case percentagePoints
    case scorePoints
    case hours
    case unknown
}

public struct SleepTrendPoint: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let localDay: String
    public let value: Double?
    public let state: MetricState
    public let unit: String
    /// When the night's main sleep began and ended. Nil for a night with no
    /// main sleep, and for points saved before these fields existed.
    public let start: Date?
    public let end: Date?
    /// The night's other numbers, keyed by sleep metric id (`deep`, `rem`,
    /// `light`, `awake`, `efficiency`, `disturbances`, `cycles`) plus
    /// `respiration` for the overnight breathing rate. A missing key means no
    /// reading, never zero. See `SleepTrendPoint.nightValues(_:breathingRate:)`.
    public let values: [String: Double]

    public init(id: String, localDay: String, value: Double?, state: MetricState, unit: String,
                start: Date? = nil, end: Date? = nil, values: [String: Double] = [:]) {
        self.id = id
        self.localDay = localDay
        self.value = value
        self.state = state
        self.unit = unit
        self.start = start
        self.end = end
        self.values = values.filter { $0.value.isFinite }
    }

    private enum CodingKeys: String, CodingKey { case id, localDay, value, state, unit, start, end, values }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        localDay = try container.decode(String.self, forKey: .localDay)
        value = try container.decodeIfPresent(Double.self, forKey: .value)
        state = try container.decode(MetricState.self, forKey: .state)
        unit = try container.decode(String.self, forKey: .unit)
        // Saved before per-night detail existed: absent, never zero.
        start = try container.decodeIfPresent(Date.self, forKey: .start)
        end = try container.decodeIfPresent(Date.self, forKey: .end)
        values = (try container.decodeIfPresent([String: Double].self, forKey: .values) ?? [:]).filter { $0.value.isFinite }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(localDay, forKey: .localDay)
        try container.encodeIfPresent(value, forKey: .value)
        try container.encode(state, forKey: .state)
        try container.encode(unit, forKey: .unit)
        try container.encodeIfPresent(start, forKey: .start)
        try container.encodeIfPresent(end, forKey: .end)
        if !values.isEmpty { try container.encode(values, forKey: .values) }
    }

    /// The per-night numbers a trend point carries, from a night's snapshot.
    /// Only a night with a main sleep has any, and a metric without a reading
    /// is left out rather than written as zero. The breathing rate comes from
    /// the Heart derivation of the same night.
    public static func nightValues(_ snapshot: SleepDaySnapshot, breathingRate: Double? = nil) -> [String: Double] {
        guard snapshot.mainSleep != nil else { return [:] }
        var values: [String: Double] = [:]
        for id in nightValueIDs {
            guard let metric = snapshot.metric(id), metric.state != .absent,
                  let number = metric.numericValue, number.isFinite else { continue }
            values[id] = number
        }
        if let breathingRate, breathingRate.isFinite { values[breathingRateID] = breathingRate }
        return values
    }

    /// Sleep metric ids copied into `values`.
    public static let nightValueIDs = ["deep", "rem", "light", "awake", "efficiency", "disturbances", "cycles"]
    /// The key the overnight breathing rate is stored under.
    public static let breathingRateID = "respiration"
}

/// Trend windows are civil-day windows. They intentionally do not convert a
/// sleep's local-day label through a device time zone, so a DST transition or
/// timezone travel cannot duplicate or erase a night.
public enum SleepTrendRange: String, CaseIterable, Hashable, Sendable {
    case week
    case month

    public var title: String {
        switch self {
        case .week: "Week"
        case .month: "Month"
        }
    }

    fileprivate var dayCount: Int {
        switch self {
        case .week: 7
        case .month: 31
        }
    }
}

public enum SleepTrendFilter {
    /// Filters canonical `yyyy-MM-dd` local-day labels with a UTC calendar used
    /// only for civil-date arithmetic. The resulting dates remain the source
    /// labels and are never displayed as timestamps.
    public static func points(_ points: [SleepTrendPoint], range: SleepTrendRange) -> [SleepTrendPoint] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parsed = points.compactMap { point -> (SleepTrendPoint, Date)? in
            guard let date = localDayDate(point.localDay, calendar: calendar) else { return nil }
            return (point, date)
        }
        guard let latest = parsed.map(\.1).max(),
              let earliest = calendar.date(byAdding: .day, value: -(range.dayCount - 1), to: latest)
        else { return [] }
        return parsed
            .filter { $0.1 >= earliest && $0.1 <= latest }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                return lhs.0.id < rhs.0.id
            }
            .map(\.0)
    }

    private static func localDayDate(_ value: String, calendar: Calendar) -> Date? {
        let components = value.split(separator: "-").compactMap { Int($0) }
        guard components.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: components[0], month: components[1], day: components[2]))
    }
}

public struct SleepSuggestedAlarm: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    /// A canonical local clock label such as `07:30`; no timezone conversion
    /// is performed by SleepKit.
    public let localTime: String
    public let reason: String
    public let source: String
    public let algorithmVersion: String?

    public init(id: String = "suggested-alarm", localTime: String, reason: String, source: String, algorithmVersion: String? = nil) {
        self.id = id
        self.localTime = localTime
        self.reason = reason
        self.source = source
        self.algorithmVersion = algorithmVersion
    }
}

public enum SleepAlarmConfirmation: Equatable, Sendable {
    case applied
    case unavailable(String)
}

/// Notification and hardware effects are intentionally injected. Until a
/// verified platform seam is available, production uses this fail-closed
/// implementation and never claims that an alarm was scheduled.
public protocol SleepSuggestedAlarmEffect: Sendable {
    func confirm(_ suggestion: SleepSuggestedAlarm) async -> SleepAlarmConfirmation
}

public struct UnavailableSleepSuggestedAlarmEffect: SleepSuggestedAlarmEffect {
    public init() {}
    public func confirm(_ suggestion: SleepSuggestedAlarm) async -> SleepAlarmConfirmation {
        .unavailable("Alarm scheduling is unavailable on this device.")
    }
}

public struct SleepDaySnapshot: Codable, Equatable, Sendable {
    public let day: DayIdentity
    public let state: MetricState
    public let mainSleep: SleepSessionSummary?
    public let naps: [SleepSessionSummary]
    public let metrics: [SleepMetricValue]
    public let hypnogram: [SleepSegment]
    public let trend: [SleepTrendPoint]
    public let needHours: Double?
    public let debtHours: Double?
    public let source: String
    public let algorithmVersion: String?
    public let coachLink: SleepCoachLink?
    public let suggestedAlarm: SleepSuggestedAlarm?

    public init(day: DayIdentity, state: MetricState, mainSleep: SleepSessionSummary?, naps: [SleepSessionSummary] = [], metrics: [SleepMetricValue], hypnogram: [SleepSegment] = [], trend: [SleepTrendPoint] = [], needHours: Double? = nil, debtHours: Double? = nil, source: String, algorithmVersion: String? = nil, coachLink: SleepCoachLink? = nil, suggestedAlarm: SleepSuggestedAlarm? = nil) {
        self.day = day
        self.state = state
        self.mainSleep = mainSleep
        self.naps = naps
        self.metrics = metrics
        self.hypnogram = hypnogram
        self.trend = trend
        self.needHours = needHours
        self.debtHours = debtHours
        self.source = source
        self.algorithmVersion = algorithmVersion
        self.coachLink = coachLink
        self.suggestedAlarm = suggestedAlarm
    }

    private enum CodingKeys: String, CodingKey {
        case day, state, mainSleep, naps, metrics, hypnogram, trend, needHours, debtHours, source, algorithmVersion, coachLink, suggestedAlarm
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        day = try container.decode(DayIdentity.self, forKey: .day)
        state = try container.decode(MetricState.self, forKey: .state)
        mainSleep = try container.decodeIfPresent(SleepSessionSummary.self, forKey: .mainSleep)
        naps = try container.decode([SleepSessionSummary].self, forKey: .naps)
        metrics = try container.decode([SleepMetricValue].self, forKey: .metrics)
        hypnogram = try container.decode([SleepSegment].self, forKey: .hypnogram)
        trend = try container.decode([SleepTrendPoint].self, forKey: .trend)
        needHours = try container.decodeIfPresent(Double.self, forKey: .needHours)
        debtHours = try container.decodeIfPresent(Double.self, forKey: .debtHours)
        source = try container.decode(String.self, forKey: .source)
        algorithmVersion = try container.decodeIfPresent(String.self, forKey: .algorithmVersion)
        coachLink = try container.decodeIfPresent(SleepCoachLink.self, forKey: .coachLink)
        suggestedAlarm = try container.decodeIfPresent(SleepSuggestedAlarm.self, forKey: .suggestedAlarm)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(day, forKey: .day)
        try container.encode(state, forKey: .state)
        try container.encodeIfPresent(mainSleep, forKey: .mainSleep)
        try container.encode(naps, forKey: .naps)
        try container.encode(metrics, forKey: .metrics)
        try container.encode(hypnogram, forKey: .hypnogram)
        try container.encode(trend, forKey: .trend)
        try container.encodeIfPresent(needHours, forKey: .needHours)
        try container.encodeIfPresent(debtHours, forKey: .debtHours)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(algorithmVersion, forKey: .algorithmVersion)
        try container.encodeIfPresent(coachLink, forKey: .coachLink)
        try container.encodeIfPresent(suggestedAlarm, forKey: .suggestedAlarm)
    }

    public func metric(_ id: String) -> SleepMetricValue? { metrics.first { $0.id == id } }

    public static func == (lhs: SleepDaySnapshot, rhs: SleepDaySnapshot) -> Bool {
        guard lhs.day == rhs.day,
              lhs.state == rhs.state,
              lhs.mainSleep == rhs.mainSleep,
              lhs.naps == rhs.naps,
              lhs.metrics == rhs.metrics,
              lhs.trend == rhs.trend,
              lhs.needHours == rhs.needHours,
              lhs.debtHours == rhs.debtHours,
              lhs.source == rhs.source,
              lhs.algorithmVersion == rhs.algorithmVersion,
              lhs.coachLink == rhs.coachLink,
              lhs.suggestedAlarm == rhs.suggestedAlarm,
              lhs.hypnogram.count == rhs.hypnogram.count else { return false }
        return zip(lhs.hypnogram, rhs.hypnogram).allSatisfy { left, right in
            left.id == right.id && left.stage.rawValue == right.stage.rawValue && left.durationMinutes == right.durationMinutes
        }
    }
}

public struct SleepCoachLink: Codable, Equatable, Sendable {
    public let title: String
    public let detail: String
    public let routeID: String
    public let state: MetricState

    public init(title: String, detail: String, routeID: String = "coach", state: MetricState) {
        self.title = title
        self.detail = detail
        self.routeID = routeID
        self.state = state
    }
}

public protocol SleepRepository: Sendable {
    func readSleepDay(for day: DayIdentity) async throws -> SleepDaySnapshot?
}

/// Corrections are append-only provenance records.  Consumers can display the
/// latest value while the audit trail retains before/after values and source.
public struct SleepCorrection: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let day: DayIdentity
    public let target: String
    public let before: String?
    public let after: String?
    public let reason: String
    public let source: String
    public let algorithmVersion: String?
    public let createdAt: Date

    public init(id: UUID = UUID(), day: DayIdentity, target: String, before: String?, after: String?, reason: String, source: String = "user", algorithmVersion: String?, createdAt: Date) {
        self.id = id
        self.day = day
        self.target = target
        self.before = before
        self.after = after
        self.reason = reason
        self.source = source
        self.algorithmVersion = algorithmVersion
        self.createdAt = createdAt
    }
}

public protocol SleepCorrectionRepository: Sendable {
    func append(_ correction: SleepCorrection) async throws
    func history(for day: DayIdentity) async throws -> [SleepCorrection]
    func deleteAll() async throws
}

public actor InMemorySleepRepository: SleepRepository {
    private var values: [DayIdentity: SleepDaySnapshot]
    public init(values: [DayIdentity: SleepDaySnapshot] = [:]) { self.values = values }
    public func readSleepDay(for day: DayIdentity) async throws -> SleepDaySnapshot? { values[day] }
    public func replace(_ snapshot: SleepDaySnapshot, for day: DayIdentity) { values[day] = snapshot }
    public func deleteAll() { values.removeAll(keepingCapacity: true) }
}

public actor InMemorySleepCorrectionRepository: SleepCorrectionRepository {
    private var values: [DayIdentity: [SleepCorrection]] = [:]
    /// `seed` starts the audit trail with existing corrections (fixtures).
    public init(seed: [SleepCorrection] = []) {
        for correction in seed { values[correction.day, default: []].append(correction) }
    }
    public func append(_ correction: SleepCorrection) async throws { values[correction.day, default: []].append(correction) }
    public func history(for day: DayIdentity) async throws -> [SleepCorrection] { values[day] ?? [] }
    public func deleteAll() async throws { values.removeAll(keepingCapacity: true) }
}
