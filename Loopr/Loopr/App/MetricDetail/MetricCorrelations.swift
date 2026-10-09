import DesignSystem
import Foundation

/// One other metric that rises and falls with the metric on screen.
nonisolated struct MetricCorrelation: Hashable, Sendable, Identifiable {
    let other: MetricKey
    /// Pearson correlation coefficient, -1 to 1.
    let r: Double
    /// Days where both metrics have a reading.
    let pairedDays: Int

    var id: MetricKey { other }
}

/// "What moves with this": which of the person's other metrics went up and
/// down together with this one over the days on screen.
///
/// Pearson's r over days where both metrics have a reading. A link is shown
/// only when |r| is at least 0.3 and there are at least 10 such days, the
/// five strongest first. Two metrics that are the same measurement in
/// another form (RMSSD, SDNN and pNN50 all read beat-to-beat variation) are
/// left out: of course they move together, and saying so teaches nothing.
///
/// The page says plainly that this is about moving together, not cause.
nonisolated enum MetricCorrelations {
    static let minimumStrength = 0.3
    static let minimumPairedDays = 10
    static let maximumResults = 5

    /// DEC-05 permits temperature comparisons; oxygen stays import-only.
    /// this new comparison section does not introduce links to either.
    static func canCompare(_ key: MetricKey) -> Bool {
        key != .oxygenSaturation
    }

    /// Groups of metrics that measure the same thing.
    static let sameMeasurement: [Set<MetricKey>] = [
        [.rmssd, .sdnn, .pNN50],
        [.restingHeartRate, .sleepingHeartRate]
    ]

    static func isSameMeasurement(_ a: MetricKey, _ b: MetricKey) -> Bool {
        a == b || sameMeasurement.contains { $0.contains(a) && $0.contains(b) }
    }

    /// Pearson's r for paired values, or nil for fewer than 2 pairs, a
    /// non-finite value, or a series that never changes.
    static func pearson(_ pairs: [(Double, Double)]) -> Double? {
        let clean = pairs.filter { $0.0.isFinite && $0.1.isFinite }
        guard clean.count >= 2, clean.count == pairs.count else { return nil }
        let n = Double(clean.count)
        let meanX = clean.reduce(0) { $0 + $1.0 } / n
        let meanY = clean.reduce(0) { $0 + $1.1 } / n
        var covariance = 0.0
        var varianceX = 0.0
        var varianceY = 0.0
        for (x, y) in clean {
            let dx = x - meanX
            let dy = y - meanY
            covariance += dx * dy
            varianceX += dx * dx
            varianceY += dy * dy
        }
        guard varianceX > 0, varianceY > 0 else { return nil }
        return min(max(covariance / (varianceX.squareRoot() * varianceY.squareRoot()), -1), 1)
    }

    /// One value per local day.
    static func daily(_ points: [MetricHistoryPoint], calendar: Calendar = .current) -> [Date: Double] {
        var result: [Date: Double] = [:]
        for point in points where point.value.isFinite {
            result[calendar.startOfDay(for: point.day)] = point.value
        }
        return result
    }

    /// The days a range shows, ending on `anchor`.
    static func window(_ range: LooprChartRange, anchor: Date, calendar: Calendar = .current) -> ClosedRange<Date> {
        let last = calendar.startOfDay(for: anchor)
        let first = calendar.date(byAdding: .day, value: -(range.dayCount - 1), to: last) ?? last
        return first...last
    }

    /// Days with a reading of `target` inside the window.
    static func measuredDays(_ target: [Date: Double], in window: ClosedRange<Date>) -> Int {
        target.keys.filter { window.contains($0) }.count
    }

    /// The links worth showing, strongest first.
    static func rank(
        target key: MetricKey,
        values target: [Date: Double],
        others: [MetricKey: [Date: Double]],
        window: ClosedRange<Date>
    ) -> [MetricCorrelation] {
        let days = target.filter { window.contains($0.key) }
        guard canCompare(key), days.count >= minimumPairedDays else { return [] }
        var found: [MetricCorrelation] = []
        for (other, series) in others where canCompare(other) && !isSameMeasurement(key, other) {
            let pairs = days.compactMap { day, value in series[day].map { (value, $0) } }
            guard pairs.count >= minimumPairedDays, let r = pearson(pairs), abs(r) >= minimumStrength else { continue }
            found.append(MetricCorrelation(other: other, r: r, pairedDays: pairs.count))
        }
        return Array(found.sorted {
            abs($0.r) != abs($1.r) ? abs($0.r) > abs($1.r) : $0.other.rawValue < $1.other.rawValue
        }.prefix(maximumResults))
    }

    // MARK: Loading, off the main actor

    /// Reads every other metric's history once for a page.
    @concurrent
    static func loadOthers(
        for key: MetricKey,
        provider: any MetricHistoryProviding,
        days: Int,
        endingOn: Date,
        calendar: Calendar = .current
    ) async -> [MetricKey: [Date: Double]] {
        var result: [MetricKey: [Date: Double]] = [:]
        for other in MetricKey.allCases where canCompare(other) && !isSameMeasurement(key, other) {
            if Task.isCancelled { return result }
            let points = (try? await provider.series(for: other, days: days, endingOn: endingOn)) ?? []
            let values = daily(points, calendar: calendar)
            if values.count >= minimumPairedDays { result[other] = values }
        }
        return result
    }

    @concurrent
    static func rankOffMain(
        target key: MetricKey,
        values: [Date: Double],
        others: [MetricKey: [Date: Double]],
        window: ClosedRange<Date>
    ) async -> [MetricCorrelation] {
        rank(target: key, values: values, others: others, window: window)
    }

    // MARK: Words

    /// "Strong link", "Clear link" or "Loose link".
    static func strength(_ r: Double) -> String {
        switch abs(r) {
        case 0.7...: "Strong link"
        case 0.5..<0.7: "Clear link"
        default: "Loose link"
        }
    }

    /// "When you sleep longer, your HRV tends to be higher."
    static func sentence(_ correlation: MetricCorrelation, target: MetricKey) -> String {
        "When \(rising(correlation.other)), \(outcome(target, up: correlation.r > 0))."
    }

    /// The metric on screen moving, said the way people say it:
    /// "your HRV tends to be higher", "you tend to walk less".
    static func outcome(_ key: MetricKey, up: Bool) -> String {
        switch key {
        case .steps: up ? "you tend to walk more" : "you tend to walk less"
        case .sleepDuration: up ? "you tend to sleep longer" : "you tend to sleep less"
        default: "\(subject(key)) tends to be \(up ? "higher" : "lower")"
        }
    }

    /// "Clear link · r = 0.54 · 38 days"
    static func caption(_ correlation: MetricCorrelation) -> String {
        "\(strength(correlation.r)) · r = \(signed(correlation.r)) · \(correlation.pairedDays) days"
    }

    static func spoken(_ correlation: MetricCorrelation, target: MetricKey) -> String {
        "\(correlation.other.presentation.title). \(sentence(correlation, target: target)) \(strength(correlation.r)), across \(correlation.pairedDays) days."
    }

    static func signed(_ r: Double) -> String {
        let text = String(format: "%.2f", abs(r))
        return r < 0 ? LooprUnitFormatter.minusSign + text : text
    }

    /// The metric as the subject of a sentence: "your HRV".
    static func subject(_ key: MetricKey) -> String {
        "your \(name(key))"
    }

    /// The metric going up, said the way people say it.
    static func rising(_ key: MetricKey) -> String {
        switch key {
        case .sleepDuration: "you sleep longer"
        case .deepSleep: "you get more deep sleep"
        case .remSleep: "you get more REM sleep"
        case .steps: "you walk more"
        case .activeEnergy: "you burn more active energy"
        default: "\(subject(key)) is higher"
        }
    }

    /// Lower-case name for use inside a sentence; abbreviations keep their case.
    static func name(_ key: MetricKey) -> String {
        let title = key.presentation.title
        switch key {
        case .rmssd, .sdnn, .pNN50, .vo2Max: return title
        case .remSleep: return "REM sleep"
        default: return title.prefix(1).lowercased() + title.dropFirst()
        }
    }
}
