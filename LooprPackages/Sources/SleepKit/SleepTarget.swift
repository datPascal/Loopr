import Foundation
import DesignSystem
import ProfileKit

/// What the night is measured against on the Sleep tab: the ring's full lap,
/// the hero line and the debt ledger.
///
/// The personal setting wins over a learned estimate. With no setting, the
/// same eight-hour default used by Today and Profile applies.
public struct SleepTarget: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case need
        case goal
        case recommended
    }

    public static let recommendedMinutes: Double = SleepNeed.defaultMinutes
    /// Earlier nights the need calculation waits for.
    public static let nightsForNeed = 3

    public let minutes: Double
    public let source: Source
    /// What is still missing before Loopr knows your need. Nil once it does.
    public let progress: SleepNeedProgress?

    public init(minutes: Double, source: Source, progress: SleepNeedProgress? = nil) {
        self.minutes = minutes
        self.source = source
        self.progress = source == .need ? nil : progress
    }

    /// Picks the target for a night from the saved setting or its default.
    public static func resolve(needHours: Double?, goalMinutes: Double?, history: SleepNightHistory) -> SleepTarget {
        if let goalMinutes, goalMinutes.isFinite, goalMinutes > 0 {
            return SleepTarget(minutes: goalMinutes, source: .goal)
        }
        return SleepTarget(minutes: recommendedMinutes, source: .recommended)
    }

    public var isProvisional: Bool { source != .need }

    public var ringScale: LooprRingScale { LooprRingScale(fullValue: minutes) }

    /// "7 h 50 m"
    public var durationText: String { LooprUnitFormatter.duration(minutes: minutes) ?? "" }

    /// The hero line, such as "7 h 12 m of 8 h needed".
    public func line(asleepMinutes: Double) -> String {
        let asleep = LooprUnitFormatter.duration(minutes: asleepMinutes) ?? ""
        switch source {
        case .need: return "\(asleep) of \(durationText) needed"
        case .goal, .recommended: return "\(asleep) of \(durationText) needed"
        }
    }

    /// The quiet line under a provisional target, or nil for a learned need.
    public var provisionalNote: String? {
        guard isProvisional else { return nil }
        return nil
    }

    public func spokenLine(asleepMinutes: Double) -> String {
        let asleep = LooprUnitFormatter.spokenDuration(minutes: asleepMinutes) ?? ""
        let target = LooprUnitFormatter.spokenDuration(minutes: minutes) ?? ""
        switch source {
        case .need: return "\(asleep) of the \(target) you need"
        case .goal, .recommended: return "\(asleep) of the \(target) you need"
        }
    }
}

/// How far Loopr is from knowing your sleep need.
public struct SleepNeedProgress: Equatable, Sendable {
    /// Earlier finished nights with a main sleep.
    public let nights: Int
    public let neededNights: Int
    /// Whether one of them ended on a Saturday or Sunday.
    public let hasWeekendNight: Bool

    public init(nights: Int, neededNights: Int = SleepTarget.nightsForNeed, hasWeekendNight: Bool) {
        self.nights = max(0, nights)
        self.neededNights = max(1, neededNights)
        self.hasWeekendNight = hasWeekendNight
    }

    /// The derivation reads the 28 nights before the selected one.
    public init(history: SleepNightHistory) {
        let nights = history.prior(within: 28).filter { $0.asleepMinutes != nil }
        self.init(nights: nights.count, hasWeekendNight: nights.contains { $0.day.isWeekend })
    }

    public var missingNights: Int { max(0, neededNights - nights) }

    /// "2 more nights and a weekend night to go." Nil when nothing is
    /// missing, which happens when the need is being recalculated.
    public var remainingText: String? {
        let nightsText: String? = missingNights == 0 ? nil
            : missingNights == 1 ? "1 more night" : "\(missingNights) more nights"
        switch (nightsText, hasWeekendNight) {
        case (nil, true): return nil
        case (nil, false): return "It needs one weekend night first."
        case (let text?, true): return "It needs \(text) first."
        case (let text?, false): return "It needs \(text), one of them on a weekend."
        }
    }
}
