import Foundation

/// The pins an older version kept for Today's "Your numbers". Nothing writes them any more. Health's pins
/// are the only ones, and `HealthMetricPins` reads this once to carry an older choice over.
public struct TodayPreferences: Decodable, Equatable, Sendable {
    public let pinned: [TodayTrackedMetric]

    private enum CodingKeys: String, CodingKey { case pinned }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A metric a later version removed must not throw away the rest.
        let raw = try container.decode([String].self, forKey: .pinned)
        var seen = Set<TodayTrackedMetric>()
        pinned = raw.compactMap(TodayTrackedMetric.init(rawValue:)).filter { seen.insert($0).inserted }
    }
}

/// Where the old pins were saved. The key stays so the migration can find them and Delete all data can remove them.
public enum TodayPreferencesStore {
    public static let key = "loopr.today.preferences.v1"
}

/// "Hide" on Today's "No band connected" line, for a person who has no band (ICP R3-NEW-7). Settings still offers the
/// band. Delete all data removes the key.
public enum TodayBandBannerPreference {
    public static let hiddenKey = "loopr.today.no-band-banner-hidden.v1"
}
