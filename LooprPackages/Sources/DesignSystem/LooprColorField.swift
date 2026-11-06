import Combine
import SwiftUI

/// The five tabs, each with its own colour field (DEC-12.2 and the contract's per-phone `.aura`).
public enum LooprColorFieldTab: String, CaseIterable, Sendable {
    case today
    case food
    case fitness
    case `protocol`
    case data

    /// The tab's accent (DESIGN_LANGUAGE, "Tabs and accents").
    public var accent: LooprColorToken {
        switch self {
        case .today, .data: .brand
        case .food: .energy
        case .fitness: .strain
        case .protocol: .protocol
        }
    }
}

/// One soft blob of the field, in the contract's units: a box placed as a percentage of the
/// screen, a radial gradient to transparent inside it, and how far ahead it is in the drift.
public struct LooprColorFieldBlob: Equatable, Sendable {
    public let tint: LooprColorToken
    /// The centre as a fraction of the field's width and height.
    public let centre: CGPoint
    /// Half the box, as a fraction of the field's width and height.
    public let radius: CGSize
    public let opacity: Double
    /// Seconds into the 22 s drift: the contract's negative `animation-delay`.
    public let lead: Double

    /// `left`, `top`, `width` and `height` are the contract's percentages; `delay` is its
    /// `animation-delay` in seconds (zero or negative).
    public init(_ tint: LooprColorToken, left: Double, top: Double, width: Double, height: Double,
                opacity: Double = 1, delay: Double = 0) {
        self.tint = tint
        centre = CGPoint(x: (left + width / 2) / 100, y: (top + height / 2) / 100)
        radius = CGSize(width: width / 200, height: height / 200)
        self.opacity = opacity
        lead = -delay
    }

    /// For a blob placed with `right` instead of `left`.
    public init(_ tint: LooprColorToken, right: Double, top: Double, width: Double, height: Double,
                opacity: Double = 1, delay: Double = 0) {
        self.init(tint, left: 100 - right - width, top: top, width: width, height: height, opacity: opacity, delay: delay)
    }
}

/// The three blobs of one field and the accent its flat fallback uses.
public struct LooprColorFieldPalette: Equatable, Sendable {
    public let accent: LooprColorToken
    public let blobs: [LooprColorFieldBlob]

    public init(accent: LooprColorToken, blobs: [LooprColorFieldBlob]) {
        self.accent = accent
        self.blobs = Array(blobs.prefix(Self.maximumBlobs))
    }

    /// The shader draws at most this many blobs.
    public static let maximumBlobs = 3

    /// The contract's blobs for each tab phone.
    public static func tab(_ tab: LooprColorFieldTab) -> Self {
        switch tab {
        case .today:
            Self(accent: tab.accent, blobs: [
                .init(.sleep, left: -10, top: -6, width: 70, height: 38),
                .init(.brand, right: -20, top: 4, width: 65, height: 30, delay: -6),
                .init(.protocol, left: 20, top: 30, width: 60, height: 26, opacity: 0.4, delay: -11)
            ])
        case .food:
            Self(accent: tab.accent, blobs: [
                .init(.energy, left: -15, top: -6, width: 75, height: 34),
                .init(.heart, right: -25, top: 6, width: 60, height: 26, opacity: 0.5, delay: -7),
                .init(.brand, left: 10, top: 40, width: 70, height: 24, opacity: 0.3, delay: -13)
            ])
        case .fitness:
            Self(accent: tab.accent, blobs: [
                .init(.strain, left: -15, top: -6, width: 72, height: 34),
                .init(.heart, right: -20, top: 2, width: 60, height: 26, opacity: 0.55, delay: -5),
                .init(.energy, left: 20, top: 44, width: 60, height: 22, opacity: 0.25, delay: -12)
            ])
        case .protocol:
            Self(accent: tab.accent, blobs: [
                .init(.protocol, left: -15, top: -6, width: 75, height: 34),
                .init(.sleep, right: -25, top: 4, width: 62, height: 28, opacity: 0.6, delay: -8),
                .init(.heart, left: 25, top: 40, width: 55, height: 22, opacity: 0.25, delay: -3)
            ])
        case .data:
            Self(accent: tab.accent, blobs: [
                .init(.brand, left: -15, top: -6, width: 75, height: 34),
                .init(.sleep, right: -25, top: 6, width: 60, height: 26, opacity: 0.45, delay: -9),
                .init(.strain, left: 30, top: 42, width: 50, height: 20, opacity: 0.2, delay: -4)
            ])
        }
    }

    /// A field led by `accent`. The tab accents get their tab's field; any other colour leads the
    /// Data tab's arrangement.
    public static func accent(_ accent: LooprColorToken) -> Self {
        switch accent {
        case .energy: tab(.food)
        case .strain: tab(.fitness)
        case .protocol, .protocolChip, .cyclePlum, .cyclePlumChip: tab(.protocol)
        case .brand: tab(.data)
        default:
            Self(accent: accent, blobs: [LooprColorFieldBlob(accent, left: -15, top: -6, width: 75, height: 34)]
                + tab(.data).blobs.dropFirst())
        }
    }

    /// The blob geometry the shader reads, six floats per blob.
    var shaderValues: [Float] {
        blobs.flatMap { blob in
            [Float(blob.centre.x), Float(blob.centre.y), Float(blob.radius.width), Float(blob.radius.height),
             Float(blob.opacity), Float(blob.lead)]
        }
    }

    /// The blob tints, padded to three with a blob the shader never reaches.
    var shaderTints: [LooprColorToken] {
        let tints = blobs.map(\.tint)
        return tints + Array(repeating: accent, count: Self.maximumBlobs - tints.count)
    }
}

/// What the field draws, decided from its inputs alone so each rule can be tested.
public struct LooprColorFieldPolicy: Equatable, Sendable {
    public enum Rendering: Equatable, Sendable {
        /// The blobs drift: the timeline ticks.
        case animated
        /// The blobs at rest and the grain. The timeline does not tick.
        case still
        /// Reduce Transparency: one flat wash of the accent over the page, no gradients.
        case flatWash
        /// Increase Contrast: the plain page colour.
        case plain
    }

    public var isVisible: Bool
    public var isLowPowerModeEnabled: Bool
    public var reduceMotion: Bool
    public var reduceTransparency: Bool
    public var increasedContrast: Bool

    public init(isVisible: Bool, isLowPowerModeEnabled: Bool, reduceMotion: Bool,
                reduceTransparency: Bool, increasedContrast: Bool) {
        self.isVisible = isVisible
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
        self.reduceMotion = reduceMotion
        self.reduceTransparency = reduceTransparency
        self.increasedContrast = increasedContrast
    }

    public var rendering: Rendering {
        if increasedContrast { return .plain }
        if reduceTransparency { return .flatWash }
        if !isVisible || isLowPowerModeEnabled || reduceMotion { return .still }
        return .animated
    }

    /// True only while the field drifts. Every other rendering is one static frame.
    public var ticks: Bool { rendering == .animated }
}

/// How strongly the field shows in each appearance: the contract's `--auraOp`, `--grainOp` and
/// `--grainBlend`. Dark is the main design; light is warm paper with the same blobs, fainter.
public struct LooprColorFieldIntensity: Equatable, Sendable {
    public let aura: Double
    public let grain: Double
    /// Light mode multiplies the grain into the paper; dark mode dithers around the colour.
    public let multipliesGrain: Bool
    /// The accent's opacity in the Reduce Transparency wash.
    public let wash: Double

    public static let dark = Self(aura: 0.55, grain: 0.09, multipliesGrain: false, wash: 0.08)
    public static let light = Self(aura: 0.32, grain: 0.05, multipliesGrain: true, wash: 0.05)

    public static func forDark(_ isDark: Bool) -> Self { isDark ? .dark : .light }
}

/// The drifting colour field behind a tab's scroll view, with a faint grain. One Metal pass over
/// the page colour (`Shaders/LooprColorField.metal`). It sits behind the scroll view, so
/// scrolling never redraws it. It holds a still frame while hidden, in Low Power Mode and under
/// Reduce Motion, and falls back to a flat wash or the plain page under the accessibility settings.
///
/// ```swift
/// ZStack {
///     LooprColorField(accent: .protocol)
///     ScrollView { ... }
/// }
/// ```
public struct LooprColorField: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var isOnScreen = false
    @State private var isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled

    private let palette: LooprColorFieldPalette

    public init(accent: LooprColorToken) {
        palette = .accent(accent)
    }

    public init(tab: LooprColorFieldTab) {
        palette = .tab(tab)
    }

    public init(palette: LooprColorFieldPalette) {
        self.palette = palette
    }

    /// The `[[ stitchable ]]` function in `Shaders/LooprColorField.metal`.
    public nonisolated static let shaderFunctionName = "looprColorField"
    /// The drift takes 22 s each way, so 30 frames a second is smooth and leaves the GPU to scrolling.
    nonisolated static let frameInterval: TimeInterval = 1.0 / 30
    /// The bundle that holds the compiled shader library.
    nonisolated static var shaderBundle: Bundle { .module }

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
        field
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            .accessibilityHidden(true)
            .allowsHitTesting(false)
            .onAppear {
                isOnScreen = true
                isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
            .onDisappear { isOnScreen = false }
            .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange).receive(on: RunLoop.main)) { _ in
                isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
    }

    @ViewBuilder private var field: some View {
        let rendering = policy.rendering
        let intensity = LooprColorFieldIntensity.forDark(LooprAppearance.isDark(colorScheme))
        switch rendering {
        case .plain:
            Color.loopr(.background)
        case .flatWash:
            Color.loopr(.background)
                .overlay(Color.loopr(palette.accent).opacity(intensity.wash))
        case .animated, .still:
            GeometryReader { proxy in
                TimelineView(.animation(minimumInterval: Self.frameInterval, paused: rendering != .animated)) { context in
                    Rectangle()
                        .fill(Color.loopr(.background))
                        .colorEffect(shader(size: proxy.size, date: context.date, animated: rendering == .animated,
                                            intensity: intensity))
                }
            }
        }
    }

    private func shader(size: CGSize, date: Date, animated: Bool, intensity: LooprColorFieldIntensity) -> Shader {
        let tints = palette.shaderTints.map { Shader.Argument.color(Color.loopr($0)) }
        // Wrapped to two drift cycles before the cast, so a Float keeps its precision.
        let seconds = animated ? date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 44) : 0
        let function = ShaderFunction(library: .bundle(Self.shaderBundle), name: Self.shaderFunctionName)
        return Shader(function: function, arguments: [
            .float2(size),
            .float(seconds),
            .float(animated ? 1 : 0)
        ] + tints + [
            .floatArray(palette.shaderValues),
            .float(intensity.aura),
            .float(intensity.grain),
            .float(intensity.multipliesGrain ? 1 : 0)
        ])
    }
}
