import Foundation
import StorageKit

/// Decodes workout times without allocating their per-second samples. A saved
/// or removed workout invalidates daily generations even without a new strap
/// second, so a manually logged session can never remain in the quiet baseline.
nonisolated enum HourlyStressWorkoutMask {
    static let revisionKey = "com.loopr.hourly-stress.workout-revision"

    struct Header: Codable, Equatable, Sendable {
        let startedAt: Date?
        let endedAt: Date?
        let state: String

        var interval: DateInterval? {
            guard state == "completed", let startedAt, let endedAt, endedAt > startedAt else { return nil }
            return DateInterval(start: startedAt, end: endedAt)
        }
    }

    static func intervals(in store: StorageDocumentStore, start: Date, end: Date) throws -> [DateInterval] {
        try store.keys().filter { $0.hasPrefix("workout.") }.compactMap { key in
            guard let header = try store.read(Header.self, key: key), let interval = header.interval,
                  interval.end > start, interval.start < end else { return nil }
            return interval
        }
    }

    static func changed() {
        let defaults = UserDefaults.standard
        defaults.set(defaults.integer(forKey: revisionKey) + 1, forKey: revisionKey)
    }
}
