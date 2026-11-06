import AIKit
import DesignSystem
import SwiftUI

/// What the chart card draws, worked out from the saved snapshot and nothing else. The numbers are the
/// ones the app read. The model's text never reaches this type.
nonisolated enum AgentChartPlan {
    /// Daily bars beyond this many days get too thin to read, so the card draws a line instead.
    static let maxBarDays = 45

    enum Renderer: Equatable { case highlightBars, trendLine }

    static func renderer(for chart: AgentChartSnapshot) -> Renderer {
        chart.kind == .bars && spanDays(chart) <= maxBarDays ? .highlightBars : .trendLine
    }

    static func spanDays(_ chart: AgentChartSnapshot) -> Int {
        guard let first = chart.points.map(\.day).min(), let last = chart.points.map(\.day).max() else { return 0 }
        return AgentDays.count(from: first, to: last) ?? chart.points.count
    }

    /// The civil day as a date near noon in the person's calendar, which is what the chart axes read.
    static func date(_ day: String, calendar: Calendar = .current) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }

    /// One bar per calendar day from the first reading to the last. A day with no reading is a gap, never zero.
    static func bars(for chart: AgentChartSnapshot, calendar: Calendar = .current) -> [LooprHighlightBar] {
        guard let first = chart.points.map(\.day).min(), let last = chart.points.map(\.day).max() else { return [] }
        let values = Dictionary(chart.points.map { ($0.day, $0.value) }, uniquingKeysWith: { _, later in later })
        let marked = Set(chart.highlightedDays)
        return AgentDays.days(from: first, to: last).compactMap { day in
            date(day, calendar: calendar).map { LooprHighlightBar(date: $0, value: values[day], isHighlighted: marked.contains(day)) }
        }
    }

    static func linePoints(for chart: AgentChartSnapshot, calendar: Calendar = .current) -> [LooprChartPoint] {
        chart.points.compactMap { point in
            date(point.day, calendar: calendar).map { LooprChartPoint(date: $0, value: point.value) }
        }
    }

    /// The number reads in the person's locale, so a comma-decimal region sees "51,5 ms".
    static func valueText(_ value: Double, unit: String, locale: Locale = .current) -> String {
        let precision: NumberFormatStyleConfiguration.Precision = abs(value) >= 100 ? .fractionLength(0) : .fractionLength(0...1)
        let number = value.formatted(.number.precision(precision).grouping(.never).locale(locale))
        switch unit {
        case "": return number
        case "%": return number + "%"
        default: return number + " " + unit
        }
    }

    /// The latest reading, for the line under a trend chart.
    static func latest(of chart: AgentChartSnapshot) -> AgentChartPoint? { chart.points.max { $0.day < $1.day } }

    static func accent(for chart: AgentChartSnapshot) -> LooprColorToken {
        switch chart.domain {
        case .food: return .energy
        case .training: return .movement
        case .cycle: return .cycle
        case .journalAnswers, .journalNotes, .supplements, .labs: return .brand
        case .metrics:
            // Ids read "metric.<key>.<from>.<to>".
            let key = chart.id.split(separator: ".").dropFirst().first.map(String.init) ?? ""
            if key.localizedCaseInsensitiveContains("sleep") { return .sleep }
            switch key {
            case "rmssd", "sdnn", "pNN50": return .heart
            case "recovery": return .recovery
            case "strain": return .strain
            case "steps", "vo2Max": return .movement
            case "stress": return .stress
            default: return key.localizedCaseInsensitiveContains("heart") ? .heart : .brand
            }
        }
    }
}

/// An inline chart under an answer. Daily totals draw as bars with the highlighted days brighter, and a
/// reading that moves draws as a line. It draws the saved snapshot, so it is the same after a relaunch.
struct AgentChartCard: View {
    let chart: AgentChartSnapshot
    @State private var selectedDate: Date?

    private var accent: LooprColorToken { AgentChartPlan.accent(for: chart) }
    private var format: @Sendable (Double) -> String {
        let unit = chart.unit
        return { AgentChartPlan.valueText($0, unit: unit) }
    }

    var body: some View {
        LooprCard {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                LooprSectionHeader(chart.title, detail: chart.caption, accent: accent)
                switch AgentChartPlan.renderer(for: chart) {
                case .highlightBars:
                    LooprHighlightBars(bars: AgentChartPlan.bars(for: chart), accent: accent, title: chart.title,
                                       valueFormat: format, identifier: "agent-chart-bars")
                case .trendLine:
                    trend
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-chart-card")
    }

    @ViewBuilder private var trend: some View {
        let points = AgentChartPlan.linePoints(for: chart)
        if let last = points.map(\.date).max() {
            let series = LooprChartSeries.prepare(points, window: LooprChartWindow(dayCount: max(AgentChartPlan.spanDays(chart), 2)),
                                                  endingOn: last, kind: .line)
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                LooprMetricTrendChart(series: series, kind: .line, accent: accent, title: chart.title, unit: chart.unit,
                                      valueFormat: format, selectedDate: $selectedDate, height: 150)
                LooprText(readout(points: points), style: .headerMeta, color: .inkSecondary)
                    .accessibilityHidden(true)
            }
        }
    }

    private func readout(points: [LooprChartPoint]) -> String {
        let shown = selectedDate.flatMap { target in
            points.min { abs($0.date.timeIntervalSince(target)) < abs($1.date.timeIntervalSince(target)) }
        } ?? points.max { $0.date < $1.date }
        guard let shown else { return "" }
        let day = shown.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)).looprLabelCased
        return "\(day) · \(AgentChartPlan.valueText(shown.value, unit: chart.unit))"
    }
}
