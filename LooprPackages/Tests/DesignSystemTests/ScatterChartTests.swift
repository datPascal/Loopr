import DesignSystem
import SwiftUI
import Testing

@MainActor struct ScatterChartTests {
    @Test func invalidSamplesAreOmittedFromVoiceOverAndBothAppearancesRenderAtLargestText() throws {
        let chart = LooprScatterChart(points: [.init(id: "1", x: 19, y: 72), .init(id: "2", x: 22, y: 56),
                                               .init(id: "invalid", x: .nan, y: 60)],
            title: "Last meal and deep sleep", xTitle: "Last meal", yTitle: "Deep sleep minutes",
            xDomain: 18...23, yDomain: 40...90, threshold: 21, accent: .sleep,
            xFormat: { "\(Int($0)):00" }, yFormat: { "\(Int($0))m" })
        #expect(chart.accessibilitySummary == "2 observations. Last meal and Deep sleep minutes.")
        for appearance in [ColorScheme.light, .dark] {
            let image = try #require(ImageRenderer(content: chart.environment(\.colorScheme, appearance)
                .environment(\.dynamicTypeSize, .accessibility5).frame(width: 320)).cgImage)
            #expect(image.width == 320 && image.height >= 160)
        }
    }
}
