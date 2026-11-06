import DesignSystem
import SwiftUI

/// The dial face and every layer, drawn in the contract's 340-point view box and scaled to the frame.
///
/// `elapsed` is seconds into the entrance. It is the view's animatable value, so the entrance animates by moving it from
/// 0 to `TodayDialDrawing.entranceDuration` once; every later frame, and every visit after the first of the day, draws
/// the final state. The hand moves only when the model is rebuilt, once a minute.
struct TodayDialCanvas: View, Animatable {
    let drawing: TodayDialDrawing
    let stickerImages: [UUID: Image]
    var elapsed: Double
    /// The minute a finger is on, drawn as a faint line from the centre.
    let scrubMinute: Int?
    /// Strokes by id, and stickers as "sticker-<meal id>", that an open focus card has carried off the dial.
    var hidden: Set<String> = []

    nonisolated var animatableData: Double {
        get { elapsed }
        set { elapsed = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            context.translateBy(x: (size.width - side) / 2, y: (size.height - side) / 2)
            context.scaleBy(x: side / TodayDialGeometry.viewBox, y: side / TodayDialGeometry.viewBox)
            drawFace(&context)
            for stroke in drawing.strokes where !hidden.contains(stroke.id) { draw(stroke, in: &context) }
            for mark in drawing.marks { draw(mark, in: &context) }
            if let angle = drawing.tonightLabelAngle { drawTonightLabel(angle, in: &context) }
            for sticker in drawing.stickers where !hidden.contains("sticker-\(sticker.id)") { draw(sticker, in: &context) }
            if let scrubMinute { drawScrub(scrubMinute, in: &context) }
            if let angle = drawing.handAngle { drawHand(angle, in: &context) }
        } symbols: {
            ForEach(drawing.stickers) { sticker in
                TodayDialStickerSymbol(sticker: sticker, image: sticker.sticker.flatMap { stickerImages[$0.photoID] })
                    .tag(sticker.id)
            }
        }
    }

    // MARK: Face

    private func drawFace(_ context: inout GraphicsContext) {
        let c = TodayDialGeometry.centre
        let face = Path(ellipseIn: CGRect(x: c - TodayDialGeometry.faceRadius, y: c - TodayDialGeometry.faceRadius,
                                          width: TodayDialGeometry.faceRadius * 2, height: TodayDialGeometry.faceRadius * 2))
        let ink = Color.loopr(.ink)
        context.fill(face, with: .radialGradient(Gradient(colors: [ink.opacity(0.07), ink.opacity(0)]),
                                                 center: CGPoint(x: c, y: TodayDialGeometry.viewBox * 0.38),
                                                 startRadius: 0, endRadius: TodayDialGeometry.viewBox * 0.62))
        let divider = GraphicsContext.Shading.color(Color.loopr(.divider))
        context.stroke(face, with: divider, lineWidth: 1)
        let inner = TodayDialGeometry.innerRingRadius
        context.stroke(Path(ellipseIn: CGRect(x: c - inner, y: c - inner, width: inner * 2, height: inner * 2)), with: divider, lineWidth: 1)

        for index in 0..<96 {
            let major = index % 4 == 0, six = index % 24 == 0
            let angle = Double(index) * 3.75 + 180
            let from = TodayDialGeometry.point(radius: six ? TodayDialGeometry.sixHourTickInnerRadius
                                                : major ? TodayDialGeometry.hourTickInnerRadius : TodayDialGeometry.quarterTickInnerRadius,
                                               angle: angle)
            let to = TodayDialGeometry.point(radius: TodayDialGeometry.tickOuterRadius, angle: angle)
            var tick = Path()
            tick.move(to: CGPoint(x: from.x, y: from.y))
            tick.addLine(to: CGPoint(x: to.x, y: to.y))
            context.stroke(tick, with: .color(Color.loopr(six ? .inkSecondary : .inkMuted)),
                           style: StrokeStyle(lineWidth: six ? 1.8 : major ? 1.2 : 0.8, lineCap: .round))
        }
        // Each label sits on the box's edge, anchored on its inner side, so the canvas never cuts it ("06" read ")6" when
        // it was centred two points from the edge, R1-OPT-19). It still clears the ticks, which end 12 points in.
        let edge = TodayDialGeometry.viewBox
        for (hour, label, at, anchor) in [(0, "00", CGPoint(x: edge / 2, y: edge), UnitPoint.bottom),
                                          (6, "06", CGPoint(x: 0, y: edge / 2), UnitPoint.leading),
                                          (12, "12", CGPoint(x: edge / 2, y: 0), UnitPoint.top),
                                          (18, "18", CGPoint(x: edge, y: edge / 2), UnitPoint.trailing)] {
            _ = hour
            context.draw(Text(label).font(.custom("SpaceGrotesk-Medium", fixedSize: 10)).foregroundStyle(Color.loopr(.inkMuted)),
                         at: at, anchor: anchor)
        }
    }

    // MARK: Layers

    private func arcPath(radius: Double, start: Double, sweep: Double) -> Path {
        var path = Path()
        let c = TodayDialGeometry.centre
        path.addArc(center: CGPoint(x: c, y: c), radius: radius, startAngle: .degrees(start - 90),
                    endAngle: .degrees(start - 90 + max(sweep, 0.01)), clockwise: false)
        return path
    }

    private func draw(_ stroke: TodayDialStroke, in context: inout GraphicsContext) {
        let progress = TodayDialDrawing.progress(elapsed: elapsed, start: stroke.revealStart, duration: TodayDialDrawing.strokeDrawDuration)
        guard progress > 0 else { return }
        let path = arcPath(radius: stroke.radius, start: stroke.startAngle, sweep: stroke.sweep).trimmedPath(from: 0, to: progress)
        let style = StrokeStyle(lineWidth: stroke.width, lineCap: stroke.roundCaps ? .round : .butt, dash: stroke.dash.map { CGFloat($0) })
        let color = Color.loopr(stroke.tint).opacity(stroke.opacity)
        if stroke.glows { glow(path, color: color, style: style, in: &context) }
        context.stroke(path, with: .color(color), style: style)
    }

    private func glow(_ path: Path, color: Color, style: StrokeStyle, in context: inout GraphicsContext) {
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 3))
            layer.opacity = 0.7
            layer.stroke(path, with: .color(color), style: style)
        }
    }

    private func draw(_ mark: TodayDialMark, in context: inout GraphicsContext) {
        let progress = TodayDialDrawing.progress(elapsed: elapsed, start: mark.revealStart, duration: TodayDialDrawing.markFadeDuration)
        guard progress > 0 else { return }
        let point = TodayDialGeometry.point(radius: mark.radius, angle: mark.angle)
        let centre = CGPoint(x: point.x, y: point.y)
        let r = mark.size
        let color = Color.loopr(mark.tint).opacity(mark.opacity * progress)
        let circle = Path(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2))
        switch mark.shape {
        case .dot:
            if mark.glows {
                context.drawLayer { layer in
                    layer.addFilter(.blur(radius: 2.5))
                    layer.fill(circle, with: .color(color))
                }
            }
            context.fill(circle, with: .color(color))
        case .hollow(let lineWidth):
            context.fill(circle, with: .color(Color.loopr(.background).opacity(progress)))
            context.stroke(circle, with: .color(color), lineWidth: lineWidth)
        case .dashedHollow(let lineWidth):
            context.fill(circle, with: .color(Color.loopr(.background).opacity(progress)))
            context.stroke(circle, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, dash: [1.5, 1.5]))
        case .gem:
            var gem = Path()
            gem.move(to: CGPoint(x: centre.x, y: centre.y - r * 1.414))
            gem.addLine(to: CGPoint(x: centre.x + r * 1.414, y: centre.y))
            gem.addLine(to: CGPoint(x: centre.x, y: centre.y + r * 1.414))
            gem.addLine(to: CGPoint(x: centre.x - r * 1.414, y: centre.y))
            gem.closeSubpath()
            if mark.glows {
                context.drawLayer { layer in
                    layer.addFilter(.blur(radius: 3))
                    layer.fill(gem, with: .color(color))
                }
            }
            context.fill(gem, with: .color(color))
        }
    }

    private func drawTonightLabel(_ angle: Double, in context: inout GraphicsContext) {
        let progress = TodayDialDrawing.progress(elapsed: elapsed, start: 1.1, duration: TodayDialDrawing.markFadeDuration)
        guard progress > 0 else { return }
        let point = TodayDialGeometry.point(radius: TodayDialGeometry.eatingRadius, angle: angle)
        var layer = context
        layer.opacity = progress
        layer.draw(Text("tonight").font(.custom("SpaceGrotesk-Medium", fixedSize: 10.5)).foregroundStyle(Color.loopr(.sleep)),
                   at: CGPoint(x: point.x, y: point.y), anchor: .center)
    }

    private func draw(_ sticker: TodayDialStickerMark, in context: inout GraphicsContext) {
        let progress = TodayDialDrawing.progress(elapsed: elapsed, start: sticker.revealStart, duration: TodayDialDrawing.stickerPopDuration)
        guard progress > 0, let symbol = context.resolveSymbol(id: sticker.id) else { return }
        let point = TodayDialGeometry.point(radius: sticker.radius, angle: sticker.angle)
        // A pop with a small overshoot, as the contract's stickers land.
        let scale = progress < 1 ? 0.4 + 0.75 * sin(progress * .pi * 0.62) : 1
        var layer = context
        layer.translateBy(x: point.x, y: point.y)
        layer.scaleBy(x: scale, y: scale)
        layer.drawLayer { shadow in
            shadow.addFilter(.shadow(color: .black.opacity(0.45), radius: 2.5, x: 0, y: 3))
            shadow.draw(symbol, at: .zero, anchor: .center)
        }
    }

    private func drawScrub(_ minute: Int, in context: inout GraphicsContext) {
        let angle = TodayDialGeometry.angle(minuteOfDay: Double(minute))
        let from = TodayDialGeometry.point(radius: TodayDialGeometry.innerRingRadius, angle: angle)
        let to = TodayDialGeometry.point(radius: TodayDialGeometry.tickOuterRadius, angle: angle)
        var line = Path()
        line.move(to: CGPoint(x: from.x, y: from.y))
        line.addLine(to: CGPoint(x: to.x, y: to.y))
        context.stroke(line, with: .color(Color.loopr(.ink).opacity(0.35)), style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [2, 3]))
    }

    private func drawHand(_ angle: Double, in context: inout GraphicsContext) {
        let progress = TodayDialDrawing.progress(elapsed: elapsed, start: 0.2, duration: 1.6)
        // The hand swings in from 70 degrees back, then rests.
        let eased = 1 - pow(1 - progress, 3)
        let shown = angle - 70 * (1 - eased)
        let from = TodayDialGeometry.point(radius: TodayDialGeometry.handInnerRadius, angle: shown)
        let to = TodayDialGeometry.point(radius: TodayDialGeometry.handOuterRadius, angle: shown)
        var line = Path()
        line.move(to: CGPoint(x: from.x, y: from.y))
        line.addLine(to: CGPoint(x: to.x, y: to.y))
        let brand = Color.loopr(.brand)
        let style = StrokeStyle(lineWidth: 1.6, lineCap: .round)
        glow(line, color: brand, style: style, in: &context)
        context.stroke(line, with: .color(brand), style: style)
        let tip = TodayDialGeometry.handTipRadius
        let tipPath = Path(ellipseIn: CGRect(x: to.x - tip, y: to.y - tip, width: tip * 2, height: tip * 2))
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 3))
            layer.fill(tipPath, with: .color(brand))
        }
        context.fill(tipPath, with: .color(brand))
        context.fill(Path(ellipseIn: CGRect(x: to.x - 2, y: to.y - 2, width: 4, height: 4)), with: .color(.white))
    }
}

/// One sticker as a Canvas symbol, in view-box points: the meal's photo clipped to a circle inside a white rim, or a
/// drawn sticker when the meal has no photo. "+N" counts meals of the same cluster without a sticker of their own.
struct TodayDialStickerSymbol: View {
    let sticker: TodayDialStickerMark
    let image: Image?

    var body: some View {
        let outer = TodayDialGeometry.stickerRadius * 2, inner = TodayDialGeometry.stickerImageRadius * 2
        ZStack(alignment: .topTrailing) {
            if let image {
                ZStack {
                    Circle().fill(Color.white)
                    image.resizable().scaledToFill().frame(width: inner, height: inner).clipShape(Circle())
                }
                .frame(width: outer, height: outer)
            } else {
                LooprDrawnSticker(meal: sticker.title, diameter: outer)
            }
            if sticker.overflow > 0 {
                Text("+\(sticker.overflow)")
                    .font(.custom("SpaceGrotesk-Medium", fixedSize: 8))
                    .foregroundStyle(Color.loopr(.background))
                    .padding(.horizontal, 3)
                    .background(Capsule().fill(Color.loopr(.ink)))
                    .offset(x: 4, y: -2)
            }
        }
        .frame(width: outer + 8, height: outer + 4)
    }
}
