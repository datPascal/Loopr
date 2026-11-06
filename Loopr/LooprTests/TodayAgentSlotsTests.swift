import DesignSystem
import DeviceCenterKit
import DomainKit
import Foundation
import JournalKit
import SleepKit
import Testing
import TodayKit
import TrainKit
@testable import Loopr

private typealias F = PatternsFixtures4b

/// What the app puts into Today's slots: the Your day rows for Food, Train and Journal, the timeline moments, the
/// pattern card and its hidden states, where each tap goes, and the Sleep comparison's day arithmetic.
@MainActor
struct TodayAgentSlotsTests {
    // MARK: Food

    @Test func foodRowShowsEnergyAgainstTheTargetAndProtein() throws {
        let row = try #require(TodayAgentSlotBuilder.foodRow(TodayFoodFacts(
            energy: 1_232, energyTarget: 2_450, protein: 82, proteinTarget: 150, hasEntries: true)))
        #expect(row.id == "food")
        // The app's one number formatter, as the dial's steps tile uses (ICP R2-OPT-9).
        #expect(row.value == "1,232")
        #expect(row.unit == "of 2,450 kcal")
        #expect(row.caption == "Protein 82 of 150 g")
        #expect(row.identifier == "today-your-day-food")
    }

    /// ICP R2-OPT-1: the day's total counts drinks, so the row says how much of it they are.
    @Test func foodRowNamesTheEnergyFromDrinks() throws {
        let row = try #require(TodayAgentSlotBuilder.foodRow(TodayFoodFacts(
            energy: 1_240, energyTarget: 2_450, protein: 82, proteinTarget: 150, hasEntries: true, drinkEnergy: 8)))
        #expect(row.caption == "Protein 82 of 150 g · 8 kcal from drinks")
    }

    @Test func foodRowWithoutATargetStillShowsWhatWasEaten() throws {
        let row = try #require(TodayAgentSlotBuilder.foodRow(TodayFoodFacts(
            energy: 640, energyTarget: nil, protein: 30, proteinTarget: nil, hasEntries: true)))
        #expect(row.value == "640")
        #expect(row.unit == "kcal")
        #expect(row.caption == "Protein 30 g")
    }

    @Test func foodRowSaysNothingLoggedWhenThereIsATargetButNoMeals() throws {
        let row = try #require(TodayAgentSlotBuilder.foodRow(TodayFoodFacts(
            energy: nil, energyTarget: 2_450, protein: nil, proteinTarget: 150, hasEntries: false)))
        #expect(row.value == "0")
        #expect(row.unit == "of 2,450 kcal")
        #expect(row.caption == "Nothing logged yet")
    }

    @Test func foodRowIsHiddenWithNeitherMealsNorATarget() {
        #expect(TodayAgentSlotBuilder.foodRow(nil) == nil)
        #expect(TodayAgentSlotBuilder.foodRow(TodayFoodFacts(energy: nil, energyTarget: nil, protein: nil, proteinTarget: nil, hasEntries: false)) == nil)
    }

    // MARK: Train

    private func overview(sessions: [TrainSession] = []) -> TrainOverview {
        TrainOverviewModel(TrainOverviewInput(
            now: AppTrainFixtures.now, calendar: AppTrainFixtures.calendar,
            templates: [AppTrainFixtures.upperA, AppTrainFixtures.lowerA, AppTrainFixtures.lowerB, AppTrainFixtures.upperB, AppTrainFixtures.zoneTwo],
            programs: [AppTrainFixtures.strengthBlock], sessions: sessions,
            recovery: AppTrainFixtures.recoveryScores.map { RecoveryReading(localDay: $0.day, score: $0.score) })).overview
    }

    @Test func trainRowNamesTheSessionAndItsPlannedTime() throws {
        let row = try #require(TodayAgentSlotBuilder.trainRow(overview().today, finished: [], locale: Locale(identifier: "en_GB")))
        #expect(row.id == "train")
        #expect(row.title == "Upper A at 18:30")
        #expect(row.chip == "Planned")
        #expect(row.caption?.hasPrefix("6 exercises") == true)
        #expect(row.value == nil)
    }

    @Test func trainRowIsHiddenWithNoTemplatesAndNamesARestDay() throws {
        #expect(TodayAgentSlotBuilder.trainRow(.none, finished: []) == nil)
        let rest = try #require(TodayAgentSlotBuilder.trainRow(.rest(next: "Lower B on Thursday"), finished: []))
        #expect(rest.title == "Rest day")
        #expect(rest.caption == "Next is Lower B on Thursday")
        #expect(rest.chip == nil)
    }

    // MARK: Protocol

    private static func rule(_ key: String, _ state: TodayDialRuleState, source: TodayDialRuleSource = .manual,
                             evening: Bool = false) -> TodayRailRuleInput {
        TodayRailRuleInput(key: key, title: key, source: source, isEvening: evening, state: state)
    }

    /// ICP R2-UPG-15: the rail under the dial counts the rules, so "Your day" carries no second Protocol count.
    @Test func yourDayLeavesTheProtocolCountToTheRail() throws {
        let content = TodayAgentContent(yourDayRows: [TodayYourDayRow(id: "food", title: "Food"),
                                                      TodayYourDayRow(id: "journal", title: "Protocol")])
        #expect(TodayAgentSlotBuilder.withoutProtocolRow(content).yourDayRows.map(\.id) == ["food"])
    }

    // MARK: Timeline

    @Test func timelineHoldsWakeMealsThePlannedWorkoutAndReminders() throws {
        var inputs = TodayAgentInputs(nowMinute: 13 * 60 + 30)
        inputs.wake = (minuteOfDay: 6 * 60 + 52, sleepMinutes: 462)
        inputs.meals = [
            TodayMealFact(id: "b", minuteOfDay: 7 * 60 + 30, slot: "Breakfast", items: ["Yogurt", "berries", "granola"], energy: 520),
            TodayMealFact(id: "l", minuteOfDay: 12 * 60 + 40, slot: "Lunch", items: ["Chicken rice bowl"], energy: nil),
        ]
        inputs.train = overview().today
        inputs.reminders = [TodayReminderFact(id: "t1", minuteOfDay: 20 * 60 + 15, title: "Pattern check-in", detail: "Kitchen closed at 20:30")]
        let items = TodayAgentSlotBuilder.timeline(inputs)
        #expect(items.map(\.id) == ["wake", "meal-b", "meal-l", "workout-planned", "reminder-t1"])
        #expect(items.map(\.kind) == [.wake, .meal, .meal, .workout, .reminder])
        #expect(items[0].detail == "Slept 7 h 42 m")
        #expect(items[1].detail == "Yogurt, berries, granola · 520 kcal")
        #expect(items[2].detail == "Chicken rice bowl")
        #expect(items[3].detail == "Planned")
        #expect(items[3].minuteOfDay == 18 * 60 + 30)
        // Through TodayKit's rules the planned workout and the reminder are still ahead at 13:30.
        let rows = TodayTimelineRules.rows(items: items, tonight: nil, nowMinute: inputs.nowMinute)
        #expect(rows.map(\.isDimmed) == [false, false, false, true, true])
    }

    @Test func aPlannedSessionWithoutATimeIsLeftOutOfTheTimelineButKeepsItsRow() {
        // The Zone 2 template is planned on Wednesday with no start time, so the timeline has no place for it.
        let wednesday = TrainOverviewModel(TrainOverviewInput(
            now: AppTrainFixtures.now.addingTimeInterval(86_400), calendar: AppTrainFixtures.calendar,
            templates: [AppTrainFixtures.zoneTwo], programs: [], sessions: [], recovery: [])).overview
        var inputs = TodayAgentInputs(nowMinute: 600)
        inputs.train = wednesday.today
        #expect(TodayAgentSlotBuilder.timeline(inputs).isEmpty)
        #expect(TodayAgentSlotBuilder.trainRow(wednesday.today, finished: []) != nil)
    }

    @Test func contentBundlesRowsInOrderAndCarriesTheClock() {
        var inputs = TodayAgentInputs(nowMinute: 810)
        inputs.food = TodayFoodFacts(energy: 1_232, energyTarget: 2_450, protein: 82, proteinTarget: 150, hasEntries: true)
        inputs.train = overview().today
        let content = TodayAgentSlotBuilder.withoutProtocolRow(TodayAgentSlotBuilder.content(inputs))
        #expect(content.yourDayRows.map(\.id) == ["food", "train"])
        #expect(content.nowMinute == 810)
        #expect(content.pattern == nil)
    }

    // MARK: Bedtime

    private var fixtureEnvironment: AppEnvironment {
        AppEnvironment(composition: .populated, root: .main, storageURL: nil, applicationVersion: "test",
                       dateProvider: SystemDateProvider(), calendarProvider: SystemCalendarProvider(),
                       timeZoneProvider: SystemTimeZoneProvider(timeZone: TimeZone(identifier: "Australia/Perth")!),
                       uuidProvider: SystemUUIDProvider(), scheduler: SystemScheduler())
    }

    /// The Sleep tab and the Today timeline read one night. The timeline's Bedtime row must show the time and the
    /// sleep length of the Tonight card, not Today's own wake-minus-need sum.
    @Test func theTimelineBedtimeIsTheBedtimeOnSleepsTonightCard() async throws {
        let environment = fixtureEnvironment
        let model = SleepNightDetails.viewModel(environment: environment, repositories: nil)
        await model.load(day: SleepFixtures.day)
        let plan = try #require(model.insights?.tonight, "the fixture night has enough nights for a plan")

        let loader = TodayAgentLoader(environment: environment, repositories: nil, history: EmptyMetricHistoryProvider())
        let content = await loader.load(day: SleepFixtures.day, isToday: true)
        let rows = TodayTimelineRules.rows(items: content.timeline, tonight: nil, nowMinute: content.nowMinute)
        let bedtime = try #require(rows.first { $0.id == "bedtime" })
        #expect(bedtime.time == plan.bedtimeText)
        // Without an "In bed by" rule the row is Sleep's plan, its sleep split into the need and the catch-up (R3-OPT-7).
        #expect(bedtime.detail == "For " + TodayAgentSlotBuilder.sleepPhrase(sleepMinutes: plan.sleepMinutes,
                                                                             extraMinutes: plan.extraMinutes))
        #expect(rows.filter { $0.id == "bedtime" }.count == 1)

        let past = await loader.load(day: SleepFixtures.day, isToday: false)
        #expect(!past.timeline.contains { $0.kind == .bedtime }, "a past day has no bedtime to aim for")
    }

    /// ICP R3-OPT-7: the person's own In bed rule is the bedtime. Sleep's plan is advice under it, in the Sleep card's one
    /// need, and drops out when the two agree.
    @Test func theInBedRuleIsTheBedtimeAndSleepsPlanIsAdvice() {
        let gb = Locale(identifier: "en_GB")
        #expect(TodayAgentSlotBuilder.sleepPhrase(sleepMinutes: 530, extraMinutes: 50) == "8 h of sleep plus 50 min to catch up")
        #expect(TodayAgentSlotBuilder.sleepPhrase(sleepMinutes: 480, extraMinutes: 0) == "8 h of sleep")
        let later = TodayAgentSlotBuilder.bedtimeItem(planMinute: 22 * 60 + 40, sleepMinutes: 530, extraMinutes: 50,
                                                      ruleMinute: 22 * 60 + 30, locale: gb)
        #expect(later.minuteOfDay == 22 * 60 + 30)
        #expect(later.detail == "Your rule. 22:40 would still give you 8 h of sleep plus 50 min to catch up.")
        let earlier = TodayAgentSlotBuilder.bedtimeItem(planMinute: 22 * 60, sleepMinutes: 530, extraMinutes: 50,
                                                        ruleMinute: 22 * 60 + 30, locale: gb)
        #expect(earlier.minuteOfDay == 22 * 60 + 30)
        #expect(earlier.detail == "Your rule. For 8 h of sleep plus 50 min to catch up, go to bed by 22:00.")
        let agrees = TodayAgentSlotBuilder.bedtimeItem(planMinute: 22 * 60 + 33, sleepMinutes: 480, extraMinutes: 0,
                                                       ruleMinute: 22 * 60 + 30, locale: gb)
        #expect(agrees.detail == "Your rule. It gives you 8 h of sleep.")
        let noRule = TodayAgentSlotBuilder.bedtimeItem(planMinute: 22 * 60 + 40, sleepMinutes: 530, extraMinutes: 50, ruleMinute: nil)
        #expect(noRule.minuteOfDay == 22 * 60 + 40 && noRule.detail == "For 8 h of sleep plus 50 min to catch up")
    }

    @Test func noSleepPlanLeavesTheBedtimeToTodaysOwnRule() {
        var inputs = TodayAgentInputs(nowMinute: 600)
        inputs.bedtime = TodayAgentSlotBuilder.bedtime(nil)
        #expect(inputs.bedtime == nil)
        #expect(!TodayAgentSlotBuilder.timeline(inputs).contains { $0.kind == .bedtime })
    }

    // MARK: Wake alarm

    private func plan(on: Bool = true, wake: Int = 6 * 60 + 45, window: Int = 30, days: Set<AlarmWeekday> = WakeAlarmPlan.everyDay) -> WakeAlarmPlan {
        WakeAlarmPlan(isEnabled: on, wakeMinute: wake, smartWindowMinutes: window, weekdays: days)
    }

    @Test func beforeItRingsTheAlarmIsTodaysRowAtTheWakeMinute() throws {
        var inputs = TodayAgentInputs(nowMinute: 6 * 60)
        inputs.alarm = TodayAgentSlotBuilder.alarm(plan(), weekday: 3)
        let item = try #require(TodayAgentSlotBuilder.timeline(inputs).first { $0.kind == .alarm })
        #expect(item.id == "alarm")
        #expect(item.minuteOfDay == 6 * 60 + 45)
        #expect(item.title == "Smart alarm")
        #expect(item.detail == "Up to 30 min early")
        #expect(!item.isNextDay)
        #expect(item.isInteractive, "a tap opens the wake alarm screen")
        let row = try #require(TodayTimelineRules.rows(items: [item], tonight: nil, nowMinute: inputs.nowMinute, locale: Locale(identifier: "en_GB")).first)
        #expect(row.time == LooprClockFormat.text(minuteOfDay: 6 * 60 + 45, locale: Locale(identifier: "en_GB")),
                "the time comes from LooprClockFormat like every other row")
        #expect(row.isInteractive)
        #expect(row.isDimmed, "it is still ahead")
    }

    @Test func afterTheMorningTheRowIsTomorrowsAlarmAfterBedtime() throws {
        var inputs = TodayAgentInputs(nowMinute: 13 * 60 + 30)
        inputs.wake = (minuteOfDay: 6 * 60 + 52, sleepMinutes: 462)
        inputs.alarm = TodayAgentSlotBuilder.alarm(plan(wake: 7 * 60), weekday: 3)
        inputs.bedtime = (minuteOfDay: 22 * 60 + 30, sleepMinutes: 480)
        let items = TodayAgentSlotBuilder.timeline(inputs)
        let alarm = try #require(items.first { $0.kind == .alarm })
        #expect(alarm.detail == "Tomorrow, up to 30 min early")
        #expect(alarm.isNextDay)
        let rows = TodayTimelineRules.rows(items: items, tonight: nil, nowMinute: inputs.nowMinute)
        #expect(rows.map(\.id) == ["wake", "bedtime", "alarm"], "tomorrow's alarm comes after tonight's bedtime")
        #expect(rows.map(\.isDimmed) == [false, true, true])
    }

    @Test func anAlarmWithoutASmartWindowIsJustAlarm() throws {
        var inputs = TodayAgentInputs(nowMinute: 6 * 60)
        inputs.alarm = TodayAgentSlotBuilder.alarm(plan(wake: 7 * 60, window: 0), weekday: 3)
        let item = try #require(TodayAgentSlotBuilder.timeline(inputs).first { $0.kind == .alarm })
        #expect(item.title == "Alarm")
        #expect(item.detail == nil)
        inputs.nowMinute = 600
        #expect(try #require(TodayAgentSlotBuilder.timeline(inputs).first { $0.kind == .alarm }).detail == "Tomorrow")
    }

    @Test func anAlarmThatIsOffLeavesNoRow() {
        #expect(TodayAgentSlotBuilder.alarm(plan(on: false), weekday: 3) == nil)
        #expect(TodayAgentSlotBuilder.alarm(nil, weekday: 3) == nil)
        var inputs = TodayAgentInputs(nowMinute: 600)
        inputs.alarm = TodayAgentSlotBuilder.alarm(plan(on: false), weekday: 3)
        #expect(!TodayAgentSlotBuilder.timeline(inputs).contains { $0.kind == .alarm })
    }

    @Test func anAlarmNotSetForTheDayItWouldRingStaysOneTapAwayAndSaysSo() throws {
        let mondays: Set<AlarmWeekday> = [.monday]
        var morning = TodayAgentInputs(nowMinute: 5 * 60)
        morning.alarm = TodayAgentSlotBuilder.alarm(plan(days: mondays), weekday: 1)
        #expect(try #require(TodayAgentSlotBuilder.timeline(morning).first { $0.kind == .alarm }).detail == "Not set for today")
        morning.alarm = TodayAgentSlotBuilder.alarm(plan(days: mondays), weekday: 2)
        #expect(try #require(TodayAgentSlotBuilder.timeline(morning).first { $0.kind == .alarm }).detail == "Up to 30 min early")

        var afternoon = TodayAgentInputs(nowMinute: 15 * 60)
        afternoon.alarm = TodayAgentSlotBuilder.alarm(plan(days: mondays), weekday: 1)
        #expect(try #require(TodayAgentSlotBuilder.timeline(afternoon).first { $0.kind == .alarm }).detail == "Tomorrow, up to 30 min early",
                "Sunday afternoon: Monday's alarm is next")
        afternoon.alarm = TodayAgentSlotBuilder.alarm(plan(days: mondays), weekday: 2)
        #expect(try #require(TodayAgentSlotBuilder.timeline(afternoon).first { $0.kind == .alarm }).detail == "Not set for tomorrow")
    }

    @Test func theLoaderShowsTheAlarmOnTodayAndNeverOnAPastDay() async throws {
        let environment = fixtureEnvironment
        let on = FixtureWakeAlarmController(seed: .set)
        let loader = TodayAgentLoader(environment: environment, repositories: nil, history: EmptyMetricHistoryProvider(), alarmController: on)
        let today = await loader.load(day: SleepFixtures.day, isToday: true)
        let alarm = try #require(today.timeline.first { $0.kind == .alarm })
        #expect(alarm.minuteOfDay == 7 * 60)
        #expect(alarm.title == "Smart alarm")

        let past = await loader.load(day: SleepFixtures.day, isToday: false)
        #expect(!past.timeline.contains { $0.kind == .alarm }, "a past day has no alarm row")

        let hidden = await loader.load(day: SleepFixtures.day, isToday: true, includesAlarm: false)
        #expect(!hidden.timeline.contains { $0.kind == .alarm }, "an experimental band shows no alarm, as on Sleep")

        let off = TodayAgentLoader(environment: environment, repositories: nil, history: EmptyMetricHistoryProvider(),
                                   alarmController: FixtureWakeAlarmController(seed: .empty))
        #expect(!(await off.load(day: SleepFixtures.day, isToday: true)).timeline.contains { $0.kind == .alarm })

        let turnedOff = FixtureWakeAlarmController(seed: .set)
        try await turnedOff.turnOff()
        let after = TodayAgentLoader(environment: environment, repositories: nil, history: EmptyMetricHistoryProvider(), alarmController: turnedOff)
        #expect(!(await after.load(day: SleepFixtures.day, isToday: true)).timeline.contains { $0.kind == .alarm },
                "a saved alarm that was switched off leaves no row")
    }

    @Test func theAlarmRowOpensTheWakeAlarmAndNothingElseDoes() {
        #expect(TodayAgentDestination.opensWakeAlarm(.timelineItem("alarm")))
        #expect(!TodayAgentDestination.opensWakeAlarm(.timelineItem("bedtime")))
        #expect(!TodayAgentDestination.opensWakeAlarm(.timelineItem("meal-alarm")))
        #expect(TodayAgentDestination.destination(for: .timelineItem("alarm")) == nil, "it is not a tab or Patterns")
    }

    // MARK: Pattern card

    private func snapshot(found: [FoundPattern], running: [PatternTest] = []) -> PatternsSnapshot {
        PatternsSnapshot(tests: running, found: found)
    }

    private func runningTest(candidate: String) -> PatternTest {
        PatternTest(candidateID: candidate, habitID: F.lateDinner.habitID, title: "Kitchen closed at 20:30",
                    predicate: .food(label: "a kitchen closed at 20:30"), outcomeMetric: .deepSleepMinutes, startDay: "2026-10-11",
                    timeZoneID: F.zoneID, reminder: PatternReminder(enabled: true, minuteOfDay: 20 * 60 + 15), createdAt: F.now)
    }

    @Test func theCardShowsTheStrongestPatternWithItsCounts() throws {
        let card = try #require(TodayAgentSlotBuilder.patternCard(snapshot(found: [F.alcohol, F.lateDinner]), enabled: true))
        #expect(card.id == F.alcohol.candidateID)
        #expect(card.strengthLabel == "Strong")
        #expect(card.title == PatternsCopy.headline(F.alcohol))
        #expect(card.detail == PatternCopy.counts(for: F.alcohol))
        #expect(card.detail != card.title, "the body gives the counts, not the title again")
        #expect(card.nightsLine == "From your last 23 nights")
        #expect(card.canStartTest)
    }

    @Test func theCardIsHiddenWhenPatternsIsOffOrThereIsNothing() {
        #expect(TodayAgentSlotBuilder.patternCard(snapshot(found: [F.alcohol]), enabled: false) == nil)
        #expect(TodayAgentSlotBuilder.patternCard(nil, enabled: true) == nil)
        #expect(TodayAgentSlotBuilder.patternCard(snapshot(found: []), enabled: true) == nil)
    }

    @Test func aPatternAlreadyUnderTestDoesNotLeadTheCard() throws {
        let running = runningTest(candidate: F.alcohol.candidateID)
        let card = try #require(TodayAgentSlotBuilder.patternCard(snapshot(found: [F.alcohol, F.lateDinner], running: [running]), enabled: true))
        #expect(card.id == F.lateDinner.candidateID)
        #expect(!card.canStartTest, "one test runs at a time")
        #expect(TodayAgentSlotBuilder.patternCard(snapshot(found: [F.alcohol], running: [running]), enabled: true) == nil)
    }

    @Test func aRunningTestsReminderBecomesATimelineMoment() {
        let facts = TodayAgentSlotBuilder.reminders(snapshot(found: [], running: [runningTest(candidate: "x")]), enabled: true, locale: Locale(identifier: "en_GB"))
        #expect(facts.count == 1)
        #expect(facts[0].minuteOfDay == 20 * 60 + 15)
        #expect(facts[0].title == "Pattern check-in")
        #expect(facts[0].detail == "Kitchen closed at 20:30")
        #expect(TodayAgentSlotBuilder.reminders(snapshot(found: [], running: [runningTest(candidate: "x")]), enabled: false).isEmpty)
    }

    @Test func patternsAreOffUntilTheHabitInsightsStageOpens() {
        #expect(!LooprPatternsRuntime.isEnabled(stage: .disabled))
        #expect(LooprPatternsRuntime.isEnabled(stage: .internalOnly))
    }

    // MARK: Taps

    @Test func tapsGoToTheTabThatOwnsTheData() {
        #expect(TodayAgentDestination.destination(for: .yourDayRow("food")) == .tab(.food))
        #expect(TodayAgentDestination.destination(for: .yourDayRow("train")) == .tab(.fitness))
        #expect(TodayAgentDestination.destination(for: .yourDayRow("journal")) == .tab(.protocol))
        #expect(TodayAgentDestination.destination(for: .yourDayRow("other")) == nil)
        #expect(TodayAgentDestination.destination(for: .timelineItem("meal-abc")) == .tab(.food))
        #expect(TodayAgentDestination.destination(for: .timelineItem("workout-planned")) == .tab(.fitness))
        #expect(TodayAgentDestination.destination(for: .timelineItem("reminder-abc")) == .patterns)
        #expect(TodayAgentDestination.destination(for: .patterns) == .patterns)
        #expect(TodayAgentDestination.destination(for: .startPatternTest("x")) == .patterns)
    }

    // MARK: Pinned numbers

    @Test func pinsAreCustomisedOnlyWhenTheyDifferFromTheDefaults() {
        let suite = UserDefaults(suiteName: "TodayAgentSlotsTests.\(UUID().uuidString)")!
        let pins = HealthMetricPins(storage: suite)
        #expect(!pins.isCustomised, "a fresh install pins the defaults and Today shows no pinned card")
        pins.toggle(.recovery)
        #expect(pins.isCustomised)
        for key in pins.metrics { pins.toggle(key) }
        #expect(pins.metrics.isEmpty)
        #expect(!pins.isCustomised, "no pins means no card")
    }

    @Test func theFullListRowShowsOnlyWhenPinsAreHiddenAndCountsThemAll() {
        // Today's card shows four rows. Seven pinned leaves three out, so the card ends with a row to Health.
        #expect(HealthPinnedSection.showAllTitle(total: 7, limit: 4) == "All 7 pinned numbers")
        #expect(HealthPinnedSection.showAllTitle(total: 5, limit: 4) == "All 5 pinned numbers")
        #expect(HealthPinnedSection.showAllTitle(total: 4, limit: 4) == nil, "four fit, so there is nothing more to open")
        #expect(HealthPinnedSection.showAllTitle(total: 2, limit: 4) == nil)
        #expect(HealthPinnedSection.showAllTitle(total: 7, limit: nil) == nil, "Health shows every pin and needs no link to itself")
    }

    @Test func theRowCountIsThePinnedCountOfARealPinSet() {
        let suite = UserDefaults(suiteName: "TodayAgentSlotsTests.\(UUID().uuidString)")!
        let pins = HealthMetricPins(storage: suite)
        pins.move(.rmssd, by: 1)
        #expect(pins.isCustomised, "a reorder of the seven defaults is a choice, so Today shows the card")
        #expect(HealthPinnedSection.showAllTitle(total: pins.metrics.count, limit: 4) == "All 7 pinned numbers")
        for key in pins.metrics.suffix(4) { pins.toggle(key) }
        #expect(pins.metrics.count == 3)
        #expect(HealthPinnedSection.showAllTitle(total: pins.metrics.count, limit: 4) == nil)
    }

    // MARK: Sleep comparison inputs

    @Test func dayKeysCountBackOverMonthsAndLeapDays() {
        #expect(SleepComparisonLoader.key(DayIdentity(year: 2026, month: 10, day: 13), minusDays: 1) == "2026-10-12")
        #expect(SleepComparisonLoader.key(DayIdentity(year: 2026, month: 10, day: 13), minusDays: 28) == "2026-09-15")
        #expect(SleepComparisonLoader.key(DayIdentity(year: 2024, month: 3, day: 1), minusDays: 1) == "2024-02-29")
        #expect(SleepComparisonLoader.key(DayIdentity(year: 2026, month: 1, day: 2), minusDays: 3) == "2025-12-30")
    }

    @Test func theAlcoholQuestionIsFoundByPresetOrByName() {
        func definition(_ source: HabitDefinitionSource, _ name: String) -> HabitDefinition {
            HabitDefinition(id: HabitID(rawValue: UUID()), source: source, name: name, question: name + "?", sortOrder: 0, createdAt: F.now)
        }
        #expect(SleepComparisonLoader.isAlcohol(definition(.preset(catalogID: "alcohol"), "Drinks")))
        #expect(SleepComparisonLoader.isAlcohol(definition(.custom, "alcohol")))
        #expect(!SleepComparisonLoader.isAlcohol(definition(.preset(catalogID: "late_caffeine"), "Late caffeine")))
    }

    // MARK: Clock times follow the locale

    private let twentyFour = Locale(identifier: "en_GB")
    private let twelve = Locale(identifier: "en_AU")
    private func plain(_ text: String) -> String { text.replacingOccurrences(of: "\u{202F}", with: " ") }

    @Test func theUpperARowWritesItsTimeInTheLocalesClock() throws {
        let day = try #require(TodayAgentSlotBuilder.trainRow(overview().today, finished: [], locale: twentyFour))
        #expect(day.title == "Upper A at 18:30")
        let evening = try #require(TodayAgentSlotBuilder.trainRow(overview().today, finished: [], locale: twelve))
        #expect(plain(evening.title) == "Upper A at 6:30 pm")
    }

    @Test func theTodayCardTitleAndCountsWriteTheirTimesInTheLocalesClock() throws {
        let late = F.lateDinner
        let card24 = try #require(TodayAgentSlotBuilder.patternCard(snapshot(found: [late]), enabled: true, locale: twentyFour))
        #expect(card24.title.hasSuffix("when you eat after 21:00"))
        #expect(card24.detail.contains("when you ate after 21:00"), "past tense, matching averaged")
        let card12 = try #require(TodayAgentSlotBuilder.patternCard(snapshot(found: [late]), enabled: true, locale: twelve))
        #expect(plain(card12.title).hasSuffix("when you eat after 9:00 pm"))
        #expect(plain(card12.detail).contains("when you ate after 9:00 pm"))
        #expect(!card12.detail.contains("21:00"))
    }

    @Test func aTestTitleAndItsReminderRowFollowTheLocaleWithoutChangingTheStoredTitle() throws {
        let test = runningTest(candidate: "x")
        #expect(test.title == "Kitchen closed at 20:30", "stored text is untouched")
        #expect(PatternsCopy.title(test, locale: twentyFour) == "Kitchen closed at 20:30")
        #expect(plain(PatternsCopy.title(test, locale: twelve)) == "Kitchen closed at 8:30 pm")
        let row = TodayAgentSlotBuilder.reminders(snapshot(found: [], running: [test]), enabled: true, locale: twelve)
        #expect(plain(row[0].detail ?? "") == "Kitchen closed at 8:30 pm")
    }
}
