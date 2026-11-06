import DesignSystem
import Foundation
import Testing

struct TargetProgressTests {
    @Test func missingAndInvalidProgressNeverPretendToBeZero() {
        for (value, target) in [(nil, 100.0), (0.0, nil), (.nan, 100.0), (1.0, 0.0), (-1.0, 100.0), (1.0, .infinity)] as [(Double?, Double?)] {
            #expect(LooprLinearProgressModel(value: value, target: target).fraction == nil)
        }
        #expect(LooprLinearProgressModel(value: 0, target: 100).fraction == 0)
        #expect(LooprLinearProgressModel(value: 50, target: 100).fraction == 0.5)
        #expect(LooprLinearProgressModel(value: 150, target: 100).fraction == 1)
    }
    @MainActor @Test func oneTargetGuideRequiresEveryDayToHaveTheSameKnownTarget() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        func chart(_ targets: [Double?]) -> LooprTargetBars {
            LooprTargetBars(days: targets.enumerated().map { index, target in
                .init(date: date.addingTimeInterval(Double(index) * 86400), value: 1800, target: target, isComplete: true)
            }, title: "Week", unit: "kcal", accent: .energy)
        }
        #expect(chart([2000, 2000, 2000]).uniformTarget == 2000)
        #expect(chart([2000, nil, 2000]).uniformTarget == nil)
        #expect(chart([2000, 2200, 2000]).uniformTarget == nil)
        #expect(chart([nil, nil]).uniformTarget == nil)
    }
    @Test func dailyBarPreservesGapsAndOnlyUsesPositiveFiniteTargets() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let missing = LooprTargetBar(date: date, value: nil, target: nil, isComplete: false)
        #expect(missing.value == nil && missing.target == nil && !missing.isComplete)
        let zero = LooprTargetBar(date: date, value: 0, target: 2_000, isComplete: true)
        #expect(zero.value == 0 && zero.target == 2_000 && zero.isComplete)
        #expect(LooprTargetBar(date: date, value: .infinity, target: -1, isComplete: false).value == nil)
        #expect(LooprTargetBar(date: date, value: 1, target: .nan, isComplete: false).target == nil)
    }
}
