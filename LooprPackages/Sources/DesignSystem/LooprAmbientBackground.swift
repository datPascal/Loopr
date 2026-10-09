import SwiftUI

/// A fixed wash of the tab's colour behind its scroll view. Detail screens
/// keep their plain background.
///
/// A nil tint keeps whatever tint the glow last had, so a tab reloading its
/// next day does not flash back to a neutral colour and then on to the new
/// one. Before any tint has been shown, nil means `fallback`.
public struct LooprAmbientBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let requestedTint: LooprColorToken?
    private let fallback: LooprColorToken
    @State private var heldTint: LooprColorToken?

    public init(tint: LooprColorToken) {
        requestedTint = tint
        fallback = tint
    }

    public init(tint: LooprColorToken?, fallback: LooprColorToken) {
        requestedTint = tint
        self.fallback = fallback
    }

    private var tint: LooprColorToken {
        requestedTint ?? heldTint ?? fallback
    }

    public var body: some View {
        glow
            .onChange(of: requestedTint, initial: true) { _, newTint in
                if let newTint, newTint != heldTint { heldTint = newTint }
            }
    }

    private var glow: some View {
        ZStack(alignment: .top) {
            Color.loopr(.background)

            if LooprAmbientPolicy.showsGlow(
                reduceTransparency: reduceTransparency,
                increasedContrast: colorSchemeContrast == .increased
                    || DesignSystemRuntime.state().increasedContrast
            ) {
                RadialGradient(
                    stops: [
                        .init(color: Color.loopr(tint).opacity(peakOpacity), location: 0),
                        .init(color: Color.loopr(tint).opacity(peakOpacity * 0.65), location: 0.22),
                        .init(color: Color.loopr(tint).opacity(peakOpacity * 0.27), location: 0.55),
                        .init(color: .clear, location: 1)
                    ],
                    center: .top,
                    startRadius: 0,
                    endRadius: 480
                )
                .frame(height: 480)
                .id(tint)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
        .animation((reduceMotion || DesignSystemRuntime.state().reduceMotion == true) ? nil
            : .easeInOut(duration: 0.35), value: tint)
    }

    private var peakOpacity: Double {
        LooprAppearance.isDark(colorScheme) ? 0.22 : 0.11
    }
}

/// Accessibility settings take the background back to a plain field.
nonisolated enum LooprAmbientPolicy {
    static func showsGlow(reduceTransparency: Bool, increasedContrast: Bool) -> Bool {
        !reduceTransparency && !increasedContrast
    }
}
