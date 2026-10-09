import Foundation
import SwiftUI
import Testing
@testable import DesignSystem

// Tests for the tabs-redesign kit: formatters, recovery bands, delta
// captions, row cleanup rules, scrub arithmetic, the stage timeline model,
// the bar chart models and the shared fixture truth.

private let minus = LooprUnitFormatter.minusSign

struct DurationFormatterTests {
    @Test func durationsReadAsHoursAndMinutesOrMinutesAlone() {
        #expect(LooprUnitFormatter.duration(minutes: 462) == "7 h 42 m")
        #expect(LooprUnitFormatter.duration(minutes: 480) == "8 h")
        #expect(LooprUnitFormatter.duration(minutes: 24) == "24 min")
        #expect(LooprUnitFormatter.duration(minutes: 59.6) == "1 h")
        #expect(LooprUnitFormatter.duration(minutes: 0) == "0 min")
        #expect(LooprUnitFormatter.duration(minutes: 61) == "1 h 1 m")
    }

    @Test func impossibleDurationsReturnNilInsteadOfAMadeUpZero() {
        #expect(LooprUnitFormatter.duration(minutes: -5) == nil)
        #expect(LooprUnitFormatter.duration(minutes: .nan) == nil)
        #expect(LooprUnitFormatter.duration(minutes: .infinity) == nil)
    }

    @Test func signedDurationsCarryATrueMinusAndNeverPlusZero() {
        #expect(LooprUnitFormatter.signedDuration(minutes: 24) == "+24 min")
        #expect(LooprUnitFormatter.signedDuration(minutes: -65) == "\(minus)1 h 5 m")
        #expect(LooprUnitFormatter.signedDuration(minutes: 0.3) == "0 min")
        #expect(LooprUnitFormatter.signedDuration(minutes: -0.4) == "0 min")
    }

    @Test func spokenDurationsSpellOutUnits() {
        #expect(LooprUnitFormatter.spokenDuration(minutes: 462) == "7 hours 42 minutes")
        #expect(LooprUnitFormatter.spokenDuration(minutes: 60) == "1 hour")
        #expect(LooprUnitFormatter.spokenDuration(minutes: 1) == "1 minute")
        #expect(LooprUnitFormatter.spokenDuration(minutes: -24) == "24 minutes")
    }

    @Test func signedNumbersUseOneLocaleAndRoundBeforeChoosingASign() {
        #expect(LooprUnitFormatter.signed(6) == "+6")
        #expect(LooprUnitFormatter.signed(-2.46, digits: 1) == "\(minus)2.5")
        #expect(LooprUnitFormatter.signed(0.4) == "0")
        #expect(LooprUnitFormatter.signed(-0.04, digits: 1) == "0.0")
        #expect(LooprUnitFormatter.number(8_240) == "8,240")
        #expect(LooprUnitFormatter.number(14.6, digits: 1) == "14.6")
        #expect(LooprUnitFormatter.signed(.nan) == nil)
    }

    @Test func spokenUnitsAreWords() {
        #expect(LooprUnitFormatter.spokenUnit("ms") == "milliseconds")
        #expect(LooprUnitFormatter.spokenUnit("bpm") == "beats per minute")
        #expect(LooprUnitFormatter.spokenUnit("br/min") == "breaths per minute")
        #expect(LooprUnitFormatter.spokenUnit("/21") == "out of 21")
        #expect(LooprUnitFormatter.spokenUnit("%") == "percent")
        #expect(LooprUnitFormatter.spokenUnit("steps") == "steps")
    }
}

struct RowValueTests {
    @Test func clockHoursBecomeASpelledDuration() {
        let row = LooprUnitFormatter.rowValue("7:42", unit: "hours", title: "Duration")
        #expect(row.value == "7 h 42 m")
        #expect(row.unit.isEmpty)
    }

    @Test func decimalHoursAndMinutesBecomeDurations() {
        #expect(LooprUnitFormatter.rowValue("0.4", unit: "hours", title: "Sleep debt").value == "24 min")
        #expect(LooprUnitFormatter.rowValue("82", unit: "minutes", title: "Deep sleep").value == "1 h 22 m")
        #expect(LooprUnitFormatter.rowValue("12", unit: "minutes", title: "Time to fall asleep").value == "12 min")
    }

    @Test func fillerUnitsAreDropped() {
        for unit in ["points", "index", "load", "level", "power", "zones", "score", "quality", "TSB"] {
            let row = LooprUnitFormatter.rowValue("42", unit: unit, title: "Something")
            #expect(row.unit.isEmpty, "\(unit) should be dropped")
            #expect(row.value == "42")
        }
    }

    @Test func aUnitTheTitleAlreadySaysIsDropped() {
        #expect(LooprUnitFormatter.rowValue("8,240", unit: "steps", title: "Estimated steps").unit.isEmpty)
        #expect(LooprUnitFormatter.rowValue("4", unit: "cycles", title: "Sleep cycles").unit.isEmpty)
    }

    @Test func realUnitsSurvive() {
        #expect(LooprUnitFormatter.rowValue("58", unit: "ms", title: "RMSSD").unit == "ms")
        #expect(LooprUnitFormatter.rowValue("3", unit: "times", title: "Wake-ups").unit == "times")
        #expect(LooprUnitFormatter.rowValue("8.6", unit: "/21", title: "Strain").unit == "/21")
        #expect(LooprUnitFormatter.rowValue("91", unit: "%", title: "Efficiency").unit == "%")
    }

    @Test func textThatIsNotANumberPassesThrough() {
        let row = LooprUnitFormatter.rowValue("moderate", unit: "hours", title: "Effort")
        #expect(row.value == "moderate")
        #expect(row.unit == "hours")
    }
}

@MainActor
struct RowPresentationTests {
    @Test func highConfidenceAndPartialDataAreNotShown() {
        #expect(LooprRowPresentation.make(title: "Duration", value: "7:42", unit: "hours", confidence: "High confidence").caption == nil)
        #expect(LooprRowPresentation.make(title: "Duration", value: "7:42", unit: "hours", confidence: "Partial data").caption == nil)
        #expect(LooprRowPresentation.make(title: "Energy", value: "612", unit: "kcal", confidence: "Low confidence").caption == "Low confidence")
        #expect(LooprRowPresentation.make(title: "Score", value: "84", unit: nil, confidence: "6 of 7 nights").caption == "6 of 7 nights")
    }

    @Test func absentValuesAreQuietText() {
        let row = LooprRowPresentation.make(title: "Heart-rate dip", value: "Not measured", unit: "%", confidence: nil)
        #expect(row.isAbsent)
        #expect(row.value == "No reading")
        #expect(row.unit == nil)
        let dash = LooprRowPresentation.make(title: "HRV", value: "\u{2014}", unit: "ms", confidence: nil)
        #expect(dash.isAbsent)
        #expect(dash.value == "No reading")
        let permission = LooprRowPresentation.make(title: "VO2 max", value: MetricState.permissionDenied.title, unit: nil, confidence: nil)
        #expect(permission.isAbsent)
        #expect(permission.value == "Permission needed")
    }

    @Test func aStateTitlePassedAsTheCaptionMovesIntoTheValueSlot() {
        let row = LooprRowPresentation.make(title: "REM sleep", value: "", unit: nil, confidence: "Not measured")
        #expect(row.isAbsent)
        #expect(row.value == "No reading")
        #expect(row.caption == nil)
    }

    @Test func aNavigationRowWithNoValueIsNotAbsent() {
        let row = LooprRowPresentation.make(title: "Night timeline", value: "", unit: nil, confidence: nil)
        #expect(!row.isAbsent)
        #expect(row.value.isEmpty)
    }

    @Test func measuredZeroIsAValue() {
        let row = LooprRowPresentation.make(title: "Steps", value: "0", unit: "steps", confidence: MetricState.measuredZero.title)
        #expect(!row.isAbsent)
        #expect(row.value == "0")
    }

    @Test func sentencesAreNotUppercased() {
        #expect(LooprRowPresentation.isSentence("Estimated from wrist motion and your walking pace"))
        #expect(LooprRowPresentation.isSentence("Add your age to your profile to see strain"))
        #expect(!LooprRowPresentation.isSentence("6 of 7 nights"))
        #expect(!LooprRowPresentation.isSentence("Low confidence"))
        #expect(LooprRowPresentation.isSentence("Use with care."))
    }

    @Test func hairlineRowSpeaksWhatItShows() {
        let row = HairlineMetricRow(title: "Duration", confidence: "High confidence", value: "7:42", unit: "hours", showsDisclosure: true)
        #expect(row.accessibilitySummary == "Duration, 7 h 42 m, Opens details")
        let rmssd = HairlineMetricRow(title: "RMSSD", value: "58", unit: "ms")
        #expect(rmssd.accessibilitySummary == "RMSSD, 58 milliseconds")
        // Stored properties stay what the caller passed, for callers and tests
        // that read them.
        #expect(row.value == "7:42")
        #expect(row.unit == "hours")
    }

    @Test func valueTextSplitsNumbersFromUnitWords() {
        let pieces = LooprValueText.pieces("7 h 42 m", unit: nil)
        #expect(pieces.map(\.0) == ["7", "h", "42", "m"])
        #expect(pieces.map(\.1) == [true, false, true, false])
        #expect(LooprValueText.pieces("58", unit: "ms").map(\.1) == [true, false])
    }
}

struct RecoveryBandTests {
    @Test func bandsFollowTheWhoopCutOffsAfterRounding() {
        #expect(LooprRecoveryBand(score: 0) == .low)
        #expect(LooprRecoveryBand(score: 33) == .low)
        #expect(LooprRecoveryBand(score: 33.4) == .low)
        #expect(LooprRecoveryBand(score: 33.5) == .middle)
        #expect(LooprRecoveryBand(score: 34) == .middle)
        #expect(LooprRecoveryBand(score: 66) == .middle)
        #expect(LooprRecoveryBand(score: 66.5) == .high)
        #expect(LooprRecoveryBand(score: 67) == .high)
        #expect(LooprRecoveryBand(score: 100) == .high)
    }

    @Test func outOfRangeScoresClampAndMissingScoresHaveNoBand() {
        #expect(LooprRecoveryBand(score: -4) == .low)
        #expect(LooprRecoveryBand(score: 140) == .high)
        #expect(LooprRecoveryBand(score: nil) == nil)
        #expect(LooprRecoveryBand(score: .nan) == nil)
    }

    @Test func eachBandHasItsOwnColourVerdictAndSweep() {
        let tokens = Set(LooprRecoveryBand.allCases.map(\.token))
        #expect(tokens.count == 3)
        #expect(Set(LooprRecoveryBand.allCases.map(\.verdict)).count == 3)
        #expect(LooprRecoveryBand.high.token.spectralSweepPartner == .recoveryHighSweep)
        #expect(LooprRecoveryBand.low.token.spectralSweepPartner == .recoveryLowSweep)
        #expect(!tokens.contains(.critical))
        #expect(!tokens.contains(.heart))
    }

    @Test func textInkIsReadableForEveryDomain() {
        #expect(LooprColorToken.brand.textInk == .brandInk)
        #expect(LooprColorToken.recovery.textInk == .brandInk)
        #expect(LooprColorToken.strain.textInk == .caution)
        #expect(LooprColorToken.sleep.textInk == .sleepChip)
        #expect(LooprColorToken.inkTertiary == .inkMuted)
    }
}

struct DeltaCaptionTests {
    private let band = LooprBaselineBand(center: 51, lower: 47, upper: 55, measuredDays: 28)

    @Test func insideTheUsualRangeReadsUsual() {
        let delta = LooprDelta.compare(53, usual: band, higherIsBetter: true, unit: "ms")
        #expect(delta?.kind == .usual)
        #expect(delta?.text == "Usual")
        #expect(delta?.tone == .neutral)
        #expect(delta?.spokenText == "In your usual range")
    }

    @Test func insideTheRangeCanStillShowItsSizeWhenAsked() {
        let delta = LooprDelta.compare(53, usual: band, higherIsBetter: true, unit: "ms", withinRange: .signed)
        #expect(delta?.text == "+2 ms vs usual")
        #expect(delta?.tone == .good)
        let worse = LooprDelta.compare(49, usual: band, higherIsBetter: true, unit: "ms", withinRange: .signed)
        #expect(worse?.tone == .neutral, "The bad direction is grey inside the usual range")
    }

    @Test func outsideTheRangePrintsASignedDifference() {
        let delta = LooprDelta.compare(58, usual: band, higherIsBetter: true, unit: "ms")
        #expect(delta?.text == "+7 ms vs usual")
        #expect(delta?.compactText == "+7 ms")
        #expect(delta?.tone == .good)
        #expect(delta?.spokenText == "7 milliseconds above your usual")
    }

    @Test func theUnwantedDirectionOutsideTheRangeIsAmberNeverRed() {
        let rhr = LooprBaselineBand(center: 54, lower: 52.5, upper: 55.5, measuredDays: 28)
        let delta = LooprDelta.compare(59, usual: rhr, higherIsBetter: false, unit: "bpm")
        #expect(delta?.tone == .caution)
        #expect(LooprDeltaCaption.token(for: .caution, accent: .heart) == .caution)
        #expect(LooprDeltaCaption.token(for: .good, accent: .heart) == .heartChip)
        #expect(LooprDeltaCaption.token(for: .neutral, accent: .heart) == .inkSecondary)
        let lower = LooprDelta.compare(51, usual: rhr, higherIsBetter: false, unit: "bpm")
        #expect(lower?.tone == .good)
        #expect(lower?.text == "\(minus)3 bpm vs usual")
    }

    @Test func metricsWithNoGoodDirectionStayGrey() {
        let strain = LooprBaselineBand(center: 11, lower: 9, upper: 13, measuredDays: 28)
        let delta = LooprDelta.compare(17.2, usual: strain, higherIsBetter: nil, format: .number(digits: 1))
        #expect(delta?.tone == .neutral)
        #expect(delta?.text == "+6.2 vs usual")
    }

    @Test func aChangeThatRoundsToNothingReadsUsual() {
        let tight = LooprBaselineBand(center: 51, lower: 51, upper: 51, measuredDays: 28)
        let delta = LooprDelta.compare(51.3, usual: tight, higherIsBetter: true, unit: "ms")
        #expect(delta?.kind == .usual)
    }

    @Test func percentAndDurationFormats() {
        let hrv = LooprDelta.compare(40, usual: band, higherIsBetter: true, format: .percent)
        #expect(hrv?.text == "\(minus)22% vs usual")
        #expect(hrv?.spokenText == "22 percent below your usual")
        let sleepBand = LooprBaselineBand(center: 452, lower: 425, upper: 479, measuredDays: 28)
        let sleep = LooprDelta.compare(372, usual: sleepBand, higherIsBetter: true, format: .duration)
        #expect(sleep?.text == "\(minus)1 h 20 m vs usual")
        #expect(sleep?.spokenText == "1 hour 20 minutes below your usual")
        #expect(sleep?.tone == .caution)
    }

    @Test func learningWhenThereIsNoUsualRangeYet() {
        let delta = LooprDelta.compare(58, usual: nil, higherIsBetter: true, unit: "ms", learning: (3, 14))
        #expect(delta?.compactText == "Learning · 3 of 14 nights")
        #expect(delta?.text == "Learning your usual · 3 of 14 nights")
        #expect(delta?.spokenText == "Learning your usual range, 3 of 14 nights")
        #expect(LooprDelta.learning(20, of: 14).compactText == "Learning · 14 of 14 nights")
    }

    @Test func noValueOrNothingToSayMeansNoCaption() {
        #expect(LooprDelta.compare(nil, usual: band, higherIsBetter: true) == nil)
        #expect(LooprDelta.compare(.nan, usual: band, higherIsBetter: true) == nil)
        #expect(LooprDelta.compare(58, usual: nil, higherIsBetter: true) == nil)
    }
}

struct ScrubMathTests {
    @Test func fractionClampsToTheTrack() {
        #expect(LooprScrubMath.fraction(x: -20, width: 200) == 0)
        #expect(LooprScrubMath.fraction(x: 50, width: 200) == 0.25)
        #expect(LooprScrubMath.fraction(x: 400, width: 200) == 1)
        #expect(LooprScrubMath.fraction(x: 10, width: 0) == 0)
    }

    @Test func indexPicksTheSlotUnderTheFingerAndClampsAtTheEdges() {
        #expect(LooprScrubMath.index(x: 0, width: 140, count: 14) == 0)
        #expect(LooprScrubMath.index(x: 9.9, width: 140, count: 14) == 0)
        #expect(LooprScrubMath.index(x: 10, width: 140, count: 14) == 1)
        #expect(LooprScrubMath.index(x: 140, width: 140, count: 14) == 13)
        #expect(LooprScrubMath.index(x: 500, width: 140, count: 14) == 13)
        #expect(LooprScrubMath.index(x: -3, width: 140, count: 14) == 0)
        #expect(LooprScrubMath.index(x: 20, width: 140, count: 0) == nil)
    }

    @Test func centreAndIndexAgree() {
        for index in 0..<7 {
            let x = LooprScrubMath.center(of: index, count: 7, width: 280)
            #expect(LooprScrubMath.index(x: x, width: 280, count: 7) == index)
        }
    }

    @Test func timeAxisRoundTrips() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let end = start.addingTimeInterval(8 * 3_600)
        let date = LooprScrubMath.date(x: 150, width: 300, start: start, end: end)
        #expect(date == start.addingTimeInterval(4 * 3_600))
        #expect(LooprScrubMath.x(for: date, width: 300, start: start, end: end) == 150)
        #expect(LooprScrubMath.x(for: end.addingTimeInterval(600), width: 300, start: start, end: end) == 300)
        #expect(LooprScrubMath.date(x: 10, width: 300, start: start, end: start) == start)
    }

    @Test func readoutLabelStaysInsideTheChart() {
        #expect(LooprScrubMath.readoutCenter(x: 5, labelWidth: 80, containerWidth: 300) == 40)
        #expect(LooprScrubMath.readoutCenter(x: 150, labelWidth: 80, containerWidth: 300) == 150)
        #expect(LooprScrubMath.readoutCenter(x: 298, labelWidth: 80, containerWidth: 300) == 260)
        #expect(LooprScrubMath.readoutCenter(x: 10, labelWidth: 400, containerWidth: 300) == 150)
    }

    @Test func holdIsAQuarterSecond() {
        #expect(LooprScrub.holdDuration == 0.25)
    }
}

struct StageTimelineModelTests {
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let start = Date(timeIntervalSince1970: 1_700_000_000 - 30_480)

    private var model: LooprStageTimelineModel {
        LooprStageTimelineModel(spans: LooprStageSpan.spans(from: LooprSampleNight.segments, start: start), timeZone: utc)
    }

    @Test func segmentsLayEndToEnd() {
        let spans = model.spans
        #expect(spans.first?.start == start)
        for (previous, next) in zip(spans, spans.dropFirst()) {
            #expect(previous.end == next.start)
        }
        #expect(model.end == start.addingTimeInterval(Double(LooprSampleNight.timeInBedMinutes) * 60))
    }

    @Test func totalsMatchTheSampleNight() {
        let totals = model.totals
        #expect(totals[.deep] == 82)
        #expect(totals[.rem] == 96)
        #expect(totals[.light] == 284)
        #expect(totals[.awake] == 46)
        #expect(model.asleepMinutes == 462)
        #expect(LooprSampleNight.asleepMinutes == 462)
    }

    @Test func spanUnderAMomentAndItsReadout() {
        let first = model.spans[0]
        #expect(model.span(at: first.start.addingTimeInterval(60))?.id == first.id)
        #expect(model.span(at: start.addingTimeInterval(-60)) == nil)
        let deep = model.spans.first { $0.stage == .deep }!
        let text = model.readout(for: deep)
        #expect(text.hasSuffix("· Deep · 38 min"))
        #expect(text.contains(" to "))
    }

    @Test func highlightSummaryGivesTotalAndShare() {
        #expect(model.highlightSummary(for: .deep) == "Deep · 1 h 22 m · 18% of sleep")
        #expect(model.highlightSummary(for: .awake) == "Awake · 46 min · 9% of time in bed")
    }

    @Test func hourTicksStayOnWholeHoursAwayFromTheEnds() {
        let ticks = model.hourTicks(calendar: Calendar(identifier: .gregorian))
        #expect(!ticks.isEmpty)
        #expect(ticks.count <= 3)
        for tick in ticks {
            #expect(Int(tick.timeIntervalSince1970) % 3_600 == 0)
            #expect(tick > model.start!.addingTimeInterval(3_600))
            #expect(tick < model.end!.addingTimeInterval(-3_600))
        }
    }

    @Test func emptyNightHasAnHonestSummary() {
        let empty = LooprStageTimelineModel(spans: [])
        #expect(empty.accessibilitySummary == "No sleep stages for this night")
        #expect(empty.hourTicks().isEmpty)
    }

    @Test func spokenSummaryListsEveryStage() {
        let summary = model.accessibilitySummary
        #expect(summary.contains("Deep 1 hour 22 minutes"))
        #expect(summary.contains("Awake 46 minutes"))
    }
}

@MainActor
struct BarModelTests {
    @Test func divergingScaleUsesTheLargestMagnitudeOrTheMinimum() {
        let day = Date(timeIntervalSince1970: 0)
        let bars = [LooprDailyBar(date: day, value: -30), LooprDailyBar(date: day.addingTimeInterval(86_400), value: 12),
                    LooprDailyBar(date: day.addingTimeInterval(172_800), value: nil)]
        let model = LooprDivergingBarsModel(bars: bars)
        #expect(model.extent == 30)
        #expect(model.share(of: -30) == -1)
        #expect(model.share(of: 12) == 0.4)
        #expect(model.total == -18)
        #expect(model.measured.count == 2)
        #expect(LooprDivergingBarsModel(bars: bars, minimumSpan: 60).extent == 60)
    }

    @Test func nonFiniteReadingsBecomeGaps() {
        #expect(LooprDailyBar(date: Date(), value: .nan).value == nil)
        #expect(LooprPairedBarDay(date: Date(), first: .infinity, second: 4).first == nil)
    }

    @Test func pairedSeriesKeepTheirOwnScales() {
        #expect(LooprBarSeriesStyle.strain.share(of: 10.5) == 0.5)
        #expect(LooprBarSeriesStyle.recovery.share(of: 50) == 0.5)
        #expect(LooprBarSeriesStyle.recovery.share(of: 140) == 1)
        #expect(LooprBarSeriesStyle.recovery.token(for: 80) == .recoveryHigh)
        #expect(LooprBarSeriesStyle.recovery.token(for: 20) == .recoveryLow)
        #expect(LooprBarSeriesStyle.strain.token(for: 20) == .inkSecondary)
    }

    @Test func impactsScaleToTheLargestMover() {
        let scaled = LooprContributorImpact.scaled([6, -3, nil, 1.5])
        #expect(scaled[0] == 1)
        #expect(scaled[1] == -0.5)
        #expect(scaled[2] == nil)
        #expect(scaled[3] == 0.25)
        #expect(LooprContributorImpact.scaled([0, 0]) == [0, 0])
        #expect(LooprContributorImpact(share: 3).share == 1)
        #expect(LooprContributorImpact(share: 0.8).spokenText == "raises the score a lot")
        #expect(LooprContributorImpact(share: -0.2).spokenText == "lowers the score a little")
    }

    @Test func contributorRowSpeaksValueDeltaAndImpact() {
        let band = LooprBaselineBand(center: 51, lower: 47, upper: 55, measuredDays: 28)
        let row = LooprContributorRow(title: "HRV", value: "58", unit: "ms",
                                      delta: .compare(58, usual: band, higherIsBetter: true, unit: "ms"),
                                      impact: LooprContributorImpact(share: 0.9), accent: .recovery)
        #expect(row.accessibilitySummary == "HRV, 58 milliseconds, 7 milliseconds above your usual, raises the score a lot")
        let absent = LooprContributorRow(title: "Sleep", value: nil, accent: .recovery)
        #expect(absent.accessibilitySummary == "Sleep, No reading")
    }

    @Test func contributorComparisonReplacesDeltaAndStaysMissingWithoutAValue() {
        let row = LooprContributorRow(title: "Skin temperature", value: "+0.2", unit: "°C",
            delta: .init(kind: .change(0.2), unit: "°C", format: .number(digits: 1)),
            comparison: "+0.2 °C vs usual", accent: .heart)
        #expect(row.accessibilitySummary == "Skin temperature, +0.2 degrees Celsius, +0.2 °C vs usual")
        let same = LooprContributorRow(title: "Resting heart rate", value: "54", unit: "bpm",
            comparison: "Same as usual", accent: .heart)
        #expect(same.accessibilitySummary == "Resting heart rate, 54 beats per minute, Same as usual")
        let absent = LooprContributorRow(title: "Skin temperature", value: nil, comparison: "+0.2 °C vs usual", accent: .heart)
        #expect(absent.accessibilitySummary == "Skin temperature, No reading")
    }
}

struct FixtureMetricsTests {
    private let end = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func historyEndsOnTheFixtureDayValue() {
        for id in LooprMetricLinkID.all where !LooprFixtureMetrics.emptyIDs.contains(id) {
            let history = LooprFixtureMetrics.history(id, days: 60, endingOn: end)
            #expect(history.last.map { Calendar.current.isDate($0.date, inSameDayAs: end) } == true, "\(id)")
            #expect(history.last?.value == LooprFixtureMetrics.today(id), "\(id)")
        }
    }

    @Test func aDayHasTheSameValueWhateverLengthIsAskedFor() {
        for id in [LooprMetricLinkID.rmssd, LooprMetricLinkID.sleepDuration, LooprMetricLinkID.steps] {
            let short = LooprFixtureMetrics.history(id, days: 30, endingOn: end)
            let long = LooprFixtureMetrics.history(id, days: 400, endingOn: end)
            #expect(Array(long.suffix(short.count)) == short, "\(id)")
        }
    }

    @Test func everyMetricHasAUsualRangeAndTheStoryHolds() {
        func position(_ id: String) -> LooprBaselineBand.Position? {
            let history = LooprFixtureMetrics.history(id, days: 60, endingOn: end)
            guard let today = LooprFixtureMetrics.today(id),
                  let band = LooprBaselineBand.trailing(history, before: end) else { return nil }
            return band.position(of: today)
        }
        for id in LooprMetricLinkID.all where !LooprFixtureMetrics.emptyIDs.contains(id) {
            let history = LooprFixtureMetrics.history(id, days: 60, endingOn: end)
            #expect(LooprBaselineBand.trailing(history, before: end) != nil, "\(id) needs a usual range")
        }
        #expect(position(LooprMetricLinkID.rmssd) == .above)
        #expect(position(LooprMetricLinkID.restingHeartRate) == .below)
        #expect(position(LooprMetricLinkID.respiratoryRate) == .within)
        #expect(position(LooprMetricLinkID.sleepDuration) == .within)
    }

    @Test func heartMetricsDoNotShareOneNumber() {
        let ids = [LooprMetricLinkID.restingHeartRate, LooprMetricLinkID.rmssd, LooprMetricLinkID.sdnn,
                   LooprMetricLinkID.pNN50, LooprMetricLinkID.respiratoryRate]
        let values = ids.compactMap(LooprFixtureMetrics.today)
        #expect(values.count == ids.count)
        #expect(Set(values).count == values.count)
    }

    @Test func metricsLooprDoesNotCalculateStayEmpty() {
        #expect(LooprFixtureMetrics.history(LooprMetricLinkID.heartRateDip, days: 60, endingOn: end).isEmpty)
        #expect(LooprFixtureMetrics.today(LooprMetricLinkID.maxHeartRate) == nil)
    }

    @Test func recoveryIsInTheHighBandAndSleepBeatsNeed() {
        #expect(LooprRecoveryBand(score: LooprFixtureMetrics.today(LooprMetricLinkID.recovery)) == .high)
        #expect((LooprFixtureMetrics.today(LooprMetricLinkID.sleepDuration) ?? 0) > LooprFixtureMetrics.sleepNeedMinutes)
    }

    @Test func ledgerAndWeekDeriveFromTheSameHistory() {
        let ledger = LooprSampleNight.debtLedger(endingOn: end)
        #expect(ledger.count == 14)
        #expect(ledger.last?.value == (LooprFixtureMetrics.today(LooprMetricLinkID.sleepDuration) ?? 0) - LooprFixtureMetrics.sleepNeedMinutes)
        let week = LooprSampleNight.strainRecoveryWeek(endingOn: end)
        #expect(week.count == 7)
        #expect(week.last?.second == LooprFixtureMetrics.today(LooprMetricLinkID.recovery))
    }
}
