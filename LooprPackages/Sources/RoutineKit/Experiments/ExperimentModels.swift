import DomainKit
import Foundation

// An experiment tests one rule of a protocol against the person's own nights. The start record is written once, on
// day 1, and never changes: the design, the washout, the minimum nights and above all the outcome metric with its
// direction of benefit. Only the status and the end day move afterwards, and only forward.

public struct ExperimentID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { rawValue = UUID() }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(UUID.self) }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// How the on and off nights are laid out. Every design starts with its first on night or, for before and after, with
/// the baseline period. The person decides it before night 1.
public enum ExperimentDesign: Equatable, Hashable, Codable, Sendable {
    /// On, off, on, off, one night each.
    case alternatingDays
    /// Blocks of `length` nights, on first: 7 on, 7 off, 7 on, ...
    case blocks(length: Int)
    /// `baselineNights` off nights first, then on nights until the planned nights run out.
    case beforeAndAfter(baselineNights: Int)

    public var kind: String {
        switch self {
        case .alternatingDays: "alternating"
        case .blocks: "blocks"
        case .beforeAndAfter: "beforeAfter"
        }
    }

    /// The block length or baseline length. Nil for alternating days.
    public var length: Int? {
        switch self {
        case .alternatingDays: nil
        case .blocks(let length): length
        case .beforeAndAfter(let baselineNights): baselineNights
        }
    }

    public init?(kind: String, length: Int?) {
        switch (kind, length) {
        case ("alternating", nil): self = .alternatingDays
        case ("blocks", let length?): self = .blocks(length: length)
        case ("beforeAfter", let length?): self = .beforeAndAfter(baselineNights: length)
        default: return nil
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, length }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        guard let design = Self(kind: kind, length: try container.decodeIfPresent(Int.self, forKey: .length)) else {
            throw ExperimentError.corruptRecord
        }
        self = design
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(length, forKey: .length)
    }
}

public enum ExperimentArm: String, Codable, CaseIterable, Sendable {
    /// The person does the intervention.
    case on
    /// The person does not.
    case off
}

/// What a given local day is in an experiment. A washout night sits in an arm's block but is left out of the result;
/// it keeps its arm so Today still says whether to do the intervention.
public enum ExperimentNightRole: Equatable, Hashable, Sendable {
    case on
    case off
    case washout(ExperimentArm)
    case outside
}

/// Which way a better night points for the outcome. Fixed on day 1 with the metric.
public enum ExperimentBenefit: String, Codable, CaseIterable, Sendable {
    case higher
    case lower
}

/// A measured quantity an experiment can use as its outcome, or list as "also moved". The key matches the key the
/// metric series uses elsewhere in the app.
public struct ExperimentMetric: Equatable, Hashable, Codable, Sendable {
    public let key: String
    public let title: String
    /// Short unit as printed next to a number: "min", "bpm", "ms".
    public let unit: String
    public let benefit: ExperimentBenefit

    public init(key: String, title: String, unit: String, benefit: ExperimentBenefit) {
        self.key = key; self.title = title; self.unit = unit; self.benefit = benefit
    }

    public static let deepSleep = ExperimentMetric(key: "deepSleepMinutes", title: "Deep sleep", unit: "min", benefit: .higher)
    public static let sleepHeartRate = ExperimentMetric(key: "sleepHeartRate", title: "Sleep heart rate", unit: "bpm", benefit: .lower)
    public static let timeToFallAsleep = ExperimentMetric(key: "timeToFallAsleepMinutes", title: "Time to fall asleep", unit: "min", benefit: .lower)
    public static let hrv = ExperimentMetric(key: "hrvRMSSD", title: "HRV", unit: "ms", benefit: .higher)

    /// The sentence for "also moved" when the metric has a natural phrasing. `{amount}` stands for "8 min".
    var lowerPhrase: String? { key == Self.timeToFallAsleep.key ? "Fell asleep {amount} sooner" : nil }
    var higherPhrase: String? { key == Self.timeToFallAsleep.key ? "Fell asleep {amount} later" : nil }

    var isValid: Bool {
        !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public enum ExperimentStatus: String, Codable, CaseIterable, Sendable {
    case running, finished, stopped
}

/// The immutable start record. Every property is a `let`, the store has no call that rewrites a saved one, and a
/// trigger in the database refuses an UPDATE of these columns, so the outcome a person fixed on day 1 is the outcome
/// the result reports.
public struct ExperimentStart: Equatable, Codable, Identifiable, Sendable {
    public let id: ExperimentID
    public let protocolID: ProtocolID
    /// "Magnesium glycinate, 300 mg".
    public let title: String
    /// How a night reads in a sentence: "magnesium" in "Tonight is a magnesium night."
    public let interventionName: String
    /// The protocol rule that is the intervention. A kept check on a night is the adherence.
    public let ruleKey: RuleKey
    public let design: ExperimentDesign
    /// Nights left out after each switch between arms, 0 or more.
    public let washout: Int
    /// Included nights each arm needs before a result can show.
    public let minimumNightsPerArm: Int
    public let plannedNights: Int
    public let outcome: ExperimentMetric
    /// Night 1 starts on this local day.
    public let startDay: DayIdentity
    public let timeZoneIdentifier: String
    public let createdAt: Date

    public init(id: ExperimentID = ExperimentID(), protocolID: ProtocolID, title: String, interventionName: String,
                ruleKey: RuleKey, design: ExperimentDesign, washout: Int, minimumNightsPerArm: Int,
                plannedNights: Int, outcome: ExperimentMetric, startDay: DayIdentity,
                timeZoneIdentifier: String, createdAt: Date) throws {
        self.id = id; self.protocolID = protocolID; self.title = title; self.interventionName = interventionName
        self.ruleKey = ruleKey; self.design = design; self.washout = washout
        self.minimumNightsPerArm = minimumNightsPerArm; self.plannedNights = plannedNights
        self.outcome = outcome; self.startDay = startDay; self.timeZoneIdentifier = timeZoneIdentifier
        self.createdAt = createdAt
        try validate()
    }

    private enum CodingKeys: String, CodingKey {
        case id, protocolID, title, interventionName, ruleKey, design, washout, minimumNightsPerArm
        case plannedNights, outcome, startDay, timeZoneIdentifier, createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(ExperimentID.self, forKey: .id)
        protocolID = try c.decode(ProtocolID.self, forKey: .protocolID)
        title = try c.decode(String.self, forKey: .title)
        interventionName = try c.decode(String.self, forKey: .interventionName)
        ruleKey = try c.decode(RuleKey.self, forKey: .ruleKey)
        design = try c.decode(ExperimentDesign.self, forKey: .design)
        washout = try c.decode(Int.self, forKey: .washout)
        minimumNightsPerArm = try c.decode(Int.self, forKey: .minimumNightsPerArm)
        plannedNights = try c.decode(Int.self, forKey: .plannedNights)
        outcome = try c.decode(ExperimentMetric.self, forKey: .outcome)
        startDay = try c.decode(DayIdentity.self, forKey: .startDay)
        timeZoneIdentifier = try c.decode(String.self, forKey: .timeZoneIdentifier)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        try validate()
    }

    /// The fewest included nights an arm must be able to reach for the plan to make sense at all.
    public static let smallestMinimumNightsPerArm = 2

    private func validate() throws {
        func blank(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !blank(title) else { throw ExperimentError.missingTitle }
        guard !blank(interventionName) else { throw ExperimentError.missingInterventionName }
        guard ruleKey.isValid else { throw ExperimentError.invalidRuleKey }
        guard outcome.isValid else { throw ExperimentError.invalidOutcome }
        guard startDay.routineDayKey != nil else { throw ExperimentError.invalidDay }
        guard !blank(timeZoneIdentifier) else { throw ExperimentError.invalidTimeZone }
        guard minimumNightsPerArm >= Self.smallestMinimumNightsPerArm else { throw ExperimentError.minimumNightsTooLow }
        try ExperimentSchedule.validate(design: design, washout: washout, plannedNights: plannedNights,
                                        minimumNightsPerArm: minimumNightsPerArm)
    }

    public var schedule: ExperimentSchedule {
        ExperimentSchedule(design: design, washout: washout, plannedNights: plannedNights, startDay: startDay)
    }

    /// The last planned night's day.
    public var lastPlannedDay: DayIdentity { startDay.adding(days: plannedNights - 1) ?? startDay }
}

/// A start record plus the two things that move: the status and the day the experiment ended.
public struct Experiment: Equatable, Identifiable, Sendable {
    public let start: ExperimentStart
    public let status: ExperimentStatus
    /// The last night that counts. Nil while running. A finished experiment ends on its last planned night; a stopped
    /// one on the last night before the person stopped.
    public let endDay: DayIdentity?

    public var id: ExperimentID { start.id }

    public init(start: ExperimentStart, status: ExperimentStatus = .running, endDay: DayIdentity? = nil) {
        self.start = start; self.status = status; self.endDay = endDay
    }

    /// The schedule with the end day applied, so nights after a stop are outside the experiment.
    public var schedule: ExperimentSchedule {
        ExperimentSchedule(design: start.design, washout: start.washout, plannedNights: start.plannedNights,
                           startDay: start.startDay, endDay: endDay)
    }

    /// True when the person stopped before the planned nights ran out.
    public var stoppedEarly: Bool {
        guard status == .stopped, let endDay else { return false }
        return endDay.days(until: start.lastPlannedDay).map { $0 > 0 } ?? false
    }
}

/// Whether the person did the intervention on a night, from a RoutineKit check on the intervention rule.
public enum ExperimentAdherence: String, Codable, CaseIterable, Sendable {
    /// The rule was kept: the person did the intervention.
    case kept
    /// The rule was missed.
    case missed
    /// No check, a pending check, a skipped check, or a source that could not say.
    case unknown

    /// Reads a protocol check. A night with no check is `unknown`, never `missed`.
    public static func from(_ check: RuleCheck?) -> ExperimentAdherence {
        switch check?.state {
        case .kept: .kept
        case .missed: .missed
        case .pending, .unknown, .skipped, nil: .unknown
        }
    }
}

/// One night of an experiment as stored. `outcomeValue` is nil when the night has no measurement; it is never zero in
/// that case. `otherValues` holds the other metrics of that night, by key, for "also moved".
public struct ExperimentNight: Equatable, Codable, Sendable {
    public let experimentID: ExperimentID
    public let day: DayIdentity
    public let arm: ExperimentArm
    public let isWashout: Bool
    public let adherence: ExperimentAdherence
    public let outcomeValue: Double?
    public let otherValues: [String: Double]
    public let recordedAt: Date

    public init(experimentID: ExperimentID, day: DayIdentity, arm: ExperimentArm, isWashout: Bool,
                adherence: ExperimentAdherence, outcomeValue: Double?, otherValues: [String: Double] = [:],
                recordedAt: Date) throws {
        self.experimentID = experimentID; self.day = day; self.arm = arm; self.isWashout = isWashout
        self.adherence = adherence; self.outcomeValue = outcomeValue; self.otherValues = otherValues
        self.recordedAt = recordedAt
        guard day.routineDayKey != nil else { throw ExperimentError.invalidDay }
        if let outcomeValue, !outcomeValue.isFinite { throw ExperimentError.invalidNight }
        if otherValues.contains(where: { !$0.value.isFinite }) { throw ExperimentError.invalidNight }
    }
}

public enum ExperimentError: Error, Equatable, LocalizedError, Sendable {
    case missingTitle
    case missingInterventionName
    case invalidRuleKey
    case invalidOutcome
    case invalidDay
    case invalidTimeZone
    case minimumNightsTooLow
    case plannedNightsTooLow
    case invalidDesign
    case invalidWashout
    case planCannotReachMinimum(ExperimentArm)
    case missingProtocol
    case missingExperiment
    case duplicateExperiment
    case anotherExperimentRunning
    case notRunning
    case outsideExperiment
    case plannedNightsNotOver
    case invalidNight
    case corruptRecord

    public var errorDescription: String? {
        switch self {
        case .missingTitle: "Give the experiment a title."
        case .missingInterventionName: "Name the intervention, for example magnesium."
        case .invalidRuleKey: "Pick the protocol rule this experiment tests."
        case .invalidOutcome: "Pick the outcome before night 1."
        case .invalidDay: "That day does not exist."
        case .invalidTimeZone: "The experiment needs a time zone."
        case .minimumNightsTooLow: "Each side needs at least 2 nights."
        case .plannedNightsTooLow: "An experiment needs at least 2 nights."
        case .invalidDesign: "A block or baseline needs at least 1 night."
        case .invalidWashout: "The washout has to leave at least one night in each block."
        case .planCannotReachMinimum(let arm):
            "These dates leave too few \(arm == .on ? "on" : "off") nights to reach the minimum."
        case .missingProtocol: "This protocol is no longer available."
        case .missingExperiment: "This experiment is no longer available."
        case .duplicateExperiment: "This experiment already started. Its design and outcome stay as they were."
        case .anotherExperimentRunning: "Another experiment is still running. Finish or stop it first."
        case .notRunning: "This experiment is not running."
        case .outsideExperiment: "That night is outside the experiment."
        case .plannedNightsNotOver: "The planned nights are not over yet."
        case .invalidNight: "That night has a value Loopr cannot use."
        case .corruptRecord: "A stored experiment record could not be read."
        }
    }
}
