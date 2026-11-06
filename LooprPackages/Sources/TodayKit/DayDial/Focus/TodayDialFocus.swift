import DesignSystem
import Foundation

/// What a tap on the dial opens. The detail grows out of the tapped element inside the dial's own square, so Today
/// never changes screen; closing plays the same morph back into the element.
public enum TodayDialFocus: Hashable, Sendable {
    /// A meal sticker, by meal id.
    case meal(String)
    /// Last night's hypnogram, in the morning.
    case lastNight
    /// Tonight's sleep window, in the evening.
    case tonight
    /// A workout or a planned session, by block id.
    case training(String)
    /// A protocol rule bead, by rule key.
    case bead(String)
    case bedtime
    case alarm
}

/// Where a focused element sits on the dial, in view-box points. The morph leaves from here and lands back here.
public struct TodayDialFocusAnchor: Equatable, Sendable {
    public let center: TodayDialPoint
    /// Half the element's size.
    public let radius: Double

    public init(center: TodayDialPoint, radius: Double) {
        self.center = center
        self.radius = radius
    }
}

/// Which element a touch picks, and where each element sits. Pure, in the dial's 340-point view box.
public enum TodayDialHitTest {
    /// A touch this far outside an element, in screen points, still picks it: Apple's 44-point target, halved.
    public static let touchSlop: Double = 22

    /// The element under `point`, a point in the view box of a dial drawn `side` screen points across. The centre opens
    /// the sleep layer it describes. Nil when nothing is near.
    public static func focus(at point: TodayDialPoint, side: Double, model: TodayDialModel) -> TodayDialFocus? {
        guard side > 0 else { return nil }
        let geometry = TodayDialGeometry.self
        let slop = touchSlop * geometry.viewBox / side
        let dx = point.x - geometry.centre, dy = point.y - geometry.centre
        let r = hypot(dx, dy)
        let angle = geometry.normalized(atan2(dx, -dy) * 180 / .pi)

        if r < geometry.innerRingRadius {
            switch model.sleep {
            case .present(.lastNight): return .lastNight
            case .present(.tonight): return .tonight
            case .absent: return nil
            }
        }

        // Each candidate scores its distance from the element's edge. Small things win ties, so a bead on the night
        // arc still opens.
        var best: (focus: TodayDialFocus, distance: Double)?
        func consider(_ focus: TodayDialFocus, _ distance: Double, reach: Double = slop) {
            guard distance <= reach else { return }
            if best == nil || distance < best!.distance { best = (focus, distance) }
        }
        func toMark(_ angleDegrees: Double, _ radius: Double, size: Double) -> Double {
            let p = geometry.point(radius: radius, angle: angleDegrees)
            return max(hypot(p.x - point.x, p.y - point.y) - size, 0)
        }
        func toArc(_ arc: TodayDialArc, radius: Double, halfWidth: Double) -> Double {
            arcDistance(r: r, angle: angle, point: point, radius: radius, startAngle: arc.startAngle, sweep: arc.sweep,
                        halfWidth: halfWidth)
        }

        for sticker in TodayDialStickerLayout.place(model.eating.value?.meals ?? []) {
            // Stickers sit on top of everything they cover, so they get a head start.
            consider(.meal(sticker.id), max(toMark(sticker.angle, sticker.radius, size: geometry.stickerRadius) - 2, 0))
        }
        if let eating = model.eating.value, eating.window.sweep > 0,
           toArc(eating.window, radius: geometry.eatingRadius, halfWidth: geometry.eatingWindowWidth / 2) <= slop / 2,
           let nearest = eating.meals.min(by: { angularDistance($0.angle, angle) < angularDistance($1.angle, angle) }) {
            consider(.meal(nearest.id), toArc(eating.window, radius: geometry.eatingRadius, halfWidth: geometry.eatingWindowWidth / 2) + 1)
        }
        for bead in model.beads {
            consider(.bead(bead.id), toMark(bead.angle, bead.radius, size: bead.size))
        }
        if let bedtime = model.bedtime {
            let side = model.mode == .evening ? geometry.eveningBedtimeGemSide : geometry.morningBedtimeGemSide
            consider(.bedtime, toMark(bedtime.angle, geometry.sleepRadius, size: side / 2))
        }
        if let alarm = model.alarm {
            consider(.alarm, toMark(alarm.angle, alarm.radius, size: geometry.ruleBeadRadius))
        }
        for block in model.training.value ?? [] {
            if block.arc.sweep == 0 {
                consider(.training(block.id), toMark(block.arc.startAngle, geometry.trainingRadius, size: geometry.trainingWidth / 2))
            } else {
                consider(.training(block.id), toArc(block.arc, radius: geometry.trainingRadius, halfWidth: geometry.trainingWidth / 2) + 0.5)
            }
        }
        switch model.sleep {
        case .present(.lastNight(let night)):
            let half = night.spans.map(\.width).max().map { $0 / 2 } ?? geometry.stageWidth(.light) / 2
            consider(.lastNight, toArc(night.night, radius: geometry.sleepRadius, halfWidth: half) + 1)
        case .present(.tonight(let tonight)):
            for arc in [tonight.window, tonight.windDown].compactMap({ $0 }) {
                consider(.tonight, toArc(arc, radius: geometry.sleepRadius, halfWidth: geometry.tonightWindowWidth / 2) + 1)
            }
        case .absent:
            break
        }
        return best?.focus
    }

    /// Where `focus` sits on `model`'s dial, or nil when the element is not on it any more.
    public static func anchor(for focus: TodayDialFocus, in model: TodayDialModel) -> TodayDialFocusAnchor? {
        let geometry = TodayDialGeometry.self
        func at(_ angle: Double, _ radius: Double, size: Double) -> TodayDialFocusAnchor {
            TodayDialFocusAnchor(center: geometry.point(radius: radius, angle: angle), radius: size)
        }
        func middle(_ arc: TodayDialArc) -> Double { geometry.normalized(arc.startAngle + arc.sweep / 2) }
        switch focus {
        case .meal(let id):
            guard let sticker = TodayDialStickerLayout.place(model.eating.value?.meals ?? []).first(where: { $0.id == id }) else {
                // A meal folded into a "+N" sticker leaves from its own time on the ring.
                guard let meal = model.eating.value?.meals.first(where: { $0.id == id }) else { return nil }
                return at(meal.angle, meal.radius, size: geometry.stickerRadius)
            }
            return at(sticker.angle, sticker.radius, size: geometry.stickerRadius)
        case .lastNight:
            guard case .present(.lastNight(let night)) = model.sleep else { return nil }
            return at(middle(night.night), geometry.sleepRadius, size: geometry.stageWidth(.deep) / 2)
        case .tonight:
            guard case .present(.tonight(let tonight)) = model.sleep else { return nil }
            guard let arc = tonight.window ?? tonight.windDown else {
                return at(tonight.bedtime.angle, geometry.sleepRadius, size: geometry.tonightWindowWidth / 2)
            }
            return at(middle(arc), geometry.sleepRadius, size: geometry.tonightWindowWidth / 2)
        case .training(let id):
            guard let block = model.training.value?.first(where: { $0.id == id }) else { return nil }
            return at(middle(block.arc), geometry.trainingRadius, size: geometry.trainingWidth / 2)
        case .bead(let id):
            guard let bead = model.beads.first(where: { $0.id == id }) else { return nil }
            return at(bead.angle, bead.radius, size: bead.size)
        case .bedtime:
            guard let bedtime = model.bedtime else { return nil }
            return at(bedtime.angle, geometry.sleepRadius, size: geometry.eveningBedtimeGemSide / 2)
        case .alarm:
            guard let alarm = model.alarm else { return nil }
            return at(alarm.angle, alarm.radius, size: geometry.ruleBeadRadius)
        }
    }

    /// The ids of what the dial stops drawing while `focus` is open, because the detail carries it out of the dial.
    public static func carriedIDs(for focus: TodayDialFocus, in model: TodayDialModel) -> Set<String> {
        switch focus {
        case .meal(let id): ["sticker-\(id)"]
        case .lastNight:
            if case .present(.lastNight(let night)) = model.sleep { Set(night.spans.map { "stage-\($0.id)" }).union(["night"]) } else { [] }
        case .tonight, .training, .bead, .bedtime, .alarm: []
        }
    }

    /// Distance from a point to a stroked arc's edge: radial inside the sweep, to the nearer end outside it.
    static func arcDistance(r: Double, angle: Double, point: TodayDialPoint, radius: Double, startAngle: Double, sweep: Double,
                            halfWidth: Double) -> Double {
        if TodayDialGeometry.normalized(angle - startAngle) <= sweep {
            return max(abs(r - radius) - halfWidth, 0)
        }
        let ends = [startAngle, startAngle + sweep].map { TodayDialGeometry.point(radius: radius, angle: $0) }
        let nearest = ends.map { hypot($0.x - point.x, $0.y - point.y) }.min() ?? .infinity
        return max(nearest - halfWidth, 0)
    }

    static func angularDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(TodayDialGeometry.normalized(a) - TodayDialGeometry.normalized(b)).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d)
    }
}
