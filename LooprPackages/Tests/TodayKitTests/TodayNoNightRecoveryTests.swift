import Foundation
import Testing
import DomainKit
@testable import TodayKit

/// Midday after days without the band: the summary still carries a daytime
/// resting heart rate far above the nightly usual, but there is no night and
/// no recovery, so the hero must not score or compare against it.
struct TodayNoNightRecoveryTests {
    private static func summary() -> TodaySummary {
        TodayTestDays.summary(recovery: nil, hrv: 31, rhr: 80, sleep: nil,
                              recoveryConfidence: "Wear your strap overnight to start this", recoveryState: .settling)
    }

    private static func context() -> TodayDayContext {
        var history = TodayTestDays.standardHistory(recoveryToday: nil, sleepToday: nil)
        history[.recovery] = []
        return TodayTestDays.context(history: history)
    }

    @Test func todayWithoutANightWaitsForLastNightInsteadOfScoring() {
        let hero = TodayTestDays.dashboard(Self.summary(), Self.context()).hero
        #expect(hero == .calculating(title: "Waiting for last night",
                                     detail: "Recovery appears once your band syncs last night's sleep."))
        #expect(hero.reading == nil)
    }

    @Test func aPastDayWithoutANightReadsNoSleepRecorded() {
        let hero = TodayTestDays.dashboard(Self.summary(), Self.context(), isToday: false).hero
        guard case .unavailable(let title, let detail) = hero else { Issue.record("expected unavailable, got \(hero)"); return }
        #expect(title == "No sleep recorded")
        #expect(!detail.contains("above your usual"))
    }

    @Test func noSentenceComparesDaytimeRestingHeartRateWithTheNightlyUsual() {
        for isToday in [true, false] {
            let hero = TodayTestDays.dashboard(Self.summary(), Self.context(), isToday: isToday).hero
            #expect(hero.reading?.sentence.contains("above your usual") != true)
            #expect(hero.reading == nil)
        }
    }
}
