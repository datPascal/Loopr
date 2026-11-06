import DomainKit
import Foundation
import JournalKit
import RoutineKit
import Testing

/// LV-07.3: the experiment strip draws every counted night as a dot, split into on and off nights, against the noise
/// band around the off nights' average.
struct ProtocolExperimentStripTests {
    @Test func theRunningStripHasEveryCountedNightAndTheBand() throws {
        let item = try ProtocolExperimentTestData.running()
        let strip = ProtocolExperimentStrip.make(item, showsRange: false)

        #expect(strip.dots.count == 8)
        #expect(strip.onDots.map(\.value) == [86, 81, 90, 79])
        #expect(strip.offDots.map(\.value) == [76, 82, 74, 80])
        #expect(strip.onDots.count == item.report.on.nights && strip.offDots.count == item.report.off.nights)
        #expect(strip.dots.map(\.night) == Array(1...8), "Dots land in night order")
        #expect(strip.dots.allSatisfy { (0...1).contains($0.position) })
        #expect(strip.onMean == 84 && strip.offMean == 78)
        let band = try #require(strip.band)
        #expect(abs(band.lowerBound - 69) < 1e-6 && abs(band.upperBound - 87) < 1e-6, "Off average 78, plus and minus 9")
        #expect(strip.likelyRange == nil, "A running experiment draws no range")
        #expect(strip.onTitle == "Magnesium" && strip.offTitle == "Other nights")
        // The axis holds every dot and the whole band.
        #expect(strip.lowerBound <= 69 && strip.upperBound >= 90)
        #expect(strip.position(strip.lowerBound) == 0 && strip.position(strip.upperBound) == 1)
        #expect(strip.ticks.count == 3)
    }

    @Test func voiceOverReadsBothGroupsTheDifferenceAndTheSpread() throws {
        let strip = ProtocolExperimentStrip.make(try ProtocolExperimentTestData.running(), showsRange: false)
        #expect(strip.accessibilitySummary
            == "Magnesium: 4 nights, average 84 min. Other nights: 4 nights, average 78 min. Difference plus 6 min, inside your usual spread of 9 min.")
    }

    @Test func leftOutNightsAreNotDrawn() throws {
        let startDay = ProtocolExperimentTestData.day(11, 6)
        let experiment = Experiment(start: try ProtocolExperimentTestData.start(startDay: startDay, planned: 14, minimum: 7))
        // Night 1 was not done, night 3 has no reading, night 2 (off) has no reading.
        let nights = try ProtocolExperimentTestData.nights(experiment, on: [86, 81, 90, 79], off: [76, 82, 74, 80],
                                                           override: [1: (.missed, 86), 3: (.kept, nil), 2: (.missed, nil)])
        let item = ProtocolExperimentTestData.item(experiment, nights: nights,
                                                   baseline: ProtocolExperimentTestData.baseline(mean: 78, spread: 9, before: startDay))
        let strip = ProtocolExperimentStrip.make(item, showsRange: false)
        #expect(strip.onDots.map(\.night) == [5, 7])
        #expect(strip.offDots.map(\.night) == [4, 6, 8])
        #expect(strip.onDots.count == item.report.on.nights && strip.offDots.count == item.report.off.nights,
                "The strip counts nights the way the report does")
    }

    @Test func washoutNightsAreNotDrawn() throws {
        let startDay = ProtocolExperimentTestData.day(10, 1)
        let experiment = Experiment(start: try ProtocolExperimentTestData.start(startDay: startDay, planned: 12, minimum: 2,
                                                                                design: .blocks(length: 3), washout: 1),
                                    status: .finished, endDay: startDay.adding(days: 11))
        let nights = try ProtocolExperimentTestData.nights(experiment, on: [80, 81, 82, 79, 80], off: [60, 61, 62, 59, 60])
        #expect(nights.contains { $0.isWashout })
        let item = ProtocolExperimentTestData.item(experiment, nights: nights,
                                                   baseline: ProtocolExperimentTestData.baseline(mean: 60, spread: 5, before: startDay))
        let strip = ProtocolExperimentStrip.make(item, showsRange: true)
        #expect(!strip.dots.contains { $0.value == 999 })
        #expect(strip.onDots.count == item.report.on.nights && strip.offDots.count == item.report.off.nights)
    }

    @Test func aResultDrawsTheLikelyRangeOverTheOffAverage() throws {
        let item = try ProtocolExperimentTestData.finished()
        let strip = ProtocolExperimentStrip.make(item, showsRange: true)
        let range = try #require(item.report.range)
        let likely = try #require(strip.likelyRange)
        #expect(strip.offMean == 60)
        #expect(abs(likely.lowerBound - (60 + range.lowerBound)) < 1e-9 && abs(likely.upperBound - (60 + range.upperBound)) < 1e-9)
        #expect(strip.lowerBound <= likely.lowerBound && strip.upperBound >= likely.upperBound)
        #expect(strip.accessibilitySummary.contains("outside your usual spread of 5 min"))
        #expect(strip.accessibilitySummary.contains("95 percent range"))
        #expect(ProtocolExperimentStrip.make(item, showsRange: false).likelyRange == nil)
    }

    @Test func noCountedNightsDrawsTheEmptyShape() throws {
        let startDay = ProtocolExperimentTestData.day(11, 13)
        let experiment = Experiment(start: try ProtocolExperimentTestData.start(startDay: startDay, planned: 14, minimum: 7))
        let item = ProtocolExperimentTestData.item(experiment, nights: [],
                                                   baseline: ProtocolExperimentTestData.baseline(mean: 78, spread: 9, before: startDay))
        let strip = ProtocolExperimentStrip.make(item, showsRange: false)
        #expect(strip.isEmpty)
        #expect(strip.band == nil, "No average yet, so no band to centre")
        #expect(strip.lowerBound < strip.upperBound)
        #expect(strip.accessibilitySummary == "No counted nights with a deep sleep reading yet.")
    }

    // MARK: ICP R1-OPT-11

    @Test func theBandCaptionStatesTheHalfWidthTheBandIsDrawnWith() throws {
        let strip = ProtocolExperimentStrip.make(try ProtocolExperimentTestData.running(), showsRange: false)
        let band = try #require(strip.band)
        let offMean = try #require(strip.offMean)
        #expect(abs((band.upperBound - offMean) - 9) < 1e-6 && abs((offMean - band.lowerBound) - 9) < 1e-6)
        #expect(strip.bandCaption == ExperimentCopy.spreadExplanation(spread: 9, unit: "min"))
        #expect(strip.bandCaption?.hasPrefix("The shaded band is your usual spread, 9 min either side of the other nights' average.") == true)
        #expect(strip.likelyRangeCaption == nil, "A running experiment draws no bracket, so it explains none")
    }

    @Test func aResultSaysWhoseBracketItIs() throws {
        let strip = ProtocolExperimentStrip.make(try ProtocolExperimentTestData.finished(), showsRange: true)
        let likely = try #require(strip.likelyRange)
        let caption = try #require(strip.likelyRangeCaption)
        #expect(caption.hasPrefix("The bracket under \(strip.onTitle) is the 95% range for its average, "))
        #expect(caption.contains("\(ExperimentCopy.amount(likely.lowerBound)) to \(ExperimentCopy.amount(likely.upperBound)) min, "
                                 + "worked out from both groups of nights."))
        #expect(caption.hasSuffix("It is measured against the other nights' average, so that row has no bracket."))
    }

    @Test func equalNightsStackIntoLanesInsteadOfCoveringEachOther() {
        // Three nights on the same value: the line, then above, then below.
        #expect(ProtocolExperimentStrip.lanes(positions: [0.5, 0.5, 0.5], minimumGap: 0.05) == [0, 1, -1])
        // Far-apart nights all stay on the line.
        #expect(ProtocolExperimentStrip.lanes(positions: [0.1, 0.5, 0.9], minimumGap: 0.05) == [0, 0, 0])
        // Only the close pair stacks; the order of the result follows the input.
        #expect(ProtocolExperimentStrip.lanes(positions: [0.9, 0.52, 0.5], minimumGap: 0.05) == [0, 1, 0])
        // No gap to keep, or a broken one, leaves every dot on the line.
        #expect(ProtocolExperimentStrip.lanes(positions: [0.5, 0.5], minimumGap: 0) == [0, 0])
        #expect(ProtocolExperimentStrip.lanes(positions: [0.5, 0.5], minimumGap: .nan) == [0, 0])
        #expect(ProtocolExperimentStrip.lanes(positions: [], minimumGap: 0.05).isEmpty)
    }

    @Test func noTwoDotsInALaneAreCloserThanTheGap() {
        // Seven "other nights" piled at 55 to 56 bpm on a 50 to 62 axis, the shape the critique captured.
        let values = [55.0, 55.2, 55.5, 55.5, 55.8, 56.0, 55.1]
        let positions = values.map { ($0 - 50) / 12 }
        let gap = 0.04
        let lanes = ProtocolExperimentStrip.lanes(positions: positions, minimumGap: gap)
        for i in positions.indices {
            for j in positions.indices where i < j && lanes[i] == lanes[j] {
                #expect(abs(positions[i] - positions[j]) >= gap)
            }
        }
        #expect(ProtocolExperimentStrip.lanes(positions: positions, minimumGap: gap) == lanes, "The same nights stack the same way")
    }
}
