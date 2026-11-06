#if DEBUG
import DomainKit
import Foundation
import JournalKit
import RoutineKit
import StorageKit

/// DEBUG launch fixture for the protocol in the populated composition. It builds one protocol in a throwaway SQLite
/// file under the simulator's temporary folder, and the Protocol tab, Today's rail, Today's experiment strip and the
/// weekly review all read that one store, so every tab counts the same ten rules (ICP R2-UPG-4). They run on the real
/// `RoutineStore` and `RoutineDayEvaluation`. Every launch starts from the seeded state: the first read of a launch
/// deletes the file, its WAL and SHM files and any fixture file an older build left behind, then seeds a new one. The
/// other fixture compositions (onboarding, pairing, empty and the rest) get the same file with no protocol, so a person
/// who just finished onboarding meets an empty Protocol tab (ICP R2-NEW-2). Nothing here is reachable in a release build.
///
/// Relative to the launch's one fixture clock (`TodayDialFixtureClock`: Tue 14 Nov 2023, 13:30, or 07:12 and 19:49 with
/// `--loopr-today-clock=`), the clock Today reads too: "My protocol", day 21. Version 1 has the ten daily rules,
/// version 2 keeps the caffeine result with the same rules, and version 3 (12 days ago, with the person's reason)
/// replaces the daily "Zone 2, 45 min" with "Zone 2, 150 min a week", so the same minutes never count twice (ICP
/// R3-VET-05), and adds "Blood panel every 3 months" (ICP R2-VET-06, R2-VET-07). The band's minutes fill the weekly rule
/// to 112 of 150 by this evening (64 on Monday, 48 today once the session is over). The blood panel was done the day it
/// was added. Its "due" is three months from then: a check before day 1 would move day 1. Days already stored keep the
/// checks they were seeded with.
/// - Monday is decided: 9 kept and "In bed by 22:30" missed. "Screens off" was ticked with Done on its reminder.
/// - Last week missed "Screens off by 21:45" on Friday and "In bed by 22:30" on Saturday. Sunday is the fixture's day
///   without band data or logs (`FixtureDayHistory`), so only the rules the person ticks have an answer on it.
/// - Today, in the evening, Apple Health kept Morning light and Food the last meal and late caffeine. In the morning
///   only Morning light is kept: the caffeine and kitchen limits are still ahead.
///   Protein (82 g of 150 g) and No alcohol stay open until the day ends. Magnesium (21:30), Screens off (21:45), Read
///   before bed (22:00) and In bed (22:30) are open, so they are the deck.
/// - Experiments (LV-07.3): magnesium is running at night 9 of 14, inside the spread, and tonight is a magnesium
///   night. Monday was an off night, so Monday's magnesium reads as skipped by design. With
///   `--loopr-protocol-fixture=off-night` the test started a day earlier: tonight is night 10, an off night, and the
///   check-in says so instead of asking about magnesium (ICP R1-VET-02). Three finished: "No caffeine after 14:00", the rule it tested (Clear, kept as version 2, which keeps the same rules), "Mouth
///   tape" (No change) and "Bedroom at 18 °C" (Clear, not kept, with "Fell asleep 8 min sooner" as also moved). Keeping
///   that one adds its rule as version 4.
@MainActor
enum ProtocolTabFixture {
    private static var shared: RoutineStore?
    private static var sharedExperiments: ExperimentStore?

    nonisolated struct Stores: Sendable {
        let routine: RoutineStore
        let experiments: ExperimentStore
    }

    nonisolated static let protocolName = "My protocol"
    nonisolated static let protocolAgeDays = 20
    nonisolated static let fileName = "loopr-protocol-fixture.sqlite"
    nonisolated static let filePrefix = "loopr-protocol-fixture"

    /// The DEBUG launch argument for a fixture with no protocol, so the Rules segment offers the templates (LV-07.4).
    /// Pair it with `--loopr-start-at=protocol-rules`.
    nonisolated static let emptyArgument = "--loopr-protocol-fixture=empty"

    /// True when the launch asks for the empty fixture, read the way `MainTabLaunchState.startingAt` reads its argument.
    nonisolated static func startsEmpty(_ arguments: [String]) -> Bool {
        arguments.contains(emptyArgument)
    }

    /// The DEBUG launch argument that makes tonight an off night of the running magnesium test.
    nonisolated static let offNightArgument = "--loopr-protocol-fixture=off-night"

    /// The magnesium test's first night, counted back from today: one night further back with `offNightArgument`.
    nonisolated static func magnesiumStartOffset(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> Int {
        arguments.contains(offNightArgument) ? -9 : -8
    }

    /// True when a launch in `composition` starts without a protocol: every fixture composition but the populated one,
    /// which is the only one with history (`FixtureDayHistory.hasHistory`), and the populated one with
    /// `--loopr-protocol-fixture=empty`.
    nonisolated static func startsEmpty(composition: AppEnvironment.Composition, arguments: [String]) -> Bool {
        !FixtureDayHistory.hasHistory(composition) || startsEmpty(arguments)
    }

    /// The launch's stores, made fresh on first use. Every reader of a launch gets the same file, whichever asks first.
    /// They are seeded on the launch's one fixture clock (`TodayDialFixtureClock`), the clock every tab reads.
    static func stores(environment: AppEnvironment) -> Stores? {
        let clock = TodayDialFixtureClock.clock(environment: environment)
        return stores(now: clock.now, timeZone: clock.calendar.timeZone,
                      empty: startsEmpty(composition: environment.composition, arguments: ProcessInfo.processInfo.arguments))
    }

    /// The launch's store, made fresh on its first use. `empty` leaves it without a protocol or experiments.
    static func store(now: Date, timeZone: TimeZone, empty: Bool = false) -> RoutineStore? {
        stores(now: now, timeZone: timeZone, empty: empty)?.routine
    }

    private static func stores(now: Date, timeZone: TimeZone, empty: Bool) -> Stores? {
        if let shared, let sharedExperiments { return Stores(routine: shared, experiments: sharedExperiments) }
        guard let stores = try? makeStores(in: FileManager.default.temporaryDirectory, now: now, timeZone: timeZone,
                                           empty: empty) else { return nil }
        shared = stores.routine
        sharedExperiments = stores.experiments
        return stores
    }

    /// The launch's experiment store, on the same file as `store(now:timeZone:)`.
    static func experimentStore(now: Date, timeZone: TimeZone) -> ExperimentStore? {
        _ = store(now: now, timeZone: timeZone)
        return sharedExperiments
    }

    /// Deletes every fixture file in `directory`, then opens and seeds a new one. Whatever an earlier launch or test
    /// answered is gone. A file that cannot be removed throws, so a launch never reuses old answers. Call it once per
    /// launch, before any store on the folder is open.
    nonisolated static func makeStore(in directory: URL, now: Date, timeZone: TimeZone) throws -> RoutineStore {
        try makeStores(in: directory, now: now, timeZone: timeZone).routine
    }

    /// `makeStore`, with the experiment store on the same file.
    nonisolated static func makeStores(in directory: URL, now: Date, timeZone: TimeZone, empty: Bool = false) throws -> Stores {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in try manager.contentsOfDirectory(atPath: directory.path) where name.hasPrefix(filePrefix) {
            let url = directory.appendingPathComponent(name)
            try manager.removeItem(at: url)
            guard !manager.fileExists(atPath: url.path) else { throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path]) }
        }
        let database = try StorageDatabase(url: directory.appendingPathComponent(fileName), applicationVersion: "DEBUG Fixture")
        let store = RoutineStore(database: database)
        let experiments = ExperimentStore(database: database)
        if empty { return Stores(routine: store, experiments: experiments) }
        seededDay = ProtocolWeekCalendar(timeZone: timeZone, locale: Locale(identifier: "en_US_POSIX")).day(now)
        try seed(store, now: now, timeZone: timeZone)
        try seedExperiments(experiments, routine: store, now: now, timeZone: timeZone)
        try seedLongerRules(store, now: now, timeZone: timeZone)
        return Stores(routine: store, experiments: experiments)
    }

    nonisolated static let rules: [ProtocolRule] = [
        ProtocolRule(key: "morning-light", title: "Morning light", group: .sleep,
                     target: RuleTarget(kind: .atLeast, metric: RoutineMetric.daylightMinutes.rawValue, value: 10, unit: "min"),
                     timeOfDayMinutes: 7 * 60, source: .appleHealth,
                     why: "Light early in the day helps set your body clock.",
                     evidence: "No guideline sets a number of minutes, so 10 is a modest place to start."),
        // Protein matches Food's target (150 g) and the fixture Food day's breakfast and lunch (32 g and 50 g).
        ProtocolRule(key: "protein", title: "Protein 150 g", group: .food,
                     target: RuleTarget(kind: .atLeast, metric: RoutineMetric.proteinG.rawValue, value: 150, unit: "g"),
                     source: .food,
                     why: "Enough protein helps you keep your muscle as you get older.",
                     evidence: "A 2013 expert group, PROT-AGE, suggested 1.0 to 1.2 g of protein per kg of body weight a day for adults over 65, and more for people who exercise."),
        ProtocolRule(key: "caffeine-cutoff", title: "No caffeine after 14:00", group: .food,
                     target: RuleTarget(kind: .atMost, metric: RoutineMetric.lastCaffeineTime.rawValue, value: 839, unit: "min"),
                     timeOfDayMinutes: 14 * 60, source: .food,
                     why: "Caffeine stays in your body for hours and can still cut into your sleep.",
                     evidence: "In a 2013 study in the Journal of Clinical Sleep Medicine, 400 mg of caffeine taken 6 hours before bed still cut sleep by more than an hour. You tested this rule yourself and kept it."),
        ProtocolRule(key: "kitchen-closed", title: "Kitchen closes", group: .food,
                     target: RuleTarget(kind: .atMost, metric: RoutineMetric.lastMealTime.rawValue, value: 1_110, unit: "min"),
                     timeOfDayMinutes: 18 * 60 + 30, source: .food, isEvening: true,
                     why: "Finishing dinner a few hours before bed gives your body time to settle.",
                     evidence: "No trial sets how long to leave between dinner and bed. Four hours before 22:30 is a modest place to start."),
        ProtocolRule(key: "no-alcohol", title: "No alcohol", group: .food,
                     target: RuleTarget(kind: .atMost, metric: RoutineMetric.alcoholDrinks.rawValue, value: 0, unit: "drinks"),
                     source: .food,
                     why: "Skipping alcohol usually means better sleep.",
                     evidence: "A 2013 review in Alcoholism: Clinical and Experimental Research found that alcohol before bed breaks up sleep in the second half of the night. The WHO says no amount of alcohol is free of risk."),
        ProtocolRule(key: "zone-2", title: "Zone 2, 45 min", group: .fitness,
                     target: RuleTarget(kind: .atLeast, metric: RoutineMetric.zone2Minutes.rawValue, value: 45, unit: "min"),
                     timeOfDayMinutes: 17 * 60 + 30, source: .band,
                     why: "Steady exercise where you can still talk keeps your heart and lungs fit.",
                     evidence: "WHO guidelines from 2020 ask adults for 150 to 300 minutes of moderate activity a week. Zone 2 is a steady effort where you can still talk."),
        ProtocolRule(key: "magnesium", title: "Magnesium, 300 mg", group: .supplements, timeOfDayMinutes: 21 * 60 + 30,
                     isEvening: true,
                     why: "You are testing whether magnesium changes your sleep.",
                     evidence: "The magnesium test compares your nights with it and without it. Loopr shows a result only after the last night."),
        ProtocolRule(key: "screens-off", title: "Screens off by 21:45", group: .sleep, timeOfDayMinutes: 21 * 60 + 45,
                     isEvening: true,
                     why: "Time away from screens before bed gives your mind a chance to wind down.",
                     evidence: "No study sets how long to stay off screens before bed. 45 minutes is a modest place to start."),
        ProtocolRule(key: "read-before-bed", title: "Read before bed", group: .sleep, timeOfDayMinutes: 22 * 60,
                     isEvening: true,
                     why: "A book is a calm habit to take the phone's place.",
                     evidence: "No study sets a time for this. It is a calm habit you picked, not a rule from research."),
        ProtocolRule(key: "in-bed", title: "In bed by 22:30", group: .sleep,
                     target: RuleTarget(kind: .atMost, metric: RoutineMetric.inBedTime.rawValue, value: 1_350, unit: "min"),
                     timeOfDayMinutes: 22 * 60 + 30, source: .band, isEvening: true,
                     why: "A steady bedtime leaves room for the 7 to 9 hours of sleep adults need.",
                     evidence: "The American Academy of Sleep Medicine and the Sleep Research Society say adults need 7 to 9 hours of sleep a night, in a 2015 consensus. In bed by 22:30 leaves room for that before a 06:30 to 07:30 wake-up.")
    ]

    /// Two rules with a longer period, in version 3 so Versions has a row that says what changed and why. Neither gets a
    /// daily check: the weekly one is filled by the band's minutes, the blood panel was ticked once. The weekly Zone 2
    /// takes the daily one's place.
    nonisolated static let longerRules: [ProtocolRule] = [
        ProtocolRule(key: "zone-2-week", title: "Zone 2, 150 min a week", group: .fitness,
                     target: RuleTarget(kind: .atLeast, metric: RoutineMetric.zone2Minutes.rawValue, value: 150, unit: "min"),
                     source: .band, cadence: RuleCadence(unit: .week),
                     why: "A weekly total lets you catch up later in the week after a busy day."),
        ProtocolRule(key: "blood-panel", title: "Blood panel every 3 months", group: .tests,
                     cadence: RuleCadence(unit: .month, every: 3),
                     why: "Your GP wants to see your cholesterol and blood sugar every 3 months.")
    ]

    /// The rule Monday's answer came from its reminder for: the day sheet reads "Answered from your reminder."
    nonisolated static let reminderAnsweredRuleKey: RuleKey = "screens-off"

    /// The daily rule version 3 took out for the weekly one (ICP R3-VET-05).
    nonisolated static let replacedRuleKey: RuleKey = "zone-2"

    /// Every rule of the newest version, in its order: the nine daily rules left, then the two longer ones.
    nonisolated static var allRules: [ProtocolRule] { rules.filter { $0.key != replacedRuleKey } + longerRules }

    /// Days before today that version 3 was saved, and the blood panel done.
    nonisolated static let longerRulesAgeDays = 12
    /// Version 3's note: the person's answer to "Why this change?".
    nonisolated static let longerRulesReason = "Changed Zone 2 to 150 min a week, and added the blood test my GP asked for."
    /// The band's zone 2 minutes on Monday, so the weekly rule reads 112 of 150 this evening.
    nonisolated static let mondayZone2Minutes = 64.0

    /// Version 3: the newest rules with the daily Zone 2 swapped for `longerRules`, and the blood panel ticked that day.
    private nonisolated static func seedLongerRules(_ store: RoutineStore, now: Date, timeZone: TimeZone) throws {
        let week = ProtocolWeekCalendar(timeZone: timeZone, locale: Locale(identifier: "en_US_POSIX"))
        guard let active = try store.activeProtocol(), let day = week.day(now).adding(days: -longerRulesAgeDays),
              let savedAt = week.date(day) else { return }
        let id = active.routineProtocol.id
        let saved = try store.saveEdit(protocolID: id, rules: active.latestVersion.rules.filter { $0.key != replacedRuleKey } + longerRules,
                                       reason: longerRulesReason, at: savedAt)
        _ = try store.recordChecks([try RuleCheck(ruleKey: "blood-panel", day: day, version: saved.number, state: .kept,
                                                  source: .manual, recordedAt: savedAt)], protocolID: id)
    }

    private nonisolated static func seed(_ store: RoutineStore, now: Date, timeZone: TimeZone) throws {
        let week = ProtocolWeekCalendar(timeZone: timeZone, locale: Locale(identifier: "en_US_POSIX"))
        let today = week.day(now)
        guard let created = week.calendar.date(byAdding: .day, value: -protocolAgeDays, to: now) else { return }
        let routineProtocol = RoutineProtocol(name: protocolName, createdAt: created)
        try store.createProtocol(routineProtocol, rules: rules)
        let id = routineProtocol.id

        func check(_ key: RuleKey, _ day: DayIdentity, _ state: CheckState, by source: CheckSource,
                   answeredFrom: AnswerOrigin? = nil) throws -> RuleCheck {
            try RuleCheck(ruleKey: key, day: day, version: 1, state: state, source: source,
                          recordedAt: week.date(day) ?? now, answeredFrom: answeredFrom)
        }

        let days = week.week(containing: today)
        for day in days where ProtocolTabLoader.key(day) < ProtocolTabLoader.key(today) {
            try store.recordChecks(rules.map { rule in
                // Monday's "Screens off" was ticked with Done on its reminder, so the day sheet says so.
                try check(rule.key, day, rule.key == "in-bed" ? .missed : .kept, by: rule.source,
                          answeredFrom: rule.key == reminderAnsweredRuleKey && day == days.first ? .reminder : nil)
            }, protocolID: id)
        }
        if let monday = days.first, let lastMonday = week.adding(-7, to: monday) {
            for (offset, day) in week.week(containing: lastMonday).enumerated() {
                // The fixture's empty day has nothing logged and no band data, so no source kept or missed a rule on it.
                // The person still ticked the rules they answer, so all seven days of the review have answers (ICP
                // R2-VET-02, R2-HAB-10).
                let empty = isEmptyFixtureDay(day, fixtureDay: today)
                try store.recordChecks(rules.filter { !empty || $0.source == .manual }.map { rule in
                    let missed = rule.key == "in-bed" && offset >= 5 || rule.key == "screens-off" && offset == 4
                    return try check(rule.key, day, missed ? .missed : .kept, by: rule.source)
                }, protocolID: id)
            }
        }
    }

    // MARK: Experiments

    /// One fixture experiment: its design, its per-arm values in night order and the baseline it is measured against.
    private nonisolated struct Plan {
        let id: ExperimentID
        let title: String
        let interventionName: String
        let ruleKey: RuleKey
        let outcome: ExperimentMetric
        let startOffset: Int
        let plannedNights: Int
        let minimumNightsPerArm: Int
        let on: [Double]
        let off: [Double]
        var otherOn: [Double] = []
        var otherOff: [Double] = []
        var finishes = true
    }

    private nonisolated static let otherMetric = ExperimentMetric.timeToFallAsleep

    /// Fixed ids, so UI tests can name a row: `protocol-experiment-finished-<id in lower case>`.
    nonisolated static let caffeineExperimentID = fixtureID("0F1A0000-0000-4000-8000-000000000001")
    nonisolated static let mouthTapeExperimentID = fixtureID("0F1A0000-0000-4000-8000-000000000002")
    nonisolated static let bedroomExperimentID = fixtureID("0F1A0000-0000-4000-8000-000000000003")
    nonisolated static let magnesiumExperimentID = fixtureID("0F1A0000-0000-4000-8000-000000000004")

    private nonisolated static func fixtureID(_ text: String) -> ExperimentID {
        ExperimentID(rawValue: UUID(uuidString: text) ?? UUID())
    }

    private nonisolated static let plans: [Plan] = [
        Plan(id: caffeineExperimentID, title: "No caffeine after 14:00", interventionName: "caffeine-free afternoon", ruleKey: "caffeine-cutoff",
             outcome: .deepSleep, startOffset: -64, plannedNights: 28, minimumNightsPerArm: 8,
             on: [96, 88, 92, 99, 85, 94, 90, 97, 89, 93, 91, 95, 87, 92],
             off: [80, 74, 78, 83, 76, 77, 79, 81, 76, 75, 82, 78, 73, 80]),
        Plan(id: mouthTapeExperimentID, title: "Mouth tape", interventionName: "mouth tape", ruleKey: "mouth-tape", outcome: .deepSleep,
             startOffset: -36, plannedNights: 14, minimumNightsPerArm: 5,
             on: [70, 72, 69, 71, 73, 70, 71], off: [71, 70, 72, 70, 71, 69, 72]),
        Plan(id: bedroomExperimentID, title: "Bedroom at 18 °C", interventionName: "cool bedroom", ruleKey: "bedroom-18", outcome: .sleepHeartRate,
             startOffset: -22, plannedNights: 14, minimumNightsPerArm: 5,
             on: [52, 53, 51, 52, 54, 51, 52], off: [56, 57, 55, 56, 58, 55, 56],
             otherOn: [12, 14, 11, 13, 12, 13, 12], otherOff: [21, 20, 21, 19, 21, 20, 21]),
        Plan(id: magnesiumExperimentID, title: "Magnesium glycinate, 300 mg", interventionName: "magnesium", ruleKey: "magnesium", outcome: .deepSleep,
             startOffset: -8, plannedNights: 14, minimumNightsPerArm: 7,
             on: [86, 81, 90, 79], off: [76, 82, 74, 80], finishes: false)
    ]

    /// Starts, records and finishes the plans in order, so only magnesium is left running, then keeps the caffeine
    /// result the way the result screen does.
    private nonisolated static func seedExperiments(_ experiments: ExperimentStore, routine: RoutineStore, now: Date,
                                                    timeZone: TimeZone) throws {
        guard let active = try routine.activeProtocol() else { return }
        let week = ProtocolWeekCalendar(timeZone: timeZone, locale: Locale(identifier: "en_US_POSIX"))
        let today = week.day(now)
        for plan in plans {
            let offset = plan.id == magnesiumExperimentID ? magnesiumStartOffset() : plan.startOffset
            guard let startDay = today.adding(days: offset) else { continue }
            let createdAt = week.date(startDay) ?? now
            let experiment = try experiments.start(try ExperimentStart(
                id: plan.id, protocolID: active.routineProtocol.id, title: plan.title, interventionName: plan.interventionName,
                ruleKey: plan.ruleKey, design: .alternatingDays, washout: 0, minimumNightsPerArm: plan.minimumNightsPerArm,
                plannedNights: plan.plannedNights, outcome: plan.outcome, startDay: startDay,
                timeZoneIdentifier: timeZone.identifier, createdAt: createdAt))
            var on = plan.on[...], off = plan.off[...], otherOn = plan.otherOn[...], otherOff = plan.otherOff[...]
            for night in experiment.start.schedule.nights {
                let isOn = night.role == .on
                guard let value = isOn ? on.popFirst() : off.popFirst() else { continue }
                let other = isOn ? otherOn.popFirst() : otherOff.popFirst()
                try experiments.recordNight(experimentID: experiment.id, day: night.day, adherence: isOn ? .kept : .missed,
                                            outcomeValue: value, otherValues: other.map { [otherMetric.key: $0] } ?? [:],
                                            at: week.date(night.day) ?? now)
            }
            guard plan.finishes else { continue }
            let finished = try experiments.finish(id: experiment.id, lastNight: experiment.start.lastPlannedDay)
            if plan.ruleKey == "caffeine-cutoff", let keptDay = today.adding(days: -19), let keptAt = week.date(keptDay) {
                let inputs = experimentInputs(finished)
                let report = ExperimentAnalyzer.report(experiment: finished, nights: try experiments.nights(experimentID: finished.id),
                                                       baseline: inputs.baseline, otherBaselines: inputs.otherBaselines,
                                                       alsoMetrics: inputs.alsoMetrics, lastNight: finished.start.lastPlannedDay)
                _ = try? routine.keep(finished, report: report, at: keptAt)
            }
        }
    }

    /// The fixture's baselines: 28 nights before day 1 with the spread each plan is measured against.
    nonisolated static func experimentInputs(_ experiment: Experiment) -> ProtocolExperimentInputs {
        let start = experiment.start.startDay
        switch experiment.start.ruleKey {
        case "magnesium":
            return ProtocolExperimentInputs(baseline: baseline(mean: 78, spread: 9, before: start))
        case "caffeine-cutoff":
            return ProtocolExperimentInputs(baseline: baseline(mean: 78, spread: 5, before: start))
        case "mouth-tape":
            return ProtocolExperimentInputs(baseline: baseline(mean: 70, spread: 5, before: start))
        case "bedroom-18":
            return ProtocolExperimentInputs(baseline: baseline(mean: 56, spread: 1.5, before: start),
                                            otherBaselines: [otherMetric.key: baseline(mean: 20, spread: 2, before: start)],
                                            alsoMetrics: [otherMetric])
        default:
            return .none
        }
    }

    /// Nights whose back-to-back differences are one 0 and then +m and -m in turn, so their median is 0 and their
    /// median absolute deviation is exactly m. The noise band then reads `spread`.
    nonisolated static func baseline(mean: Double, spread: Double, before startDay: DayIdentity,
                                     nights: Int = ExperimentPolicy.standard.baselineWindowNights) -> [DayIdentity: Double] {
        let step = spread * 2.0.squareRoot() / 1.4826
        var result: [DayIdentity: Double] = [:]
        var value = mean - step / 2
        for index in 0..<nights {
            if index >= 2 { value += index % 2 == 0 ? step : -step }
            if let day = startDay.adding(days: index - nights) { result[day] = value }
        }
        return result
    }

    /// The day the launch's protocol was seeded for, so the source snapshots know which day is the empty one.
    nonisolated(unsafe) private static var seededDay: DayIdentity?

    /// The fixture's day without band data or logs (`FixtureDayHistory`: two days back).
    nonisolated static func isEmptyFixtureDay(_ day: DayIdentity, fixtureDay: DayIdentity) -> Bool {
        guard let offset = fixtureDay.days(until: day), (-3...0).contains(offset) else { return false }
        return !FixtureDayHistory.offsetsWithData.contains(offset)
    }

    /// Minutes in zone 2 on every fixture day with data: the Zone 2 rule and Today's dial read this one number.
    nonisolated static let zone2Minutes = 48.0
    /// Protein on the fixture day: the Food fixture's breakfast (32 g) and lunch (50 g), which Today's Food row shows.
    nonisolated static let proteinGrams = 82.0

    /// The last meal of the Food fixture's day: lunch at 12:30, the time Today's Last meal tile shows (ICP R2-OPT-8).
    nonisolated static let lastMealMinute = 12 * 60 + 30
    /// The Zone 2 session runs 17:30 to 18:15, so its minutes count only once it is over (ICP R2-OPT-3).
    nonisolated static let zone2SessionEndMinute = 18 * 60 + 15

    /// What the sources hold for a fixture day at `now`, for the Protocol tab and Today alike: 22 minutes of daylight,
    /// the Food fixture's day (82 g of protein, the last coffee at 10:15 and lunch at 12:30 as the last meal), no
    /// alcohol, and 48 minutes in zone 2 once the 17:30 session is over. The empty day holds nothing.
    nonisolated static func snapshots(day: DayIdentity, timeZone: TimeZone, now: Date) -> RoutineSourceSnapshots {
        if let seeded = seededDay, isEmptyFixtureDay(day, fixtureDay: seeded) { return RoutineSourceSnapshots() }
        let minute = RoutineDayClock(day: day, timeZone: timeZone)?.minutes(of: now) ?? 0
        let lastMeal = lastMealMinute
        let isMonday = seededDay.flatMap { $0.adding(days: -1) } == day && RuleWeekday(day: day) == .monday
        let zone2 = isMonday ? mondayZone2Minutes : minute >= Double(zone2SessionEndMinute) ? zone2Minutes : 0
        return RoutineSourceSnapshots(
            band: RoutineSourceSnapshot(source: .band, readings: [.zone2Minutes: .measured(zone2)]),
            food: RoutineSourceSnapshot(source: .food, readings: [
                .proteinG: .measured(proteinGrams), .lastMealTime: .measured(Double(lastMeal)),
                .lastCaffeineTime: .measured(10 * 60 + 15),
                .alcoholDrinks: .measured(0)
            ]),
            fitness: RoutineSourceSnapshot(source: .fitness, readings: [.workoutMinutes: .measured(45)]),
            appleHealth: RoutineSourceSnapshot(source: .appleHealth, readings: [
                .daylightMinutes: .measured(TodayFixtureAppleHealth.daylightMinutes)
            ]))
    }
}
#endif
