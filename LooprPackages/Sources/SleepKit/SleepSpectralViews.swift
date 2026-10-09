import Foundation
import SwiftUI
import DesignSystem

struct SleepMetricList: View {
    @Environment(\.looprMetricLink) private var metricLink
    let metrics: [SleepMetricValue]

    /// Every row is built from the metric's own title and unit, so a kind the
    /// derivation adds later needs no case here to render correctly.
    static func row(_ metric: SleepMetricValue) -> HairlineMetricRow {
        row(metric, action: nil)
    }

    static func row(_ metric: SleepMetricValue, action: (() -> Void)?, showsDisclosure: Bool = false) -> HairlineMetricRow {
        HairlineMetricRow(
            id: metric.id,
            title: metric.title,
            confidence: metric.confidence ?? metric.state.title,
            value: metric.value ?? "",
            unit: metric.value == nil || metric.unit.isEmpty ? nil : metric.unit,
            accent: metric.confidenceIndicatesCount ? .sleep : nil,
            showsDisclosure: showsDisclosure,
            action: action
        )
    }

    /// The metric detail page each sleep row opens, keyed by the row id the
    /// derivation writes.
    static func metricLinkID(for id: String) -> String? {
        switch id {
        case "duration": LooprMetricLinkID.sleepDuration
        case "efficiency": LooprMetricLinkID.sleepEfficiency
        case "deep": LooprMetricLinkID.deepSleep
        case "rem": LooprMetricLinkID.remSleep
        case "regularity": LooprMetricLinkID.sleepConsistency
        default: nil
        }
    }

    var body: some View {
        SleepHairlineList(metrics) { metric in
            if let open = openAction(for: metric) {
                Button(action: open) {
                    Self.row(metric, action: nil, showsDisclosure: true)
                        .looprMetricZoomSource(Self.metricLinkID(for: metric.id) ?? metric.id, cornerRadius: 0)
                }
                .buttonStyle(.looprPressableRow)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(metric.accessibilitySummary)
                .accessibilityHint("Opens history and explanation")
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("sleep-metric-\(metric.id)")
            } else {
                Self.row(metric)
                    .accessibilityIdentifier("sleep-metric-\(metric.id)")
                    .accessibilityLabel(metric.accessibilitySummary)
            }
        }
    }

    private func openAction(for metric: SleepMetricValue) -> (() -> Void)? {
        guard let id = Self.metricLinkID(for: metric.id), let metricLink, metricLink.supports(id) else { return nil }
        return { metricLink.open(id) }
    }
}

struct SleepNapList: View {
    let naps: [SleepSessionSummary]

    static func row(_ nap: SleepSessionSummary) -> HairlineMetricRow {
        HairlineMetricRow(
            id: "sleep-nap-\(nap.id)",
            title: "Nap at \(nap.start.formatted(date: .omitted, time: .shortened))",
            confidence: nap.state.title,
            value: nap.durationLabel
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.md) {
            LooprText("NAPS", style: .sectionLabel, color: .inkSecondary)
                .padding(.leading, LooprSpacing.xxs)
            SleepHairlineList(naps) { nap in
                Self.row(nap)
                    .accessibilityIdentifier("sleep-nap-\(nap.id)")
                    .accessibilityLabel("Nap at \(nap.start.formatted(date: .omitted, time: .shortened)), \(nap.durationLabel), \(nap.state.title)")
            }
        }
    }
}

struct SleepNavigationItem: Identifiable {
    let id: String
    let title: String
    let detail: String?
    let accessibilityLabel: String
    let action: () -> Void
}

struct SleepNavigationRow: View {
    let item: SleepNavigationItem

    var body: some View {
        Button(action: item.action) {
            HStack(alignment: .center, spacing: LooprSpacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .looprTypography(.rowTitle)
                        .foregroundStyle(Color.loopr(.ink))
                    if let detail = item.detail {
                        Text(detail)
                            .looprTypography(.caption)
                            .foregroundStyle(Color.loopr(.inkSecondary))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .layoutPriority(1)
                Spacer(minLength: LooprSpacing.sm)
                LooprChevron()
            }
            .padding(.vertical, LooprSpacing.metricRowVertical)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.looprPressableRow)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.accessibilityLabel)
        .accessibilityIdentifier(item.id)
    }
}

/// A local variant keeps the existing row identifiers and supports the
/// hypnogram preview inside its navigable row.
struct SleepHairlineList<Item: Identifiable, RowContent: View>: View {
    let items: [Item]
    private let rowContent: (Item) -> RowContent

    init(_ items: [Item], @ViewBuilder rowContent: @escaping (Item) -> RowContent) {
        self.items = items
        self.rowContent = rowContent
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                rowContent(item)
                if index < items.count - 1 {
                    Rectangle()
                        .fill(Color.loopr(.divider))
                        .frame(height: 1)
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.horizontal, LooprSpacing.cardHorizontal)
        .looprCardBackground()
    }
}

enum SleepDateFormatting {
    /// The header line without a shared day. A day's night runs from the
    /// evening before into the morning of that day, so the night is the
    /// previous day and the day itself. It used to name the day and the next
    /// one, which on Thursday morning read "Thu 24 → Fri 25": a night that
    /// had not happened yet.
    ///
    /// "Last night" only when the day is `today`.
    static func nightMeta(for snapshot: SleepDaySnapshot, today: Date = Date(),
                          calendar base: Calendar = .autoupdatingCurrent) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = base.timeZone
        let day = LooprDay(year: snapshot.day.year, month: snapshot.day.month, day: snapshot.day.day)
        let current = LooprDay(date: today, calendar: calendar)
        let range = LooprDayLabel.nightRange(for: day, today: current, calendar: calendar)
        return (day == current ? "Last night · \(range)" : range).uppercased()
    }
}

extension SleepMetricValue {
    var confidenceIndicatesCount: Bool {
        confidence?.contains(where: { $0.isNumber }) == true
    }
}
