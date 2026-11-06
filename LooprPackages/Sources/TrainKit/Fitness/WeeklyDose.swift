import DomainKit
import Foundation
import WorkoutKit

// DEC-12.15: the weekly dose counts zone 2 minutes the band measured in any activity, hard minutes in zones 4 and 5,
// strength sessions and mobility sessions, for one ISO week.

/// Minutes in each of the five heart rate zones for one day, as the band measured them.
public struct BandZoneMinutes: Equatable, Sendable {
    /// Zones 1 to 5, in order.
    public let zones: [Double]

    /// Nil unless there are exactly five finite, non-negative values.
    public init?(zones: [Double]) {
        guard zones.count == 5, zones.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        self.zones = zones
    }

    public var zone2: Double { zones[1] }
    /// Zones 4 and 5 together.
    public var hard: Double { zones[3] + zones[4] }
}

/// One local day of band zone minutes. `zones` is nil when the band has no data for the day, which is not the
/// same as a day with zero minutes. If a day appears twice, the later entry wins.
public struct DoseDay: Equatable, Sendable {
    public let day: DayIdentity
    public let zones: BandZoneMinutes?
    /// Where `zones` came from. The band, unless the heart rate of Apple Health workouts filled a day the band did
    /// not cover (R1-VET-02).
    public let source: DoseZoneSource
    public init(day: DayIdentity, zones: BandZoneMinutes?, source: DoseZoneSource = .band) {
        self.day = day; self.zones = zones; self.source = source
    }
}

/// Who measured a day's zone minutes.
public enum DoseZoneSource: String, Sendable {
    case band, appleHealth
}

/// Who measured the week's zone minutes, for the label on the dose card.
public enum DoseZoneMinutesSource: String, Sendable {
    case band, appleHealth, bandAndAppleHealth

    /// "Band", "Apple Health", "Band and Apple Health".
    public var label: String {
        switch self {
        case .band: "Band"
        case .appleHealth: "Apple Health"
        case .bandAndAppleHealth: "Band and Apple Health"
        }
    }

    /// Nil when no day has zone minutes.
    public static func of(_ sources: [DoseZoneSource]) -> DoseZoneMinutesSource? {
        switch (sources.contains(.band), sources.contains(.appleHealth)) {
        case (true, true): .bandAndAppleHealth
        case (true, false): .band
        case (false, true): .appleHealth
        case (false, false): nil
        }
    }
}

public enum DoseSessionKind: String, CaseIterable, Sendable {
    case strength, mobility

    /// Activity names that count as strength. HealthKit's `HKWorkoutActivityType` has `traditionalStrengthTraining`
    /// and `functionalStrengthTraining`; Loopr's own catalogue (WorkoutKit `ActivityType`) has `strength` and
    /// `crossfit`, so a logged WOD counts as a strength session.
    public static let strengthActivities: Set<String> = [
        "strength", "strengthtraining", "traditionalstrengthtraining", "functionalstrengthtraining",
        "weighttraining", "weightlifting", "crossfit", "crosstraining"
    ]

    /// Activity names that count as mobility and balance: yoga, mobility work, stretching, flexibility, balance,
    /// pilates, tai chi, and the Apple Watch types for mind and body, cooldown and preparation and recovery
    /// (stretching and warm-up routines). Loopr's own catalogue has `yoga`, `pilates` and `mobility` here.
    public static let mobilityActivities: Set<String> = [
        "yoga", "mobility", "stretching", "flexibility", "balance", "pilates", "taichi", "mindandbody",
        "cooldown", "preparationandrecovery"
    ]

    /// Nil for any other activity. Case, spaces, underscores and a leading `HKWorkoutActivityType` do not matter,
    /// so "Tai Chi", "tai_chi" and "HKWorkoutActivityTypeTaiChi" all match.
    public static func classify(activity: String) -> DoseSessionKind? {
        var name = String(activity.lowercased().filter(\.isLetter))
        let prefix = "hkworkoutactivitytype"
        if name.hasPrefix(prefix) { name = String(name.dropFirst(prefix.count)) }
        if strengthActivities.contains(name) { return .strength }
        if mobilityActivities.contains(name) { return .mobility }
        return nil
    }
}

/// A completed session. `id` lets the dose count one session once when the same session arrives twice, as a gym
/// session and its linked workout record do. Pass the workout id for both.
public struct DoseSession: Equatable, Sendable {
    public let id: UUID?
    public let activity: String
    public let date: Date

    public init(id: UUID? = nil, activity: String, date: Date) {
        self.id = id; self.activity = activity; self.date = date
    }

    public init(id: UUID? = nil, activity: ActivityType, date: Date) {
        self.init(id: id, activity: activity.rawValue, date: date)
    }

    /// A completed gym session counts as strength. Nil for an active or abandoned one, and for one where every
    /// logged set was a warm-up. It shares its workout's identity, so the gym session and the workout record behind
    /// it count once.
    public init?(trainSession: TrainSession) {
        guard trainSession.status == .completed, trainSession.hasWorkingSet || trainSession.warmUpSetCount == 0 else { return nil }
        self.init(id: trainSession.workoutID ?? trainSession.id, activity: "strength", date: trainSession.startedAt)
    }
}

/// Weekly targets. A nil target means the protocol has no rule for it, and the dose shows the count without a goal.
public struct DoseTargets: Equatable, Sendable {
    public static let zone2MinutesMetric = "zone2_minutes"
    public static let zone45MinutesMetric = "zone45_minutes"
    public static let strengthSessionsMetric = "strength_sessions"
    public static let mobilitySessionsMetric = "mobility_sessions"

    public static let none = DoseTargets()

    public let zone2Minutes: Double?
    public let hardMinutes: Double?
    public let strengthSessions: Int?
    public let mobilitySessions: Int?

    /// A value that is not finite or not above zero becomes no target.
    public init(zone2Minutes: Double? = nil, hardMinutes: Double? = nil,
                strengthSessions: Int? = nil, mobilitySessions: Int? = nil) {
        self.zone2Minutes = Self.valid(zone2Minutes)
        self.hardMinutes = Self.valid(hardMinutes)
        self.strengthSessions = strengthSessions.flatMap { $0 > 0 ? $0 : nil }
        self.mobilitySessions = mobilitySessions.flatMap { $0 > 0 ? $0 : nil }
    }

    private static func valid(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }
}

/// One dot is five minutes. `filled` counts whole dots and is not capped by `total`, so a week past its target
/// shows it. `total` is nil when there is no target.
public struct DoseDots: Equatable, Sendable {
    public static let minutesPerDot = 5.0
    public let filled: Int
    public let total: Int?

    public init(minutes: Double, target: Double?) {
        filled = Int((minutes / Self.minutesPerDot).rounded(.down))
        total = target.map { Int(($0 / Self.minutesPerDot).rounded(.up)) }
    }
}

/// Band minutes in one zone group for the week. `minutes` is nil when the band has no data for any day of the week.
public struct DoseMinutes: Equatable, Sendable {
    public let minutes: Double?
    public let target: Double?
    public let dots: DoseDots?

    public init(minutes: Double?, target: Double?) {
        self.minutes = minutes
        self.target = target
        dots = minutes.map { DoseDots(minutes: $0, target: target) }
    }

    /// Minutes over target, not capped. Nil without minutes or without a target.
    public var progress: Double? {
        guard let minutes, let target else { return nil }
        return minutes / target
    }
}

public struct DoseSessions: Equatable, Sendable {
    public let count: Int
    public let target: Int?
    public init(count: Int, target: Int?) { self.count = count; self.target = target }
}

public struct WeeklyDose: Equatable, Sendable {
    public let week: ISOWeek
    public let zone2: DoseMinutes
    /// Zones 4 and 5.
    public let hard: DoseMinutes
    public let strength: DoseSessions
    public let mobility: DoseSessions
    /// Days of the week with zone minutes, from the band or from Apple Health workouts. Zero means the minutes are
    /// absent.
    public let bandDaysWithData: Int
    public var bandDaysInWeek: Int { week.days.count }
    /// True when the band covered some days of the week but not all, so the minutes are a floor.
    public var bandCoverageIsPartial: Bool { bandDaysWithData > 0 && bandDaysWithData < bandDaysInWeek }
    /// Who measured the zone minutes: "Band", "Apple Health" or both. Nil when no day has zone minutes.
    public var zoneMinutesSource: DoseZoneMinutesSource? = nil

    /// The dose for the ISO week holding `date`. Nil only when the calendar cannot place the date.
    public static func make(weekContaining date: Date, days: [DoseDay], sessions: [DoseSession],
                            targets: DoseTargets = .none, calendar: Calendar) -> WeeklyDose? {
        guard let week = ISOWeek(containing: date, calendar: calendar) else { return nil }
        return make(week: week, days: days, sessions: sessions, targets: targets)
    }

    public static func make(week: ISOWeek, days: [DoseDay], sessions: [DoseSession],
                            targets: DoseTargets = .none) -> WeeklyDose {
        var latestByDay: [DayIdentity: DoseDay] = [:]
        for entry in days where week.days.contains(entry.day) { latestByDay[entry.day] = entry }
        let measured = latestByDay.values.compactMap(\.zones)
        let measuredBy = latestByDay.values.filter { $0.zones != nil }.map(\.source)
        let zone2 = measured.isEmpty ? nil : measured.reduce(0) { $0 + $1.zone2 }
        let hard = measured.isEmpty ? nil : measured.reduce(0) { $0 + $1.hard }

        var seen = Set<UUID>()
        var strength = 0, mobility = 0
        for session in sessions where week.contains(session.date) {
            if let id = session.id, !seen.insert(id).inserted { continue }
            switch DoseSessionKind.classify(activity: session.activity) {
            case .strength: strength += 1
            case .mobility: mobility += 1
            case nil: break
            }
        }
        return WeeklyDose(week: week,
            zone2: DoseMinutes(minutes: zone2, target: targets.zone2Minutes),
            hard: DoseMinutes(minutes: hard, target: targets.hardMinutes),
            strength: DoseSessions(count: strength, target: targets.strengthSessions),
            mobility: DoseSessions(count: mobility, target: targets.mobilitySessions),
            bandDaysWithData: measured.count, zoneMinutesSource: DoseZoneMinutesSource.of(measuredBy))
    }
}
