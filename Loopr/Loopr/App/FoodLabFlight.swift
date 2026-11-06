import DesignSystem
import UIKit

/// The chip flight in Lab mode: as the light passes a row of the report, a few dots break off it and fly to that
/// value's chip through `LooprDotFlight`. The flight view ticks one light haptic per landing, capped by
/// `LooprHapticLimiter` at 30 a second, and plays a success at the end.
nonisolated enum FoodLabFlight {
    static let dotsPerValue = 5

    /// Seconds the light takes to pass the whole page once.
    static func sweepDuration(values: Int) -> Double { min(max(1.2, Double(values) * 0.08), 2.6) }

    /// Plans the flight.
    /// - Parameters:
    ///   - rows: each value's row from the top of the page, 0 to 1; a value without one is spread down the page in order.
    ///   - page: the report on screen, in the flight's coordinates.
    ///   - chips: each value's chip on screen. A value without a chip on screen gets no dots.
    /// - Returns: the request, and for each landing in it the index of the value it belongs to. Nil when nothing flies.
    static func plan(rows: [Double?], review: [Bool], page: CGRect, chips: [Int: CGRect], sweep: Double,
                     read: UIColor, uncertain: UIColor) -> (request: LooprDotFlightRequest, owners: [Int])? {
        var landings: [LooprDotLanding] = []
        var owners: [Int] = []
        let count = rows.count
        for index in rows.indices {
            guard let chip = chips[index], page.width > 0, page.height > 0 else { continue }
            let y = min(max(rows[index] ?? (Double(index) + 0.5) / Double(max(count, 1)), 0), 1)
            let color = review.indices.contains(index) && review[index] ? uncertain : read
            for dot in 0..<dotsPerValue {
                let spread = Double(dot) / Double(dotsPerValue)
                let start = CGPoint(x: page.minX + page.width * (0.3 + 0.55 * spread), y: page.minY + page.height * y)
                let scheduled = LooprScheduledDot(start: start, color: color, spawn: 0.12 + y * sweep + Double(dot) * 0.025,
                                                  linger: 0.1 + 0.03 * Double(dot), flight: 0.5 + 0.04 * Double(dot))
                let target = CGPoint(x: chip.minX + chip.width * (0.2 + 0.6 * spread), y: chip.midY)
                landings.append(LooprDotLanding(dot: scheduled, target: target, color: color))
                owners.append(index)
            }
        }
        guard !landings.isEmpty else { return nil }
        return (LooprDotFlightRequest(landings: landings, away: CGPoint(x: page.midX, y: page.midY)), owners)
    }
}
