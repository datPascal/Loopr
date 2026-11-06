import SwiftUI

/// A tappable field with a sparkles glyph and a placeholder. It does not take
/// text: tapping calls `action`, which opens Ask with the screen as its origin.
///
/// ```swift
/// LooprAskField("Describe it: \"push day, 50 min\"", accessibilityLabel: "Describe it",
///               identifier: "template-describe") { ask("Workout builder") }
/// ```
public struct LooprAskField: View {
    public static let minimumHeight: CGFloat = LooprSpacing.interactiveRowHeight

    private let placeholder: String
    private let spoken: String
    private let accent: LooprColorToken
    private let identifier: String
    private let action: () -> Void

    /// - Parameters:
    ///   - placeholder: The prompt shown in the field.
    ///   - accessibilityLabel: What VoiceOver reads. Usually the placeholder without its example.
    public init(_ placeholder: String, accessibilityLabel: String, accent: LooprColorToken = .brand,
                identifier: String, action: @escaping () -> Void) {
        self.placeholder = placeholder
        spoken = accessibilityLabel
        self.accent = accent
        self.identifier = identifier
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            LooprCard(density: .flush) {
                HStack(spacing: LooprSpacing.sm) {
                    Image(systemName: "sparkles")
                        .looprTypography(.title)
                        .foregroundStyle(Color.loopr(accent))
                        .accessibilityHidden(true)
                    Text(placeholder)
                        .looprTypography(.body)
                        .foregroundStyle(Color.loopr(.inkSecondary))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, LooprSpacing.cardHorizontal)
                .padding(.vertical, LooprSpacing.sm)
                .frame(minHeight: Self.minimumHeight)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.looprPressableCard)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityHint("Opens Ask")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(identifier)
    }
}

#Preview("Ask field") {
    LooprAskField("Describe it: \"push day, 50 min\"", accessibilityLabel: "Describe it", identifier: "preview-ask") {}
        .padding(LooprSpacing.screenGutter)
        .background(Color.loopr(.background))
}
