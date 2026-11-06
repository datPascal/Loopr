import DesignSystem
import FoodKit
import SwiftUI
import UIKit

/// Calories and the three macros, summed over some food.
nonisolated struct FoodBurstNumbers: Equatable, Sendable {
    var energy = 0.0, protein = 0.0, carbs = 0.0, fat = 0.0
    init(energy: Double = 0, protein: Double = 0, carbs: Double = 0, fat: Double = 0) {
        self.energy = energy; self.protein = protein; self.carbs = carbs; self.fat = fat
    }
    init(items: [FoodItem]) {
        func total(_ nutrient: FoodNutrient) -> Double { FoodNutrientTotal(nutrient, items: items).knownValue ?? 0 }
        self.init(energy: total(.energy), protein: total(.protein), carbs: total(.carbs), fat: total(.fat))
    }
    static func + (lhs: Self, rhs: Self) -> Self {
        .init(energy: lhs.energy + rhs.energy, protein: lhs.protein + rhs.protein, carbs: lhs.carbs + rhs.carbs, fat: lhs.fat + rhs.fat)
    }
}

/// The day a meal lands in: what was eaten before it and the targets, where the person set them.
nonisolated struct FoodBurstDay: Equatable, Sendable {
    var eaten = FoodBurstNumbers()
    var energyTarget: Double?, proteinTarget: Double?, carbsTarget: Double?, fatTarget: Double?

    init(eaten: FoodBurstNumbers = .init(), energyTarget: Double? = nil, proteinTarget: Double? = nil,
         carbsTarget: Double? = nil, fatTarget: Double? = nil) {
        self.eaten = eaten; self.energyTarget = energyTarget; self.proteinTarget = proteinTarget
        self.carbsTarget = carbsTarget; self.fatTarget = fatTarget
    }

    init(_ day: FoodDaySummary?) {
        guard let day else { self.init(); return }
        func total(_ nutrient: FoodNutrient) -> Double { day.total(nutrient).knownValue ?? 0 }
        self.init(eaten: .init(energy: total(.energy), protein: total(.protein), carbs: total(.carbs), fat: total(.fat)),
                  energyTarget: day.target.energy, proteinTarget: day.settings?.protein,
                  carbsTarget: day.settings?.carbs, fatTarget: day.settings?.fat)
    }
}

/// One run of the burst: the picture to dissolve, where it sits on screen, and what it adds.
struct FoodBurstRequest: Equatable {
    let id = UUID()
    let subject: UIImage
    /// The picture's frame in the burst view's coordinates, which fill the screen.
    let frame: CGRect
    let day: FoodBurstDay
    let added: FoodBurstNumbers
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

/// Hosts `FoodMacroBurstView`. It plays each new request once.
struct FoodMacroBurst: UIViewRepresentable {
    let request: FoodBurstRequest?
    let reduceMotion: Bool
    let finished: @MainActor () -> Void

    func makeUIView(context: Context) -> FoodMacroBurstView { FoodMacroBurstView() }
    func updateUIView(_ view: FoodMacroBurstView, context: Context) {
        guard let request, view.played != request.id else { return }
        view.play(request, reduceMotion: reduceMotion, completion: finished)
    }
}

/// The finish of a log. The picture breaks into dots coloured by the meal's macros (protein red, carbs
/// teal, fat violet, in proportion to the calories each brings). The dots fly into the day's calorie
/// ring, laying down one coloured stretch per macro, and into each macro's own ring, whose number
/// counts up as they land. The dots fly through the shared `LooprDotFlightView`, which keeps them on
/// the render server, ticks a soft haptic as they land and plays the success at the end.
final class FoodMacroBurstView: UIView {
    private(set) var played: UUID?
    private let stage = CALayer()
    /// The dots, between the rings and the picture, as when the burst drew them itself.
    private let dots = LooprDotFlightView()
    private let picture = UIImageView()
    private var counters: [Counter] = []
    private var completion: (@MainActor () -> Void)?

    /// The media clock. A test replaces it and runs the burst frame by frame with `advance(to:)`.
    var clock: () -> CFTimeInterval = CACurrentMediaTime {
        didSet { dots.clock = clock }
    }

    /// Runs `work` after `delay` seconds: the holds before the burst finishes. A test replaces it and
    /// runs the holds itself.
    var after: (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { work() }
    }

    /// Moves the flight to media time `now`, as the display link does on every frame.
    func advance(to now: CFTimeInterval) {
        dots.advance(to: now)
    }

    /// The burst's timing (DEC-11.7). The success plays 0.12 s after the last landing measured from
    /// the call, and the flight's clock starts 0.04 s after it, so the flight settles for 0.08 s.
    static var timing: LooprDotFlightTiming {
        var timing = LooprDotFlightTiming.standard
        timing.settle = 0.08
        return timing
    }

    /// Soft ticks under the finger while the dots land, like grains filling a cup: one every 75 ms at
    /// most, and the success at the end.
    static let haptics = LooprDotFlightHaptics(style: .soft, intensity: 0.45, maximumPerSecond: 30, minimumInterval: 0.075)

    private enum Macro: Int, CaseIterable {
        case protein, carbs, fat
        var token: LooprColorToken { [LooprColorToken.heart, .brand, .sleep][rawValue] }
        var title: String { ["Protein", "Carbs", "Fat"][rawValue] }
        /// Calories per gram, used only to share the calorie ring between the three.
        var energy: Double { [4.0, 4, 9][rawValue] }
    }

    /// A label that counts from one number to another while its dots land.
    private struct Counter {
        let label: UILabel
        let from: Double, to: Double
        let start: CFTimeInterval, end: CFTimeInterval
        let format: (Double) -> String
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        overrideUserInterfaceStyle = .dark
        backgroundColor = .clear
        layer.addSublayer(stage)
        dots.frame = bounds
        dots.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(dots)
        picture.contentMode = .scaleAspectFit
        addSubview(picture)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func color(_ token: LooprColorToken) -> UIColor {
        UIColor(token.color).resolvedColor(with: traitCollection)
    }

    private func font(_ name: String, _ size: CGFloat) -> UIFont {
        UIFontMetrics.default.scaledFont(for: UIFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: .medium), maximumPointSize: size * 1.4)
    }

    func play(_ request: FoodBurstRequest, reduceMotion: Bool, completion: @escaping @MainActor () -> Void) {
        guard bounds.width > 0 else {
            DispatchQueue.main.async { [weak self] in self?.play(request, reduceMotion: reduceMotion, completion: completion) }
            return
        }
        played = request.id
        self.completion = completion
        stage.sublayers?.forEach { $0.removeFromSuperlayer() }
        subviews.filter { $0 !== picture && $0 !== dots }.forEach { $0.removeFromSuperview() }
        counters = []
        CATransaction.begin(); CATransaction.setDisableActions(true)
        picture.image = request.subject; picture.frame = request.frame; picture.alpha = 1; picture.layer.mask = nil
        CATransaction.commit()

        let now = clock() + 0.04
        let after = request.day.eaten + request.added
        let layout = ringLayout()
        let energyScale = request.day.energyTarget.flatMap { $0 > 0 ? $0 : nil } ?? max(after.energy * 1.25, 1)
        let energyFrom = min(request.day.eaten.energy / energyScale, 1), energyTo = min(after.energy / energyScale, 1)

        // The calorie ring and its three new stretches, in protein, carbs, fat order.
        let shares = Macro.allCases.map { macro -> Double in
            let grams = [request.added.protein, request.added.carbs, request.added.fat][macro.rawValue]
            return max(grams, 0) * macro.energy
        }
        let shareTotal = shares.reduce(0, +)
        var segments: [(macro: Macro?, from: Double, to: Double)] = []
        if shareTotal > 0 {
            var start = energyFrom
            for macro in Macro.allCases {
                let span = (energyTo - energyFrom) * shares[macro.rawValue] / shareTotal
                segments.append((macro, start, start + span)); start += span
            }
        } else { segments.append((nil, energyFrom, energyTo)) }
        let energyRing = ring(center: layout.energy, diameter: layout.energyDiameter, line: 15, token: .energy, base: energyFrom)
        let energyArcs = segments.map { segment in
            arc(center: layout.energy, diameter: layout.energyDiameter, line: 15, color: color(segment.macro?.token ?? .energy),
                from: segment.from, to: segment.to)
        }
        let energyValue = label(font("SpaceGrotesk-Medium", 46), color: color(.ink))
        let energyCaption = label(font("SpaceGrotesk-Regular", 14), color: color(.inkSecondary))
        energyCaption.text = request.day.energyTarget.map { "of \(Self.number($0)) kcal" } ?? "kcal today"
        let delta = label(font("SpaceGrotesk-Medium", 15), color: color(.energy))
        delta.text = "+\(Self.number(request.added.energy))"
        place(energyValue, center: CGPoint(x: layout.energy.x, y: layout.energy.y - 6), width: layout.energyDiameter * 0.7)
        place(energyCaption, center: CGPoint(x: layout.energy.x, y: layout.energy.y + 28), width: layout.energyDiameter * 0.7)
        place(delta, center: CGPoint(x: layout.energy.x, y: layout.energy.y - 46), width: layout.energyDiameter * 0.6)
        energyValue.text = Self.number(request.day.eaten.energy)

        // One ring per macro.
        var macroArcs: [Macro: (layer: CAShapeLayer, from: Double, to: Double)] = [:]
        var macroValues: [Macro: UILabel] = [:]
        var rings = [energyRing]
        for macro in Macro.allCases {
            let before = [request.day.eaten.protein, request.day.eaten.carbs, request.day.eaten.fat][macro.rawValue]
            let total = [after.protein, after.carbs, after.fat][macro.rawValue]
            let target = [request.day.proteinTarget, request.day.carbsTarget, request.day.fatTarget][macro.rawValue]
            let scale = target.flatMap { $0 > 0 ? $0 : nil } ?? max(total * 1.25, 1)
            let center = layout.macros[macro.rawValue]
            let from = min(before / scale, 1), to = min(total / scale, 1)
            rings.append(ring(center: center, diameter: layout.macroDiameter, line: 7, token: macro.token, base: from))
            macroArcs[macro] = (arc(center: center, diameter: layout.macroDiameter, line: 7, color: color(macro.token), from: from, to: to), from, to)
            let value = label(font("SpaceGrotesk-Medium", 17), color: color(.ink))
            value.text = "\(Self.number(before)) g"
            let name = label(font("SpaceGrotesk-Regular", 13), color: color(.inkSecondary))
            name.text = target.map { "\(macro.title) of \(Self.number($0)) g" } ?? macro.title
            place(value, center: CGPoint(x: center.x, y: center.y + layout.macroDiameter / 2 + 20), width: bounds.width / 3 - 8)
            place(name, center: CGPoint(x: center.x, y: center.y + layout.macroDiameter / 2 + 41), width: bounds.width / 3 - 8)
            macroValues[macro] = value
        }

        // The rings rise in while the picture starts to break up.
        let labels = subviews.filter { $0 !== picture && $0 !== dots }
        for layer in rings + energyArcs + macroArcs.values.map(\.layer) { appear(layer, at: now) }
        labels.forEach { $0.alpha = 0 }
        UIView.animate(withDuration: 0.35, delay: 0.05, options: [.curveEaseOut]) { labels.forEach { $0.alpha = 1 } }

        let middle = CGPoint(x: request.frame.midX, y: request.frame.midY)
        if reduceMotion {
            // No flight: the picture fades and the rings show the new day.
            UIView.animate(withDuration: 0.3) { self.picture.alpha = 0 }
            for (index, segment) in segments.enumerated() { energyArcs[index].strokeEnd = segment.to }
            for (macro, entry) in macroArcs { entry.layer.strokeEnd = entry.to; macroValues[macro]?.text = "\(Self.number([after.protein, after.carbs, after.fat][macro.rawValue])) g" }
            energyValue.text = Self.number(after.energy)
            // The flight plays the success at once and lands nothing.
            dots.play(LooprDotFlightRequest(landings: [], away: middle, timing: Self.timing, haptics: Self.haptics),
                      reduceMotion: true, completion: { [weak self] in
                guard let self else { return }
                self.after(1.4) { [weak self] in self?.finish() }
            })
            return
        }

        // Dots: sampled from the picture's opaque pixels, wearing those pixels' colours.
        let starts = LooprDotFlight.samples(request.subject, count: Int(min(max(request.frame.width * request.frame.height / 85, 170), 340)))
        var random = SystemRandomNumberGenerator()
        var flights = LooprDotFlight.schedule(starts, in: request.frame, timing: Self.timing, using: &random)
        flights.shuffle(using: &random)
        // A little over half the dots paint the calorie ring; the rest fill the macro rings.
        let split = Int(Double(flights.count) * 0.56)
        var toEnergy = Array(flights[..<split]).sorted { $0.arrival < $1.arrival }
        var toMacros = Array(flights[split...])
        if shareTotal == 0 { toEnergy += toMacros; toMacros = []; toEnergy.sort { $0.arrival < $1.arrival } }

        var landings: [LooprDotLanding] = []
        // Calorie dots land in arrival order along the ring, so the stretches grow end to end.
        var cursor = 0
        for (index, segment) in segments.enumerated() {
            let share = shareTotal > 0 ? shares[index] / shareTotal : 1
            let count = index == segments.count - 1 ? toEnergy.count - cursor : Int((Double(toEnergy.count) * share).rounded())
            let group = Array(toEnergy[cursor..<min(cursor + max(count, 0), toEnergy.count)])
            cursor += group.count
            guard let first = group.first?.arrival, let last = group.last?.arrival else { continue }
            let target = LooprDotTarget.ring(center: layout.energy, radius: layout.energyDiameter / 2 - 7.5,
                                             from: segment.from, to: segment.to, jitter: 3)
            landings += LooprDotFlight.land(group, on: target, color: color(segment.macro?.token ?? .energy), using: &random)
            grow(energyArcs[index], from: segment.from, to: segment.to, start: now + first, end: now + last)
        }
        counters.append(.init(label: energyValue, from: request.day.eaten.energy, to: after.energy,
                              start: now + (toEnergy.first?.arrival ?? 0.8), end: now + (toEnergy.last?.arrival ?? 1.4), format: Self.number))
        // Macro dots split by each macro's share of the calories.
        var offset = 0
        for macro in Macro.allCases {
            guard let entry = macroArcs[macro] else { continue }
            let share = shareTotal > 0 ? shares[macro.rawValue] / shareTotal : 0
            let count = macro == .fat ? toMacros.count - offset : Int((Double(toMacros.count) * share).rounded())
            let group = Array(toMacros[offset..<min(offset + max(count, 0), toMacros.count)]).sorted { $0.arrival < $1.arrival }
            offset += group.count
            let before = [request.day.eaten.protein, request.day.eaten.carbs, request.day.eaten.fat][macro.rawValue]
            let total = [after.protein, after.carbs, after.fat][macro.rawValue]
            guard let first = group.first?.arrival, let last = group.last?.arrival else {
                entry.layer.strokeEnd = entry.to; macroValues[macro]?.text = "\(Self.number(total)) g"; continue
            }
            let target = LooprDotTarget.ring(center: layout.macros[macro.rawValue], radius: layout.macroDiameter / 2 - 3.5,
                                             from: entry.from, to: entry.to, jitter: 1.5)
            landings += LooprDotFlight.land(group, on: target, color: color(macro.token), using: &random)
            grow(entry.layer, from: entry.from, to: entry.to, start: now + first, end: now + last)
            if let value = macroValues[macro] {
                counters.append(.init(label: value, from: before, to: total, start: now + first, end: now + last) { "\(Self.number($0)) g" })
            }
        }

        // The picture wipes away behind the dots, top first, as they break off.
        let mask = CAGradientLayer()
        mask.frame = picture.bounds
        mask.startPoint = CGPoint(x: 0.35, y: 0); mask.endPoint = CGPoint(x: 0.65, y: 1)
        mask.colors = [UIColor.clear.cgColor, UIColor.black.cgColor]
        mask.locations = [1.05, 1.15]
        picture.layer.mask = mask
        let wipe = CABasicAnimation(keyPath: "locations")
        wipe.fromValue = [-0.15, -0.02]; wipe.toValue = [1.05, 1.15]
        wipe.beginTime = now + 0.16; wipe.duration = 0.5; wipe.fillMode = .backwards
        wipe.timingFunction = CAMediaTimingFunction(name: .easeIn)
        mask.add(wipe, forKey: "wipe")

        var timing = Self.timing
        // With no dots the success still waits as long as a short burst would.
        if landings.isEmpty { timing.settle = 1.2 + timing.settle }
        let flight = LooprDotFlightRequest(landings: landings, away: middle, timing: timing, haptics: Self.haptics)
        let pulsing = rings + energyArcs + macroArcs.values.map(\.layer)
        dots.play(flight, startingAt: now, reduceMotion: false, onFrame: { [weak self] time in
            self?.updateCounters(at: time)
        }, completion: { [weak self] in
            guard let self else { return }
            self.updateCounters(at: .greatestFiniteMagnitude)
            for layer in pulsing { self.pulse(layer) }
            self.after(0.9) { [weak self] in self?.finish() }
        })
    }

    private func finish() {
        let completion = completion
        self.completion = nil
        completion?()
    }

    // MARK: Layout

    private func ringLayout() -> (energy: CGPoint, energyDiameter: CGFloat, macros: [CGPoint], macroDiameter: CGFloat) {
        let bottom = bounds.height - safeAreaInsets.bottom
        let macroDiameter: CGFloat = 66
        let energyDiameter = min(bounds.width * 0.56, 232)
        // Macro rings sit above the home indicator with their two labels under them.
        let macroY = bottom - 64 - macroDiameter / 2
        let energyY = min(bounds.height * 0.57, macroY - macroDiameter / 2 - 44 - energyDiameter / 2)
        let width = bounds.width
        return (CGPoint(x: width / 2, y: energyY), energyDiameter,
                [CGPoint(x: width / 6, y: macroY), CGPoint(x: width / 2, y: macroY), CGPoint(x: width * 5 / 6, y: macroY)], macroDiameter)
    }

    private func circle(center: CGPoint, diameter: CGFloat, line: CGFloat) -> CGPath {
        UIBezierPath(arcCenter: center, radius: diameter / 2 - line / 2, startAngle: -.pi / 2, endAngle: .pi * 1.5, clockwise: true).cgPath
    }

    /// A quiet track plus the day so far, drawn in the ring's colour at reduced strength.
    private func ring(center: CGPoint, diameter: CGFloat, line: CGFloat, token: LooprColorToken, base: Double) -> CALayer {
        let group = CALayer()
        let track = CAShapeLayer()
        track.path = circle(center: center, diameter: diameter, line: line)
        track.fillColor = nil; track.lineWidth = line
        track.strokeColor = color(token).withAlphaComponent(0.16).cgColor
        let eaten = CAShapeLayer()
        eaten.path = track.path; eaten.fillColor = nil; eaten.lineWidth = line; eaten.lineCap = .round
        eaten.strokeColor = color(token).withAlphaComponent(0.55).cgColor
        eaten.strokeEnd = base
        eaten.isHidden = base <= 0.001
        group.addSublayer(track); group.addSublayer(eaten)
        group.frame = bounds
        stage.addSublayer(group)
        return group
    }

    private func arc(center: CGPoint, diameter: CGFloat, line: CGFloat, color: UIColor, from: Double, to: Double) -> CAShapeLayer {
        let arc = CAShapeLayer()
        arc.frame = bounds
        arc.path = circle(center: center, diameter: diameter, line: line)
        arc.fillColor = nil; arc.lineWidth = line; arc.lineCap = .round
        arc.strokeColor = color.cgColor
        arc.shadowColor = color.cgColor; arc.shadowRadius = 6; arc.shadowOpacity = 0.55; arc.shadowOffset = .zero
        arc.strokeStart = from; arc.strokeEnd = from
        // A stretch too short to draw would still show as a dot through its round caps.
        arc.isHidden = to - from < 0.004
        stage.addSublayer(arc)
        return arc
    }

    private func label(_ font: UIFont, color: UIColor) -> UILabel {
        let label = UILabel()
        label.font = font; label.textColor = color; label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true; label.minimumScaleFactor = 0.6
        label.isAccessibilityElement = false
        addSubview(label)
        return label
    }

    private func place(_ label: UILabel, center: CGPoint, width: CGFloat) {
        let height = label.font.lineHeight + 4
        label.frame = CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
    }

    // MARK: Motion

    private func appear(_ layer: CALayer, at time: CFTimeInterval) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0; fade.toValue = 1
        let rise = CABasicAnimation(keyPath: "transform.translation.y")
        rise.fromValue = 18; rise.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [fade, rise]
        group.beginTime = time; group.duration = 0.42; group.fillMode = .backwards
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
        layer.add(group, forKey: "appear")
    }

    private func grow(_ arc: CAShapeLayer, from: Double, to: Double, start: CFTimeInterval, end: CFTimeInterval) {
        arc.strokeEnd = to
        let grow = CABasicAnimation(keyPath: "strokeEnd")
        grow.fromValue = from; grow.toValue = to
        grow.beginTime = start; grow.duration = max(end - start, 0.18); grow.fillMode = .backwards
        grow.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0.1, 0.4, 1)
        arc.add(grow, forKey: "grow")
    }

    /// A short flare once the last dot lands. The rings share one full-screen frame, so a scale
    /// would pull them toward the screen centre; the arcs' glow swells instead.
    private func pulse(_ layer: CALayer) {
        let glow = CAKeyframeAnimation(keyPath: "shadowRadius")
        glow.values = [6, 16, 6]; glow.keyTimes = [0, 0.3, 1]; glow.duration = 0.7
        layer.add(glow, forKey: "pulse")
    }

    // MARK: Counting

    /// Sets each counting label for media time `now`. The flight calls it on every frame.
    private func updateCounters(at now: CFTimeInterval) {
        for counter in counters {
            let progress = min(max((now - counter.start) / max(counter.end - counter.start, 0.01), 0), 1)
            let eased = 1 - pow(1 - progress, 2.2)
            let text = counter.format(counter.from + (counter.to - counter.from) * eased)
            if counter.label.text != text { counter.label.text = text }
        }
    }

    // MARK: Sampling

    /// Points spread over the picture's opaque pixels, as fractions of its size, each with that pixel's colour.
    static func samples(_ image: UIImage, count: Int) -> [(unit: CGPoint, color: UIColor)] {
        LooprDotFlight.samples(image, count: count).map { ($0.unit, $0.color) }
    }

    nonisolated static func number(_ value: Double) -> String { LooprUnitFormatter.number(value, digits: 0) ?? "0" }
}
