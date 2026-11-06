import Testing
@testable import DesignSystem

/// Sentence-case labels and barbell arithmetic from the 2026-10-22 redesign.
struct RedesignTextAndPlatesTests {
    @Test func allCapsLabelsBecomeSentenceCase() {
        #expect("LAST 3 MIN".looprLabelCased == "Last 3 min")
        #expect("YOUR USUAL RANGE".looprLabelCased == "Your usual range")
        #expect("HRV · LAST NIGHT".looprLabelCased == "HRV · Last night")
        #expect("TUE 22 SEP · NO SCORE".looprLabelCased == "Tue 22 Sep · No score")
        #expect("USUAL RANGE 49-52 MS".looprLabelCased == "Usual range 49-52 ms")
        #expect("142 BPM".looprLabelCased == "142 bpm")
        #expect("30 OF 30 NIGHTS".looprLabelCased == "30 of 30 nights")
        #expect("AFTER GPS GAP".looprLabelCased == "After GPS gap")
        #expect("1-YEAR AVERAGE".looprLabelCased == "1-year average")
        // Quick log chips (R2-WOD-06, R2-DES-15).
        #expect("WOD".looprLabelCased == "WOD")
        #expect("HIIT".looprLabelCased == "HIIT")
    }

    @Test func textThatIsAlreadyCasedIsLeftAlone() {
        for text in ["Tue 22 Sep", "Last night", "HRV", "M", "S", "7.9", "", "Synced 5 min ago", "PR"] {
            #expect(text.looprLabelCased == text)
        }
    }

    @Test func platesAreCountedPerSideHeaviestFirst() {
        #expect(LooprPlateMath.perSide(total: 100).plates == [25, 15])
        #expect(LooprPlateMath.perSide(total: 140).plates == [25, 25, 10])
        #expect(LooprPlateMath.perSide(total: 22.5).plates == [1.25])
        #expect(LooprPlateMath.perSide(total: 20).plates.isEmpty)
        #expect(LooprPlateMath.perSide(total: 81).remainder == 0.5)
        #expect(LooprPlateMath.caption(total: 100) == "25 + 15 each side")
        #expect(LooprPlateMath.caption(total: 20) == "Just the bar")
        #expect(LooprPlateMath.caption(total: 15) == nil)
        #expect(LooprPlateMath.caption(total: 81) == "25 + 5 each side, about")
    }

    @Test func theWeightIsComparedWithLastTime() {
        #expect(LooprLoadComparison.text(load: 100, lastTime: 100) == "Same weight as last time")
        #expect(LooprLoadComparison.text(load: 110, lastTime: 100) == "+10 kg on last time")
        #expect(LooprLoadComparison.text(load: 70, lastTime: 100) == "30 kg under last time")
        #expect(LooprLoadComparison.text(load: 82.5, lastTime: 80) == "+\(2.5.formatted()) kg on last time")
        #expect(LooprLoadComparison.text(load: 80, lastTime: nil) == nil)
    }
}
