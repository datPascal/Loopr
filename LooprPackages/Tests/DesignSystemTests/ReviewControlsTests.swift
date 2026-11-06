import DesignSystem
import SwiftUI
import Testing

@MainActor struct ReviewControlsTests {
    @Test func expandedFoodRowSpeaksAllVisibleStateAndRendersAtLargestTextSize() throws {
        let row = LooprReviewRow(title: "White rice", detail: "180 g", value: "234 kcal", state: "Check", accent: .energy,
            expanded: true, identifier: "test") {}
        #expect(row.accessibilitySummary == "White rice, 180 g, Check, 234 kcal")
        for appearance in [ColorScheme.light, .dark] {
            let image = try #require(ImageRenderer(content: row.environment(\.colorScheme, appearance)
                .environment(\.dynamicTypeSize, .accessibility5).frame(width: 320)).cgImage)
            #expect(image.width == 320 && image.height >= 56)
        }
    }

    @Test func amountSliderSnapsToWholeStepsInsideItsRange() {
        #expect(LooprAmountSlider.snapped(300.4, step: 1, range: 1...600) == 300)
        #expect(LooprAmountSlider.snapped(300.6, step: 1, range: 1...600) == 301)
        #expect(LooprAmountSlider.snapped(1.1, step: 0.25, range: 0.25...5) == 1)
        #expect(LooprAmountSlider.snapped(-4, step: 1, range: 1...600) == 1)
        #expect(LooprAmountSlider.snapped(700, step: 1, range: 1...600) == 600)
        #expect(LooprAmountSlider.snapped(3.3, step: 0, range: 1...5) == 3.3)
    }
}
