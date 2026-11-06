import Foundation

/// The dot counts the dose field last showed for one ISO week, so dots that arrive with a sync fly in
/// once and only once (DESIGN_LANGUAGE premium check 2).
public struct FitnessDoseShown: Equatable, Sendable, Codable {
    public var zone2: Int
    public var hard: Int

    public init(zone2: Int, hard: Int) {
        self.zone2 = max(zone2, 0)
        self.hard = max(hard, 0)
    }
}

/// Decides how many dots fly in. The first look at a week flies nothing: the tab's entrance draws its
/// dots, and that look becomes the count to compare against. After that, a count above the last one
/// shown flies the difference, up to `maximumDots`; the rest appear in place.
public enum FitnessDoseFlight {
    /// More than this many dots read as a smear rather than a landing.
    public static let maximumDots = 24

    /// Dots to fly for one row, given what it shows now and what it showed last.
    public static func newDots(current: Int, lastShown: Int?) -> Int {
        guard let lastShown, current > lastShown else { return 0 }
        return min(current - lastShown, maximumDots)
    }

    /// Dots to fly for each row. Nothing flies when the person asked for less motion, when a capture
    /// forces final states, or when the band has no minutes.
    public static func plan(current: FitnessDoseShown?, lastShown: FitnessDoseShown?, animates: Bool) -> FitnessDoseShown {
        guard animates, let current else { return FitnessDoseShown(zone2: 0, hard: 0) }
        return FitnessDoseShown(zone2: newDots(current: current.zone2, lastShown: lastShown?.zone2),
                                hard: newDots(current: current.hard, lastShown: lastShown?.hard))
    }
}

/// Remembers the last counts shown per ISO week, in `UserDefaults`. Weeks other than the current
/// one and the one before are dropped as a new week is recorded.
public final class FitnessDoseShownStore: @unchecked Sendable {
    public static let shared = FitnessDoseShownStore()

    private let defaults: UserDefaults
    private static let prefix = "loopr.fitness.dose-shown."

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// `2023-W46`
    public static func key(for week: ISOWeek) -> String {
        String(format: "%04ld-W%02ld", week.yearForWeekOfYear, week.weekOfYear)
    }

    public func lastShown(week: String) -> FitnessDoseShown? {
        guard let data = defaults.data(forKey: Self.prefix + week) else { return nil }
        return try? JSONDecoder().decode(FitnessDoseShown.self, from: data)
    }

    public func record(_ shown: FitnessDoseShown, week: String) {
        guard let data = try? JSONEncoder().encode(shown) else { return }
        let key = Self.prefix + week
        if defaults.data(forKey: key) == nil {
            // A new week: keep the one before it for a late sync, drop anything older.
            let kept = Set(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(Self.prefix) }.sorted().suffix(1))
            for old in defaults.dictionaryRepresentation().keys where old.hasPrefix(Self.prefix) && !kept.contains(old) {
                defaults.removeObject(forKey: old)
            }
        }
        defaults.set(data, forKey: key)
    }
}
