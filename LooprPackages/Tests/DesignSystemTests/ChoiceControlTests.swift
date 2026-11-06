import Foundation
import Testing
@testable import DesignSystem

@MainActor struct ChoiceControlTests {
    @Test func unansweredIsNotTheLowestRatingOrNoAnswer() {
        let control = LooprChoiceControl("Mood", choices: [LooprChoice("1"), LooprChoice("2")],
            selection: nil, accent: .cyclePlum, identifier: "test") { _ in }
        #expect(control.accessibilitySummary == "Mood, Unanswered")
        let selected = LooprChoiceControl("Mood", choices: [LooprChoice("1"), LooprChoice("2")],
            selection: "1", accent: .cyclePlum, identifier: "test") { _ in }
        #expect(selected.accessibilitySummary == "Mood, 1")
        #expect(LooprColorToken.cyclePlum.spectralChipLabel == .cyclePlumChip)
    }

    @Test func selectedJournalLabelsMeetTextContrastInEveryAppearance() {
        let label = LooprColorToken.cyclePlumChip.rgbPalette
        let fill = LooprColorToken.cyclePlum.rgbPalette
        let surface = LooprColorToken.surfaceElevated.rgbPalette
        for (ink, tint, base) in [
            (label.light, fill.light, surface.light), (label.dark, fill.dark, surface.dark),
            (label.highLight, fill.highLight, surface.highLight), (label.highDark, fill.highDark, surface.highDark)
        ] {
            let foreground = luminance(channels(ink))
            let background = luminance(zip(channels(tint), channels(base)).map { $0 * 0.16 + $1 * 0.84 })
            #expect((max(foreground, background) + 0.05) / (min(foreground, background) + 0.05) >= 4.5)
        }
    }

    private func channels(_ rgb: UInt32) -> [Double] {
        [16, 8, 0].map { Double((rgb >> $0) & 255) / 255 }
    }

    private func luminance(_ channels: [Double]) -> Double {
        zip(channels, [0.2126, 0.7152, 0.0722]).reduce(0) { total, pair in
            total + (pair.0 <= 0.04045 ? pair.0 / 12.92 : pow((pair.0 + 0.055) / 1.055, 2.4)) * pair.1
        }
    }
}
