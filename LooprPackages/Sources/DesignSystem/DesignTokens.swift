import Foundation
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public enum LooprColorToken: String, CaseIterable, Sendable {
    case background
    case settingsBackground
    case surface
    case surfaceElevated
    case surfaceSunk
    case surfaceStroke
    /// The lit edge of a card. Dark: a white highlight along the top edge. Light: a warm hairline
    /// round the card, since a white edge would not show on a white card.
    case surfaceEdge
    case divider
    case ink
    case inkSecondary
    case inkMuted
    case sheetFill
    case brand
    case brandSoft
    case brandSweep
    case brandChip
    case heart
    case heartSoft
    case heartSweep
    case heartChip
    case recovery
    case sleep
    case sleepSweep
    case sleepChip
    case strain
    case strainSweep
    case strainChip
    case movement
    case energy
    case stress
    case cycle
    case cyclePlum
    case cyclePlumChip
    /// The Protocol tab accent (DEC-12.2). It resolves to the `cyclePlum` values in every
    /// appearance and contrast mode.
    case `protocol`
    /// Small text and chip labels in the Protocol accent, the `cyclePlumChip` values.
    case protocolChip
    case warning
    case critical
    case lowConfidence
    case sleepAwake
    case sleepLight
    case sleepDeep
    case sleepREM
    /// Recovery 67 to 100. Only `LooprRecoveryBand` should pick these.
    case recoveryHigh
    case recoveryHighSweep
    /// Recovery 34 to 66.
    case recoveryMid
    case recoveryMidSweep
    /// Recovery 0 to 33.
    case recoveryLow
    case recoveryLowSweep
    /// Text and marks for a change in the unwanted direction that sits outside
    /// the usual range. Amber, never red, and dark enough to read as text on
    /// white.
    case caution
    /// Brand teal dark enough to read as small text on white. `brand` itself
    /// is a fill colour and falls below 3:1 as 11 pt text in light mode.
    case brandInk

    /// The quietest ink, for chevrons and other affordances that should be
    /// seen but not read. The same colour as `inkMuted`.
    public static let inkTertiary: LooprColorToken = .inkMuted

    /// The token's dynamic colour. Cached per token, so two reads return
    /// equal values and SwiftUI can skip views whose colours did not change.
    /// The cache is dropped whenever the appearance override or increased
    /// contrast changes, so a switch still hands every re-rendered view a new
    /// colour, as it did before the cache.
    public var color: Color {
        DesignSystemRuntime.cachedColor(self)
    }

    fileprivate var uncachedColor: Color {
        let pair = palette
        return Color.looprDynamic(
            light: pair.light,
            dark: pair.dark,
            highContrastLight: pair.highContrastLight,
            highContrastDark: pair.highContrastDark
        )
    }

    /// RGB values for another process that cannot link the phone's views.
    public var rgbPalette: (light: UInt32, dark: UInt32, highLight: UInt32, highDark: UInt32) {
        func packed(_ color: RGBColor) -> UInt32 {
            (UInt32((color.red * 255).rounded()) << 16)
                | (UInt32((color.green * 255).rounded()) << 8)
                | UInt32((color.blue * 255).rounded())
        }
        let colors = palette
        return (packed(colors.light), packed(colors.dark), packed(colors.highContrastLight), packed(colors.highContrastDark))
    }

    private var palette: PalettePair {
        switch self {
        // Warm paper and warm black. Accents are soft and a little desaturated, so a screen reads as
        // calm and the one number that matters carries the colour (redesign of 2026-10-22).
        case .background: .init("#F6F3EE", "#0B0A08", highLight: "#FFFFFF", highDark: "#050403")
        case .settingsBackground: .init("#EFEBE4", "#070605", highLight: "#E6E1D9", highDark: "#000000")
        case .surface: .init(
            "#FFFFFF", "#FFF3E2", highLight: "#FFFFFF", highDark: "#FFF3E2",
            darkAlpha: 0.055, highDarkAlpha: 0.13
        )
        case .surfaceElevated: .init("#FFFFFF", "#1C1A16", highLight: "#FFFFFF", highDark: "#2A2721")
        case .surfaceSunk: .init("#EEEAE3", "#080706", highLight: "#E4DFD7", highDark: "#000000")
        case .surfaceStroke: .init(
            "#2A2118", "#FFF3E2", highLight: "#1C1814", highDark: "#FFF3E2",
            lightAlpha: 0, darkAlpha: 0.035, highLightAlpha: 0.16, highDarkAlpha: 0.2
        )
        case .surfaceEdge: .init(
            "#2A2118", "#FFFFFF", highLight: "#1C1814", highDark: "#FFFFFF",
            lightAlpha: 0.07, darkAlpha: 0.16, highLightAlpha: 0.22, highDarkAlpha: 0.38
        )
        case .divider: .init(
            "#2A2118", "#FFF3E2", highLight: "#1C1814", highDark: "#FFF3E2",
            lightAlpha: 0.08, darkAlpha: 0.07, highLightAlpha: 0.18, highDarkAlpha: 0.2
        )
        case .ink: .init("#1C1814", "#F3EDE4", highLight: "#000000", highDark: "#FFFFFF")
        case .inkSecondary: .init("#6B635A", "#9A938A", highLight: "#463F37", highDark: "#C2BBB1")
        case .inkMuted: .init("#A39A90", "#615B54", highLight: "#7D746A", highDark: "#8F887F")
        case .sheetFill: .init("#FFFFFF", "#131210", highLight: "#FFFFFF", highDark: "#1E1C18")
        case .brand: .init("#12927F", "#7DD3C0", highLight: "#0B6E5F", highDark: "#A8EEDD")
        case .brandSoft: .init(
            "#12927F", "#7DD3C0", highLight: "#0B6E5F", highDark: "#A8EEDD",
            lightAlpha: 0.10, darkAlpha: 0.12, highLightAlpha: 0.16, highDarkAlpha: 0.20
        )
        case .brandSweep: .init("#3BAE9C", "#A6E4D6", highLight: "#0B6E5F", highDark: "#C8F5EA")
        case .brandChip: .init("#0E7464", "#A6E4D6", highLight: "#08594D", highDark: "#C8F5EA")
        case .heart: .init("#D6456C", "#F08CA8", highLight: "#AE2E52", highDark: "#FFB3C7")
        case .heartSoft: .init(
            "#D6456C", "#F08CA8", highLight: "#AE2E52", highDark: "#FFB3C7",
            lightAlpha: 0.10, darkAlpha: 0.12, highLightAlpha: 0.16, highDarkAlpha: 0.20
        )
        case .heartSweep: .init("#E56F8E", "#F6B3C5", highLight: "#AE2E52", highDark: "#FFC9D7")
        case .heartChip: .init("#C23A60", "#F6AFC2", highLight: "#9C2747", highDark: "#FFC9D7")
        case .recovery: .init("#12927F", "#7DD3C0", highLight: "#0B6E5F", highDark: "#A8EEDD")
        case .sleep: .init("#5B63D6", "#98A1EF", highLight: "#434BB8", highDark: "#BEC4FF")
        case .sleepSweep: .init("#7A82E4", "#B7BDF6", highLight: "#434BB8", highDark: "#D3D7FF")
        case .sleepChip: .init("#4D55C6", "#B9BFF7", highLight: "#3A41A6", highDark: "#D3D7FF")
        case .strain: .init("#DD6A40", "#EE8F6A", highLight: "#B24E28", highDark: "#FFB497")
        case .strainSweep: .init("#E8875F", "#F5AE90", highLight: "#B24E28", highDark: "#FFCBB4")
        case .strainChip: .init("#C2582F", "#F5B497", highLight: "#9C4220", highDark: "#FFCBB4")
        case .movement: .init("#12927F", "#7DD3C0", highLight: "#0B6E5F", highDark: "#A8EEDD")
        case .energy: .init("#C2843A", "#E8C196", highLight: "#9A6526", highDark: "#F5D9B6")
        case .stress: .init("#D6456C", "#F08CA8", highLight: "#AE2E52", highDark: "#FFB3C7")
        case .cycle: .init("#D6456C", "#F08CA8", highLight: "#AE2E52", highDark: "#FFB3C7")
        case .cyclePlum: .init("#A257CC", "#CFA2EE", highLight: "#7F3BA6", highDark: "#E3C6F7")
        case .cyclePlumChip: .init("#8E45B8", "#DDB9F2", highLight: "#7F3BA6", highDark: "#EBD3FA")
        // Read from the plum tokens, so the Protocol accent cannot drift from them.
        case .protocol: LooprColorToken.cyclePlum.palette
        case .protocolChip: LooprColorToken.cyclePlumChip.palette
        case .warning: .init("#C2843A", "#E8C196", highLight: "#9A6526", highDark: "#F5D9B6")
        case .critical: .init("#D0453E", "#EE7E76", highLight: "#A8302A", highDark: "#FFA9A2")
        case .lowConfidence: .init("#A39A90", "#615B54", highLight: "#7D746A", highDark: "#8F887F")
        case .sleepAwake: .init("#B3A898", "#6F6860", highLight: "#7D746A", highDark: "#A39C93")
        case .sleepLight: .init("#9AA0E6", "#5D63A0", highLight: "#6A71C9", highDark: "#8C93D9")
        case .sleepDeep: .init("#4A52C4", "#98A1EF", highLight: "#353CA0", highDark: "#BEC4FF")
        case .sleepREM: .init("#C79A5E", "#E6C49E", highLight: "#9A6E33", highDark: "#F5DCBE")
        case .recoveryHigh: .init("#2F9A68", "#8FD9B4", highLight: "#1F7550", highDark: "#B8F0D2")
        case .recoveryHighSweep: .init("#4DB389", "#B3E8CD", highLight: "#1F7550", highDark: "#CFF6E2")
        case .recoveryMid: .init("#C4962A", "#E8C67E", highLight: "#94701A", highDark: "#F5DCA6")
        case .recoveryMidSweep: .init("#D6AE52", "#F0D8A4", highLight: "#94701A", highDark: "#FAE9C6")
        case .recoveryLow: .init("#D3533F", "#EE8A78", highLight: "#A83B2A", highDark: "#FFB3A6")
        case .recoveryLowSweep: .init("#E07760", "#F4AE9F", highLight: "#A83B2A", highDark: "#FFCBC1")
        case .caution: .init("#A6561E", "#F0B58A", highLight: "#82420F", highDark: "#FFD0AC")
        case .brandInk: .init("#0E7464", "#8FDCCB", highLight: "#08594D", highDark: "#B9F2E4")
        }
    }

    /// The colour used for the second stop in the lens sweep for this token's domain.
    public var spectralSweepPartner: LooprColorToken {
        switch self {
        case .sleep, .sleepSweep, .sleepChip, .sleepAwake, .sleepLight, .sleepDeep, .sleepREM: .sleepSweep
        case .heart, .heartSoft, .heartSweep, .heartChip, .stress, .cycle, .cyclePlum, .cyclePlumChip, .protocol, .protocolChip, .critical: .heartSweep
        case .strain, .strainSweep, .strainChip, .energy, .warning: .strainSweep
        case .recoveryHigh, .recoveryHighSweep: .recoveryHighSweep
        case .recoveryMid, .recoveryMidSweep: .recoveryMidSweep
        case .recoveryLow, .recoveryLowSweep: .recoveryLowSweep
        case .caution: .strainSweep
        default: .brandSweep
        }
    }

    public var spectralStartAngle: Double {
        switch self {
        case .sleep, .sleepSweep, .sleepChip, .sleepAwake, .sleepLight, .sleepDeep, .sleepREM: 210
        case .heart, .heartSoft, .heartSweep, .heartChip, .stress, .cycle, .cyclePlum, .cyclePlumChip, .protocol, .protocolChip, .critical: 20
        case .strain, .strainSweep, .strainChip, .energy, .warning: 300
        default: 150
        }
    }

    public var spectralRotationPeriod: Double {
        switch self {
        case .sleep, .sleepSweep, .sleepChip, .sleepAwake, .sleepLight, .sleepDeep, .sleepREM: 16
        case .heart, .heartSoft, .heartSweep, .heartChip, .stress, .cycle, .cyclePlum, .cyclePlumChip, .protocol, .protocolChip, .critical: 13
        case .strain, .strainSweep, .strainChip, .energy, .warning: 18
        default: 12
        }
    }

    /// The colour for small text in this domain's accent: readable on the
    /// page and card backgrounds in both appearances. Delta captions and
    /// section actions use it instead of the fill colour.
    public var textInk: LooprColorToken {
        switch self {
        case .cyclePlum, .cyclePlumChip: .cyclePlumChip
        case .protocol, .protocolChip: .protocolChip
        case .sleep, .sleepSweep, .sleepChip, .sleepAwake, .sleepLight, .sleepDeep, .sleepREM: .sleepChip
        case .heart, .heartSoft, .heartSweep, .heartChip, .stress, .cycle, .critical: .heartChip
        case .strain, .strainSweep, .strainChip, .energy, .warning, .caution: .caution
        case .ink, .inkSecondary, .inkMuted: self
        default: .brandInk
        }
    }

    /// The brighter label colour used by this domain's dark-mode chip.
    public var spectralChipLabel: LooprColorToken {
        switch self {
        case .cyclePlum, .cyclePlumChip: .cyclePlumChip
        case .protocol, .protocolChip: .protocolChip
        case .sleep, .sleepSweep, .sleepChip, .sleepAwake, .sleepLight, .sleepDeep, .sleepREM: .sleepChip
        case .heart, .heartSoft, .heartSweep, .heartChip, .stress, .cycle, .critical: .heartChip
        case .strain, .strainSweep, .strainChip, .energy, .warning: .strainChip
        case .recoveryHigh, .recoveryHighSweep: .recoveryHigh
        case .recoveryMid, .recoveryMidSweep: .recoveryMid
        case .recoveryLow, .recoveryLowSweep: .recoveryLow
        case .caution: .caution
        // There is no movement chip token. Movement shares the brand palette, so its label is the brand chip colour.
        case .movement: .brandChip
        default: .brandChip
        }
    }
}

/// Runtime overrides owned by the app's Settings surface.  The palette still
/// comes from this package; the bridge only selects which already-reviewed
/// token variant is rendered.  A lock keeps `Color`'s trait resolver safe when
/// SwiftUI evaluates it off the main actor during previews or tests.
public enum LooprAppearanceOverride: String, Codable, CaseIterable, Sendable {
    case system
    case light
    case dark

    /// The scheme the window should take so UIKit's bars, glass and text fields match the tokens. Nil follows the
    /// system. Without it a stored Dark turned the tokens dark over light system chrome: a mid grey tab bar, white text
    /// fields and light ink on them (R2-UPG-5, R2-UPG-6).
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

public struct LooprDesignSystemRuntimeState: Codable, Equatable, Sendable {
    public var appearance: LooprAppearanceOverride
    public var increasedContrast: Bool
    public var reduceMotion: Bool?
    /// What every screen formats distances, heights and weights against.
    public var measurementSystem: LooprMeasurementSystem
    /// Whether screens add the longer VoiceOver hints.
    public var voiceOverHints: Bool

    public init(
        appearance: LooprAppearanceOverride = .system,
        increasedContrast: Bool = false,
        reduceMotion: Bool? = nil,
        measurementSystem: LooprMeasurementSystem = .metric,
        voiceOverHints: Bool = true
    ) {
        self.appearance = appearance
        self.increasedContrast = increasedContrast
        self.reduceMotion = reduceMotion
        self.measurementSystem = measurementSystem
        self.voiceOverHints = voiceOverHints
    }
}

public enum DesignSystemRuntime {
    /// Posted after every `apply` and `reset`. A view that renders units or
    /// hints listens for it, because a global read alone would not tell
    /// SwiftUI that anything changed.
    public static let didChangeNotification = Notification.Name("com.loopr.designSystem.didChange")

    private static let lock = NSLock()
    nonisolated(unsafe) private static var value = LooprDesignSystemRuntimeState()
    nonisolated(unsafe) private static var colorCache: [LooprColorToken: Color] = [:]

    public static func state() -> LooprDesignSystemRuntimeState {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    public static func apply(_ state: LooprDesignSystemRuntimeState) {
        lock.lock()
        let changed = value != state
        if value.appearance != state.appearance || value.increasedContrast != state.increasedContrast {
            colorCache.removeAll()
        }
        value = state
        lock.unlock()
        guard changed else { return }
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    public static func reset() {
        apply(LooprDesignSystemRuntimeState())
    }

    fileprivate static func cachedColor(_ token: LooprColorToken) -> Color {
        lock.lock()
        if let cached = colorCache[token] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        // Built outside the lock: the colour's provider reads `state()`.
        let made = token.uncachedColor
        lock.lock()
        defer { lock.unlock() }
        if let raced = colorCache[token] { return raced }
        colorCache[token] = made
        return made
    }
}

public extension Color {
    static func loopr(_ token: LooprColorToken) -> Color { token.color }

    fileprivate static func looprDynamic(
        light: RGBColor,
        dark: RGBColor,
        highContrastLight: RGBColor,
        highContrastDark: RGBColor
    ) -> Color {
        #if canImport(UIKit)
        // The override is read when the colour resolves, not when it is built.
        // Reading it at build time froze every colour created before Settings
        // applied its appearance, which left ink at its light value on a dark
        // surface.
        return Color(uiColor: UIColor { traits in
            let runtime = DesignSystemRuntime.state()
            let highContrast = runtime.increasedContrast || traits.accessibilityContrast == .high
            let isDark = switch runtime.appearance {
            case .system: traits.userInterfaceStyle == .dark
            case .light: false
            case .dark: true
            }
            let value = isDark
                ? (highContrast ? highContrastDark : dark)
                : (highContrast ? highContrastLight : light)
            return UIColor(red: value.red, green: value.green, blue: value.blue, alpha: value.alpha)
        })
        #elseif canImport(AppKit)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let runtime = DesignSystemRuntime.state()
            let isDark = switch runtime.appearance {
            case .system: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            case .light: false
            case .dark: true
            }
            let value = isDark
                ? (runtime.increasedContrast ? highContrastDark : dark)
                : (runtime.increasedContrast ? highContrastLight : light)
            return NSColor(red: value.red, green: value.green, blue: value.blue, alpha: value.alpha)
        })
        #else
        let runtime = DesignSystemRuntime.state()
        let isDark = runtime.appearance == .dark
        let value = isDark
            ? (runtime.increasedContrast ? highContrastDark : dark)
            : (runtime.increasedContrast ? highContrastLight : light)
        return Color(red: value.red, green: value.green, blue: value.blue, opacity: value.alpha)
        #endif
    }
}

// MARK: Readable labels on accent fills

public extension LooprColorToken {
    /// A label on a solid fill of this colour. In light mode it is dark ink or white, whichever
    /// contrasts more with the fill: light text on the bright teal and orange fills read at 2.7:1.
    /// Dark mode keeps the page background colour, as before.
    var filledLabelColor: Color {
        let fill = palette, page = LooprColorToken.background.palette
        let ink = RGBColor(hex: "#1C1814"), white = RGBColor(hex: "#FFFFFF")
        func best(on color: RGBColor) -> RGBColor { color.contrast(with: ink) >= color.contrast(with: white) ? ink : white }
        return Color.looprDynamic(light: best(on: fill.light), dark: page.dark,
                                  highContrastLight: best(on: fill.highContrastLight), highContrastDark: page.highContrastDark)
    }

    /// A label on a 10% tint of this colour, or on the page for a quiet button. In light mode the
    /// accent is darkened towards ink until it reaches 4.5:1 on the tint. Dark mode keeps the accent.
    var tintedLabelColor: Color {
        let fill = palette, ink = RGBColor(hex: "#1C1814"), page = LooprColorToken.background.palette
        func readable(_ accent: RGBColor, over base: RGBColor) -> RGBColor {
            let tint = accent.mixed(with: base, weight: 0.10)
            var label = accent
            var step = 0.0
            while label.contrast(with: tint) < 4.5 && step < 1 {
                step += 0.05
                label = ink.mixed(with: accent, weight: step)
            }
            return label
        }
        return Color.looprDynamic(light: readable(fill.light, over: page.light), dark: fill.dark,
                                  highContrastLight: readable(fill.highContrastLight, over: page.highContrastLight),
                                  highContrastDark: fill.highContrastDark)
    }
}

private extension RGBColor {
    /// WCAG relative luminance.
    var luminance: Double {
        func channel(_ value: Double) -> Double { value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    func contrast(with other: RGBColor) -> Double {
        let (high, low) = luminance > other.luminance ? (luminance, other.luminance) : (other.luminance, luminance)
        return (high + 0.05) / (low + 0.05)
    }

    /// `weight` of this colour over `base`.
    func mixed(with base: RGBColor, weight: Double) -> RGBColor {
        RGBColor(red: red * weight + base.red * (1 - weight), green: green * weight + base.green * (1 - weight),
                 blue: blue * weight + base.blue * (1 - weight))
    }
}

private struct PalettePair: Sendable {
    let light: RGBColor
    let dark: RGBColor
    let highContrastLight: RGBColor
    let highContrastDark: RGBColor

    init(
        _ light: String,
        _ dark: String,
        highLight: String,
        highDark: String,
        lightAlpha: Double = 1,
        darkAlpha: Double = 1,
        highLightAlpha: Double? = nil,
        highDarkAlpha: Double? = nil
    ) {
        self.light = RGBColor(hex: light, alpha: lightAlpha)
        self.dark = RGBColor(hex: dark, alpha: darkAlpha)
        highContrastLight = RGBColor(hex: highLight, alpha: highLightAlpha ?? lightAlpha)
        highContrastDark = RGBColor(hex: highDark, alpha: highDarkAlpha ?? darkAlpha)
    }
}

private struct RGBColor: Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    init(hex: String, alpha: Double = 1) {
        let value = UInt64(hex.dropFirst(), radix: 16) ?? 0
        red = Double((value >> 16) & 0xff) / 255
        green = Double((value >> 8) & 0xff) / 255
        blue = Double(value & 0xff) / 255
        self.alpha = max(0, min(alpha, 1))
    }

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }
}

public enum LooprSpacing {
    public static let foodReviewThumbnail: CGFloat = 72
    public static let capturePreviewHeight: CGFloat = 500
    public static let captureControlDiameter: CGFloat = 78
    public static let xxs: CGFloat = 4
    public static let xs: CGFloat = 8
    public static let sm: CGFloat = 12
    public static let md: CGFloat = 16
    public static let lg: CGFloat = 20
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32
    public static let hero: CGFloat = 40
    public static let screenGutter: CGFloat = 20
    public static let tabBarClearance: CGFloat = 118
}

public enum LooprRadius {
    public static let calendarCell: CGFloat = 3
    public static let chip: CGFloat = 20
    public static let control: CGFloat = 18
    public static let compactCard: CGFloat = 18
    public static let card: CGFloat = 26
    public static let sheet: CGFloat = 34
}

public enum LooprMotion {
    public static let fast = 0.18
    public static let standard = 0.32
    public static let deliberate = 0.52
    public static let reveal = 1.0

    public static var stateChange: Animation {
        DesignSystemRuntime.state().reduceMotion == true ? .linear(duration: 0) : .easeOut(duration: standard)
    }
    public static var navigation: Animation {
        DesignSystemRuntime.state().reduceMotion == true ? .linear(duration: 0) : .smooth(duration: standard)
    }
    public static var revealAnimation: Animation {
        DesignSystemRuntime.state().reduceMotion == true ? .linear(duration: 0) : .snappy(duration: deliberate)
    }
}
