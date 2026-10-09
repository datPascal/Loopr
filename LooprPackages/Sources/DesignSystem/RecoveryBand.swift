import SwiftUI

/// The three recovery bands, the only place in Loopr where green, yellow and
/// red carry meaning (tabs spec, principle 6). Use it for the recovery score
/// and nothing else: strain, sleep and vitals keep their domain accent.
///
/// The cut-offs match what WHOOP users already know: 67 to 100 is high,
/// 34 to 66 is middle, 0 to 33 is low. The score is rounded to a whole number
/// first, so 66.6 counts as 67 and lands in the high band, the same number the
/// ring prints.
///
/// ```swift
/// if let band = LooprRecoveryBand(score: 74) {
///     LooprProgressRing(value: 74, scale: LooprRingScale(fullValue: 100),
///                       text: "74", accent: band.token, diameter: 172)
///     LooprText(band.verdict, style: .title)      // "Ready"
///     LooprRecoveryBandLabel(band)                // dot + verdict, for rows
/// }
/// ```
public enum LooprRecoveryBand: String, CaseIterable, Sendable, Hashable {
    case high
    case middle
    case low

    /// The whole-number boundaries, inclusive.
    public static let highRange = 67...100
    public static let middleRange = 34...66
    public static let lowRange = 0...33

    /// The band for a 0 to 100 recovery score, or nil when there is no score.
    /// Values outside 0...100 are clamped; non-finite values return nil.
    public init?(score: Double?) {
        guard let score, score.isFinite else { return nil }
        let whole = min(max(Int(score.rounded()), 0), 100)
        switch whole {
        case Self.highRange: self = .high
        case Self.middleRange: self = .middle
        default: self = .low
        }
    }

    /// The ring and dot colour. Each has light, dark and increased-contrast
    /// variants, and a sweep partner so `LooprProgressRing` draws a gradient
    /// in the band's own hue.
    public var token: LooprColorToken {
        switch self {
        case .high: .recoveryHigh
        case .middle: .recoveryMid
        case .low: .recoveryLow
        }
    }

    /// One word under the recovery number.
    public var verdict: String {
        switch self {
        case .high: "Ready"
        case .middle: "Steady"
        case .low: "Recover"
        }
    }

    /// A short, neutral suggestion for the day. The Today hero may replace it
    /// with a sentence that names the biggest driver.
    public var guidance: String {
        switch self {
        case .high: "A good day to push."
        case .middle: "Moderate effort suits today."
        case .low: "Keep today light and get to bed on time."
        }
    }

    /// What VoiceOver says after the score, for example "74 percent, high
    /// recovery, ready".
    public var spokenDescription: String {
        switch self {
        case .high: "high recovery, ready"
        case .middle: "middle recovery, steady"
        case .low: "low recovery, recover"
        }
    }
}

/// A small coloured dot and the band's verdict word, for rows and legends
/// where the band has to be named without a ring. The dot is decoration; the
/// word carries the meaning, so the label works without colour.
public struct LooprRecoveryBandLabel: View {
    @ScaledMetric(relativeTo: .caption) private var dotSize: CGFloat = 8
    private let band: LooprRecoveryBand
    private let style: LooprTextStyle

    public init(_ band: LooprRecoveryBand, style: LooprTextStyle = .label) {
        self.band = band
        self.style = style
    }

    public var body: some View {
        HStack(spacing: LooprSpacing.xs - 2) {
            Circle()
                .fill(Color.loopr(band.token))
                .frame(width: dotSize, height: dotSize)
                .accessibilityHidden(true)
            Text(band.verdict)
                .looprTypography(style)
                .foregroundStyle(Color.loopr(.ink))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(band.spokenDescription.prefix(1).uppercased() + band.spokenDescription.dropFirst())
    }
}

#Preview("Recovery bands") {
    VStack(spacing: LooprSpacing.lg) {
        HStack(spacing: LooprSpacing.lg) {
            ForEach([88.0, 52, 21], id: \.self) { score in
                let band = LooprRecoveryBand(score: score)!
                VStack(spacing: LooprSpacing.xs) {
                    LooprProgressRing(value: score, scale: LooprRingScale(fullValue: 100),
                                      text: String(format: "%.0f", score), accent: band.token, diameter: 96)
                    LooprRecoveryBandLabel(band)
                }
            }
        }
    }
    .padding()
    .background(Color.loopr(.background))
}
