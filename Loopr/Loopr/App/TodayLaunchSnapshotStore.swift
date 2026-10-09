import DomainKit
import Foundation
import TodayKit

/// Legacy launch snapshot storage. Older builds used it to prefill Today;
/// scores can revise later that day, so current builds wait for a fresh read.
/// Keep the key in the owned-data list so Delete all Loopr data clears old
/// snapshots too.
///
/// Only a summary for the current day is ever shown. After midnight the
/// stored summary belongs to yesterday and is ignored, so Today never
/// presents an old day's numbers as today's. The key is listed in
/// `ProductRepositoryKeys.allOwnedDefaultsKeys`, so deleting all Loopr data
/// removes it too.
nonisolated struct TodayLaunchSnapshotStore {
    static let key = "loopr.today.launch-snapshot.v1"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func read(for day: DayIdentity) -> TodaySummary? {
        guard let data = defaults.data(forKey: Self.key),
              let summary = try? JSONDecoder().decode(TodaySummary.self, from: data),
              summary.day == day else { return nil }
        return summary
    }

    func write(_ summary: TodaySummary) {
        guard let data = try? JSONEncoder().encode(summary) else { return }
        defaults.set(data, forKey: Self.key)
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
    }

    /// Mirrors what Today now shows. A finished load that found nothing
    /// clears the snapshot; a load still in flight or one that failed leaves
    /// the last good summary alone.
    func record(summary: TodaySummary?, loadState: TodayLoadState) {
        if let summary {
            write(summary)
        } else if loadState == .loaded {
            clear()
        }
    }
}
