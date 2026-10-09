import AnalyticsKit
import Foundation

/// Hour-sized date bins keep scored bars visible on the time axis.
/// Only measured hours become score bars; activity is rendered separately.
enum HourlyStressChartModel {
    static let xUnit: Calendar.Component = .hour

    struct Bar: Identifiable, Equatable {
        let start: Date
        let end: Date
        let score: Double
        var id: Date { start }
    }

    static func scoredBars(in day: HourlyStressDay) -> [Bar] {
        day.hours.compactMap { hour in
            guard let score = hour.score else { return nil }
            return Bar(start: hour.feature.start, end: hour.feature.end, score: score)
        }
    }
}
