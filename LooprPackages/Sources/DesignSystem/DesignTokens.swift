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
        case .background: .init("#F3F4F6", "#0A0D11", highLight: "#FFFFFF", highDark: "#05070A")
        case .settingsBackground: .init("#EDEFF2", "#05070A", highLight: "#E3E7EC", highDark: "#000000")
        case .surface: .init(
            "#FFFFFF", "#A0BEDC", highLight: "#FFFFFF", highDark: "#D8E7F4",
            darkAlpha: 0.07, highDarkAlpha: 0.16
        )
        case .surfaceElevated: .init("#FFFFFF", "#1A2029", highLight: "#FFFFFF", highDark: "#283545")
        case .surfaceSunk: .init("#EEF1F5", "#0D1116", highLight: "#E5E9EE", highDark: "#020408")
        case .surfaceStroke: .init(
            "#102030", "#A0BEDC", highLight: "#0B1118", highDark: "#D9ECFF",
            lightAlpha: 0, darkAlpha: 0.08, highLightAlpha: 0.14, highDarkAlpha: 0.16
        )
        case .divider: .init(
            "#102030", "#A0BEDC", highLight: "#0B1118", highDark: "#D9ECFF",
            lightAlpha: 0.08, darkAlpha: 0.08, highLightAlpha: 0.16, highDarkAlpha: 0.16
        )
        case .ink: .init("#101820", "#EEF2F8", highLight: "#000000", highDark: "#FFFFFF")
        case .inkSecondary: .init("#5D6B7A", "#7C889C", highLight: "#34404B", highDark: "#A7B4C8")
        case .inkMuted: .init("#9AA5B1", "#5D6A80", highLight: "#7A8794", highDark: "#7C889C")
        case .sheetFill: .init("#FFFFFF", "#0D1015", highLight: "#FFFFFF", highDark: "#151B24")
        case .brand: .init("#00A6BE", "#2AD4E6", highLight: "#007B8E", highDark: "#78FFDC")
        case .brandSoft: .init(
            "#00A6BE", "#2AD4E6", highLight: "#007B8E", highDark: "#78FFDC",
            lightAlpha: 0.10, darkAlpha: 0.13, highLightAlpha: 0.16, highDarkAlpha: 0.20
        )
        case .brandSweep: .init("#00A6BE", "#78FFDC", highLight: "#00697A", highDark: "#B0FFE9")
        case .brandChip: .init("#00A6BE", "#78FFDC", highLight: "#00697A", highDark: "#B0FFE9")
        case .heart: .init("#E2205A", "#FF4D7E", highLight: "#B51247", highDark: "#FF86A8")
        case .heartSoft: .init(
            "#E2205A", "#FF4D7E", highLight: "#B51247", highDark: "#FF86A8",
            lightAlpha: 0.10, darkAlpha: 0.13, highLightAlpha: 0.16, highDarkAlpha: 0.20
        )
        case .heartSweep: .init("#B432E6", "#D654FF", highLight: "#8621BA", highDark: "#F0A5FF")
        case .heartChip: .init("#E2205A", "#FF86A8", highLight: "#B51247", highDark: "#FFB0C5")
        case .recovery: .init("#00A6BE", "#2AD4E6", highLight: "#007B8E", highDark: "#78FFDC")
        case .sleep: .init("#6C48FF", "#7C5CFF", highLight: "#5230DB", highDark: "#A794FF")
        case .sleepSweep: .init("#4078FF", "#5A8CFF", highLight: "#275ACF", highDark: "#8CB0FF")
        case .sleepChip: .init("#6C48FF", "#A794FF", highLight: "#5230DB", highDark: "#C1B8FF")
        case .strain: .init("#E07400", "#FF9A2E", highLight: "#B65300", highDark: "#FFB867")
        case .strainSweep: .init("#E64628", "#FF603C", highLight: "#B72E18", highDark: "#FF9D83")
        case .strainChip: .init("#E07400", "#FFB867", highLight: "#B65300", highDark: "#FFD19A")
        case .movement: .init("#00A6BE", "#2AD4E6", highLight: "#007B8E", highDark: "#78FFDC")
        case .energy: .init("#E07400", "#FF9A2E", highLight: "#B65300", highDark: "#FFB867")
        case .stress: .init("#E2205A", "#FF4D7E", highLight: "#B51247", highDark: "#FF86A8")
        case .cycle: .init("#E2205A", "#FF4D7E", highLight: "#B51247", highDark: "#FF86A8")
        case .cyclePlum: .init("#B432E6", "#D654FF", highLight: "#8621BA", highDark: "#F0A5FF")
        case .warning: .init("#E07400", "#FF9A2E", highLight: "#B65300", highDark: "#FFB867")
        case .critical: .init("#E2205A", "#FF4D7E", highLight: "#B51247", highDark: "#FF86A8")
        case .lowConfidence: .init("#9AA5B1", "#5D6A80", highLight: "#7A8794", highDark: "#7C889C")
        case .sleepAwake: .init("#E07400", "#FF9A2E", highLight: "#B65300", highDark: "#FFB867")
        case .sleepLight: .init("#4078FF", "#5A8CFF", highLight: "#275ACF", highDark: "#8CB0FF")
        case .sleepDeep: .init("#3B22B8", "#6A4DFF", highLight: "#2A1690", highDark: "#9C88FF")
        case .sleepREM: .init("#A77BFF", "#C3A2FF", highLight: "#7E4BE8", highDark: "#DCC8FF")
        case .recoveryHigh: .init("#16A34A", "#34D77B", highLight: "#0F7A36", highDark: "#86EFAC")
        case .recoveryHighSweep: .init("#22B8A0", "#7CF0B4", highLight: "#11806F", highDark: "#BBF7D0")
        case .recoveryMid: .init("#D99A00", "#FFCB3D", highLight: "#9A6B00", highDark: "#FFE28A")
        case .recoveryMidSweep: .init("#E8B400", "#FFE27A", highLight: "#A37A00", highDark: "#FFF0B8")
        case .recoveryLow: .init("#DC3B2E", "#FF5B4F", highLight: "#A8261B", highDark: "#FF9B92")
        case .recoveryLowSweep: .init("#E8663A", "#FF8A66", highLight: "#B2401D", highDark: "#FFB8A3")
        case .caution: .init("#B25A00", "#FFB054", highLight: "#8A4400", highDark: "#FFD19A")
        case .brandInk: .init("#007A8A", "#5EE3F0", highLight: "#005A66", highDark: "#A6F4FA")
        }
    }

    /// The colour used for the second stop in the lens sweep for this token's domain.
    public var spectralSweepPartner: LooprColorToken {
        switch self {
        case .sleep, .sleepSweep, .sleepChip, .sleepAwake, .sleepLight, .sleepDeep, .sleepREM: .sleepSweep
        case .heart, .heartSoft, .heartSweep, .heartChip, .stress, .cycle, .cyclePlum, .critical: .heartSweep
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
        case .heart, .heartSoft, .heartSweep, .heartChip, .stress, .cycle, .cyclePlum, .critical: 20
        case .strain, .strainSweep, .strainChip, .energy, .warning: 300
        default: 150
        }
    }

    public var spectralRotationPeriod: Double {
        switch self {
        case .sleep, .sleepSweep, .sleepChip, .sleepAwake, .sleepLight, .sleepDeep, .sleepREM: 16
        case .heart, .heartSoft, .heartSweep, .heartChip, .stress, .cycle, .cyclePlum, .critical: 13
        case .strain, .strainSweep, .strainChip, .energy, .warning: 18
        default: 12
        }
    }

    /// The colour for small text in this domain's accent: readable on the
    /// page and card backgrounds in both appearances. Delta captions and
    /// section actions use it instead of the fill colour.
    public var textInk: LooprColorToken {
        switch self {
        case .sleep, .sleepSweep, .sleepChip, .sleepAwake, .sleepLight, .sleepDeep, .sleepREM: .sleepChip
        case .heart, .heartSoft, .heartSweep, .heartChip, .stress, .cycle, .cyclePlum, .critical: .heartChip
        case .strain, .strainSweep, .strainChip, .energy, .warning, .caution: .caution
        case .ink, .inkSecondary, .inkMuted: self
        default: .brandInk
        }
    }

    /// The brighter label colour used by this domain's dark-mode chip.
    public var spectralChipLabel: LooprColorToken {
        switch self {
        case .sleep, .sleepSweep, .sleepChip, .sleepAwake, .sleepLight, .sleepDeep, .sleepREM: .sleepChip
        case .heart, .heartSoft, .heartSweep, .heartChip, .stress, .cycle, .cyclePlum, .critical: .heartChip
        case .strain, .strainSweep, .strainChip, .energy, .warning: .strainChip
        case .recoveryHigh, .recoveryHighSweep: .recoveryHigh
        case .recoveryMid, .recoveryMidSweep: .recoveryMid
        case .recoveryLow, .recoveryLowSweep: .recoveryLow
        case .caution: .caution
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
}

public enum LooprSpacing {
    public static let xxs: CGFloat = 4
    public static let xs: CGFloat = 8
    public static let sm: CGFloat = 12
    public static let md: CGFloat = 16
    public static let lg: CGFloat = 20
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32
    public static let hero: CGFloat = 40
    public static let screenGutter: CGFloat = 16
    public static let tabBarClearance: CGFloat = 118
}

public enum LooprRadius {
    public static let chip: CGFloat = 20
    public static let control: CGFloat = 14
    public static let compactCard: CGFloat = 14
    public static let card: CGFloat = 20
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
