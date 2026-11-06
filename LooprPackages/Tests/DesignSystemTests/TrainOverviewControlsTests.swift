import DesignSystem
import SwiftUI
import Testing

@MainActor struct TrainOverviewControlsTests {
    private static let themes: [ColorScheme] = [.light, .dark]
    private static let minimum = LooprSpacing.interactiveRowHeight

    private func rows(showsLastDivider: Bool = false) -> some View {
        LooprCard(density: .flush) {
            VStack(spacing: LooprSpacing.none) {
                LooprNavigationRow(title: "Strength block", caption: "8 weeks · 5 days a week", progress: 3.0 / 8.0,
                                   value: "3", valueUnit: "of 8", accessibilityLabel: "Strength block, week 3 of 8",
                                   identifier: "row-program") {}
                LooprNavigationRow(title: "Upper A", caption: "Bench press, Pull-up and 4 more",
                                   accessibilityLabel: "Upper A, 6 exercises", identifier: "row-template",
                                   showsDivider: showsLastDivider) {}
            }
        }
    }

    @Test func navigationRowIsAtLeastOneTargetTallAtEveryTextSize() throws {
        #expect(LooprNavigationRow.minimumHeight == Self.minimum)
        for appearance in Self.themes {
            let regular = try render(rows(), appearance: appearance, size: .large, width: 358)
            #expect(regular.width == 358 && CGFloat(regular.height) >= Self.minimum * 2)
            let largest = try render(rows(), appearance: appearance, size: .accessibility5)
            // The value drops under the caption, so two rows grow instead of clipping.
            #expect(largest.width == 320 && CGFloat(largest.height) >= Self.minimum * 2)
        }
    }

    @Test func navigationRowAcceptsMissingOptionalParts() throws {
        let bare = LooprNavigationRow(title: "Zone 2", accessibilityLabel: "Zone 2", identifier: "bare") {}
        let image = try render(bare, appearance: .dark, size: .large, width: 358)
        #expect(CGFloat(image.height) >= Self.minimum)
    }

    @Test func recoveryTokensTintAStatusChip() throws {
        for score in [88.0, 52, 21] {
            let band = try #require(LooprRecoveryBand(score: score))
            let chip = StatusChip("Recovery \(Int(score))", symbol: nil, accent: band.token)
            #expect(chip.accessibilitySummary == "Recovery \(Int(score))")
            #expect(chip.hasNonColorDifferentiator)
            for appearance in Self.themes {
                _ = try render(chip, appearance: appearance, size: .large)
            }
        }
    }

    private func render(_ view: some View, appearance: ColorScheme, size: DynamicTypeSize, width: CGFloat = 320) throws -> CGImage {
        try #require(ImageRenderer(content: view.environment(\.colorScheme, appearance)
            .environment(\.dynamicTypeSize, size).frame(width: width)).cgImage)
    }
}
