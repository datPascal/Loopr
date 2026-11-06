import Foundation
import SwiftUI
import Testing
@testable import DesignSystem

// The pure parts of LooprHighlightBars: scale, emphasis and the spoken summary.

@MainActor
struct HighlightBarsTests {
    private let start = Date(timeIntervalSince1970: 1_760_000_000)

    private func bars(_ values: [Double?], highlighted: Set<Int> = []) -> [LooprHighlightBar] {
        values.enumerated().map { index, value in
            LooprHighlightBar(date: start.addingTimeInterval(Double(index) * 86_400), value: value, isHighlighted: highlighted.contains(index))
        }
    }

    @Test func scaleTopIsTheLargestReadingOrTheMinimum() {
        let model = LooprHighlightBarsModel(bars: bars([72, 58, nil, 36]))
        #expect(model.top == 72)
        #expect(model.share(of: 36) == 0.5)
        #expect(model.share(of: 72) == 1)
        #expect(LooprHighlightBarsModel(bars: bars([10, 20]), minimumTop: 100).top == 100)
    }

    @Test func negativeReadingsDrawNoBarAndNonFiniteReadingsAreGaps() {
        let model = LooprHighlightBarsModel(bars: bars([50]))
        #expect(model.share(of: -5) == 0)
        #expect(model.share(of: 500) == 1)
        #expect(LooprHighlightBar(date: start, value: .nan, isHighlighted: true).value == nil)
        #expect(LooprHighlightBarsModel(bars: []).top > 0)
    }

    @Test func gapsAreNeverHighlightedBars() {
        let model = LooprHighlightBarsModel(bars: bars([60, nil, 40], highlighted: [1]))
        #expect(!model.hasHighlight)
        #expect(model.highlightedCount == 0)
    }

    @Test func emphasisDimsOnlyWhenSomeBarsAreHighlighted() {
        let marked = LooprHighlightBarsModel(bars: bars([72, 58, 51], highlighted: [1, 2]))
        #expect(marked.hasHighlight)
        #expect(marked.highlightedCount == 2)
        #expect(LooprHighlightBarsModel.opacity(isHighlighted: true, hasHighlight: true) == 1)
        #expect(LooprHighlightBarsModel.opacity(isHighlighted: false, hasHighlight: true) == 0.35)
        // Nothing to tell apart: every bar stays at full strength.
        let plain = LooprHighlightBarsModel(bars: bars([72, 58, 51]))
        #expect(!plain.hasHighlight)
        #expect(LooprHighlightBarsModel.opacity(isHighlighted: false, hasHighlight: plain.hasHighlight) == 1)
    }

    @Test func speechNamesTheHighlightedDays() {
        let model = LooprHighlightBarsModel(bars: bars([72, 58, 51, 56], highlighted: [1, 2]))
        let text = LooprHighlightBarsSpeech.summary(model: model) { "\(Int($0)) min" }
        #expect(text.contains("4 of 4 days measured"))
        #expect(text.contains("highest 72 min"))
        #expect(text.contains("lowest 51 min"))
        #expect(text.contains("Highlighted, 2 days: "))
        #expect(text.contains("58 min"))
        let single = LooprHighlightBarsModel(bars: bars([72, 58], highlighted: [1]))
        #expect(LooprHighlightBarsSpeech.summary(model: single) { "\(Int($0)) min" }.contains("Highlighted, 1 day: "))
    }

    @Test func speechSaysNothingAboutHighlightWhenThereIsNone() {
        let model = LooprHighlightBarsModel(bars: bars([72, 58]))
        #expect(!LooprHighlightBarsSpeech.summary(model: model) { "\(Int($0))" }.contains("Highlighted"))
        #expect(LooprHighlightBarsSpeech.summary(model: LooprHighlightBarsModel(bars: bars([nil, nil]))) { "\($0)" } == "No readings")
    }

    @Test func sampleWeekMatchesTheMockup() {
        let sample = LooprSampleNight.highlightedDeepSleep(endingOn: start)
        #expect(sample.compactMap(\.value) == [72, 70, 69, 58, 51, 47, 56])
        #expect(sample.map(\.isHighlighted) == [false, false, false, true, true, true, false])
    }
}
