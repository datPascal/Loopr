import DesignSystem
import SwiftUI
import Testing

@MainActor struct ToggleRowAndStepperFormatTests {
    private static let themes: [ColorScheme] = [.light, .dark]

    // MARK: Toggle row

    @Test func toggleRowKeepsTheBrandTintAndNoIdentifierByDefault() {
        let row = LooprToggleRow(title: "High heart rate", isOn: .constant(true))
        #expect(row.tintToken == .brand)
        #expect(row.switchIdentifier == nil)
    }

    @Test func toggleRowTakesAnAccentAndAnIdentifier() {
        let row = LooprToggleRow(title: "Early light week", subtitle: "When 7-day recovery averages under 50",
                                 accent: .movement, identifier: "program-rule-early-light", isOn: .constant(false))
        #expect(row.tintToken == .movement)
        #expect(row.switchIdentifier == "program-rule-early-light")
    }

    @Test func toggleRowStaysAtLeastFiftySixPointsTallInBothAppearancesAndAtTheLargestText() throws {
        for appearance in Self.themes {
            for size in [DynamicTypeSize.large, .accessibility5] {
                let row = LooprToggleRow(title: "Add to Calendar", accent: .movement, identifier: "calendar", isOn: .constant(true))
                let image = try render(row, appearance: appearance, size: size)
                #expect(CGFloat(image.height) >= LooprSpacing.interactiveRowHeight)
            }
        }
    }

    // MARK: Value format

    @Test func clockFormatWritesRestAsMinutesAndSeconds() {
        #expect(LooprValueFormat.clockText(seconds: 150) == "2:30")
        #expect(LooprValueFormat.clockText(seconds: 60) == "1:00")
        #expect(LooprValueFormat.clockText(seconds: 45) == "0:45")
        #expect(LooprValueFormat.clockText(seconds: 0) == "0:00")
        #expect(LooprValueFormat.clockText(seconds: 3_600) == "60:00")
        #expect(LooprValueFormat.clockText(seconds: -15) == "0:00")
        #expect(LooprValueFormat.clockText(seconds: .nan) == "0:00")
    }

    @Test func clockFormatSpeaksMinutesAndSecondsInWords() {
        #expect(LooprValueFormat.spokenClock(seconds: 150) == "2 minutes 30 seconds")
        #expect(LooprValueFormat.spokenClock(seconds: 60) == "1 minute")
        #expect(LooprValueFormat.spokenClock(seconds: 61) == "1 minute 1 second")
        #expect(LooprValueFormat.spokenClock(seconds: 45) == "45 seconds")
        #expect(LooprValueFormat.spokenClock(seconds: 0) == "0 seconds")
    }

    @Test func stepperUsesTheFormatForTheValueAndForVoiceOver() {
        let locale = Locale(identifier: "en_US")
        #expect(LooprValueStepper.valueText(150, locale: locale, format: .clock) == "2:30")
        #expect(LooprValueStepper.spokenValue(150, spokenUnit: "seconds", locale: locale, format: .clock) == "2 minutes 30 seconds")
        // Without a format nothing changes.
        #expect(LooprValueStepper.valueText(150, locale: locale) == "150")
        #expect(LooprValueStepper.spokenValue(150, spokenUnit: "seconds", locale: locale) == "150 seconds")
    }

    @Test func aCustomFormatReplacesBothTexts() {
        let format = LooprValueFormat(text: { "\(Int($0)) x" }, spoken: { "\(Int($0)) times" })
        #expect(LooprValueStepper.valueText(3, format: format) == "3 x")
        #expect(LooprValueStepper.spokenValue(3, spokenUnit: "reps", format: format) == "3 times")
    }

    @Test func restStepsOfFifteenSecondsStayOnTheClockGrid() {
        var rest = 150.0
        rest = LooprValueStepper.stepped(rest, direction: 1, step: 15, range: 0...600)
        #expect(LooprValueFormat.clockText(seconds: rest) == "2:45")
        rest = LooprValueStepper.stepped(rest, direction: -1, step: 15, range: 0...600)
        rest = LooprValueStepper.stepped(rest, direction: -1, step: 15, range: 0...600)
        #expect(LooprValueFormat.clockText(seconds: rest) == "2:15")
    }

    @Test func formattedStepperKeepsFiftySixPointTargetsAtEverySize() throws {
        for appearance in Self.themes {
            for size in [DynamicTypeSize.large, .accessibility5] {
                let stepper = LooprValueStepper("rest", label: "Rest", spokenUnit: "seconds", value: .constant(150), step: 15,
                                                range: 0...600, identifier: "rest", decrementIdentifier: "rest-minus",
                                                incrementIdentifier: "rest-plus", format: .clock)
                let image = try render(stepper, appearance: appearance, size: size)
                #expect(CGFloat(image.height) >= LooprValueStepper.minimumTargetHeight)
            }
        }
    }

    private func render(_ view: some View, appearance: ColorScheme, size: DynamicTypeSize, width: CGFloat = 320) throws -> CGImage {
        try #require(ImageRenderer(content: view.environment(\.colorScheme, appearance)
            .environment(\.dynamicTypeSize, size).frame(width: width)).cgImage)
    }
}
