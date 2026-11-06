import SwiftUI

public struct LooprCaptureControl: View {
    private let label: String
    private let identifier: String
    private let action: () -> Void
    @State private var shots = 0
    public init(_ label: String, identifier: String, action: @escaping () -> Void) {
        self.label = label; self.identifier = identifier; self.action = action
    }
    public var body: some View {
        Button { shots += 1; action() } label: {
            Circle().fill(Color.loopr(.ink)).padding(LooprSpacing.xs)
                .overlay { Circle().stroke(Color.loopr(.ink), lineWidth: LooprSpacing.xxs).accessibilityHidden(true) }
        }
        .buttonStyle(LooprButtonStyle(prominent: false, accent: .ink, circular: true))
        .frame(width: LooprSpacing.captureControlDiameter, height: LooprSpacing.captureControlDiameter)
        // A firm click, like a camera shutter.
        .sensoryFeedback(.impact(flexibility: .rigid, intensity: 0.9), trigger: shots)
        .accessibilityLabel(label).accessibilityIdentifier(identifier)
    }
}

#Preview("Photo capture") {
    LooprCaptureControl("Take photo", identifier: "capture-preview") {}.padding()
}
