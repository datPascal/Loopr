import AnalyticsKit
import DesignSystem
import DomainKit
import Foundation
import Testing
@testable import TodayKit

struct MorningBriefingTests {
    @Test func everyScoreAndDriverDirectionAgreesWithThePrintedNumbers() {
        for score in 0...100 {
            for signal in TodayMorningSentence.Signal.allCases {
                for change in [-8.0, -0.01, 0, 0.01, 8] {
                    for term in [-0.8, 0, 0.8] {
                        let sentence = TodayMorningSentence.make(score: Double(score),
                            drivers: [.init(signal: signal, change: change, contribution: term)], sleepMinutes: nil, sleepNeed: nil)
                        let sign = signal == .hrv ? 1.0 : -1.0
                        let precision = signal == .breathing ? 10.0 : 1.0
                        let visible = (change * precision).rounded() != 0
                        let eligible = visible && term != 0 && (term > 0) == (score >= 50) && (change * sign > 0) == (term > 0)
                        if eligible {
                            #expect(sentence.lowercased().contains(change > 0 ? "higher" : "lower"))
                            #expect(sentence.contains(score >= 50 ? "supported" : "lowered"))
                        } else {
                            #expect(sentence == "This score reflects the available overnight heart readings.")
                        }
                    }
                }
            }
        }
    }

    @Test func shortSleepIsContextAndNeverClaimsToChangeTheScore() {
        let drivers: [TodayMorningSentence.Driver] = [.init(signal: .restingHeartRate, change: 4, contribution: -0.5)]
        #expect(TodayMorningSentence.make(score: 32, drivers: drivers, sleepMinutes: 330, sleepNeed: 480)
            == "Sleep was short, and a higher resting heart rate lowered this score.")
        #expect(TodayMorningSentence.make(score: 32, drivers: [], sleepMinutes: 330, sleepNeed: 480)
            == "Sleep fell short of your need; this score reflects your overnight heart readings.")
        for minutes in [nil, .nan, 0, 430, 480] as [Double?] {
            #expect(!TodayMorningSentence.make(score: 32, drivers: drivers, sleepMinutes: minutes, sleepNeed: 480).contains("Sleep"))
        }
        #expect(!TodayMorningSentence.make(score: 32, drivers: drivers, sleepMinutes: 330, sleepNeed: nil).contains("Sleep"))
    }

    @Test func missingInvalidAndDuplicateDriversStayHonest() {
        let sentence = TodayMorningSentence.make(score: 75, drivers: [
            .init(signal: .hrv, change: 8, contribution: 0.4),
            .init(signal: .hrv, change: 8, contribution: 0.3),
            .init(signal: .breathing, change: .nan, contribution: 0.8),
            .init(signal: .restingHeartRate, change: -3, contribution: 0.2)
        ], sleepMinutes: nil, sleepNeed: nil)
        #expect(sentence == "Higher HRV and a lower resting heart rate supported this score.")
        #expect(TodayMorningSentence.make(score: .nan, drivers: [], sleepMinutes: nil, sleepNeed: nil)
            == "Recovery needs at least two overnight heart readings with enough history.")
    }

    @Test func plansUseBothPrintedEdgesAndTheLoadReason() {
        #expect(TodayMorningSentence.plan(range: 8...12, adjustment: .heavy)
            == "Keep strain between 8 and 12 today. The range is lower after a heavy week.")
        #expect(TodayMorningSentence.plan(range: nil) == nil)
        #expect(TodayMorningSentence.plan(range: 0...22) == nil)
    }

    @Test func learningTextClampsCountsAndUsesTheMetricUnit() {
        #expect(LooprLearningText.progress(have: -1, need: 14) == "0 of 14 nights")
        #expect(LooprLearningText.progress(have: 20, need: 14) == "14 of 14 nights")
        #expect(LooprLearningText.progress(have: 9, need: 42, noun: "days") == "9 of 42 days")
        #expect(LooprLearningText.remaining(have: 13, need: 14) == "1 more night")
        #expect(LooprLearningText.remaining(have: 8, need: 14) == "6 more nights")
        #expect(LooprLearningText.stale(days: 3) == "No new nights from your band for 3 days.")
    }

    @Test func earlyEstimateUsesTheLeastLearnedContributingInput() {
        let inputs = TodayTestDays.breakdown(score: 74).inputs.map { input in
            TodayRecoveryBreakdown.Input(signal: input.signal, status: input.status, value: input.value,
                usual: input.usual, baselineNights: input.signal == .hrv ? 4 : 20, weight: input.weight,
                contribution: input.contribution, points: input.points)
        }
        let split = TodayRecoveryBreakdown(score: 74, isSaturated: false, isMeaningful: true, inputs: inputs, nightsNeeded: 3)
        let dashboard = TodayTestDays.dashboard(TodayTestDays.summary(), TodayTestDays.context(recovery: split))
        #expect(dashboard.hero.reading?.earlyEstimate == "Early estimate · 5 of 14 nights")
    }

    @Test func staleNightsNeverBecomeTodaysScore() {
        let history: [TodayTrackedMetric: [LooprChartPoint]] = [.sleep: [.init(date: TodayTestDays.dayStart.addingTimeInterval(-16 * 86_400), value: 450)]]
        let dashboard = TodayTestDays.dashboard(TodayTestDays.summary(recovery: nil, hrv: nil, rhr: nil, sleep: nil), TodayTestDays.context(history: history))
        guard case .unavailable(_, let reason) = dashboard.hero else { Issue.record("Expected stale reason"); return }
        #expect(reason.hasPrefix("No new nights from your band for 16 days."))
    }

    @Test func scoredAndCarriedHeroesNeverSayRecoveryCannotStart() {
        for source in ["test", "Account export"] {
            for score in [0.0, 81.0, 100.0] {
                let summary = TodayTestDays.summary(recovery: score, recoverySource: source)
                let dashboard = TodayTestDays.dashboard(summary, TodayTestDays.context(history: [:]))
                #expect(dashboard.hero.reading?.score == score)
                if source == "Account export" {
                    #expect(dashboard.hero.reading?.driver == "From your account export")
                    #expect(dashboard.hero.reading?.earlyEstimate == nil)
                }
            }
        }
        let history: [TodayTrackedMetric: [LooprChartPoint]] = [
            .recovery: TodayTestDays.series(usual: 81, spread: 0, days: 1),
            .hrv: [.init(date: TodayTestDays.dayStart, value: 58)]
        ]
        let carried = TodayTestDays.dashboard(TodayTestDays.summary(recovery: nil, sleep: nil),
            TodayTestDays.context(history: history))
        if case .carried = carried.hero {} else { Issue.record("Expected the previous night's score") }
    }

    @Test func summaryAndContextUseTheSameTotalNightCount() {
        let summary = TodayTestDays.summary(recovery: nil, recoveryConfidence: "1 of 4 nights. 3 more nights before recovery can start", recoveryState: .settling)
        let learning = TodayHeroRules.learningState(summary: summary, breakdown: nil)
        #expect(learning?.have == 1)
        #expect(learning?.need == 4)
    }
}
