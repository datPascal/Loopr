import SwiftUI

/// A line drawn above the stage lanes of `LooprStageTimeline`, on the same
/// clock axis: the overnight heart rate, for example.
///
/// ```swift
/// LooprStageTimeline(segments: night.hypnogram, start: main.start, highlightedStage: $stage,
///                    line: LooprStageTimelineLine(title: "Heart rate", unit: "bpm", points: minutes, accent: .heart))
/// ```
///
/// Holding and dragging on either the line or the lanes reads the same moment
/// in both. A highlighted stage washes its stretches behind the line, so you
/// can see what the heart did during deep sleep.
public struct LooprStageTimelineLine: Hashable, Sendable {
    public let title: String
    public let unit: String
    /// Readings, any order. Sorted on init; non-finite values are dropped.
    public let points: [LooprChartPoint]
    public let accent: LooprColorToken
    /// A pause longer than this between two readings breaks the line.
    public let maximumGap: TimeInterval

    public init(title: String, unit: String, points: [LooprChartPoint], accent: LooprColorToken = .heart,
                maximumGap: TimeInterval = 300) {
        self.title = title
        self.unit = unit
        self.points = points.filter { $0.value.isFinite }.sorted { $0.date < $1.date }
        self.accent = accent
        self.maximumGap = maximumGap
    }

    /// Runs of readings with no gap longer than `maximumGap`.
    public var segments: [[LooprChartPoint]] {
        var result: [[LooprChartPoint]] = []
        for point in points {
            if let last = result.last?.last, point.date.timeIntervalSince(last.date) <= maximumGap {
                result[result.count - 1].append(point)
            } else {
                result.append([point])
            }
        }
        return result
    }

    /// The vertical scale: the readings padded by a tenth of their spread,
    /// at least 10 units tall so a flat night does not look jagged.
    public var domain: ClosedRange<Double>? {
        guard let low = points.map(\.value).min(), let high = points.map(\.value).max() else { return nil }
        let spread = max(high - low, 10)
        let middle = (low + high) / 2
        let half = spread / 2 * 1.1
        return (middle - half)...(middle + half)
    }

    /// The reading closest to `date`, if one lies within half the maximum gap.
    public func value(at date: Date) -> Double? {
        guard !points.isEmpty else { return nil }
        var low = 0, high = points.count - 1
        while low < high {
            let mid = (low + high) / 2
            if points[mid].date < date { low = mid + 1 } else { high = mid }
        }
        let candidates = [low - 1, low].filter { points.indices.contains($0) }
        guard let best = candidates.min(by: { abs(points[$0].date.timeIntervalSince(date)) < abs(points[$1].date.timeIntervalSince(date)) }),
              abs(points[best].date.timeIntervalSince(date)) <= maximumGap / 2 else { return nil }
        return points[best].value
    }

    /// "52 bpm"
    public func valueText(_ value: Double) -> String {
        "\(Int(value.rounded())) \(unit)"
    }

    /// Spoken: "Heart rate, lowest 48 beats per minute, highest 72 beats per minute".
    public var accessibilitySummary: String {
        guard let low = points.min(by: { $0.value < $1.value }), let high = points.max(by: { $0.value < $1.value }) else {
            return "\(title), no readings"
        }
        let unitWords = LooprUnitFormatter.spokenUnit(unit)
        return "\(title), lowest \(Int(low.value.rounded())) \(unitWords), highest \(Int(high.value.rounded())) \(unitWords)"
    }
}

/// Draws a `LooprStageTimelineLine` across the night.
struct LooprStageTimelineLineView: View {
    @Environment(\.colorScheme) private var colorScheme

    let line: LooprStageTimelineLine
    let model: LooprStageTimelineModel
    let selection: Date?
    let highlightedStage: SleepStage?
    let revealed: Bool

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            Canvas { context, canvasSize in
                draw(in: &context, size: canvasSize)
            }
            .mask(alignment: .leading) {
                Rectangle().frame(width: revealed ? size.width : 0)
            }
            .overlay(alignment: .topLeading) {
                if let selection, let start = model.start, let end = model.end {
                    let x = LooprScrubMath.x(for: selection, width: size.width, start: start, end: end)
                    Rectangle()
                        .fill(Color.loopr(.ink).opacity(isDark ? 0.6 : 0.5))
                        .frame(width: 1, height: size.height)
                        .position(x: x, y: size.height / 2)
                        .allowsHitTesting(false)
                    if let value = line.value(at: selection), let domain = line.domain {
                        let y = Self.y(value, domain: domain, height: size.height)
                        Circle()
                            .fill(Color.loopr(line.accent))
                            .overlay(Circle().strokeBorder(Color.loopr(.background), lineWidth: 1.5))
                            .frame(width: 8, height: 8)
                            .position(x: x, y: y)
                            .allowsHitTesting(false)
                        Text(line.valueText(value))
                            .looprTypography(.confidence)
                            .fontWeight(.semibold)
                            .monospacedDigit()
                            .foregroundStyle(Color.loopr(line.accent.textInk))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.loopr(.background).opacity(0.85), in: Capsule())
                            .fixedSize()
                            .position(x: min(max(x, 30), size.width - 30), y: y < 18 ? y + 14 : y - 14)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
    }

    static func y(_ value: Double, domain: ClosedRange<Double>, height: CGFloat) -> CGFloat {
        let span = domain.upperBound - domain.lowerBound
        guard span > 0 else { return height / 2 }
        return height - CGFloat((value - domain.lowerBound) / span) * height
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        guard let start = model.start, let end = model.end, let domain = line.domain else { return }
        func x(_ date: Date) -> CGFloat { LooprScrubMath.x(for: date, width: size.width, start: start, end: end) }

        // A highlighted stage washes its stretches, so the line reads against it.
        if let highlightedStage {
            for span in model.spans where span.stage == highlightedStage {
                let rect = CGRect(x: x(span.start), y: 0, width: max(x(span.end) - x(span.start), 1), height: size.height)
                context.fill(Path(rect), with: .color(Color.loopr(span.stage.token).opacity(isDark ? 0.22 : 0.18)))
            }
        }

        // Quiet gridlines at the top and bottom of the readings.
        for fraction in [0.0, 1.0] {
            var grid = Path()
            let gy = size.height * fraction
            grid.move(to: CGPoint(x: 0, y: gy))
            grid.addLine(to: CGPoint(x: size.width, y: gy))
            context.stroke(grid, with: .color(Color.loopr(.divider)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
        }

        let dimmed = selection != nil
        for segment in line.segments {
            guard let first = segment.first else { continue }
            var path = Path()
            path.move(to: CGPoint(x: x(first.date), y: Self.y(first.value, domain: domain, height: size.height)))
            for point in segment.dropFirst() {
                path.addLine(to: CGPoint(x: x(point.date), y: Self.y(point.value, domain: domain, height: size.height)))
            }
            if segment.count == 1 {
                let center = CGPoint(x: x(first.date), y: Self.y(first.value, domain: domain, height: size.height))
                context.fill(Path(ellipseIn: CGRect(x: center.x - 1.5, y: center.y - 1.5, width: 3, height: 3)),
                             with: .color(Color.loopr(line.accent)))
            }
            context.stroke(path, with: .color(Color.loopr(line.accent).opacity(dimmed ? 0.55 : 0.95)),
                           style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
    }

    private var isDark: Bool { LooprAppearance.isDark(colorScheme) }
}
