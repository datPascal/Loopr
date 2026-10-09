import SwiftUI

/// What one full lap of a progress ring stands for.
///
/// A ring only fills against a scale the data actually has: a 0 to 100 score,
/// the 0 to 21 strain scale, or a sleep goal or need the person or the
/// derivation supplied. Without a scale there is no ring fill at all.
public struct LooprRingScale: Equatable, Sendable {
    /// The most laps a ring draws. A night twice as long as the goal already
    /// reads as "well past it"; a third lap would only add noise.
    public static let maximumLaps: Double = 2

    /// The value that fills exactly one lap.
    public let fullValue: Double
    /// Whether a value past `fullValue` starts a second lap. Bounded scores
    /// (0 to 100, 0 to 21) clamp at one lap instead.
    public let allowsOverflow: Bool

    public init(fullValue: Double, allowsOverflow: Bool = false) {
        self.fullValue = fullValue
        self.allowsOverflow = allowsOverflow
    }

    /// The share of one lap `value` fills, clamped to the scale's range.
    /// Nil when there is no value or no usable scale, which a ring renders as
    /// an empty track rather than a zero.
    public func fraction(for value: Double?) -> Double? {
        guard let value, value.isFinite, fullValue.isFinite, fullValue > 0 else { return nil }
        let raw = max(0, value / fullValue)
        return min(raw, allowsOverflow ? Self.maximumLaps : 1)
    }

    /// Whole percent of one lap, for VoiceOver. Not clamped to 100 when the
    /// scale overflows, so "112 percent of your goal" stays true.
    public func percent(for value: Double?) -> Int? {
        fraction(for: value).map { Int(($0 * 100).rounded()) }
    }
}

/// How the centre number is written while it counts up. The resting frame
/// always shows the caller's own display string, so this only has to agree
/// with it at the end of the animation.
public enum LooprRingNumberFormat: Sendable, Equatable {
    case integer
    case oneDecimal
    /// The value is in minutes and reads as `H:MM`.
    case hoursMinutes
    /// The value is in minutes and reads as `7 h 42 m`.
    case hoursMinutesSpelled

    public func text(for value: Double) -> String {
        let value = value.isFinite ? max(0, value) : 0
        switch self {
        case .integer:
            return String(format: "%.0f", value)
        case .oneDecimal:
            return String(format: "%.1f", value)
        case .hoursMinutes:
            let minutes = Int(value)
            return "\(minutes / 60):\(String(format: "%02d", minutes % 60))"
        case .hoursMinutesSpelled:
            let minutes = Int(value)
            return "\(minutes / 60) h \(minutes % 60) m"
        }
    }
}

/// Keeps an animating ring between its previous reading and its target, even
/// if SwiftUI supplies a presentation value beyond either end of the curve.
nonisolated enum LooprRingMotion {
    static func clamped(_ value: Double, from start: Double, to target: Double) -> Double {
        min(max(value, min(start, target)), max(start, target))
    }
}

/// An activity-style progress ring: a rounded arc on a quiet track, an
/// angular gradient in the metric's own colours, and a soft glow at the arc's
/// end. The centre number counts up with the arc.
///
/// The ring fills from zero on first appearance (after `revealDelay`) and
/// animates to a new value whenever `value` changes. With Reduce Motion on it
/// fades in at its final value instead of sweeping.
///
/// The ring is decoration for VoiceOver; the caller owns the spoken label.
public struct LooprProgressRing: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.colorScheme) private var colorScheme

    /// The value the arc and number animate through, in the caller's units.
    /// Nil means "at rest on `value`", so a ring that never appears on screen
    /// (an image render, a test host) still draws its real reading.
    @State private var shown: Double?
    @State private var animationOrigin: Double?
    @State private var hasRevealed = false
    @State private var revealRevision = 0
    /// Whether the Reduce Motion fade has run. Until then a Reduce Motion
    /// ring is transparent so the fade has a first frame to start from.
    @State private var faded = false

    private let value: Double?
    private let scale: LooprRingScale?
    private let text: String
    private let format: LooprRingNumberFormat?
    private let caption: String?
    private let accent: LooprColorToken
    private let diameter: CGFloat
    private let revealDelay: Double
    private let animates: Bool

    /// - Parameters:
    ///   - value: The number the ring measures, or nil when it is unavailable.
    ///   - scale: What one lap stands for, or nil when there is nothing honest
    ///     to measure against. Either nil leaves the track empty.
    ///   - text: The display string at rest, for example `"8:15"` or `"—"`.
    ///   - format: How to write the number while it counts. Nil shows `text`
    ///     throughout.
    ///   - caption: An optional uppercase label under the number, inside the
    ///     ring. Compact rings put their caption below the ring instead.
    ///   - accent: The metric's colour token.
    ///   - diameter: The ring's outer diameter.
    ///   - revealDelay: Seconds to wait before the first fill, for staggering
    ///     a row of rings.
    public init(
        value: Double?,
        scale: LooprRingScale?,
        text: String,
        format: LooprRingNumberFormat? = nil,
        caption: String? = nil,
        accent: LooprColorToken,
        diameter: CGFloat,
        revealDelay: Double = 0,
        animates: Bool = true
    ) {
        self.value = value?.isFinite == true ? value : nil
        self.scale = scale
        self.text = text
        self.format = format
        self.caption = caption
        self.accent = accent
        self.diameter = max(diameter, 1)
        self.revealDelay = max(0, revealDelay)
        self.animates = animates
    }

    /// The first-appearance fill: about a second, settling without a wobble.
    public static let revealAnimation = Animation.easeOut(duration: 0.9)
    /// A later value change: shorter, because the eye is already on the ring.
    public static let updateAnimation = Animation.easeOut(duration: 0.6)
    /// The gap between neighbouring rings' first fills.
    public static let staggerInterval = 0.08

    public var body: some View {
        ZStack {
            track

            if let scale, value != nil {
                LooprRingArc(
                    progress: scale.fraction(for: displayed) ?? 0,
                    startProgress: scale.fraction(for: animationOrigin ?? value) ?? 0,
                    targetProgress: scale.fraction(for: value) ?? 0,
                    maximum: scale.allowsOverflow ? LooprRingScale.maximumLaps : 1,
                    accent: accent,
                    lineWidth: lineWidth,
                    diameter: diameter,
                    isDark: isDark,
                    increasedContrast: DesignSystemRuntime.state().increasedContrast
                )
            }

            centre
                .frame(width: innerWidth)
        }
        .frame(width: diameter, height: diameter)
        .opacity(!animates || faded || !shouldReduceMotion ? 1 : 0)
        .onAppear(perform: reveal)
        .onChange(of: value) { _, newValue in
            update(to: newValue)
        }
        .accessibilityHidden(true)
    }

    // MARK: Pieces

    private var track: some View {
        Circle()
            .stroke(Color.loopr(accent).opacity(trackOpacity), lineWidth: lineWidth)
            .frame(width: diameter - lineWidth, height: diameter - lineWidth)
    }

    @ViewBuilder
    private var centre: some View {
        VStack(spacing: isCompact ? 0 : 5) {
            Group {
                if let value, let format {
                    LooprRingCount(value: displayed, start: animationOrigin ?? value,
                                   target: value, finalText: text, format: format)
                } else {
                    Text(text)
                }
            }
            .font(valueFont)
            .tracking(valueTracking)
            .monospacedDigit()
            .foregroundStyle(Color.loopr(value == nil && !hasTextValue ? .inkSecondary : .ink))
            .lineLimit(1)
            .minimumScaleFactor(0.5)

            if let caption {
                Text(caption.uppercased())
                    .looprTypography(.lensCaption)
                    .foregroundStyle(Color.loopr(.inkSecondary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    // Inside the ring there is only so much room.
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            }
        }
    }

    // MARK: Motion

    private var displayed: Double { animates ? shown ?? value ?? 0 : value ?? 0 }

    private func reveal() {
        guard animates else { return }
        guard !hasRevealed else { return }
        hasRevealed = true
        if shouldReduceMotion {
            withAnimation(.easeOut(duration: LooprMotion.standard)) { faded = true }
            return
        }
        faded = true
        guard value != nil else { return }
        // Park at zero for this frame, then sweep in a separate update: two
        // writes in one update would coalesce and nothing would animate.
        animationOrigin = 0
        shown = 0
        let delay = revealDelay
        let revision = revealRevision
        Task { @MainActor in
            guard revealRevision == revision else { return }
            withAnimation(Self.revealAnimation.delay(delay)) { shown = value }
        }
    }

    private func update(to newValue: Double?) {
        guard animates else { return }
        revealRevision += 1
        let target = newValue.flatMap { $0.isFinite ? $0 : nil } ?? 0
        animationOrigin = shown ?? target
        if shouldReduceMotion {
            shown = target
        } else {
            withAnimation(Self.updateAnimation) { shown = target }
        }
    }

    // MARK: Metrics

    private var isCompact: Bool { diameter < 140 }

    private var lineWidth: CGFloat {
        isCompact ? max(4, diameter * 0.085) : max(8, diameter * 0.07)
    }

    /// The width the centre text may use: the chord a little above and below
    /// the middle, so a long value shrinks before it touches the arc.
    private var innerWidth: CGFloat {
        max(1, (diameter - lineWidth * 2) * 0.84)
    }

    /// The numeral is sized from the ring, not from Dynamic Type on its own:
    /// a numeral that outgrows its ring runs over the arc. Callers that want
    /// larger text grow the ring, as the Today row does.
    private var valueFont: Font {
        .custom("SpaceGrotesk-SemiBold", fixedSize: valueSize)
    }

    private var valueSize: CGFloat {
        // 74 → 18.5 on Today; 172 → 40, the lens value size, on a hero.
        isCompact ? diameter * 0.25 : diameter * LooprTextStyle.lensValue.baseSize / 172
    }

    private var valueTracking: CGFloat {
        isCompact ? -0.02 * valueSize : LooprTextStyle.lensValue.tracking * valueSize / LooprTextStyle.lensValue.baseSize
    }

    /// A non-numeric reading such as "Low" is still a value, not an absence.
    private var hasTextValue: Bool {
        !text.isEmpty && text != "—" && text != "-"
    }

    private var trackOpacity: Double {
        let increased = DesignSystemRuntime.state().increasedContrast
        if isDark { return increased ? 0.30 : 0.17 }
        return increased ? 0.26 : 0.13
    }

    private var isDark: Bool { LooprAppearance.isDark(colorScheme) }

    private var shouldReduceMotion: Bool {
        accessibilityReduceMotion || DesignSystemRuntime.state().reduceMotion == true
    }
}

/// The arc itself. It is the one view whose body runs per animation frame, so
/// it only builds a handful of shapes from `progress`.
private struct LooprRingArc: View, Animatable {
    var progress: Double
    let startProgress: Double
    let targetProgress: Double
    let maximum: Double
    let accent: LooprColorToken
    let lineWidth: CGFloat
    let diameter: CGFloat
    let isDark: Bool
    let increasedContrast: Bool

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = LooprRingMotion.clamped(newValue, from: startProgress, to: targetProgress) }
    }

    var body: some View {
        let clamped = min(max(progress, 0), maximum)
        let firstLap = min(clamped, 1)
        let secondLap = max(clamped - 1, 0)

        ZStack {
            if isDark && !increasedContrast {
                // A soft bloom under the first lap so the arc reads as light,
                // not paint, on the near-black background.
                arc(span: firstLap)
                    .blur(radius: lineWidth * 0.9)
                    .opacity(0.38)
            }
            arc(span: firstLap)
            if secondLap > 0 {
                // The second lap carries on in the colour the first lap ended
                // in, so it reads as one line wrapping past the start rather
                // than a new ring restarting its gradient.
                Circle()
                    .trim(from: 0, to: secondLap)
                    .stroke(endColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            }
            tip(at: clamped, overlapping: secondLap > 0)
        }
        .frame(width: pathDiameter, height: pathDiameter)
        // Circle trims start at three o'clock; the ring starts at twelve.
        .rotationEffect(.degrees(-90))
    }

    /// Strokes straddle their path, so the path sits half a line inside the
    /// ring's outer edge.
    private var pathDiameter: CGFloat { max(1, diameter - lineWidth) }

    private func arc(span: Double) -> some View {
        Circle()
            .trim(from: 0, to: span)
            .stroke(
                AngularGradient(
                    colors: [startColor, endColor],
                    center: .center,
                    startAngle: .zero,
                    endAngle: .degrees(360 * max(span, 0.0001))
                ),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            )
    }

    /// The arc's leading end: a cap in the end colour with a glow, and on a
    /// second lap a short shadow ahead of it so the overlap reads as a lap.
    private func tip(at progress: Double, overlapping: Bool) -> some View {
        Circle()
            .fill(endColor)
            .frame(width: lineWidth, height: lineWidth)
            .shadow(color: endColor.opacity(isDark ? 0.85 : 0.45), radius: lineWidth * (isDark ? 0.9 : 0.6))
            // Before rotation the tip sits at three o'clock travelling down,
            // so a positive y offset puts the shadow just ahead of it.
            .shadow(
                color: Color.black.opacity(overlapping ? (isDark ? 0.6 : 0.3) : 0),
                radius: lineWidth * 0.4,
                y: lineWidth * 0.4
            )
            .offset(x: pathDiameter / 2)
            .rotationEffect(.degrees(360 * progress))
    }

    private var startColor: Color {
        Color.loopr(accent).opacity(isDark ? 0.92 : 0.9)
    }

    private var endColor: Color {
        Color.loopr(accent.spectralSweepPartner)
    }
}

/// The centre number. SwiftUI interpolates `value` between the old and new
/// reading; at rest it shows the caller's own display string.
private struct LooprRingCount: View, Animatable {
    var value: Double
    let start: Double
    let target: Double
    let finalText: String
    let format: LooprRingNumberFormat

    nonisolated var animatableData: Double {
        get { value }
        set { value = LooprRingMotion.clamped(newValue, from: start, to: target) }
    }

    var body: some View {
        Text(value == target ? finalText : format.text(for: value))
    }
}

/// A screen's hero reading drawn as a large progress ring, seated the way the
/// hero lens is: open on the dark background, on a white card in light mode
/// with the footer line inside the card.
public struct LooprRingHero<Footer: View>: View {
    @Environment(\.colorScheme) private var colorScheme

    private let value: Double?
    private let scale: LooprRingScale?
    private let text: String
    private let format: LooprRingNumberFormat?
    private let caption: String
    private let accent: LooprColorToken
    private let diameter: CGFloat
    private let footer: Footer

    public init(
        value: Double?,
        scale: LooprRingScale?,
        text: String,
        format: LooprRingNumberFormat? = nil,
        caption: String,
        accent: LooprColorToken,
        diameter: CGFloat = 172,
        @ViewBuilder footer: () -> Footer
    ) {
        self.value = value
        self.scale = scale
        self.text = text
        self.format = format
        self.caption = caption
        self.accent = accent
        self.diameter = diameter
        self.footer = footer()
    }

    public var body: some View {
        if isDark {
            stack
                .padding(.top, 26)
                .padding(.horizontal, LooprSpacing.md)
                .padding(.bottom, LooprSpacing.xs)
                .frame(maxWidth: .infinity)
        } else {
            stack
                .padding(.top, 26)
                .padding(.horizontal, 18)
                .padding(.bottom, 22)
                .frame(maxWidth: .infinity)
                .background(
                    Color.loopr(.sheetFill),
                    in: RoundedRectangle(cornerRadius: LooprRadius.card, style: .continuous)
                )
                .shadow(color: Color.loopr(.ink).opacity(0.06), radius: 2, y: 1)
                .shadow(color: Color.loopr(.ink).opacity(0.05), radius: 15, y: 10)
                .padding(.horizontal, LooprSpacing.md)
        }
    }

    private var stack: some View {
        VStack(spacing: 14) {
            LooprProgressRing(
                value: value,
                scale: scale,
                text: text,
                format: format,
                caption: caption,
                accent: accent,
                // The light hero card is a touch tighter, as the lens was.
                diameter: !isDark && diameter == 172 ? 168 : diameter
            )
            footer
        }
        .frame(maxWidth: .infinity)
    }

    private var isDark: Bool { LooprAppearance.isDark(colorScheme) }
}

public extension LooprRingHero where Footer == EmptyView {
    init(
        value: Double?,
        scale: LooprRingScale?,
        text: String,
        format: LooprRingNumberFormat? = nil,
        caption: String,
        accent: LooprColorToken,
        diameter: CGFloat = 172
    ) {
        self.init(value: value, scale: scale, text: text, format: format, caption: caption,
                  accent: accent, diameter: diameter) { EmptyView() }
    }
}
