import Testing
@testable import DesignSystem

struct LooprAmbientBackgroundTests {
    @Test func glowRespectsAccessibilityContrastSettings() {
        #expect(LooprAmbientPolicy.showsGlow(reduceTransparency: false, increasedContrast: false))
        #expect(!LooprAmbientPolicy.showsGlow(reduceTransparency: true, increasedContrast: false))
        #expect(!LooprAmbientPolicy.showsGlow(reduceTransparency: false, increasedContrast: true))
        #expect(!LooprAmbientPolicy.showsGlow(reduceTransparency: true, increasedContrast: true))
    }
}
