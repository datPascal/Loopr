import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// The glass avatar at the trailing end of every tab header. Its ring shows
/// the band battery, a small badge shows the band link when there is
/// something worth noticing, and a tap opens Settings.
///
/// It reads `\.looprBandIndicator` and `\.looprOpenSettings`, which the app
/// shell provides on every tab. A screen can pass its own fallbacks for hosts
/// that do not (previews, a screen outside the shell). Without any settings
/// action the button is not drawn.
public struct LooprBandButton: View {
    @Environment(\.looprBandIndicator) private var environmentIndicator
    @Environment(\.looprOpenSettings) private var environmentOpenSettings

    private let accent: LooprColorToken
    private let fallbackIndicator: LooprBandIndicator?
    private let fallbackAction: (@MainActor () -> Void)?

    public static let diameter: CGFloat = 48

    public init(
        accent: LooprColorToken = .brand,
        fallbackIndicator: LooprBandIndicator? = nil,
        fallbackAction: (@MainActor () -> Void)? = nil
    ) {
        self.accent = accent
        self.fallbackIndicator = fallbackIndicator
        self.fallbackAction = fallbackAction
    }

    public var body: some View {
        if let action = environmentOpenSettings?.run ?? fallbackAction {
            let indicator = environmentIndicator ?? fallbackIndicator
            LooprSettingsGlassButton(spokenLabel: LooprBandButtonStyle.spokenLabel(for: indicator), action: action)
                .overlay {
                    LooprBatteryRing(
                        percent: indicator?.batteryPercent,
                        charging: indicator?.charging,
                        isStale: LooprBandButtonStyle.batteryIsStale(for: indicator?.link)
                    )
                        .frame(width: Self.diameter, height: Self.diameter)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .overlay(alignment: .topTrailing) {
                    LooprBandLinkBadge(link: indicator?.link, accent: accent)
                        .offset(x: 1, y: -1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .frame(width: Self.diameter, height: Self.diameter)
        }
    }
}

/// Words and colours for the band button, kept apart from the view so they
/// can be tested.
public enum LooprBandButtonStyle {
    public static func batteryTone(percent: Int) -> LooprColorToken {
        if percent <= 10 { return .critical }
        if percent <= 20 { return .strain }
        return .recoveryHigh
    }

    /// "Open settings, band battery 64 percent, charging, syncing". Only
    /// what is known and worth saying is read out.
    public static func spokenLabel(percent: Int?, charging: Bool?, link: LooprBandIndicator.Link? = nil) -> String {
        var parts = ["Open settings"]
        if let percent {
            parts.append("band battery \(min(max(percent, 0), 100)) percent")
        }
        if charging == true { parts.append("charging") }
        if let phrase = link.flatMap(spokenLink) { parts.append(phrase) }
        return parts.joined(separator: ", ")
    }

    /// While the band is not linked the ring keeps its last level, dimmed,
    /// rather than vanishing: the number is the last one the band sent.
    public static func batteryIsStale(for link: LooprBandIndicator.Link?) -> Bool {
        switch link {
        case .reconnecting, .disconnected, .bluetoothOff, .needsAttention: true
        case .connected, .syncing, .notPaired, nil: false
        }
    }

    public static func spokenLabel(for indicator: LooprBandIndicator?) -> String {
        let label = spokenLabel(percent: indicator?.batteryPercent, charging: indicator?.charging, link: indicator?.link)
        return indicator?.onWrist == false ? label + ", off wrist" : label
    }

    /// The badge a link state gets, or nil for the calm states.
    public static func badge(for link: LooprBandIndicator.Link?) -> LooprBandLinkBadge.Kind? {
        switch link {
        case .syncing: .syncing
        case .disconnected: .disconnected
        case .bluetoothOff: .bluetoothOff
        case .needsAttention: .needsAttention
        case .connected, .reconnecting, .notPaired, nil: nil
        }
    }

    static func spokenLink(_ link: LooprBandIndicator.Link) -> String? {
        switch link {
        case .syncing: "syncing"
        case .disconnected: "band not connected"
        case .bluetoothOff: "Bluetooth is off"
        case .needsAttention: "band needs attention"
        case .connected, .reconnecting, .notPaired: nil
        }
    }
}

/// The small mark on the avatar ring. Syncing breathes slowly in the tab's
/// accent; the other states sit still.
public struct LooprBandLinkBadge: View {
    public enum Kind: Equatable, Sendable {
        case syncing
        case disconnected
        case bluetoothOff
        case needsAttention
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let kind: Kind?
    private let accent: LooprColorToken

    public init(link: LooprBandIndicator.Link?, accent: LooprColorToken = .brand) {
        kind = LooprBandButtonStyle.badge(for: link)
        self.accent = accent
    }

    public var body: some View {
        ZStack {
            switch kind {
            case .syncing:
                dot(.loopr(accent))
                    .modifier(LooprBreathing(active: !LooprMotion.reducesMotion(reduceMotion)))
            case .disconnected:
                dot(.loopr(.warning))
            case .needsAttention:
                dot(.loopr(.critical))
            case .bluetoothOff:
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Color.loopr(.ink))
                    .frame(width: 17, height: 17)
                    .background(Color.loopr(.background), in: Circle())
                    .overlay { Circle().strokeBorder(Color.loopr(.divider), lineWidth: 1) }
            case nil:
                EmptyView()
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.6)))
        .animation(LooprMotion.stateChange, value: kind)
    }

    private func dot(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .padding(2)
            .background(Color.loopr(.background), in: Circle())
    }
}

/// A slow 1.6 s breath: opacity and a hint of scale.
struct LooprBreathing: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content.keyframeAnimator(initialValue: 1.0, repeating: true) { view, value in
                view.opacity(value).scaleEffect(0.82 + 0.18 * value)
            } keyframes: { _ in
                CubicKeyframe(0.45, duration: 0.8)
                CubicKeyframe(1.0, duration: 0.8)
            }
        } else {
            content
        }
    }
}

#if canImport(UIKit)
enum LooprBatteryColors {
    // SwiftUI resolves dynamic colors on its asynchronous rendering executor.
    // Creating this provider in a View getter inherits MainActor isolation.
    nonisolated static var darkTrack: UIColor {
        UIColor { @Sendable traits in
            let highContrast = DesignSystemRuntime.state().increasedContrast
                || traits.accessibilityContrast == .high
            return UIColor(red: 160 / 255, green: 190 / 255, blue: 220 / 255, alpha: highContrast ? 0.24 : 0.16)
        }
    }
}
#endif

/// The battery level drawn around the avatar. Nothing is drawn while the
/// level is unknown. Level changes ease along the ring. A stale level, from a
/// band that is not linked right now, stays on the ring dimmed.
public struct LooprBatteryRing: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let percent: Int?
    private let charging: Bool?
    private let isStale: Bool

    public init(percent: Int?, charging: Bool? = nil, isStale: Bool = false) {
        self.percent = percent
        self.charging = charging
        self.isStale = isStale
    }

    public var body: some View {
        ZStack {
            if let percent {
                let tone = Color.loopr(LooprBandButtonStyle.batteryTone(percent: percent))
                Circle()
                    .strokeBorder(trackColor, lineWidth: 2.25)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(tone, style: StrokeStyle(lineWidth: 2.25, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(1.125)
                    .opacity(fraction > 0 ? (isStale ? 0.35 : 1) : 0)
                    .saturation(isStale ? 0.2 : 1)
            }
            if charging == true, !isStale {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Color.loopr(percent.map(LooprBandButtonStyle.batteryTone) ?? .brand))
                    .padding(2)
                    .background(Color.loopr(.background), in: Circle())
                    .offset(x: 14, y: 14)
            }
        }
        .padding(2.5)
        .animation(LooprMotion.reducesMotion(reduceMotion) ? nil : .smooth(duration: LooprMotion.deliberate), value: percent)
        // A fade is not motion, so it runs with Reduce Motion too, only shorter.
        .animation(
            LooprMotion.reducesMotion(reduceMotion) ? .easeInOut(duration: LooprMotion.fast) : .smooth(duration: LooprMotion.deliberate),
            value: isStale
        )
    }

    private var fraction: Double {
        guard let percent else { return 0 }
        return min(max(Double(percent) / 100, 0), 1)
    }

    private var trackColor: Color {
        if LooprAppearance.isDark(colorScheme) {
            #if canImport(UIKit)
            return Color(uiColor: LooprBatteryColors.darkTrack)
            #else
            return Color(red: 160 / 255, green: 190 / 255, blue: 220 / 255)
                .opacity(DesignSystemRuntime.state().increasedContrast ? 0.24 : 0.16)
            #endif
        }
        return Color.loopr(.ink).opacity(DesignSystemRuntime.state().increasedContrast ? 0.20 : 0.14)
    }
}
