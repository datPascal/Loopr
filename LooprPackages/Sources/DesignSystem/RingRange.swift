import SwiftUI

/// Where a `LooprProgressRing` draws its track, so a layer drawn behind or in
/// front of the ring lines up with it exactly.
public enum LooprRingGeometry {
    /// The stroke width `LooprProgressRing` uses at `diameter`. Keep in step
    /// with `LooprProgressRing.lineWidth`.
    public static func lineWidth(diameter: CGFloat) -> CGFloat {
        let diameter = max(diameter, 1)
        return diameter < 140 ? max(4, diameter * 0.085) : max(8, diameter * 0.07)
    }

    /// The diameter of the circle the stroke is centred on.
    public static func pathDiameter(diameter: CGFloat) -> CGFloat {
        max(1, max(diameter, 1) - lineWidth(diameter: diameter))
    }

    /// The share of one lap for each end of `range`, clamped to one lap, or
    /// nil when the scale or the range cannot be drawn.
    public static func fractions(of range: ClosedRange<Double>, scale: LooprRingScale) -> ClosedRange<Double>? {
        guard range.lowerBound.isFinite, range.upperBound.isFinite,
              let lower = scale.fraction(for: range.lowerBound),
              let upper = scale.fraction(for: range.upperBound) else { return nil }
        let low = min(lower, 1)
        let high = min(upper, 1)
        guard high > low else { return nil }
        return low...high
    }
}

/// A target range drawn on a progress ring's track: a brighter segment of the
/// track between the two ends, with a short tick across the track at each end
/// so the edges still read when the arc covers the segment.
///
/// Put it behind a `LooprProgressRing` of the same diameter:
///
/// ```swift
/// ZStack {
///     LooprRingRange(14...18, scale: LooprRingScale(fullValue: 21), accent: .strain, diameter: 172)
///     LooprProgressRing(value: 8.6, scale: LooprRingScale(fullValue: 21), text: "8.6",
///                       caption: "Strain", accent: .strain, diameter: 172)
/// }
/// ```
///
/// The ring's own track is translucent, so the segment shows through it, and
/// the arc draws over it: a strain inside the range ends inside the segment.
/// The view is decoration for VoiceOver; the caller says the range in words.
public struct LooprRingRange: View {
    @Environment(\.colorScheme) private var colorScheme

    private let range: ClosedRange<Double>
    private let scale: LooprRingScale
    private let accent: LooprColorToken
    private let diameter: CGFloat

    public init(_ range: ClosedRange<Double>, scale: LooprRingScale, accent: LooprColorToken, diameter: CGFloat) {
        self.range = range
        self.scale = scale
        self.accent = accent
        self.diameter = max(diameter, 1)
    }

    public var body: some View {
        let lineWidth = LooprRingGeometry.lineWidth(diameter: diameter)
        let path = LooprRingGeometry.pathDiameter(diameter: diameter)
        ZStack {
            if let fractions = LooprRingGeometry.fractions(of: range, scale: scale) {
                Circle()
                    .trim(from: fractions.lowerBound, to: fractions.upperBound)
                    .stroke(Color.loopr(accent).opacity(segmentOpacity), style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                    .frame(width: path, height: path)
                tick(at: fractions.lowerBound, lineWidth: lineWidth, path: path)
                tick(at: fractions.upperBound, lineWidth: lineWidth, path: path)
            }
        }
        // Circle trims start at three o'clock; rings start at twelve.
        .rotationEffect(.degrees(-90))
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }

    private func tick(at fraction: Double, lineWidth: CGFloat, path: CGFloat) -> some View {
        Capsule(style: .continuous)
            .fill(Color.loopr(accent.textInk))
            .frame(width: lineWidth + 8, height: 2.5)
            .offset(x: path / 2)
            .rotationEffect(.degrees(360 * fraction))
    }

    private var segmentOpacity: Double {
        let increased = DesignSystemRuntime.state().increasedContrast
        if LooprAppearance.isDark(colorScheme) { return increased ? 0.62 : 0.42 }
        return increased ? 0.55 : 0.34
    }
}

#Preview("Ring range") {
    HStack(spacing: 24) {
        ZStack {
            LooprRingRange(14...18, scale: LooprRingScale(fullValue: 21), accent: .strain, diameter: 172)
            LooprProgressRing(value: 8.6, scale: LooprRingScale(fullValue: 21), text: "8.6", format: .oneDecimal,
                              caption: "Strain", accent: .strain, diameter: 172)
        }
        ZStack {
            LooprRingRange(10...14, scale: LooprRingScale(fullValue: 21), accent: .strain, diameter: 74)
            LooprProgressRing(value: 12.1, scale: LooprRingScale(fullValue: 21), text: "12.1", format: .oneDecimal,
                              accent: .strain, diameter: 74)
        }
    }
    .padding()
    .background(Color.loopr(.background))
}
