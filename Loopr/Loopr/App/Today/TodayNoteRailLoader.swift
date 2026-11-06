import CoachKit
import DesignSystem
import DomainKit
import FoodKit
import Foundation
import JournalKit
import RoutineKit
import SleepKit
import Synchronization
import TodayKit
import WorkoutKit

// What the app puts under Today's dial (LV-04 step 3): the rule-written morning and evening notes with the receipt,
// the protocol rail and the running experiment. CoachKit writes every sentence, RoutineKit decides every rule and
// TodayKit draws them; this file reads the stores and maps their records across. A store that is missing leaves its
// part out. A store that has too few nights says so. Nothing here fills in a zero or writes a coach sentence.

/// The active protocol's rules with today's checks and this week's kept days.
nonisolated struct TodayRailProtocolDay: Sendable, Equatable {
    var rules: [ProtocolRule]
    var checks: [RuleCheck]
    /// Days this week each rule was kept, today included.
    var keptThisWeek: [RuleKey: Int] = [:]
    /// Days of this week so far, today included (Monday is 1).
    var daysThisWeek: Int?

    var dialDay: TodayDialProtocolDay { TodayDialProtocolDay(rules: rules, checks: checks) }
}

/// One reader per store. A nil reader means this composition has no such store and its part stays out.
nonisolated struct TodayNoteRailSources: Sendable {
    /// Day, now and time zone. Returns nil when there is no protocol yet; throws when the store cannot be read.
    var readProtocol: (@Sendable (DayIdentity, Date, TimeZone) async throws -> TodayRailProtocolDay?)?
    /// Ticks a manual rule. True when it was stored, false when it was already kept and nothing was written.
    var tick: (@Sendable (RuleKey, DayIdentity, Date) async throws -> Bool)?
    /// Removes a manual tick (the rail's Undo) and evaluates the day again. Throws when the store cannot write.
    var untick: (@Sendable (RuleKey, DayIdentity, Date, TimeZone) async throws -> Void)?
    /// The experiment that is running, if any.
    var readExperiment: (@Sendable () async -> Experiment?)?
    /// What the morning note reads: last night, the usual and the factors, for the dial's day.
    var readMorning: (@Sendable (DayIdentity, Calendar) async -> MorningNoteInput?)?
    var rewriter: CoachRewriter = CoachRewriter(model: UnavailableCoachRewordingModel())
    var bedtimeEnabled: @Sendable () async -> Bool = { false }
    var firstEveningDismissed: @Sendable () -> Bool = { false }
    var bandName = ""
}

/// A load: the content to draw, and the rule notes behind it for the rewriter.
nonisolated struct TodayCompanionLoad: Sendable {
    var content: TodayCompanionContent
    var morningNote: CoachNote?
    var eveningNote: CoachNote?
    var protocolDay: TodayRailProtocolDay?
}

nonisolated struct TodayNoteRailLoader: Sendable {
    let sources: TodayNoteRailSources

    var provenance: TodayNoteProvenance {
        TodayNoteProvenance(outcome: .band(device: sources.bandName), factor: .food(.logged), kept: .onThisPhone)
    }

    func load(day: DayIdentity, now: Date, calendar: Calendar, isToday: Bool, isClockPinned: Bool,
              locale: Locale = .current) async -> TodayCompanionLoad {
        let writer = CoachNoteWriter(context: NoteContext(locale: locale, calendar: calendar))
        var content = TodayCompanionContent(now: now, isClockPinned: isClockPinned, calendar: calendar, locale: locale)
        content.isToday = isToday
        var load = TodayCompanionLoad(content: content)

        if let readMorning = sources.readMorning {
            let input = await readMorning(day, calendar) ?? MorningNoteInput(lastNight: nil)
            let morning = TodayNoteCards.morning(input, writer: writer, provenance: provenance)
            load.content.morning = morning.state
            load.morningNote = morning.note
        }

        if let readProtocol = sources.readProtocol {
            do {
                if let protocolDay = try await readProtocol(day, now, calendar.timeZone) {
                    load.protocolDay = protocolDay
                    load.content.rail = .rules(TodayNoteRailMapping.railRules(protocolDay))
                    if isToday, let evening = TodayNoteCards.evening(TodayNoteRailMapping.eveningInput(protocolDay),
                                                                      writer: writer, provenance: provenance) {
                        load.content.evening = evening.card
                        load.eveningNote = evening.note
                    }
                } else {
                    load.content.rail = .noProtocol
                }
            } catch {
                // A store that cannot be read shows no rail rather than an empty protocol.
                load.content.rail = nil
            }
        }

        if isToday, let readExperiment = sources.readExperiment, let experiment = await readExperiment() {
            load.content.experiment = TodayExperimentStrip.make(TodayNoteRailMapping.experimentInput(experiment, tonight: day))
        }
        load.content.bedtimeEnabled = await sources.bedtimeEnabled()
        load.content.offersFirstEvening = !sources.firstEveningDismissed()
        return load
    }

    /// The same content with each note reworded by the on-device model, where its numbers matched. Nil when nothing
    /// changed, so the screen keeps what it shows.
    func reworded(_ load: TodayCompanionLoad) async -> TodayCompanionContent? {
        guard sources.rewriter.isAvailable else { return nil }
        var content = load.content
        var changed = false
        if let note = load.morningNote {
            let card = await TodayNoteCards.reworded(note, rewriter: sources.rewriter, provenance: provenance)
            if card.isReworded { content.morning = .note(card); changed = true }
        }
        if let note = load.eveningNote {
            let card = await TodayNoteCards.reworded(note, rewriter: sources.rewriter, provenance: provenance)
            if card.isReworded { content.evening = card; changed = true }
        }
        return changed ? content : nil
    }

    /// Ticks a manual rule for today. True when the rule is kept now, whether this hold stored it or an earlier one did.
    func tick(_ key: String, day: DayIdentity, now: Date) async -> Bool {
        guard let tick = sources.tick else { return false }
        do {
            _ = try await tick(RuleKey(rawValue: key), day, now)
            return true
        } catch {
            return false
        }
    }

    /// Takes back a tick made on Today. True when the rule has no manual tick any more.
    func untick(_ key: String, day: DayIdentity, now: Date, timeZone: TimeZone) async -> Bool {
        guard let untick = sources.untick else { return false }
        do {
            try await untick(RuleKey(rawValue: key), day, now, timeZone)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Mapping

/// Turns RoutineKit and the stores' records into the plain inputs of CoachKit and TodayKit. No decisions.
nonisolated enum TodayNoteRailMapping {
    /// Every rule of the version with its stored check, in the version's order. A rule with no check is unknown.
    static func railRules(_ day: TodayRailProtocolDay) -> [TodayRailRuleInput] {
        let checks = Dictionary(day.checks.map { ($0.ruleKey, $0) }, uniquingKeysWith: { _, newer in newer })
        return day.rules.map { rule in
            let check = checks[rule.key]
            return TodayRailRuleInput(
                key: rule.key.rawValue, title: rule.title, group: group(rule.group),
                source: TodayDialInputMapping.source(rule.source), metric: rule.target.metric,
                targetKind: targetKind(rule.target.kind), targetValue: rule.target.value, unit: unit(rule.target.metric),
                timeOfDayMinutes: rule.timeOfDayMinutes, isEvening: rule.isEvening,
                state: TodayDialInputMapping.state(check?.state), measuredValue: check?.measuredValue)
        }
    }

    static func group(_ group: RuleGroup) -> TodayRailGroup {
        switch group {
        case .sleep: .sleep
        case .food: .food
        case .fitness: .fitness
        case .supplements: .supplements
        case .tests: .tests
        case .custom: .custom
        }
    }

    static func targetKind(_ kind: RuleTargetKind) -> TodayRailTargetKind {
        switch kind {
        case .done: .done
        case .atLeast: .atLeast
        case .atMost: .atMost
        case .exactly: .exactly
        }
    }

    static func unit(_ metric: String?) -> TodayRailUnit? {
        guard let metric else { return nil }
        if RoutineItemMetric(rawValue: metric) != nil { return .tick }
        guard let known = RoutineMetric(rawValue: metric) else { return .other }
        switch known.unit {
        case .grams: return .grams
        case .kilocalories: return .kilocalories
        case .drinks: return .drinks
        case .minutes: return .minutes
        case .sessions: return .sessions
        case .steps: return .steps
        case .minutesAfterMidnight: return .minutesAfterMidnight
        case .tick: return .tick
        case .mlPerKgPerMin, .kilograms, .beatsPerMinute, .fraction: return .other
        }
    }

    /// The evening note reads every evening rule, the in-bed rule too, so "Still to come before bed" ends with going to
    /// bed (ICP R3-OPT-15). A rule's kept time is the time its source measured.
    static func eveningInput(_ day: TodayRailProtocolDay) -> EveningNoteInput {
        let checks = Dictionary(day.checks.map { ($0.ruleKey, $0) }, uniquingKeysWith: { _, newer in newer })
        let rules = day.rules.filter(\.isEvening)
        return EveningNoteInput(rules: rules.map { rule in
            let check = checks[rule.key]
            let state = check?.state ?? .unknown
            let metric = rule.target.metric.flatMap(RoutineMetric.init(rawValue:))
            var keptAt: Int?
            if state == .kept, metric?.isTimeOfDay == true, let value = check?.measuredValue, value.isFinite, value >= 0 {
                keptAt = Int(value.rounded()) % 1_440
            }
            return NoteRuleDay(rule: rule, state: state, keptAtMinuteOfDay: keptAt,
                               keptLabel: metric == .lastMealTime ? "Kitchen closed" : nil,
                               keptDaysThisWeek: state == .kept ? day.keptThisWeek[rule.key] : nil,
                               daysThisWeek: day.daysThisWeek)
        })
    }

    /// The strip for the running experiment on the night that starts on `tonight`: its number, the outcome fixed on day
    /// 1, RoutineKit's line for tonight's arm and one bead per planned night. Nil when it is not running or tonight is
    /// outside the plan.
    static func experimentInput(_ experiment: Experiment, tonight: DayIdentity) -> TodayExperimentInput? {
        guard experiment.status == .running else { return nil }
        let schedule = experiment.schedule
        guard let night = schedule.nightNumber(on: tonight) else { return nil }
        let beads = schedule.nights.map { scheduled -> TodayExperimentBead in
            let arm: TodayExperimentBead.Arm = switch scheduled.role {
            case .on: .on
            case .off: .off
            case .washout, .outside: .washout
            }
            let phase: TodayExperimentBead.Phase = scheduled.number < night ? .past : scheduled.number == night ? .tonight : .future
            return TodayExperimentBead(arm: arm, phase: phase)
        }
        return TodayExperimentInput(title: experiment.start.title, night: night, plannedNights: experiment.start.plannedNights,
                                    outcome: experiment.start.outcome.title,
                                    tonight: ExperimentCopy.tonight(role: schedule.role(on: tonight),
                                                                    interventionName: experiment.start.interventionName),
                                    beads: beads, isRunning: true)
    }

    // MARK: Morning

    /// The morning note's factor: how long before bed the last meal was. Four hours or more against less.
    static let mealToBedFactorID = "meal-to-bed"
    static let fourHoursGroup = NoteFactorGroup(id: "four-hours", label: "4 h or more")
    static let lessGroup = NoteFactorGroup(id: "less", label: "less")
    static let fourHoursMinutes = 240.0
    /// A meal more than this long before bed belongs to another day.
    static let mealWindow: TimeInterval = 20 * 3_600

    /// - Parameters:
    ///   - outcomes: sleeping heart rate by the day the night ended, the dial's 30 days.
    ///   - bedtimes: when the main sleep started, by the same day.
    ///   - meals: every meal time around those nights.
    static func morningInput(today: DayIdentity, outcomes: [DayIdentity: Double], bedtimes: [DayIdentity: Date],
                             meals: [Date], windowDays: Int = TodayDialSources.heartRateHistoryDays) -> MorningNoteInput {
        let lastNight = outcomes[today].flatMap { $0.isFinite && $0 > 0 ? NightOutcome(kind: .sleepHeartRate, value: $0, day: today) : nil }
        let todayKey = today.routineDayKey ?? ""
        let prior = outcomes.filter { ($0.key.routineDayKey ?? "") < todayKey && $0.value.isFinite && $0.value > 0 }
        let usual = median(Array(prior.values)).map { NoteUsual(median: $0, nights: prior.count, windowDays: windowDays) }

        func gap(_ day: DayIdentity) -> Double? {
            guard let bed = bedtimes[day],
                  let meal = meals.filter({ $0 < bed && bed.timeIntervalSince($0) <= mealWindow }).max() else { return nil }
            return bed.timeIntervalSince(meal) / 60
        }
        func groupID(_ minutes: Double) -> String { minutes >= fourHoursMinutes ? fourHoursGroup.id : lessGroup.id }

        var factors: [NightFactor] = []
        if let lastGap = gap(today) {
            let days = outcomes.keys.sorted { ($0.routineDayKey ?? "") < ($1.routineDayKey ?? "") }
            let history = days.compactMap { day -> NoteFactorNight? in
                guard let minutes = gap(day), let value = outcomes[day], value.isFinite, value > 0 else { return nil }
                return NoteFactorNight(day: day, groupID: groupID(minutes), outcome: value)
            }
            factors.append(NightFactor(id: mealToBedFactorID, name: "Last meal to bed",
                                       statement: "You stopped eating {value} before bed.",
                                       lastNightValue: .duration(minutes: lastGap), lastNightGroupID: groupID(lastGap),
                                       groups: [fourHoursGroup, lessGroup], history: history))
        }
        return MorningNoteInput(lastNight: lastNight, usual: usual, factors: factors)
    }

    static func median(_ values: [Double]) -> Double? {
        let sorted = values.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    /// The day `date` falls on in `calendar`.
    static func day(_ date: Date, calendar: Calendar) -> DayIdentity {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return DayIdentity(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
    }
}

// MARK: - Live readers

/// Remembers when each past night started, per storage generation, so Today does not read thirty nights on every visit.
/// Today's night is always read again.
actor TodayNightStartCache {
    static let shared = TodayNightStartCache()
    private var generation: UInt64?
    private var starts: [String: Date?] = [:]

    func start(for day: DayIdentity, isToday: Bool, generation: UInt64?, read: @Sendable () async -> Date?) async -> Date? {
        if generation != self.generation { starts = [:]; self.generation = generation }
        let key = day.routineDayKey ?? ""
        if !isToday, let cached = starts[key] { return cached }
        let value = await read()
        if !isToday { starts[key] = value }
        return value
    }
}

extension TodayNoteRailSources {
    /// A tick or an Undo on Today: the rule's delivered reminders clear and the reminders are planned again, so a week
    /// whose count is now met goes quiet (ICP round 4, Q5 and HAB).
    nonisolated static func ruleAnswered(_ key: RuleKey) async {
        #if canImport(UserNotifications)
        await ProtocolRuleReminderPlanning.shared.answered(key)
        #endif
    }

    /// Reads the production stores. Fixture compositions read the Today fixture in DEBUG builds and nothing otherwise.
    @MainActor
    static func live(environment: AppEnvironment, repositories: ProductRepositoryContainer?, history: any MetricHistoryProviding,
                     bandName: String = "") -> TodayNoteRailSources {
        #if DEBUG
        // Only the populated fixture carries a protocol and nights; the other fixtures keep Today without them.
        if repositories?.isFixtureComposition != false, environment.composition == .populated, let fixture = TodayNoteRailFixture.sources(environment: environment, repositories: repositories,
                                                                                                    history: history, bandName: bandName) {
            return fixture
        }
        #endif
        guard let repositories, let persistent = repositories.persistent else { return TodayNoteRailSources(bandName: bandName) }
        let wiring = TodayRoutineWiring.make(environment: environment, repositories: repositories, persistent: persistent)
        let store = wiring.store
        let experiments = ExperimentStore(database: persistent.database)
        let sleep = persistent.sleep
        let food = AppFoodRepository(store: persistent.food, environment: environment)
        let generation = repositories.storageGeneration
        let provider = wiring.provider
        #if canImport(UserNotifications)
        // The rule reminders count what the sources saw this week too (ICP round 4, Q5).
        Task { await ProtocolRuleReminderPlanning.shared.attach { day, zone, now in
            try await provider.snapshots(for: day, timeZoneID: zone.identifier, now: now)
        } }
        #endif

        let readProtocol: @Sendable (DayIdentity, Date, TimeZone) async throws -> TodayRailProtocolDay? = { day, now, zone in
            try await TodayNoteRailReaders.protocolDay(store: store, day: day, now: now, zone: zone) { day, zone, now in
                try await provider.snapshots(for: day, timeZoneID: zone.identifier, now: now)
            }
        }
        let readMorning: @Sendable (DayIdentity, Calendar) async -> MorningNoteInput? = { day, calendar in
            await TodayNoteRailReaders.morning(day: day, calendar: calendar, history: history, generation: generation,
                                               nightStart: { night in
                                                   guard let main = try? await sleep.readSleepDay(for: night)?.mainSleep,
                                                         !main.isPartial, main.end > main.start else { return nil }
                                                   return main.start
                                               },
                                               meals: { first, last in
                                                   ((try? await food.overview(from: first, through: last))?.meals ?? []).map(\.occurredAt)
                                               })
        }
        return TodayNoteRailSources(
            readProtocol: readProtocol,
            tick: { [habits = persistent.habits, zone = environment.timeZoneProvider] key, day, now in
                let stored = try RoutineDayEvaluation(store: store).tickOnce(ruleKey: key, day: day, at: now) != nil
                // A rule that was a Journal habit question keeps the habit's history in step (ICP R1-UPG-1).
                await RoutineHabitAnswerMirror.ruleChanged(key, day: day, store: store, habits: habits,
                                                           timeZoneID: zone.timeZone.identifier)
                // The bedtime activity shows the same rules as steps, so it learns of the tick at once.
                await BedtimeActivityRuntime.shared.reconcile()
                await Self.ruleAnswered(key)
                return stored
            },
            untick: { key, day, now, zone in
                let sources = (try? await provider.snapshots(for: day, timeZoneID: zone.identifier, now: now)) ?? RoutineSourceSnapshots()
                _ = try RoutineDayEvaluation(store: store).untick(ruleKey: key, day: day, now: now, timeZone: zone, sources: sources)
                await BedtimeActivityRuntime.shared.reconcile()
                await Self.ruleAnswered(key)
            },
            readExperiment: { try? experiments.running() },
            readMorning: readMorning,
            rewriter: CoachRewriter.system(),
            bedtimeEnabled: { await BedtimeActivityPreference.isEnabled() },
            firstEveningDismissed: { TodayFirstEveningStore.isDismissed },
            bandName: bandName)
    }
}

/// The reads behind the live sources, apart so tests run them on an in-memory store.
nonisolated enum TodayNoteRailReaders {
    /// Evaluates the day through `RoutineDayEvaluation`, the same call the Protocol tab and the bedtime activity make,
    /// and counts this week's kept days per rule from the stored checks.
    static func protocolDay(store: RoutineStore, day: DayIdentity, now: Date, zone: TimeZone,
                            snapshots: @Sendable (DayIdentity, TimeZone, Date) async throws -> RoutineSourceSnapshots) async throws
        -> TodayRailProtocolDay? {
        guard let active = try store.activeProtocol() else { return nil }
        let sources = try await snapshots(day, zone, now)
        let result = try RoutineDayEvaluation(store: store).evaluate(day: day, now: now, timeZone: zone, sources: sources)
        // The rules the checks were decided against, so a row never pairs one version's target with another's verdict:
        // "48 of 50 min" is never kept by a 45-minute check (ICP R3-OPT-2).
        let version = try result.flatMap { try store.version(protocolID: active.routineProtocol.id, number: $0.summary.version) }
            ?? active.latestVersion
        let checks = result?.checks ?? []
        let protocolID = active.routineProtocol.id
        let week = ProtocolWeekCalendar(timeZone: zone, locale: Locale(identifier: "en_US_POSIX"))
        var keptThisWeek: [RuleKey: Int] = [:]
        var daysThisWeek: Int?
        var due = version.rules
        if let weekday = week.isoWeekday(day), let monday = day.adding(days: 1 - weekday) {
            daysThisWeek = weekday
            for rule in version.rules {
                let history = try store.history(protocolID: protocolID, ruleKey: rule.key, from: monday, through: day)
                keptThisWeek[rule.key] = history.filter { $0.state == .kept }.count
            }
            due = try dueRules(version.rules, checks: checks, day: day, keptThisWeek: keptThisWeek) { rule in
                try store.history(protocolID: protocolID, ruleKey: rule.key, through: day)
            }
        }
        let dueKeys = Set(due.map(\.key))
        var protocolDay = TodayRailProtocolDay(rules: due, checks: checks.filter { dueKeys.contains($0.ruleKey) })
        protocolDay.daysThisWeek = daysThisWeek
        protocolDay.keptThisWeek = keptThisWeek.filter { key, _ in version.rules.contains { $0.key == key && $0.isEvening } }
        return protocolDay
    }

    /// The rules Today lists and counts: the ones the check-in's deck asks today (`ProtocolDeckQueue.isDue`, ICP
    /// R3-NEW-07), so a blood panel every 3 months is not "Tap to tick" every day and "4 of 11 kept" counts what is due.
    /// The test reads the week and the history as they stood this morning, so a rule kept today stays on the list as
    /// kept. A rule with an answer today, kept, not kept or skipped, always stays.
    /// - Parameter history: the rule's stored checks through `day`, read only for a rule every few days, weeks or months.
    static func dueRules(_ rules: [ProtocolRule], checks: [RuleCheck], day: DayIdentity, keptThisWeek: [RuleKey: Int],
                         history: (ProtocolRule) throws -> [RuleCheck]) rethrows -> [ProtocolRule] {
        let today = Dictionary(checks.map { ($0.ruleKey, $0.state) }, uniquingKeysWith: { _, newer in newer })
        return try rules.filter { rule in
            let state = today[rule.key]
            if state == .kept || state == .missed || state == .skipped { return true }
            let kept = keptThisWeek[rule.key] ?? 0
            var progress: RuleProgress?
            if let cadence = rule.cadence, !cadence.isDaily, cadence.unit != .week || cadence.every != 1 {
                let before = try history(rule).filter { $0.day != day }
                progress = RuleProgressReader.progress(for: rule, week: [], history: before, readings: [:])
            }
            return ProtocolDeckQueue.isDue(rule, on: day, keptThisWeek: kept, progress: progress)
        }
    }

    /// The morning note's input: the dial's 30 days of sleeping heart rate, when each night started and the meals
    /// before it.
    static func morning(day: DayIdentity, calendar: Calendar, history: any MetricHistoryProviding, generation: UInt64?,
                        nightStart: @escaping @Sendable (DayIdentity) async -> Date?,
                        meals: @Sendable (String, String) async -> [Date]) async -> MorningNoteInput? {
        guard let clock = TodayDialClock(day: day, calendar: calendar),
              let points = try? await history.series(for: .sleepingHeartRate, days: TodayDialSources.heartRateHistoryDays,
                                                     endingOn: clock.start.addingTimeInterval(12 * 3_600)) else { return nil }
        var outcomes: [DayIdentity: Double] = [:]
        for point in points where point.value.isFinite && point.value > 0 {
            outcomes[TodayNoteRailMapping.day(point.day, calendar: calendar)] = point.value
        }
        var bedtimes: [DayIdentity: Date] = [:]
        if outcomes[day] != nil {
            for night in outcomes.keys {
                let start = await TodayNightStartCache.shared.start(for: night, isToday: night == day, generation: generation) {
                    await nightStart(night)
                }
                if let start { bedtimes[night] = start }
            }
        }
        let keys = outcomes.keys.compactMap(\.routineDayKey).sorted()
        var mealTimes: [Date] = []
        if !bedtimes.isEmpty, let first = keys.first, let last = keys.last,
           let before = DayIdentity(routineDayKey: first)?.adding(days: -1)?.routineDayKey {
            mealTimes = await meals(before, last)
        }
        return TodayNoteRailMapping.morningInput(today: day, outcomes: outcomes, bedtimes: bedtimes, meals: mealTimes)
    }
}

/// The routine store and the source snapshots behind the rail and the bedtime activity, built once from the
/// production repositories the way the dial builds them.
nonisolated struct TodayRoutineWiring: Sendable {
    let store: RoutineStore
    let provider: RoutineSourceProvider

    @MainActor
    static func make(environment: AppEnvironment, repositories: ProductRepositoryContainer,
                     persistent: PersistentProductRepositories) -> TodayRoutineWiring {
        let sleep = SleepNightDetails.repository(environment: environment, repositories: repositories)
        let food = AppFoodRepository(store: persistent.food, environment: environment)
        let workouts = repositories.workoutStore
        let readTraining: (@Sendable () async throws -> [WorkoutRecord])? = workouts.map { store in { @Sendable in await store.all() } }
        let provider = RoutineSourceProvider.live(food: food, sleep: sleep, readTraining: readTraining,
                                                  analytics: persistent.analytics,
                                                  appleHealth: persistent.healthSync.appleHealthSources())
        return TodayRoutineWiring(store: RoutineStore(database: persistent.database), provider: provider)
    }
}

/// Whether the person said "Not now" to the first-evening card. Production keeps it in the standard defaults; fixture
/// launches keep it for the launch only, so every UI test starts with the card.
nonisolated enum TodayFirstEveningStore {
    static let defaultsKey = "loopr.today.firstEveningDismissed"
    private static let launchOnly = Mutex(false)

    static var isDismissed: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

    static var isDismissedThisLaunch: Bool { launchOnly.withLock { $0 } }

    /// "Not now". Production remembers it; a fixture launch forgets it at the next launch.
    static func dismiss(persisting: Bool) {
        if persisting { UserDefaults.standard.set(true, forKey: defaultsKey) } else { launchOnly.withLock { $0 = true } }
    }
}
