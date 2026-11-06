import SwiftUI

public struct LooprSettingsGlassButton: View {
    private let action: () -> Void
    private let spokenLabel: String

    public init(spokenLabel: String = "Open settings", action: @escaping () -> Void) {
        self.spokenLabel = spokenLabel
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: "person.crop.circle")
                .looprTypography(.metricValue)
                .foregroundStyle(Color.loopr(.ink))
                .frame(width: LooprSpacing.headerControlDiameter, height: LooprSpacing.headerControlDiameter)
                .glassEffect(.regular.interactive(), in: Circle())
                .frame(width: LooprSpacing.interactiveRowHeight, height: LooprSpacing.interactiveRowHeight)
                .contentShape(.interaction, Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(spokenLabel)
        .accessibilityIdentifier("open-settings")
    }
}
