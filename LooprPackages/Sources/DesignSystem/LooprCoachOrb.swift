import Combine
import SwiftUI

/// The coach's mark (the contract's `.orb`): a small glowing sphere of the tab accents that turns
/// slowly. It sits on coach notes and the header Ask button. It turns only when the colour field
/// would drift (`LooprColorFieldPolicy`): still when hidden, in Low Power Mode and under Reduce
/// Motion, and a solid disc under Reduce Transparency and Increase Contrast. It is decorative and
/// hidden from VoiceOver unless it has a label.
///
/// ```swift
/// LooprCoachOrb(size: .xs)
/// LooprCoachOrb(size: .sm, accessibilityLabel: "Ask Loopr")
/// ```
public struct LooprCoachOrb: View {
    public enum Size: CaseIterable, Sendable {
        /// 16 pt, inline with a line of text.
        case xs
        /// 20 pt, in a header button.
        case sm
        /// 24 pt, on a coach note.
        case regular

        public var diameter: CGFloat {
            switch self {
            case .xs: 16
            case .sm: 20
            case .regular: 24
            }
        }
    }

    /// How the orb draws, from the colour field's rules.
    public enum Appearance: Equatable, Sendable {
        case turning
        case still
        case solid

        public init(_ policy: LooprColorFieldPolicy) {
            switch policy.rendering {
            case .animated: self = .turning
            case .still: self = .still
            case .flatWash, .plain: self = .solid
            }
        }
    }

    /// One turn takes this long (`animation: spin 6s linear infinite`).
    public nonisolated static let turnSeconds: Double = 6
    /// The gradient's colours, once round.
    public nonisolated static let tints: [LooprColorToken] = [.brand, .sleep, .protocol, .energy, .brand]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.scenePhase) private var scenePhase
    @State private var isOnScreen = false
    @State private var isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled

    private let size: Size
    private let label: String?

    public init(size: Size = .regular, accessibilityLabel: String? = nil) {
        self.size = size
        label = accessibilityLabel
    }

    var policy: LooprColorFieldPolicy {
        LooprColorFieldPolicy(
            isVisible: isOnScreen && scenePhase == .active,
            isLowPowerModeEnabled: isLowPowerModeEnabled,
            reduceMotion: LooprMotion.reducesMotion(reduceMotion),
            reduceTransparency: reduceTransparency,
            increasedContrast: colorSchemeContrast == .increased || DesignSystemRuntime.state().increasedContrast
        )
    }

    public var body: some View {
        let appearance = Appearance(policy)
        orb(appearance)
            .frame(width: size.diameter, height: size.diameter)
            .onAppear {
                isOnScreen = true
                isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
            .onDisappear { isOnScreen = false }
            .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange).receive(on: RunLoop.main)) { _ in
                isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
            .modifier(LooprCoachOrbAccessibility(label: label))
    }

    @ViewBuilder private func orb(_ appearance: Appearance) -> some View {
        switch appearance {
        case .solid:
            Circle().fill(Color.loopr(.brand))
        case .still:
            sphere(turn: 0)
        case .turning:
            TimelineView(.animation(minimumInterval: LooprColorField.frameInterval, paused: false)) { context in
                sphere(turn: context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.turnSeconds)
                    / Self.turnSeconds)
            }
        }
    }

    private func sphere(turn: Double) -> some View {
        ZStack {
            Circle()
                .fill(AngularGradient(colors: Self.tints.map { Color.loopr($0) }, center: .center))
                .rotationEffect(.degrees(turn * 360))
            // The highlight and shade stay put while the colours turn, so it reads as a sphere.
            Circle()
                .fill(RadialGradient(colors: [.white.opacity(0.75), .white.opacity(0)], center: UnitPoint(x: 0.35, y: 0.3),
                                     startRadius: 0, endRadius: size.diameter * 0.42))
                .padding(2)
            Circle()
                .fill(RadialGradient(colors: [.clear, .black.opacity(0.25)], center: UnitPoint(x: 0.5, y: 0.6),
                                     startRadius: size.diameter * 0.15, endRadius: size.diameter * 0.5))
                .padding(2)
        }
        .shadow(color: Color.loopr(.brand).opacity(0.8), radius: size.diameter / 3)
    }
}

private struct LooprCoachOrbAccessibility: ViewModifier {
    let label: String?

    func body(content: Content) -> some View {
        if let label {
            content
                .accessibilityElement()
                .accessibilityLabel(label)
        } else {
            content.accessibilityHidden(true)
        }
    }
}
