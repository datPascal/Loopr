import DesignSystem
import DomainKit
import Foundation
import SwiftUI

public extension HeartMetricID {
    /// The metric detail page this card opens, or nil when there is none.
    var metricLinkID: String? {
        switch self {
        case .restingHeartRate: LooprMetricLinkID.restingHeartRate
        case .rmssd: LooprMetricLinkID.rmssd
        case .sdnn: LooprMetricLinkID.sdnn
        case .pNN50: LooprMetricLinkID.pNN50
        case .respiration: LooprMetricLinkID.respiratoryRate
        case .heartRateDip: LooprMetricLinkID.heartRateDip
        case .sleepingHeartRate: LooprMetricLinkID.sleepingHeartRate
        case .maxHeartRate: LooprMetricLinkID.maxHeartRate
        case .frequencyDomain, .quality: nil
        }
    }
}

/// How one card compares today's value with the person's usual range.
/// Kept separate from the view so the wording can be tested.
public enum HeartBaselineComparison: Equatable, Sendable {
    case within
    case above(String)
    case below(String)
    case learning(measuredDays: Int, neededDays: Int)

    public static func make(
        value: Double?,
        unit: String,
        history: [LooprChartPoint],
        today: Date,
        decimals: Int = 0,
        calendar: Calendar = .current
    ) -> HeartBaselineComparison? {
        guard let value, value.isFinite else { return nil }
        guard let band = LooprBaselineBand.trailing(history, before: today, calendar: calendar) else {
            let end = calendar.startOfDay(for: today)
            let start = calendar.date(byAdding: .day, value: -LooprBaselineBand.windowDays, to: end) ?? end
            let measured = Set(history.filter { $0.date >= start && $0.date < end }.map { calendar.startOfDay(for: $0.date) }).count
            // The current metric value is a measured night too. Count it as
            // the detail page does, while the usual band still uses prior nights.
            return .learning(measuredDays: measured + 1, neededDays: LooprBaselineBand.minimumDays)
        }
        let delta = value - band.center
        let magnitude = decimals == 0 ? String(Int(abs(delta).rounded())) : String(format: "%.\(decimals)f", abs(delta))
        let text = unit.isEmpty ? magnitude : unit == "%" ? magnitude + unit : "\(magnitude) \(unit)"
        switch band.position(of: value) {
        case .within: return .within
        case .above: return .above(text)
        case .below: return .below(text)
        }
    }

    public var label: String {
        switch self {
        case .within: "Usual"
        case .above(let text): "+\(text) vs usual"
        case .below(let text): "−\(text) vs usual"
        case .learning(let measured, let needed): "Learning your usual · \(min(measured, needed)) of \(needed) nights"
        }
    }

    var symbol: String {
        switch self {
        case .within: "checkmark"
        case .above: "arrow.up.right"
        case .below: "arrow.down.right"
        case .learning: "hourglass"
        }
    }
}

/// One overnight measurement on Heart Detail: value, unit, a 30-day
/// sparkline, the comparison with the person's usual range, and a chevron
/// when it opens a detail page.
struct HeartDetailMetricCard: View {
    @Environment(\.looprMetricLink) private var metricLink
    @Environment(\.colorScheme) private var colorScheme
    @State private var history: [LooprChartPoint]?

    let metric: HeartMetricValue
    let day: DayIdentity

    static let sparklineDays = 30

    private var selectedDay: Date { HeartTrendCharts.endDate(for: day, calendar: .current) ?? Date() }

    private var linkID: String? {
        guard let id = metric.id.metricLinkID, let metricLink, metricLink.supports(id) else { return nil }
        return id
    }

    var body: some View {
        Group {
            if let linkID, let metricLink {
                Button { metricLink.open(linkID) } label: {
                    card(navigable: true).looprMetricZoomSource(linkID, cornerRadius: radius)
                }
                    .buttonStyle(.looprPressableCard)
            } else {
                card(navigable: false)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(linkID == nil ? "" : "Opens history and explanation")
        .accessibilityAddTraits(linkID == nil ? [] : .isButton)
        .accessibilityIdentifier("heart-detail-metric-\(metric.id.rawValue)")
        .task(id: day) {
            guard let linkID, let metricLink else { return }
            history = nil
            let days = Self.sparklineDays + LooprBaselineBand.windowDays
            if let historyEndingOn = metricLink.historyEndingOn {
                history = await historyEndingOn(linkID, days, selectedDay)
            } else {
                history = await metricLink.history(linkID, days)
            }
        }
    }

    private func card(navigable: Bool) -> some View {
        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xs) {
                Text(metric.id == .rmssd ? "HRV" : metric.title)
                    .looprTypography(.rowTitle)
                    .foregroundStyle(Color.loopr(.ink))
                Spacer(minLength: LooprSpacing.xs)
                if let confidence = metric.confidence, hasValue {
                    Text(confidence.uppercased())
                        .looprTypography(.confidence)
                        .foregroundStyle(Color.loopr(.inkSecondary))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .layoutPriority(-1)
                }
                if navigable {
                    LooprChevron()
                }
            }

            if hasValue, let value = metric.value {
                HStack(alignment: .bottom, spacing: LooprSpacing.md) {
                    VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                        HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xxs + 2) {
                            Text(value)
                                .looprTypography(.metric)
                                .foregroundStyle(Color.loopr(.ink))
                                .contentTransition(.numericText())
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            Text(metric.unit)
                                .looprTypography(.metricUnit)
                                .foregroundStyle(Color.loopr(.inkSecondary))
                        }
                        comparisonLine
                    }
                    .layoutPriority(1)
                    Spacer(minLength: 0)
                    sparkline
                        .frame(maxWidth: 150)
                }
            } else {
                StateMessage(metric.state, compact: true, accent: .heart)
            }
        }
        .padding(.vertical, isDark ? 15 : 16)
        .padding(.horizontal, isDark ? 17 : 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: LooprSpacing.interactiveRowHeight)
        .background(isDark ? Color.loopr(.surface) : Color.loopr(.sheetFill), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.loopr(.surfaceStroke), lineWidth: isDark ? 1 : 0)
                .allowsHitTesting(false)
        }
        .shadow(color: isDark ? .clear : Color.loopr(.ink).opacity(0.06), radius: 2, y: 1)
        .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    @ViewBuilder
    private var comparisonLine: some View {
        if let comparison {
            HStack(spacing: LooprSpacing.xxs + 1) {
                Image(systemName: comparison.symbol)
                    .looprTypography(.chip)
                    .foregroundStyle(Color.loopr(.heartChip))
                Text(comparison.label)
                    .looprTypography(.caption)
                    .foregroundStyle(Color.loopr(.inkSecondary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        } else if history == nil, linkID != nil {
            LooprSkeleton(height: 9)
                .frame(width: 96)
        }
    }

    @ViewBuilder
    private var sparkline: some View {
        if let history, !history.isEmpty {
            LooprSparkline(
                points: history,
                days: Self.sparklineDays,
                endingOn: selectedDay,
                accent: .heart,
                baseline: LooprBaselineBand.trailing(history, before: Calendar.current.startOfDay(for: selectedDay)),
                height: 44
            )
        } else if history == nil, linkID != nil {
            Color.clear.frame(height: 44)
        }
    }

    private var comparison: HeartBaselineComparison? {
        guard let history else { return nil }
        return HeartBaselineComparison.make(
            value: metric.numericValue ?? metric.value.flatMap(Double.init),
            unit: metric.unit,
            history: history,
            today: Calendar.current.startOfDay(for: selectedDay),
            decimals: metric.id == .respiration ? 1 : 0
        )
    }

    private var hasValue: Bool {
        guard let value = metric.value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && ![.loading, .noRecords, .absent, .disconnected, .bluetoothOff, .permissionDenied, .unsupportedHardware, .recoverableError, .destructiveFailure].contains(metric.state)
    }

    private var accessibilityLabel: String {
        var parts = [metric.id == .rmssd ? metric.accessibilitySummary.replacingOccurrences(of: "RMSSD", with: "HRV") : metric.accessibilitySummary]
        if let comparison { parts.append(comparison.label) }
        return parts.joined(separator: ", ")
    }

    private var isDark: Bool { LooprAppearance.isDark(colorScheme) }
    private var radius: CGFloat { isDark ? LooprRadius.compactCard : LooprRadius.card }
}

/// Heart Trends: resting heart rate and RMSSD on one shared range.
struct HeartTrendCharts: View {
    let day: DayIdentity
    @Environment(\.looprMetricLink) private var metricLink
    @State private var range: LooprChartRange = .month
    @State private var restingHistory: [LooprChartPoint] = []
    @State private var rmssdHistory: [LooprChartPoint] = []
    @State private var loaded = false

    static func endDate(for day: DayIdentity, calendar: Calendar) -> Date? {
        calendar.date(from: DateComponents(era: day.era, year: day.year, month: day.month, day: day.day, hour: 12))
    }

    private var endDate: Date { Self.endDate(for: day, calendar: .current) ?? Date() }

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            LooprRangePicker(selection: $range, accent: .heart, identifier: "heart-trends-range")
            card(
                title: HeartMetricID.restingHeartRate.title,
                id: LooprMetricLinkID.restingHeartRate,
                points: restingHistory,
                unit: "bpm",
                identifier: "heart-trends-resting"
            )
            card(
                title: HeartMetricID.rmssd.title,
                id: LooprMetricLinkID.rmssd,
                points: rmssdHistory,
                unit: "ms",
                identifier: "heart-trends-rmssd"
            )
        }
        .task(id: day) {
            guard let metricLink else { return }
            loaded = false
            async let resting = history(LooprMetricLinkID.restingHeartRate, from: metricLink)
            async let rmssd = history(LooprMetricLinkID.rmssd, from: metricLink)
            restingHistory = await resting
            rmssdHistory = await rmssd
            loaded = true
        }
    }

    private func history(_ id: String, from link: LooprMetricLink) async -> [LooprChartPoint] {
        if let historyEndingOn = link.historyEndingOn {
            return await historyEndingOn(id, 400, endDate)
        }
        return await link.history(id, 400)
    }

    @ViewBuilder
    private func card(title: String, id: String, points: [LooprChartPoint], unit: String, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            HStack {
                Text(title.uppercased())
                    .looprTypography(.sectionLabel)
                    .foregroundStyle(Color.loopr(.inkSecondary))
                Spacer()
                if let metricLink {
                    Button("Details") { metricLink.open(id) }
                        .looprTypography(.chip)
                        .foregroundStyle(Color.loopr(.heartChip))
                        .frame(minHeight: 32)
                        .accessibilityLabel("\(title) details")
                        .accessibilityIdentifier("\(identifier)-details")
                }
            }
            .padding(.horizontal, LooprSpacing.xxs)
            .padding(.top, LooprSpacing.xs)
            if loaded {
                LooprMetricTrendCard(
                    title: title,
                    points: points,
                    endingOn: endDate,
                    range: $range,
                    kind: .line,
                    accent: .heart,
                    unit: unit,
                    valueFormat: { String(Int($0.rounded())) },
                    baseline: LooprBaselineBand.trailing(points, before: Calendar.current.startOfDay(for: endDate)),
                    identifier: identifier,
                    showsRangePicker: false
                )
            } else {
                LooprSurface { LooprSkeleton(height: 220) }
            }
        }
    }
}
