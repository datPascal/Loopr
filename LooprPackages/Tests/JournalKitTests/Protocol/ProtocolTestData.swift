import DomainKit
import Foundation
import JournalKit
import RoutineKit

/// Shared rules and days for the Protocol tab tests. The week is Mon 13 to Sun 19 Nov 2023, in UTC.
enum ProtocolTestData {
    static let zone = TimeZone(identifier: "UTC")!
    static let locale = Locale(identifier: "en_GB")
    static let calendar = ProtocolWeekCalendar(timeZone: zone, locale: locale)
    /// Tue 14 Nov 2023, 22:13 UTC.
    static let now = Date(timeIntervalSince1970: 1_700_000_000)

    static func day(_ value: Int) -> DayIdentity { DayIdentity(year: 2023, month: 11, day: value) }

    static let light = ProtocolRule(key: "light", title: "Morning light", timeOfDayMinutes: 8 * 60)
    static let caffeine = ProtocolRule(key: "caffeine", title: "No caffeine after 14:00",
        target: RuleTarget(kind: .atMost, metric: RoutineMetric.lastCaffeineTime.rawValue, value: 839),
        timeOfDayMinutes: 14 * 60, source: .food)
    static let meal = ProtocolRule(key: "meal", title: "Last meal by 19:00",
        target: RuleTarget(kind: .atMost, metric: RoutineMetric.lastMealTime.rawValue, value: 1_140),
        timeOfDayMinutes: 19 * 60, source: .food)
    static let alcohol = ProtocolRule(key: "alcohol", title: "No alcohol",
        target: RuleTarget(kind: .atMost, metric: RoutineMetric.alcoholDrinks.rawValue, value: 0), source: .food)
    static let zone2 = ProtocolRule(key: "zone2", title: "Zone 2 for 30 minutes",
        target: RuleTarget(kind: .atLeast, metric: RoutineMetric.zone2Minutes.rawValue, value: 30), source: .band)
    static let training = ProtocolRule(key: "training", title: "Training",
        target: RuleTarget(kind: .done, metric: RoutineMetric.workoutMinutes.rawValue), source: .fitness)
    static let magnesium = ProtocolRule(key: "magnesium", title: "Magnesium, 300 mg", timeOfDayMinutes: 21 * 60 + 30, isEvening: true)
    static let screens = ProtocolRule(key: "screens", title: "Screens off by 21:45", timeOfDayMinutes: 21 * 60 + 45, isEvening: true)
    static let bed = ProtocolRule(key: "bed", title: "In bed by 22:30",
        target: RuleTarget(kind: .atMost, metric: RoutineMetric.inBedTime.rawValue, value: 1_350),
        timeOfDayMinutes: 22 * 60 + 30, source: .band, isEvening: true)
    static let stretch = ProtocolRule(key: "stretch", title: "Stretch")

    static let rules = [light, caffeine, meal, alcohol, zone2, training, magnesium, screens, bed, stretch]

    static func input(_ day: Int, _ phase: ProtocolDayPhase, _ states: [RuleKey: CheckState],
                      overridden: Set<RuleKey> = [], rules: [ProtocolRule] = rules) -> ProtocolDayInput {
        ProtocolDayInput(day: Self.day(day), phase: phase, rules: rules.map { rule in
            let state = states[rule.key]
            let person = overridden.contains(rule.key)
            return ProtocolRuleDay(rule: rule, state: state, decidedBy: state == nil ? nil : (person ? .manual : rule.source),
                                   overriddenByPerson: person)
        })
    }

    /// Tuesday at 22:13: Food, the band and Fitness answered, Morning light ticked, the evening still open.
    static var tuesday: ProtocolDayInput {
        input(14, .today, ["light": .kept, "caffeine": .kept, "meal": .kept, "alcohol": .pending, "zone2": .kept,
                           "training": .kept, "magnesium": .pending, "screens": .pending, "bed": .pending, "stretch": .pending])
    }

    /// A whole week with Monday decided, Tuesday as above and the rest ahead.
    static func week(monday: [RuleKey: CheckState]) -> [ProtocolDayInput] {
        [input(13, .past, monday), tuesday] + (15...19).map { input($0, .future, [:]) }
    }
}
