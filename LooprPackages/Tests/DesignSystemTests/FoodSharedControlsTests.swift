import DesignSystem
import SwiftUI
import Testing

@MainActor struct FoodSharedControlsTests {
    @Test func emptyCorrectionAndLongNoteRemainUsableAtLargestTextInBothThemes() throws {
        for appearance in [ColorScheme.light, .dark] {
            for draft in ["", "The rice was brown and I ate half the portion"] {
                let composer = LooprInlineComposer("Say what is wrong, like the rice was brown", text: .constant(draft), recording: false,
                    identifier: "correction", voiceLabel: "Dictate correction", submitLabel: "Review correction", voice: {}, submit: {})
                let image = try render(composer, appearance: appearance)
                #expect(image.width == 320 && image.height >= 56)
            }
            let note = try render(LooprInlineTextField("Add a note, like half a portion", text: .constant(""), label: "Food note", identifier: "note"), appearance: appearance)
            #expect(note.width == 320 && note.height >= 56)
        }
    }

    @Test func waterTargetAndQuietActionExpandAtLargestText() throws {
        for appearance in [ColorScheme.light, .dark] {
            let row = LooprIntakeRow(title: "Water", symbol: "drop.fill", accent: .brand, value: "1.2", unit: "of 2.5 L",
                progress: 1200, target: 2500, showsProgress: true, showsPlus: true,
                identifier: "water", accessibilityLabel: "Water, 1.2 of 2.5 litres") {}
            let image = try render(row, appearance: appearance)
            #expect(image.width == 320 && image.height > 100)
            let action = try render(LooprInlineActionRow("Add something it missed", symbol: "plus", identifier: "add") {}, appearance: appearance)
            #expect(action.width == 320 && action.height >= 56)
        }
    }

    @Test func textOnlyStatusRemainsDistinctWithoutColor() throws {
        let chip = StatusChip("Check", symbol: nil, accent: .energy)
        #expect(chip.hasNonColorDifferentiator)
        #expect(chip.accessibilitySummary == "Check")
        for appearance in [ColorScheme.light, .dark] {
            let image = try render(LooprCaptureAnnotations(labels: ["Chicken", "Rice", "Avocado"], guide: "Fit the whole plate in the frame")
                .frame(height: LooprSpacing.capturePreviewHeight), appearance: appearance)
            #expect(image.width == 320 && image.height == 500)
        }
    }

    private func render(_ view: some View, appearance: ColorScheme) throws -> CGImage {
        try #require(ImageRenderer(content: view.environment(\.colorScheme, appearance)
            .environment(\.dynamicTypeSize, .accessibility5).frame(width: 320)).cgImage)
    }
}
