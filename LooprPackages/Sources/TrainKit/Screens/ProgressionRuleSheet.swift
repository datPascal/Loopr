import DesignSystem
import SwiftUI

/// Chooses how a template raises its load: nothing, double progression or linear.
/// It works on a copy. Apply hands the rule back, Cancel drops it.
public struct ProgressionRuleSheet: View {
    private static let kinds: [LooprChoice] = [
        LooprChoice("none", title: "None"),
        LooprChoice("double", title: "Double"),
        LooprChoice("linear", title: "Linear")
    ]

    @Environment(\.dismiss) private var dismiss
    @State private var kind: String
    @State private var incrementKg: Double
    private let onApply: (ProgressionRule) -> Void

    public init(rule: ProgressionRule, onApply: @escaping (ProgressionRule) -> Void) {
        switch rule {
        case .none: _kind = State(initialValue: "none")
        case .doubleProgression: _kind = State(initialValue: "double")
        case .linear: _kind = State(initialValue: "linear")
        }
        _incrementKg = State(initialValue: rule.incrementKg ?? ProgressionRule.defaultIncrementKg)
        self.onApply = onApply
    }

    /// The rule the sheet currently describes.
    var rule: ProgressionRule {
        switch kind {
        case "double": .doubleProgression(incrementKg: incrementKg)
        case "linear": .linear(incrementKg: incrementKg)
        default: .none
        }
    }

    private var explanation: String {
        switch kind {
        case "double":
            "Add reps until every set reaches the top of the range, then add \(TemplateBuilderFormat.kilograms(incrementKg)) kg and start again at the bottom."
        case "linear":
            "Add \(TemplateBuilderFormat.kilograms(incrementKg)) kg after each session where every set hits its planned reps."
        default:
            "The load stays where you set it until you change it."
        }
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LooprSpacing.tabSection) {
                    VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                        LooprSectionHeader("Progression")
                        LooprChoiceControl("Progression", choices: Self.kinds, selection: kind, accent: .movement,
                                           identifier: "progression-kind") { choice in
                            if let choice { kind = choice }
                        }
                        LooprText(explanation, style: .prose, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("progression-explanation")
                    }
                    if kind != "none" {
                        LooprValueStepper("kg", label: "Increase", spokenUnit: "kilograms", value: $incrementKg, step: 0.5,
                                          range: 0.5...20, identifier: "progression-increment",
                                          decrementIdentifier: "progression-increment-minus",
                                          incrementIdentifier: "progression-increment-plus")
                    }
                    Button("Apply") {
                        onApply(rule)
                        dismiss()
                    }
                    .buttonStyle(LooprButtonStyle(accent: .movement))
                    .accessibilityIdentifier("progression-apply")
                }
                .padding(.horizontal, LooprSpacing.screenGutter)
                .padding(.top, LooprSpacing.tabContentTop)
                .padding(.bottom, LooprSpacing.tabSection)
            }
            .background(Color.loopr(.background))
            .navigationTitle("Progression")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("progression-cancel")
                }
            }
        }
    }
}

#Preview("Progression rule") {
    ProgressionRuleSheet(rule: .doubleProgression(incrementKg: 2.5)) { _ in }
}
