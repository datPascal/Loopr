import Foundation
import DomainKit

public struct HabitID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) { self.rawValue = rawValue }

    public static func < (lhs: HabitID, rhs: HabitID) -> Bool {
        lhs.rawValue.uuidString < rhs.rawValue.uuidString
    }
}

public enum HabitResponseKind: String, Codable, CaseIterable, Sendable {
    case binary
    case quantity
    case time
}

public enum HabitDefinitionSource: Codable, Equatable, Sendable {
    case preset(catalogID: String)
    case custom

    private enum CodingKeys: String, CodingKey { case kind, catalogID }
    private enum Kind: String, Codable { case preset, custom }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .preset: self = .preset(catalogID: try container.decode(String.self, forKey: .catalogID))
        case .custom: self = .custom
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .preset(let catalogID):
            try container.encode(Kind.preset, forKey: .kind)
            try container.encode(catalogID, forKey: .catalogID)
        case .custom:
            try container.encode(Kind.custom, forKey: .kind)
        }
    }
}

public struct HabitDefinition: Codable, Equatable, Identifiable, Sendable {
    public let id: HabitID
    public let source: HabitDefinitionSource
    public var name: String
    public var question: String
    public let responseKind: HabitResponseKind
    public var sortOrder: Int
    public var archivedAt: Date?
    public let createdAt: Date
    public var updatedAt: Date
    public let schemaVersion: Int

    public init(
        id: HabitID,
        source: HabitDefinitionSource,
        name: String,
        question: String,
        responseKind: HabitResponseKind = .binary,
        sortOrder: Int,
        archivedAt: Date? = nil,
        createdAt: Date,
        updatedAt: Date? = nil,
        schemaVersion: Int = 1
    ) {
        self.id = id
        self.source = source
        self.name = name
        self.question = question
        self.responseKind = responseKind
        self.sortOrder = sortOrder
        self.archivedAt = archivedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.schemaVersion = schemaVersion
    }

    public var isArchived: Bool { archivedAt != nil }
}

public enum HabitAnswer: String, Codable, CaseIterable, Sendable {
    case yes
    case no
    case skipped
}

public enum HabitResponseSource: String, Codable, Sendable {
    case sameDay
    case morningCheckIn
    case historyEdit
    case legacyPresence
}

public struct HabitResponse: Codable, Equatable, Sendable {
    public let habitID: HabitID
    public let behaviorDay: DayIdentity
    public let behaviorTimeZoneID: String
    public var answer: HabitAnswer
    public let firstAnsweredAt: Date
    public var updatedAt: Date
    public let firstAnswerSource: HabitResponseSource
    public var lastUpdateSource: HabitResponseSource

    public init(
        habitID: HabitID,
        behaviorDay: DayIdentity,
        behaviorTimeZoneID: String,
        answer: HabitAnswer,
        firstAnsweredAt: Date,
        updatedAt: Date? = nil,
        firstAnswerSource: HabitResponseSource,
        lastUpdateSource: HabitResponseSource? = nil
    ) {
        self.habitID = habitID
        self.behaviorDay = behaviorDay
        self.behaviorTimeZoneID = behaviorTimeZoneID
        self.answer = answer
        self.firstAnsweredAt = firstAnsweredAt
        self.updatedAt = updatedAt ?? firstAnsweredAt
        self.firstAnswerSource = firstAnswerSource
        self.lastUpdateSource = lastUpdateSource ?? firstAnswerSource
    }
}

public struct HabitDayRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String { behaviorDay.habitKey }
    public let behaviorDay: DayIdentity
    public let behaviorTimeZoneID: String
    public var responses: [HabitResponse]
    public var completedAt: Date?
    public let createdAt: Date
    public var updatedAt: Date
    public let schemaVersion: Int

    public init(
        behaviorDay: DayIdentity,
        behaviorTimeZoneID: String,
        responses: [HabitResponse] = [],
        completedAt: Date? = nil,
        createdAt: Date,
        updatedAt: Date? = nil,
        schemaVersion: Int = 1
    ) {
        self.behaviorDay = behaviorDay
        self.behaviorTimeZoneID = behaviorTimeZoneID
        self.responses = responses
        self.completedAt = completedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.schemaVersion = schemaVersion
    }

    public func response(for habitID: HabitID) -> HabitResponse? {
        responses.first { $0.habitID == habitID }
    }
}

public enum HabitOutcomeMetricID: String, Codable, CaseIterable, Hashable, Sendable {
    case recoveryScore
    case sleepScore
    case hrvRMSSD
    case restingHeartRate
    case sleepDuration
    case sleepEfficiency
    case sleepConsistency

    public var title: String {
        switch self {
        case .recoveryScore: "Recovery"
        case .sleepScore: "Sleep score"
        case .hrvRMSSD: "HRV"
        case .restingHeartRate: "Resting heart rate"
        case .sleepDuration: "Sleep duration"
        case .sleepEfficiency: "Sleep efficiency"
        case .sleepConsistency: "Sleep consistency"
        }
    }

    public var unit: HabitMetricUnitID {
        switch self {
        case .recoveryScore, .sleepScore, .sleepConsistency: .scorePoints
        case .hrvRMSSD: .milliseconds
        case .restingHeartRate: .beatsPerMinute
        case .sleepDuration: .minutes
        case .sleepEfficiency: .percentagePoints
        }
    }
}

public enum HabitMetricUnitID: String, Codable, Sendable {
    case scorePoints
    case milliseconds
    case beatsPerMinute
    case minutes
    case percentagePoints
}

public struct HabitOutcomeSnapshot: Codable, Equatable, Sendable {
    public let behaviorDay: DayIdentity
    public let behaviorTimeZoneID: String
    public let sleepSessionID: String
    public let sleepStartedAt: Date
    public let sleepEndedAt: Date
    public let outcomeDay: DayIdentity
    public let metrics: [HabitOutcomeMetricID: Double]
    public let priorDayStrain: Double?
    public let sourceVersions: [String: String]
    public let builtAt: Date

    public init(
        behaviorDay: DayIdentity,
        behaviorTimeZoneID: String,
        sleepSessionID: String,
        sleepStartedAt: Date,
        sleepEndedAt: Date,
        outcomeDay: DayIdentity,
        metrics: [HabitOutcomeMetricID: Double],
        priorDayStrain: Double?,
        sourceVersions: [String: String],
        builtAt: Date
    ) {
        self.behaviorDay = behaviorDay
        self.behaviorTimeZoneID = behaviorTimeZoneID
        self.sleepSessionID = sleepSessionID
        self.sleepStartedAt = sleepStartedAt
        self.sleepEndedAt = sleepEndedAt
        self.outcomeDay = outcomeDay
        self.metrics = metrics.filter { $0.value.isFinite }
        self.priorDayStrain = priorDayStrain?.isFinite == true ? priorDayStrain : nil
        self.sourceVersions = sourceVersions
        self.builtAt = builtAt
    }
}

public struct HabitOutcomeExclusionRecord: Codable, Equatable, Sendable {
    public let behaviorDay: DayIdentity
    public let reason: HabitExclusionReason
    public let resolvedAt: Date

    public init(behaviorDay: DayIdentity, reason: HabitExclusionReason, resolvedAt: Date) {
        self.behaviorDay = behaviorDay
        self.reason = reason
        self.resolvedAt = resolvedAt
    }
}

public enum HabitExclusionReason: String, Codable, CaseIterable, Sendable {
    case skipped
    case unanswered
    case lateFirstEntry
    case legacyPresence
    case missingMainSleep
    case ambiguousMainSleep
    case partialSleep
    case missingMetric
    case invalidMetric
    case incompatibleMetricVersion
    case unresolvedTimeZone
    case insufficientBaseline
}

public struct HabitExclusion: Codable, Equatable, Sendable, Identifiable {
    public var id: String { "\(day.habitKey).\(reason.rawValue)" }
    public let day: DayIdentity
    public let reason: HabitExclusionReason

    public init(day: DayIdentity, reason: HabitExclusionReason) {
        self.day = day
        self.reason = reason
    }
}

public enum HabitInsightStatus: String, Codable, CaseIterable, Sendable {
    case collecting
    case earlySignal
    case enoughData
    case clearAssociation
    case noClearAssociation
    case cannotSeparate
    case stale
    case unavailable
}

public struct HabitMetricEstimate: Codable, Equatable, Sendable {
    public let metricID: HabitOutcomeMetricID
    public let yesMean: Double?
    public let noMean: Double?
    public let rawDifference: Double?
    public let adjustedDifference: Double?
    public let intervalLower: Double?
    public let intervalUpper: Double?
    public let bootstrapPValue: Double?
    public let adjustedPValue: Double?
    public let adjustedRowCount: Int
    public let isClear: Bool

    public init(
        metricID: HabitOutcomeMetricID,
        yesMean: Double?,
        noMean: Double?,
        rawDifference: Double?,
        adjustedDifference: Double?,
        intervalLower: Double?,
        intervalUpper: Double?,
        bootstrapPValue: Double? = nil,
        adjustedPValue: Double? = nil,
        adjustedRowCount: Int = 0,
        isClear: Bool = false
    ) {
        self.metricID = metricID
        self.yesMean = yesMean
        self.noMean = noMean
        self.rawDifference = rawDifference
        self.adjustedDifference = adjustedDifference
        self.intervalLower = intervalLower
        self.intervalUpper = intervalUpper
        self.bootstrapPValue = bootstrapPValue
        self.adjustedPValue = adjustedPValue
        self.adjustedRowCount = adjustedRowCount
        self.isClear = isClear
    }
}

public struct HabitLastValidEstimate: Codable, Equatable, Sendable {
    public let validThrough: DayIdentity
    public let recovery: HabitMetricEstimate

    public init(validThrough: DayIdentity, recovery: HabitMetricEstimate) {
        self.validThrough = validThrough
        self.recovery = recovery
    }
}

public struct HabitImpactEstimate: Codable, Equatable, Identifiable, Sendable {
    public var id: HabitID { habitID }
    public let habitID: HabitID
    public let status: HabitInsightStatus
    public let yesCount: Int
    public let noCount: Int
    public let eligibleDayCount: Int
    public let excludedDayCount: Int
    public let metrics: [HabitMetricEstimate]
    public let exclusions: [HabitExclusion]
    public let overlappingHabitID: HabitID?
    public let windowStart: DayIdentity
    public let windowEnd: DayIdentity
    public let calculatedAt: Date
    public let algorithmVersion: String
    public let lastValidEstimate: HabitLastValidEstimate?

    public init(
        habitID: HabitID,
        status: HabitInsightStatus,
        yesCount: Int,
        noCount: Int,
        eligibleDayCount: Int,
        excludedDayCount: Int,
        metrics: [HabitMetricEstimate] = [],
        exclusions: [HabitExclusion] = [],
        overlappingHabitID: HabitID? = nil,
        windowStart: DayIdentity,
        windowEnd: DayIdentity,
        calculatedAt: Date,
        algorithmVersion: String = HabitImpactPolicy.default.algorithmVersion,
        lastValidEstimate: HabitLastValidEstimate? = nil
    ) {
        self.habitID = habitID
        self.status = status
        self.yesCount = yesCount
        self.noCount = noCount
        self.eligibleDayCount = eligibleDayCount
        self.excludedDayCount = excludedDayCount
        self.metrics = metrics
        self.exclusions = exclusions
        self.overlappingHabitID = overlappingHabitID
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.calculatedAt = calculatedAt
        self.algorithmVersion = algorithmVersion
        self.lastValidEstimate = lastValidEstimate
    }

    public func metric(_ id: HabitOutcomeMetricID) -> HabitMetricEstimate? {
        metrics.first { $0.metricID == id }
    }
}

public struct HabitImpactPolicy: Codable, Equatable, Sendable {
    public let algorithmVersion: String
    public let windowDays: Int
    public let earlyPerGroup: Int
    public let maturePerGroup: Int
    public let matureEligibleDays: Int
    public let minimumAdjustedRows: Int
    public let trailingBaselineDays: Int
    public let minimumBaselineDays: Int
    public let ridgeLambda: Double
    public let bootstrapReplicates: Int
    public let bootstrapBlockDays: Int
    public let overlapPhiThreshold: Double
    public let minimumDiscordantDays: Int
    public let practicalThresholds: [HabitOutcomeMetricID: Double]

    public static let `default` = HabitImpactPolicy(
        algorithmVersion: "journal.habit-impact.v1",
        windowDays: 90,
        earlyPerGroup: 5,
        maturePerGroup: 10,
        matureEligibleDays: 30,
        minimumAdjustedRows: 24,
        trailingBaselineDays: 28,
        minimumBaselineDays: 7,
        ridgeLambda: 1,
        bootstrapReplicates: 2_000,
        bootstrapBlockDays: 7,
        overlapPhiThreshold: 0.9,
        minimumDiscordantDays: 3,
        practicalThresholds: [
            .recoveryScore: 3,
            .sleepScore: 3,
            .hrvRMSSD: 5,
            .restingHeartRate: 1,
            .sleepDuration: 15,
            .sleepEfficiency: 2,
            .sleepConsistency: 3
        ]
    )

    public init(
        algorithmVersion: String,
        windowDays: Int,
        earlyPerGroup: Int,
        maturePerGroup: Int,
        matureEligibleDays: Int,
        minimumAdjustedRows: Int,
        trailingBaselineDays: Int,
        minimumBaselineDays: Int,
        ridgeLambda: Double,
        bootstrapReplicates: Int,
        bootstrapBlockDays: Int,
        overlapPhiThreshold: Double,
        minimumDiscordantDays: Int,
        practicalThresholds: [HabitOutcomeMetricID: Double]
    ) {
        self.algorithmVersion = algorithmVersion
        self.windowDays = windowDays
        self.earlyPerGroup = earlyPerGroup
        self.maturePerGroup = maturePerGroup
        self.matureEligibleDays = matureEligibleDays
        self.minimumAdjustedRows = minimumAdjustedRows
        self.trailingBaselineDays = trailingBaselineDays
        self.minimumBaselineDays = minimumBaselineDays
        self.ridgeLambda = ridgeLambda
        self.bootstrapReplicates = bootstrapReplicates
        self.bootstrapBlockDays = bootstrapBlockDays
        self.overlapPhiThreshold = overlapPhiThreshold
        self.minimumDiscordantDays = minimumDiscordantDays
        self.practicalThresholds = practicalThresholds
    }
}

public struct HabitSettings: Codable, Equatable, Sendable {
    public var reminderEnabled: Bool
    public var reminderHour: Int
    public var reminderMinute: Int
    public var featureStage: HabitFeatureStage
    public let schemaVersion: Int

    public init(
        reminderEnabled: Bool = false,
        reminderHour: Int = 9,
        reminderMinute: Int = 0,
        featureStage: HabitFeatureStage = .internalOnly,
        schemaVersion: Int = 1
    ) {
        self.reminderEnabled = reminderEnabled
        self.reminderHour = reminderHour
        self.reminderMinute = reminderMinute
        self.featureStage = featureStage
        self.schemaVersion = schemaVersion
    }
}

public struct HabitTodaySelection: Codable, Equatable, Sendable {
    public let habitID: HabitID
    public let selectedAt: Date
    public let schemaVersion: Int

    public init(habitID: HabitID, selectedAt: Date, schemaVersion: Int = 1) {
        self.habitID = habitID
        self.selectedAt = selectedAt
        self.schemaVersion = schemaVersion
    }
}

public protocol HabitReminderScheduling: Sendable {
    func update(settings: HabitSettings, activeHabitCount: Int, behaviorDay: DayIdentity) async throws
    func cancel() async throws
}

public struct NoOpHabitReminderScheduler: HabitReminderScheduling {
    public init() {}
    public func update(settings: HabitSettings, activeHabitCount: Int, behaviorDay: DayIdentity) async throws {}
    public func cancel() async throws {}
}

public enum HabitFeatureStage: String, Codable, CaseIterable, Sendable {
    case disabled
    case internalOnly
    case beta
    case `public`

    public var exposesEntryPoints: Bool {
        switch self {
        case .disabled: false
        case .internalOnly:
            #if DEBUG
            true
            #else
            false
            #endif
        case .beta, .public: true
        }
    }
    public var enablesToday: Bool { self == .beta || self == .public }
}

public struct HabitMigrationReceipt: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let completedAt: Date
    public let approvedMappings: [String: HabitID]

    public init(schemaVersion: Int = 1, completedAt: Date, approvedMappings: [String: HabitID]) {
        self.schemaVersion = schemaVersion
        self.completedAt = completedAt
        self.approvedMappings = approvedMappings
    }
}

public enum HabitStoreError: Error, Equatable, LocalizedError, Sendable {
    case invalidDefinition
    case unsupportedResponseKind
    case activeLimitReached
    case duplicateHabitID
    case duplicatePreset
    case missingHabit
    case duplicateResponse
    case responseDayMismatch
    case timeZoneMismatch
    case invalidDay
    case invalidRestore

    public var errorDescription: String? {
        switch self {
        case .invalidDefinition: "Enter a name and a question for this habit."
        case .unsupportedResponseKind: "Loopr currently supports Yes or No habits only."
        case .activeLimitReached: "You can track up to 10 active habits. Archive one before adding another."
        case .duplicateHabitID: "That habit already exists."
        case .duplicatePreset: "That preset is already in your habits."
        case .missingHabit: "This habit is no longer available."
        case .duplicateResponse: "A habit can have one answer per day."
        case .responseDayMismatch: "The answer does not match the selected day."
        case .timeZoneMismatch: "All answers for a day must use the same time zone."
        case .invalidDay: "The selected day is invalid."
        case .invalidRestore: "The journal archive could not be restored."
        }
    }
}

public extension DayIdentity {
    var habitKey: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    init?(habitKey: String) {
        let values = habitKey.split(separator: "-").compactMap { Int($0) }
        guard values.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: values[0], month: values[1], day: values[2])
        guard let date = calendar.date(from: components) else { return nil }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        guard roundTrip.year == values[0], roundTrip.month == values[1], roundTrip.day == values[2] else { return nil }
        self.init(year: values[0], month: values[1], day: values[2])
    }
}
