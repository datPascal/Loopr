import DesignSystem
import SwiftUI

/// The day dial's place while its first read runs: the dial's face, rim and inner ring as quiet outlines, with the
/// notes line and the readout row under them, at the dial's own size. Today shows it in the dial's spot, so the page
/// keeps its shape and nothing jumps when the dial lands. No other layout ever stands in for it (ICP R3-PAS-1).
struct TodayDialPlaceholder: View {
    var body: some View {
        VStack(spacing: LooprSpacing.md) {
            // A square that takes its size from the width, as the dial's own ZStack does, with the rings drawn over it.
            // A bare GeometryReader would collapse in the scroll view's open height.
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: TodayDialStack.maximumSide)
                .overlay {
                    GeometryReader { proxy in
                        let scale = proxy.size.width / TodayDialGeometry.viewBox
                        ZStack {
                            ring(TodayDialGeometry.faceRadius, width: 2, scale: scale)
                            ring(TodayDialGeometry.rimRadius, width: 10, scale: scale)
                            ring(TodayDialGeometry.innerRingRadius, width: 6, scale: scale)
                            VStack(spacing: LooprSpacing.xs) {
                                LooprPlaceholderBlock(width: 64, height: 28, radius: 8)
                                LooprPlaceholderBlock(width: 84, height: 10)
                            }
                        }
                        .frame(width: proxy.size.width, height: proxy.size.height)
                    }
                }
                .frame(maxWidth: .infinity)
            LooprPlaceholderBlock(width: 220, height: 12)
            HStack(spacing: LooprSpacing.sm) {
                ForEach(0..<3, id: \.self) { _ in
                    LooprPlaceholderBlock(height: 64, radius: 12)
                }
            }
        }
        .padding(.horizontal, LooprSpacing.screenGutter)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading your day")
        .accessibilityIdentifier("today-dial-placeholder")
    }

    private func ring(_ radius: Double, width: CGFloat, scale: CGFloat) -> some View {
        Circle()
            .stroke(Color.loopr(.ink).opacity(0.07), lineWidth: width * scale)
            .frame(width: radius * 2 * scale, height: radius * 2 * scale)
            .looprShimmer()
    }
}

/// What leads Today: the dial, or its placeholder while the dial loads. There is no third choice, so the recovery ring
/// layout of earlier builds can never show first (ICP R3-PAS-1).
enum TodayLead: Equatable, CaseIterable {
    case dial
    case placeholder

    init(dial: TodayDialContent?) { self = dial == nil ? .placeholder : .dial }
}
