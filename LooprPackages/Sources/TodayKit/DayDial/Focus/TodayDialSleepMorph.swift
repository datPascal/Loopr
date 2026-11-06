import CoreGraphics
import DesignSystem
import Foundation

/// Where Sleep's stage chart draws its lanes inside the focus card, in the card square's points. It repeats
/// `LooprStageTimeline`'s arithmetic (label column, lane height, bar height, linear clock axis), so the peeled spans land
/// exactly where the real chart takes over.
struct TodayDialStageChartLayout: Equatable {
    /// The whole chart: lane labels, lanes and the axis under them.
    let frame: CGRect
    /// The lane column, without labels or axis.
    let lanes: CGRect
    let rowHeight: CGFloat
    let barHeight: CGFloat
    let start: Date
    let end: Date

    /// - Parameters:
    ///   - laneHeight: `LooprStageTimeline`'s 24-point lane, scaled for the text size.
    ///   - labelWidth: Its 46-point label column, scaled and capped at 62.
    init(frame: CGRect, laneHeight: CGFloat, labelWidth: CGFloat, start: Date, end: Date) {
        self.frame = frame
        let lanesLeft = frame.minX + labelWidth + LooprSpacing.xs
        lanes = CGRect(x: lanesLeft, y: frame.minY, width: max(frame.maxX - lanesLeft, 1),
                       height: laneHeight * CGFloat(LooprStageTimelineModel.laneOrder.count))
        rowHeight = laneHeight
        barHeight = max(6, min(laneHeight * 0.62, 16))
        self.start = start
        self.end = end
    }

    /// The chart's height for a lane height: four lanes, the gap and the 14-point axis.
    static func height(laneHeight: CGFloat) -> CGFloat {
        laneHeight * CGFloat(LooprStageTimelineModel.laneOrder.count) + LooprSpacing.xxs + 2 + 14
    }

    func x(_ date: Date) -> CGFloat {
        lanes.minX + LooprScrubMath.x(for: date, width: lanes.width, start: start, end: end)
    }

    func laneMidY(_ stage: SleepStage) -> CGFloat {
        lanes.minY + CGFloat(LooprStageTimelineModel.laneOrder.firstIndex(of: stage) ?? 0) * rowHeight + rowHeight / 2
    }

    /// The bar a span becomes, as the chart draws it.
    func bar(start: Date, end: Date, stage: SleepStage) -> CGRect {
        let left = x(start)
        return CGRect(x: left, y: laneMidY(stage) - barHeight / 2, width: max(x(end) - left, 1.5), height: barHeight)
    }

    /// The faint track behind each lane.
    func track(_ index: Int) -> CGRect {
        CGRect(x: lanes.minX, y: lanes.minY + CGFloat(index) * rowHeight + (rowHeight - barHeight) / 2, width: lanes.width,
               height: barHeight)
    }
}

/// The peel from the dial to the chart. Each stage span leaves the ring in the order the night happened, swings out a
/// little and lands as its bar. A span is sampled into the same number of points on the ring and on the bar, and every point
/// travels on its own, so the curved band straightens as it flies.
struct TodayDialSleepMorph {
    struct Piece: Equatable, Identifiable {
        let id: Int
        let stage: SleepStage
        /// Where on the shared progress this piece starts, 0 to `maximumDelay`.
        let delay: Double
        let source: [CGPoint]
        let target: [CGPoint]
        /// How far the middle of the flight bows out, away from the dial's centre.
        let bow: CGVector
    }

    /// Points along each long edge of a piece.
    static let samples = 14
    /// The last span starts this far into the shared progress. Short enough that the night reads as one wave, not a queue.
    static let maximumDelay = 0.26

    let pieces: [Piece]

    /// - Parameters:
    ///   - spans: The hypnogram's spans as the dial draws them.
    ///   - side: The dial square's side in points.
    init(spans: [TodayDialStageSpan], side: CGFloat, chart: TodayDialStageChartLayout) {
        let scale = side / TodayDialGeometry.viewBox
        let ordered = spans.sorted { $0.arc.start < $1.arc.start }
        let count = ordered.count
        pieces = ordered.enumerated().map { index, span in
            // The dial trims a hair off each span; the chart does not, so the gap closes on the way.
            let sweep = span.arc.sweep > 0.36 ? span.arc.sweep - 0.18 : span.arc.sweep
            func ring(_ radius: Double, _ u: Double) -> CGPoint {
                let p = TodayDialGeometry.point(radius: radius, angle: span.arc.startAngle + sweep * u)
                return CGPoint(x: p.x * scale, y: p.y * scale)
            }
            let n = Self.samples
            let steps = (0...n).map { Double($0) / Double(n) }
            let outer = steps.map { ring(span.outerRadius, $0) }
            let inner = steps.map { ring(span.innerRadius, $0) }

            let bar = chart.bar(start: span.arc.start, end: span.arc.end, stage: span.stage)
            // Pair the ring's visual left with the bar's left and its upper edge with the bar's top, so no piece turns
            // itself inside out mid-flight. At the bottom of the dial time runs right to left.
            let mirrored = (outer.first!.x + inner.first!.x) > (outer.last!.x + inner.last!.x)
            let outerIsUpper = outer[n / 2].y < inner[n / 2].y
            func barX(_ u: Double) -> CGFloat { mirrored ? bar.maxX - bar.width * u : bar.minX + bar.width * u }
            let top = steps.map { CGPoint(x: barX($0), y: bar.minY) }
            let bottom = steps.map { CGPoint(x: barX($0), y: bar.maxY) }
            let outerTarget = outerIsUpper ? top : bottom
            let innerTarget = outerIsUpper ? bottom : top

            let middle = TodayDialGeometry.point(radius: span.radius, angle: span.arc.startAngle + sweep / 2)
            let outward = CGVector(dx: middle.x - TodayDialGeometry.centre, dy: middle.y - TodayDialGeometry.centre)
            let length = max(hypot(outward.dx, outward.dy), 1)
            // A gentle swing away from the centre, so a span visibly lifts off the ring without leaving the card.
            let reach = side * 0.035
            return Piece(id: span.id, stage: span.stage,
                         delay: count > 1 ? Self.maximumDelay * Double(index) / Double(count - 1) : 0,
                         source: outer + inner.reversed(), target: outerTarget + innerTarget.reversed(),
                         bow: CGVector(dx: outward.dx / length * reach, dy: outward.dy / length * reach))
        }
    }

    /// The piece's own progress at the shared progress `progress`, eased, 0 on the ring and 1 on the bar. The shared
    /// spring already eases out; the piece eases in and out on top, so every span leaves softly and lands without a bump.
    static func local(_ piece: Piece, progress: Double) -> Double {
        let t = min(max((progress - piece.delay) / (1 - maximumDelay), 0), 1)
        return easeInOut(t)
    }

    /// The piece's outline at the shared progress.
    static func outline(_ piece: Piece, progress: Double) -> [CGPoint] {
        let e = local(piece, progress: progress)
        let lift = sin(min(max(e, 0), 1) * .pi)
        return zip(piece.source, piece.target).map { source, target in
            CGPoint(x: source.x + (target.x - source.x) * e + piece.bow.dx * lift,
                    y: source.y + (target.y - source.y) * e + piece.bow.dy * lift)
        }
    }

    /// Smootherstep: zero speed at both ends, so a span neither jerks off the ring nor overshoots its lane.
    static func easeInOut(_ t: Double) -> Double {
        t * t * t * (t * (t * 6 - 15) + 10)
    }
}
