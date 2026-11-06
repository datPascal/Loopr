import AnalyticsKit
import CoreGraphics
import Foundation

// LV-08b step 1: every marker Loopr knows as a star, in clusters by body system. A star's brightness says how
// recent its latest value is; its colour comes from `DataTrendRule` over its own history. A marker with no value
// is a dim outline, never left out, so the count in the header is the real count.

public struct DataStar: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let system: DataBodySystem
    public let source: DataMarkerSource
    /// The latest value with its unit. Nil when the marker has no value.
    public let latestText: String?
    public let latestDate: Date?
    /// Nil when absent, or when there is not enough history to compare.
    public let trend: DataTrend?
    /// 0 for an absent marker, else 0.3 to 1 by how recent the latest value is.
    public let brightness: Double
    /// How this star was compared, or why it was not.
    public let note: String

    public var isAbsent: Bool { latestDate == nil }

    public var spokenLabel: String {
        guard let latestText else { return "\(title), not measured" }
        return "\(title), \(latestText), \(trend?.title ?? "no comparison yet")"
    }
}

public struct DataStarCluster: Equatable, Sendable, Identifiable {
    public let system: DataBodySystem
    /// Measured stars first, brightest first, then the absent ones.
    public let stars: [DataStar]

    public var id: DataBodySystem { system }
    public var measuredCount: Int { stars.filter { !$0.isAbsent }.count }

    public func count(of trend: DataTrend) -> Int { stars.filter { $0.trend == trend }.count }

    /// "Cardiovascular, 16 markers, 9 measured: 3 improving, 5 steady, 1 changed."
    public var spokenLabel: String {
        var text = "\(system.title), \(DataText.count(stars.count, "marker", "markers")), \(measuredCount) measured"
        let trends = DataTrend.allCases.compactMap { trend -> String? in
            let count = count(of: trend)
            return count > 0 ? "\(count) \(trend.title)" : nil
        }
        if !trends.isEmpty { text += ": " + trends.joined(separator: ", ") }
        return text + "."
    }
}

public struct DataStarMap: Equatable, Sendable {
    /// Every body system with at least one marker, in `DataBodySystem` order.
    public let clusters: [DataStarCluster]

    /// Every marker, measured or not.
    public var count: Int { clusters.reduce(0) { $0 + $1.stars.count } }
    public var measuredCount: Int { clusters.reduce(0) { $0 + $1.measuredCount } }

    /// Says how the dots are coloured and where the lab's own range is, so it agrees with the Blood tests page, which
    /// keeps each lab's printed range (Data ICP R3-NEW-12).
    public static let labNote = "Each lab marker is coloured against your own earlier values. The range the lab printed is on the marker's page, beside its value."
    /// What "changed" means in the legend.
    public static let changedNote = "Changed: moved more than your usual spread, with no better or worse. Every lab marker is read this way."

    /// "56 markers Loopr can show. None measured yet."
    public static func emptyTitle(_ map: DataStarMap) -> String {
        "\(DataText.count(map.count, "marker", "markers")) Loopr can show. None measured yet."
    }

    public static let emptyBody = "Lab markers appear here after your first blood test, grouped by body system. Band and Apple Health values join them as they arrive. Type in a report or scan it with the camera."

    public var spokenSummary: String {
        "\(DataText.count(count, "marker", "markers")) by body system, \(measuredCount) measured. " +
            clusters.map(\.spokenLabel).joined(separator: " ")
    }
}

/// How a star is compared: daily metrics set the median of the last 30 days against the 90 days before them, with
/// at least 10 and 30 days of values; occasional values and lab values set the latest value against the median of the
/// earlier ones. Brightness falls from 1 for a value today to 0.3 for one a year old or older.
public enum DataStarMapRule {
    /// The catalog marker a lab star stands for: its id is "lab-" and the marker key.
    public static func labMarkerKey(_ star: DataStar) -> LabMarkerKey? {
        guard star.id.hasPrefix("lab-") else { return nil }
        return LabMarkerKey(rawValue: String(star.id.dropFirst(4)))
    }

    public static let recentDays = 30
    public static let earlierDays = 90
    public static let recentCoverage = 10
    public static let earlierCoverage = 30
    public static let dimmest = 0.3

    public static func make(_ series: [DataSeries], now: Date, calendar: Calendar) -> DataStarMap {
        let stars = series.map { star(for: $0, now: now, calendar: calendar) }
        let clusters = DataBodySystem.allCases.compactMap { system -> DataStarCluster? in
            let members = stars.filter { $0.system == system }
            guard !members.isEmpty else { return nil }
            let ordered = members.enumerated().sorted { lhs, rhs in
                (lhs.element.isAbsent ? 1 : 0, -lhs.element.brightness, lhs.offset)
                    < (rhs.element.isAbsent ? 1 : 0, -rhs.element.brightness, rhs.offset)
            }.map(\.element)
            return DataStarCluster(system: system, stars: ordered)
        }
        return DataStarMap(clusters: clusters)
    }

    public static func brightness(daysSince days: Int) -> Double {
        max(dimmest, 1 - Double(max(days, 0)) / 365)
    }

    static func star(for series: DataSeries, now: Date, calendar: Calendar) -> DataStar {
        guard let latest = series.latest else {
            return DataStar(id: series.id, title: series.title, system: series.system, source: series.source, latestText: nil,
                            latestDate: nil, trend: nil, brightness: 0, note: "Not measured yet.")
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: latest.date), to: calendar.startOfDay(for: now)).day ?? 0
        let (trend, note) = classify(series, latest: latest, now: now, calendar: calendar)
        return DataStar(id: series.id, title: series.title, system: series.system, source: series.source,
                        latestText: series.latestText ?? series.valueText(latest.value), latestDate: latest.date, trend: trend,
                        brightness: brightness(daysSince: days), note: note)
    }

    static func classify(_ series: DataSeries, latest: DataPoint, now: Date, calendar: Calendar) -> (DataTrend?, String) {
        switch series.cadence {
        case .daily:
            let today = calendar.startOfDay(for: now)
            guard let recentStart = calendar.date(byAdding: .day, value: -(recentDays - 1), to: today),
                  let earlierStart = calendar.date(byAdding: .day, value: -earlierDays, to: recentStart),
                  let end = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: today) else {
                return (nil, "Not enough days to compare yet.")
            }
            let recent = series.values(from: recentStart, through: end)
            let earlier = series.values(from: earlierStart, through: recentStart.addingTimeInterval(-1))
            guard recent.count >= recentCoverage, earlier.count >= earlierCoverage,
                  let later = DataTrendRule.median(recent), let before = DataTrendRule.median(earlier) else {
                return (nil, "Compares once it has \(recentCoverage) days in the last \(recentDays) and \(earlierCoverage) in the \(earlierDays) before.")
            }
            let band = DataTrendRule.band(earlier: earlier, floorShare: series.floorShare)
            let trend = DataTrendRule.classify(earlier: before, later: later, band: band, higherIsBetter: series.higherIsBetter)
            return (trend, "The last \(recentDays) days against the \(earlierDays) days before them.")
        case .occasional, .lab:
            let earlier = series.points.dropLast().map(\.value)
            guard let before = DataTrendRule.median(earlier) else {
                return (nil, series.cadence == .lab
                    ? "One value so far. The next blood test starts the comparison."
                    : "One value so far. The next one starts the comparison.")
            }
            let band = DataTrendRule.band(earlier: earlier, floorShare: series.floorShare)
            let trend = DataTrendRule.classify(earlier: before, later: latest.value, band: band, higherIsBetter: series.higherIsBetter)
            let lead = "Your latest value against the median of your \(DataText.count(earlier.count, "earlier value", "earlier values"))."
            return (trend, series.cadence == .lab ? lead + " " + DataStarMap.labNote : lead)
        }
    }

    /// Star centres in a unit disc, on a sunflower spiral: the first at the centre, each next one a golden angle on
    /// and a little further out, squashed to 80 % in height as on the contract.
    public static func positions(count: Int) -> [CGPoint] {
        guard count > 0 else { return [] }
        let golden = 137.5 * Double.pi / 180
        let outer = (Double(count) - 0.5).squareRoot()
        return (0..<count).map { index in
            let radius = count == 1 ? 0 : (Double(index) + 0.5).squareRoot() / max(outer, 1) * (index == 0 ? 0 : 1)
            let angle = Double(index) * golden
            return CGPoint(x: radius * cos(angle), y: radius * sin(angle) * 0.8)
        }
    }
}
