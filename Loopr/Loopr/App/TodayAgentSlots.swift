import DesignSystem
import DeviceCenterKit
import DomainKit
import FoodKit
import Foundation
import JournalKit
import RoutineKit
import SleepKit
import TodayKit
import TrainKit

// What the app puts into Today's slots. TodayKit draws the Your day rows, the timeline and the pattern card
// but does not know Food, Train, Journal or Patterns. This file turns their data into the plain values
// TodayKit takes. `TodayAgentSlotBuilder` is pure so a test can check every row without a store.

nonisolated struct TodayFoodFacts: Equatable, Sendable {
    var energy: Double?
    var energyTarget: Double?
    var protein: Double?
    var proteinTarget: Double?
    var hasEntries: Bool
    /// Energy from drinks, which the day's total counts and the timeline's meals do not. 8 kcal of coffee is why
    /// 1,240 kcal sat over two meals of 1,232 (ICP R2-OPT-1).
    var drinkEnergy: Double?

    init(energy: Double?, energyTarget: Double?, protein: Double?, proteinTarget: Double?, hasEntries: Bool,
         drinkEnergy: Double? = nil) {
        self.energy = energy; self.energyTarget = energyTarget; self.protein = protein
        self.proteinTarget = proteinTarget; self.hasEntries = hasEntries; self.drinkEnergy = drinkEnergy
    }

    init(_ day: FoodDaySummary) {
        energy = day.total(.energy).knownValue
        energyTarget = day.target.energy
        protein = day.total(.protein).knownValue
        proteinTarget = day.settings?.protein
        hasEntries = !day.meals.isEmpty || !day.drinks.isEmpty
        let drinks = day.drinks.compactMap(\.energy).filter(\.isFinite).reduce(0, +)
        drinkEnergy = drinks >= 0.5 ? drinks : nil
    }
}

nonisolated struct TodayMealFact: Equatable, Sendable {
    var id: String
    var minuteOfDay: Int
    var slot: String
    var items: [String]
    var energy: Double?

    init(id: String, minuteOfDay: Int, slot: String, items: [String], energy: Double?) {
        self.id = id; self.minuteOfDay = minuteOfDay; self.slot = slot; self.items = items; self.energy = energy
    }

    /// The minute is the clock time in the zone the meal was logged in.
    init(_ meal: FoodMeal) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: meal.timeZoneIdentifier) ?? .current
        let parts = calendar.dateComponents([.hour, .minute], from: meal.occurredAt)
        let total = FoodNutrientTotal(.energy, items: meal.items)
        self.init(id: meal.id.uuidString.lowercased(), minuteOfDay: (parts.hour ?? 0) * 60 + (parts.minute ?? 0),
                  slot: meal.slot.title, items: meal.items.map(\.name), energy: total.isComplete ? total.knownValue : nil)
    }
}

nonisolated struct TodayReminderFact: Equatable, Sendable {
    var id: String
    var minuteOfDay: Int
    var title: String
    var detail: String?
}

/// A wake alarm that is on, for the timeline row. `windowMinutes` is 0 for an alarm with no smart window.
nonisolated struct TodayAlarmFact: Equatable, Sendable {
    var wakeMinute: Int
    var windowMinutes: Int
    /// False when the alarm is on but not set for today's weekday.
    var ringsToday: Bool
    /// The same for tomorrow's weekday.
    var ringsTomorrow: Bool
}

nonisolated struct TodayAgentInputs: Sendable {
    var nowMinute: Int
    var food: TodayFoodFacts?
    var meals: [TodayMealFact] = []
    var train: TrainToday = .none
    /// Sessions finished today, with the minute each one started.
    var finishedSessions: [(summary: TrainSessionSummary, startMinute: Int)] = []
    var wake: (minuteOfDay: Int, sleepMinutes: Int?)?
    /// Tonight's bedtime from Sleep's plan, for a day that is still going. Nil falls back to Today's own rule.
    var bedtime: (minuteOfDay: Int, sleepMinutes: Double)?
    /// The part of `bedtime.sleepMinutes` that catches up on recent short nights. The rest is the sleep need the Sleep
    /// card shows, so the page names one need.
    var sleepExtraMinutes: Double = 0
    /// The person's own "In bed by" rule. It is the bedtime Today shows; Sleep's plan is advice beside it (ICP R3-OPT-7).
    var inBedRuleMinute: Int?
    var reminders: [TodayReminderFact] = []
    /// The wake alarm, for a day that is still going and only while the alarm is on.
    var alarm: TodayAlarmFact?
    var patterns: PatternsSnapshot?
    var patternsEnabled = false
}

nonisolated enum TodayAgentSlotBuilder {
    static func content(_ inputs: TodayAgentInputs, locale: Locale = .current) -> TodayAgentContent {
        TodayAgentContent(
            yourDayRows: [foodRow(inputs.food), trainRow(inputs.train, finished: inputs.finishedSessions.map(\.summary), locale: locale)]
                .compactMap { $0 },
            timeline: timeline(inputs),
            pattern: patternCard(inputs.patterns, enabled: inputs.patternsEnabled, locale: locale),
            nowMinute: inputs.nowMinute)
    }

    // MARK: Your day

    static func foodRow(_ food: TodayFoodFacts?) -> TodayYourDayRow? {
        guard let food, food.hasEntries || food.energyTarget != nil else { return nil }
        let eaten = food.energy ?? 0
        let value = number(eaten.rounded())
        let unit = food.energyTarget.map { "of \(number($0.rounded())) kcal" } ?? "kcal"
        var caption: String?
        if !food.hasEntries {
            caption = "Nothing logged yet"
        } else if let protein = food.protein {
            caption = food.proteinTarget.map { "Protein \(number(protein.rounded())) of \(number($0.rounded())) g" }
                ?? "Protein \(number(protein.rounded())) g"
        }
        if food.hasEntries, let drinks = food.drinkEnergy {
            caption = [caption, "\(number(drinks.rounded())) kcal from drinks"].compactMap { $0 }.joined(separator: " · ")
        }
        return TodayYourDayRow(id: "food", title: "Food", caption: caption, value: value, unit: unit)
    }

    static func trainRow(_ train: TrainToday, finished: [TrainSessionSummary], locale: Locale = .current) -> TodayYourDayRow? {
        switch train {
        case .none:
            return nil
        case .plan(let plan):
            let title = plan.startMinute.map { "\(plan.name) at \(TodayTimelineRules.clock($0, locale: locale))" } ?? plan.name
            return TodayYourDayRow(id: "train", title: title, caption: plan.detail, chip: "Planned")
        case .done(let session):
            return TodayYourDayRow(id: "train", title: session.name, caption: session.detail.isEmpty ? nil : session.detail, chip: "Done")
        case .rest(let next):
            if let first = finished.first {
                return TodayYourDayRow(id: "train", title: first.name, caption: first.detail.isEmpty ? nil : first.detail, chip: "Done")
            }
            return TodayYourDayRow(id: "train", title: "Rest day", caption: next.map { "Next is \($0)" } ?? "Nothing planned")
        }
    }

    /// Today's content without a "Protocol" row in "Your day". The rail under the dial counts the same rules with its
    /// ring and "4 of 10 kept", so a second count further down only repeated it (ICP R1-UPG-18, R2-UPG-15). Without a
    /// protocol the rail itself says where rules come from, so the row has no case left.
    static func withoutProtocolRow(_ content: TodayAgentContent) -> TodayAgentContent {
        var content = content
        content.yourDayRows.removeAll { $0.id == "journal" }
        return content
    }

    // MARK: Timeline

    static func timeline(_ inputs: TodayAgentInputs) -> [TodayTimelineItem] {
        var items: [TodayTimelineItem] = []
        if let wake = inputs.wake {
            items.append(TodayTimelineItem(id: "wake", minuteOfDay: wake.minuteOfDay, kind: .wake, title: "Woke up",
                detail: wake.sleepMinutes.flatMap { LooprUnitFormatter.duration(minutes: Double($0)) }.map { "Slept \($0)" }))
        }
        if let alarm = inputs.alarm {
            let smart = alarm.windowMinutes > 0
            // Once the morning is over, the alarm that matters is tomorrow's, so it follows tonight's bedtime.
            let tomorrow = inputs.wake != nil || inputs.nowMinute >= alarm.wakeMinute
            let window = smart ? "up to \(alarm.windowMinutes) min early" : nil
            let detail: String?
            if !(tomorrow ? alarm.ringsTomorrow : alarm.ringsToday) {
                detail = tomorrow ? "Not set for tomorrow" : "Not set for today"
            } else if tomorrow {
                detail = (["Tomorrow"] + [window].compactMap { $0 }).joined(separator: ", ")
            } else {
                detail = window.map { $0.prefix(1).uppercased() + $0.dropFirst() }
            }
            items.append(TodayTimelineItem(id: "alarm", minuteOfDay: alarm.wakeMinute, kind: .alarm,
                title: smart ? "Smart alarm" : "Alarm", detail: detail, isInteractive: true, isNextDay: tomorrow))
        }
        for meal in inputs.meals {
            var parts = [meal.items.joined(separator: ", ")]
            if let energy = meal.energy { parts.append("\(number(energy.rounded())) kcal") }
            items.append(TodayTimelineItem(id: "meal-\(meal.id)", minuteOfDay: meal.minuteOfDay, kind: .meal, title: meal.slot,
                detail: parts.filter { !$0.isEmpty }.joined(separator: " · "), isInteractive: true, isRecord: true))
        }
        for entry in inputs.finishedSessions {
            items.append(TodayTimelineItem(id: "workout-\(entry.summary.id.uuidString.lowercased())", minuteOfDay: entry.startMinute,
                kind: .workout, title: entry.summary.name, detail: entry.summary.detail.isEmpty ? nil : entry.summary.detail, isInteractive: true,
                isRecord: true))
        }
        if case .plan(let plan) = inputs.train, let start = plan.startMinute {
            items.append(TodayTimelineItem(id: "workout-planned", minuteOfDay: start, kind: .workout, title: plan.name,
                detail: "Planned", isInteractive: true))
        }
        for reminder in inputs.reminders {
            items.append(TodayTimelineItem(id: "reminder-\(reminder.id)", minuteOfDay: reminder.minuteOfDay, kind: .reminder,
                title: reminder.title, detail: reminder.detail, isInteractive: true))
        }
        if let bedtime = inputs.bedtime {
            let item = bedtimeItem(planMinute: bedtime.minuteOfDay, sleepMinutes: bedtime.sleepMinutes,
                                   extraMinutes: inputs.sleepExtraMinutes, ruleMinute: inputs.inBedRuleMinute)
            items.append(TodayTimelineItem(id: "bedtime", minuteOfDay: item.minuteOfDay, kind: .bedtime, title: "Bedtime",
                detail: item.detail, isInteractive: true))
        }
        return items
    }

    /// "8 h of sleep", or "8 h of sleep plus 50 m to catch up". The need is the Sleep card's, so Today shows one need.
    static func sleepPhrase(sleepMinutes: Double, extraMinutes: Double) -> String {
        let extra = max(extraMinutes.rounded(), 0)
        let need = LooprUnitFormatter.duration(minutes: max(sleepMinutes - extra, 0)) ?? ""
        guard extra >= 1, let catchUp = LooprUnitFormatter.duration(minutes: extra) else { return "\(need) of sleep" }
        return "\(need) of sleep plus \(catchUp) to catch up"
    }

    /// Tonight's bedtime row. With an "In bed by" rule the row stands at the rule's time, and Sleep's plan is a line of
    /// advice under it, left out when the two agree within 5 minutes. Without a rule the row is Sleep's plan.
    static func bedtimeItem(planMinute: Int, sleepMinutes: Double, extraMinutes: Double, ruleMinute: Int?,
                            locale: Locale = .current) -> (minuteOfDay: Int, detail: String) {
        let sleep = sleepPhrase(sleepMinutes: sleepMinutes, extraMinutes: extraMinutes)
        guard let rule = ruleMinute.map({ ($0 % 1_440 + 1_440) % 1_440 }) else { return (planMinute, "For \(sleep)") }
        let later = ((planMinute - rule) % 1_440 + 1_440) % 1_440
        let gap = min(later, 1_440 - later)
        if gap <= 5 { return (rule, "Your rule. It gives you \(sleep).") }
        let plan = LooprClockFormat.text(minuteOfDay: planMinute, locale: locale)
        // The plan is later than the rule: the rule leaves room. Earlier: the rule is short of what the night needs.
        return later < 720
            ? (rule, "Your rule. \(plan) would still give you \(sleep).")
            : (rule, "Your rule. For \(sleep), go to bed by \(plan).")
    }

    /// The alarm row's input. Nil when the alarm is off, so Today stays quiet. `weekday` is Foundation's, with Sunday as 1.
    static func alarm(_ plan: WakeAlarmPlan?, weekday: Int) -> TodayAlarmFact? {
        guard let plan, plan.isEnabled else { return nil }
        let tomorrow = weekday % 7 + 1
        return TodayAlarmFact(wakeMinute: plan.wakeMinute, windowMinutes: plan.smartWindowMinutes,
                              ringsToday: plan.weekdays.contains { $0.calendarWeekday == weekday },
                              ringsTomorrow: plan.weekdays.contains { $0.calendarWeekday == tomorrow })
    }

    /// The bedtime and sleep minutes of Sleep's Tonight card, so Today's timeline shows the same time.
    static func bedtime(_ plan: SleepTonightPlan?) -> (minuteOfDay: Int, sleepMinutes: Double)? {
        guard let plan else { return nil }
        return (minuteOfDay: ((Int(plan.bedtime.rounded()) + 720) % 1_440 + 1_440) % 1_440, sleepMinutes: plan.sleepMinutes)
    }

    // MARK: Pattern

    /// The strongest pattern that is not already under test. Nothing when Patterns is off, empty, or every
    /// pattern is the one being tested.
    static func patternCard(_ snapshot: PatternsSnapshot?, enabled: Bool, locale: Locale = .current) -> TodayPatternCard? {
        guard enabled, let snapshot else { return nil }
        let tested = Set(snapshot.running.map(\.candidateID))
        guard let pattern = snapshot.found.first(where: { !tested.contains($0.candidateID) }) else { return nil }
        return TodayPatternCard(
            id: pattern.candidateID, strengthLabel: pattern.strength.label, title: PatternsCopy.headline(pattern, locale: locale),
            detail: PatternCopy.counts(for: pattern, locale: locale), nightsLine: "From your last \(pattern.nights.total) nights",
            canStartTest: snapshot.running.isEmpty)
    }

    // MARK: Reminders

    /// A running test's daily reminder, as a timeline moment.
    static func reminders(_ snapshot: PatternsSnapshot?, enabled: Bool, locale: Locale = .current) -> [TodayReminderFact] {
        guard enabled, let snapshot else { return [] }
        return snapshot.running.compactMap { test in
            guard let reminder = test.reminder, reminder.enabled else { return nil }
            return TodayReminderFact(id: test.id.uuidString.lowercased(), minuteOfDay: reminder.minuteOfDay,
                                     title: "Pattern check-in", detail: PatternsCopy.title(test, locale: locale))
        }
    }

    /// A whole number through the app's one number formatter, as the dial's steps tile writes it, so "1,240 kcal" and
    /// "9,812 steps" never use two separators on one screen (ICP R2-OPT-9).
    private static func number(_ value: Double) -> String {
        LooprUnitFormatter.number(value) ?? String(Int(value))
    }
}
