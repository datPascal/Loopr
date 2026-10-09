import SwiftUI

/// Where one value sits against the person's usual range. The track is the
/// scale, the tinted segment is the usual range and the dot is the value.
/// Colour never carries the meaning alone: the caller prints the status next
/// to it.
public struct LooprTypicalRangeBar: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let value: Double
    private let typical: ClosedRange<Double>
    private let domain: ClosedRange<Double>
    private let accent: LooprColorToken
    private let lowLabel: String?
    private let highLabel: String?

    /// `domain` defaults to the typical range widened on both sides so a value
    /// just outside it still lands on the track.
    public init(
        value: Double,
        typical: ClosedRange<Double>,
        domain: ClosedRange<Double>? = nil,
        accent: LooprColorToken,
        lowLabel: String? = nil,
        highLabel: String? = nil
    ) {
        self.value = value
        self.typical = typical
        self.domain = domain ?? Self.defaultDomain(value: value, typical: typical)
        self.accent = accent
        self.lowLabel = lowLabel
        self.highLabel = highLabel
    }

    static func defaultDomain(value: Double, typical: ClosedRange<Double>) -> ClosedRange<Double> {
        let width = max(typical.upperBound - typical.lowerBound, abs(typical.lowerBound) * 0.02, 0.001)
        let lower = min(typical.lowerBound - width * 1.2, value - width * 0.3)
        let upper = max(typical.upperBound + width * 1.2, value + width * 0.3)
        return lower...upper
    }

    /// Position of `x` on the track, 0 at the left edge and 1 at the right.
    static func fraction(_ x: Double, in domain: ClosedRange<Double>) -> Double {
        let span = domain.upperBound - domain.lowerBound
        guard span > 0, x.isFinite else { return 0.5 }
        return min(max((x - domain.lowerBound) / span, 0), 1)
    }

    public var body: some View {
        VStack(spacing: LooprSpacing.xxs + 2) {
            GeometryReader { proxy in
                let width = proxy.size.width
                let low = Self.fraction(typical.lowerBound, in: domain) * width
                let high = Self.fraction(typical.upperBound, in: domain) * width
                let marker = Self.fraction(value, in: domain) * width
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.loopr(.ink).opacity(isDark ? 0.08 : 0.07))
                        .frame(height: 6)
                    Capsule(style: .continuous)
                        .fill(Color.loopr(accent).opacity(isDark ? 0.38 : 0.30))
                        .frame(width: max(high - low, 6), height: 6)
                        .offset(x: low)
                    Circle()
                        .fill(Color.loopr(accent))
                        .frame(width: 14, height: 14)
                        .overlay { Circle().strokeBorder(Color.loopr(.background), lineWidth: 3) }
                        .shadow(color: Color.loopr(accent).opacity(isDark ? 0.5 : 0.25), radius: 5)
                        .offset(x: min(max(marker - 7, -1), width - 13))
                }
                .frame(height: 14)
                .frame(maxHeight: .infinity)
            }
            .frame(height: 16)

            if lowLabel != nil || highLabel != nil {
                if dynamicTypeSize.isAccessibilitySize {
                    Text([lowLabel, highLabel].compactMap { $0 }.joined(separator: " to "))
                        .looprTypography(.caption)
                        .foregroundStyle(Color.loopr(.inkSecondary))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    GeometryReader { proxy in
                        let width = proxy.size.width
                        let low = Self.fraction(typical.lowerBound, in: domain) * width
                        let high = Self.fraction(typical.upperBound, in: domain) * width
                        // Labels sit under the ends of the usual range, pushed
                        // apart when the range is narrow and kept on the track.
                        let gap: CGFloat = 30
                        let middle = (low + high) / 2
                        let lowX = min(low, middle - gap / 2)
                        let highX = max(high, middle + gap / 2)
                        ZStack {
                            if let lowLabel {
                                label(lowLabel)
                                    .fixedSize()
                                    .position(x: min(max(lowX, 14), width - 14), y: 7)
                            }
                            if let highLabel {
                                label(highLabel)
                                    .fixedSize()
                                    .position(x: min(max(highX, 14), width - 14), y: 7)
                            }
                        }
                    }
                    .frame(height: 14)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .looprTypography(.confidence)
            .foregroundStyle(Color.loopr(.inkSecondary))
    }

    private var isDark: Bool { LooprAppearance.isDark(colorScheme) }
}
