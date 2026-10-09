import Foundation

/// One live sample taken from the band while a wake window is open.
///
/// The WHOOP 4 live stream Loopr subscribes to (`0x28`) carries heart rate and
/// RR intervals, not accelerometer counts, so `motion` is nil in production
/// today. It is modelled because the detector must not be rewritten the day a
/// movement source arrives, and because tests need to drive the movement rule.
public struct SmartWakeSample: Equatable, Sendable {
    public let at: Date
    public let heartRateBPM: Double
    /// Movement magnitude in whatever unit the caller has. Any value at or
    /// above `SmartWakeDetector.motionThreshold` counts as one stir.
    public let motion: Double?

    public init(at: Date, heartRateBPM: Double, motion: Double? = nil) {
        self.at = at
        self.heartRateBPM = heartRateBPM
        self.motion = motion
    }
}

/// The span a smart alarm may wake someone in, plus the resting heart rate to
/// judge a rise against.
public struct SmartWakeWindow: Equatable, Sendable {
    /// The earliest moment the person agreed to be woken.
    public let earliest: Date
    /// The latest moment. The band alarm and the phone alarm are both armed
    /// for this instant, so it fires with or without this detector.
    public let latest: Date
    /// The heart rate this person has been sleeping at tonight. When nil the
    /// detector derives one from the samples it was given, and says it is
    /// waiting until it has enough of them.
    public let sleepingBaselineBPM: Double?

    public init(earliest: Date, latest: Date, sleepingBaselineBPM: Double? = nil) {
        self.earliest = earliest
        self.latest = latest
        self.sleepingBaselineBPM = sleepingBaselineBPM
    }
}

public enum SmartWakeDecision: Equatable, Sendable {
    case wait(String)
    case fireNow(String)

    public var shouldFire: Bool {
        if case .fireNow = self { return true }
        return false
    }

    public var reason: String {
        switch self {
        case .wait(let reason): reason
        case .fireNow(let reason): reason
        }
    }
}

/// Decides whether to wake someone early inside their wake window.
///
/// Deliberately small and deterministic. It reads a rise in heart rate above
/// the level the person has been sleeping at, plus stirring when a movement
/// source exists, and it never claims to stage sleep. Everything it needs is
/// passed in, so it has no clock, no storage, and no I/O.
///
/// The window end is the safety net: `decide` fires unconditionally once the
/// window closes, and the band alarm and the phone alarm are armed for that
/// same instant, so a detector that never sees a rise costs nothing.
public enum SmartWakeDetector {
    /// How far back a "now" reading looks. Two minutes of the 1 Hz stream is
    /// enough to average out a single noisy beat without lagging a real wake.
    public static let recentSpan: TimeInterval = 120
    /// Below this many samples in `recentSpan` the link is too thin to judge.
    public static let minimumRecentSamples = 5
    /// How many older samples the detector needs before it will derive its own
    /// sleeping baseline.
    public static let minimumBaselineSamples = 20
    /// A rise has to clear both of these, whichever is larger, so a 45 bpm
    /// sleeper and a 70 bpm sleeper get the same sensitivity.
    public static let riseBPM: Double = 4
    public static let riseFraction: Double = 0.08
    public static let motionThreshold: Double = 0.25
    public static let minimumMotionSamples = 3

    public static func decide(
        samples: [SmartWakeSample],
        window: SmartWakeWindow,
        now: Date
    ) -> SmartWakeDecision {
        guard now >= window.earliest else {
            return .wait("The wake window has not opened yet.")
        }
        guard now < window.latest else {
            return .fireNow("The wake window closed, so this is the time you asked for.")
        }

        let recent = samples.filter { $0.at > now.addingTimeInterval(-recentSpan) && $0.at <= now }
        guard recent.count >= minimumRecentSamples else {
            return .wait("Not enough live data from your strap to read your sleep.")
        }

        let earlier = samples.filter { $0.at <= now.addingTimeInterval(-recentSpan) }
        guard let baseline = window.sleepingBaselineBPM ?? quietBaseline(earlier) else {
            return .wait("Loopr has no sleeping heart rate to compare tonight against yet.")
        }

        let mean = recent.map(\.heartRateBPM).reduce(0, +) / Double(recent.count)
        let threshold = baseline + max(riseBPM, baseline * riseFraction)
        if mean >= threshold {
            return .fireNow(
                "Your heart rate rose to \(bpm(mean)) bpm, above the \(bpm(baseline)) bpm you slept at."
            )
        }

        let stirs = recent.compactMap(\.motion).filter { $0 >= motionThreshold }
        if stirs.count >= minimumMotionSamples {
            return .fireNow("You are moving, so you are close to waking anyway.")
        }

        return .wait("You are still settled, so Loopr is holding the alarm.")
    }

    /// The quarter-point of the supplied heart rates. It sits below the stirs
    /// and above the single lowest beat, which is what "the level this person
    /// is sleeping at" means with no staging available.
    public static func quietBaseline(_ samples: [SmartWakeSample]) -> Double? {
        guard samples.count >= minimumBaselineSamples else { return nil }
        let sorted = samples.map(\.heartRateBPM).sorted()
        let index = min(sorted.count - 1, sorted.count / 4)
        return sorted[index]
    }

    private static func bpm(_ value: Double) -> Int {
        Int(value.rounded())
    }
}
