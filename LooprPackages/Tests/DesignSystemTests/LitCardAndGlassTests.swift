import SwiftUI
import Testing
import UIKit
@testable import DesignSystem

/// LV-01.2: cards are solid with a lit edge, glass controls fall back to solid fills, and every
/// control keeps its hit target.
@MainActor struct LitCardAndGlassTests {
    @Test func everySurfaceEmphasisCarriesALitEdge() {
        #expect(LooprCardEdge.forStyle(.standard) == .lit)
        #expect(LooprCardEdge.forStyle(.elevated) == .lit)
        #expect(LooprCardEdge.forStyle(.hero(.protocol)) == .accent(.protocol))
        #expect(LooprCardEdge.forStyle(.hero(.energy)) == .accent(.energy))
        #expect(LooprCardEdge.forStyle(.warning) == .caution)
        #expect(LooprCardEdge.forStyle(.sunk) == .none)
        #expect(LooprCardEdge.darkHighlightFade > 0 && LooprCardEdge.darkHighlightFade < 1)
        #expect(LooprRadius.card == 26)
    }

    @Test func litEdgeIsAWhiteHighlightInDarkAndAWarmHairlineOnPaper() {
        let edge = LooprColorToken.surfaceEdge.rgbPalette
        #expect(edge.dark == 0xFFFFFF)
        #expect(edge.highDark == 0xFFFFFF)
        #expect(edge.light == 0x2A2118)
        let resolved = [UIUserInterfaceStyle.light, .dark].flatMap { style in
            [UIAccessibilityContrast.normal, .high].map { contrast in
                Self.alpha(.surfaceEdge, style, contrast)
            }
        }
        #expect(resolved.allSatisfy { $0 > 0 && $0 < 0.5 })
        // Increase Contrast reads the stronger high-contrast values.
        #expect(Self.alpha(.surfaceEdge, .dark, .high) > Self.alpha(.surfaceEdge, .dark, .normal))
        #expect(Self.alpha(.surfaceEdge, .light, .high) > Self.alpha(.surfaceEdge, .light, .normal))
    }

    @Test func glassFallsBackToASolidFillUnderReduceTransparency() {
        let normal = LooprGlassAppearance(reduceTransparency: false, increasedContrast: false)
        #expect(normal.usesGlass)
        #expect(!normal.isOutlined)
        let reduced = LooprGlassAppearance(reduceTransparency: true, increasedContrast: false)
        #expect(!reduced.usesGlass)
        #expect(!reduced.isOutlined)
        #expect(LooprGlassAppearance.solidFill == .surfaceElevated)
    }

    @Test func increasedContrastOutlinesWithTheHighContrastTokens() {
        let contrast = LooprGlassAppearance(reduceTransparency: false, increasedContrast: true)
        #expect(contrast.usesGlass)
        #expect(contrast.isOutlined)
        let both = LooprGlassAppearance(reduceTransparency: true, increasedContrast: true)
        #expect(!both.usesGlass)
        #expect(both.isOutlined)
        let outline = LooprGlassAppearance.outline.rgbPalette
        #expect(outline.highDark == 0xFFFFFF)
        #expect(Self.alpha(LooprGlassAppearance.outline, .dark, .high) >= 0.3)
        #expect(Self.alpha(LooprGlassAppearance.outline, .light, .high) >= 0.2)
    }

    @Test func glassControlsKeepTheirHitTargets() {
        #expect(LooprGlassButton.minimumHitTarget >= 44)
        for size in LooprGlassButton.Size.allCases {
            #expect(size.hitTarget >= 44, "\(size)")
            #expect(size.hitTarget >= size.diameter, "\(size)")
        }
        #expect(LooprGlassButton.Size.small.diameter == 40)
        #expect(LooprGlassButton.Size.large.diameter == 54)
        #expect(LooprGlassSegmentedControl<Int>.segmentHeight >= 44)
    }

    @Test func glassControlsLayOutAtTheirHitTargets() {
        let icon = UIHostingController(rootView: LooprGlassButton(symbol: "plus", accessibilityLabel: "Add", size: .small,
                                                                  identifier: "test-icon") {})
        let iconSize = icon.sizeThatFits(in: CGSize(width: 400, height: 400))
        #expect(iconSize.width >= 44 && iconSize.height >= 44)

        let pill = UIHostingController(rootView: LooprGlassButton("This week", identifier: "test-pill") {})
        #expect(pill.sizeThatFits(in: CGSize(width: 400, height: 400)).height >= 44)

        let segments = UIHostingController(rootView: LooprGlassSegmentedControl("Range", segments: [
            LooprGlassSegment("Week", value: 0, identifier: "test-week"),
            LooprGlassSegment("Month", value: 1, identifier: "test-month")
        ], selection: .constant(0), identifier: "test-range"))
        #expect(segments.sizeThatFits(in: CGSize(width: 353, height: 400)).height >= 44 + 2 * LooprGlassSegmentedControl<Int>.inset)
    }

    @Test func segmentsKeepTheirCallerIdentifiers() {
        let segment = LooprGlassSegment("Week", value: "week", identifier: "protocol-range-week")
        #expect(segment.id == "protocol-range-week")
        #expect(segment.identifier == "protocol-range-week")
    }

    @Test func craftGalleryConstructsAndLaysOut() {
        _ = DesignSystemGallery(initialSection: "craft")
        let host = UIHostingController(rootView: ScrollView { LooprCraftGallerySection().padding(20) })
        host.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        host.view.layoutIfNeeded()
        #expect(LooprCraftGallerySection.fieldSampleHeight > 0)
        #expect(Set(LooprColorFieldTab.allCases.map(LooprCraftGallerySection.title)).count == LooprColorFieldTab.allCases.count)
    }

    private static func alpha(_ token: LooprColorToken, _ style: UIUserInterfaceStyle, _ contrast: UIAccessibilityContrast) -> CGFloat {
        DesignSystemRuntime.reset()
        let traits = UITraitCollection { $0.userInterfaceStyle = style; $0.accessibilityContrast = contrast }
        return UIColor(Color.loopr(token)).resolvedColor(with: traits).cgColor.alpha
    }
}
