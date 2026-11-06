import DesignSystem
import SwiftUI

/// One ring of the Food hero, in the contract's 300 pt design space.
struct FoodRingSpec: Identifiable {
    let id: Int
    let token: LooprColorToken
    /// The fill, 0 to 1. Nil draws the track alone, for a value without a target or with no value.
    let fraction: Double?
    let radius: CGFloat
    let width: CGFloat
    let dots: [FoodRingDot]
    /// The colours the dots wear, by `FoodRingDot.colorIndex`.
    let dotTokens: [LooprColorToken]
}

/// The Food tab's signature object (contract p-food): energy, protein and fibre as three concentric rings with the
/// calorie count in the middle. A small set of dots rests by each ring's end, left there by the camera's finish. On
/// the first visit of the day the rings draw in and the dots settle; after a camera finish the dots settle again.
/// Every other time, and under Reduce Motion, the final state shows at once and stays still.
struct FoodRingsView<Centre: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let rings: [FoodRingSpec]
    /// True while the tab plays its entrance.
    let animates: Bool
    let settleToken: Int
    let centre: Centre
    @State private var drawn = false
    @State private var settled = false

    static var designSize: CGFloat { 300 }
    /// The widest the rings draw. Smaller than the design box, so the log row and the first meal under them clear the
    /// tab bar on the first screen of a phone (UX R2-DES-01, R2-MAC-12).
    static var maxSize: CGFloat { 224 }

    init(rings: [FoodRingSpec], animates: Bool, settleToken: Int, @ViewBuilder centre: () -> Centre) {
        self.rings = rings; self.animates = animates; self.settleToken = settleToken; self.centre = centre()
    }

    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width, proxy.size.height) / Self.designSize
            let middle = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            ZStack {
                ForEach(rings) { ring in
                    ringView(ring, scale: scale, middle: middle)
                }
                centre
                    .frame(width: (rings.last?.radius ?? 80) * 2 * scale * 0.82)
                    .position(middle)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: Self.maxSize)
        .frame(maxWidth: .infinity)
        .onAppear { if !animates { showFinal() } }
        .onChange(of: animates, initial: true) { _, playing in if playing { play(draw: true) } }
        .onChange(of: settleToken) { _, _ in play(draw: false) }
    }

    private var reduces: Bool { LooprMotion.reducesMotion(reduceMotion) }

    private func showFinal() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { drawn = true; settled = true }
    }

    private func play(draw: Bool) {
        guard !reduces else { showFinal(); return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if draw { drawn = false }
            settled = false
        }
        DispatchQueue.main.async {
            if draw { withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 1.5).delay(0.3)) { drawn = true } }
            settled = true
        }
    }

    @ViewBuilder
    private func ringView(_ ring: FoodRingSpec, scale: CGFloat, middle: CGPoint) -> some View {
        let radius = ring.radius * scale, width = ring.width * scale
        let color = Color.loopr(ring.token)
        let fill = min(max(ring.fraction ?? 0, 0), 1)
        let shown = drawn ? fill : 0
        Circle()
            .stroke(Color.loopr(.divider), lineWidth: width)
            .frame(width: radius * 2, height: radius * 2)
            .position(middle)
        if fill > 0 {
            Circle()
                .trim(from: 0, to: shown)
                .stroke(LinearGradient(colors: [color.opacity(0.55), color], startPoint: .topLeading, endPoint: .bottomTrailing),
                        style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: radius * 2, height: radius * 2)
                .shadow(color: color.opacity(0.45), radius: 6 * scale)
                .position(middle)
                .animation(reduces ? nil : .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.9), value: fill)
            Circle()
                .fill(Color.white.opacity(0.92))
                .frame(width: max(width - 8 * scale, 2), height: max(width - 8 * scale, 2))
                .position(point(middle, radius: radius, degrees: fill * 360))
                .opacity(drawn ? 1 : 0)
                .animation(reduces ? nil : .easeOut(duration: 0.3).delay(drawn ? 1.6 + Double(ring.id) * 0.15 : 0), value: drawn)
            ForEach(Array(ring.dots.enumerated()), id: \.offset) { _, dot in
                let token = ring.dotTokens.isEmpty ? ring.token : ring.dotTokens[min(dot.colorIndex, ring.dotTokens.count - 1)]
                Circle()
                    .fill(Color.loopr(token))
                    .frame(width: dot.diameter * scale, height: dot.diameter * scale)
                    .position(point(middle, radius: radius + dot.radialOffset * scale, degrees: dot.angle))
                    .offset(settled ? .zero : CGSize(width: dot.settleFrom.dx * scale, height: dot.settleFrom.dy * scale))
                    .opacity(settled ? 0.75 : 0)
                    .animation(reduces ? nil : .timingCurve(0.2, 0.9, 0.2, 1, duration: 1.2).delay(settled ? dot.delay + Double(ring.id) * 0.1 : 0),
                               value: settled)
            }
        }
    }

    /// A point on a circle, `degrees` clockwise from twelve o'clock.
    private func point(_ centre: CGPoint, radius: CGFloat, degrees: Double) -> CGPoint {
        let radians = degrees * .pi / 180
        return CGPoint(x: centre.x + radius * CGFloat(sin(radians)), y: centre.y - radius * CGFloat(cos(radians)))
    }
}
