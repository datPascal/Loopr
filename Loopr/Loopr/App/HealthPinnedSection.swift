import DesignSystem
import SwiftUI

struct HealthPinnedSection: View {
    @Environment(\.healthMetricPins) private var pins
    @Environment(\.metricHistoryProvider) private var provider
    @Environment(\.looprMetricLink) private var metricLink
    @Environment(\.looprDaySelection) private var day
    @State private var model = HealthMetricsModel()
    @State private var editing = false
    var excluding: [MetricKey] = []
    var identifier = "health-pinned"
    /// The most rows to show. Today keeps its pinned card short. Nil shows every pin.
    var limit: Int? = nil
    /// Opens the full pinned list. With a limit, a card that hides pins ends with a row that calls this.
    var showAll: (() -> Void)? = nil
    private var allKeys: [MetricKey] { (pins?.metrics ?? HealthMetricPins.defaults).filter { !excluding.contains($0) } }
    private var keys: [MetricKey] { limit.map { Array(allKeys.prefix($0)) } ?? allKeys }

    /// "All 7 pinned numbers" when a card of `limit` rows leaves some of `total` pins out. Nil otherwise.
    static func showAllTitle(total: Int, limit: Int?) -> String? {
        guard let limit, total > limit else { return nil }
        return "All \(total) pinned numbers"
    }

    private var showAllRow: AnyView? {
        guard let showAll, let title = Self.showAllTitle(total: allKeys.count, limit: limit) else { return nil }
        return AnyView(
            Button(action: showAll) {
                LooprRow(title: title, symbol: nil) { LooprChevron() }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.looprPressableRow)
            .accessibilityIdentifier("\(identifier)-all")
        )
    }
    private var anchor: MetricDetailAnchor {
        MetricDetailAnchor(selectedDay: day.map { LooprDays.looprDay($0.day) },
            today: day.map { LooprDays.looprDay($0.today) }, calendar: .current)
    }
    /// The value and unit a Data row shows. Skin temperature is a change: "No change" or "+0.3 °C vs usual".
    static func valueText(_ key: MetricKey, reading: HealthMetricReading) -> (value: String?, unit: String) {
        let deviation = key == .skinTemperatureDeviation
        let unchanged = deviation && reading.value.map { abs($0) < 0.05 } == true
        if unchanged { return ("No change", "") }
        if deviation { return (reading.value.map { LooprSignedNumber.text($0, fractionDigits: 1) }, "°C vs usual") }
        return (reading.formatted, key == .steps ? "" : key.presentation.unit)
    }

    /// One metric as a row against its usual range. Pinned, Recovery's "Last night" and the area pages all build their
    /// rows here, so a number reads the same on every Data screen (Data ICP R1-NEW-09, R1-SW-04).
    static func row(_ key: MetricKey, reading: HealthMetricReading, identifier: String, title: String? = nil,
                    open: @escaping () -> Void) -> LooprContributorRow {
        // Skin temperature is a change from the band's baseline, so it carries its sign and "vs usual", as
        // the year card does. "0.0 °C" read as a body temperature (ICP R2-OPT-27, R3-OPT-13).
        // A change that rounds to 0.0 reads "No change", not "0.0 °C vs usual" (UX R2-VET-22, R2-DES-23).
        let shown = valueText(key, reading: reading)
        return LooprContributorRow(title: title ?? (key == .steps ? "Steps" : key.presentation.title),
            value: shown.value, unit: shown.unit, comparison: reading.comparison.map(DataAreaTileContent.words),
            range: [.steps, .sleepConsistency].contains(key) ? nil : reading.range,
            status: reading.state == .recoverableError ? MetricState.recoverableError.title : nil,
            accent: key.presentation.accent, identifier: "\(identifier)-\(key.rawValue)", action: open)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Pinned", detail: "Compared with your usual range", actionTitle: "Edit", identifier: identifier) { editing = true }
            if keys.isEmpty {
                LooprCard { LooprText("Pin measurements in All metrics to show them here.", style: .prose, color: .inkSecondary) }
            } else if model.isLoading {
                LooprCard { StateMessage(.loading, compact: true) }
            } else {
                LooprContributorList(keys.map { key in
                    Self.row(key, reading: model.reading(key, on: anchor.day), identifier: identifier) {
                        metricLink?.open(key.rawValue)
                    }
                }, footer: showAllRow)
            }
        }
        .task(id: HealthLoadRequest(keys: keys, day: anchor.day)) { await model.load(keys: keys, provider: provider, anchor: anchor) }
        .navigationDestination(isPresented: $editing) {
            MetricLibraryScreen(showsPinOrder: true)
                .metricDetailNavigation()
        }
    }
}
