import Charts
import DesignSystem
import AnalyticsKit
import SwiftUI

/// A session's heart rate over time, with the zones as colour bands behind it. Hold, then drag, to read a moment.
struct WorkoutEffortChart: View {
    private struct Point: Identifiable {
        let date: Date
        let bpm: Double
        let segment: Int
        var id: Date { date }
    }

    let samples: [WorkoutHeartSample]
    let zones: HeartRateZoneSet?
    let target: ClosedRange<Int>?
    let pauses: [WorkoutPause]
    let efforts: [WorkoutEffort]
    var height: CGFloat = 176
    @State private var selection: Date?

    /// Ten-second averages: enough to show the shape, few enough to draw at once.
    private var points: [Point] {
        let averaged = WorkoutSessionAnalysis.averages(samples: samples, seconds: 10)
        var segment = 0
        var previous: Date?
        return averaged.map { sample in
            if let previous, sample.date.timeIntervalSince(previous) > WorkoutSessionAnalysis.gapSeconds { segment += 1 }
            previous = sample.date
            return Point(date: sample.date, bpm: sample.bpm, segment: segment)
        }
    }

    private var domain: ClosedRange<Double> { Self.domain(for: samples.map(\.bpm)) }

    /// The readings with ten beats of room, on tens, at least 40 beats tall so a calm session draws calm.
    static func domain(for values: [Double]) -> ClosedRange<Double> {
        let low = (max(30, (values.min() ?? 60) - 10) / 10).rounded(.down) * 10
        let high = (((values.max() ?? 180) + 10) / 10).rounded(.up) * 10
        return low...max(high, low + 40)
    }

    private var bounds: ClosedRange<Date> {
        guard let first = samples.first?.date, let last = samples.last?.date, first < last else {
            let now = samples.first?.date ?? Date(timeIntervalSince1970: 0)
            return now...now.addingTimeInterval(60)
        }
        return first...last
    }

    private var selected: Point? {
        guard let selection else { return nil }
        return points.min { abs($0.date.timeIntervalSince(selection)) < abs($1.date.timeIntervalSince(selection)) }
    }

    var body: some View {
        let points = points
        let domain = domain
        let bounds = bounds
        Chart {
            ForEach(bands(in: domain), id: \.number) { band in
                RectangleMark(xStart: .value("Start", bounds.lowerBound), xEnd: .value("End", bounds.upperBound),
                              yStart: .value("Low", band.low), yEnd: .value("High", band.high))
                    .foregroundStyle(Color.loopr(LooprZonePalette.token(for: band.number)).opacity(band.isTarget ? 0.32 : 0.14))
            }
            ForEach(efforts) { effort in
                RectangleMark(xStart: .value("Start", effort.start), xEnd: .value("End", effort.end))
                    .foregroundStyle(Color.loopr(.ink).opacity(0.07))
            }
            ForEach(Array(pauses.enumerated()), id: \.offset) { _, pause in
                RuleMark(x: .value("Paused", pause.start))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    .foregroundStyle(Color.loopr(.inkMuted))
            }
            ForEach(points) { point in
                LineMark(x: .value("Time", point.date), y: .value("bpm", point.bpm), series: .value("Stretch", point.segment))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(Color.loopr(.ink))
            }
            if let selected {
                RuleMark(x: .value("Selected", selected.date))
                    .foregroundStyle(Color.loopr(.ink).opacity(0.45))
                PointMark(x: .value("Selected", selected.date), y: .value("bpm", selected.bpm))
                    .foregroundStyle(Color.loopr(.ink))
                    .symbolSize(44)
            }
        }
        .chartXScale(domain: bounds)
        .chartYScale(domain: domain)
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(Color.loopr(.divider).opacity(0.5))
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        LooprText(Self.elapsed(date.timeIntervalSince(bounds.lowerBound)), style: .caption, color: .inkSecondary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisValueLabel {
                    if let bpm = value.as(Double.self) { LooprText("\(Int(bpm))", style: .caption, color: .inkSecondary) }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .looprScrub { x in
                        guard let x else { selection = nil; return }
                        let originX = proxy.plotFrame.map { geometry[$0].origin.x } ?? 0
                        if let date: Date = proxy.value(atX: x - originX) { selection = date }
                    }
            }
        }
        .frame(height: height)
        .overlay(alignment: .topTrailing) {
            if let selected { readout(selected, start: bounds.lowerBound) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenSummary)
        .accessibilityIdentifier("workout-detail-heart-rate-chart")
    }

    private func readout(_ point: Point, start: Date) -> some View {
        let zone = zones?.zoneNumber(for: point.bpm) ?? 0
        let parts = [Self.elapsed(point.date.timeIntervalSince(start)), "\(Int(point.bpm.rounded())) bpm", zone > 0 ? "Zone \(zone)" : nil]
        return LooprText(parts.compactMap { $0 }.joined(separator: " · "), style: .caption)
            .padding(.horizontal, LooprSpacing.xs)
            .padding(.vertical, LooprSpacing.xxs)
            .background(Color.loopr(.surface), in: Capsule())
            .accessibilityHidden(true)
    }

    private var spokenSummary: String {
        let values = samples.map(\.bpm)
        guard let low = values.min(), let high = values.max() else { return "No heart rate" }
        return "Heart rate over the session, from \(Int(low)) to \(Int(high)) beats per minute"
    }

    private struct Band { let number: Int; let low: Double; let high: Double; let isTarget: Bool }

    private func bands(in domain: ClosedRange<Double>) -> [Band] {
        guard let zones else { return [] }
        return zones.zones.compactMap { zone in
            // The top zone has no real ceiling, so it runs to the top of the chart.
            let upper = zone.number == 5 ? domain.upperBound : zone.upperBPM
            let low = max(zone.lowerBPM, domain.lowerBound), high = min(upper, domain.upperBound)
            guard high > low else { return nil }
            let isTarget = target.map { Double($0.lowerBound) < high && Double($0.upperBound) > low } ?? false
            return Band(number: zone.number, low: low, high: high, isTarget: isTarget)
        }
    }

    static func elapsed(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(0, seconds) / 60)
        return minutes >= 60 ? String(format: "%d:%02d h", minutes / 60, minutes % 60) : "\(minutes) min"
    }
}
