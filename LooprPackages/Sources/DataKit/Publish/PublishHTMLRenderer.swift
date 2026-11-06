import DesignSystem
import Foundation

/// Writes the dashboard as one self-contained HTML file: inline CSS, inline SVG sparklines, no script, no
/// font, image, link or address. The only text the file holds about a metric is what the person picked.
public enum PublishHTMLRenderer {
    public static let fileName = "loopr-dashboard.html"

    static let sparklineWidth = 240.0
    static let sparklineHeight = 56.0
    static let sparklinePadding = 4.0

    public static func render(_ dashboard: PublishDashboard) -> String {
        var html = """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light dark">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
        <title>Loopr dashboard</title>
        <style>
        \(css)
        </style>
        </head>
        <body>
        <main>
        <header>
        <h1>Loopr dashboard</h1>
        <p class="period">\(escape(periodLine(dashboard)))</p>
        </header>

        """
        if dashboard.metrics.isEmpty {
            html += "<p class=\"empty\">No metrics were picked for this page.</p>\n"
        } else {
            html += "<div class=\"grid\">\n"
            for metric in dashboard.metrics { html += card(metric, range: dashboard.period) }
            html += "</div>\n"
        }
        html += """
        <footer>
        <p>Made with Loopr. Exported \(escape(longDate(dashboard.exportedAt, timeZone: dashboard.timeZone))).</p>
        <p>\(LooprMedicalLine.text)</p>
        </footer>
        </main>
        </body>
        </html>

        """
        return html
    }

    // MARK: Cards

    private static func card(_ metric: PublishMetricSeries, range: PublishPeriodRange) -> String {
        let unit = metric.unit.isEmpty ? "" : " <span class=\"unit\">\(escape(metric.unit))</span>"
        var html = "<article class=\"card\" data-metric=\"\(escape(metric.key))\">\n"
        html += "<h2>\(escape(metric.name))</h2>\n"
        if let latest = metric.latest, metric.group == .bloodTests {
            // A blood value is a draw, not a daily reading: its day and how many draws, no average (ICP R3-LAB-10).
            html += "<p class=\"latest\"><span class=\"value\">\(formatted(latest.value))</span>\(unit)</p>\n"
            html += "<p class=\"caption\">Drawn \(escape(shortDate(latest.date)))</p>\n"
            if metric.values.count > 1 {
                let earlier = metric.values.dropLast().map { "\(formatted($0.value)) on \(shortDate($0.date))" }.joined(separator: ", ")
                html += "<p class=\"average\">Earlier draws: \(escape(earlier))</p>\n"
                html += sparkline(metric, range: range)
            }
        } else if let latest = metric.latest, let average = metric.average {
            // Minutes read as hours and minutes, as Today shows sleep: "7 h 42 min", not "462 min" (ICP R3-UPG-16).
            let minutes = metric.unit == "min"
            let shownUnit = minutes ? "" : unit
            func value(_ number: Double) -> String { minutes ? hoursAndMinutes(number) : formatted(number) }
            html += "<p class=\"latest\"><span class=\"value\">\(value(latest.value))</span>\(shownUnit)</p>\n"
            html += "<p class=\"caption\">Latest, \(escape(shortDate(latest.date)))</p>\n"
            html += "<p class=\"average\">Average <strong>\(value(average))</strong>\(shownUnit) over \(metric.values.count) \(metric.values.count == 1 ? "day" : "days") with a reading</p>\n"
            html += sparkline(metric, range: range)
        } else {
            html += "<p class=\"caption\">No readings in this period.</p>\n"
        }
        html += "<p class=\"source\">Source: \(escape(metric.source))</p>\n"
        html += "</article>\n"
        return html
    }

    /// The sparkline. Days without a reading are gaps on the time axis: a line joins two readings only when
    /// they are at most three days apart, except for blood tests, which are weeks apart by nature.
    static func sparkline(_ metric: PublishMetricSeries, range: PublishPeriodRange) -> String {
        let points = positions(metric, range: range)
        guard !points.isEmpty else { return "" }
        let joinsAcrossGaps = metric.group == .bloodTests
        var segments: [[(x: Double, y: Double, day: Int)]] = []
        for point in points {
            if let last = segments.last?.last, joinsAcrossGaps || point.day - last.day <= 3 {
                segments[segments.count - 1].append(point)
            } else {
                segments.append([point])
            }
        }
        let low = metric.values.map(\.value).min() ?? 0
        let high = metric.values.map(\.value).max() ?? 0
        let label = "Sparkline of \(metric.values.count) daily \(metric.values.count == 1 ? "reading" : "readings"), lowest \(formatted(low)), highest \(formatted(high))"
        var svg = "<svg class=\"spark\" viewBox=\"0 0 \(Int(sparklineWidth)) \(Int(sparklineHeight))\" role=\"img\" aria-label=\"\(escape(label))\">\n"
        for segment in segments where segment.count > 1 {
            let list = segment.map { "\(coordinate($0.x)),\(coordinate($0.y))" }.joined(separator: " ")
            svg += "<polyline points=\"\(list)\"/>\n"
        }
        if let last = points.last {
            svg += "<circle cx=\"\(coordinate(last.x))\" cy=\"\(coordinate(last.y))\" r=\"2.5\"/>\n"
        }
        for segment in segments where segment.count == 1 {
            guard let only = segment.first, only.day != points.last?.day else { continue }
            svg += "<circle cx=\"\(coordinate(only.x))\" cy=\"\(coordinate(only.y))\" r=\"1.8\"/>\n"
        }
        svg += "</svg>\n"
        return svg
    }

    private static func positions(_ metric: PublishMetricSeries, range: PublishPeriodRange) -> [(x: Double, y: Double, day: Int)] {
        guard let first = PublishDay.ordinal(range.from) else { return [] }
        let span = Double(max(range.days - 1, 1))
        let low = metric.values.map(\.value).min() ?? 0
        let high = metric.values.map(\.value).max() ?? 0
        let width = sparklineWidth - 2 * sparklinePadding
        let height = sparklineHeight - 2 * sparklinePadding
        return metric.values.compactMap { entry in
            guard let ordinal = PublishDay.ordinal(entry.date) else { return nil }
            let offset = Double(min(max(ordinal - first, 0), range.days - 1))
            let x = sparklinePadding + offset / span * width
            let y = high > low
                ? sparklinePadding + (1 - (entry.value - low) / (high - low)) * height
                : sparklineHeight / 2
            return (x, y, ordinal)
        }
    }

    private static func coordinate(_ value: Double) -> String { String(format: "%.1f", value) }

    // MARK: Text

    /// "7 h 42 min" for 462 minutes, "45 min" under an hour.
    static func hoursAndMinutes(_ minutes: Double) -> String {
        let total = Int(minutes.rounded())
        guard total >= 60 else { return "\(total) min" }
        return total % 60 == 0 ? "\(total / 60) h" : "\(total / 60) h \(total % 60) min"
    }

    /// A number with up to three decimals for small values and one for large ones, no trailing zeros, dot notation.
    static func formatted(_ value: Double) -> String {
        let places = abs(value) >= 100 ? 0 : abs(value) >= 10 ? 1 : abs(value) >= 1 ? 2 : 3
        var text = String(format: "%.\(places)f", value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text == "-0" ? "0" : text
    }

    private static func periodLine(_ dashboard: PublishDashboard) -> String {
        let days = dashboard.period.days
        let title: String
        switch dashboard.period.id {
        case PublishPeriod.months12.rawValue: title = "Last 12 months"
        default: title = "Last \(days) days"
        }
        return "\(title), \(shortDate(dashboard.period.from, withYear: true)) to \(shortDate(dashboard.period.through, withYear: true))"
    }

    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// "24 Oct" or "24 Oct 2026" from a `yyyy-MM-dd` label. A label that is not a date comes back unchanged.
    static func shortDate(_ label: String, withYear: Bool = false) -> String {
        let parts = label.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]) else { return label }
        return withYear ? "\(parts[2]) \(months[parts[1] - 1]) \(parts[0])" : "\(parts[2]) \(months[parts[1] - 1])"
    }

    private static func longDate(_ date: Date, timeZone identifier: String) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier) ?? TimeZone(secondsFromGMT: 0) ?? .current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return shortDate(PublishDay.label(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1), withYear: true)
    }

    static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            default: result.append(character)
            }
        }
        return result
    }

    // MARK: Style

    private static let css = """
    :root { color-scheme: light dark; --bg: #f5f6f8; --card: #ffffff; --ink: #1b1d22; --muted: #565b63; --line: #0b57d0; --rule: #dfe2e7; }
    @media (prefers-color-scheme: dark) { :root { --bg: #101114; --card: #1a1c21; --ink: #f2f3f5; --muted: #a9aeb7; --line: #8ab4ff; --rule: #2c2f36; } }
    * { box-sizing: border-box; }
    body { margin: 0; background: var(--bg); color: var(--ink); font: 16px/1.45 system-ui, -apple-system, "Segoe UI", sans-serif; }
    main { max-width: 960px; margin: 0 auto; padding: 24px 16px 40px; }
    h1 { margin: 0; font-size: 1.6rem; }
    h2 { margin: 0 0 8px; font-size: 1rem; font-weight: 600; }
    p { margin: 0; }
    .period { margin-top: 4px; color: var(--muted); }
    .grid { display: grid; gap: 16px; margin-top: 24px; grid-template-columns: repeat(auto-fill, minmax(260px, 1fr)); }
    .card { background: var(--card); border: 1px solid var(--rule); border-radius: 14px; padding: 16px; }
    .latest { font-size: 2rem; font-weight: 600; line-height: 1.1; }
    .unit { font-size: 0.9rem; font-weight: 400; color: var(--muted); }
    .caption, .source { color: var(--muted); font-size: 0.85rem; }
    .average { margin-top: 8px; font-size: 0.9rem; }
    .spark { display: block; width: 100%; height: auto; margin: 12px 0; }
    .spark polyline { fill: none; stroke: var(--line); stroke-width: 2; stroke-linejoin: round; stroke-linecap: round; }
    .spark circle { fill: var(--line); }
    .empty { margin-top: 24px; color: var(--muted); }
    footer { margin-top: 32px; padding-top: 16px; border-top: 1px solid var(--rule); color: var(--muted); font-size: 0.85rem; }
    """
}
