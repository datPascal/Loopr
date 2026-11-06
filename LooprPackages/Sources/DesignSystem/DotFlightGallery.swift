#if canImport(UIKit)
import SwiftUI
import UIKit

/// The gallery's dot flight: a button sends dots into a ring and the hero number beside it counts up
/// as they land.
struct LooprDotFlightGalleryDemo: View {
    nonisolated static let sourceID = "gallery-dot-source"
    nonisolated static let targetID = "gallery-dot-ring"
    nonisolated static let dotCount = 48
    nonisolated static let added = 420.0
    nonisolated static let start = 1_240.0

    @State private var value = LooprDotFlightGalleryDemo.start
    @State private var count = LooprCountUp(from: LooprDotFlightGalleryDemo.start, to: LooprDotFlightGalleryDemo.start, total: 0)

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.md) {
            HStack(spacing: LooprSpacing.lg) {
                ZStack {
                    Circle()
                        .stroke(Color.loopr(.energy).opacity(0.16), lineWidth: 8)
                    Circle()
                        .trim(from: 0, to: Self.ringFill(value: count.value))
                        .stroke(Color.loopr(.energy), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 96, height: 96)
                .looprDotFlightTarget(Self.targetID)
                .accessibilityHidden(true)
                LooprHeroNumber(value, unit: "kcal", spokenUnit: "kilocalories", style: .heroNumeralLarge, countUp: count)
            }
            LooprDotFlightGalleryButton { flight in
                let next = value + Self.added
                count = LooprCountUp(from: value, to: next, total: Self.dotCount)
                value = next
                let flew = flight?.fly(from: Self.sourceID, to: Self.targetID, shape: .ring(inset: 4), colors: Self.colors,
                                       onLanding: { rank, _ in count.landed = rank + 1 })
                if flew != true { count.landed = count.total }
            }
            .looprDotFlightSource(Self.sourceID)
        }
        .looprDotFlightHost()
        .accessibilityIdentifier("gallery-dot-flight")
    }

    /// The ring fills against a 2,000 kcal day.
    static func ringFill(value: Double) -> CGFloat {
        CGFloat(min(max(value / 2_000, 0), 1))
    }

    static var colors: [UIColor] {
        let tokens: [LooprColorToken] = [.energy, .heart, .brand, .sleep]
        return (0..<dotCount).map { UIColor(Color.loopr(tokens[$0 % tokens.count])) }
    }
}

/// Reads the flight from the environment the demo's host installed.
private struct LooprDotFlightGalleryButton: View {
    @Environment(\.looprDotFlight) private var flight
    let action: (LooprDotFlightCoordinator?) -> Void

    var body: some View {
        LooprGlassButton("Log a meal", symbol: "fork.knife", identifier: "gallery-dot-flight-play") {
            action(flight)
        }
    }
}
#endif
