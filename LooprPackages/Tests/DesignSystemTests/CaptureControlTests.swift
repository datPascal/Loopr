import DesignSystem
import SwiftUI
import Testing

@MainActor struct CaptureControlTests {
    @Test func shutterRendersAtAnAccessibleSizeInBothAppearances() throws {
        for appearance in [ColorScheme.light, .dark] {
            let content = LooprCaptureControl("Take food photo", identifier: "test-shutter") {}
                .environment(\.colorScheme, appearance).environment(\.dynamicTypeSize, .accessibility5)
            let image = try #require(ImageRenderer(content: content).cgImage)
            #expect(image.width >= 56 && image.height >= 56)
            #expect(image.width == image.height)
        }
    }
}
