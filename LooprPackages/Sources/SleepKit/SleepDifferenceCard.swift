import SwiftUI
import DesignSystem

/// The "What was different" card under the Stages card. It names up to three ways the night differed from
/// the person's own last 28 days. A tap opens Ask about the night, so the card is a button.
public struct SleepDifferenceCard: View {
    public static let prompt = "What was different about this night?"
    public static let identifier = "sleep-what-was-different"

    private let comparison: SleepNightComparison
    private let action: () -> Void

    public init(comparison: SleepNightComparison, action: @escaping () -> Void) {
        self.comparison = comparison
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            LooprCard(style: .hero(.sleep)) {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    StatusChip("What was different", symbol: "sparkles", accent: .sleep)
                    LooprText(comparison.text, style: .settingsRow)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                    LooprText(comparison.sources.joined(separator: " · ").looprLabelCased, style: .headerMeta, color: .inkMuted)
                }
            }
        }
        .buttonStyle(.looprPressableCard)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("What was different. \(comparison.text) From \(comparison.sources.joined(separator: ", ")).")
        .accessibilityHint("Opens Ask about this night.")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(Self.identifier)
    }
}
