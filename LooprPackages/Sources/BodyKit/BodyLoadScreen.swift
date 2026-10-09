import Foundation
import SwiftUI
import DomainKit
import DesignSystem

/// Training load detail: the recent trend, fitness, fatigue and form,
/// with the history needed and how Loopr computes them.
public struct BodyLoadScreen: View {
    @Environment(\.looprDayNavigation) private var dayNavigation
    public let snapshot: BodyDaySnapshot
    public let history: BodyHistory?

    public init(snapshot: BodyDaySnapshot, history: BodyHistory? = nil) {
        self.snapshot = snapshot
        self.history = history
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LooprSpacing.xl) {
                let prompt = BodyProfileGaps.prompt(for: snapshot)
                if let prompt {
                    BodyProfilePromptCard(prompt: prompt)
                }
                if prompt == nil, let history {
                    let end = BodyStrainWeek.lastCompleteDay(anchor: history.anchor, anchorIsToday: dayNavigation?.isToday ?? true)
                    let state = BodyTrainingLoad.compute(history: history, endingOn: end)
                    summary(state)
                    let trend = BodyTrainingLoad.trend(history: history, endingOn: end)
                    if trend.contains(where: { $0.acute != nil }) {
                        BodySection(title: "Last 4 weeks", detail: "Recent load against your longer-term band") {
                            LooprSurface { BodyLoadTrendChart(points: trend) }
                        }
                    }
                    if case .ready(let load) = state {
                        numbers(load)
                    }
                } else if prompt == nil {
                    summary(.learning(daysWithStrain: 0, needed: TrainingLoad.establishedDays))
                }
                if prompt == nil { method }
            }
            .padding(.horizontal, LooprSpacing.screenGutter)
            .padding(.top, LooprSpacing.md)
            .padding(.bottom, LooprSpacing.tabBarClearance)
        }
        .background(Color.loopr(.background).ignoresSafeArea())
        .navigationTitle("Training load")
        .accessibilityIdentifier("body-load-screen")
    }

    private func summary(_ state: BodyTrainingLoad.State) -> some View {
        LooprSurface(emphasis: .hero(.strain)) {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                LooprText(state.title, style: .titleLarge)
                    .fixedSize(horizontal: false, vertical: true)
                Text(state.detail)
                    .looprTypography(.prose)
                    .foregroundStyle(Color.loopr(.inkSecondary))
                    .fixedSize(horizontal: false, vertical: true)
                if case .ready(let load) = state, load.model.isEstablished {
                    BodyLoadRangeBar(load: load)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("body-load-summary")
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private func numbers(_ load: BodyTrainingLoad) -> some View {
        let rows: [NumberRow] = [
            NumberRow(id: "chronic", title: "Fitness", value: LooprUnitFormatter.number(load.chronic, digits: 1) ?? "",
                      unit: "strain", caption: "Your longer-term load, smoothed over 42 days. This describes training history, not a fitness test."),
            NumberRow(id: "acute", title: "Fatigue", value: LooprUnitFormatter.number(load.acute, digits: 1) ?? "",
                      unit: "strain", caption: "Your recent load, smoothed over 7 days. It describes recent effort, not how tired you feel."),
            NumberRow(id: "form", title: "Form", value: LooprUnitFormatter.number(load.form, digits: 1) ?? "",
                      unit: "strain", caption: "Fitness minus fatigue. Below zero means recent load is above your longer-term load.")
        ]
        return BodySection(title: "The numbers") {
            LooprSurface {
                BodyRowStack(rows: rows) { row in
                    let layout = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: LooprSpacing.xs))
                        : AnyLayout(HStackLayout(alignment: .top, spacing: LooprSpacing.sm))
                    layout {
                        VStack(alignment: .leading, spacing: 3) {
                            LooprText(row.title, style: .rowTitle)
                            Text(row.caption)
                                .looprTypography(.caption)
                                .foregroundStyle(Color.loopr(.inkSecondary))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if row.value.isEmpty {
                            LooprText("No reading", style: .caption, color: .inkSecondary)
                        } else {
                            LooprValueText(row.value, unit: row.unit, valueStyle: .metricCompact).fixedSize()
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("body-load-\(row.id)")
                }
            }
        }
    }

    private var method: some View {
        BodySection(title: "How Loopr works it out") {
            LooprSurface {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    Text("Loopr smooths daily strain over 42 days for fitness and 7 days for fatigue. Form is the difference. Today joins once it is over. Missing days restart the history; a recorded zero counts as rest.")
                    Text("The shaded band is within 10% of your longer-term load. It appears after 42 recorded days in a row. Load gives context and never changes your recovery score.")
                }
                .looprTypography(.prose)
                .foregroundStyle(Color.loopr(.inkSecondary))
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private struct NumberRow: Identifiable {
        let id: String
        let title: String
        let value: String
        let unit: String?
        let caption: String
    }
}

/// Recent 7-day average strain as a line over the usual band,
/// hold to read a day. Days without enough data leave a gap.
struct BodyLoadTrendChart: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var scrubIndex: Int?
    let points: [BodyLoadTrendPoint]

    private let headroom: CGFloat = 34

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            legend
            VStack(spacing: LooprSpacing.xxs + 2) {
                plot.frame(height: 170)
                axis
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recent training load over the last \(points.count) days")
        .accessibilityValue(spoken)
        .accessibilityIdentifier("body-load-trend")
    }

    private var legend: some View {
        HStack(spacing: LooprSpacing.md) {
            HStack(spacing: LooprSpacing.xxs + 2) {
                Capsule().fill(Color.loopr(.strain)).frame(width: 12, height: 3)
                Text("RECENT LOAD").looprTypography(.sectionLabel).foregroundStyle(Color.loopr(.inkSecondary))
            }
            if points.contains(where: { $0.usualLow != nil && $0.usualHigh != nil }) {
                HStack(spacing: LooprSpacing.xxs + 2) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.loopr(.strain).opacity(bandOpacity * 1.6)).frame(width: 12, height: 10)
                    Text("YOUR USUAL").looprTypography(.sectionLabel).foregroundStyle(Color.loopr(.inkSecondary))
                }
            }
            Spacer(minLength: 0)
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityHidden(true)
    }

    private var maximum: Double {
        let values = points.flatMap { [$0.acute, $0.usualHigh] }.compactMap { $0 }
        return max((values.max() ?? 1) * 1.1, 1)
    }

    private var plot: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let plotHeight = proxy.size.height - headroom
            let count = max(points.count, 1)
            let x = { (index: Int) in LooprScrubMath.center(of: index, count: count, width: width) }
            let y = { (value: Double) in proxy.size.height - CGFloat(value / maximum) * plotHeight }
            ZStack(alignment: .topLeading) {
                ForEach([0.5, 1.0], id: \.self) { level in
                    Rectangle().fill(Color.loopr(.divider)).frame(width: width, height: 1)
                        .offset(y: proxy.size.height - plotHeight * level)
                }
                Rectangle().fill(Color.loopr(.inkMuted).opacity(0.5)).frame(width: width, height: 1)
                    .offset(y: proxy.size.height - 1)
                Text(LooprUnitFormatter.number(maximum, digits: 0) ?? "")
                    .looprTypography(.confidence)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .foregroundStyle(Color.loopr(.inkSecondary))
                    .fixedSize()
                    .position(x: width - 10, y: proxy.size.height - plotHeight - 8)
                    .accessibilityHidden(true)
                // The usual band, one closed shape per run of days that have it.
                ForEach(runs(\.usualLow), id: \.self) { run in
                    Path { path in
                        guard let first = run.first else { return }
                        path.move(to: CGPoint(x: x(first), y: y(points[first].usualHigh ?? 0)))
                        for index in run.dropFirst() { path.addLine(to: CGPoint(x: x(index), y: y(points[index].usualHigh ?? 0))) }
                        for index in run.reversed() { path.addLine(to: CGPoint(x: x(index), y: y(points[index].usualLow ?? 0))) }
                        path.closeSubpath()
                    }
                    .fill(Color.loopr(.strain).opacity(bandOpacity))
                }
                ForEach(runs(\.acute), id: \.self) { run in
                    Path { path in
                        guard let first = run.first else { return }
                        path.move(to: CGPoint(x: x(first), y: y(points[first].acute ?? 0)))
                        for index in run.dropFirst() { path.addLine(to: CGPoint(x: x(index), y: y(points[index].acute ?? 0))) }
                    }
                    .stroke(Color.loopr(.strain), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                }
                if let last = points.indices.last(where: { points[$0].acute != nil }), let value = points[last].acute {
                    Circle().fill(Color.loopr(.strain)).frame(width: 8, height: 8)
                        .position(x: x(last), y: y(value))
                }
                if let scrubIndex, points.indices.contains(scrubIndex) {
                    LooprScrubReadout(x: x(scrubIndex), title: readoutDate(points[scrubIndex].date),
                                      value: readout(points[scrubIndex]), accent: .strain)
                        .frame(width: width, height: proxy.size.height)
                }
            }
            .frame(width: width, height: proxy.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .looprScrub { position in
                scrubIndex = position.flatMap { LooprScrubMath.index(x: $0, width: width, count: points.count) }
            }
        }
    }

    private var axis: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                    if (points.count - 1 - index) % 7 == 0 {
                        Text(point.date.formatted(.dateTime.day().month(.abbreviated)).uppercased())
                            .looprTypography(.confidence)
                            .foregroundStyle(Color.loopr(index == points.count - 1 ? .ink : .inkSecondary))
                            .fixedSize()
                            .position(x: min(max(LooprScrubMath.center(of: index, count: points.count, width: proxy.size.width), 22),
                                             proxy.size.width - 22), y: 7)
                    }
                }
            }
        }
        .frame(height: 14)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .dynamicTypeSize(...DynamicTypeSize.large)
        .accessibilityHidden(true)
    }

    /// Consecutive indices where `key` has a value.
    private func runs(_ key: KeyPath<BodyLoadTrendPoint, Double?>) -> [[Int]] {
        var result: [[Int]] = []
        var current: [Int] = []
        for (index, point) in points.enumerated() {
            if point[keyPath: key] != nil { current.append(index) } else if !current.isEmpty { result.append(current); current = [] }
        }
        if !current.isEmpty { result.append(current) }
        return result.filter { $0.count >= 1 }
    }

    private func readoutDate(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    private func readout(_ point: BodyLoadTrendPoint) -> String? {
        guard let acute = point.acute else { return nil }
        let value = "\(LooprUnitFormatter.number(acute, digits: 1) ?? "") a day"
        guard let low = point.usualLow, let high = point.usualHigh else { return value }
        return "\(value) · usual \(LooprUnitFormatter.number(low, digits: 1) ?? "") to \(LooprUnitFormatter.number(high, digits: 1) ?? "")"
    }

    private var spoken: String {
        guard let last = points.last(where: { $0.acute != nil }), let acute = last.acute else { return "No readings" }
        var text = "Latest recent load \(LooprUnitFormatter.number(acute, digits: 1) ?? "") a day"
        if let low = last.usualLow, let high = last.usualHigh {
            text += ", usual \(LooprUnitFormatter.number(low, digits: 1) ?? "") to \(LooprUnitFormatter.number(high, digits: 1) ?? "")"
        }
        return text
    }

    private var bandOpacity: Double { LooprAppearance.isDark(colorScheme) ? 0.20 : 0.15 }
}
