import Foundation
import DomainKit

/// What the person chose on Today: the pinned "Your numbers" and the day the
/// heads-up card was put away. Stored on the phone only.
public struct TodayPreferences: Codable, Equatable, Sendable {
    public static let maximumPinned = 6
    public static let defaultPinned: [TodayTrackedMetric] = [.hrv, .restingHeartRate, .steps, .activeEnergy]

    public private(set) var pinned: [TodayTrackedMetric]
    /// The day the heads-up card was dismissed; it stays away for that day only.
    public private(set) var headsUpDismissedDay: DayIdentity?

    public init(pinned: [TodayTrackedMetric] = TodayPreferences.defaultPinned, headsUpDismissedDay: DayIdentity? = nil) {
        self.pinned = Self.sanitised(pinned)
        self.headsUpDismissedDay = headsUpDismissedDay
    }

    /// Keeps order, drops repeats, caps at six. An empty list is allowed: the
    /// person may want no tiles.
    public static func sanitised(_ metrics: [TodayTrackedMetric]) -> [TodayTrackedMetric] {
        var seen = Set<TodayTrackedMetric>()
        return Array(metrics.filter { seen.insert($0).inserted }.prefix(maximumPinned))
    }

    public mutating func setPinned(_ metrics: [TodayTrackedMetric]) {
        pinned = Self.sanitised(metrics)
    }

    public mutating func dismissHeadsUp(for day: DayIdentity) {
        headsUpDismissedDay = day
    }

    public func isHeadsUpDismissed(on day: DayIdentity) -> Bool {
        headsUpDismissedDay == day
    }

    private enum CodingKeys: String, CodingKey { case pinned, headsUpDismissedDay }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A metric a later version removed must not throw away the rest.
        let raw = try container.decodeIfPresent([String].self, forKey: .pinned)
        pinned = raw.map { Self.sanitised($0.compactMap(TodayTrackedMetric.init(rawValue:))) } ?? Self.defaultPinned
        headsUpDismissedDay = try container.decodeIfPresent(DayIdentity.self, forKey: .headsUpDismissedDay)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pinned.map(\.rawValue), forKey: .pinned)
        try container.encodeIfPresent(headsUpDismissedDay, forKey: .headsUpDismissedDay)
    }
}

/// Reads and writes `TodayPreferences` in a defaults domain.
public struct TodayPreferencesStore: Sendable {
    public static let key = "loopr.today.preferences.v1"

    private let suiteName: String?

    /// - Parameter suiteName: nil for the standard domain. Tests pass their own.
    public init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    public func load() -> TodayPreferences {
        guard let data = defaults.data(forKey: Self.key),
              let value = try? JSONDecoder().decode(TodayPreferences.self, from: data) else { return TodayPreferences() }
        return value
    }

    public func save(_ preferences: TodayPreferences) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
