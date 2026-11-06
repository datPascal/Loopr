import Foundation
import TrainKit

/// Recovery scores by local day, read from the same metric history Health and Today use.
///
/// The scheduler's early-light-week rule looks at the seven days before a week's first strength
/// day, which can be six days before today, so the window is 14 days.
nonisolated struct TrainRecoveryProvider: Sendable {
    static let windowDays = 14

    let history: any MetricHistoryProviding

    /// One reading per local day, oldest first. An unreadable history is the same as no history:
    /// the overview then says there is no reading instead of guessing.
    func readings(endingOn now: Date, calendar: Calendar) async -> [RecoveryReading] {
        let points = (try? await history.series(for: .recovery, days: Self.windowDays, endingOn: now)) ?? []
        return Self.readings(from: points, calendar: calendar)
    }

    static func readings(from points: [MetricHistoryPoint], calendar: Calendar) -> [RecoveryReading] {
        var byDay: [String: Double] = [:]
        for point in points where point.value.isFinite && (0...100).contains(point.value) {
            let parts = calendar.dateComponents([.year, .month, .day], from: point.day)
            guard let year = parts.year, let month = parts.month, let day = parts.day else { continue }
            byDay[String(format: "%04d-%02d-%02d", year, month, day)] = point.value
        }
        return byDay.keys.sorted().map { RecoveryReading(localDay: $0, score: byDay[$0] ?? 0) }
    }
}
