import CoreTransferable
import DataKit
import DesignSystem
import SwiftUI
import UniformTypeIdentifiers

// Data ICP round 1 (docs/design/2026-11-04-data-tab): the Data root leads with one tile per area, each with the
// latest number, how it sits against the person's usual and a 30-day line, so "how am I doing" is answered before the
// first scroll. Every tile and every "Last night" row reads `HealthMetricsModel`, the same history and usual-range rule
// as Pinned and the metric pages, so no two Data screens disagree about one number.

/// One area of Data on the root: Sleep, Recovery, Strain, Stress, Body or Blood tests.
struct DataArea: Identifiable {
    enum Kind: String { case sleep, recovery, strain, stress, body, blood }

    let kind: Kind
    var id: String { kind.rawValue }

    static let all: [DataArea] = [.init(kind: .sleep), .init(kind: .recovery), .init(kind: .strain),
                                  .init(kind: .stress), .init(kind: .body), .init(kind: .blood)]

    var title: String {
        switch kind {
        case .sleep: "Sleep"
        case .recovery: "Recovery"
        case .strain: "Strain"
        case .stress: "Stress"
        case .body: "Body"
        case .blood: "Blood tests"
        }
    }

    var symbol: String {
        switch kind {
        case .sleep: "moon.fill"
        case .recovery: "heart.fill"
        case .strain: "flame.fill"
        case .stress: "waveform.path.ecg"
        case .body: "figure.stand"
        case .blood: "drop.fill"
        }
    }

    /// The metric the tile leads with. Blood tests have none.
    var key: MetricKey? {
        switch kind {
        case .sleep: .sleepDuration
        case .recovery: .recovery
        case .strain: .strain
        case .stress: .stress
        case .body: .vo2Max
        case .blood: nil
        }
    }

    var accent: LooprColorToken {
        switch kind {
        case .sleep: .sleep
        case .recovery: .heart
        case .strain: .strain
        case .stress: .heart
        case .body: .brand
        case .blood: .sleep
        }
    }

    var route: AppHealthRoute {
        switch kind {
        case .sleep: .sleepHome
        case .recovery: .heartHome
        case .strain: .bodyHome
        case .stress: .stressHome
        case .body: .bodyMeasures
        case .blood: DataRootRouting.bloodTests
        }
    }

    /// The identifiers the Explore rows had, so tests and captures that open an area keep working.
    var identifier: String {
        switch kind {
        case .sleep: "health-explore-sleep"
        case .recovery: "health-explore-heart"
        case .strain: "health-explore-body"
        case .stress: "health-explore-stress"
        case .body: "data-area-body"
        case .blood: "health-explore-labs"
        }
    }

    static var metricKeys: [MetricKey] { all.compactMap(\.key) }
}

/// What a tile says: the number, its unit, and one short line against the person's usual.
struct DataAreaTileContent: Equatable {
    var value: String?
    var unit: String
    var status: String
    var points: [LooprChartPoint]
    var baseline: LooprBaselineBand?

    /// A band metric reads the anchor day; VO₂max reads its latest reading in the month, since a watch records it only
    /// on some walks and runs. A day without a reading says so and never shows 0 (honesty rule).
    static func make(_ area: DataArea, reading: HealthMetricReading?, history: [MetricHistoryPoint], isLoading: Bool,
                     isToday: Bool = false) -> DataAreaTileContent {
        guard let key = area.key, let reading else {
            return DataAreaTileContent(value: nil, unit: "", status: isLoading ? "Loading" : "No reading", points: [])
        }
        if isLoading { return DataAreaTileContent(value: nil, unit: "", status: "Loading", points: []) }
        if key == .vo2Max {
            guard let latest = history.last(where: { $0.value.isFinite }) else {
                return DataAreaTileContent(value: nil, unit: "", status: "No VO₂max yet", points: reading.points)
            }
            let date = latest.day.formatted(.dateTime.day().month(.abbreviated))
            return DataAreaTileContent(value: key.presentation.value(latest.value), unit: key.presentation.unit,
                                       status: "VO₂max, \(date)", points: reading.points)
        }
        guard reading.value != nil else {
            return DataAreaTileContent(value: nil, unit: "", status: area.kind == .sleep ? "No night yet" : "No reading today",
                                       points: reading.points, baseline: reading.baseline)
        }
        // Today's strain is still running, so it is not set against finished days (Data ICP R2-VET-07).
        let status = key == .strain && isToday ? "So far today" : reading.comparison.map(Self.short) ?? "Learning your usual"
        // A score out of 100 says so, as strain says "/21" (Data ICP R2-NEW-01).
        let unit = key == .recovery && key.presentation.unit.isEmpty ? "/100" : key.presentation.unit
        return DataAreaTileContent(value: reading.formatted, unit: unit, status: status,
                                   points: reading.points, baseline: reading.baseline)
    }

    /// Tile-sized words for the row comparisons: "Within your usual range" fits two lines, the rest already do.
    /// "+14 vs usual" reads as "14 above your usual": a beginner could not tell whether plus was good (R2-NEW-01).
    static func short(_ comparison: String) -> String {
        switch comparison {
        case "Within your usual range": return "Within your usual"
        case "Learning your usual range": return "Learning your usual"
        default: return words(comparison)
        }
    }

    /// "+10 ms vs usual" as "10 ms above your usual". Every Data row and tile says it in words.
    static func words(_ comparison: String) -> String {
        guard comparison.hasSuffix(" vs usual"), let sign = comparison.first, "+-−".contains(sign) else { return comparison }
        let amount = comparison.dropFirst().dropLast(" vs usual".count).trimmingCharacters(in: .whitespaces)
        return "\(amount) \(sign == "+" ? "above" : "below") your usual"
    }

    /// Blood tests as a state, not a count (Data ICP R3-DES-03): how many markers have a value, and how many moved
    /// against their own earlier values. With nothing to compare yet, how many reports they came from.
    static func blood(reports: Int, values: Int, markers: DataBloodMarkers = .init()) -> DataAreaTileContent {
        guard reports > 0 else { return DataAreaTileContent(value: nil, unit: "", status: "Add your first report", points: []) }
        guard markers.measured > 0 else {
            return DataAreaTileContent(value: "\(reports)", unit: reports == 1 ? "report" : "reports",
                                       status: values == 1 ? "1 value" : "\(values) values", points: [])
        }
        // Only markers tested twice can move, so the line says how many of those moved; a count of moved and steady
        // that leaves the once-tested markers out did not add up to the total (Data ICP R4-NEW, R4-VET-04).
        let retested = markers.moved + markers.steady
        let status = retested > 0
            ? markers.moved == 0 ? "None moved since your last test" : "\(markers.moved) of \(retested) retested moved"
            : reports == 1 ? "From 1 report" : "From \(reports) reports"
        return DataAreaTileContent(value: "\(markers.measured)", unit: markers.measured == 1 ? "marker" : "markers",
                                   status: status, points: [])
    }
}

/// The lab markers on the star map: how many have a value, and how many moved or held against their own history.
struct DataBloodMarkers: Equatable {
    var measured = 0
    var moved = 0
    var steady = 0

    init(measured: Int = 0, moved: Int = 0, steady: Int = 0) {
        self.measured = measured
        self.moved = moved
        self.steady = steady
    }

    init(_ map: DataStarMap?) {
        let stars = (map?.clusters ?? []).flatMap(\.stars).filter { $0.source == .lab && !$0.isAbsent }
        measured = stars.count
        moved = stars.filter { $0.trend == .changed || $0.trend == .watch }.count
        steady = stars.filter { $0.trend == .steady || $0.trend == .improving }.count
    }
}

/// The six area tiles, two to a row.
struct DataAreaGrid: View {
    @Environment(\.metricHistoryProvider) private var provider
    @Environment(\.looprDaySelection) private var day
    @State private var model = HealthMetricsModel()
    let labReports: Int
    let labValues: Int
    var bloodMarkers = DataBloodMarkers()
    let open: (AppHealthRoute) -> Void

    private var anchor: MetricDetailAnchor {
        MetricDetailAnchor(selectedDay: day.map { LooprDays.looprDay($0.day) },
                           today: day.map { LooprDays.looprDay($0.today) }, calendar: .current)
    }

    private var isToday: Bool { day.map { $0.day == $0.today } ?? true }

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            if let sentence = Self.sentence(sleep: content(DataArea.all[0]), recovery: content(DataArea.all[1])) {
                LooprText(sentence, style: .prose)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("data-areas-sentence")
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: LooprSpacing.sm), GridItem(.flexible(), spacing: LooprSpacing.sm)],
                      spacing: LooprSpacing.sm) {
                ForEach(DataArea.all) { area in
                    DataAreaTile(area: area, content: content(area), endingOn: anchor.day) { open(area.route) }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("data-areas")
        .task(id: HealthLoadRequest(keys: DataArea.metricKeys, day: anchor.day)) {
            await model.load(keys: DataArea.metricKeys, provider: provider, anchor: anchor)
        }
    }

    private func content(_ area: DataArea) -> DataAreaTileContent {
        guard let key = area.key else { return .blood(reports: labReports, values: labValues, markers: bloodMarkers) }
        return .make(area, reading: model.reading(key, on: anchor.day), history: model.history[key] ?? [],
                     isLoading: model.isLoading, isToday: isToday)
    }

    /// One line in words over the tiles, built only from what was measured: "You slept 7 h 42 m, within your usual.
    /// Recovery is 79, 14 above your usual." Nil when neither has a reading (Data ICP R2-NEW-02).
    static func sentence(sleep: DataAreaTileContent, recovery: DataAreaTileContent) -> String? {
        var parts: [String] = []
        if let value = sleep.value { parts.append("You slept \(value), \(sleep.status.lowercasedFirstLetter)") }
        if let value = recovery.value { parts.append("Recovery is \(value), \(recovery.status.lowercasedFirstLetter)") }
        return parts.isEmpty ? nil : parts.joined(separator: ". ") + "."
    }
}

struct DataAreaTile: View {
    let area: DataArea
    let content: DataAreaTileContent
    let endingOn: Date
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            LooprCard(density: .compact) {
                VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                    HStack(spacing: LooprSpacing.xs) {
                        Image(systemName: area.symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.loopr(area.accent))
                        LooprText(area.title, style: .rowTitle)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        LooprChevron()
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        if let value = content.value {
                            Text(verbatim: value)
                                .looprTypography(.metricCompact)
                                .monospacedDigit()
                                .foregroundStyle(Color.loopr(.ink))
                                .contentTransition(.numericText())
                            if !content.unit.isEmpty {
                                LooprText(content.unit, style: .metricUnit, color: .inkSecondary)
                            }
                        } else {
                            Text(verbatim: " ")
                                .looprTypography(.metricCompact)
                                .accessibilityHidden(true)
                        }
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    LooprText(content.status, style: .caption, color: .inkSecondary)
                        .lineLimit(2, reservesSpace: true)
                    sparkline
                }
            }
        }
        .buttonStyle(.looprPressableCard)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(area.identifier)
    }

    @ViewBuilder private var sparkline: some View {
        let line = LooprSparkline(points: content.points, days: 30, endingOn: endingOn,
                                  kind: area.kind == .sleep || area.kind == .strain ? .bars : .line,
                                  accent: area.accent, baseline: content.baseline, height: 28)
        if line.isEmpty {
            Color.clear.frame(height: 28).accessibilityHidden(true)
        } else {
            line
        }
    }

    private var spokenLabel: String {
        let value = content.value.map { "\($0) \(content.unit)" } ?? ""
        return [area.title, value, content.status].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// Recovery's "Last night": the recovery score and the four overnight signals, against the usual range the root and
/// the metric pages use, with one line on what recovery is.
struct DataLastNightCard: View {
    @Environment(\.metricHistoryProvider) private var provider
    @Environment(\.looprMetricLink) private var metricLink
    @Environment(\.looprDaySelection) private var day
    @State private var model = HealthMetricsModel()

    static let keys: [MetricKey] = [.recovery, .rmssd, .restingHeartRate, .respiratoryRate, .skinTemperatureDeviation]
    @State private var showsMeanings = false

    /// One plain line per number, for people who have never met HRV (Data ICP R2-NEW-04, R3-NEW).
    static let meanings: [(title: String, text: String)] = [
        ("HRV", "How much the time between heartbeats varies. Higher than your usual often goes with good rest. One night says little."),
        ("Resting heart rate", "Your pulse while you sleep. Lower than your usual often means you recovered."),
        ("Breathing rate", "Breaths per minute while you sleep. It stays steady for most people, so a jump stands out."),
        ("Skin temperature", "The change from your band's usual reading. A rise can come with illness, alcohol or a warm room.")
    ]
    static let explanation = "Recovery is a score from 0 to 100 for how last night's HRV, resting heart rate and breathing compare with your own recent nights."

    private var anchor: MetricDetailAnchor {
        MetricDetailAnchor(selectedDay: day.map { LooprDays.looprDay($0.day) },
                           today: day.map { LooprDays.looprDay($0.today) }, calendar: .current)
    }

    private var title: String {
        guard let day, day.day != day.today else { return "Last night" }
        return "The night before \(anchor.day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader(title, detail: Self.explanation, accent: .heart, identifier: "data-last-night")
            if model.isLoading {
                LooprCard { StateMessage(.loading, compact: true) }
            } else {
                LooprContributorList(Self.keys.map { key in
                    HealthPinnedSection.row(key, reading: model.reading(key, on: anchor.day), identifier: "data-last-night",
                                            title: key == .rmssd ? "HRV" : nil) {
                        metricLink?.open(key.rawValue)
                    }
                })
            }
            LooprFoldSection("What these numbers mean", summary: "HRV, resting heart rate, breathing and skin temperature",
                             identifier: "data-last-night-meanings", isOpen: $showsMeanings) {
                LooprCard {
                    VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                        ForEach(Self.meanings, id: \.title) { item in
                            VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                                LooprText(item.title, style: .rowTitle)
                                LooprText(item.text, style: .prose, color: .inkSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
        .task(id: HealthLoadRequest(keys: Self.keys, day: anchor.day)) {
            await model.load(keys: Self.keys, provider: provider, anchor: anchor)
        }
    }
}

/// A new person's first card: what to add, in the order it pays off, each one tap away (Data ICP R1-NEW-02,
/// R1-DES-21, R1-SW-17, R1-VET-18).
struct DataSetupCard: View {
    struct Step: Identifiable {
        let id: String
        let title: String
        let detail: String
        let symbol: String
        let action: () -> Void
    }

    let steps: [Step]

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Data fills in as you add things", detail: "Everything stays on this iPhone.",
                               identifier: "data-setup-header")
            LooprCard(density: .flush) {
                VStack(spacing: 0) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                        if index > 0 { LooprHairline() }
                        Button(action: step.action) {
                            LooprRow(title: step.title, subtitle: step.detail, symbol: step.symbol, accent: .brand)
                                .padding(.horizontal, LooprSpacing.md)
                        }
                        .buttonStyle(.looprPressableRow)
                        .accessibilityIdentifier("data-setup-\(step.id)")
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("data-setup")
    }
}

/// An area page's long view (Data ICP round 2): a range picker, chips for the area's numbers, the chart of the picked
/// one against the person's usual, one sentence on what the range shows, and a row to how the number is worked out.
/// Recovery, Strain, Stress and Body share it, so every area page reads the same way as Sleep's.
struct DataAreaTrend: View {
    @Environment(\.metricHistoryProvider) private var provider
    @Environment(\.looprDaySelection) private var day
    let keys: [MetricKey]
    let accent: LooprColorToken
    let identifier: String
    /// Leads with the newest reading and its date, so the page and its tile show the same number first (R3-DES).
    var showsLatest = false
    @State private var selected: MetricKey
    @State private var range: LooprChartRange = .month
    @State private var points: [LooprChartPoint] = []
    @State private var loadedKey: MetricKey?

    init(keys: [MetricKey], accent: LooprColorToken, identifier: String, showsLatest: Bool = false) {
        self.keys = keys
        self.accent = accent
        self.identifier = identifier
        self.showsLatest = showsLatest
        _selected = State(initialValue: keys[0])
    }

    private var latestLine: String? {
        guard showsLatest, loadedKey == selected, let last = points.last else { return nil }
        let presentation = selected.presentation
        let unit = presentation.format == .duration || presentation.unit.isEmpty ? "" : " \(presentation.unit)"
        return "Latest: \(presentation.format.string(last.value))\(unit), \(last.date.formatted(.dateTime.day().month(.abbreviated)))"
    }

    private var anchor: MetricDetailAnchor {
        MetricDetailAnchor(selectedDay: day.map { LooprDays.looprDay($0.day) },
                           today: day.map { LooprDays.looprDay($0.today) }, calendar: .current)
    }

    /// The ranges longer than the metric's history, shown dimmed, as on the metric pages (Data ICP R4-DES-01, R4-VET-03).
    nonisolated static func locked(points: [LooprChartPoint], endingOn: Date) -> Set<LooprChartRange> {
        let open = LooprChartRange.unlocked(historyDays: LooprChartRange.historyDays(points, endingOn: endingOn))
        return Set(LooprChartRange.allCases.filter { !open.contains($0) })
    }

    static let rangeOptions: [LooprPillOption<LooprChartRange>] = LooprChartRange.allCases.map {
        LooprPillOption($0, title: $0.title, spokenTitle: $0.spokenTitle, identifier: "data-trend-range-\($0.rawValue)")
    }

    var body: some View {
        let presentation = selected.presentation
        let format = presentation.format
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Over time", accent: accent, identifier: "\(identifier)-header")
            if let latestLine {
                LooprText(latestLine, style: .rowTitle)
                    .accessibilityIdentifier("\(identifier)-latest")
            }
            LooprPillPicker(selection: $range, options: Self.rangeOptions, accent: accent, identifier: "\(identifier)-range",
                            locked: loadedKey == selected ? Self.locked(points: points, endingOn: anchor.day) : [])
            if keys.count > 1 { chips }
            if loadedKey == selected, !points.isEmpty {
                let summary = MetricTrendNarrative.summary(points: points, key: selected, range: range, today: anchor.day)
                LooprMetricTrendCard(
                    title: presentation.title,
                    points: points,
                    endingOn: anchor.day,
                    range: $range,
                    kind: presentation.chartKind,
                    accent: presentation.accent,
                    unit: format == .duration ? "" : presentation.unit,
                    valueFormat: { format.string($0) },
                    axisFormat: { format.axisString($0) },
                    baseline: MetricTrendNarrative.baseline(points, today: anchor.day),
                    identifier: "\(identifier)-chart",
                    showsRangePicker: false,
                    yAxisStep: presentation.yAxisStep
                )
                LooprText(summary.headline, style: .prose, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("\(identifier)-sentence")
            } else if loadedKey == selected {
                LooprCard { LooprText("No readings of \(presentation.title) yet.", style: .prose, color: .inkSecondary) }
            } else {
                LooprCard { StateMessage(.loading, compact: true) }
            }
            // The chart as a CSV with the unit in its header, for people who keep their own sheet (Data ICP R3-VET-08).
            if loadedKey == selected, !points.isEmpty {
                let csv = DataChartCSV.make(key: selected, points: points, range: range, endingOn: anchor.day)
                ShareLink(item: csv, preview: SharePreview(csv.fileName)) {
                    LooprCard(density: .flush) {
                        LooprRow(title: "Export this chart", subtitle: "\(presentation.title), \(range.spokenTitle), as a CSV file",
                                 symbol: "square.and.arrow.up", accent: .inkSecondary)
                            .padding(.horizontal, LooprSpacing.md)
                    }
                }
                .buttonStyle(.looprPressableRow)
                .accessibilityIdentifier("\(identifier)-export")
            }
            if let method = MetricDetailMethodLink.methodID(for: selected) {
                NavigationLink(value: AppHealthRoute.method(method)) {
                    LooprCard(density: .flush) {
                        LooprRow(title: "How this is worked out", subtitle: "What goes into \(presentation.title), and where it stops being reliable",
                                 symbol: "function", accent: .inkSecondary)
                            .padding(.horizontal, LooprSpacing.md)
                    }
                }
                .buttonStyle(.looprPressableRow)
                .accessibilityIdentifier("\(identifier)-method")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
        .task(id: TrendRequest(key: selected, day: anchor.day)) {
            let history = (try? await provider.series(for: selected, days: LooprChartRange.longestDayCount, endingOn: anchor.endOfDay)) ?? []
            guard !Task.isCancelled else { return }
            points = MetricTrendNarrative.chartPoints(history.filter { $0.value.isFinite && $0.day <= anchor.endOfDay })
            loadedKey = selected
            // A metric with a shorter history than the picked range falls back to the longest range it fills.
            let open = LooprChartRange.unlocked(historyDays: LooprChartRange.historyDays(points, endingOn: anchor.day))
            if !open.contains(range) { range = LooprChartRange.resolved(range, available: open) }
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: LooprSpacing.xs) {
                ForEach(keys, id: \.self) { key in
                    let on = key == selected
                    Button { selected = key } label: {
                        Text(key.presentation.title)
                            .looprTypography(.label)
                            .foregroundStyle(Color.loopr(on ? accent.spectralChipLabel : .inkSecondary))
                            .padding(.horizontal, LooprSpacing.sm)
                            .frame(minHeight: 34)
                            .background(Capsule(style: .continuous)
                                .fill(Color.loopr(on ? accent : .ink).opacity(on ? 0.12 : 0.04)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
                    .accessibilityIdentifier("\(identifier)-metric-\(key.rawValue)")
                }
            }
        }
        .scrollClipDisabled()
    }

    private struct TrendRequest: Hashable {
        let key: MetricKey
        let day: Date
    }
}

private extension String {
    var lowercasedFirstLetter: String { prefix(1).lowercased() + dropFirst() }
}

/// One chart as a CSV file: a date column and the value with its unit in the header, one row per day in the range.
/// It holds what the chart draws and nothing more.
struct DataChartCSV: Transferable {
    let fileName: String
    let text: String

    static func make(key: MetricKey, points: [LooprChartPoint], range: LooprChartRange, endingOn: Date,
                     calendar: Calendar = .current) -> DataChartCSV {
        let presentation = key.presentation
        let end = calendar.startOfDay(for: endingOn)
        let start = calendar.date(byAdding: .day, value: -(range.dayCount - 1), to: end) ?? end
        let unit = presentation.format == .duration ? "minutes" : presentation.unit
        let header = "date,\(csvField(unit.isEmpty ? presentation.title : "\(presentation.title) (\(unit))"))"
        let day = Date.ISO8601FormatStyle(timeZone: calendar.timeZone).year().month().day()
        let rows = points.filter { $0.date >= start && $0.date <= end && $0.value.isFinite }
            .sorted { $0.date < $1.date }
            .map { "\($0.date.formatted(day)),\(String(format: "%.2f", $0.value))" }
        let name = "Loopr \(presentation.title) \(range.title).csv".replacingOccurrences(of: "/", with: "-")
        return DataChartCSV(fileName: name, text: ([header] + rows).joined(separator: "\n") + "\n")
    }

    private static func csvField(_ text: String) -> String {
        text.contains(",") || text.contains("\"") ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
    }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .commaSeparatedText) { csv in Data(csv.text.utf8) }
            .suggestedFileName { $0.fileName }
    }
}
