import CoreGraphics
import DesignSystem
import Foundation

// MARK: - Scrub

/// What a finger on the rim, or VoiceOver stepping through the hours, reads at one time of day.
public struct TodayDialScrubReading: Equatable, Sendable {
    public let minuteOfDay: Int
    /// "14:00"
    public let time: String
    /// What happened then, one line each, or "Nothing recorded".
    public let lines: [String]

    /// "14:00. Lunch at 13:05."
    public var spoken: String { ([time] + lines).joined(separator: ". ") + "." }
}

public enum TodayDialScrub {
    /// Things this close to the time read out with it.
    public static let windowMinutes = 30

    /// The minute of the day under `point` in a dial of `side` points, or nil inside the centre, where the hand starts.
    public static func minuteOfDay(at point: CGPoint, side: CGFloat) -> Int? {
        guard side > 0 else { return nil }
        let scale = Double(side) / TodayDialGeometry.viewBox
        let dx = Double(point.x) / scale - TodayDialGeometry.centre, dy = Double(point.y) / scale - TodayDialGeometry.centre
        guard hypot(dx, dy) >= TodayDialGeometry.innerRingRadius else { return nil }
        // Clockwise from the top: atan2 of x against minus y.
        let angle = TodayDialGeometry.normalized(atan2(dx, -dy) * 180 / .pi)
        return Int((TodayDialGeometry.normalized(angle - 180) * 4).rounded(.down)) % 1_440
    }

    /// The hour stop for a minute, for the detent haptic.
    public static func hour(_ minuteOfDay: Int) -> Int { (minuteOfDay / 60) % 24 }

    public static func reading(_ model: TodayDialModel, minuteOfDay: Int, locale: Locale = .current) -> TodayDialScrubReading {
        let minute = ((minuteOfDay % 1_440) + 1_440) % 1_440
        let clock = model.clock
        func dayMinute(_ date: Date) -> Int { ((Int(clock.dialMinutes(of: date).rounded(.down)) % 1_440) + 1_440) % 1_440 }
        func distance(_ a: Int, _ b: Int) -> Int { let d = abs(a - b) % 1_440; return min(d, 1_440 - d) }
        func covers(_ arc: TodayDialArc) -> Bool {
            let start = dayMinute(arc.start), length = Int((arc.sweep * 4).rounded())
            return ((minute - start) % 1_440 + 1_440) % 1_440 <= length
        }
        func time(_ date: Date) -> String { TodayDialFormat.clock(date, clock: clock, locale: locale) }
        var lines: [String] = []

        switch model.sleep {
        case .present(.lastNight(let night)):
            if let span = night.spans.first(where: { covers($0.arc) }) {
                lines.append(span.stage == .awake ? "Awake in the night" : "\(span.stage.title) sleep")
            } else if covers(night.night) {
                lines.append("Asleep")
            }
        case .present(.tonight(let tonight)):
            if let window = tonight.window, covers(window) { lines.append("Tonight's sleep window") }
            if let windDown = tonight.windDown, covers(windDown) { lines.append("Wind-down before bed") }
        case .absent:
            break
        }
        if let bedtime = model.bedtime, distance(dayMinute(bedtime.at), minute) <= windowMinutes {
            lines.append("Bed at \(time(bedtime.at))")
        }
        for meal in model.eating.value?.meals ?? [] where distance(dayMinute(meal.at), minute) <= windowMinutes {
            lines.append("\(meal.title) at \(time(meal.at))")
        }
        for block in model.training.value ?? [] where covers(block.arc) || distance(dayMinute(block.arc.start), minute) <= windowMinutes {
            let span = block.arc.sweep > 0 ? "\(time(block.arc.start)) to \(time(block.arc.end))" : "at \(time(block.arc.start))"
            lines.append(block.isPlanned ? "\(block.title) planned \(span)" : "\(block.title), \(span)")
        }
        for bead in model.beads where distance(bead.minuteOfDay, minute) <= windowMinutes {
            lines.append("\(bead.title) at \(TodayDialFormat.clock(minuteOfDay: bead.minuteOfDay, locale: locale)), \(stateWord(bead.state))")
        }
        if let daylight = model.daylight.value, daylight.placement == .atTimes,
           daylight.dotAngles.contains(where: { distance(Int(TodayDialGeometry.normalized($0 - 180) * 4), minute) <= 2 }) {
            lines.append("In daylight")
        }
        if let alarm = model.alarm, distance(dayMinute(alarm.wake), minute) <= windowMinutes {
            lines.append(alarm.isTomorrow ? "Alarm at \(time(alarm.wake)) tomorrow" : "Alarm at \(time(alarm.wake))")
        }
        return TodayDialScrubReading(minuteOfDay: minute, time: TodayDialFormat.clock(minuteOfDay: minute, locale: locale),
                                     lines: lines.isEmpty ? ["Nothing recorded"] : lines)
    }

    static func stateWord(_ state: TodayDialRuleState) -> String {
        switch state {
        case .kept: "kept"
        case .missed: "missed"
        case .pending: "to do"
        case .unknown: "not checked"
        }
    }
}

// MARK: - Arrivals

/// Something that arrived on the dial since it was last seen, and where its dots fly.
public struct TodayDialArrival: Equatable, Sendable, Identifiable {
    public enum Kind: String, Equatable, Sendable { case meal, workout }

    public let id: String
    public let kind: Kind
    /// Where the dots start: the sticker or the training block.
    public let sourceAngle: Double
    public let sourceRadius: Double
    /// Where they land: the eating window or the block's arc.
    public let targetRadius: Double
    public let targetStartAngle: Double
    public let targetSweep: Double
    public let tint: LooprColorToken

    /// How many dots fly.
    public static let dotCount = 14
}

/// Decides what flies. The first time a day's dial is seen, everything on it is recorded as shown and nothing flies:
/// the entrance draws it in. After that, a meal or a finished workout that is new since the last look flies once,
/// whether it was logged while Today was open or before the next visit.
public enum TodayDialArrivals {
    /// The meals and finished workouts on the dial, by the id the store keeps.
    public static func ids(_ model: TodayDialModel) -> Set<String> {
        var ids = Set((model.eating.value?.meals ?? []).map { "meal-\($0.id)" })
        for block in model.training.value ?? [] where !block.isPlanned && !block.isOngoing { ids.insert("workout-\(block.id)") }
        return ids
    }

    /// - Parameter seen: What was shown before for this day, nil on the day's first visit.
    public static func plan(_ model: TodayDialModel, seen: Set<String>?) -> [TodayDialArrival] {
        guard model.isToday, let seen else { return [] }
        var arrivals: [TodayDialArrival] = []
        if let eating = model.eating.value {
            let stickers = TodayDialStickerLayout.place(eating.meals)
            for meal in eating.meals where !seen.contains("meal-\(meal.id)") {
                let sticker = stickers.first { $0.id == meal.id }
                arrivals.append(TodayDialArrival(id: "meal-\(meal.id)", kind: .meal, sourceAngle: sticker?.angle ?? meal.angle,
                                                 sourceRadius: meal.radius, targetRadius: TodayDialGeometry.eatingRadius,
                                                 targetStartAngle: eating.window.startAngle, targetSweep: eating.window.sweep, tint: .energy))
            }
        }
        for block in model.training.value ?? [] where !block.isPlanned && !block.isOngoing && !seen.contains("workout-\(block.id)") {
            arrivals.append(TodayDialArrival(id: "workout-\(block.id)", kind: .workout,
                                             sourceAngle: TodayDialGeometry.normalized(block.arc.startAngle + block.arc.sweep / 2),
                                             sourceRadius: TodayDialGeometry.trainingRadius, targetRadius: TodayDialGeometry.trainingRadius,
                                             targetStartAngle: block.arc.startAngle, targetSweep: block.arc.sweep, tint: .strain))
        }
        return arrivals
    }
}

/// Remembers, per local day, which meals and workouts the dial has shown. Kept in an injectable `UserDefaults`.
public final class TodayDialArrivalStore: @unchecked Sendable {
    public static let shared = TodayDialArrivalStore()
    /// Days older than this are forgotten.
    static let keptDays = 3

    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static let key = "loopr.today.dial.shown"

    public func seen(day: String) -> Set<String>? {
        lock.lock(); defer { lock.unlock() }
        guard let all = defaults.dictionary(forKey: Self.key) as? [String: [String]], let ids = all[day] else { return nil }
        return Set(ids)
    }

    /// Adds `ids` to what `day` has shown and forgets old days.
    public func record(_ ids: Set<String>, day: String) {
        lock.lock(); defer { lock.unlock() }
        var all = defaults.dictionary(forKey: Self.key) as? [String: [String]] ?? [:]
        all[day] = Array(Set(all[day] ?? []).union(ids)).sorted()
        for old in all.keys.sorted().dropLast(Self.keptDays) { all[old] = nil }
        defaults.set(all, forKey: Self.key)
    }
}
