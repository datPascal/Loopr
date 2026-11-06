import DomainKit
import Foundation
import Testing
@testable import RoutineKit

struct ExperimentAnalysisTests {
    private let spread = ExpFixtures.baselineSpread

    private func makeReport(on: [Double], off: [Double], minimum: Int = 3, planned: Int = 14,
                        design: ExperimentDesign = .alternatingDays, washout: Int = 0,
                        outcome: ExperimentMetric = .deepSleep) throws -> ExperimentReport {
        let experiment = try ExpFixtures.experiment(design: design, washout: washout, minimum: minimum, planned: planned,
                                                    outcome: outcome)
        return ExpFixtures.report(experiment, nights: try ExpFixtures.nights(for: experiment, on: on, off: off))
    }

    private func night(_ experiment: Experiment, offset: Int, adherence: ExperimentAdherence = .kept,
                       value: Double?) throws -> ExperimentNight {
        let day = ExpFixtures.night(offset)
        let on = experiment.schedule.role(on: day) == .on
        return try ExperimentNight(experimentID: experiment.id, day: day, arm: on ? .on : .off, isWashout: false,
                                   adherence: adherence, outcomeValue: value, recordedAt: ExpFixtures.createdAt)
    }

    // MARK: Exclusions

    @Test func nightsAreExcludedAndCountedNeverZeroed() throws {
        let experiment = try ExpFixtures.experiment()
        var nights = try ExpFixtures.nights(for: experiment, on: ExpFixtures.clearOn, off: ExpFixtures.clearOff)
        // On nights sit at offsets 0, 2, 4, ... Off nights at 1, 3, 5, ...
        nights = try nights.compactMap { current in
            let offset = ExpFixtures.startDay.days(until: current.day)!
            switch offset {
            case 2: return try night(experiment, offset: 2, adherence: .missed, value: 82)   // did not do it
            case 4: return try night(experiment, offset: 4, adherence: .unknown, value: 78)  // no tick
            case 6: return try night(experiment, offset: 6, value: nil)                      // no measurement
            case 8: return nil                                                               // no record at all
            case 3: return try night(experiment, offset: 3, value: nil)                      // off night, no measurement
            default: return current
            }
        }
        let report = ExpFixtures.report(experiment, nights: nights)
        #expect(report.on.nights == 3 && report.off.nights == 6)
        #expect(report.on.exclusions == ExperimentExclusions(washout: 0, notAdherent: 1, adherenceUnknown: 1, outcomeAbsent: 2))
        #expect(report.off.exclusions == ExperimentExclusions(washout: 0, notAdherent: 0, adherenceUnknown: 0, outcomeAbsent: 1))
        #expect(report.on.exclusions.total == 4)
        // On: 80, 80, 80 survive. Off: 60, 58, 61, 59, 60, 60 survive. A zero in place of a gap would pull both down.
        #expect(report.on.mean == 80)
        #expect(abs((report.off.mean ?? 0) - 358.0 / 6.0) < 1e-9)
        #expect(ExperimentCopy.exclusionsLine(report) == "Left out 1 night you did not do it, 1 night with no tick and 3 nights with no deep sleep reading.")
    }

    @Test func offNightsAreNotJudgedOnAdherence() throws {
        let experiment = try ExpFixtures.experiment()
        let nights = try ExpFixtures.nights(for: experiment, on: ExpFixtures.clearOn, off: ExpFixtures.clearOff, adherence: .unknown)
        // Every night says "unknown", so every on night is out and every off night stays in.
        let report = ExpFixtures.report(experiment, nights: nights)
        #expect(report.on.nights == 0 && report.on.exclusions.adherenceUnknown == 7)
        #expect(report.off.nights == 7)
        #expect(report.state == .notEnoughNights)
    }

    @Test func washoutNightsStayOutOfTheMeansAndAreCounted() throws {
        let report = try makeReport(on: Array(repeating: 80, count: 12), off: Array(repeating: 60, count: 10), minimum: 5,
                                planned: 28, design: .blocks(length: 7), washout: 2)
        #expect(report.on.nights == 12 && report.off.nights == 10)
        #expect(report.on.exclusions.washout == 2 && report.off.exclusions.washout == 4)
        #expect(report.on.mean == 80 && report.off.mean == 60 && report.difference == 20)
        #expect(report.label == .strong)
        #expect(ExperimentCopy.exclusionsLine(report) == "Left out 6 washout nights.")
    }

    @Test func aMissingNightCountsAsAbsentInTheReportAndNotAsZero() throws {
        let experiment = try ExpFixtures.experiment()
        // Only the first four nights exist, the rest of a finished experiment has no record.
        let nights = try ExpFixtures.nights(for: experiment, on: ExpFixtures.clearOn, off: ExpFixtures.clearOff, through: 4)
        let report = ExpFixtures.report(experiment, nights: nights)
        #expect(report.on.nights == 2 && report.off.nights == 2)
        #expect(report.on.exclusions.outcomeAbsent == 5 && report.off.exclusions.outcomeAbsent == 5)
        #expect(report.on.mean == 81 && report.off.mean == 61)
    }

    // MARK: What is shown, and when

    @Test func theRunningStateSaysTooEarlyWithTheContractSentence() throws {
        let experiment = try ExpFixtures.experiment()
        let nights = try ExpFixtures.nights(for: experiment, on: [70, 72, 68, 70], off: [64, 66, 62, 64], through: 8)
        // A baseline scaled so its night-to-night spread reads 9.
        let report = ExpFixtures.report(experiment, nights: nights, baseline: ExpFixtures.baseline(scale: 1.717),
                                        lastNight: ExpFixtures.night(7))
        #expect(report.state == .tooEarlyToSay)
        #expect(report.label == nil && report.range == nil)
        #expect(report.nightsCompleted == 8 && report.difference == 6 && report.favors == .better)
        #expect(ExperimentCopy.progress(experiment: experiment, report: report) == "Running · night 9 of 14")
        #expect(ExperimentCopy.summary(report: report, interventionName: "magnesium")
                == "Too early to say. Magnesium nights are 6 minutes ahead, inside your usual night-to-night spread of 9. Loopr shows a result after night 14, and only if it clears that spread.")
        #expect(ExperimentCopy.outcomeChip == "outcome fixed on day 1")
    }

    @Test func theRunningStateNamesADifferenceBeyondTheSpreadWithoutCallingIt() throws {
        let experiment = try ExpFixtures.experiment()
        let nights = try ExpFixtures.nights(for: experiment, on: [90, 92, 88, 90], off: [60, 62, 58, 60], through: 8)
        let report = ExpFixtures.report(experiment, nights: nights, lastNight: ExpFixtures.night(7))
        let text = ExperimentCopy.summary(report: report, interventionName: "magnesium")
        #expect(text == "Too early to say. Magnesium nights are 30 minutes ahead, outside your usual night-to-night spread of 5.2. Loopr shows a result after night 14.")
        #expect(report.label == nil)
    }

    @Test func theRunningStateHandlesAnArmWithNoNightsAndAWorseDirection() throws {
        let experiment = try ExpFixtures.experiment()
        let first = try ExpFixtures.nights(for: experiment, on: [70], off: [], through: 1)
        let early = ExpFixtures.report(experiment, nights: first, lastNight: ExpFixtures.night(0))
        #expect(early.difference == nil)
        #expect(ExperimentCopy.summary(report: early, interventionName: "magnesium")
                == "Too early to say. Loopr needs a night on and a night off before it can compare them. It shows a result after night 14, and only if it clears your usual night-to-night spread of 5.2.")

        // Sleep heart rate: lower is better, so a higher on night is behind.
        let heart = try ExpFixtures.experiment(outcome: .sleepHeartRate)
        let nights = try ExpFixtures.nights(for: heart, on: [60, 60, 60, 60], off: [55, 55, 55, 55], through: 8)
        let report = ExpFixtures.report(heart, nights: nights, lastNight: ExpFixtures.night(7))
        #expect(report.favors == .worse)
        #expect(ExperimentCopy.summary(report: report, interventionName: "magnesium")
                == "Too early to say. Magnesium nights are 5 beats a minute behind, inside your usual night-to-night spread of 5.2. Loopr shows a result after night 14, and only if it clears that spread.")
    }

    @Test func tooFewBaselineNightsMeansNoResultAndSaysSo() throws {
        let experiment = try ExpFixtures.experiment()
        let nights = try ExpFixtures.nights(for: experiment, on: ExpFixtures.clearOn, off: ExpFixtures.clearOff)
        let short = ExpFixtures.baseline(values: Array(ExpFixtures.baselineValues.prefix(9)))
        let report = ExpFixtures.report(experiment, nights: nights, baseline: short)
        #expect(report.state == .cannotReport(.tooFewNights(have: 9, need: 10)))
        #expect(report.label == nil && report.range == nil && report.spread == nil)
        #expect(ExperimentCopy.summary(report: report, interventionName: "magnesium")
                == "Loopr cannot show a result for this one. It needs 10 nights of deep sleep in the 28 nights before day 1 to learn your usual spread, and found 9.")

        var pairs: [DayIdentity: Double] = [:]
        for index in 0..<10 { pairs[ExpFixtures.night(-1 - 2 * index)] = 50 + Double(index) }
        let gappy = ExpFixtures.report(experiment, nights: nights, baseline: pairs)
        #expect(gappy.state == .cannotReport(.tooFewConsecutivePairs(have: 0, need: 6)))
    }

    @Test func noResultShowsBeforeThePlannedNightsEvenWithEnoughNights() throws {
        let experiment = try ExpFixtures.experiment()
        let nights = try ExpFixtures.nights(for: experiment, on: ExpFixtures.clearOn, off: ExpFixtures.clearOff, through: 11)
        let report = ExpFixtures.report(experiment, nights: nights, lastNight: ExpFixtures.night(10))
        #expect(report.on.nights >= 3 && report.off.nights >= 3)
        #expect(report.state == .tooEarlyToSay && report.label == nil && report.range == nil)
        #expect((report.difference ?? 0) > report.spread ?? 99)
    }

    @Test func reachingThePlannedNightsEndsTheWaitEvenWhileStillRunning() throws {
        let experiment = try ExpFixtures.experiment()
        #expect(experiment.status == .running)
        let nights = try ExpFixtures.nights(for: experiment, on: ExpFixtures.clearOn, off: ExpFixtures.clearOff)
        let report = ExpFixtures.report(experiment, nights: nights, lastNight: experiment.start.lastPlannedDay)
        #expect(report.label == .strong)
    }

    @Test func anArmBelowTheMinimumGivesNoResultEvenWhenFinished() throws {
        let experiment = try ExpFixtures.experiment()
        var nights = try ExpFixtures.nights(for: experiment, on: ExpFixtures.clearOn, off: ExpFixtures.clearOff)
        // Five of the seven on nights are ones the person did not do.
        var missed = 0
        nights = try nights.map { current in
            guard current.arm == .on, missed < 5 else { return current }
            missed += 1
            return try ExperimentNight(experimentID: current.experimentID, day: current.day, arm: .on, isWashout: false,
                                       adherence: .missed, outcomeValue: current.outcomeValue, recordedAt: current.recordedAt)
        }
        let report = ExpFixtures.report(experiment, nights: nights)
        #expect(report.state == .notEnoughNights && report.label == nil && report.range == nil)
        #expect(ExperimentCopy.summary(report: report, interventionName: "magnesium")
                == "Not enough nights to show a result. Loopr needs 3 counted nights on and 3 off, and has 2 on and 7 off. Left out 5 nights you did not do it.")
    }

    // MARK: Labels

    @Test func aClearEffectIsLabelledClear() throws {
        let report = try makeReport(on: ExpFixtures.clearOn, off: ExpFixtures.clearOff, minimum: 5)
        #expect(report.state == .result(.clear))
        #expect(report.difference == 20 && report.favors == .better)
        let range = try #require(report.range)
        #expect(range.lowerBound > spread && range.contains(20) && report.rangeOutsideSpread)
        #expect(ExperimentCopy.resultHeadline(report: report) == "+20 min")
        let text = ExperimentCopy.summary(report: report, interventionName: "magnesium")
        #expect(text.hasPrefix("Deep sleep was 20 minutes higher on magnesium nights than on the other nights. The 95% range is "))
        #expect(text.contains(" minutes, and the whole range sits outside your usual spread."))
        #expect(text.hasSuffix(ExperimentCopy.footnote))
        // The row carries the range and the nights on each side, and Clear is only ever said with the range outside.
        let row = ExperimentCopy.listSubtitle(report: report)
        #expect(row.hasPrefix("Deep sleep +20 min, 95% range +") && row.hasSuffix(" · 7 nights each"), "\(row)")
        #expect(ExperimentCopy.effectWithRange(report: report)
                == "+20 min, 95% range \(ExperimentCopy.signed(range.lowerBound)) to \(ExperimentCopy.signed(range.upperBound))")
        #expect(ExperimentCopy.rangeLine(report: report)
                == "95% range \(ExperimentCopy.signed(range.lowerBound)) to \(ExperimentCopy.signed(range.upperBound)) min · 7 nights each")
        #expect(ExperimentLabel.clear.title == "Clear" && ExperimentLabel.clear.claimsDifference)
    }

    @Test func aLargeEffectOnEnoughNightsIsLabelledStrong() throws {
        let report = try makeReport(on: ExpFixtures.clearOn, off: ExpFixtures.clearOff, minimum: 3)
        #expect(report.label == .strong)
        #expect(ExperimentLabel.strong.title == "Strong")
        #expect((report.range?.lowerBound ?? 0) >= 2 * spread)
    }

    @Test func anEffectInsideTheNoiseIsNoChange() throws {
        let report = try makeReport(on: ExpFixtures.sameOn, off: ExpFixtures.sameOff)
        #expect(report.state == .result(.noChange))
        let range = try #require(report.range)
        #expect(range.lowerBound >= -spread && range.upperBound <= spread && !report.rangeOutsideSpread)
        #expect(report.favors == nil)
        let text = ExperimentCopy.summary(report: report, interventionName: "magnesium")
        #expect(text.hasPrefix("Deep sleep looked about the same on magnesium nights and the other nights. The 95% range is "))
        #expect(text.contains(", inside your usual spread of 5.2."))
        let row = ExperimentCopy.listSubtitle(report: report)
        #expect(row.hasPrefix("Deep sleep ") && row.contains(", 95% range ") && row.hasSuffix(" · 7 nights each"), "\(row)")
        #expect(ExperimentLabel.noChange.title == "No change" && !ExperimentLabel.noChange.claimsDifference)
    }

    @Test func aDifferenceBeyondTheSpreadWhoseRangeReachesInsideIsEarlyAndClaimsNothing() throws {
        let report = try makeReport(on: ExpFixtures.noisyOn, off: ExpFixtures.steadyOff)
        #expect(report.state == .result(.early))
        #expect(abs(report.difference ?? 0) > spread && !report.rangeOutsideSpread)
        let text = ExperimentCopy.summary(report: report, interventionName: "magnesium")
        #expect(text.hasPrefix("A first look only. "))
        #expect(text.contains("It still reaches into your usual spread of 5.2. Loopr does not call it a difference."))
        #expect(!text.contains("whole range sits outside"))
        #expect(ExperimentLabel.early.title == "Early" && !ExperimentLabel.early.claimsDifference)
    }

    @Test func aRangeWiderThanTheBandWithASmallDifferenceIsNotCalled() throws {
        let report = try makeReport(on: ExpFixtures.noisyOn, off: ExpFixtures.level66Off)
        #expect(report.state == .notCalled && report.label == nil)
        #expect(abs(report.difference ?? 99) <= spread)
        let text = ExperimentCopy.summary(report: report, interventionName: "magnesium")
        #expect(text.hasPrefix("Loopr does not call this one. The 95% range is "))
        #expect(text.hasSuffix("so these nights cannot tell a change from noise."))
        let row = ExperimentCopy.listSubtitle(report: report)
        #expect(row.contains(", 95% range ") && row.hasSuffix(" · 7 nights each"), "\(row)")
    }

    @Test func aWorseDirectionStaysLabelledByEvidenceAndPointsTheOtherWay() throws {
        let report = try makeReport(on: ExpFixtures.clearOn, off: ExpFixtures.clearOff, minimum: 3, outcome: .sleepHeartRate)
        #expect(report.label == .strong && report.favors == .worse)
        // ICP R2-SEN-13: the sentence says the unit in words; the number beside it keeps "bpm".
        #expect(ExperimentCopy.resultSentence(report: report, interventionName: "Cool bedroom")
                == "Sleep heart rate was 20 beats a minute higher on cool bedroom nights than on the other nights.")
    }

    @Test func theLabelMappingIsDocumentedCaseByCase() {
        let s = 5.0
        func call(_ difference: Double, _ range: ClosedRange<Double>, on: Int = 7, off: Int = 7, minimum: Int = 5,
                  stopped: Bool = false) -> ExperimentCall {
            ExperimentAnalyzer.call(difference: difference, range: range, spread: s, onNights: on, offNights: off,
                                    minimumNightsPerArm: minimum, stoppedEarly: stopped)
        }
        // The whole range beyond the band is Clear, or Strong with a cautious end at 2 spreads and 2x the minimum nights.
        #expect(call(14, 6...22) == .effect(.clear))
        #expect(call(17, 12...22, on: 10, off: 10) == .effect(.strong))
        #expect(call(17, 12...22, on: 10, off: 9) == .effect(.clear))
        #expect(call(17, 9.9...22, on: 10, off: 10) == .effect(.clear))
        #expect(call(-17, -22 ... -12, on: 10, off: 10) == .effect(.strong))
        #expect(call(-14, -22 ... -6) == .effect(.clear))
        // A difference beyond the band whose range reaches inside it is Early.
        #expect(call(11, 2...20) == .effect(.early))
        #expect(call(-11, -20 ... -2) == .effect(.early))
        // The whole range inside the band is No change, edges included.
        #expect(call(0.5, -3...4) == .noChange)
        #expect(call(0, -5...5) == .noChange)
        // A small difference with a wider range is not called.
        #expect(call(1, -9...12) == .notCalled)
        #expect(call(4, 3...20) == .notCalled)
        // An early stop never claims more than Early, and never hides No change.
        #expect(call(14, 6...22, stopped: true) == .effect(.early))
        #expect(call(17, 12...22, on: 10, off: 10, stopped: true) == .effect(.early))
        #expect(call(0.5, -3...4, stopped: true) == .noChange)
        #expect(call(1, -9...12, stopped: true) == .notCalled)
    }

    // MARK: Early stop

    @Test func anEarlyStopWithEnoughNightsIsAtMostEarly() throws {
        let experiment = try ExpFixtures.experiment(planned: 14, status: .stopped, endDay: ExpFixtures.night(9))
        let nights = try ExpFixtures.nights(for: experiment, on: ExpFixtures.clearOn, off: ExpFixtures.clearOff)
        let report = ExpFixtures.report(experiment, nights: nights, lastNight: ExpFixtures.night(9))
        #expect(report.stoppedEarly && report.on.nights == 5 && report.off.nights == 5)
        #expect(report.difference == 20 && report.rangeOutsideSpread)
        #expect(report.state == .result(.early))
        let text = ExperimentCopy.summary(report: report, interventionName: "magnesium")
        #expect(text.hasPrefix("You stopped early, so this is a first look only. "))
        #expect(text.contains("You stopped before the plan finished. Loopr does not call it a difference."))
        #expect(ExperimentCopy.progress(experiment: experiment, report: report) == "Stopped · 10 nights")
    }

    @Test func anEarlyStopWithTooFewNightsGivesNoResult() throws {
        let experiment = try ExpFixtures.experiment(planned: 14, status: .stopped, endDay: ExpFixtures.night(3))
        let nights = try ExpFixtures.nights(for: experiment, on: ExpFixtures.clearOn, off: ExpFixtures.clearOff)
        let report = ExpFixtures.report(experiment, nights: nights, lastNight: ExpFixtures.night(3))
        #expect(report.on.nights == 2 && report.off.nights == 2)
        #expect(report.state == .notEnoughNights && report.label == nil)
    }

    @Test func anEarlyStopStillSaysNoChangeWhenTheRangeIsInsideTheNoise() throws {
        let experiment = try ExpFixtures.experiment(planned: 14, status: .stopped, endDay: ExpFixtures.night(9))
        let nights = try ExpFixtures.nights(for: experiment, on: ExpFixtures.sameOn, off: ExpFixtures.sameOff)
        let report = ExpFixtures.report(experiment, nights: nights, lastNight: ExpFixtures.night(9))
        #expect(report.state == .result(.noChange))
    }

    @Test func aStopOnTheLastPlannedNightIsNotAnEarlyStop() throws {
        let experiment = try ExpFixtures.experiment(planned: 14, status: .stopped, endDay: ExpFixtures.night(13))
        #expect(!experiment.stoppedEarly)
        let nights = try ExpFixtures.nights(for: experiment, on: ExpFixtures.clearOn, off: ExpFixtures.clearOff)
        #expect(ExpFixtures.report(experiment, nights: nights).label == .strong)
    }

    // MARK: Also moved

    @Test func otherMetricsThatMovedAreListedAndNeverClaimed() throws {
        let experiment = try ExpFixtures.experiment()
        let base = try ExpFixtures.nights(for: experiment, on: ExpFixtures.clearOn, off: ExpFixtures.clearOff)
        let nights = try base.map { current in
            let onNight = current.arm == .on
            return try ExperimentNight(
                experimentID: current.experimentID, day: current.day, arm: current.arm, isWashout: false,
                adherence: .kept, outcomeValue: current.outcomeValue,
                otherValues: [ExperimentMetric.timeToFallAsleep.key: onNight ? 22 : 30,
                              ExperimentMetric.hrv.key: 50,
                              ExperimentMetric.sleepHeartRate.key: onNight ? 50 : 70],
                recordedAt: current.recordedAt)
        }
        let baseline = ExpFixtures.baseline()
        let report = ExpFixtures.report(
            experiment, nights: nights,
            otherBaselines: [ExperimentMetric.timeToFallAsleep.key: baseline, ExperimentMetric.hrv.key: baseline],
            alsoMetrics: [.deepSleep, .timeToFallAsleep, .hrv, .sleepHeartRate])
        #expect(report.label == .strong)
        // Deep sleep is the outcome, HRV did not move, and sleep heart rate has no baseline to judge it against.
        let moved = try #require(report.alsoMoved.first)
        #expect(report.alsoMoved.count == 1)
        #expect(moved.metric == .timeToFallAsleep && moved.difference == -8 && moved.favors == .better)
        #expect(!moved.claimed)
        #expect(ExperimentCopy.alsoMoved(moved) == "Fell asleep 8 min sooner. Not the outcome, so shown, not claimed.")
    }

    @Test func alsoMovedStaysEmptyWhenThereIsNoResultToShow() throws {
        let experiment = try ExpFixtures.experiment()
        let nights = try ExpFixtures.nights(for: experiment, on: ExpFixtures.clearOn, off: ExpFixtures.clearOff, through: 8)
        let report = ExpFixtures.report(experiment, nights: nights, alsoMetrics: [.timeToFallAsleep], lastNight: ExpFixtures.night(7))
        #expect(report.alsoMoved.isEmpty)
        let named = AlsoMoved(metric: .hrv, difference: 6, range: 5...7, favors: .better)
        #expect(ExperimentCopy.alsoMoved(named) == "HRV was 6 ms higher. Not the outcome, so shown, not claimed.")
        let later = AlsoMoved(metric: .timeToFallAsleep, difference: 8, range: 7...9, favors: .worse)
        #expect(ExperimentCopy.alsoMoved(later) == "Fell asleep 8 min later. Not the outcome, so shown, not claimed.")
    }

    // MARK: Determinism

    @Test func theIntervalIsDeterministicForAFixedSeed() throws {
        let first = try #require(ExperimentStatistics.bootstrapInterval(on: ExpFixtures.clearOn, off: ExpFixtures.clearOff,
                                                                         seed: 42, resamples: 2_000, confidence: 0.95))
        let second = try #require(ExperimentStatistics.bootstrapInterval(on: ExpFixtures.clearOn, off: ExpFixtures.clearOff,
                                                                          seed: 42, resamples: 2_000, confidence: 0.95))
        let other = try #require(ExperimentStatistics.bootstrapInterval(on: ExpFixtures.clearOn, off: ExpFixtures.clearOff,
                                                                         seed: 43, resamples: 2_000, confidence: 0.95))
        #expect(first == second)
        #expect(first != other)
        #expect(first.lowerBound < 20 && first.upperBound > 20)
        // Without any spread inside the arms the interval has no width, whatever the seed.
        #expect(ExperimentStatistics.bootstrapInterval(on: [10, 10, 10], off: [4, 4], seed: 7, resamples: 500, confidence: 0.95) == Optional(6.0...6.0))
        #expect(ExperimentStatistics.bootstrapInterval(on: [], off: [4], seed: 7, resamples: 500, confidence: 0.95) == nil)
        // A wider confidence level gives a wider range.
        let wide = try #require(ExperimentStatistics.bootstrapInterval(on: ExpFixtures.noisyOn, off: ExpFixtures.steadyOff,
                                                                        seed: 5, resamples: 2_000, confidence: 0.99))
        let narrow = try #require(ExperimentStatistics.bootstrapInterval(on: ExpFixtures.noisyOn, off: ExpFixtures.steadyOff,
                                                                          seed: 5, resamples: 2_000, confidence: 0.80))
        #expect(wide.upperBound - wide.lowerBound > narrow.upperBound - narrow.lowerBound)
    }

    @Test func aReportIsTheSameEveryTimeItIsBuilt() throws {
        let experiment = try ExpFixtures.experiment()
        let nights = try ExpFixtures.nights(for: experiment, on: ExpFixtures.noisyOn, off: ExpFixtures.steadyOff)
        let one = ExpFixtures.report(experiment, nights: nights)
        let two = ExpFixtures.report(experiment, nights: nights)
        #expect(one == two && one.range != nil)
        let seeded = ExperimentAnalyzer.report(experiment: experiment, nights: nights, baseline: ExpFixtures.baseline(),
                                               lastNight: experiment.start.lastPlannedDay, seed: 11)
        let reseeded = ExperimentAnalyzer.report(experiment: experiment, nights: nights, baseline: ExpFixtures.baseline(),
                                                 lastNight: experiment.start.lastPlannedDay, seed: 12)
        #expect(seeded.range != reseeded.range)
        #expect(one.policyVersion == "experiment.v1")
    }

    @Test func theSeedComesFromTheExperimentAndNotTheProcess() {
        let id = ExpFixtures.experimentID
        #expect(ExperimentStatistics.seed(for: id) == ExperimentStatistics.seed(for: id))
        #expect(ExperimentStatistics.seed(for: id) != ExperimentStatistics.seed(for: ExperimentID()))
        // Fixed expectation: FNV-1a of the uppercase UUID text. A change here changes every stored result.
        var expected: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in "6F1A2B3C-0000-4000-8000-000000000007".utf8 { expected = (expected ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
        #expect(ExperimentStatistics.seed(for: id) == expected)
    }

    @Test func theGeneratorMatchesTheSplitMix64ReferenceStream() {
        var generator = ExperimentStatistics.SeededGenerator(seed: 0)
        #expect(generator.next() == 0xE220_A839_7B1D_CDAF)
        #expect(generator.next() == 0x6E78_9E6A_A1B9_65F4)
    }

    // MARK: Copy

    @Test func numbersAreWrittenTheSameInEveryLocale() {
        #expect(ExperimentCopy.amount(14) == "14" && ExperimentCopy.amount(7.54) == "7.5" && ExperimentCopy.amount(-3.04) == "3")
        #expect(ExperimentCopy.signed(14) == "+14" && ExperimentCopy.signed(-9.3) == "\u{2212}9.3" && ExperimentCopy.signed(0.01) == "0")
        #expect(ExperimentCopy.outcomeLine(.deepSleep) == "Deep sleep, fixed on day 1")
    }

    /// ICP R1-VET-12: the spread names its statistic and its window, and the likely range names how it is made.
    @Test func theHowThisWorksSentencesNameTheirStatistics() {
        let spread = ExperimentCopy.spreadExplanation(spread: 9, unit: "min")
        #expect(spread.hasPrefix("The shaded band is your usual spread, 9 min either side of the other nights' average."))
        #expect(spread.contains("on the 28 nights before night 1") && spread.contains("one standard deviation of a single night")
                && spread.contains("scaled median absolute deviation"))
        #expect(ExperimentCopy.rangeExplanation().contains("2000 times, a 95 percent bootstrap range"))
        #expect(ExperimentCopy.outcomeFixed(.hrv) == "Loopr fixed the measure, HRV, on day 1. Nobody can swap it later for one that looks better.")
        #expect(ExperimentCopy.outcomeFixed(.deepSleep).contains("measure, deep sleep, on day 1"))
    }

    @Test func unevenSidesNameBothCounts() throws {
        let report = try makeReport(on: Array(ExpFixtures.clearOn.prefix(5)), off: ExpFixtures.clearOff)
        #expect(ExperimentCopy.nightsPerSide(report) == "5 nights with, 7 without")
    }

    @Test func noSentenceUsesAnEmDashOrAnExclamationMark() throws {
        let reports = [
            try makeReport(on: ExpFixtures.clearOn, off: ExpFixtures.clearOff),
            try makeReport(on: ExpFixtures.sameOn, off: ExpFixtures.sameOff),
            try makeReport(on: ExpFixtures.noisyOn, off: ExpFixtures.steadyOff),
            try makeReport(on: ExpFixtures.noisyOn, off: ExpFixtures.level66Off)
        ]
        var sentences = reports.map { ExperimentCopy.summary(report: $0, interventionName: "magnesium") }
        sentences += reports.map { ExperimentCopy.listSubtitle(report: $0) }
        sentences += [ExperimentCopy.tonight(role: .on, interventionName: "magnesium"),
                      ExperimentCopy.tonight(role: .washout(.off), interventionName: "magnesium")].compactMap { $0 }
        for sentence in sentences {
            #expect(!sentence.contains("\u{2014}") && !sentence.contains("!"), "\(sentence)")
        }
    }
}
