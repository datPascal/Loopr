import SwiftUI

/// One route and one action label wherever a missing age blocks a metric.
public enum ProfileAgePrompt {
    public static let action = "Add your age in Profile"
}

public struct ProfileAgeAction: Sendable {
    public let open: @MainActor @Sendable () -> Void

    public init(open: @escaping @MainActor @Sendable () -> Void) { self.open = open }
}

extension EnvironmentValues {
    @Entry public var profileAgeAction: ProfileAgeAction? = nil
    @Entry public var profileAgeFocusRequested = false
}

public struct ProfileAgePromptButton: View {
    @Environment(\.profileAgeAction) private var action
    let identifier: String

    public init(identifier: String) { self.identifier = identifier }

    public var body: some View {
        Group {
            if let action {
                Button { action.open() } label: { content }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(.isButton)
            } else {
                content
            }
        }
        .accessibilityIdentifier(identifier)
    }

    private var content: some View {
        LooprSurface {
            HStack(spacing: LooprSpacing.sm) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .foregroundStyle(Color.loopr(.heart))
                    .accessibilityHidden(true)
                LooprText(ProfileAgePrompt.action, style: .rowTitle)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                LooprChevron()
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
    }
}
