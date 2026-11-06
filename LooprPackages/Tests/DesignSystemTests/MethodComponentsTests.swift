@testable import DesignSystem
import Testing

/// LV-08b step 3: the shared pieces of a method page.
struct MethodComponentsTests {
    @Test func waterfallBarsChainAndTheTotalSpansStartToEnd() {
        let model = LooprWaterfallModel(start: 50, steps: [
            LooprWaterfallStep(id: "a", label: "A", value: 6.5),
            LooprWaterfallStep(id: "b", label: "B", value: -2.25),
            LooprWaterfallStep(id: "c", label: "C", value: 0.4)
        ], totalLabel: "Result")
        #expect(model.bars.count == 4)
        #expect(model.bars[0].from == 50 && model.bars[0].to == 56.5)
        #expect(model.bars[1].from == 56.5 && model.bars[1].to == 54.25)
        #expect(abs(model.bars[2].to - 54.65) < 1e-9)
        let total = model.bars[3]
        #expect(total.isTotal && total.from == 50 && abs(total.to - 54.65) < 1e-9)
        #expect(abs(model.sum - 4.65) < 1e-9)
        #expect(abs(model.end - 54.65) < 1e-9)
        #expect(model.lower == 50 && model.upper == 56.5)
    }

    /// PhenoAge's shape: one dominant term (about −84 years) against marker terms of 0.7 to 48 years. Every bar keeps
    /// one scale, so its width is the step times points per unit, and a tiny term is held at the minimum width.
    @Test func everyBarIsProportionalToItsStepAndAtLeastTheMinimum() {
        let values = [-17.14, 7.38, 10.83, -0.73, -3.99, 26.75, 47.67, 1.47, 4.30, -83.75, 0.01]
        let model = LooprWaterfallModel(start: 50, steps: values.enumerated().map {
            LooprWaterfallStep(id: "s\($0.offset)", label: "S\($0.offset)", value: $0.element)
        }, totalLabel: "Result")
        let track = 300.0, minimum = Double(LooprWaterfall.minimumBarWidth)
        let scale = model.pointsPerUnit(trackWidth: track)
        #expect(abs(scale - track / (model.upper - model.lower)) < 1e-9)
        for bar in model.bars where !bar.isTotal {
            let segment = model.segment(for: bar, trackWidth: track, minimumWidth: minimum)
            #expect(abs(segment.width - max(abs(bar.value) * scale, minimum)) < 1e-9, "\(bar.id) width")
            #expect(segment.width >= minimum)
            #expect(segment.x >= 0 && segment.x + segment.width <= track + 1e-9, "\(bar.id) leaves the track")
            // A bar wide enough to draw at its true length starts at its running total before the step.
            if abs(bar.value) * scale >= minimum {
                let left = model.position(min(bar.from, bar.to)) * track
                #expect(abs(segment.x - left) < 1e-9, "\(bar.id) does not start at its running total")
            }
        }
        // The dominant term spans most of the track; the 0.01 term is held at the minimum.
        let dominant = model.segment(for: model.bars[9], trackWidth: track, minimumWidth: minimum)
        #expect(dominant.width > track * 0.8)
        #expect(model.segment(for: model.bars[10], trackWidth: track, minimumWidth: minimum).width == minimum)
        let total = model.segment(for: model.bars[11], trackWidth: track, minimumWidth: minimum)
        #expect(abs(total.width - max(abs(model.sum) * scale, minimum)) < 1e-9)
    }

    @Test func waterfallDropsNonFiniteStepsAndKeepsPositionsInRange() {
        let model = LooprWaterfallModel(start: 10, steps: [
            LooprWaterfallStep(id: "a", label: "A", value: .nan),
            LooprWaterfallStep(id: "b", label: "B", value: -4)
        ], totalLabel: "Result")
        #expect(model.steps.map(\.id) == ["b"])
        #expect(model.position(6) == 0)
        #expect(model.position(10) == 1)
        #expect(model.position(100) == 1)
        let flat = LooprWaterfallModel(start: 3, steps: [], totalLabel: "Result")
        #expect(flat.position(3) == 0.5)
    }

    @Test func formulaSetsAndSpeaksItsTokens() {
        let line = LooprFormulaLine([
            .variable("PhenoAge"), .op("="), .number("141.50"), .op("+"), .function("ln"), .op("("),
            .op("−"), .number("0.00553"), .op("·"), .function("ln"), .op("("), .number("1"), .op("−"),
            .variable("M"), .op(")"), .op(")"), .op("/"), .number("0.090165")
        ])
        #expect(line.plainText == "PhenoAge = 141.50 + ln(−0.00553 · ln(1 − M)) / 0.090165")
        #expect(line.spokenText == "PhenoAge equals 141.50 plus natural log of minus 0.00553 times natural log of 1 minus M divided by 0.090165")
    }

    @Test func codeCardWritesRangesForPeopleAndForGitHub() {
        #expect(LooprCodeCardFormat.lineLabel(187...215) == "Lines 187 to 215")
        #expect(LooprCodeCardFormat.lineLabel(12...12) == "Line 12")
        #expect(LooprCodeCardFormat.fragment(187...215) == "#L187-L215")
        #expect(LooprCodeCardFormat.fragment(12...12) == "#L12")
        #expect(LooprCodeCard.breakable("a/b.swift") == "a/\u{200B}b.swift")
    }
}
