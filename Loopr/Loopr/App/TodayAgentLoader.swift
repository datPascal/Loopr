import BodyKit
import DataKit
import DeviceCenterKit
import DomainKit
import FoodKit
import Foundation
import JournalKit
import RoutineKit
import SleepKit
import TodayKit
import TrainKit

/// Where a tap on Today's injected sections goes.
nonisolated enum TodayAgentDestination: Equatable {
    case tab(MainTab)
    case patterns
    /// One number's method page, pushed on Data's stack (DEC-12.20).
    case method(MethodID)
    /// The Protocol tab at its root on one segment.
    case protocolSegment(ProtocolSegment)
    /// All metrics on Data's stack: Today's "All 7 pinned" row, since Data's root no longer lists the pins (Data ICP R1).
    case allMetrics

    /// The alarm row opens the wake alarm screen, which is a route on Today's own stack, not a tab.
    static func opensWakeAlarm(_ action: TodayAgentAction) -> Bool { action == .timelineItem("alarm") }

    static func destination(for action: TodayAgentAction) -> TodayAgentDestination? {
        switch action {
        case .yourDayRow(let id):
            switch id {
            case "food": .tab(.food)
            case "train": .tab(.fitness)
            case "journal": .tab(.protocol)
            default: nil
            }
        case .timelineItem(let id):
            if id.hasPrefix("meal-") { .tab(.food) }
            else if id.hasPrefix("workout-") { .tab(.fitness) }
            else if id.hasPrefix("reminder-") { .patterns }
            else { nil }
        case .patterns, .startPatternTest:
            .patterns
        }
    }
}

/// Reads Food, Train, Journal, Sleep and Patterns for one day and builds Today's slot content. Every read is
/// from this phone's own stores. A store that fails to read leaves its row out. Today never shows a guess.
@MainActor
struct TodayAgentLoader {
    let environment: AppEnvironment
    let repositories: ProductRepositoryContainer?
    let history: any MetricHistoryProviding
    /// Reads the wake alarm. Nil uses the one the Sleep card and the alarm screen use. Tests pass their own.
    var alarmController: (any WakeAlarmControlling)? = nil
    /// Fixture launches read `--loopr-today-clock=` from these, as the dial does.
    var arguments = ProcessInfo.processInfo.arguments

    /// The day's clock. Fixture launches pin the zone and the time so what is ahead never drifts.
    var clock: (now: Date, calendar: Calendar) {
        var calendar = Calendar(identifier: .gregorian)
        if repositories?.isFixtureComposition != false {
            calendar.timeZone = TimeZone(identifier: "Australia/Perth") ?? .gmt
            return (environment.dateProvider.now(), calendar)
        }
        calendar.timeZone = environment.timeZoneProvider.timeZone
        return (environment.dateProvider.now(), calendar)
    }

    /// - Parameter includesAlarm: False when this phone shows no wake alarm, as with an experimental band.
    func load(day: DayIdentity, isToday: Bool, includesAlarm: Bool = true) async -> TodayAgentContent {
        let clock = clock
        let calendar = clock.calendar
        guard let noon = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12)),
              let start = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day)) else { return .empty }
        // Fixtures stand on the dial's pinned clock: 13:30, or 07:12 and 19:49 with `--loopr-today-clock=`. Production reads
        // the real clock.
        let now = repositories?.isFixtureComposition != false
            ? Self.fixtureNow(day: day, calendar: calendar, arguments: arguments) ?? start.addingTimeInterval(13.5 * 3_600)
            : clock.now
        let parts = calendar.dateComponents([.hour, .minute], from: now)
        var inputs = TodayAgentInputs(nowMinute: (parts.hour ?? 0) * 60 + (parts.minute ?? 0))

        if let food = await foodFacts(noon: noon, calendar: calendar) { inputs.food = food.facts; inputs.meals = food.meals }
        await loadTrain(into: &inputs, day: day, now: now, calendar: calendar, isToday: isToday)
        inputs.wake = await wake(day: day)
        if isToday {
            if includesAlarm { inputs.alarm = await alarm(now: now, calendar: calendar) }
            let plan = await SleepNightDetails.tonightPlan(day: day, environment: environment, repositories: repositories)
            inputs.bedtime = TodayAgentSlotBuilder.bedtime(plan)
            inputs.sleepExtraMinutes = plan?.extraMinutes ?? 0
            inputs.inBedRuleMinute = inBedRuleMinute()
        }
        if LooprPatternsRuntime.isEnabled, let snapshot = await patternsSnapshot() {
            inputs.patterns = snapshot
            inputs.patternsEnabled = true
            inputs.reminders = isToday ? TodayAgentSlotBuilder.reminders(snapshot, enabled: true) : []
        }
        if !isToday { inputs.train = pastTrain(inputs.train) }
        return TodayAgentSlotBuilder.content(inputs)
    }

    /// The person's own "In bed by" rule from the active protocol, the bedtime Today shows (ICP R3-OPT-7). Nil without
    /// a protocol or such a rule.
    private func inBedRuleMinute() -> Int? {
        var store: RoutineStore?
        if let persistent = repositories?.persistent { store = RoutineStore(database: persistent.database) }
        #if DEBUG
        if store == nil, repositories?.isFixtureComposition == true { store = ProtocolTabFixture.stores(environment: environment)?.routine }
        #endif
        guard let rules = (try? store?.activeProtocol())?.latestVersion.rules,
              let value = rules.first(where: { $0.target.metric == RoutineMetric.inBedTime.rawValue })?.target.value,
              value.isFinite else { return nil }
        return Int(value.rounded())
    }

    /// The fixture's "now" on `day`: the same wall-clock minute the dial's fixture clock pins, so the timeline's past and
    /// upcoming rows agree with the dial and the note.
    nonisolated static func fixtureNow(day: DayIdentity, calendar: Calendar, arguments: [String]) -> Date? {
        TodayDialFixtureClock.now(day: day, calendar: calendar, arguments: arguments)
    }

    // MARK: Alarm

    /// The same alarm state the Sleep card and the wake alarm screen read. Nil when it is off or there is no store.
    private func alarm(now: Date, calendar: Calendar) async -> TodayAlarmFact? {
        guard let controller = alarmController ?? WakeAlarmControllerFactory.make(repositories: repositories) else { return nil }
        let snapshot = await controller.snapshot()
        guard snapshot.isOn else { return nil }
        return TodayAgentSlotBuilder.alarm(WakeAlarmPlan(configuration: snapshot.configuration),
                                           weekday: calendar.component(.weekday, from: now))
    }

    // MARK: Food

    private var foodRepository: AppFoodRepository? {
        if let persistent = repositories?.persistent { return AppFoodRepository(store: persistent.food, environment: environment) }
        #if DEBUG
        return repositories?.fixtureFoodRepository
        #else
        return nil
        #endif
    }

    private var bodyRepository: (any BodyRepository)? { repositories?.persistent?.body }

    private func foodFacts(noon: Date, calendar: Calendar) async -> (facts: TodayFoodFacts, meals: [TodayMealFact])? {
        guard let repository = foodRepository, let key = try? FoodMeal.day(at: noon, timeZoneIdentifier: calendar.timeZone.identifier),
              let data = try? await repository.overview(from: key, through: key),
              let summary = try? await FoodOverviewModel.summary(date: noon, calendar: calendar, data: data, body: bodyRepository).summary
        else { return nil }
        return (facts: TodayFoodFacts(summary), meals: summary.meals.map(TodayMealFact.init))
    }

    // MARK: Train

    private var trainRepository: AppTrainRepository? { repositories?.makeTrainRepository() }

    /// Reads what the Train overview reads, without saving the scheduler's decisions. Opening Train does that.
    private func loadTrain(into inputs: inout TodayAgentInputs, day: DayIdentity, now: Date, calendar: Calendar, isToday: Bool) async {
        guard let repository = trainRepository else { return }
        var clockCalendar = calendar
        var clockNow = now
        var series = history
        #if DEBUG
        if repositories?.isFixtureComposition != false, AppTrainFixtures.isRequested() {
            clockCalendar = AppTrainFixtures.calendar
            clockNow = AppTrainFixtures.now
            series = TrainFixtureMetricHistory()
        }
        #endif
        // Another day reads the overview as of that day, so its week and its sessions are the ones in the overview.
        if !isToday, let noon = clockCalendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12)) {
            clockNow = noon
        }
        guard let templates = try? await repository.templates(), let programs = try? await repository.programs(),
              let sessions = try? await repository.recentSessions(limit: 200, status: .completed) else { return }
        let readings = await TrainRecoveryProvider(history: series).readings(endingOn: clockNow, calendar: clockCalendar)
        let input = TrainOverviewInput(now: clockNow, calendar: clockCalendar, templates: templates, programs: programs,
                                       sessions: sessions, recovery: readings)
        let overview = TrainOverviewModel(input).overview
        inputs.train = overview.today
        let today = ProgramScheduler(calendar: clockCalendar).localDay(for: clockNow)
        inputs.finishedSessions = sessions.filter { $0.localDay == today }.compactMap { session in
            guard let summary = overview.thisWeek.first(where: { $0.id == session.id }) else { return nil }
            let parts = clockCalendar.dateComponents([.hour, .minute], from: session.startedAt)
            return (summary: summary, startMinute: (parts.hour ?? 0) * 60 + (parts.minute ?? 0))
        }
    }

    /// A past day has nothing planned. Only what was finished stays.
    private func pastTrain(_ today: TrainToday) -> TrainToday {
        if case .plan = today { return .none }
        return today
    }

    // MARK: Sleep

    private func wake(day: DayIdentity) async -> (minuteOfDay: Int, sleepMinutes: Int?)? {
        let repository = SleepNightDetails.repository(environment: environment, repositories: repositories)
        guard let snapshot = try? await repository.readSleepDay(for: day), let night = snapshot.mainSleep,
              !night.isPartial, night.end > night.start else { return nil }
        let parts = SleepClock.calendar(environment: environment, repositories: repositories).dateComponents([.hour, .minute], from: night.end)
        return ((parts.hour ?? 0) * 60 + (parts.minute ?? 0), night.durationMinutes)
    }

    // MARK: Patterns

    private func patternsSnapshot() async -> PatternsSnapshot? {
        if let persistent = repositories?.persistent {
            guard let engine = try? LooprPatternsRuntime.shared.configure(persistent) else { return nil }
            return try? await engine.snapshot()
        }
        #if DEBUG
        if repositories?.isFixtureComposition != false {
            return try? await PatternsFixtures.shared().engine.snapshot()
        }
        #endif
        return nil
    }

    /// Starts the 14-day test for a pattern on Today's card, the same way the Patterns detail does.
    func startTest(candidateID: String) async -> Bool {
        let engine: PatternsEngine?
        if let persistent = repositories?.persistent { engine = try? LooprPatternsRuntime.shared.configure(persistent) }
        else {
            #if DEBUG
            engine = repositories?.isFixtureComposition != false ? await PatternsFixtures.shared().engine : nil
            #else
            engine = nil
            #endif
        }
        guard let engine, let snapshot = try? await engine.snapshot(),
              let pattern = snapshot.found.first(where: { $0.candidateID == candidateID }) else { return false }
        return (try? await engine.startTest(candidateID: pattern.candidateID, metric: pattern.metric.rawValue,
                                            reminderMinuteOfDay: snapshot.settings.defaultReminderMinuteOfDay)) != nil
    }
}

/// The zone Sleep's nights and the step history are written in. The fixture night is built in the phone's zone, so
/// fixture launches read it there. Everything else reads the zone the app uses for its days.
@MainActor
enum SleepClock {
    static func calendar(environment: AppEnvironment, repositories: ProductRepositoryContainer?) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = repositories?.isFixtureComposition != false ? Calendar.current.timeZone : environment.timeZoneProvider.timeZone
        return calendar
    }
}
