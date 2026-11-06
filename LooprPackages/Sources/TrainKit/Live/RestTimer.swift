import Foundation

/// A rest countdown held as an end date, not as a number that ticks down.
///
/// Everything reads the clock through the `now` the caller passes. Nothing here sleeps or
/// schedules, so a view, a background task and a test all agree on the same answer, and the
/// timer is still right after the app has been suspended and comes back.
public struct RestTimer: Equatable, Sendable, Codable {
    /// What the "+30 s" button adds.
    public static let extensionSeconds = 30
    /// A cue that arrives later than this after the end date is dropped. A buzz two minutes after
    /// the rest ended would tell the person nothing.
    public static let cueGraceSeconds: TimeInterval = 20
    /// The longest rest the timer holds, matching the template limit.
    public static let maximumSeconds = 3_600

    public private(set) var startedAt: Date
    public private(set) var endsAt: Date
    public private(set) var cueClaimed: Bool

    public init(startingAt now: Date, seconds: Int) {
        let clamped = min(max(seconds, 0), Self.maximumSeconds)
        startedAt = now
        endsAt = now.addingTimeInterval(TimeInterval(clamped))
        cueClaimed = false
    }

    /// The full length the ring drains from, including any added time.
    public var totalSeconds: TimeInterval { max(endsAt.timeIntervalSince(startedAt), 0) }

    /// Whole seconds left, rounded up so the timer reads 0:01 until the end date passes.
    public func remainingSeconds(at now: Date) -> Int {
        let remaining = endsAt.timeIntervalSince(now)
        guard remaining.isFinite, remaining > 0 else { return 0 }
        return Int(remaining.rounded(.up))
    }

    public func isExpired(at now: Date) -> Bool { now >= endsAt }

    /// The share of the rest still left, 0 to 1.
    public func fractionRemaining(at now: Date) -> Double {
        guard totalSeconds > 0 else { return 0 }
        return min(max(Double(remainingSeconds(at: now)) / totalSeconds, 0), 1)
    }

    /// Adds time. While the rest is running it moves the end date later. Once the rest is over it
    /// starts a fresh countdown of `seconds` from `now` and arms the cue again.
    public mutating func extend(bySeconds seconds: Int = RestTimer.extensionSeconds, now: Date) {
        let added = TimeInterval(min(max(seconds, 0), Self.maximumSeconds))
        if isExpired(at: now) {
            startedAt = now
            endsAt = now.addingTimeInterval(added)
            cueClaimed = false
        } else {
            let capped = min(endsAt.addingTimeInterval(added), now.addingTimeInterval(TimeInterval(Self.maximumSeconds)))
            endsAt = capped
        }
    }

    /// True once, when the rest has ended and the end date is recent enough to be worth a buzz.
    /// A later call returns false, and so does a call before the end date. A call long after the
    /// end date returns false and still uses up the cue.
    public mutating func claimCue(at now: Date) -> Bool {
        guard isExpired(at: now), !cueClaimed else { return false }
        cueClaimed = true
        return now.timeIntervalSince(endsAt) <= Self.cueGraceSeconds
    }
}
