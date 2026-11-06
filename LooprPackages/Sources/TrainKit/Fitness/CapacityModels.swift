import Foundation

// DEC-12.14: capacity tests. Grip is typed in from a dynamometer, dead hang and one-leg balance are timed by the
// phone, sit to stand is self-scored, and heart rate recovery is read from completed workouts.

public enum CapacityTestKind: String, CaseIterable, Codable, Sendable {
    case grip
    case deadHang = "dead_hang"
    case sitToStand = "sit_to_stand"
    case oneLegBalance = "one_leg_balance"
    case heartRateRecovery = "heart_rate_recovery"

    public var title: String {
        switch self {
        case .grip: "Grip"
        case .deadHang: "Dead hang"
        case .sitToStand: "Sit to stand"
        case .oneLegBalance: "One-leg balance"
        case .heartRateRecovery: "Heart rate recovery"
        }
    }

    /// `kg`, `s`, `points` (shown as "10/10") or `bpm`.
    public var unit: String {
        switch self {
        case .grip: "kg"
        case .deadHang, .oneLegBalance: "s"
        case .sitToStand: "points"
        case .heartRateRecovery: "bpm"
        }
    }

    /// What a protocol rule in the Tests group names to schedule this test, such as `capacity_grip`.
    public var ruleMetric: String { "capacity_\(rawValue)" }

    /// Grip is recorded per hand: the person types the best of their trials for one hand, and each hand is its own
    /// result. Balance is recorded per leg. The other tests have no side.
    public var requiresSide: Bool { self == .grip || self == .oneLegBalance }

    /// The only source each test accepts.
    public var source: CapacitySource {
        switch self {
        case .grip, .sitToStand: .typed
        case .deadHang, .oneLegBalance: .timed
        case .heartRateRecovery: .workout
        }
    }

    /// Whether the person schedules a retest. Heart rate recovery comes from workouts, not from a test session.
    public var isRetestable: Bool { self != .heartRateRecovery }

    /// The values the model accepts. Dead hang and balance are bounded by what a person can hold; grip by the
    /// strongest dynamometer readings; sit to stand by the 0 to 10 score.
    public var validRange: ClosedRange<Double> {
        switch self {
        case .grip: 0.1...150
        case .deadHang: 0.1...3_600
        case .sitToStand: 0...10
        case .oneLegBalance: 0.1...600
        case .heartRateRecovery: 0...220
        }
    }

    /// Sit to stand moves in half points: one point off for each support, half a point for unsteadiness
    /// (Araujo's sitting-rising test, as used by Brito et al. 2014).
    public var step: Double? { self == .sitToStand ? 0.5 : nil }

    public func validate(value: Double) throws {
        guard value.isFinite else { throw CapacityError.valueNotFinite }
        guard validRange.contains(value) else { throw CapacityError.valueOutOfRange(self) }
        if let step, (value / step).rounded() * step != value { throw CapacityError.notInSteps(self) }
    }
}

public enum CapacitySide: String, CaseIterable, Codable, Sendable {
    case left, right
}

public enum CapacitySource: String, CaseIterable, Codable, Sendable {
    case typed, timed, workout
}

public enum CapacityError: Error, Equatable, LocalizedError, Sendable {
    case valueNotFinite
    case valueOutOfRange(CapacityTestKind)
    case notInSteps(CapacityTestKind)
    case sideRequired(CapacityTestKind)
    case sideNotAllowed(CapacityTestKind)
    case wrongSource(CapacityTestKind)
    case workoutRequired
    case workoutNotAllowed
    case unknownTimeZone
    case invalidDate
    case missingResult
    /// A stored row could not be read back. The message names the column.
    case corruptRow(String)

    public var errorDescription: String? {
        switch self {
        case .valueNotFinite: "Enter a number."
        case .valueOutOfRange(let kind): "That \(kind.title.lowercased()) value is outside what Loopr can store."
        case .notInSteps: "Sit to stand scores move in half points, from 0 to 10."
        case .sideRequired(let kind): "Pick left or right for \(kind.title.lowercased())."
        case .sideNotAllowed(let kind): "\(kind.title) has no side."
        case .wrongSource(let kind): "\(kind.title) does not save this way."
        case .workoutRequired: "A heart rate recovery result needs its workout."
        case .workoutNotAllowed: "Only heart rate recovery comes from a workout."
        case .unknownTimeZone: "The time zone is not known."
        case .invalidDate: "The date is not valid."
        case .missingResult: "That result is no longer saved."
        case .corruptRow(let column): "A saved capacity result could not be read (\(column))."
        }
    }
}

public struct CapacityResult: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let kind: CapacityTestKind
    public let value: Double
    public let side: CapacitySide?
    public let recordedAt: Date
    public let timeZoneIdentifier: String
    public let source: CapacitySource
    /// The workout a heart rate recovery was read from. Nil for every other result.
    public let workoutID: UUID?
    /// The calculation behind a workout result, such as `loopr.workout-hrr.1`. Nil for typed and timed results.
    public let algorithmVersion: String?
    public let createdAt: Date

    public var unit: String { kind.unit }

    public init(id: UUID = UUID(), kind: CapacityTestKind, value: Double, side: CapacitySide? = nil,
                recordedAt: Date, timeZoneIdentifier: String, source: CapacitySource? = nil,
                workoutID: UUID? = nil, algorithmVersion: String? = nil, createdAt: Date? = nil) throws {
        self.id = id; self.kind = kind; self.value = value; self.side = side; self.recordedAt = recordedAt
        self.timeZoneIdentifier = timeZoneIdentifier; self.source = source ?? kind.source
        self.workoutID = workoutID; self.algorithmVersion = algorithmVersion; self.createdAt = createdAt ?? recordedAt
        try validate()
    }

    func validate() throws {
        try kind.validate(value: value)
        if kind.requiresSide, side == nil { throw CapacityError.sideRequired(kind) }
        if !kind.requiresSide, side != nil { throw CapacityError.sideNotAllowed(kind) }
        guard source == kind.source else { throw CapacityError.wrongSource(kind) }
        if source == .workout {
            guard workoutID != nil, algorithmVersion?.isEmpty == false else { throw CapacityError.workoutRequired }
        } else if workoutID != nil || algorithmVersion != nil {
            throw CapacityError.workoutNotAllowed
        }
        guard TimeZone(identifier: timeZoneIdentifier) != nil else { throw CapacityError.unknownTimeZone }
        guard recordedAt.timeIntervalSince1970.isFinite, createdAt.timeIntervalSince1970.isFinite else {
            throw CapacityError.invalidDate
        }
    }

    /// The local day the result was recorded on, in the zone it was recorded in.
    var localDayKey: String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day], from: recordedAt)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }
}

/// The person's target for age 85 on one test, in the test's unit.
public struct CapacityGoal: Equatable, Sendable {
    public static let targetAge = 85

    public let kind: CapacityTestKind
    public let targetValue: Double
    public let setAt: Date

    public var unit: String { kind.unit }

    public init(kind: CapacityTestKind, targetValue: Double, setAt: Date) throws {
        self.kind = kind; self.targetValue = targetValue; self.setAt = setAt
        try kind.validate(value: targetValue)
        guard targetValue > 0 else { throw CapacityError.valueOutOfRange(kind) }
        guard setAt.timeIntervalSince1970.isFinite else { throw CapacityError.invalidDate }
    }
}

/// The history of one test, newest first, with the latest result and the headline value.
public struct CapacityHistory: Equatable, Sendable {
    public let kind: CapacityTestKind
    /// Newest first. Results recorded at the same instant list the later-created first.
    public let results: [CapacityResult]

    public init(kind: CapacityTestKind, results: [CapacityResult]) {
        self.kind = kind
        self.results = results.filter { $0.kind == kind }.sorted {
            ($0.recordedAt, $0.createdAt, $0.id.uuidString) > ($1.recordedAt, $1.createdAt, $1.id.uuidString)
        }
    }

    public var latest: CapacityResult? { results.first }

    /// The best value from the most recent day the test was recorded. A grip test on both hands, or a balance test
    /// on both legs, gives the better of the two. Higher is better for every test. Nil with no results.
    public var headline: Double? {
        guard let latest else { return nil }
        return results.filter { $0.localDayKey == latest.localDayKey }.map(\.value).max()
    }
}
