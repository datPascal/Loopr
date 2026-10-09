import AnalyticsKit
import Charts
import DesignSystem
import SwiftUI

struct HourlyStressCard: View {
    let day: HourlyStressDay?
    let openBreathing: () -> Void
    @State private var selection: Date?

    var body: some View {
        LooprSurface {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                LooprText("Today's waking hours", style: .cardTitle)
                if let day, let firstHour = day.hours.first, let lastHour = day.hours.last {
                    if day.daysRemaining > 0 {
                        LooprText("Learning your baseline", style: .rowTitle)
                        LooprText(LooprLearningText.progress(have: HourlyStress.minimumBaselineDays - day.daysRemaining, need: HourlyStress.minimumBaselineDays, noun: "days") + ". Wear your band during quiet waking hours.", style: .prose, color: .inkSecondary)
                    }
                    Chart {
                        ForEach(HourlyStressChartModel.scoredBars(in: day)) { bar in
                            BarMark(x: .value("Hour", bar.start, unit: HourlyStressChartModel.xUnit),
                                    y: .value("Stress", bar.score), width: .ratio(0.8))
                                .foregroundStyle(Color.loopr(.stress).opacity(bar.score >= 65 ? 1 : 0.5))
                                .accessibilityLabel(time(bar.start))
                                .accessibilityValue("\(Int(bar.score.rounded())) of 100")
                        }
                        ForEach(day.hours.filter { $0.feature.state == .active }) { hour in
                            // A neutral status strip, not a stress score. Missing
                            // and sleeping hours remain gaps.
                            RectangleMark(xStart: .value("Hour start", hour.feature.start),
                                          xEnd: .value("Hour end", hour.feature.end),
                                          yStart: .value("Status floor", 0), yEnd: .value("Status height", 12))
                                .foregroundStyle(Color.loopr(.inkMuted).opacity(0.18))
                                .annotation(position: .overlay) {
                                    Text("Active").looprTypography(.confidence)
                                        .fixedSize()
                                        .foregroundStyle(Color.loopr(.inkSecondary))
                                }
                                .accessibilityLabel(time(hour.feature.start))
                                .accessibilityValue("Active")
                        }
                        if let selection {
                            RuleMark(x: .value("Selected hour", selection))
                                .foregroundStyle(Color.loopr(.inkMuted))
                                .accessibilityHidden(true)
                        }
                    }
                    .chartXScale(domain: firstHour.feature.start...lastHour.feature.end,
                                 range: .plotDimension(startPadding: 4, endPadding: 16))
                    .chartYScale(domain: 0...100)
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .hour, count: 4)) { value in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 1))
                                .foregroundStyle(Color.loopr(.divider))
                            AxisValueLabel {
                                if let date = value.as(Date.self) {
                                    Text(time(date)).looprTypography(.confidence)
                                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                                        .foregroundStyle(Color.loopr(.inkSecondary))
                                        .fixedSize()
                                }
                            }
                        }
                    }
                    .chartYAxis {
                        AxisMarks(values: [0, 50, 100]) { value in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                                .foregroundStyle(Color.loopr(.divider))
                            AxisValueLabel {
                                if let score = value.as(Double.self) {
                                    Text(String(format: "%.0f", score)).looprTypography(.confidence)
                                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                                        .foregroundStyle(Color.loopr(.inkSecondary))
                                        .fixedSize()
                                }
                            }
                        }
                    }
                    .chartOverlay { proxy in
                        GeometryReader { geometry in
                            if let plot = proxy.plotFrame {
                                Rectangle().fill(Color.clear).contentShape(Rectangle())
                                    .looprScrub { x in
                                        guard let x, let date: Date = proxy.value(atX: x - geometry[plot].minX) else { return }
                                        selection = date
                                    }
                            }
                        }
                    }
                    .frame(height: 150)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .environment(\.timeZone, calendar.timeZone)
                    .environment(\.calendar, calendar)
                    .accessibilityLabel("Hourly daytime stress")
                    if let selection, let hour = day.hours.first(where: { $0.feature.start <= selection && selection < $0.feature.end }) {
                        LooprText("\(time(hour.feature.start)) · \(label(hour))", style: .caption, color: .inkSecondary)
                            .accessibilityIdentifier("hourly-stress-readout")
                    } else {
                        LooprText("Hold to read an hour", style: .caption, color: .inkMuted)
                    }
                    LooprText("Higher reflects a faster heart rate or lower HRV than your usual quiet hours. Lower reflects a slower heart rate or higher HRV. Active hours are left out. Gaps mean there was not enough clean data.", style: .prose, color: .inkSecondary)
                    if isCurrentDay(day), day.hasSustainedHigh {
                        Button(action: openBreathing) {
                            VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                                LooprText("Take a breathing break", style: .rowTitle, color: .stress)
                                LooprText("Stress has stayed high for two hours or more. Try a calm breathing session.", style: .prose, color: .inkSecondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("hourly-stress-breathing")
                    }
                } else {
                    LooprText("Learning your baseline", style: .rowTitle)
                    LooprText(LooprLearningText.progress(have: 0, need: HourlyStress.minimumBaselineDays, noun: "days") + ". Wear your band during quiet waking hours.", style: .prose, color: .inkSecondary)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hourly-stress-timeline")
    }

    private func isCurrentDay(_ day: HourlyStressDay) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: day.timeZoneIdentifier) ?? .current
        return day.hours.first.map { calendar.isDate($0.feature.start, inSameDayAs: Date()) } ?? false
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: day?.timeZoneIdentifier ?? "") ?? .current
        return calendar
    }

    private func time(_ date: Date) -> String {
        LooprDateFormatterCache.string(from: date, format: "HH:mm", calendar: calendar)
    }

    private func label(_ hour: StressHour) -> String {
        if let score = hour.score { return "\(Int(score.rounded())) of 100, \(score >= 65 ? "High" : score <= 35 ? "Low" : "Usual")" }
        switch hour.feature.state {
        case .active: return "Active"
        case .asleep: return "Asleep"
        case .missing: return "No data"
        case .quiet: return "Learning your baseline, \(hour.daysRemaining) days remaining"
        }
    }
}
