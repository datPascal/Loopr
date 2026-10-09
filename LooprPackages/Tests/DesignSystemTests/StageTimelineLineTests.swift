import Foundation
import Testing
@testable import DesignSystem

/// The optional line over `LooprStageTimeline` (the overnight heart rate).
struct StageTimelineLineTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func point(_ minute: Int, _ value: Double) -> LooprChartPoint {
        LooprChartPoint(date: start.addingTimeInterval(Double(minute) * 60), value: value)
    }

    @Test func pointsAreSortedAndNonFiniteValuesDropped() {
        let line = LooprStageTimelineLine(title: "Heart rate", unit: "bpm", points: [point(2, 50), point(0, 55), point(1, .nan)])
        #expect(line.points.map(\.value) == [55, 50])
    }

    @Test func aLongPauseBreaksTheLine() {
        let line = LooprStageTimelineLine(title: "Heart rate", unit: "bpm",
                                          points: [point(0, 50), point(1, 52), point(20, 60), point(21, 61)], maximumGap: 300)
        #expect(line.segments.map(\.count) == [2, 2])
    }

    @Test func theScaleIsPaddedAndAtLeastTenTall() {
        let flat = LooprStageTimelineLine(title: "Heart rate", unit: "bpm", points: [point(0, 50), point(1, 51)])
        let domain = flat.domain
        #expect(domain.map { $0.upperBound - $0.lowerBound } == 11)
        #expect(domain.map { $0.contains(50) && $0.contains(51) } == true)
        #expect(LooprStageTimelineLine(title: "x", unit: "bpm", points: []).domain == nil)
    }

    @Test func readingAMomentPicksTheNearestPointInsideHalfTheGap() {
        let line = LooprStageTimelineLine(title: "Heart rate", unit: "bpm", points: [point(0, 50), point(1, 52), point(10, 60)],
                                          maximumGap: 300)
        #expect(line.value(at: start.addingTimeInterval(40)) == 52)
        #expect(line.value(at: start.addingTimeInterval(-20)) == 50)
        #expect(line.value(at: start.addingTimeInterval(5 * 60 + 30)) == nil, "In a gap there is no reading")
        #expect(line.valueText(51.6) == "52 bpm")
    }

    @Test func voiceOverHearsTheLowestAndHighest() {
        let line = LooprStageTimelineLine(title: "Heart rate", unit: "bpm", points: [point(0, 48), point(1, 72)])
        #expect(line.accessibilitySummary == "Heart rate, lowest 48 beats per minute, highest 72 beats per minute")
    }

    @Test func stageTotalsFromFinerEpochsOverrideTheDrawnMinutes() {
        let spans = [LooprStageSpan(id: 0, stage: .deep, start: start, end: start.addingTimeInterval(60 * 60)),
                     LooprStageSpan(id: 1, stage: .light, start: start.addingTimeInterval(3_600), end: start.addingTimeInterval(4 * 3_600))]
        let drawn = LooprStageTimelineModel(spans: spans)
        #expect(drawn.totals[.deep] == 60)
        let accounted = LooprStageTimelineModel(spans: spans, stageTotals: [.deep: 76, .light: 164])
        #expect(accounted.totals[.deep] == 76)
        #expect(accounted.highlightSummary(for: .deep).hasPrefix("Deep · 1 h 16 m · 32%"))
        #expect(LooprStageTimelineModel(spans: spans, stageTotals: [:]).totals[.deep] == 60)
    }
}
