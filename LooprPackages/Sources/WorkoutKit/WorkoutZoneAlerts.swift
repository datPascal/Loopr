import AnalyticsKit
import Foundation
import DomainKit

public enum WorkoutZoneAlertTarget: Codable, Equatable, Sendable {
    case off
    case zoneTwo
    case zone(Int)
    case custom(lower: Int, upper: Int)

    public func range(in zones: HeartRateZoneSet?, zoneTwo: ZoneTwoRange? = nil) -> ClosedRange<Int>? {
        switch self {
        case .off: nil
        case .zoneTwo: zoneTwo?.range
        case .zone(let number):
            zones?.zones.first(where: { $0.number == number }).flatMap { zone in
                let lower = Int(ceil(zone.lowerBPM))
                let upper = number == 5 ? Int(zone.upperBPM.rounded()) : Int(ceil(zone.upperBPM)) - 1
                return lower <= upper ? lower...upper : nil
            }
        case .custom(let lower, let upper):
            (30...240).contains(lower) && (30...240).contains(upper) && lower < upper ? lower...upper : nil
        }
    }
}

public struct WorkoutZoneAlertPreference: Codable, Equatable, Sendable {
    public var target: WorkoutZoneAlertTarget
    public var playSound: Bool
    public var alertWhenTooLow: Bool
    public var buzzWhenBackInZone: Bool
    public var warmUpMinutes: Int
    public var manualZoneTwo: ZoneTwoRange?
    public init(target: WorkoutZoneAlertTarget = .off, playSound: Bool = false,
                alertWhenTooLow: Bool = false, buzzWhenBackInZone: Bool = true,
                warmUpMinutes: Int = 8, manualZoneTwo: ZoneTwoRange? = nil) {
        self.target = target; self.playSound = playSound
        self.alertWhenTooLow = alertWhenTooLow; self.buzzWhenBackInZone = buzzWhenBackInZone
        self.warmUpMinutes = min(15, max(0, warmUpMinutes)); self.manualZoneTwo = manualZoneTwo
    }
    private enum CodingKeys: String, CodingKey {
        case target, playSound, alertWhenTooLow, buzzWhenBackInZone, warmUpMinutes, manualZoneTwo
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(target: try values.decodeIfPresent(WorkoutZoneAlertTarget.self, forKey: .target) ?? .off,
                  playSound: try values.decodeIfPresent(Bool.self, forKey: .playSound) ?? false,
                  alertWhenTooLow: try values.decodeIfPresent(Bool.self, forKey: .alertWhenTooLow) ?? false,
                  buzzWhenBackInZone: try values.decodeIfPresent(Bool.self, forKey: .buzzWhenBackInZone) ?? true,
                  warmUpMinutes: try values.decodeIfPresent(Int.self, forKey: .warmUpMinutes) ?? 8,
                  manualZoneTwo: try values.decodeIfPresent(ZoneTwoRange.self, forKey: .manualZoneTwo))
    }
    public func resolvedZoneTwo(_ automatic: ZoneTwoRange?) -> ZoneTwoRange? {
        guard let manualZoneTwo, manualZoneTwo.lower >= 30, manualZoneTwo.upper <= 240, manualZoneTwo.lower < manualZoneTwo.upper else { return automatic }
        return ZoneTwoRange.resolve(maximum: nil, restingNights: [], manual: manualZoneTwo.range) ?? automatic
    }
}

/// Shared timing for every workout target. Thirty seconds requires a steady
/// excursion; wrist testing can assess whether a longer dwell is useful.
public struct WorkoutZoneAlertConfiguration: Equatable, Sendable {
    public var hysteresisBPM = 3
    public var sustainedSeconds: TimeInterval = 30
    public var returnSeconds: TimeInterval = 15
    public var reminderSeconds: TimeInterval = 90
    public var maximumAlerts = 3
    /// Dwell requires a continuous live signal, a stricter check than the
    /// screen freshness window. A missed stretch restarts the timer.
    public var maximumSampleGapSeconds: TimeInterval = 2
    public init() {}
}

public final class WorkoutZoneAlertPreferenceStore: @unchecked Sendable {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func preference(for activity: ActivityType) -> WorkoutZoneAlertPreference {
        guard let data = defaults.data(forKey: key(activity)),
              let preference = try? JSONDecoder().decode(WorkoutZoneAlertPreference.self, from: data) else {
            return .init()
        }
        return preference
    }
    public func set(_ preference: WorkoutZoneAlertPreference, for activity: ActivityType) {
        guard let data = try? JSONEncoder().encode(preference) else { return }
        defaults.set(data, forKey: key(activity))
    }
    private func key(_ activity: ActivityType) -> String { "loopr.workout.zone-alert.\(activity.rawValue)" }
}

public enum WorkoutZoneAlertEvent: Equatable, Sendable {
    case tooLow
    case tooHigh
    case returned
}

public struct WorkoutZoneAlertMachine: Sendable {
    public enum Side: Equatable, Sendable { case low, high }
    public enum State: Equatable, Sendable {
        case inRange
        case leaving(Side, since: Date)
        case out(Side)
        case returning(Side, since: Date)
    }
    public private(set) var state: State = .inRange
    public private(set) var alertCount = 0
    public var configuration = WorkoutZoneAlertConfiguration()
    private var lastAlertAt: Date?
    private var excursionSide: Side?
    public init() {}
    public mutating func reset() {
        state = .inRange; alertCount = 0; lastAlertAt = nil; excursionSide = nil
    }
    /// A gap clears dwell timers, but does not turn an unobserved return into
    /// a new excursion or permit extra reminders beyond the cap.
    public mutating func interrupt() { state = .inRange }

    public mutating func observe(bpm: Int?, at now: Date, target: ClosedRange<Int>?,
                                 activeElapsed: TimeInterval = .infinity,
                                 preference: WorkoutZoneAlertPreference = .init()) -> WorkoutZoneAlertEvent? {
        guard activeElapsed >= Double(preference.warmUpMinutes * 60) else { reset(); return nil }
        guard let target, let bpm, (30...240).contains(bpm) else { interrupt(); return nil }
        let side: Side? = bpm > target.upperBound + configuration.hysteresisBPM ? .high
            : bpm < target.lowerBound - configuration.hysteresisBPM && preference.alertWhenTooLow ? .low : nil
        let inside = target.contains(bpm)
        // After an interruption, a confirmed return still earns a cue only
        // if an alert was sent before the gap.
        if case .inRange = state, alertCount > 0, inside, let previous = excursionSide {
            state = .returning(previous, since: now)
            return nil
        }
        switch state {
        case .inRange:
            if let side { state = .leaving(side, since: now); excursionSide = side }
        case .leaving(let previous, let since):
            guard side == previous else {
                if inside, alertCount > 0 { state = .returning(previous, since: now) }
                else { state = side.map { .leaving($0, since: now) } ?? .inRange }
                return nil
            }
            if now.timeIntervalSince(since) >= configuration.sustainedSeconds {
                state = .out(previous)
                return alert(previous, at: now)
            }
        case .out(let previous):
            if inside { state = .returning(previous, since: now) }
            else if let side, side != previous { state = .leaving(side, since: now); excursionSide = side }
            else if side == previous { return alert(previous, at: now) }
        case .returning(let previous, let since):
            guard inside else {
                state = side.map { $0 == previous ? .out($0) : .leaving($0, since: now) } ?? .out(previous)
                return nil
            }
            if now.timeIntervalSince(since) >= configuration.returnSeconds {
                let shouldCue = alertCount > 0 && preference.buzzWhenBackInZone
                reset()
                return shouldCue ? .returned : nil
            }
        }
        return nil
    }
    private mutating func alert(_ side: Side, at now: Date) -> WorkoutZoneAlertEvent? {
        guard alertCount < configuration.maximumAlerts,
              lastAlertAt.map({ now.timeIntervalSince($0) >= configuration.reminderSeconds }) ?? true else { return nil }
        alertCount += 1; lastAlertAt = now; excursionSide = side
        return side == .high ? .tooHigh : .tooLow
    }
}
