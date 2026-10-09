import Foundation
import DomainKit

nonisolated let looprHeartZonesChanged = Notification.Name("com.loopr.heart.zones.changed")
nonisolated let looprHeartZoneHistoryUpdated = Notification.Name("com.loopr.heart.zones.history.updated")

/// Kept outside the profile document so an edited zone can invalidate every
/// saved daily generation without changing the person's birth year.
actor HeartZonePreferences {
    static let shared = HeartZonePreferences()
    static let revisionKey = "com.loopr.heart.zones.revision"
    private let defaults: UserDefaults
    private let dataKey: String
    private let storedRevisionKey: String

    init(defaults: UserDefaults = .standard,
         dataKey: String = "com.loopr.heart.zones.settings",
         revisionKey: String = HeartZonePreferences.revisionKey) {
        self.defaults = defaults
        self.dataKey = dataKey
        self.storedRevisionKey = revisionKey
    }

    func load() -> HeartRateZoneSettings {
        guard let data = defaults.data(forKey: dataKey),
              let settings = try? JSONDecoder().decode(HeartRateZoneSettings.self, from: data) else {
            return HeartRateZoneSettings()
        }
        return settings
    }

    func save(_ settings: HeartRateZoneSettings) {
        guard settings != load(), let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: dataKey)
        announceChange()
    }

    /// Age supplies the automatic maximum. A new age invalidates saved
    /// strain and zone history even when the boundary settings did not move.
    func profileAgeChanged() {
        announceChange()
    }

    private func announceChange() {
        defaults.set(defaults.integer(forKey: storedRevisionKey) + 1, forKey: storedRevisionKey)
        NotificationCenter.default.post(name: looprHeartZonesChanged, object: nil)
        if self === Self.shared {
            Task(priority: .utility) {
                await LooprMetricHistory.shared.rebuildZoneHistory()
                NotificationCenter.default.post(name: looprDerivedGenerationUpdated, object: nil)
            }
        }
    }

    func recordReliablePeak(_ samples: [ReliableHeartRateSample], age: Int?) {
        var settings = load()
        settings.observe(samples, age: age)
        save(settings)
    }
}
