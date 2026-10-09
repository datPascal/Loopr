import SwiftUI
import DomainKit
import DesignSystem

/// Five zone segments from 50% to 100% of the saved maximum. The dot follows
/// the newest rate; below-zone readings rest at the start of the arc.
struct HeartZoneGauge: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let zones: HeartRateZones?
    let bpm: Double?
    var lineWidth: CGFloat = 8

    var body: some View {
        Canvas { context, size in
            let radius = min(size.width * 0.44, size.height * 0.77)
            let centre = CGPoint(x: size.width / 2, y: size.height - radius * 0.17 - lineWidth)
            func point(_ percent: Double) -> CGPoint {
                let angle = (170 + (percent - 50) / 50 * 200) * Double.pi / 180
                return CGPoint(x: centre.x + radius * CGFloat(cos(angle)),
                               y: centre.y + radius * CGFloat(sin(angle)))
            }
            func arc(_ from: Double, _ to: Double) -> Path {
                var path = Path()
                for step in 0...32 {
                    let location = point(from + (to - from) * Double(step) / 32)
                    if step == 0 { path.move(to: location) } else { path.addLine(to: location) }
                }
                return path
            }
            if let zones {
                for number in 1...5 {
                    let token = HeartZone(number: number, percentOfMax: 0).token
                    let start = Double(zones.edges[number - 1]) + 0.35
                    let end = Double(zones.edges[number]) - 0.35
                    context.stroke(arc(start, end), with: .color(Color.loopr(token).opacity(0.75)),
                                   style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                }
            } else {
                context.stroke(arc(50, 100), with: .color(Color.loopr(.heart).opacity(0.20)),
                               style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            }
        }
        .overlay {
            if let currentPercent {
                HeartZoneMarker(percent: min(max(currentPercent, 50), 100), lineWidth: lineWidth)
                    .fill(Color.loopr(.ink))
                    .overlay {
                        HeartZoneMarker(percent: min(max(currentPercent, 50), 100), lineWidth: lineWidth)
                            .stroke(Color.loopr(.background), lineWidth: 2)
                    }
                    .animation(reduceMotion ? nil : .smooth(duration: 0.45), value: currentPercent)
            }
        }
        .accessibilityHidden(true)
    }

    private var currentPercent: Double? {
        guard let zones, let bpm, bpm.isFinite else { return nil }
        return 100 * bpm / zones.maximum
    }
}

private struct HeartZoneMarker: Shape {
    var percent: Double
    let lineWidth: CGFloat

    var animatableData: Double {
        get { percent }
        set { percent = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width * 0.44, rect.height * 0.77)
        let centre = CGPoint(x: rect.midX, y: rect.height - radius * 0.17 - lineWidth)
        let angle = (170 + (percent - 50) / 50 * 200) * Double.pi / 180
        let point = CGPoint(x: centre.x + radius * CGFloat(cos(angle)),
                            y: centre.y + radius * CGFloat(sin(angle)))
        return Path(ellipseIn: CGRect(x: point.x - lineWidth * 0.9, y: point.y - lineWidth * 0.9,
                                      width: lineWidth * 1.8, height: lineWidth * 1.8))
    }
}
