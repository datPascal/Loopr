import SwiftUI

/// A target arc with marked, labelled endpoints on a circular scale.
public struct LooprRingRangeOverlay: View {
    public let range: ClosedRange<Double>
    public let maximum: Double
    public let diameter: CGFloat
    public init(range: ClosedRange<Double>, maximum: Double, diameter: CGFloat) {
        self.range = range; self.maximum = maximum; self.diameter = diameter
    }
    public var body: some View {
        let lower = fraction(range.lowerBound), upper = fraction(range.upperBound)
        ZStack {
            Circle().trim(from: lower, to: upper)
                .stroke(Color.loopr(.ink).opacity(0.5), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            edge(range.lowerBound)
            edge(range.upperBound)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }
    private func fraction(_ value: Double) -> Double { maximum > 0 ? min(max(value / maximum, 0), 1) : 0 }
    private func edge(_ value: Double) -> some View {
        let angle: Double = fraction(value) * 2 * Double.pi - Double.pi / 2
        return ZStack {
            Circle().fill(Color.loopr(.ink)).frame(width: 5, height: 5)
                .offset(x: CGFloat(cos(angle)) * diameter / 2, y: CGFloat(sin(angle)) * diameter / 2)
            Text("\(Int(value.rounded()))")
                .looprTypography(.confidence)
                .foregroundStyle(Color.loopr(.inkSecondary))
                .padding(.horizontal, 2)
                .background(Color.loopr(.surface))
                .offset(x: CGFloat(cos(angle)) * (diameter / 2 + 11), y: CGFloat(sin(angle)) * (diameter / 2 + 11))
        }
    }
}
