import CryptoKit
import DesignSystem
import DomainKit
import Foundation
import RoutineKit

// The Rules segment (LV-07.4) as pure values: the rules grouped by time of day, the draft the rule editor changes, the
// version history, the pass card and the import review. The views in ProtocolRulesViews.swift draw these.

// MARK: - Rules list

/// The part of the day a rule belongs to. An evening rule is in the evening whatever its time.
public enum ProtocolRulePart: String, CaseIterable, Sendable {
    case morning, afternoon, evening, anyTime = "any-time"

    public var title: String {
        switch self {
        case .morning: "Morning"
        case .afternoon: "Afternoon"
        case .evening: "Evening"
        case .anyTime: "Any time"
        }
    }

    public static func of(_ rule: ProtocolRule) -> ProtocolRulePart {
        if rule.isEvening { return .evening }
        guard let minute = rule.timeOfDayMinutes else { return .anyTime }
        if minute < 12 * 60 { return .morning }
        if minute < 17 * 60 { return .afternoon }
        return .evening
    }
}

public struct ProtocolRuleRow: Equatable, Sendable, Identifiable {
    public var id: RuleKey { rule.key }
    public let rule: ProtocolRule
    /// The title with its time in the locale's clock: "Screens off by 9:45 pm" in en_US (ICP R1-OPT-9).
    public let title: String
    /// Why the rule is on the list, one short line under the title (ICP R1-NEW-02). Nil when it has none.
    public let why: String?
    /// How often, whether it is off today and how far a longer rule has come: "Mon, Wed, Fri · not today",
    /// "Each week · 112 of 150 min · 6 days left", "Every 3 months · last done 12 Sep · due 12 Dec". Nil for a rule due
    /// every day (ICP R1-HAB-02, R1-VET-08, R1-VET-23).
    public let schedule: String?
    /// "Every day · checked by the band", for the read-only lists: an old version and a file's rules.
    public let caption: String
    /// The rule's reminder time, when the person turned one on.
    public let reminderMinute: Int?
    /// "Reminder 13:30". A time shows on the row only as a reminder, so it never reads against the rule's own words
    /// (ICP R1-DES-07, R1-NEW-11).
    public let reminderText: String?
    /// This week, Monday to Sunday, for a rule checked day by day (ICP R2-HAB-05, R2-DES-15). Empty for a rule with a
    /// longer period, whose `schedule` says how far it has come instead, and for the read-only lists.
    public let weekDots: [ProtocolRuleWeekDot]
    /// Days kept in a row up to today, or up to yesterday while today is still open.
    public let run: Int
    /// "Under test, night 9 of 14" while an experiment tests the rule (ICP R3-NEW-10, R3-VET-12). Nil otherwise.
    public var testText: String? = nil
    /// A weekly amount as a share of its target, 0 to 1, for the thin bar under the row (ICP R3-VET-09). Nil for every
    /// other rule, and while the source has measured nothing this week.
    public var weekShare: Double? = nil

    public init(rule: ProtocolRule, title: String, why: String? = nil, schedule: String? = nil, caption: String,
                reminderMinute: Int? = nil, reminderText: String? = nil, weekDots: [ProtocolRuleWeekDot] = [], run: Int = 0,
                testText: String? = nil, weekShare: Double? = nil) {
        self.rule = rule; self.title = title; self.why = why; self.schedule = schedule; self.caption = caption
        self.reminderMinute = reminderMinute; self.reminderText = reminderText; self.weekDots = weekDots; self.run = run
        self.testText = testText; self.weekShare = weekShare
    }

    /// The run shows from 3 days on: "5 days in a row". Fewer is not a run yet.
    public static let shortestRunShown = 3

    /// "5 days in a row", or nil under three.
    public var runText: String? { run >= Self.shortestRunShown ? "\(run) days in a row" : nil }

    /// "This week: Mon kept, Tue not answered yet, Wed to Sun still to come."
    public var weekAccessibilityLabel: String? {
        guard !weekDots.isEmpty else { return nil }
        let days = weekDots.map { "\($0.dayName) \($0.state.spokenName)" }
        return "This week: " + days.joined(separator: ", ")
    }

    /// "You", "Food", "Band": the chip that says who checks the rule.
    public var sourceChip: String { ProtocolRulesPresentation.sourceChip(rule.source) }
    public var sourceSymbol: String { ProtocolRulesPresentation.sourceSymbol(rule.source) }

    public var accessibilityLabel: String {
        var parts = [title]
        if let why { parts.append(why) }
        parts.append(ProtocolAutoFill.capitalizedFirst(ProtocolRulesPresentation.sourceText(rule.source)))
        if let testText { parts.append(testText) }
        if let reminderText { parts.append(reminderText) }
        if let schedule { parts.append(schedule.replacingOccurrences(of: " \u{00B7} ", with: ", ")) }
        if let runText { parts.append(runText) }
        if let weekAccessibilityLabel { parts.append(weekAccessibilityLabel) }
        if rule.isEvening, rule.rebuttal != nil { parts.append("Has your line for the morning") }
        return parts.joined(separator: ". ")
    }
}

/// One day of a rule's week on its row: seven small dots, Monday first.
public struct ProtocolRuleWeekDot: Equatable, Sendable, Identifiable {
    public enum State: String, Equatable, Sendable {
        case kept, missed, skipped
        /// Today, still to answer or to be checked.
        case open
        /// A past day nobody could check. Never drawn as a miss.
        case unknown
        /// A day the rule is not due on, or a day before the protocol.
        case off
        /// A day still to come.
        case future

        /// The words VoiceOver reads for the dot.
        public var spokenName: String {
            switch self {
            case .kept: "kept"
            case .missed: "not kept"
            case .skipped: "skipped"
            case .open: "not answered yet"
            case .unknown: "not known"
            case .off: "not due"
            case .future: "still to come"
            }
        }
    }

    public var id: String { day.routineDayKey ?? dayName }
    public let day: DayIdentity
    /// "Mon".
    public let dayName: String
    public let state: State
    public let isToday: Bool

    public init(day: DayIdentity, dayName: String, state: State, isToday: Bool = false) {
        self.day = day; self.dayName = dayName; self.state = state; self.isToday = isToday
    }
}

/// A rule's week and its run, from the week the Check-in counts (`ProtocolRoutineData.week` and `lastWeek`), so the
/// Rules row and the Check-in never disagree about a day.
public enum ProtocolRuleWeek {
    /// The seven dots of `week` for `key`. Empty for a rule with a longer period, or without a full week.
    public static func dots(for rule: ProtocolRule, week: [ProtocolDayInput]) -> [ProtocolRuleWeekDot] {
        guard week.count == 7, rule.cadence?.isDaily ?? true else { return [] }
        return week.map { input in
            let name = RuleWeekday(day: input.day).map(ProtocolRulesPresentation.dayName) ?? ""
            let item = input.rules.first { $0.rule.key == rule.key }
            return ProtocolRuleWeekDot(day: input.day, dayName: name, state: state(item, phase: input.phase, due: rule.isDue(on: input.day)),
                                       isToday: input.phase == .today)
        }
    }

    static func state(_ item: ProtocolRuleDay?, phase: ProtocolDayPhase, due: Bool) -> ProtocolRuleWeekDot.State {
        switch phase {
        case .future: return due ? .future : .off
        case .beforeProtocol: return item?.state == .kept ? .kept : .off
        case .past, .today:
            guard let item else { return due ? (phase == .today ? .open : .unknown) : .off }
            switch item.state {
            case .kept?: return .kept
            case .missed?: return .missed
            case .skipped?: return .skipped
            case .unknown?: return phase == .today ? .open : .unknown
            case .pending?, nil: return phase == .today ? .open : .unknown
            }
        }
    }

    /// Days kept in a row, counted back from today over this week and last week. Today counts once kept and is passed
    /// over while open. A day the rule is not due on, or a skipped day, is passed over too: it neither adds nor breaks.
    /// A missed day, or a past day nobody could check, ends the run.
    public static func run(for rule: ProtocolRule, week: [ProtocolDayInput], lastWeek: [ProtocolDayInput]) -> Int {
        guard rule.cadence?.isDaily ?? true else { return 0 }
        let days = (lastWeek + week).filter { $0.phase != .future }
        var count = 0
        for input in days.reversed() {
            switch state(input.rules.first { $0.rule.key == rule.key }, phase: input.phase, due: rule.isDue(on: input.day)) {
            case .kept: count += 1
            case .open, .off, .skipped, .future: continue
            case .missed, .unknown: return count
            }
        }
        return count
    }
}

public struct ProtocolRuleSection: Equatable, Sendable, Identifiable {
    public var id: String { part.rawValue }
    public let part: ProtocolRulePart
    public let rows: [ProtocolRuleRow]
    public var title: String { part.title }
}

public enum ProtocolRulesPresentation {
    /// Morning, afternoon, evening, then any time. Inside a part, rules with a time come earliest first, then the
    /// version's order. Parts without rules are left out. `today` marks a rule on chosen days that is off today, and
    /// `progress` holds how far each longer rule has come.
    public static func sections(_ rules: [ProtocolRule], reminders: [RuleKey: Int] = [:], progress: [RuleKey: RuleProgress] = [:],
                                today: DayIdentity? = nil, week: [ProtocolDayInput] = [], lastWeek: [ProtocolDayInput] = [],
                                tests: [RuleKey: String] = [:], locale: Locale = .current) -> [ProtocolRuleSection] {
        let indexed = Array(rules.enumerated())
        return ProtocolRulePart.allCases.compactMap { part in
            let members = indexed.filter { ProtocolRulePart.of($0.element) == part }.sorted { lhs, rhs in
                switch (lhs.element.timeOfDayMinutes, rhs.element.timeOfDayMinutes) {
                case let (left?, right?): left == right ? lhs.offset < rhs.offset : left < right
                case (_?, nil): true
                case (nil, _?): false
                case (nil, nil): lhs.offset < rhs.offset
                }
            }
            guard !members.isEmpty else { return nil }
            return ProtocolRuleSection(part: part, rows: members.map { _, rule in
                var made = row(rule, reminderMinute: reminders[rule.key], progress: progress[rule.key], today: today, week: week,
                               lastWeek: lastWeek, locale: locale)
                made.testText = tests[rule.key]
                return made
            })
        }
    }

    /// One rule as the Rules list shows it. `week` and `lastWeek` give its dots and its run; without them the row has
    /// neither, as in the read-only lists.
    public static func row(_ rule: ProtocolRule, reminderMinute: Int? = nil, progress: RuleProgress? = nil, today: DayIdentity? = nil,
                           week: [ProtocolDayInput] = [], lastWeek: [ProtocolDayInput] = [], locale: Locale = .current) -> ProtocolRuleRow {
        return ProtocolRuleRow(rule: rule, title: rule.displayTitle(locale: locale), why: ProtocolRule.shortLine(rule.why),
                               schedule: schedule(rule, progress: progress, today: today, locale: locale),
                               caption: caption(rule, locale: locale), reminderMinute: reminderMinute,
                               reminderText: reminderMinute.map { "Reminder \(LooprClockFormat.text(minuteOfDay: $0, locale: locale))" },
                               weekDots: ProtocolRuleWeek.dots(for: rule, week: week),
                               run: week.isEmpty ? 0 : ProtocolRuleWeek.run(for: rule, week: week, lastWeek: lastWeek),
                               weekShare: weekShare(progress))
    }

    /// How much of a weekly amount is done, 0 to 1. Nil without a measured amount, so nothing is drawn as zero.
    public static func weekShare(_ progress: RuleProgress?) -> Double? {
        guard case .amount(let measured?, let target, _)? = progress, target > 0, measured.isFinite else { return nil }
        return min(max(measured / target, 0), 1)
    }

    /// "Under test, night 9 of 14" for the rule a running experiment tests, by rule key (ICP R3-NEW-10, R3-VET-12). The
    /// night is the one ahead, as the Experiments segment counts it.
    public static func testTexts(running: ProtocolExperimentItem?) -> [RuleKey: String] {
        guard let running, running.experiment.status == .running else { return [:] }
        let planned = running.report.plannedNights
        let night = min(running.report.nightsCompleted + 1, planned)
        return [running.experiment.start.ruleKey: "Under test, night \(night) of \(planned)"]
    }

    /// "Every day · checked by the band", with the first letter in capitals. No time: a rule's time is when it reminds,
    /// and the name already says any time the rule is about (ICP R1-DES-07).
    public static func caption(_ rule: ProtocolRule, locale: Locale = .current) -> String {
        ProtocolAutoFill.capitalizedFirst([cadenceText(rule.cadence), sourceText(rule.source)].joined(separator: " \u{00B7} "))
    }

    /// "Mon, Wed, Fri · not today", "Each week · 112 of 150 min · 6 days left". Nil for a rule due every day.
    public static func schedule(_ rule: ProtocolRule, progress: RuleProgress?, today: DayIdentity?, locale: Locale = .current) -> String? {
        guard let cadence = rule.cadence, !cadence.isEveryDay else { return nil }
        var parts = [ProtocolAutoFill.capitalizedFirst(cadenceText(cadence))]
        if let today, !rule.isDue(on: today) { parts.append("not today") }
        if let progress { parts.append(progressText(progress, today: today, locale: locale)) }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// "every day", "Mon, Wed, Fri", "weekdays", "3 times a week", "each week", "every 6 months".
    public static func cadenceText(_ cadence: RuleCadence?) -> String {
        guard let cadence, !cadence.isEveryDay else { return "every day" }
        if cadence.hasChosenDays { return daysText(cadence.days) }
        if let times = cadence.timesPerWeek { return "\(times) times a week" }
        let every = cadence.every
        switch cadence.unit {
        case .day: return "every \(every) days"
        case .week: return every == 1 ? "each week" : "every \(every) weeks"
        case .month: return every == 1 ? "each month" : every == 12 ? "every year" : "every \(every) months"
        }
    }

    /// "Mon, Wed, Fri". Monday to Friday is "weekdays" and Saturday with Sunday "weekends".
    public static func daysText(_ days: [RuleWeekday]) -> String {
        let set = Set(days)
        if set == [.monday, .tuesday, .wednesday, .thursday, .friday] { return "weekdays" }
        if set == [.saturday, .sunday] { return "weekends" }
        return set.sorted().map(dayName).joined(separator: ", ")
    }

    /// "Mon".
    public static func dayName(_ day: RuleWeekday) -> String {
        switch day {
        case .monday: "Mon"
        case .tuesday: "Tue"
        case .wednesday: "Wed"
        case .thursday: "Thu"
        case .friday: "Fri"
        case .saturday: "Sat"
        case .sunday: "Sun"
        }
    }

    /// "112 of 150 min · 6 days left", "done 2 of 3 times this week", "last done 12 Sep · due 12 Dec".
    public static func progressText(_ progress: RuleProgress, today: DayIdentity?, locale: Locale = .current) -> String {
        switch progress {
        case .amount(let measured?, let target, let unit):
            let suffix = (unit ?? "").isEmpty ? "" : " \(unit ?? "")"
            let amount = "\(RoutineRuleTitle.amountText(measured)) of \(RoutineRuleTitle.amountText(target))\(suffix)"
            // How long the week still runs, so a weekly total reads as a pace (ICP R3-VET-09).
            if measured >= target { return "\(amount) \u{00B7} done this week" }
            guard let left = today.flatMap(daysLeftInWeek) else { return "\(amount) this week" }
            return "\(amount) \u{00B7} " + (left == 1 ? "last day" : "\(left) days left")
        case .amount(nil, _, _):
            return "nothing measured this week yet"
        case .times(let done, 1):
            return done > 0 ? "done this week" : "not done this week yet"
        case .times(let done, let target):
            return "done \(min(done, target)) of \(target) times this week"
        case .due(let last?, let next?):
            let overdue = today.map { key(next) < key($0) } ?? false
            return "last done \(dateText(last, locale: locale)) \u{00B7} \(overdue ? "was due" : "due") \(dateText(next, locale: locale))"
        case .due(let last?, nil):
            return "last done \(dateText(last, locale: locale))"
        case .due(nil, _):
            return "not done yet"
        }
    }

    /// Days of the Monday to Sunday week from `day` to Sunday, `day` included: 7 on a Monday, 1 on a Sunday.
    public static func daysLeftInWeek(_ day: DayIdentity) -> Int? {
        RuleWeekday(day: day).map { 8 - $0.isoNumber }
    }

    /// "12 Dec", in the locale's order.
    public static func dateText(_ day: DayIdentity, locale: Locale) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day)) else { return "" }
        var style = Date.FormatStyle.dateTime.day().month(.abbreviated).locale(locale)
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    private static func key(_ day: DayIdentity) -> String { day.routineDayKey ?? "" }

    /// "you tick it" or "checked by Food".
    public static func sourceText(_ source: CheckSource) -> String {
        source == .manual ? "you tick it" : "checked by \(ProtocolAutoFill.name(source))"
    }

    /// The check source's name in a picker: "You tick it", "Food", "The band".
    public static func sourceTitle(_ source: CheckSource) -> String {
        source == .manual ? "You tick it" : ProtocolAutoFill.capitalizedFirst(ProtocolAutoFill.name(source))
    }

    /// The short name on a rule's chip and in the editor's choices: "You", "Band", "Food", "Fitness", "Apple Health".
    public static func sourceChip(_ source: CheckSource) -> String {
        switch source {
        case .manual: "You"
        case .band: "Band"
        case .food: "Food"
        case .fitness: "Fitness"
        case .appleHealth: "Apple Health"
        }
    }

    /// The SF Symbol beside the chip's name.
    public static func sourceSymbol(_ source: CheckSource) -> String {
        switch source {
        case .manual: "hand.tap"
        case .band: "dot.radiowaves.left.and.right"
        case .food: "fork.knife"
        case .fitness: "figure.run"
        case .appleHealth: "heart.text.square"
        }
    }

    /// One line under the editor's "Checked by" choices, so a beginner knows what the pick does.
    public static func sourceHelp(_ source: CheckSource) -> String {
        switch source {
        case .manual: "You tick it in the check-in."
        case .band: "Loopr reads your band and ticks it for you."
        case .food: "Loopr reads what you log in Food and ticks it for you."
        case .fitness: "Loopr reads your workouts in Fitness and ticks it for you."
        case .appleHealth: "Loopr reads Apple Health and ticks it for you."
        }
    }

    public static func groupTitle(_ group: RuleGroup) -> String {
        switch group {
        case .sleep: "Sleep"
        case .food: "Food"
        case .fitness: "Fitness"
        case .supplements: "Supplements"
        case .tests: "Tests"
        case .custom: "Other"
        }
    }

    public static func metricTitle(_ metric: RoutineMetric) -> String {
        switch metric {
        case .proteinG: "Protein"
        case .fibreG: "Fibre"
        case .energyKcal: "Energy"
        case .lastMealTime: "Last meal"
        case .alcoholDrinks: "Alcohol"
        case .lastCaffeineTime: "Last caffeine"
        case .supplementsAllTaken: "Every supplement taken"
        case .medicationAllTaken: "Every medication taken"
        case .supplementAdherence: "Supplement doses taken"
        case .sleepOnsetTime: "Asleep by"
        case .inBedTime: "In bed by"
        case .zone2Minutes: "Zone 2 minutes"
        case .zone45Minutes: "Hard minutes, zones 4 and 5"
        case .sleepHR: "Sleeping heart rate"
        case .strengthSessions: "Strength sessions"
        case .mobilitySessions: "Mobility sessions"
        case .workoutMinutes: "Workout minutes"
        case .steps: "Steps"
        case .daylightMinutes: "Daylight minutes"
        case .vo2max: "VO\u{2082}max"
        case .weightKg: "Weight"
        case .done: "Done or not"
        }
    }

    /// What a measure is about, short enough for "You already have a Zone 2 rule." (ICP R3-VET-05).
    public static func measureName(_ metric: RoutineMetric) -> String {
        switch metric {
        case .proteinG: "protein"
        case .fibreG: "fibre"
        case .energyKcal: "energy"
        case .lastMealTime: "last meal"
        case .alcoholDrinks: "alcohol"
        case .lastCaffeineTime: "caffeine"
        case .supplementsAllTaken, .supplementAdherence: "supplements"
        case .medicationAllTaken: "medication"
        case .sleepOnsetTime: "sleep time"
        case .inBedTime: "bedtime"
        case .zone2Minutes: "Zone 2"
        case .zone45Minutes: "hard minutes"
        case .sleepHR: "sleeping heart rate"
        case .strengthSessions: "strength"
        case .mobilitySessions: "mobility"
        case .workoutMinutes: "workout"
        case .steps: "steps"
        case .daylightMinutes: "daylight"
        case .vo2max: "VO\u{2082}max"
        case .weightKg: "weight"
        case .done: "matching"
        }
    }

    public static func unitLabel(_ unit: RoutineMetricUnit) -> String {
        switch unit {
        case .grams: "g"
        case .kilocalories: "kcal"
        case .drinks: "drinks"
        case .minutes: "min"
        case .sessions: "sessions"
        case .steps: "steps"
        case .mlPerKgPerMin: "ml/kg/min"
        case .kilograms: "kg"
        case .beatsPerMinute: "bpm"
        case .minutesAfterMidnight: "min"
        case .tick: ""
        case .fraction: ""
        }
    }

    public static func targetKindTitle(_ kind: RuleTargetKind) -> String {
        switch kind {
        case .done: "Done"
        case .atLeast: "At least"
        case .atMost: "At most"
        case .exactly: "Exactly"
        }
    }
}

// MARK: - Rule editor draft

/// What the rule editor changes. Nothing is saved until the person taps Save, which writes the next version.
public struct ProtocolRuleDraft: Equatable, Sendable {
    public static let defaultEveningMinute = 21 * 60

    /// The editor's four ways to say which days a rule is due (ICP R1-HAB-02).
    public enum DaysMode: String, CaseIterable, Sendable {
        case everyDay = "every-day", someDays = "some-days", timesAWeek = "times-a-week", lessOften = "less-often"

        public var title: String {
            switch self {
            case .everyDay: "Every day"
            case .someDays: "Some days"
            case .timesAWeek: "A few times a week"
            case .lessOften: "Once a week or less"
            }
        }
    }

    /// The field a problem is about, so the editor shows the hint next to it (ICP R1-DES-20).
    public enum Field: Sendable { case name, why, days, target, reason }

    /// Nil while adding a rule.
    public let originalKey: RuleKey?
    public var title: String
    /// Why the rule is on the list. Optional, on every rule, up to 280 characters (ICP R1-VET-22).
    public var why: String
    public var group: RuleGroup
    public var source: CheckSource
    public var metric: RoutineMetric
    public var targetKind: RuleTargetKind
    /// The target amount. For a time-of-day metric, minutes after midnight on the clock (0 to 1439).
    public var value: Double?
    public var hasTime: Bool
    public var minuteOfDay: Int
    public var isEvening: Bool
    public var rebuttal: String
    public var daysMode: DaysMode
    /// The weekdays for "Some days".
    public var chosenDays: Set<RuleWeekday>
    /// The count for "Times a week".
    public var timesPerWeek: Int
    /// The period for "Less often": each week, every 2 weeks, every 3 months and so on.
    public var cadenceUnit: RuleCadence.Unit
    public var cadenceEvery: Int
    /// The person wants the reminder at the rule's time.
    public var remindMe: Bool
    /// Delete was tapped. Save then writes a version without the rule, and Undo takes it back.
    public var isRemoved = false
    /// A metric outside the vocabulary's cases, such as `supplement_taken:magnesium`, kept as it was until the person
    /// picks another source or metric.
    public private(set) var keptMetric: String?
    private var keptUnit: String?
    private let untouched: ProtocolRule?
    /// The amount the name carries now, once an edit moved it.
    private var titleAmount: Double?
    private let initialRemind: Bool
    private var isNew = false

    public init(rule: ProtocolRule, remindMe: Bool = false) {
        originalKey = rule.key
        untouched = rule
        title = rule.title
        why = rule.why ?? ""
        group = rule.group
        source = rule.source
        let known = rule.target.metric.flatMap(RoutineMetric.init(rawValue:))
        metric = known ?? (rule.source == .manual ? .done : RoutineMetric.metrics(for: rule.source).first ?? .done)
        keptMetric = known == nil ? rule.target.metric : nil
        keptUnit = known == nil ? rule.target.unit : nil
        targetKind = rule.target.kind
        value = rule.target.value.map { known?.isTimeOfDay == true ? Double(Int($0) % 1_440) : $0 }
        hasTime = rule.timeOfDayMinutes != nil
        minuteOfDay = rule.timeOfDayMinutes ?? (rule.isEvening ? Self.defaultEveningMinute : 8 * 60)
        isEvening = rule.isEvening
        rebuttal = rule.rebuttal ?? ""
        let cadence = rule.cadence
        chosenDays = Set(cadence?.days ?? [])
        timesPerWeek = cadence?.timesPerWeek ?? 3
        if let cadence, !cadence.isEveryDay {
            daysMode = cadence.hasChosenDays ? .someDays : cadence.timesPerWeek != nil ? .timesAWeek : .lessOften
        } else {
            daysMode = .everyDay
        }
        let plain = cadence.map { !$0.isDaily && $0.timesPerWeek == nil } ?? false
        cadenceUnit = plain ? cadence?.unit ?? .week : .week
        cadenceEvery = plain ? cadence?.every ?? 1 : 1
        self.remindMe = remindMe
        initialRemind = remindMe
    }

    /// "045" to "45", "00.5" to "0.5". A lone "0" stays.
    public static func trimmingLeadingZeros(_ text: String) -> String {
        var rest = Substring(text)
        while rest.count > 1, rest.first == "0", let next = rest.dropFirst().first, next.isNumber { rest = rest.dropFirst() }
        return String(rest)
    }

    /// A new manual rule with no time.
    public static func newRule() -> ProtocolRuleDraft {
        var draft = ProtocolRuleDraft(rule: ProtocolRule(key: "new", title: ""))
        draft.isNew = true
        return draft
    }

    public var isAdding: Bool { isNew }

    /// "Where this comes from", as the template or file wrote it. The editor shows it read only, so a year on the
    /// person can still see where a rule came from (ICP R3-VET-08, R3-NEW-10). Nil for a rule without one.
    public var evidence: String? {
        guard let text = untouched?.evidence?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// The metrics a source can measure, in the vocabulary's order. A manual rule has `done` only.
    public static func metrics(for source: CheckSource) -> [RoutineMetric] { RoutineMetric.metrics(for: source) }

    /// Picks a source and its first metric. A manual rule is done or not; a measured one starts at "at least".
    public mutating func setSource(_ newSource: CheckSource) {
        guard newSource != source else { return }
        source = newSource
        keptMetric = nil; keptUnit = nil
        metric = Self.metrics(for: newSource).first ?? .done
        if newSource == .manual { targetKind = .done; value = nil } else if targetKind == .done { targetKind = .atLeast }
        if targetKind != .done, value == nil { value = metric.isTimeOfDay ? Double(minuteOfDay) : 0 }
    }

    public mutating func setMetric(_ newMetric: RoutineMetric) {
        guard newMetric != metric || keptMetric != nil else { return }
        metric = newMetric
        keptMetric = nil; keptUnit = nil
        if targetKind != .done { value = newMetric.isTimeOfDay ? Double(minuteOfDay) : 0 }
    }

    public var unitLabel: String { ProtocolRulesPresentation.unitLabel(metric.unit) }

    /// True when the time in the rule's name stands for the target, as in "In bed by 22:30"; otherwise it stands for the
    /// rule's own time, as in "Screens off by 21:45".
    public var titleFollowsTarget: Bool { keptMetric == nil && targetKind != .done && metric.isTimeOfDay }

    /// The rule's own time moved on the wheel. A time in the name that stands for it moves the same amount, so the name
    /// never says 21:45 after the rule moved to 22:00 (ICP R1-OPT-9).
    public mutating func setMinuteOfDay(_ minute: Int) {
        let before = minuteOfDay
        minuteOfDay = minute
        if !titleFollowsTarget { title = RoutineRuleTitle.shiftingTime(in: title, by: minute - before) }
    }

    /// The amount typed for the target. A number in the name that stands for it follows, so "Zone 2, 45 min" reads
    /// "Zone 2, 50 min" once the amount is 50 (ICP R2-OPT-5). An empty field leaves the name alone until a number comes.
    public mutating func setAmount(_ newValue: Double?) {
        value = newValue
        guard let newValue, newValue.isFinite, let shown = titleAmount ?? untouched?.target.value, shown.isFinite else { return }
        let renamed = RoutineRuleTitle.replacingAmount(in: title, from: shown, to: newValue)
        if renamed != title || shown == newValue {
            title = renamed
            titleAmount = newValue
        }
    }

    /// The target time moved on its wheel. A time in the name that stands for the target moves with it.
    public mutating func setTargetMinute(_ minute: Int) {
        let before = value.map { Int($0) % 1_440 }
        value = Double(minute)
        if titleFollowsTarget, let before { title = RoutineRuleTitle.shiftingTime(in: title, by: minute - before) }
    }

    /// The name as the rest of the app shows it, when that differs from what is typed: "Screens off by 9:45 pm" for
    /// "Screens off by 21:45" in a 12-hour locale. Nil when they read the same.
    public func shownTitle(locale: Locale) -> String? {
        let typed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = LooprClockFormat.localizing(typed, locale: locale)
        return shown == typed ? nil : shown
    }

    public var trimmedRebuttal: String { rebuttal.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// True when the editor offers "Also ask me, even when it is checked for me": only on a rule a source checks. A rule
    /// the person ticks is always asked, so it has no switch to contradict (ICP R2-NEW-05, R2-SEN-08, R2-HAB-07).
    public var offersAlsoAsk: Bool { source != .manual }

    /// True when the morning line is kept: on a rule the person ticks, or a source rule they also answer.
    public var keepsMorningLine: Bool { source == .manual || isEvening }

    /// The evening flag the rule is saved with. A rule the person ticks keeps its own, and becomes an evening rule once
    /// it has a line for the morning, since that line is what the evening reminder quotes.
    var savedIsEvening: Bool { source == .manual ? isEvening || !trimmedRebuttal.isEmpty : isEvening }

    /// The editor's first line, over Name, Why and Days, so the folded options are never a surprise (ICP R2-HAB-08):
    /// "Every day at 21:45. You tick it in the check-in. Reminder on."
    public func summary(locale: Locale) -> String {
        var when = ProtocolAutoFill.capitalizedFirst(ProtocolRulesPresentation.cadenceText(cadence))
        if daysMode == .someDays, chosenDays.isEmpty { when = "No days picked yet" }
        if hasTime { when += " at \(LooprClockFormat.text(minuteOfDay: minuteOfDay, locale: locale))" }
        var parts = [when + "."]
        if source == .manual {
            parts.append("You tick it in the check-in.")
        } else {
            parts.append("\(ProtocolAutoFill.capitalizedFirst(ProtocolAutoFill.name(source))) checks it for you.")
            if isEvening { parts.append("You answer it too.") }
        }
        if remindMe { parts.append("Reminder on.") }
        return parts.joined(separator: " ")
    }
    public var trimmedWhy: String { why.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// What "More options" holds, in one line: "Protein, at least 150 g. Group Food." A tick rule shows its group only.
    public func optionsSummary(locale: Locale) -> String {
        var parts: [String] = []
        if source != .manual {
            let measure = keptMetric ?? ProtocolRulesPresentation.metricTitle(metric)
            if targetKind == .done || value == nil {
                parts.append(measure)
            } else if let value {
                let amount = metric.isTimeOfDay
                    ? LooprClockFormat.text(minuteOfDay: Int(value) % 1_440, locale: locale)
                    : "\(RoutineRuleTitle.amountText(value))\(unitLabel.isEmpty ? "" : " \(unitLabel)")"
                parts.append("\(measure), \(ProtocolRulesPresentation.targetKindTitle(targetKind).lowercased()) \(amount)")
            }
        }
        parts.append("Group \(ProtocolRulesPresentation.groupTitle(group))")
        return parts.map { $0 + "." }.joined(separator: " ")
    }

    /// The "How often" row's value: "Every day", "Mon, Wed, Fri", "3 times a week", "Every 3 months" (ICP R3-DES-07).
    public var cadenceSummary: String {
        if daysMode == .someDays, chosenDays.isEmpty { return "No days picked yet" }
        return ProtocolAutoFill.capitalizedFirst(ProtocolRulesPresentation.cadenceText(cadence))
    }

    /// The cadence the draft describes. Nil is every day.
    public var cadence: RuleCadence? {
        switch daysMode {
        case .everyDay: return nil
        case .someDays: return chosenDays.isEmpty ? nil : RuleCadence.on(chosenDays).nilIfEveryDay
        case .timesAWeek: return RuleCadence.timesAWeek(timesPerWeek).nilIfEveryDay
        case .lessOften: return RuleCadence(unit: cadenceUnit, every: cadenceEvery).nilIfEveryDay
        }
    }

    /// Why Save is off, in plain words. Nil when the draft can be saved.
    public var problem: String? { issue?.text }

    /// The field Save waits on, shown beside that field.
    public var problemField: Field? { issue?.field }

    private var issue: (field: Field, text: String)? {
        if isRemoved { return nil }
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return (.name, "Give the rule a name.") }
        if title.count > ProtocolFile.maximumTitleLength { return (.name, "Keep the name to \(ProtocolFile.maximumTitleLength) characters.") }
        if trimmedWhy.count > ProtocolFile.maximumWhyLength { return (.why, "Keep why to \(ProtocolFile.maximumWhyLength) characters.") }
        if daysMode == .someDays, chosenDays.isEmpty { return (.days, "Pick at least one day.") }
        if targetKind != .done, value?.isFinite != true || (value ?? -1) < 0 { return (.target, "Set a target amount.") }
        if keepsMorningLine, rebuttal.count > ProtocolFile.maximumRebuttalLength {
            return (.reason, "Keep your reason to \(ProtocolFile.maximumRebuttalLength) characters.")
        }
        return nil
    }

    /// True when Save would write something: a removal, a new rule, a changed rule, or a reminder switched.
    public var canSave: Bool {
        guard problem == nil else { return false }
        if isRemoved || isNew || remindMe != initialRemind { return true }
        return rule(key: originalKey ?? "new").normalized != untouched?.normalized
    }

    /// True when only the reminder switch changed, so Save writes no version.
    public var onlyReminderChanged: Bool {
        !isRemoved && !isNew && remindMe != initialRemind && rule(key: originalKey ?? "new").normalized == untouched?.normalized
    }

    /// The rule this draft describes. The rebuttal is kept only on an evening rule, and a tick rule with one is an
    /// evening rule (`savedIsEvening`).
    public func rule(key: RuleKey) -> ProtocolRule {
        let amount: Double? = targetKind == .done ? nil : value.map { Self.storedValue($0, metric: metric) }
        let unit = keptMetric != nil ? keptUnit : (metric.unit == .tick || metric.unit == .fraction ? nil : ProtocolRulesPresentation.unitLabel(metric.unit))
        let target: RuleTarget
        if let untouched, keptMetric == nil, source == untouched.source, targetKind == untouched.target.kind,
           untouched.target.metric == metric.rawValue || (untouched.target.metric == nil && source == .manual),
           amount == untouched.target.value {
            target = untouched.target
        } else if source == .manual && targetKind == .done {
            target = .done
        } else {
            target = RuleTarget(kind: targetKind, metric: keptMetric ?? metric.rawValue, value: amount, unit: unit)
        }
        let reason = trimmedRebuttal
        let why = trimmedWhy
        let evening = savedIsEvening
        return ProtocolRule(key: key, title: title.trimmingCharacters(in: .whitespacesAndNewlines), group: group, target: target,
                            timeOfDayMinutes: hasTime ? minuteOfDay : nil, source: source, isEvening: evening,
                            rebuttal: evening && !reason.isEmpty ? reason : nil, cadence: cadence, why: why.isEmpty ? nil : why,
                            evidence: untouched?.evidence)
    }

    /// A night metric set before noon is the night after midnight: 00:30 is 1470 (docs/PROTOCOL_FILES.md).
    static func storedValue(_ value: Double, metric: RoutineMetric) -> Double {
        guard metric.isTimeOfDay else { return value }
        let isNight = metric == .sleepOnsetTime || metric == .inBedTime
        return isNight && value < 12 * 60 ? value + 1_440 : value
    }

    /// A key for a new rule from its title: "stretch", or "stretch-2" when taken. ASCII letters, digits and dashes.
    public static func newKey(title: String, existing: Set<RuleKey>) -> RuleKey {
        var slug = ""
        var lastWasDash = true
        for scalar in title.lowercased().unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                slug.unicodeScalars.append(scalar); lastWasDash = false
            } else if !lastWasDash {
                slug.append("-"); lastWasDash = true
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        let base = String((slug.isEmpty ? "rule" : slug).prefix(ProtocolFile.maximumKeyLength - 4))
        var candidate = RuleKey(rawValue: base)
        var number = 2
        while existing.contains(candidate) {
            candidate = RuleKey(rawValue: "\(base)-\(number)")
            number += 1
        }
        return candidate
    }
}

extension RuleCadence {
    /// Nil for every day, which a version stores as no cadence.
    var nilIfEveryDay: RuleCadence? { isEveryDay ? nil : self }
}

/// Applies a saved draft to the newest version's rules.
public enum ProtocolRuleEdit {
    /// The rules after the draft: the rule replaced in place, removed, or added at the end.
    public static func apply(_ draft: ProtocolRuleDraft, to rules: [ProtocolRule]) -> [ProtocolRule] {
        if draft.isAdding {
            let key = ProtocolRuleDraft.newKey(title: draft.title, existing: Set(rules.map(\.key)))
            return rules + [draft.rule(key: key)]
        }
        guard let key = draft.originalKey else { return rules }
        if draft.isRemoved { return rules.filter { $0.key != key } }
        return rules.map { $0.key == key ? draft.rule(key: key) : $0 }
    }
}

// MARK: - Version history

public struct ProtocolVersionEntry: Equatable, Sendable, Identifiable {
    public var id: Int { number }
    public let number: Int
    public let createdAt: Date
    /// What the version changed, in one line: "Changed Magnesium, 300 mg: time to 21:30 · Added Sauna", "Same rules as
    /// version 1", "First version, 10 rules" (ICP R2-VET-07).
    public let summary: String
    /// Why the version exists, when its note says more than what changed: the person's "Why this change?", a template,
    /// a file or a kept experiment. Nil for a note Loopr wrote from the changes alone.
    public let reason: String?
    public let ruleCount: Int
    public let isCurrent: Bool

    public init(number: Int, createdAt: Date, summary: String, reason: String? = nil, ruleCount: Int, isCurrent: Bool) {
        self.number = number; self.createdAt = createdAt; self.summary = summary; self.reason = reason
        self.ruleCount = ruleCount; self.isCurrent = isCurrent
    }

    public func dateText(locale: Locale, timeZone: TimeZone) -> String {
        var style = Date.FormatStyle.dateTime.day().month(.abbreviated).year().locale(locale)
        style.timeZone = timeZone
        return createdAt.formatted(style)
    }

    /// Newest first. Each entry says what changed against the version before it.
    public static func entries(_ versions: [ProtocolVersion], locale: Locale = .current) -> [ProtocolVersionEntry] {
        let ordered = versions.sorted { $0.number < $1.number }
        var result: [ProtocolVersionEntry] = []
        for (index, version) in ordered.enumerated() {
            let summary: String
            var reason = version.note?.trimmingCharacters(in: .whitespacesAndNewlines)
            if index == 0 {
                summary = "First version, \(version.rules.count) \(version.rules.count == 1 ? "rule" : "rules")"
            } else {
                let previous = ordered[index - 1]
                let changes = ProtocolVersionDiff.changes(from: previous.rules, to: version.rules)
                summary = ProtocolVersionDiff.rowSummary(changes, locale: locale) ?? "Same rules as version \(previous.number)"
                if ProtocolVersionDiff.isAutomaticNote(version.note, for: changes) { reason = nil }
            }
            result.append(ProtocolVersionEntry(number: version.number, createdAt: version.createdAt,
                                               summary: summary,
                                               reason: reason?.isEmpty == false ? reason.map { LooprClockFormat.localizing($0, locale: locale) } : nil,
                                               ruleCount: version.rules.count, isCurrent: index == ordered.count - 1))
        }
        return result.reversed()
    }
}

/// One line of what a version changed, in plain words: "Added: Sauna", or a changed rule's name with what moved.
public struct ProtocolVersionChangeLine: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case added, removed, changed }

    public var id: String { "\(kind.rawValue)-\(key.rawValue)" }
    public let kind: Kind
    public let key: RuleKey
    /// "Added: Sauna", "Removed: Late coffee", "Protein 160 g".
    public let title: String
    /// For a changed rule: "Protein 150 to 160 g. Time 21:45 to 22:05." Nil for an added or removed rule.
    public let detail: String?

    public var accessibilityLabel: String { [title, detail].compactMap { $0 }.joined(separator: ". ") }
}

/// A saved version against the one before it: what changed first, then the rules that stayed the same (ICP R1-VET-06,
/// R1-DES-16). Version 1 has nothing to compare with, so it lists its rules.
public struct ProtocolVersionDetail: Equatable, Sendable {
    public let number: Int
    /// The version this one is compared with. Nil for the first version.
    public let previousNumber: Int?
    /// The note saved with the version, such as "Started from the Sleep first template."
    public let note: String?
    public let changes: [ProtocolVersionChangeLine]
    /// The rules this version shares unchanged with the one before, or every rule of the first version.
    public let unchanged: [ProtocolRuleRow]

    /// "What changed from version 2".
    public var changesTitle: String { previousNumber.map { "What changed from version \($0)" } ?? "Rules" }
    /// "8 rules stayed the same".
    public var unchangedTitle: String {
        "\(unchanged.count) \(unchanged.count == 1 ? "rule" : "rules") stayed the same"
    }

    public static func make(_ version: ProtocolVersion, previous: ProtocolVersion?, locale: Locale = .current) -> ProtocolVersionDetail {
        guard let previous else {
            return ProtocolVersionDetail(number: version.number, previousNumber: nil, note: version.note, changes: [],
                                         unchanged: version.rules.map { ProtocolRulesPresentation.row($0, locale: locale) })
        }
        // A rebuttal is the person's own text and changes with every morning; it is still a change of the rule.
        let changes = ProtocolVersionDiff.changes(from: previous.rules, to: version.rules)
        let changed = Set(changes.map(\.key))
        return ProtocolVersionDetail(number: version.number, previousNumber: previous.number, note: version.note,
                                     changes: changes.map { line($0, locale: locale) },
                                     unchanged: version.rules.filter { !changed.contains($0.key) }
                                         .map { ProtocolRulesPresentation.row($0, locale: locale) })
    }

    static func line(_ change: ProtocolRuleChange, locale: Locale) -> ProtocolVersionChangeLine {
        switch change {
        case .added(let rule):
            return ProtocolVersionChangeLine(kind: .added, key: rule.key, title: "Added: \(rule.displayTitle(locale: locale))", detail: nil)
        case .removed(let rule):
            return ProtocolVersionChangeLine(kind: .removed, key: rule.key, title: "Removed: \(rule.displayTitle(locale: locale))", detail: nil)
        case .changed(let before, let after, let fields):
            let parts = fields.compactMap { sentence($0, before: before, after: after, locale: locale) }
            return ProtocolVersionChangeLine(kind: .changed, key: after.key, title: after.displayTitle(locale: locale),
                                             detail: parts.isEmpty ? nil : parts.map { $0 + "." }.joined(separator: " "))
        }
    }

    /// One field in a sentence: "Target 150 to 160 g", "Time 21:45 to 22:05", "Was every day, now Mon, Wed, Fri". Nil
    /// for a name that only followed its amount, which the target line already says.
    static func sentence(_ field: ProtocolRuleField, before: ProtocolRule, after: ProtocolRule, locale: Locale) -> String? {
        switch field {
        case .title:
            if let old = before.target.value, let new = after.target.value, old.isFinite, new.isFinite,
               RoutineRuleTitle.replacingAmount(in: before.title, from: old, to: new) == after.title { return nil }
            return "Was called \(before.displayTitle(locale: locale))"
        case .target:
            let named = ProtocolVersionDiff.name(.target, before: before, after: after)
            return named == ProtocolRuleField.target.name ? "Target changed" : ProtocolAutoFill.capitalizedFirst(named)
        case .time:
            switch (before.timeOfDayMinutes, after.timeOfDayMinutes) {
            case let (old?, new?):
                return "Time \(LooprClockFormat.text(minuteOfDay: old, locale: locale)) to \(LooprClockFormat.text(minuteOfDay: new, locale: locale))"
            case (nil, let new?): return "Time set to \(LooprClockFormat.text(minuteOfDay: new, locale: locale))"
            default: return "Time taken off"
            }
        case .evening:
            return after.isEvening ? "Now asked in the evening check-in" : "No longer asked in the evening check-in"
        case .reason: return "Your reason changed"
        case .source: return after.source == .manual ? "Now you tick it" : "Now \(ProtocolRulesPresentation.sourceText(after.source))"
        case .cadence:
            return "Was \(ProtocolRulesPresentation.cadenceText(before.cadence)), now \(ProtocolRulesPresentation.cadenceText(after.cadence))"
        case .why: return after.why == nil ? "Why taken off" : "Why changed"
        case .evidence: return after.evidence == nil ? "Where it comes from taken off" : "Where it comes from changed"
        case .group:
            return "Moved from \(ProtocolRulesPresentation.groupTitle(before.group)) to \(ProtocolRulesPresentation.groupTitle(after.group))"
        }
    }
}

// MARK: - Pass card

/// The pass card (contract phone p-share): the file's name, version, author and lineage, a rosette of its rules, the
/// counts and the file's fingerprint: the start of its SHA-256 as text and as a row of dots. The dots are drawn so they
/// cannot pass for a QR code, since there is nothing for a camera to read.
public struct ProtocolPass: Equatable, Sendable {
    public let version: Int
    public let name: String
    /// "by Sam · fork of sleep-first". Nil when the file names neither.
    public let byline: String?
    public let ruleCount: Int
    /// This week's kept share, as the Check-in shows it.
    public let keptPercent: Int?
    public let experimentCount: Int
    public let fileName: String
    public let byteCount: Int
    /// The rules' groups in the file's order, for the rosette.
    public let groups: [RuleGroup]
    public let fingerprint: ProtocolPassFingerprint
    /// This week's checks with an answer behind `keptPercent`, so the pass says what the share stands on (ICP R2-VET-11).
    public var checkCount: Int? = nil

    public var header: String { "Loopr protocol" }
    public var versionText: String { "v\(version)" }
    public var keptText: String { keptPercent.map { "\($0)%" } ?? "No data" }
    /// "3.2 KB · rules and experiment designs only. No health data inside."
    public var fileDetail: String { "\(Self.sizeText(byteCount)) \u{00B7} rules and experiment designs only. No health data inside." }

    public var countsAccessibilityLabel: String {
        let rules = "\(ruleCount) \(ruleCount == 1 ? "rule" : "rules")"
        let checks = checkCount.map { " over \($0) \($0 == 1 ? "check" : "checks")" } ?? ""
        let kept = keptPercent.map { "\($0) percent kept this week\(checks)" } ?? "nothing kept this week yet"
        let experiments = "\(experimentCount) \(experimentCount == 1 ? "experiment" : "experiments")"
        return "\(rules), \(kept), \(experiments)"
    }

    public var rosetteAccessibilityLabel: String {
        guard ruleCount > 0 else { return "An empty ring. This protocol has no rules yet." }
        let counts = RuleGroup.allCases.compactMap { group -> String? in
            let count = groups.filter { $0 == group }.count
            return count == 0 ? nil : "\(count) \(ProtocolRulesPresentation.groupTitle(group).lowercased())"
        }
        return "Rosette of \(ruleCount) \(ruleCount == 1 ? "rule" : "rules"): \(ProtocolVersionDiff.listText(counts))"
    }

    public static func make(file: ProtocolFile, data: Data, keptPercent: Int?, checkCount: Int? = nil) -> ProtocolPass {
        var by: [String] = []
        if let author = file.author?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty { by.append("by \(author)") }
        if let lineage = file.lineage { by.append("fork of \(lineage.forkedFromName)") }
        return ProtocolPass(version: file.version, name: file.name, byline: by.isEmpty ? nil : by.joined(separator: " \u{00B7} "),
                            ruleCount: file.rules.count, keptPercent: keptPercent, experimentCount: file.experiments.count,
                            fileName: file.suggestedFileName, byteCount: data.count, groups: file.rules.map(\.group),
                            fingerprint: ProtocolPassFingerprint(data: data), checkCount: checkCount)
    }

    /// "812 bytes", "3.2 KB".
    public static func sizeText(_ bytes: Int) -> String {
        if bytes < 1_024 { return "\(bytes) \(bytes == 1 ? "byte" : "bytes")" }
        let kilobytes = Double(bytes) / 1_024
        return String(format: "%.1f KB", kilobytes)
    }
}

/// The start of a file's SHA-256, for comparing two copies by eye: "3f9a 21c0 7b4e" and one dot per hex pair. The same
/// file always gives the same fingerprint. It is not a code to scan, so the card draws it as a single row of round dots
/// of four sizes, nothing like a QR grid.
public struct ProtocolPassFingerprint: Equatable, Sendable {
    /// Hex characters shown, in groups of four.
    public static let characterCount = 12
    public static let dotCount = characterCount / 2
    public static let caption = "Fingerprint of this file. Two copies match when these match."

    /// The first `characterCount` hex characters of the SHA-256, lower case.
    public let hex: String
    /// One size step per dot, 0 to 3, from the same bytes as `hex`.
    public let levels: [Int]

    public init(data: Data) {
        let digest = Array(SHA256.hash(data: data))
        let bytes = Array(digest.prefix(Self.dotCount))
        hex = bytes.map { String(format: "%02x", $0) }.joined()
        levels = bytes.map { Int($0 >> 6) }
    }

    /// "3f9a 21c0 7b4e".
    public var text: String {
        stride(from: 0, to: hex.count, by: 4).map { start in
            let from = hex.index(hex.startIndex, offsetBy: start)
            return String(hex[from..<(hex.index(from, offsetBy: 4, limitedBy: hex.endIndex) ?? hex.endIndex)])
        }.joined(separator: " ")
    }

    /// Spells the characters one by one so VoiceOver does not read the groups as words or numbers.
    public var accessibilityLabel: String {
        "File fingerprint: \(text.split(separator: " ").map { $0.map(String.init).joined(separator: " ") }.joined(separator: ", "))"
    }
}

public extension ProtocolVersionDiff {
    /// "a, b and c".
    static func listText(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " and " + (items.last ?? "")
        }
    }
}

// MARK: - Import review

/// What the person sees before "Use this protocol": the file and what it changes against their newest version.
public struct ProtocolImportReview: Equatable, Sendable {
    public let preview: ProtocolImportPreview
    public let byline: String?
    public let rows: [ProtocolRuleRow]
    /// One line per change: "Adds Stretch", "Removes No alcohol", "Changes In bed by 22:30: time".
    public let changeLines: [String]
    /// "Against version 7: 2 added, 1 removed, 1 changed."
    public let headline: String

    public var name: String { preview.file.name }

    public static func make(_ preview: ProtocolImportPreview, current: [ProtocolRule]?, currentVersion: Int?,
                            locale: Locale = .current) -> ProtocolImportReview {
        let file = preview.file
        var by: [String] = []
        if let author = file.author { by.append("by \(author)") }
        if let lineage = file.lineage { by.append("fork of \(lineage.forkedFromName)") }
        let rows = file.rules.map { ProtocolRulesPresentation.row($0, locale: locale) }
        guard let current, let currentVersion else {
            let count = "\(file.rules.count) \(file.rules.count == 1 ? "rule" : "rules")"
            return ProtocolImportReview(preview: preview, byline: by.isEmpty ? nil : by.joined(separator: " \u{00B7} "), rows: rows,
                                        changeLines: [], headline: "This becomes version 1 of your protocol, with \(count).")
        }
        // Rebuttals are personal and never come from a file, so they are not a change.
        let changes = ProtocolVersionDiff.changes(from: current.map(\.withoutRebuttal), to: file.rules.map(\.withoutRebuttal))
        let lines = changes.map { change -> String in
            switch change {
            case .added(let rule): "Adds \(rule.displayTitle(locale: locale))"
            case .removed(let rule): "Removes \(rule.displayTitle(locale: locale))"
            case .changed(_, let after, let fields): "Changes \(after.displayTitle(locale: locale)): \(ProtocolVersionDiff.listText(fields.map(\.name)))"
            }
        }
        let added = changes.filter { if case .added = $0 { true } else { false } }.count
        let removed = changes.filter { if case .removed = $0 { true } else { false } }.count
        let changed = changes.count - added - removed
        let headline = changes.isEmpty
            ? "Same rules as your version \(currentVersion). Using it saves version \(currentVersion + 1) with this name."
            : "Against your version \(currentVersion): \(added) added, \(removed) removed, \(changed) changed. Using it saves version \(currentVersion + 1)."
        return ProtocolImportReview(preview: preview, byline: by.isEmpty ? nil : by.joined(separator: " \u{00B7} "), rows: rows,
                                    changeLines: lines, headline: headline)
    }
}

// MARK: - Templates

/// One of the bundled templates on the start screen: what is in it and how much of it a source checks (ICP R1-NEW-03,
/// R1-SEN-13). Tapping it opens its preview, so nothing is installed from this line.
public struct ProtocolTemplateChoice: Equatable, Sendable, Identifiable {
    public var id: String { template.rawValue }
    public let template: ProtocolTemplate
    /// The template's rules, in the file's order.
    public let rules: [ProtocolRule]

    public init(template: ProtocolTemplate, rules: [ProtocolRule]) {
        self.template = template; self.rules = rules
    }

    public var title: String { template.title }
    public var ruleCount: Int { rules.count }
    /// Rules the band checks. Without a band they stay not known (ICP R3-NEW-8).
    public var bandRuleCount: Int { rules.filter { $0.source == .band }.count }
    /// Rules Loopr checks without a tick: the band, Food, Fitness and Apple Health together (ICP R2-NEW-11).
    public var checkedRuleCount: Int { rules.filter { $0.source != .manual }.count }
    /// The one the start screen marks "Start here".
    public var isRecommended: Bool { template == .recommended }

    /// What is in it, in a few words.
    public var summary: String {
        switch template {
        case .gentleStart: "In bed by 22:30, 6,000 steps a day and one drink at most."
        case .sleepFirst: "In bed by 22:30, no caffeine after 14:00 and the kitchen closed by 19:00."
        case .fitnessForTheLongRun: "Zone 2 and strength each week, grip and balance tests each month."
        case .everythingAtOnce: "Sleep, food, exercise and a blood test every 6 months."
        case .startEmpty: "No rules. You add your own, one at a time."
        }
    }

    /// "3 rules. Loopr checks 2 of the 3 for you." Nil for Start empty, whose summary already says it has none. It counts
    /// every rule a source checks, so the number says how little the person has to tick, and no source reads like
    /// something to buy (ICP R1-SEN-13, R2-NEW-11).
    public var counts: String? {
        guard ruleCount > 0 else { return nil }
        let rules = "\(ruleCount) \(ruleCount == 1 ? "rule" : "rules")."
        let checked = checkedRuleCount
        guard checked > 0 else { return "\(rules) \(ruleCount == 1 ? "You tick it." : "You tick each one.")" }
        let line = checked == ruleCount
            ? (ruleCount == 1 ? "Loopr checks it for you." : ruleCount == 2 ? "Loopr checks both for you." : "Loopr checks all \(ruleCount) for you.")
            : "Loopr checks \(checked) of the \(ruleCount) for you."
        return "\(rules) \(line)"
    }

    /// The summary and the counts on one line, for VoiceOver and a test.
    public var detail: String { [summary, counts].compactMap { $0 }.joined(separator: " ") }

    public static func all() -> [ProtocolTemplateChoice] {
        ProtocolTemplate.allCases.map { template in
            ProtocolTemplateChoice(template: template, rules: (try? template.load().file.rules) ?? [])
        }
    }
}

// MARK: - Copy

public enum ProtocolRulesText {
    public static let editTitle = "Edit rule"
    public static let addTitle = "New rule"
    public static let nameTitle = "Name"
    public static let whyTitle = "Why"
    public static let whyPrompt = "Why this rule matters to you. Optional."
    public static let whenTitle = "When"
    public static let anyTime = "Any time"
    public static let atATime = "At a time"
    public static let daysTitle = "Days"
    /// The editor's one row for the rule's days, which shows the real cadence (ICP R3-DES-07).
    public static let howOftenTitle = "How often"
    /// The period under "Once a week or less": each week, every 3 months and so on.
    public static let repeatsTitle = "Repeats"
    public static let remindTitle = "Remind me"
    /// Said once, where the switch is (ICP R1-HAB-03).
    public static let remindDetail = "A notification at this time on the rule's days. Reminders stay on this iPhone."
    public static let remindNeedsTime = "Turning this on sets a time you can change."
    public static let reminderNeedsTime = "Give the rule a time to get a reminder."
    /// Only on a rule a source checks. A rule the person ticks is always asked (ICP R2-NEW-05).
    public static let eveningTitle = "Also ask me, even when it is checked for me"
    public static let eveningDetail = "Loopr asks you in the evening check-in while it has no answer of its own."
    public static let checkedByTitle = "Checked by"
    public static let moreOptions = "More options"
    public static let moreOptionsSummary = "Time, reminder, who checks it and more"
    public static let setATime = "Set a time"
    /// Asked before saving a rule that measures what another rule already measures (ICP R3-VET-05): "You already have a
    /// Zone 2 rule. Keep both?"
    public static func overlapTitle(_ existing: ProtocolRule) -> String {
        let name = existing.target.metric.flatMap(RoutineMetric.init(rawValue:)).map(ProtocolRulesPresentation.measureName)
        let article = name.map { "aeiou".contains($0.prefix(1).lowercased()) ? "an" : "a" } ?? "a"
        return "You already have \(article) \(name ?? "matching") rule. Keep both?"
    }

    /// "Zone 2, 45 min already checks this. With both, one reading counts twice."
    public static func overlapDetail(_ existing: ProtocolRule, locale: Locale = .current) -> String {
        "\(existing.displayTitle(locale: locale)) already checks this. With both, one reading counts twice."
    }

    public static let overlapKeepBoth = "Keep both"
    public static func overlapReplace(_ existing: ProtocolRule, locale: Locale = .current) -> String {
        "Replace \(existing.displayTitle(locale: locale))"
    }
    public static let overlapGoBack = "Go back"
    /// The toast's action after a new rule is saved (ICP R3-HAB-08).
    public static let addAnother = "Add another"

    /// The editor's read-only line for `ProtocolRule.evidence` (ICP R3-VET-08).
    public static let evidenceTitle = "Where this comes from"
    public static let groupTitle = "Group"
    /// The rebuttal, under "More options" (ICP R2-DES-09, R2-HAB-07).
    public static let rebuttalTitle = "A line to yourself for the morning"
    public static let rebuttalPrompt = "What will you tell yourself tonight?"
    public static let rebuttalHelp = "Write it while you still mean it. If the reminder is on, it shows this line at the rule's time. It stays on this iPhone and never goes into a shared file."
    public static let timeTitle = "Time"
    /// The optional line at Save that becomes the version's note (ICP R2-VET-07).
    public static let changeReasonTitle = "Why this change?"
    public static let changeReasonPrompt = "Optional. For example, my GP asked for it."
    public static let removeTitle = "Remove this rule"
    public static let removeConfirm = "Remove rule"
    public static let removeNote = "Earlier versions keep it, with its history."
    public static let saveFailed = "Loopr could not save this version."
    public static let undone = "Undone. Your rules are as they were."
    public static let templatesTitle = "Start with a template"
    public static let templatesDetail = "Pick one to start your list. You can change every rule afterwards."
    /// For the person who had the Journal before (ICP R1-UPG-23).
    public static let journalStays = "How you feel, your notes and your questions about the day stay in the check-in, with or without a protocol. Deleting a protocol never deletes them."
    public static let findOnGitHub = "Find protocols on GitHub"
    public static let findOnGitHubDetail = "Opens the community folder in Safari"
    public static let importTitle = "Import a file"
    public static let importDetail = "A .looprprotocol file from Files"
    public static let shareTitle = "Share protocol"
    public static let shareDetail = "A pass card and the file, with no health data"
    public static let historyTitle = "Versions"
    public static let menuTitle = "More for your rules"
    public static let addRule = "Add a rule"
    public static let addRuleDetail = "Name it, then pick when and who checks it"
    public static let readOnly = "You can read an old version but not edit it. To change your protocol, edit the newest one."
    public static let useFile = "Use this protocol"
    public static let shareFile = "Share file"
    public static let openPullRequest = "Open a pull request on GitHub"
}
