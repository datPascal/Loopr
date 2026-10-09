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
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.loopr(.ink))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel(spokenLabel)
        .accessibilityIdentifier("open-settings")
    }
}
