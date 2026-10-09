import Foundation
import Testing
import DomainKit
import DesignSystem
@testable import TodayKit

struct TodayRecoveryExplanationTests {
    @Test func aSplitThatReproducesTheScoreShowsExactPoints() {
        let context = TodayTestDays.context(recovery: TodayTestDays.breakdown(score: 74.4))
        let explanation = TodayRecoveryExplanation(summary: TodayTestDays.summary(), context: context, calendar: TodayTestDays.calendar)
        #expect(explanation.mode == .exact)
        #expect(explanation.rows.map(\.title) == ["HRV", "Resting heart rate", "Breathing rate"])
        #expect(explanation.rows.map(\.pointsLabel) == ["+14 pts", "+8 pts", "+2 pts"])
        #expect(explanation.rows[0].share == 1)
        #expect(explanation.rows[0].delta?.text == "+7 ms vs usual")
        #expect(explanation.note.hasPrefix("A night that matches your usual on all three scores 50."))
    }

    @Test func aSplitThatDoesNotReproduceTheScoreShowsDirectionOnly() {
        let context = TodayTestDays.context(recovery: TodayTestDays.breakdown(score: 61))
        let explanation = TodayRecoveryExplanation(summary: TodayTestDays.summary(), context: context, calendar: TodayTestDays.calendar)
        #expect(explanation.mode == .directionOnly)
        #expect(explanation.rows.allSatisfy { $0.pointsLabel == nil })
        #expect(explanation.rows.contains { $0.share != nil })
        #expect(explanation.note.contains("Exact points aren't shown"))
    }

    @Test func learningShowsProgressInsteadOfBars() {
        let summary = TodayTestDays.summary(recovery: nil, recoveryConfidence: "2 more nights and this is ready", recoveryState: .settling)
        let split = TodayRecoveryBreakdown(
            score: nil, isSaturated: false, isMeaningful: false,
            inputs: [
                .init(signal: .hrv, status: .learning(have: 1, need: 3), value: 42, usual: 44, baselineNights: 1, weight: 0.4, contribution: nil, points: nil),
                .init(signal: .restingHeartRate, status: .learning(have: 1, need: 3), value: 58, usual: 57, baselineNights: 1, weight: 0.3, contribution: nil, points: nil),
                .init(signal: .respiratoryRate, status: .noReading, value: nil, usual: nil, baselineNights: 0, weight: 0.2, contribution: nil, points: nil)
            ],
            nightsNeeded: 3
        )
        let context = TodayTestDays.context(history: TodayTestDays.standardHistory(respiratoryToday: nil, recoveryToday: nil), recovery: split)
        let explanation = TodayRecoveryExplanation(summary: summary, context: context, calendar: TodayTestDays.calendar)
        #expect(explanation.mode == .learning)
        #expect(explanation.rows[0].delta?.text == "Learning your usual · 2 of 4 nights")
        #expect(explanation.rows[2].value == nil)
        #expect(explanation.rows.allSatisfy { $0.share == nil })
    }

    @Test func flatBaselineExplainsWhyTheBarIsMissing() {
        let split = TodayRecoveryBreakdown(score: 74, isSaturated: false, isMeaningful: true,
            inputs: [.init(signal: .restingHeartRate, status: .flatBaseline, value: 61, usual: 55,
                baselineNights: 28, weight: 0.3, contribution: nil, points: nil)], nightsNeeded: 3)
        let explanation = TodayRecoveryExplanation(summary: TodayTestDays.summary(),
            context: TodayTestDays.context(recovery: split), calendar: TodayTestDays.calendar)
        let rhr = explanation.rows.first { $0.signal == .restingHeartRate }
        #expect(rhr?.share == nil)
        #expect(rhr?.status == "Not scored. Your resting heart rate has barely changed over your usual nights.")
    }

    @Test func sleepIsNamedAsOutsideTheScore() {
        let explanation = TodayRecoveryExplanation(summary: TodayTestDays.summary(), context: TodayTestDays.context(),
                                                   calendar: TodayTestDays.calendar)
        #expect(explanation.sleepNote == "Sleep isn't part of this score. Last night: 7 h 42 m against a 7 h 30 m need.")
    }

    @Test func theTrendHasThirtyDaysEndingOnTheDayWithGapsAsNil() {
        var history = TodayTestDays.standardHistory()
        history[.recovery] = TodayTestDays.series(usual: 62, spread: 10, days: 10, today: 74, skipping: [2])
        let explanation = TodayRecoveryExplanation(summary: TodayTestDays.summary(), context: TodayTestDays.context(history: history),
                                                   calendar: TodayTestDays.calendar)
        #expect(explanation.trend.count == 30)
        #expect(explanation.trend.last?.date == TodayTestDays.dayStart)
        #expect(explanation.trend.last?.value == 74)
        #expect(explanation.trend[27].value == nil)
        #expect(explanation.trend.first?.value == nil)
    }

    @Test func pointLabelsUseATrueMinusAndSingular() {
        #expect(TodayRecoveryExplanation.pointsText(-6.4) == "\u{2212}6 pts")
        #expect(TodayRecoveryExplanation.pointsText(1.2) == "+1 pt")
        #expect(TodayRecoveryExplanation.pointsText(0.3) == "0 pts")
    }

    @Test func theStrainBreakdownScalesZonesToTheLongest() {
        let context = TodayDayContext(day: TodayTestDays.day, dayStart: TodayTestDays.dayStart, history: TodayTestDays.standardHistory(),
                                      zoneMinutes: [TodayZoneMinutes(id: 1, name: "Recovery", minutes: 80),
                                                    TodayZoneMinutes(id: 2, name: "Aerobic", minutes: 40)])
        let explanation = TodayStrainExplanation(summary: TodayTestDays.summary(), context: context, calendar: TodayTestDays.calendar)
        #expect(explanation.text == "8.6")
        #expect(explanation.zones.map(\.share) == [1, 0.5])
        #expect(explanation.totalZoneMinutes == 120)
        #expect(explanation.rangeText == nil)
    }
}

struct TodayPreferencesTests {
    @Test func defaultsAreHRVRestingHRStepsAndActiveEnergy() {
        #expect(TodayPreferences().pinned == [.hrv, .restingHeartRate, .steps, .activeEnergy])
    }

    @Test func pinnedIsDedupedAndCappedAtSix() {
        var preferences = TodayPreferences()
        preferences.setPinned([.hrv, .hrv, .steps, .sleep, .strain, .stress, .recovery, .remSleep, .deepSleep])
        #expect(preferences.pinned == [.hrv, .steps, .sleep, .strain, .stress, .recovery])
    }

    @Test func preferencesSurviveARoundTripThroughDefaults() {
        let suite = "today-preferences-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = TodayPreferencesStore(suiteName: suite)
        #expect(store.load() == TodayPreferences())
        var preferences = TodayPreferences(pinned: [.stress, .hrv])
        preferences.dismissHeadsUp(for: TodayTestDays.day)
        store.save(preferences)
        let loaded = store.load()
        #expect(loaded.pinned == [.stress, .hrv])
        #expect(loaded.isHeadsUpDismissed(on: TodayTestDays.day))
        #expect(!loaded.isHeadsUpDismissed(on: DayIdentity(year: 2026, month: 9, day: 24)))
    }

    @Test func anUnknownMetricFromALaterVersionIsDroppedNotFatal() throws {
        let json = #"{"pinned":["hrv","vo2_future","steps"]}"#
        let decoded = try JSONDecoder().decode(TodayPreferences.self, from: Data(json.utf8))
        #expect(decoded.pinned == [.hrv, .steps])
        #expect(decoded.headsUpDismissedDay == nil)
    }

    @Test func anEmptyChoiceStaysEmpty() {
        #expect(TodayPreferences(pinned: []).pinned.isEmpty)
    }
}

struct TodayViewModelContextTests {
    @Test @MainActor
    func contextIsReadOncePerDayAndAgainOnlyWhenTheSummaryChanges() async {
        let repository = InMemoryTodayRepository(values: [TodayTestDays.day: TodayTestDays.summary()])
        let context = CountingContextRepository(context: TodayTestDays.context())
        let viewModel = TodayViewModel(repository: repository, contextRepository: context)

        await viewModel.load(day: TodayTestDays.day)
        await viewModel.load(day: TodayTestDays.day)
        #expect(await context.reads == 1)
        #expect(viewModel.context?.day == TodayTestDays.day)

        await repository.replace(TodayTestDays.summary(strain: 12.1), for: TodayTestDays.day)
        await viewModel.load(day: TodayTestDays.day)
        #expect(await context.reads == 2)
    }

    @Test @MainActor
    func anotherDayDropsTheOldContextBeforeLoading() async {
        let other = DayIdentity(year: 2026, month: 9, day: 22)
        let repository = InMemoryTodayRepository(values: [TodayTestDays.day: TodayTestDays.summary()])
        let viewModel = TodayViewModel(repository: repository, contextRepository: CountingContextRepository(context: TodayTestDays.context()))
        await viewModel.load(day: TodayTestDays.day)
        await viewModel.load(day: other)
        #expect(viewModel.summary == nil)
        #expect(viewModel.context == nil)
    }

    @Test @MainActor
    func theDashboardIsBuiltOnceUntilSomethingChanges() async {
        let repository = InMemoryTodayRepository(values: [TodayTestDays.day: TodayTestDays.summary()])
        let suite = "today-vm-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let viewModel = TodayViewModel(repository: repository, preferencesStore: TodayPreferencesStore(suiteName: suite))
        await viewModel.load(day: TodayTestDays.day)
        let first = viewModel.dashboard(isToday: true)
        #expect(first?.tiles.map(\.metric) == TodayPreferences.defaultPinned)
        viewModel.setPinned([.stress])
        #expect(viewModel.dashboard(isToday: true)?.tiles.map(\.metric) == [.stress])
        #expect(TodayPreferencesStore(suiteName: suite).load().pinned == [.stress])
        viewModel.dismissHeadsUp(for: TodayTestDays.day)
        #expect(TodayPreferencesStore(suiteName: suite).load().isHeadsUpDismissed(on: TodayTestDays.day))
    }
}

private actor CountingContextRepository: TodayContextRepository {
    private let value: TodayDayContext
    private(set) var reads = 0

    init(context: TodayDayContext) { value = context }

    func context(for day: DayIdentity, summary: TodaySummary?) async throws -> TodayDayContext? {
        reads += 1
        return day == value.day ? value : nil
    }
}
