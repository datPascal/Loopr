import DesignSystem
import SwiftUI

// Fitness round 2 (R2-WOD-02): a WOD time is typed as minutes and seconds in two fields. One field of plain digits
// read "437" as 437 seconds, 7:17, and fed that to the PR logic.

/// What two time fields hold.
public enum WODTimeEntry: Equatable, Sendable {
    /// Both fields are empty.
    case empty
    case seconds(Int)
    /// Something that is not a time: letters, or seconds past 59.
    case invalid

    /// Reads a minutes field and a seconds field. Either may be empty ("4" and "" is 4:00, "" and "45" is 0:45).
    public init(minutes: String, seconds: String) {
        let minuteText = minutes.trimmingCharacters(in: .whitespaces)
        let secondText = seconds.trimmingCharacters(in: .whitespaces)
        guard !(minuteText.isEmpty && secondText.isEmpty) else { self = .empty; return }
        func number(_ text: String) -> Int? {
            guard !text.isEmpty else { return 0 }
            guard text.count <= 4, text.allSatisfy(\.isASCII), text.allSatisfy(\.isNumber) else { return nil }
            return Int(text)
        }
        guard let wholeMinutes = number(minuteText), let rest = number(secondText), rest < 60 else {
            self = .invalid
            return
        }
        self = .seconds(wholeMinutes * 60 + rest)
    }

    /// The two fields for a time: 277 seconds is "4" and "37". Seconds always have two digits.
    public static func fields(for seconds: Int) -> (minutes: String, seconds: String) {
        let total = max(0, seconds)
        return ("\(total / 60)", String(format: "%02d", total % 60))
    }
}

/// "Time" with a minutes field and a seconds field, each with its unit beside it.
struct WODTimeField: View {
    let title: String
    @Binding var minutes: String
    @Binding var seconds: String
    let identifier: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xs) {
            LooprText(title, style: .settingsRow)
            Spacer(minLength: LooprSpacing.sm)
            field(text: $minutes, prompt: "0", spoken: "Minutes", identifier: "\(identifier)-minutes", maxLength: 3)
            LooprText("min", style: .metricUnit, color: .inkSecondary)
            field(text: $seconds, prompt: "00", spoken: "Seconds", identifier: "\(identifier)-seconds", maxLength: 2)
            LooprText("sec", style: .metricUnit, color: .inkSecondary)
        }
        .padding(.horizontal, LooprSpacing.formCardPadding)
        .padding(.vertical, LooprSpacing.formRowVerticalPadding)
        .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private func field(text: Binding<String>, prompt: String, spoken: String, identifier: String, maxLength: Int) -> some View {
        TextField(text: text, prompt: Text(prompt).foregroundStyle(Color.loopr(.inkSecondary))) { Text(spoken) }
            .keyboardType(.numberPad)
            .multilineTextAlignment(.trailing)
            .looprTypography(.metricValue)
            .monospacedDigit()
            .frame(width: 56)
            .padding(.horizontal, LooprSpacing.xs)
            .padding(.vertical, LooprSpacing.xxs)
            .background(Color.loopr(.surfaceSunk), in: RoundedRectangle(cornerRadius: LooprRadius.compactCard, style: .continuous))
            .accessibilityLabel("\(title), \(spoken.lowercased())")
            .accessibilityIdentifier(identifier)
            .onChange(of: text.wrappedValue) { _, new in
                let digits = String(new.filter { $0.isASCII && $0.isNumber }.prefix(maxLength))
                if digits != new { text.wrappedValue = digits }
            }
    }
}
