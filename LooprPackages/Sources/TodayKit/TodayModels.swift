import Foundation
import DomainKit
import DesignSystem

/// The metric identities owned by the Today surface.  Today is a projection
/// surface: it never derives these values itself.  Every value is read from a
/// canonical feature repository and keeps its state, confidence, trend, and
/// provenance alongside the display value.
public enum TodayMetricID: String, Codable, CaseIterable, Hashable, Sendable {
    case readiness
    case recovery
    case sleep
    case heart
    case strain
    case stress
    case hrv
    case restingHeartRate
    case calories
    case steps
    case wearQuality
}

public enum TodayMetricUnitID: String, Codable, Sendable {
    case scorePoints
    case milliseconds
    case beatsPerMinute
    case minutes
    case percentagePoints
    case strainScore
    case kilocalories
    case count
    case index
    case unknown
}

public struct TodayContributor: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let detail: String
    public let contribution: Double?

    public init(id: String, label: String, detail: String, contribution: Double? = nil) {
        self.id = id
        self.label = label
        self.detail = detail
        self.contribution = contribution
    }
}

public struct TodayMetricValue: Codable, Equatable, Sendable, Identifiable {
    public let id: TodayMetricID
    public let title: String
    public let value: String?
    public let unit: String
    public let numericValue: Double?
    public let numericUnit: TodayMetricUnitID?
    public let trend: String?
    public let confidence: String?
    public let state: MetricState
    public let contributors: [TodayContributor]
    public let source: String
    public let algorithmVersion: String?

    public init(
        id: TodayMetricID,
        title: String,
        value: String?,
        unit: String,
        trend: String? = nil,
        confidence: String? = nil,
        state: MetricState,
        contributors: [TodayContributor] = [],
        source: String,
        algorithmVersion: String? = nil,
        numericValue: Double? = nil,
        numericUnit: TodayMetricUnitID? = nil
    ) {
        self.id = id
        self.title = title
        self.value = value
        self.unit = unit
        self.numericValue = numericValue?.isFinite == true ? numericValue : nil
        self.numericUnit = numericUnit
        self.trend = trend
        self.confidence = confidence
        self.state = state
        self.contributors = contributors
        self.source = source
        self.algorithmVersion = algorithmVersion
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, value, unit, numericValue, numericUnit, trend, confidence, state, contributors, source, algorithmVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(TodayMetricID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        value = try container.decodeIfPresent(String.self, forKey: .value)
        unit = try container.decode(String.self, forKey: .unit)
        let decodedNumeric = try container.decodeIfPresent(Double.self, forKey: .numericValue)
        numericValue = decodedNumeric?.isFinite == true ? decodedNumeric : nil
        numericUnit = try container.decodeIfPresent(TodayMetricUnitID.self, forKey: .numericUnit)
        trend = try container.decodeIfPresent(String.self, forKey: .trend)
        confidence = try container.decodeIfPresent(String.self, forKey: .confidence)
        state = try container.decode(MetricState.self, forKey: .state)
        contributors = try container.decodeIfPresent([TodayContributor].self, forKey: .contributors) ?? []
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
        try container.encodeIfPresent(trend, forKey: .trend)
        try container.encodeIfPresent(confidence, forKey: .confidence)
        try container.encode(state, forKey: .state)
        try container.encode(contributors, forKey: .contributors)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(algorithmVersion, forKey: .algorithmVersion)
    }

    public var accessibilitySummary: String {
        if state == .absent || state == .noRecords {
            return "\(title). \(state.title). \(state.detail)"
        }
        var parts = [title]
        if let value { parts.append(value) }
        if !unit.isEmpty { parts.append(unit) }
        if let confidence { parts.append(confidence) }
        if let trend { parts.append(trend) }
        if state == .measuredZero { parts.append(state.title) }
        return parts.joined(separator: ", ")
    }
}

public struct TodayFreshness: Codable, Equatable, Sendable {
    public let state: MetricState
    public let updatedAt: Date?
    public let ageMinutes: Int?
    public let detail: String

    public init(state: MetricState, updatedAt: Date?, ageMinutes: Int?, detail: String) {
        self.state = state
        self.updatedAt = updatedAt
        self.ageMinutes = ageMinutes
        self.detail = detail
    }
}

public struct TodayExternalInsight: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let detail: String
    public let accessibilityText: String
    public let calculatedAt: Date
    public let routeToken: String

    public init(
        id: String,
        title: String,
        detail: String,
        accessibilityText: String,
        calculatedAt: Date,
        routeToken: String
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.accessibilityText = accessibilityText
        self.calculatedAt = calculatedAt
        self.routeToken = routeToken
    }
}

public enum TodayConnectionState: String, Codable, CaseIterable, Sendable {
    case connected
    case disconnected
    case bluetoothOff
    case syncing
    case unknown
}

public struct TodayDeviceSnapshot: Codable, Equatable, Sendable {
    public let name: String?
    public let model: String?
    public let generation: String?
    public let connection: TodayConnectionState
    public let status: MetricState

    public init(
        name: String? = nil,
        model: String? = nil,
        generation: String? = nil,
        connection: TodayConnectionState,
        status: MetricState
    ) {
        self.name = name
        self.model = model
        self.generation = generation
        self.connection = connection
        self.status = status
    }
}

public struct TodayGoalProgress: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let value: String?
    public let target: String?
    public let unit: String
    public let state: MetricState
    public let progressFraction: Double?

    public init(
        id: String,
        title: String,
        value: String?,
        target: String?,
        unit: String,
        state: MetricState,
        progressFraction: Double? = nil
    ) {
        self.id = id
        self.title = title
        self.value = value
        self.target = target
        self.unit = unit
        self.state = state
        self.progressFraction = progressFraction
    }
}

public struct TodayCoachPlanSummary: Codable, Equatable, Sendable {
    public let title: String
    public let detail: String
    public let recommendationCount: Int
    public let evidenceSummary: String
    public let state: MetricState

    public init(
        title: String,
        detail: String,
        recommendationCount: Int,
        evidenceSummary: String,
        state: MetricState
    ) {
        self.title = title
        self.detail = detail
        self.recommendationCount = recommendationCount
        self.evidenceSummary = evidenceSummary
        self.state = state
    }
}

public enum TodayCoachPlanSlot: Codable, Equatable, Sendable {
    case placeholder
    case plan(TodayCoachPlanSummary)

    private enum CodingKeys: String, CodingKey { case kind, plan }
    private enum Kind: String, Codable { case placeholder, plan }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .placeholder: self = .placeholder
        case .plan: self = .plan(try container.decode(TodayCoachPlanSummary.self, forKey: .plan))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .placeholder:
            try container.encode(Kind.placeholder, forKey: .kind)
        case .plan(let plan):
            try container.encode(Kind.plan, forKey: .kind)
            try container.encode(plan, forKey: .plan)
        }
    }
}

public struct TodaySummary: Codable, Equatable, Sendable {
    public let day: DayIdentity
    public let overallState: MetricState
    public let freshness: TodayFreshness
    public let device: TodayDeviceSnapshot
    public let metrics: [TodayMetricValue]
    public let goals: [TodayGoalProgress]
    public let coachPlan: TodayCoachPlanSlot
    public let notableChanges: [String]
    /// The configured sleep need in minutes. The Today view model resolves
    /// the saved goal or the eight-hour default before publishing a summary.
    public let sleepNeedMinutes: Double?
    /// The morning sentence shared with widgets, Watch and Shortcuts.
    public let headline: String?

    public init(
        day: DayIdentity,
        overallState: MetricState,
        freshness: TodayFreshness,
        device: TodayDeviceSnapshot,
        metrics: [TodayMetricValue],
        goals: [TodayGoalProgress] = [],
        coachPlan: TodayCoachPlanSlot = .placeholder,
        notableChanges: [String] = [],
        sleepNeedMinutes: Double? = nil,
        headline: String? = nil
    ) {
        self.day = day
        self.overallState = overallState
        self.freshness = freshness
        self.device = device
        self.metrics = metrics
        self.goals = goals
        self.coachPlan = coachPlan
        self.notableChanges = notableChanges
        self.sleepNeedMinutes = sleepNeedMinutes?.isFinite == true ? sleepNeedMinutes : nil
        self.headline = headline
    }

    public func withHeadline(_ headline: String?) -> TodaySummary {
        TodaySummary(day: day, overallState: overallState, freshness: freshness, device: device,
            metrics: metrics, goals: goals, coachPlan: coachPlan, notableChanges: notableChanges,
            sleepNeedMinutes: sleepNeedMinutes, headline: headline)
    }

    public func metric(_ id: TodayMetricID) -> TodayMetricValue? {
        metrics.first { $0.id == id }
    }

    /// The same summary with the Sleep derivation's need attached. The need
    /// lives on the sleep snapshot; Today only carries it for its ring.
    public func withSleepNeed(hours: Double?) -> TodaySummary {
        TodaySummary(
            day: day, overallState: overallState, freshness: freshness, device: device,
            metrics: metrics, goals: goals, coachPlan: coachPlan, notableChanges: notableChanges,
            sleepNeedMinutes: hours.map { $0 * 60 }, headline: headline
        )
    }
}

public protocol TodayRepository: Sendable {
    func readSummary(for day: DayIdentity) async throws -> TodaySummary?
}

/// APP-03B reads goal progress through this seam.  It intentionally exposes
/// only already-derived progress; Today never computes a goal from raw data.
public protocol TodayGoalsRepository: Sendable {
    func readGoals(for day: DayIdentity) async throws -> [TodayGoalProgress]
}

/// APP-03A owns the typed slot; APP-03B supplies a real plan through this
/// protocol.  Keeping the seam here avoids a TodayKit ↔ CoachKit cycle.
public protocol TodayCoachPlanRepository: Sendable {
    func readPlan(for day: DayIdentity) async throws -> TodayCoachPlanSummary?
}

public actor InMemoryTodayRepository: TodayRepository {
    private var values: [DayIdentity: TodaySummary]

    public init(values: [DayIdentity: TodaySummary] = [:]) { self.values = values }

    public func readSummary(for day: DayIdentity) async throws -> TodaySummary? { values[day] }
    public func replace(_ summary: TodaySummary, for day: DayIdentity) { values[day] = summary }
    public func removeAll() { values.removeAll(keepingCapacity: true) }
}

public actor InMemoryTodayGoalsRepository: TodayGoalsRepository {
    private var values: [DayIdentity: [TodayGoalProgress]]

    public init(values: [DayIdentity: [TodayGoalProgress]] = [:]) { self.values = values }
    public func readGoals(for day: DayIdentity) async throws -> [TodayGoalProgress] { values[day] ?? [] }
    public func replace(_ goals: [TodayGoalProgress], for day: DayIdentity) { values[day] = goals }
}

public actor InMemoryTodayCoachPlanRepository: TodayCoachPlanRepository {
    private var values: [DayIdentity: TodayCoachPlanSummary]

    public init(values: [DayIdentity: TodayCoachPlanSummary] = [:]) { self.values = values }
    public func readPlan(for day: DayIdentity) async throws -> TodayCoachPlanSummary? { values[day] }
    public func replace(_ plan: TodayCoachPlanSummary, for day: DayIdentity) { values[day] = plan }
}

/// Shared copy also identifies the optional canonical insight in Today.
public enum TodayDayInsight {
    public static let sustainedStressHint = "Stress stayed above your usual range for two hours."
}
