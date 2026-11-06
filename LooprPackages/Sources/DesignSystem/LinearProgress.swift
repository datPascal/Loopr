import SwiftUI

public struct LooprLinearProgressModel: Equatable, Sendable {
    public let fraction: Double?
    public init(value: Double?, target: Double?) {
        guard let value, let target, value.isFinite, value >= 0, target.isFinite, target > 0 else {
            fraction = nil; return
        }
        fraction = min(value / target, 1)
    }
}

/// A bounded progress bar. Missing readings leave the track empty; the
/// containing row owns its value and accessibility label.
public struct LooprLinearProgress: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Nil until the bar first appears, so an image render draws the real reading. On appear it
    /// drops to empty and grows once, as the rings do.
    @State private var revealed: Bool?
    private let model: LooprLinearProgressModel
    private let accent: LooprColorToken
    public init(value: Double?, target: Double?, accent: LooprColorToken) {
        model = .init(value: value, target: target); self.accent = accent
    }
    public var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.loopr(.inkMuted).opacity(0.16))
                if let fraction = model.fraction {
                    Capsule().fill(Color.loopr(accent))
                        .frame(width: max(0, geometry.size.width) * (revealed == false ? 0 : fraction))
                }
            }
        }
        .frame(height: LooprSpacing.xs)
        .animation(LooprMotion.revealAnimation, value: model.fraction)
        .onAppear {
            guard revealed == nil, !LooprMotion.reducesMotion(reduceMotion) else { return }
            revealed = false
            Task { @MainActor in withAnimation(LooprMotion.revealAnimation.delay(0.1)) { revealed = true } }
        }
        .accessibilityHidden(true)
    }
}

#Preview("Progress toward a target") {
    VStack(spacing: LooprSpacing.lg) {
        LooprLinearProgress(value: 82, target: 150, accent: .energy)
        LooprLinearProgress(value: nil, target: 150, accent: .energy)
        LooprLinearProgress(value: 1_200, target: 2_500, accent: .brand)
    }.padding()
}
