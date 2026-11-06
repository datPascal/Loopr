import AnalyticsKit
import Charts
import DesignSystem
import SwiftUI

/// One marker across draws (`labs-marker-screen`), opened from a report row: the opened value as the hero, a chart of
/// every draw in the same unit with the lab's own range as a faint band and its flag over the dot, then every stored
/// value as a list. The chart never colours a value as good or bad, and it never mixes units. Editing the opened value
/// stays one tap away.
public struct LabMarkerScreen: View {
    let row: LabValueRow?
    let labName: String?
    let save: @MainActor (LabValue) async -> String?
    /// Opens the Ranges method page. Nil hides the link.
    let openRangesMethod: (@MainActor () -> Void)?
    /// Opens the blood age method page. Nil hides the link.
    let openBloodAgeMethod: (@MainActor () -> Void)?
    @State private var editing: LabValue?

    public init(row: LabValueRow?, labName: String?, save: @escaping @MainActor (LabValue) async -> String?,
                openRangesMethod: (@MainActor () -> Void)? = nil, openBloodAgeMethod: (@MainActor () -> Void)? = nil) {
        self.row = row
        self.labName = labName
        self.save = save
        self.openRangesMethod = openRangesMethod
        self.openBloodAgeMethod = openBloodAgeMethod
    }

    /// "Glucose is one of the 9 values blood age reads from one draw." for the nine PhenoAge inputs, so a marker page
    /// says what it feeds (ICP R3-LAB-12). Nil for any other marker.
    static func bloodAgeLine(_ value: LabValue) -> String? {
        guard let key = value.subject.markerKey, PhenoAge.inputMarkers.contains(key) else { return nil }
        let name = DataBloodAgeMarkers.name(key)
        let lead = name.prefix(1).uppercased() + name.dropFirst()
        let line = "\(lead) is one of the \(PhenoAge.inputMarkers.count) values blood age reads from one draw."
        return value.isLimit
            ? line + " The lab printed this one as a limit, not an exact number, so blood age cannot use it."
            : line
    }

    public var body: some View {
        LabsPage {
            if let row {
                let history = LabMarkerHistory.make(row: row)
                hero(row)
                LabsSection("Every draw", detail: row.value.unit.map { "In \($0)" }, identifier: "labs-marker-chart-header") {
                    // One draw has no trend to draw, and a chart of one dot read as a mislabelled axis (ICP R2-LAB-8).
                    if history.points.count >= 2 {
                        chart(history)
                            .padding(LooprSpacing.md)
                    } else {
                        LooprText(history.trendLine, style: .prose, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(LooprSpacing.md)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("labs-marker-first-draw")
                    }
                }
                list(history)
                Button {
                    editing = row.value
                } label: {
                    Label("Edit this value", systemImage: "pencil")
                }
                .buttonStyle(LooprButtonStyle(prominent: false))
                .accessibilityIdentifier("labs-marker-edit")
                LooprText(LabsDisplay.notAMedicalDevice, style: .caption, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, LooprSpacing.xxs)
            } else {
                LooprInlineMessage("This value is no longer saved on this iPhone.", tone: .neutral)
            }
        }
        .navigationTitle(row?.name ?? "Marker")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { value in
            LabValueEditor(value: value) { updated in
                let failure = await save(updated)
                if failure == nil { editing = nil }
                return failure
            }
        }
        .accessibilityIdentifier("labs-marker-screen")
    }

    // MARK: Hero

    private func hero(_ row: LabValueRow) -> some View {
        let value = row.value
        let digits = value.displayValue.split(separator: ".").dropFirst().first?.count ?? 0
        let report = row.entries.first { $0.value.id == value.id }?.report
        return VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LabsEyebrow(text: value.assay.map { "\(row.name) · \($0)" } ?? row.name)
            HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.sm) {
                LooprHeroNumber(NSDecimalNumber(decimal: value.value).doubleValue, unit: value.unit, prefix: value.comparator?.symbol,
                                fractionDigits: digits, style: .heroNumeralXL, color: .brand)
                if let flag = LabsDisplay.flagText(value) { LabFlagBadge(flag: flag) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spokenHero(value))
            .accessibilityIdentifier("labs-marker-value")
            ProvenanceChip(.lab(name: labName ?? ""),
                           qualifier: report.map { LabsDisplay.day($0.collectedAt, timeZoneIdentifier: $0.timeZoneIdentifier) },
                           identifier: "labs-marker-source")
            LooprText(LabsDisplay.rangeText(value.referenceRange).map { "Lab range \($0)" } ?? "No range printed for this value.",
                      style: .prose, color: .inkSecondary)
            if let position = LabsDisplay.rangePosition(value) {
                LooprText(position + ".", style: .caption, color: LabsDisplay.isOutsideRange(value) ? .ink : .inkSecondary)
                    .accessibilityIdentifier("labs-marker-range-position")
            }
            // Who set the range, said once on the page (ICP R2-LAB-9).
            LooprText(LabsDisplay.rangeSourceLine(hasRange: LabsDisplay.rangeText(value.referenceRange) != nil),
                      style: .caption, color: .inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("labs-marker-range-source")
            if let openRangesMethod {
                Button(action: openRangesMethod) {
                    Label("How Loopr reads lab ranges", systemImage: "function")
                }
                .buttonStyle(LooprButtonStyle(prominent: false, quiet: true))
                .accessibilityIdentifier("labs-marker-ranges-method")
            }
            if let line = Self.bloodAgeLine(value) {
                LooprText(line, style: .caption, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("labs-marker-blood-age")
                if let openBloodAgeMethod {
                    Button(action: openBloodAgeMethod) {
                        Label("How blood age works", systemImage: "function")
                    }
                    .buttonStyle(LooprButtonStyle(prominent: false, quiet: true))
                    .accessibilityIdentifier("labs-marker-blood-age-method")
                }
            } else if value.isLimit {
                LooprText("The lab printed this as a limit, not an exact number.", style: .caption, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func spokenHero(_ value: LabValue) -> String {
        var parts = ["\(LabsDisplay.spokenValue(value))\(value.unit.map { " \($0)" } ?? "")"]
        if let flag = LabsDisplay.flagText(value) { parts.append("lab flag \(flag)") }
        return parts.joined(separator: ", ")
    }

    // MARK: Chart

    @ViewBuilder
    private func chart(_ history: LabMarkerHistory) -> some View {
        let points = history.points
        let numbers = points.map(\.value) + points.compactMap(\.low) + points.compactMap(\.high)
        let lowest = numbers.min() ?? 0
        let highest = numbers.max() ?? 1
        let pad = max((highest - lowest) * 0.15, abs(highest) * 0.05, 0.1)
        let bottom = lowest - pad
        // Twice the room above, so the opened value's label fits over its dot and never slides off it (ICP R3-LAB-7).
        let top = highest + pad * 2
        let firstDate = points.first?.date ?? Date()
        let lastDate = points.last?.date ?? firstDate
        let margin = max(lastDate.timeIntervalSince(firstDate) * 0.08, 20 * 86_400)
        let start = firstDate.addingTimeInterval(-margin)
        let end = lastDate.addingTimeInterval(margin)
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            Chart {
                ForEach(points) { point in
                    if point.low != nil || point.high != nil {
                        RuleMark(x: .value("Day", point.date),
                                 yStart: .value("Range low", point.low ?? bottom),
                                 yEnd: .value("Range high", point.high ?? top))
                            .lineStyle(StrokeStyle(lineWidth: 14, lineCap: .round))
                            .foregroundStyle(Color.loopr(.brand).opacity(0.12))
                            .accessibilityHidden(true)
                    }
                }
                // A line joins two exact values. A step to or from a limit ("<0.3") is dashed: it is not a measured
                // change (ICP R3-LAB-7).
                ForEach(Array(zip(points, points.dropFirst()).enumerated()), id: \.offset) { index, pair in
                    let dashed = pair.0.isLimit || pair.1.isLimit
                    ForEach([pair.0, pair.1]) { point in
                        LineMark(x: .value("Day", point.date), y: .value("Value", point.value), series: .value("Step", index))
                            .foregroundStyle(Color.loopr(.brand).opacity(dashed ? 0.4 : 0.55))
                            .lineStyle(StrokeStyle(lineWidth: 2, dash: dashed ? [4, 4] : []))
                            .interpolationMethod(.linear)
                            .accessibilityHidden(true)
                    }
                }
                ForEach(points) { point in
                    PointMark(x: .value("Day", point.date), y: .value("Value", point.value))
                        .symbol {
                            Circle()
                                .fill(point.isLimit ? Color.loopr(.background) : Color.loopr(.brand))
                                .overlay { Circle().strokeBorder(Color.loopr(.brand), lineWidth: 2) }
                                .frame(width: point.isOpened ? 13 : 9, height: point.isOpened ? 13 : 9)
                        }
                        // Held over its dot: the automatic overflow moved the label to the side, far from the dot.
                        .annotation(position: .top, alignment: .center, spacing: 4,
                                    overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            if point.isOpened || point.flag != nil {
                                Text(verbatim: [point.isOpened ? point.printed : nil, point.flag].compactMap { $0 }.joined(separator: " "))
                                    .looprTypography(.chip)
                                    .foregroundStyle(Color.loopr(point.isOpened ? .ink : .inkSecondary))
                            }
                        }
                        .accessibilityLabel(point.dayText)
                        .accessibilityValue([point.printed + (history.unit.map { " \($0)" } ?? ""), point.flag.map { "lab flag \($0)" }]
                            .compactMap { $0 }.joined(separator: ", "))
                }
            }
            .chartXScale(domain: start...end)
            .chartYScale(domain: bottom...top)
            .chartXAxis {
                // A few draws get a tick each, labelled with the draw's own day. Automatic month ticks put two
                // "Nov 23" labels beside one dot that sat on neither (ICP R2-LAB-8).
                if points.count <= Self.perDrawTicks {
                    AxisMarks(values: points.map(\.date)) { value in
                        AxisGridLine().foregroundStyle(Color.loopr(.divider))
                        AxisValueLabel {
                            if let date = value.as(Date.self), let point = points.first(where: { $0.date == date }) {
                                Text(verbatim: point.dayText).foregroundStyle(Color.loopr(.inkSecondary))
                            }
                        }
                    }
                } else {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine().foregroundStyle(Color.loopr(.divider))
                        AxisValueLabel(format: .dateTime.month(.abbreviated).year(.twoDigits))
                            .foregroundStyle(Color.loopr(.inkSecondary))
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(Color.loopr(.divider))
                    AxisValueLabel().foregroundStyle(Color.loopr(.inkSecondary))
                }
            }
            .frame(height: 220)
            .accessibilityLabel("\(history.name) over time")
            .accessibilityValue(history.spokenSummary)
            .accessibilityIdentifier("labs-marker-chart")
            if let change = history.changeLine {
                LooprText(change, style: .prose, color: .ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("labs-marker-change")
            }
            LooprText(chartCaption(history), style: .caption, color: .inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Up to this many draws, each gets its own labelled tick.
    static let perDrawTicks = 3

    private func chartCaption(_ history: LabMarkerHistory) -> String {
        var parts = ["Each dot is one draw. The faint band is the range the lab printed that day."]
        if history.points.contains(where: \.isLimit) {
            parts.append("A hollow dot is a result printed as a limit, and a dashed line leads to it.")
        }
        if history.otherUnitCount > 0 {
            parts.append(history.otherUnitCount == 1 ? "1 value in another unit is listed below and not drawn."
                         : "\(history.otherUnitCount) values in another unit are listed below and not drawn.")
        }
        return parts.joined(separator: " ")
    }

    // MARK: List

    private func list(_ history: LabMarkerHistory) -> some View {
        LabsSection(history.entries.count == 1 ? "1 value" : "\(history.entries.count) values", identifier: "labs-marker-list-header") {
            ForEach(Array(history.entries.enumerated()), id: \.element.value.id) { index, entry in
                entryRow(entry, opened: entry.value.id == row?.value.id)
                if index < history.entries.count - 1 { LooprHairline() }
            }
        }
    }

    private func entryRow(_ entry: LabHistoryEntry, opened: Bool) -> some View {
        let value = entry.value
        let day = LabsDisplay.day(entry.report.collectedAt, timeZoneIdentifier: entry.report.timeZoneIdentifier)
        let range = LabsDisplay.rangeText(value.referenceRange)
        return HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.sm) {
            VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                LooprText(opened ? "\(day) · this report" : day, style: .rowTitle)
                LooprText([LabsDisplay.labName(entry.report), range.map { "range \($0)" }].compactMap { $0 }.joined(separator: " · "),
                          style: .caption, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: LooprSpacing.sm)
            Text(LabsDisplay.valueWithUnit(value))
                .looprTypography(.metricValue)
                .foregroundStyle(Color.loopr(.ink))
                .multilineTextAlignment(.trailing)
            if let flag = LabsDisplay.flagText(value) { LabFlagBadge(flag: flag) }
        }
        .padding(.horizontal, LooprSpacing.formCardPadding)
        .padding(.vertical, LooprSpacing.formRowVerticalPadding)
        .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([day, LabsDisplay.spokenValue(value) + (value.unit.map { " \($0)" } ?? ""),
                             range.map { "lab range \($0)" }, LabsDisplay.flagText(value).map { "lab flag \($0)" },
                             "from \(LabsDisplay.labName(entry.report))"].compactMap { $0 }.joined(separator: ", "))
        .accessibilityIdentifier("labs-marker-entry-\(value.id.uuidString)")
    }
}
