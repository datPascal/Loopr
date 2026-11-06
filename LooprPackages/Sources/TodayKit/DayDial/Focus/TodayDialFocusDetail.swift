import DesignSystem
import Foundation

/// The words and numbers a focused element's card shows, built from the dial model alone. Pure, so every line is
/// testable without a view.
public enum TodayDialFocusDetail: Equatable, Sendable {
    case meal(Meal)
    case lastNight(Night)
    case tonight(Tonight)
    case training(Training)
    case rule(Rule)
    case bedtime(Bedtime)
    case alarm(Alarm)

    public struct Meal: Equatable, Sendable {
        public let id: String
        public let title: String
        /// "08:12"
        public let time: String
        public let photoID: UUID?
        /// "520 kcal", nil when no food in the meal has calories.
        public let energy: String?
        public let macros: [Macro]
        /// "Greek yogurt, berries, granola"
        public let items: String?
        /// "Totals count only the foods with values."
        public let note: String?
        public let provenance: TodayDialProvenance
        public let accessibilityLabel: String
    }

    public struct Macro: Equatable, Sendable, Identifiable {
        public enum Kind: String, Sendable { case protein, carbs, fat, fibre }
        public let kind: Kind
        /// "P", "C", "F", "Fibre"
        public let letter: String
        public let grams: Double?
        /// "32 g", or "– g" when unknown, as Food writes it.
        public let text: String
        /// The macro's share of the meal's energy, 0 to 1. Nil for fibre and for unknown values.
        public let energyShare: Double?
        public var id: Kind { kind }

        public var token: LooprColorToken {
            // Food's macro colours: protein red, carbs teal, fat violet, fibre amber.
            switch kind {
            case .protein: .heart
            case .carbs: .brand
            case .fat: .sleep
            case .fibre: .energy
            }
        }
    }

    public struct Night: Equatable, Sendable {
        public let spans: [LooprStageSpan]
        public let timeZone: TimeZone
        /// "7 h 48 m", nil when the band did not count the night.
        public let asleep: String?
        /// "22:30 to 06:18"
        public let range: String
        /// "Deep 1 h 0 m · REM 30 m · Light 6 h 13 m · Awake 5 m"
        public let stages: String
        public let isPartial: Bool
        public let provenance: TodayDialProvenance
    }

    public struct Tonight: Equatable, Sendable {
        /// "Bed at 22:30"
        public let bedtime: String
        /// "Your protocol" or "Sleep plan"
        public let bedtimeSource: String
        /// "2:41 until bed"
        public let countdown: String?
        /// "Up at 06:30, from your alarm"
        public let wake: String?
        /// "Wind down from 21:45"
        public let windDown: String?
        public let provenance: TodayDialProvenance
    }

    public struct Training: Equatable, Sendable {
        public let title: String
        /// "07:10 to 07:52", "Planned for 17:30" or "Since 17:05"
        public let time: String
        /// "42 min", nil for a planned session without a length.
        public let duration: String?
        /// "Done", "Planned", "In progress", or the planned rule's state.
        public let status: String
        public let isPlanned: Bool
        public let provenance: TodayDialProvenance
    }

    public struct Rule: Equatable, Sendable {
        public let key: String
        public let title: String
        /// "By 18:30" or "At 21:45"
        public let time: String
        public let state: TodayDialRuleState
        /// "Kept", "Missed", "To do", "Not checked yet"
        public let status: String
        /// "Food checks this from your meals."
        public let source: String
        /// A manual rule not kept yet, on today's dial.
        public let canTick: Bool
    }

    public struct Bedtime: Equatable, Sendable {
        /// "22:30"
        public let time: String
        /// "Your protocol" or "Sleep plan"
        public let source: String
        /// "2:41 until bed", nil past bedtime or on another day.
        public let countdown: String?
        public let status: String?
        public let provenance: TodayDialProvenance
    }

    public struct Alarm: Equatable, Sendable {
        /// "06:30"
        public let time: String
        /// "Tomorrow" or "This morning"
        public let day: String
        /// "Smart window from 06:00"
        public let smartWindow: String?
    }

    /// The card for `focus`, or nil when the element left the dial (a meal deleted while its card was open).
    public static func make(_ focus: TodayDialFocus, model: TodayDialModel, locale: Locale = .current) -> TodayDialFocusDetail? {
        let clock = model.clock
        func time(_ date: Date) -> String { TodayDialFormat.clock(date, clock: clock, locale: locale) }
        switch focus {
        case .meal(let id):
            guard let meal = model.eating.value?.meals.first(where: { $0.id == id }) else { return nil }
            return .meal(Self.meal(meal, time: time(meal.at)))

        case .lastNight:
            guard case .present(.lastNight(let night)) = model.sleep else { return nil }
            let spans = night.spans.map { LooprStageSpan(id: $0.id, stage: $0.stage, start: $0.arc.start, end: $0.arc.end) }
            let timeline = LooprStageTimelineModel(spans: spans, timeZone: clock.timeZone)
            let stages = LooprStageTimelineModel.laneOrder.reversed().compactMap { stage -> String? in
                guard let minutes = timeline.totals[stage], minutes > 0, let text = LooprUnitFormatter.duration(minutes: minutes) else {
                    return nil
                }
                return "\(stage.title) \(text)"
            }
            return .lastNight(Night(spans: spans, timeZone: clock.timeZone,
                                    asleep: night.asleepMinutes.flatMap { LooprUnitFormatter.duration(minutes: $0) },
                                    range: "\(time(night.night.start)) to \(time(night.night.end))",
                                    stages: stages.joined(separator: " · "), isPartial: night.isPartial, provenance: night.provenance))

        case .tonight:
            guard case .present(.tonight(let tonight)) = model.sleep else { return nil }
            let wake: String? = tonight.window.map { window in
                switch tonight.wakeSource {
                case .alarm: "Up at \(time(window.end)), when your alarm rings"
                case .sleepPlan, .none: "Up at \(time(window.end)), from your sleep plan"
                }
            }
            return .tonight(Tonight(bedtime: "Bed at \(time(tonight.bedtime.at))", bedtimeSource: tonight.bedtime.qualifier,
                                    countdown: countdown(model), wake: wake,
                                    windDown: tonight.windDown.map { "Wind down from \(time($0.start))" },
                                    provenance: tonight.bedtime.provenance))

        case .training(let id):
            guard let block = model.training.value?.first(where: { $0.id == id }) else { return nil }
            let minutes = block.arc.end.timeIntervalSince(block.arc.start) / 60
            let duration = minutes >= 1 ? LooprUnitFormatter.duration(minutes: minutes) : nil
            let timeText: String
            let status: String
            if block.isPlanned {
                timeText = "Planned for \(time(block.arc.start))"
                status = block.ruleState.map(ruleStatus) ?? "Planned"
            } else if block.isOngoing {
                timeText = "Since \(time(block.arc.start))"
                status = "In progress"
            } else {
                timeText = "\(time(block.arc.start)) to \(time(block.arc.end))"
                status = "Done"
            }
            return .training(Training(title: block.title, time: timeText, duration: duration, status: status,
                                      isPlanned: block.isPlanned, provenance: block.provenance))

        case .bead(let key):
            guard let bead = model.beads.first(where: { $0.id == key }) else { return nil }
            let at = TodayDialFormat.clock(minuteOfDay: bead.minuteOfDay, locale: locale)
            return .rule(Rule(key: bead.id, title: bead.title, time: bead.kind == .kitchenCloses ? "By \(at)" : "At \(at)",
                              state: bead.state, status: ruleStatus(bead.state), source: ruleSource(bead.source),
                              canTick: model.isToday && bead.source == .manual && bead.state != .kept))

        case .bedtime:
            guard let bedtime = model.bedtime else { return nil }
            let status: String? = if case .rule(_, let state) = bedtime.source { ruleStatus(state) } else { nil }
            return .bedtime(Bedtime(time: time(bedtime.at), source: bedtime.qualifier, countdown: countdown(model), status: status,
                                    provenance: bedtime.provenance))

        case .alarm:
            guard let alarm = model.alarm else { return nil }
            return .alarm(Alarm(time: time(alarm.wake), day: alarm.isTomorrow ? "Tomorrow" : "This morning",
                                smartWindow: alarm.smartWindow.map { "Smart window from \(time($0.start))" }))
        }
    }

    static func meal(_ meal: TodayDialMeal, time: String) -> Meal {
        let nutrition = meal.nutrition
        func grams(_ value: Double?) -> String {
            // A dash for an unknown value, as Food writes it.
            guard let value, value.isFinite else { return "– g" }
            return "\(LooprUnitFormatter.number(value) ?? "\(Int(value.rounded()))") g"
        }
        // Energy from each macro at 4, 4 and 9 kcal a gram, for the split bar.
        let protein = nutrition?.proteinGrams.map { $0 * 4 }, carbs = nutrition?.carbsGrams.map { $0 * 4 },
            fat = nutrition?.fatGrams.map { $0 * 9 }
        let macroEnergy = [protein, carbs, fat].compactMap { $0 }.reduce(0, +)
        func share(_ kcal: Double?) -> Double? {
            guard let kcal, macroEnergy > 0 else { return nil }
            return kcal / macroEnergy
        }
        let macros: [Macro] = nutrition.map { n in
            [Macro(kind: .protein, letter: "P", grams: n.proteinGrams, text: grams(n.proteinGrams), energyShare: share(protein)),
             Macro(kind: .carbs, letter: "C", grams: n.carbsGrams, text: grams(n.carbsGrams), energyShare: share(carbs)),
             Macro(kind: .fat, letter: "F", grams: n.fatGrams, text: grams(n.fatGrams), energyShare: share(fat)),
             Macro(kind: .fibre, letter: "Fibre", grams: n.fibreGrams, text: grams(n.fibreGrams), energyShare: nil)]
        } ?? []
        let energy = nutrition?.energyKcal.flatMap { $0.isFinite ? "\(LooprUnitFormatter.number($0) ?? "\(Int($0.rounded()))") kcal" : nil }
        let items = nutrition.flatMap { $0.items.isEmpty ? nil : $0.items.joined(separator: ", ") }
        var spoken = ["\(meal.title) at \(time)"]
        if let energy { spoken.append(energy) }
        spoken += macros.compactMap { macro in
            macro.grams.map { "\(macro.kind == .fibre ? "fibre" : macro.kind.rawValue) \(LooprUnitFormatter.number($0) ?? "") grams" }
        }
        return Meal(id: meal.id, title: meal.title, time: time, photoID: meal.sticker?.photoID, energy: energy, macros: macros,
                    items: items, note: nutrition?.isPartial == true ? "Totals count only the foods with values." : nil,
                    provenance: meal.provenance, accessibilityLabel: spoken.joined(separator: ", "))
    }

    /// "2:41 until bed" while bedtime is ahead on today's dial.
    static func countdown(_ model: TodayDialModel) -> String? {
        guard model.isToday, let bedtime = model.bedtime, bedtime.at > model.now else { return nil }
        return "\(TodayDialFormat.hoursMinutes(bedtime.at.timeIntervalSince(model.now))) until bed"
    }

    static func ruleStatus(_ state: TodayDialRuleState) -> String {
        switch state {
        case .kept: "Kept"
        case .missed: "Missed"
        case .pending: "To do"
        case .unknown: "Not checked yet"
        }
    }

    static func ruleSource(_ source: TodayDialRuleSource) -> String {
        switch source {
        case .band: "Your band checks this one."
        case .food: "Food checks this from your meals."
        case .fitness: "Fitness checks this from your workouts."
        case .appleHealth: "Apple Health checks this one."
        case .manual: "You tick this one yourself."
        }
    }
}
