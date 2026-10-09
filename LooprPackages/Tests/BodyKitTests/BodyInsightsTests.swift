import Foundation
import Testing
import DomainKit
import DesignSystem
import AnalyticsKit
@testable import BodyKit

private let anchor = DayIdentity(year: 2026, month: 9, day: 23)

/// History with the given strain values, oldest first, ending on `end`.
private func history(strain: [Double?], endingOn end: DayIdentity = anchor, recovery: [DayIdentity: Double] = [:],
                     anchor historyAnchor: DayIdentity = anchor) -> BodyHistory {
    let days = BodyHistory.window(endingOn: end, length: strain.count)
    var entries: [DayIdentity: BodyHistoryDay] = [:]
    for (day, value) in zip(days, strain) where value != nil {
        entries[day] = BodyHistoryDay(day: day, strain: value)
    }
    for (day, value) in recovery {
        var entry = entries[day] ?? BodyHistoryDay(day: day)
        entry.recovery = value
        entries[day] = entry
    }
    return BodyHistory(anchor: historyAnchor, days: Array(entries.values))
}

@Suite struct BodyDayArithmeticTests {
    @Test func stepsAcrossMonthsYearsAndLeapDays() {
        #expect(DayIdentity(year: 2026, month: 9, day: 30).bodyAdding(days: 1) == DayIdentity(year: 2026, month: 10, day: 1))
        #expect(DayIdentity(year: 2026, month: 1, day: 1).bodyAdding(days: -1) == DayIdentity(year: 2025, month: 12, day: 31))
        #expect(DayIdentity(year: 2024, month: 2, day: 28).bodyAdding(days: 1) == DayIdentity(year: 2024, month: 2, day: 29))
        #expect(DayIdentity(year: 2023, month: 2, day: 28).bodyAdding(days: 1) == DayIdentity(year: 2023, month: 3, day: 1))
        #expect(DayIdentity(year: 2026, month: 9, day: 23).bodyDays(to: DayIdentity(year: 2026, month: 11, day: 1)) == 39)
        for offset in -800...800 {
            #expect(anchor.bodyAdding(days: offset).bodyAdding(days: -offset) == anchor)
        }
    }

    @Test func windowIsOldestFirstAndEndsOnTheDay() {
        let window = BodyHistory.window(endingOn: anchor, length: 7)
        #expect(window.count == 7)
        #expect(window.last == anchor)
        #expect(window.first == DayIdentity(year: 2026, month: 9, day: 17))
        #expect(BodyHistory.window(endingOn: anchor, length: 0).isEmpty)
    }
}

@Suite struct BodyStrainTargetAgreementTests {
    /// DomainKit cannot import DesignSystem, so this keeps the strain range's
    /// bands and the recovery ring's colour bands in step.
    @Test func strainRangeBandsMatchTheRecoveryRingBands() {
        for tenth in 0...1000 {
            let score = Double(tenth) / 10
            let ring = LooprRecoveryBand(score: score)
            let target = StrainTarget(recovery: score)
            let expected: StrainTarget.RecoveryBand? = switch ring {
            case .high: .high
            case .middle: .middle
            case .low: .low
            case nil: nil
            }
            #expect(target?.band == expected, "recovery \(score)")
        }
    }
}

@Suite struct BodyStrainHeroTests {
    private func strain(_ value: String?, caption: String? = nil, state: MetricState = .partial) -> BodyMetricValue {
        BodyMetricValue(id: .strain, title: "Strain", value: value, unit: "/21", state: state, confidence: caption, source: "test")
    }

    @Test func measuredStrainGetsTheRangeFromRecovery() {
        let hero = BodyStrainHero.make(metric: strain("8.6"), recovery: 74)
        #expect(hero.strain == 8.6)
        #expect(hero.target?.text == "14 to 18")
        #expect(hero.position == .below)
        #expect(hero.verdict == "Below suggested range")
        #expect(hero.rangeLegend == "Suggested 14 to 18 · recovery 74")
        #expect(hero.sentence(isToday: true) == "There is room for more today.")
        #expect(hero.sentence(isToday: false) == nil)
        #expect(hero.accessibilityLabel(isToday: true)
                == "Strain 8.6 of 21. Below suggested range. Suggested 14 to 18, from recovery 74. There is room for more today.")
        #expect(hero.accessibilityLabel(isToday: false) == "Strain 8.6 of 21. Below suggested range. Suggested 14 to 18, from recovery 74.")
    }

    @Test func verdictFollowsThePosition() {
        #expect(BodyStrainHero.make(metric: strain("12.0"), recovery: 50).verdict == "In suggested range")
        #expect(BodyStrainHero.make(metric: strain("12.0"), recovery: 50).sentence(isToday: true) == nil)
        #expect(BodyStrainHero.make(metric: strain("11.3"), recovery: 20).verdict == "Above suggested range")
        #expect(BodyStrainHero.make(metric: strain("11.3"), recovery: 20).sentence(isToday: true) == "An easy evening helps tomorrow.")
        #expect(BodyStrainHero.make(metric: strain("11.3"), recovery: 20).rangeLegend == "Suggested 4 to 10 · recovery 20")
    }

    @Test func noRecoveryMeansNoRangeAndSaysSo() {
        let hero = BodyStrainHero.make(metric: strain("9.1"), recovery: nil)
        #expect(hero.target == nil)
        #expect(hero.verdict == nil)
        #expect(hero.rangeLegend == nil)
        #expect(hero.sentence(isToday: true) == "There is no recovery score for today yet, so there is no suggested range.")
        #expect(hero.sentence(isToday: false) == "There was no recovery score that day, so there is no suggested range.")
    }

    @Test func productionAgeCaptionBecomesTheProfilePrompt() {
        let hero = BodyStrainHero.make(metric: strain(nil, caption: "Add your age to your profile to see strain", state: .absent), recovery: 60)
        #expect(hero.state == .needsAge)
        #expect(hero.strain == nil)
        #expect(hero.sentence(isToday: true) == nil)
    }

    @Test func otherMissingStrainKeepsTheDerivationsReason() {
        let hero = BodyStrainHero.make(metric: strain(nil, caption: "Wear your band during the day", state: .absent), recovery: 60)
        #expect(hero.state == .missing(reason: "Wear your band during the day"))
        #expect(BodyStrainHero.make(metric: nil, recovery: nil).state == .missing(reason: nil))
        #expect(BodyStrainHero.make(metric: strain("not a number"), recovery: nil).state == .missing(reason: nil))
    }

    @Test func usualDeltaOnlyForFinishedDays() {
        let values: [Double?] = Array(repeating: 10, count: 30) + [14]
        let past = history(strain: values)
        let hero = BodyStrainHero.make(metric: strain("14.0"), recovery: 70)
        #expect(hero.usualDelta(history: past, anchorIsToday: true) == nil)
        let delta = hero.usualDelta(history: past, anchorIsToday: false)
        #expect(delta?.text == "+4.0 vs usual")
        #expect(delta?.tone == .neutral)
        #expect(hero.usualDelta(history: nil, anchorIsToday: false) == nil)
    }
}

@Suite struct BodyProfilePromptTests {
    @Test func needsAgeDayGetsOneShortPrompt() throws {
        let prompt = try #require(BodyProfileGaps.prompt(for: BodyFixtures.needsAge))
        #expect(prompt.title == "Strain needs a maximum heart rate")
        #expect(prompt.actionTitle == "Add your age in Profile")
        #expect(prompt.missing == [.age, .height, .weight])
        #expect(prompt.message == "Your age sets an estimated maximum heart rate for zones, strain and training load. You can also set a maximum in Heart zone settings.")
    }

    @Test func populatedDayHasNoPrompt() {
        #expect(BodyProfileGaps.prompt(for: BodyFixtures.populated) == nil)
        #expect(BodyProfileGaps.captionAsksForAge("Add your age to your profile to see strain"))
        #expect(BodyProfileGaps.captionAsksForAge("Add your age or set a maximum heart rate to see strain"))
        #expect(!BodyProfileGaps.captionAsksForAge("A few more days of wear and this is ready"))
        #expect(!BodyProfileGaps.captionAsksForAge(nil))
    }
}

@Suite struct BodyStrainWeekTests {
    private let recovery: [DayIdentity: Double] = [
        anchor.bodyAdding(days: 1): 81, anchor: 55, anchor.bodyAdding(days: -1): 40
    ]

    @Test func pastDayWeekEndsOnTheDayWithItsNextMorning() {
        let values: [Double?] = [8, 9, nil, 11, 12, 13, 14]
        let week = BodyStrainWeek.days(history: history(strain: values, recovery: recovery), anchorIsToday: false)
        #expect(week.count == 14)
        #expect(Array(week.suffix(7)).map(\.first) == values)
        #expect(week.last?.second == 81)
        #expect(week[12].second == 55)
        #expect(week[11].second == 40)
        #expect(week.first?.second == nil)
    }

    @Test func todaysWeekEndsYesterdayBecauseTodayIsStillBuilding() {
        let values: [Double?] = [8, 9, 10, 11, 12, 13, 14]
        let week = BodyStrainWeek.days(history: history(strain: values, recovery: recovery), anchorIsToday: true)
        #expect(Array(week.suffix(7)).map(\.first) == [nil, 8, 9, 10, 11, 12, 13])
        #expect(week.last?.second == 55)
    }

    @Test func weekNeedsTwoDaysWithStrain() {
        let one = BodyStrainWeek.days(history: history(strain: [nil, nil, nil, nil, nil, nil, 9]), anchorIsToday: false)
        let two = BodyStrainWeek.days(history: history(strain: [nil, nil, nil, nil, nil, 8, 9]), anchorIsToday: false)
        #expect(!BodyStrainWeek.isWorthShowing(one))
        #expect(BodyStrainWeek.isWorthShowing(two))
        #expect(!BodyStrainWeek.isWorthShowing(BodyStrainWeek.days(history: .empty(anchor: anchor), anchorIsToday: false)))
    }
}

@Suite struct BodyTrainingLoadTests {
    @Test func sharedModelAndEstablishedBand() throws {
        let values: [Double?] = Array(repeating: 10, count: 90)
        guard case .ready(let load) = BodyTrainingLoad.compute(history: history(strain: values), endingOn: anchor) else {
            Issue.record("Expected load"); return
        }
        #expect(load.model == TrainingLoad.compute(dailyStrain: values))
        #expect(load.model.days == 90)
        #expect(load.acute == 10 && load.chronic == 10 && load.form == 0)
        #expect(load.usualRange == 9...11)
        #expect(load.summary == "Your load this week is close to what you're used to.")
    }
    @Test func heavyWeekUsesDescriptiveCopy() {
        let values: [Double?] = Array(repeating: 8, count: 70) + Array(repeating: 18, count: 7)
        if case .ready(let load) = BodyTrainingLoad.compute(history: history(strain: values), endingOn: anchor) {
            #expect(load.form < 0)
            #expect(load.summary == "Your load this week is above what you're used to.")
        } else { Issue.record("Expected load") }
    }
    @Test func missingDaysRestartCountAndNeverBecomeRest() {
        let values: [Double?] = Array(repeating: 10, count: 40) + [nil] + Array(repeating: 10, count: 9)
        let state = BodyTrainingLoad.compute(history: history(strain: values), endingOn: anchor)
        #expect(state == .learning(daysWithStrain: 9, needed: 42))
        #expect(state.title == "Building your history · 9 of 42 days")
        #expect(state.detail.contains("missing day restarts"))
    }
    @Test func earlyModelWithholdsUsualBand() {
        let short = BodyTrainingLoad.trend(history: history(strain: Array(repeating: 10, count: 20)), endingOn: anchor)
        #expect(short.count == 28)
        #expect(short.first?.acute == nil)
        #expect(short.last?.acute == 10)
        #expect(short.allSatisfy { $0.usualLow == nil && $0.usualHigh == nil })
        let full = BodyTrainingLoad.trend(history: history(strain: Array(repeating: 10, count: 90)), endingOn: anchor)
        #expect(full.allSatisfy { $0.acute == 10 && $0.usualLow == 9 && $0.usualHigh == 11 })
    }
}

@Suite struct BodyZoneBarTests {
    private let zones = [
        BodyZoneMinutes(id: 1, name: "Recovery", minutes: 42),
        BodyZoneMinutes(id: 2, name: "Aerobic", minutes: 18),
        BodyZoneMinutes(id: 3, name: "Tempo", minutes: 6),
        BodyZoneMinutes(id: 4, name: "Threshold", minutes: 1),
        BodyZoneMinutes(id: 5, name: "Peak", minutes: 0)
    ]

    @Test func sharesAreProportionalAndSumToOne() throws {
        let bar = try #require(BodyZoneBar.make(zones))
        #expect(bar.totalMinutes == 67)
        #expect(abs(bar.segments.reduce(0) { $0 + $1.share } - 1) < 1e-12)
        #expect(bar.segments.map(\.id) == [1, 2, 3, 4, 5])
        #expect(bar.segments[4].share == 0)
        #expect(bar.busiest?.id == 1)
    }

    @Test func widthsFillTheBarKeepSmallZonesVisibleAndSkipEmptyOnes() throws {
        let bar = try #require(BodyZoneBar.make(zones))
        let widths = bar.widths(total: 300, minimum: 6)
        #expect(abs(widths.reduce(0, +) - 300) < 1e-9)
        #expect(widths[3] == 6)      // 1 minute of 67 would be 4.5 pt
        #expect(widths[4] == 0)      // no minutes, no segment
        #expect(widths[0] > widths[1] && widths[1] > widths[2])
        // Proportions hold among the unpinned zones.
        #expect(abs(widths[0] / widths[1] - 42.0 / 18.0) < 1e-9)
    }

    @Test func noMinutesMeansNoBar() {
        #expect(BodyZoneBar.make([]) == nil)
        #expect(BodyZoneBar.make([BodyZoneMinutes(id: 1, name: "Recovery", minutes: 0)]) == nil)
        #expect(BodyZoneBar.make([BodyZoneMinutes(id: 1, name: "Recovery", minutes: .nan)]) == nil)
    }

    @Test func labels() {
        #expect(BodyZoneBar.minutesText(42) == "42 min")
        #expect(BodyZoneBar.minutesText(68) == "1 h 8 m")
        #expect(BodyZoneBar.minutesText(0) == "0 min")
        #expect(BodyZoneBar.percentText(0.004) == "<1%")
        #expect(BodyZoneBar.percentText(0) == "0%")
        #expect(BodyZoneBar.percentText(0.627) == "63%")
    }
}

@Suite struct BodyActivityRowTests {
    @Test func rowsAreLabelledEstimatesAndTodayIsNotCompared() {
        let rows = BodyActivityRow.rows(snapshot: BodyFixtures.populated,
                                        history: BodyFixtureHistoryProvider.history(anchor: BodyFixtures.day), anchorIsToday: true)
        #expect(rows.map(\.title) == ["Estimated steps", "Active energy"])
        #expect(rows[0].value == "8,240")
        #expect(rows[0].unit == nil)
        #expect(rows[0].caption == "Estimated from wrist motion and your walking pace")
        #expect(rows[1].value == "612")
        #expect(rows[1].unit == "kcal")
        #expect(rows[1].caption == "Estimated with a default maximum heart rate")
        #expect(rows.allSatisfy { $0.delta == nil })
        #expect(rows.map(\.metricLinkID) == [LooprMetricLinkID.steps, LooprMetricLinkID.activeEnergy])
    }

    @Test func finishedDayIsComparedWithItsUsual() {
        let day = BodyFixtures.day
        var days = BodyHistory.window(endingOn: day.bodyAdding(days: -1), length: 30).map { BodyHistoryDay(day: $0, steps: 6_000) }
        days.append(BodyHistoryDay(day: day, steps: 8_240))
        let rows = BodyActivityRow.rows(snapshot: BodyFixtures.populated, history: BodyHistory(anchor: day, days: days), anchorIsToday: false)
        #expect(rows[0].delta?.text == "+2,240 vs usual")
        #expect(rows[0].delta?.tone == .neutral)
        #expect(rows[1].delta == nil) // no energy history
    }

    @Test func missingValuesKeepTheirReason() {
        let rows = BodyActivityRow.rows(snapshot: BodyFixtures.needsAge, history: nil, anchorIsToday: false)
        #expect(rows.map(\.value) == [nil, nil])
        #expect(rows[0].caption == "A few more days of wear and this is ready")
        #expect(rows[1].caption == "Add your age, height and weight to your profile to see this")
        #expect(rows[0].accessibilityLabel == "Estimated steps, No reading, A few more days of wear and this is ready")
    }
}

@Suite struct BodyAgeLockTests {
    @Test func cardioAgeIsLockedWithWhatIsMissing() {
        let snapshot = BodyFixtures.populated
        let lock = BodyAgeLock.cardio(snapshot: snapshot, presentation: snapshot.cardioAgePresentation)
        #expect(!lock.isAvailable)
        #expect(lock.status == "Locked")
        #expect(lock.requirements.map(\.id) == ["age", "vo2max"])
        #expect(lock.requirements.map(\.isMet) == [true, false])
        #expect(lock.summary == "Needs VO₂ max readings")
    }

    @Test func profileGapsJoinTheList() {
        let snapshot = BodyFixtures.needsAge
        let lock = BodyAgeLock.cardio(snapshot: snapshot, presentation: snapshot.cardioAgePresentation)
        #expect(lock.requirements.map(\.id) == ["age", "sex", "vo2max"])
        #expect(lock.requirements.allSatisfy { !$0.isMet })
        #expect(lock.summary == "Needs your age, your sex and VO₂ max readings")
    }

    @Test func availableCardioAgeShowsItsValue() {
        let lock = BodyAgeLock.cardio(snapshot: BodyFixtures.populated,
                                      presentation: .available(label: "34 years", confidence: "80% confidence", source: "Apple Health"))
        #expect(lock.isAvailable)
        #expect(lock.status == "34 years")
        #expect(lock.requirements.isEmpty)
    }

    @Test @MainActor func looprAgeStaysLockedWithoutACompositeNumber() {
        let lock = BodyAgeLock.loopr(presentation: BodyFixtures.populated.looprAgePresentation)
        #expect(!lock.isAvailable)
        #expect(lock.status == "Locked")
        #expect(lock.summary == "Not available yet. The model is still being validated.")
        #expect(lock.summary.allSatisfy { !$0.isNumber })

        let storedValue: BodyAgePresentation = .available(label: "31 years", confidence: "High", source: "Stored result")
        let storedLock = BodyAgeLock.loopr(presentation: storedValue)
        #expect(!storedLock.isAvailable)
        #expect(!storedLock.summary.contains("31"))

        let screen = BodyAgeScreen(title: "Loopr Age", presentation: storedValue)
        #expect(!screen.presentation.isAvailable)
        #expect(screen.looprAge == nil)
    }
}

@Suite struct BodyCompositionRowsTests {
    @Test func profileValuesBecomePlainRows() {
        let rows = BodyCompositionRows.make(BodyFixtures.populated.composition)
        #expect(rows.rows.map(\.title) == ["Weight", "Height"])
        #expect(rows.rows.map(\.value) == ["70 kg", "175 cm"])
        #expect(rows.source == "From your profile")
    }

    @Test func healthSourceAndBodyFat() {
        let rows = BodyCompositionRows.make(BodyCompositionContext(weight: "72.4 kg", height: nil, bodyFat: "18.0%",
                                                                   state: .partial, source: "Apple Health"))
        #expect(rows.rows.map(\.value) == ["72.4 kg", "18%"])
        #expect(rows.source == "From Apple Health")
    }

    @Test func nothingMeansNoRowsAndNoSource() {
        let rows = BodyCompositionRows.make(BodyFixtures.needsAge.composition)
        #expect(rows.rows.isEmpty)
        #expect(rows.source == nil)
    }
}

@Suite struct BodyFixtureHistoryTests {
    @Test func fixtureHistoryEndsOnTheFixtureDaysValues() {
        let history = BodyFixtureHistoryProvider.history(anchor: BodyFixtures.day)
        #expect(history.day(BodyFixtures.day)?.strain == LooprFixtureMetrics.today(LooprMetricLinkID.strain))
        #expect(history.day(BodyFixtures.day)?.recovery == LooprFixtureMetrics.today(LooprMetricLinkID.recovery))
        #expect(history.day(BodyFixtures.day.bodyAdding(days: 1)) == nil)
        // The full 14-day chart uses the shared metric story.
        let calendar = Calendar.current
        let week = BodyStrainWeek.days(history: history, anchorIsToday: true)
        let date = BodyFixtures.day.bodyDate(calendar: calendar) ?? Date()
        let strains = LooprFixtureMetrics.history(LooprMetricLinkID.strain, days: 15, endingOn: date, calendar: calendar)
        let recoveries = LooprFixtureMetrics.history(LooprMetricLinkID.recovery, days: 15, endingOn: date, calendar: calendar)
        #expect(week.count == 14)
        #expect(week.map(\.first) == strains.dropLast().map { Optional($0.value) })
        #expect(week.map(\.second) == recoveries.dropFirst().map { Optional($0.value) })
        if case .ready = BodyTrainingLoad.compute(history: history, endingOn: BodyFixtures.day.bodyAdding(days: -1)) {} else {
            Issue.record("the fixture should have a training load")
        }
        #expect(BodyFixtureHistoryProvider.history(anchor: BodyFixtures.day, hasValues: false).isEmpty)
    }
}

private actor CountingHistoryProvider: BodyHistoryProviding {
    private(set) var reads: [DayIdentity] = []
    func bodyHistory(anchor: DayIdentity) async -> BodyHistory {
        reads.append(anchor)
        return BodyFixtureHistoryProvider.history(anchor: anchor)
    }
}

@Suite struct BodyViewModelHistoryTests {
    @Test @MainActor func historyLoadsWithTheDayOnceAndAgainOnlyWhenTheDayChanges() async {
        let other = BodyFixtures.day.bodyAdding(days: -1)
        let repository = InMemoryBodyRepository(values: [BodyFixtures.day: BodyFixtures.populated, other: BodyFixtures.populated])
        let provider = CountingHistoryProvider()
        let viewModel = BodyViewModel(repository: repository, historyProvider: provider)

        await viewModel.load(day: BodyFixtures.day)
        #expect(viewModel.snapshot != nil)
        #expect(viewModel.history?.anchor == BodyFixtures.day)
        await viewModel.load(day: BodyFixtures.day)
        #expect(await provider.reads == [BodyFixtures.day])

        // New numbers for the same day read the history again.
        await repository.replace(BodyFixtures.snapshot(for: .lowConfidence), for: BodyFixtures.day)
        await viewModel.load(day: BodyFixtures.day)
        #expect(await provider.reads == [BodyFixtures.day, BodyFixtures.day])

        await viewModel.load(day: other)
        #expect(viewModel.history?.anchor == other)
        #expect(await provider.reads.last == other)

        viewModel.deleteAllData()
        #expect(viewModel.history == nil)
    }

    @Test @MainActor func withoutAProviderThereIsNoHistory() async {
        let viewModel = BodyViewModel(repository: InMemoryBodyRepository(values: [BodyFixtures.day: BodyFixtures.populated]))
        await viewModel.load(day: BodyFixtures.day)
        #expect(viewModel.snapshot != nil)
        #expect(viewModel.history == nil)
    }
}
