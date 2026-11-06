import DesignSystem
import Foundation

// The dial as drawing primitives: every arc, mark and sticker the Canvas paints, with its ring, angle, width, colour
// token, state style and when it draws in during the entrance. The Canvas only strokes and fills what is here, so the
// mapping from layers to pixels is testable without a view.

/// One stroked arc on a ring.
public struct TodayDialStroke: Equatable, Sendable, Identifiable {
    public enum Layer: String, Equatable, Sendable {
        /// A faint dashed track where an absent layer would be: the shape of what is missing.
        case ghost
        case sleep, tonight, tonightEdge, windDown, eatingPlanned, eating, training, smartWindow
    }

    public let id: String
    public let layer: Layer
    public let radius: Double
    public let startAngle: Double
    public let sweep: Double
    public let width: Double
    public let tint: LooprColorToken
    public let opacity: Double
    /// Dash and gap lengths in view-box points. Empty is solid.
    public let dash: [Double]
    public let glows: Bool
    public let roundCaps: Bool
    /// Seconds into the entrance when the arc starts drawing in.
    public let revealStart: Double
}

/// A dot, ring or gem at one angle.
public struct TodayDialMark: Equatable, Sendable, Identifiable {
    public enum Shape: Equatable, Sendable {
        case dot
        /// A ring with the page colour inside.
        case hollow(lineWidth: Double)
        case dashedHollow(lineWidth: Double)
        /// A square turned 45 degrees, `size` is half its side.
        case gem
    }

    public enum Layer: String, Equatable, Sendable {
        case daylight, bead, kitchen, bedtime, alarm, mealTime, plannedTraining
    }

    public let id: String
    public let layer: Layer
    public let angle: Double
    public let radius: Double
    /// The mark's radius in view-box points.
    public let size: Double
    public let shape: Shape
    public let tint: LooprColorToken
    public let opacity: Double
    public let glows: Bool
    public let revealStart: Double
}

/// A meal sticker on the eating ring.
public struct TodayDialStickerMark: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    /// Where the meal happened.
    public let mealAngle: Double
    /// Where the sticker sits after the overlap rule. Never before `mealAngle`.
    public let angle: Double
    public let radius: Double
    public let sticker: TodayDialSticker?
    /// Meals of the same cluster that have no sticker of their own; shown as "+N" on this one.
    public let overflow: Int
    public let revealStart: Double
}

/// Places meal stickers so they stay readable when meals sit close together.
///
/// The rule: stickers keep their meal's time unless the one before is closer than `minimumSeparation`. Then the
/// sticker moves forward just enough to keep that gap, so neighbours overlap by at most 30 percent of a sticker and
/// the later meal sits on top. A cluster shows at most `maximumPerCluster` stickers; the last one carries "+N" for the
/// rest. Every meal keeps a small tick at its real time on the ring.
public enum TodayDialStickerLayout {
    /// The angle one sticker covers on the eating ring: 2·asin(16.5 / 96), about 19.8 degrees, 79 minutes.
    public static let diameterDegrees = 2 * asin(TodayDialGeometry.stickerRadius / TodayDialGeometry.eatingRadius) * 180 / .pi
    /// Neighbouring stickers keep their centres at least this far apart.
    public static let minimumSeparation = diameterDegrees * 0.7
    public static let maximumPerCluster = 3

    public static func place(_ meals: [TodayDialMeal], revealStart: Double = 0) -> [TodayDialStickerMark] {
        // Day degrees run 0 to 360 from midnight, so a day's meals never wrap.
        func dayDegrees(_ angle: Double) -> Double { TodayDialGeometry.normalized(angle - 180) }
        var marks: [TodayDialStickerMark] = []
        var clusterCount = 0
        var lastShown: Double?
        for (index, meal) in meals.enumerated() {
            let day = dayDegrees(meal.angle)
            let joins = lastShown.map { day - $0 < minimumSeparation } ?? false
            clusterCount = joins ? clusterCount + 1 : 1
            if clusterCount > maximumPerCluster, let last = marks.popLast() {
                marks.append(TodayDialStickerMark(id: last.id, title: last.title, mealAngle: last.mealAngle, angle: last.angle,
                                                  radius: last.radius, sticker: last.sticker, overflow: last.overflow + 1,
                                                  revealStart: last.revealStart))
                continue
            }
            let shown = joins ? max(day, (lastShown ?? day) + minimumSeparation) : day
            lastShown = shown
            marks.append(TodayDialStickerMark(id: meal.id, title: meal.title, mealAngle: meal.angle,
                                              angle: TodayDialGeometry.normalized(shown + 180), radius: meal.radius,
                                              sticker: meal.sticker, overflow: 0, revealStart: revealStart + Double(index) * 0.18))
        }
        return marks
    }
}

/// Everything the Canvas paints for one model.
public struct TodayDialDrawing: Equatable, Sendable {
    public let strokes: [TodayDialStroke]
    public let marks: [TodayDialMark]
    public let stickers: [TodayDialStickerMark]
    /// The "tonight" label on the eating ring, in the evening.
    public let tonightLabelAngle: Double?
    public let handAngle: Double?
    public let bedtimeGemSide: Double

    /// The entrance draws for this long, the contract's 1.6 seconds.
    public static let entranceDuration: Double = 1.8
    /// How long an arc takes to draw in, a mark to fade in and a sticker to pop.
    public static let strokeDrawDuration: Double = 0.8
    public static let markFadeDuration: Double = 0.35
    public static let stickerPopDuration: Double = 0.5

    public init(_ model: TodayDialModel) {
        var strokes: [TodayDialStroke] = []
        var marks: [TodayDialMark] = []
        let geometry = TodayDialGeometry.self

        // Sleep: the hypnogram in the morning, tonight's window in the evening.
        switch model.sleep {
        case .present(.lastNight(let night)):
            if night.spans.isEmpty {
                strokes.append(Self.arc("night", .sleep, night.night, radius: geometry.sleepRadius, width: geometry.stageWidth(.light),
                                        tint: .sleep, opacity: 0.45, reveal: 0.15))
            }
            for (index, span) in night.spans.enumerated() {
                // A hair of gap between spans, as the contract trims each one.
                let sweep = span.arc.sweep > 0.36 ? span.arc.sweep - 0.18 : span.arc.sweep
                strokes.append(TodayDialStroke(id: "stage-\(span.id)", layer: .sleep, radius: span.radius, startAngle: span.arc.startAngle,
                                               sweep: sweep, width: span.width, tint: span.stage.token, opacity: 1, dash: [], glows: false,
                                               roundCaps: false, revealStart: 0.15 + Double(index) * 0.012))
            }
        case .present(.tonight(let tonight)):
            if let window = tonight.window {
                strokes.append(Self.arc("tonight", .tonight, window, radius: geometry.sleepRadius, width: geometry.tonightWindowWidth,
                                        tint: .sleep, opacity: 0.16, reveal: 0.2))
                strokes.append(Self.arc("tonight-edge", .tonightEdge, window, radius: geometry.sleepRadius, width: 1.4, tint: .sleep,
                                        dash: [3, 4], reveal: 0.4))
            }
            if let windDown = tonight.windDown {
                strokes.append(Self.arc("wind-down", .windDown, windDown, radius: geometry.sleepRadius, width: geometry.windDownWidth,
                                        tint: .protocol, glows: true, roundCaps: true, reveal: 0.6))
            }
        case .absent:
            strokes.append(Self.ghost("sleep", radius: geometry.sleepRadius))
        }

        // Eating.
        var stickers: [TodayDialStickerMark] = []
        switch model.eating {
        case .present(let eating):
            if let planned = eating.planned {
                strokes.append(Self.arc("eating-planned", .eatingPlanned, planned, radius: geometry.eatingRadius,
                                        width: geometry.eatingPlannedWidth, tint: .energy, opacity: 0.22, roundCaps: true, reveal: 0.3))
            }
            strokes.append(Self.arc("eating", .eating, eating.window, radius: geometry.eatingRadius, width: geometry.eatingWindowWidth,
                                    tint: .energy, glows: true, roundCaps: true, reveal: 0.5))
            for meal in eating.meals {
                marks.append(TodayDialMark(id: "meal-time-\(meal.id)", layer: .mealTime, angle: meal.angle, radius: geometry.eatingRadius,
                                           size: 1.6, shape: .dot, tint: .energy, opacity: 1, glows: false, revealStart: 0.5))
            }
            stickers = TodayDialStickerLayout.place(eating.meals, revealStart: 1.0)
        case .absent:
            strokes.append(Self.ghost("eating", radius: geometry.eatingRadius))
        }

        // Training.
        switch model.training {
        case .present(let blocks):
            for block in blocks {
                if block.arc.sweep == 0 {
                    marks.append(TodayDialMark(id: "training-\(block.id)", layer: .plannedTraining, angle: block.arc.startAngle,
                                               radius: geometry.trainingRadius, size: geometry.trainingWidth / 2,
                                               shape: block.isPlanned ? .hollow(lineWidth: 1.4) : .dot, tint: .strain,
                                               opacity: block.isPlanned ? 0.7 : 1, glows: !block.isPlanned, revealStart: 0.9))
                } else {
                    strokes.append(TodayDialStroke(id: "training-\(block.id)", layer: .training, radius: geometry.trainingRadius,
                                                   startAngle: block.arc.startAngle, sweep: block.arc.sweep, width: geometry.trainingWidth,
                                                   tint: .strain, opacity: block.isPlanned ? 0.7 : 1, dash: block.isPlanned ? [2, 4] : [],
                                                   glows: !block.isPlanned, roundCaps: true, revealStart: 0.9))
                }
            }
        case .absent:
            strokes.append(Self.ghost("training", radius: geometry.trainingRadius))
        }

        // Daylight.
        switch model.daylight {
        case .present(let daylight):
            for (index, angle) in daylight.dotAngles.enumerated() {
                marks.append(TodayDialMark(id: "daylight-\(index)", layer: .daylight, angle: angle, radius: geometry.rimRadius,
                                           size: geometry.daylightDotRadius, shape: .dot, tint: .brand, opacity: 1, glows: true,
                                           revealStart: 0.8 + Double(index) * 0.02))
            }
        case .absent:
            strokes.append(TodayDialStroke(id: "ghost-daylight", layer: .ghost, radius: geometry.rimRadius, startAngle: 270, sweep: 180,
                                           width: 1, tint: .inkMuted, opacity: 0.35, dash: [1, 5], glows: false, roundCaps: true,
                                           revealStart: 0.8))
        }

        // Rule beads.
        for bead in model.beads {
            marks.append(Self.bead(bead))
        }

        // The bedtime gem and the alarm.
        if let bedtime = model.bedtime {
            marks.append(TodayDialMark(id: "bedtime", layer: .bedtime, angle: bedtime.angle, radius: geometry.sleepRadius,
                                       size: (model.mode == .evening ? geometry.eveningBedtimeGemSide : geometry.morningBedtimeGemSide) / 2,
                                       shape: .gem, tint: .ink, opacity: 1, glows: true, revealStart: model.mode == .evening ? 1.0 : 1.2))
        }
        if let alarm = model.alarm {
            if let window = alarm.smartWindow {
                strokes.append(Self.arc("smart-window", .smartWindow, window, radius: alarm.radius, width: 3, tint: .brand, opacity: 0.5,
                                        roundCaps: true, reveal: 1.1))
            }
            marks.append(TodayDialMark(id: "alarm", layer: .alarm, angle: alarm.angle, radius: alarm.radius, size: geometry.ruleBeadRadius,
                                       shape: .hollow(lineWidth: 1.6), tint: .brand, opacity: alarm.isTomorrow ? 0.8 : 1, glows: true,
                                       revealStart: 1.1))
        }

        self.strokes = strokes
        self.marks = marks
        self.stickers = stickers
        if case .present(.tonight(let tonight)) = model.sleep { tonightLabelAngle = tonight.labelAngle } else { tonightLabelAngle = nil }
        handAngle = model.hand?.angle
        bedtimeGemSide = model.mode == .evening ? geometry.eveningBedtimeGemSide : geometry.morningBedtimeGemSide
    }

    /// A rule bead in its state's style: kept is solid and lit, pending solid and quieter, missed an empty ring,
    /// unknown a dashed ring. The kitchen-closes bead is a ring on the eating ring with the page inside until kept.
    static func bead(_ bead: TodayDialBead) -> TodayDialMark {
        let kitchen = bead.kind == .kitchenCloses
        let shape: TodayDialMark.Shape
        let tint: LooprColorToken
        let opacity: Double
        switch bead.state {
        case .kept: shape = .dot; tint = .protocol; opacity = 1
        case .pending: shape = kitchen ? .hollow(lineWidth: 2) : .dot; tint = .protocol; opacity = kitchen ? 1 : 0.6
        case .missed: shape = .hollow(lineWidth: 1.4); tint = .inkSecondary; opacity = 1
        case .unknown: shape = .dashedHollow(lineWidth: 1.2); tint = .inkMuted; opacity = 1
        }
        return TodayDialMark(id: "bead-\(bead.id)", layer: kitchen ? .kitchen : .bead, angle: bead.angle, radius: bead.radius,
                             size: bead.size, shape: shape, tint: tint, opacity: opacity, glows: bead.state == .kept, revealStart: 1.1)
    }

    static func arc(_ id: String, _ layer: TodayDialStroke.Layer, _ arc: TodayDialArc, radius: Double, width: Double,
                    tint: LooprColorToken, opacity: Double = 1, dash: [Double] = [], glows: Bool = false, roundCaps: Bool = false,
                    reveal: Double) -> TodayDialStroke {
        TodayDialStroke(id: id, layer: layer, radius: radius, startAngle: arc.startAngle, sweep: arc.sweep, width: width, tint: tint,
                        opacity: opacity, dash: dash, glows: glows, roundCaps: roundCaps, revealStart: reveal)
    }

    /// The faint full track an absent layer leaves, so the dial keeps its shape.
    static func ghost(_ id: String, radius: Double) -> TodayDialStroke {
        TodayDialStroke(id: "ghost-\(id)", layer: .ghost, radius: radius, startAngle: 0, sweep: 360, width: 1, tint: .inkMuted,
                        opacity: 0.35, dash: [2, 5], glows: false, roundCaps: false, revealStart: 0.1)
    }

    /// How far an element that starts at `start` has come, 0 to 1, at `elapsed` seconds into the entrance.
    public static func progress(elapsed: Double, start: Double, duration: Double) -> Double {
        guard duration > 0 else { return 1 }
        return min(max((elapsed - start) / duration, 0), 1)
    }
}
