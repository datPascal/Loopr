import SwiftUI

/// The LV-01 craft pieces in the gallery: the colour field for each tab, the lit cards and the
/// glass controls. Open it directly with
/// `--loopr-open-design-system --loopr-design-system-section=craft`.
struct LooprCraftGallerySection: View {
    enum Range: String, Hashable { case week, month, year }

    @State private var range: Range = .week

    /// The height of one field sample.
    static let fieldSampleHeight: CGFloat = 132

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.tabSection) {
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                LooprSectionHeader("Colour field", detail: "One per tab, in its accent. Still under Reduce Motion and in Low Power Mode.")
                ForEach(LooprColorFieldTab.allCases, id: \.self) { tab in
                    ZStack(alignment: .bottomLeading) {
                        LooprColorField(tab: tab)
                        LooprText(Self.title(tab), style: .label)
                            .padding(LooprSpacing.md)
                    }
                    .frame(height: Self.fieldSampleHeight)
                    .clipShape(RoundedRectangle(cornerRadius: LooprRadius.card, style: .continuous))
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("gallery-color-field-\(tab.rawValue)")
                }
            }
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                LooprSectionHeader("Lit cards", detail: "Solid fills. The top edge catches the light.")
                LooprSurface {
                    LooprText("Standard card", style: .rowTitle)
                }
                .accessibilityIdentifier("gallery-lit-card-standard")
                LooprSurface(emphasis: .elevated) {
                    LooprText("Elevated card", style: .rowTitle)
                }
                .accessibilityIdentifier("gallery-lit-card-elevated")
                LooprSurface(emphasis: .hero(.protocol)) {
                    VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                        LooprText("Lead card", style: .rowTitle)
                        LooprText("Lit in the Protocol accent", style: .caption, color: .inkSecondary)
                    }
                }
                .accessibilityIdentifier("gallery-lit-card-hero")
            }
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                LooprSectionHeader("Dot flight", detail: "Dots land on the ring and the number counts up with them.")
                LooprDotFlightGalleryDemo()
            }
            LooprCraftDetailGallery()
            LooprDrawnStickerGallery()
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                LooprSectionHeader("Glass controls", detail: "Solid under Reduce Transparency, outlined under Increase Contrast")
                HStack(spacing: LooprSpacing.xs) {
                    LooprGlassButton(symbol: "plus", accessibilityLabel: "Add", size: .small,
                                     identifier: "gallery-glass-button-small") {}
                    LooprGlassButton(symbol: "calendar", accessibilityLabel: "Calendar",
                                     identifier: "gallery-glass-button-regular") {}
                    LooprGlassButton(symbol: "camera", accessibilityLabel: "Camera", size: .large, tint: .energy,
                                     identifier: "gallery-glass-button-large") {}
                }
                HStack(spacing: LooprSpacing.xs) {
                    LooprGlassButton("This week", symbol: "calendar", identifier: "gallery-glass-pill") {}
                    LooprGlassButton("Check in", prominent: true, identifier: "gallery-glass-pill-prominent") {}
                }
                LooprGlassSegmentedControl("Range", segments: [
                    LooprGlassSegment("Week", value: Range.week, identifier: "gallery-glass-segment-week"),
                    LooprGlassSegment("Month", value: Range.month, identifier: "gallery-glass-segment-month"),
                    LooprGlassSegment("Year", value: Range.year, identifier: "gallery-glass-segment-year")
                ], selection: $range, identifier: "gallery-glass-segments")
            }
        }
    }

    static func title(_ tab: LooprColorFieldTab) -> String {
        switch tab {
        case .today: "Today"
        case .food: "Food"
        case .fitness: "Fitness"
        case .protocol: "Protocol"
        case .data: "Data"
        }
    }
}
