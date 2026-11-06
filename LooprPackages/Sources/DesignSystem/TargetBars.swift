import Charts
import SwiftUI

public struct LooprTargetBar: Identifiable, Equatable, Sendable {
    public let date: Date
    public let value: Double?
    public let target: Double?
    public let isComplete: Bool
    public var id: Date { date }
    public init(date: Date, value: Double?, target: Double?, isComplete: Bool) {
        self.date = date
        self.value = value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.target = target.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.isComplete = isComplete
    }
}

/// Each bar has its own target marker. The marker is absent when that day's
/// target is unknown; incomplete days use a quieter fill.
public struct LooprTargetBars: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Nil until the chart appears, so an image render draws real bars. On appear the bars rise once.
    @State private var risen: Bool?
    private let days: [LooprTargetBar]
    private let title: String
    private let unit: String
    private let accent: LooprColorToken
    /// Every day the x axis shows, when it runs past the days with bars (a week that is not over yet).
    private let axis: [Date]?
    private let showsValues: Bool
    private let labelsTarget: Bool
    /// - Parameters:
    ///   - axis: the days the axis labels, in order. Nil labels the bars' own days.
    ///   - showsValues: prints each complete day's value over its bar.
    ///   - labelsTarget: writes "Target 150 g" on a target line shared by every day.
    public init(days: [LooprTargetBar], title: String, unit: String, accent: LooprColorToken, axis: [Date]? = nil,
                showsValues: Bool = false, labelsTarget: Bool = false) {
        self.days = days; self.title = title; self.unit = unit; self.accent = accent
        self.axis = axis.flatMap { $0.isEmpty ? nil : $0 }
        self.showsValues = showsValues; self.labelsTarget = labelsTarget
    }
    private var axisDays: [Date] { axis ?? days.map(\.date) }
    /// From the first labelled day to the end of the last, so a day with no bar keeps its slot.
    private var xDomain: ClosedRange<Date>? {
        guard let first = axisDays.first, let last = axisDays.last, first <= last else { return nil }
        return first...last.addingTimeInterval(86_400)
    }
    public var uniformTarget: Double? {
        guard days.count > 1, let first = days.first?.target, days.allSatisfy({ $0.target == first }) else { return nil }
        return first
    }
    private var yMaximum: Double {
        let highest = days.flatMap { [$0.value, $0.target] }.compactMap { $0 }.filter(\.isFinite).max() ?? 0
        // Headroom for the values and the target label printed above the bars.
        return max(highest * (showsValues || labelsTarget ? 1.2 : 1.08), 1)
    }

    public var body: some View {
        Chart {
            if let target = uniformTarget {
                RuleMark(y: .value("Target", target))
                    .lineStyle(StrokeStyle(lineWidth: LooprSpacing.hairline, dash: [3, 4]))
                    .foregroundStyle(Color.loopr(.inkSecondary))
                    .accessibilityLabel("Daily target")
                    .accessibilityValue("\(LooprUnitFormatter.number(target) ?? "") \(unit)")
                    .annotation(position: .top, alignment: .leading, spacing: 2) {
                        if labelsTarget {
                            Text("Target \(LooprUnitFormatter.number(target) ?? "") \(unit)")
                                .looprTypography(.confidence).foregroundStyle(Color.loopr(.inkSecondary))
                        }
                    }
            }
            ForEach(days) { day in
            if let value = day.value {
                BarMark(x: .value("Day", day.date, unit: .day), y: .value(unit, risen == false ? 0 : value), width: .ratio(0.46))
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 5, topTrailingRadius: 5, style: .continuous))
                    .foregroundStyle(Color.loopr(accent).opacity(day.isComplete ? 1 : 0.45))
                    .accessibilityLabel(day.date.formatted(date: .abbreviated, time: .omitted))
                    .accessibilityValue("\(LooprUnitFormatter.number(value) ?? "") \(unit)\(day.isComplete ? "" : ", incomplete log")")
                    .annotation(position: .top, spacing: 2) {
                        if showsValues && day.isComplete && risen != false {
                            Text(LooprUnitFormatter.number(value) ?? "")
                                .looprTypography(.confidence).monospacedDigit()
                                .foregroundStyle(Color.loopr(.ink))
                                .minimumScaleFactor(0.7).lineLimit(1)
                        }
                    }
            }
            if uniformTarget == nil, let target = day.target {
                RectangleMark(x: .value("Day", day.date, unit: .day), y: .value("Target", target),
                    width: .ratio(0.8), height: .fixed(LooprSpacing.hairline))
                    .foregroundStyle(Color.loopr(.inkSecondary))
                    .accessibilityLabel("Target")
                    .accessibilityValue("\(LooprUnitFormatter.number(target) ?? "") \(unit)")
            }
            }
        }
        .chartXAxis {
            AxisMarks(values: axisDays) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date.formatted(.dateTime.weekday(.narrow)))
                            .looprTypography(.confidence).foregroundStyle(Color.loopr(.inkSecondary))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(Color.loopr(.divider))
            }
        }
        .chartLegend(.hidden)
        // The y scale stays put while the bars rise, so they grow instead of the axis shrinking.
        .chartYScale(domain: 0...yMaximum)
        .modifier(LooprTargetBarsDomain(domain: axis == nil ? nil : xDomain))
        .frame(height: LooprSpacing.weeklyChartHeight)
        .onAppear {
            guard risen == nil, !LooprMotion.reducesMotion(reduceMotion) else { return }
            risen = false
            Task { @MainActor in withAnimation(.spring(response: 0.7, dampingFraction: 0.86).delay(0.15)) { risen = true } }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityLabel(title)
    }
}

/// Pins the x scale to the axis days when the caller passed them, and leaves Charts' own scale otherwise.
private struct LooprTargetBarsDomain: ViewModifier {
    let domain: ClosedRange<Date>?
    func body(content: Content) -> some View {
        if let domain { content.chartXScale(domain: domain) } else { content }
    }
}

#Preview("Daily targets") {
    let days: [LooprTargetBar] = (0..<7).map { index in
        let date = Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 86_400)
        let value: Double? = index == 3 ? nil : Double(1_200 + index * 100)
        return LooprTargetBar(date: date, value: value, target: 2_000, isComplete: index < 6)
    }
    LooprCard {
        LooprTargetBars(days: days, title: "This week", unit: "kcal", accent: .energy)
    }.padding()
}
