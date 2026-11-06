import DomainKit
import Foundation
import JournalKit
import RoutineKit
import Testing

/// LV-07.3: the call text and the rows in every state: running under the minimum, running with enough nights, a
/// finished Clear or Strong result, No change, stopped early, no baseline and no experiment at all.
struct ProtocolExperimentCallTests {
    @Test func runningBelowTheMinimumSaysTooEarlyAndTheNightsStillNeeded() throws {
        let item = try ProtocolExperimentTestData.running()
        let call = ProtocolExperimentCall.make(item)
        #expect(call.lead == "Too early to say.")
        #expect(call.sentence == "Magnesium nights are 6 minutes ahead, inside your usual night-to-night spread of 9. Loopr shows a result after night 14, and only if it clears that spread.")
        #expect(call.stillNeeded == "So far 4 magnesium nights and 4 other nights count. Each side needs 7.")
        #expect(call.text.hasPrefix("Too early to say. Magnesium nights are 6 minutes ahead"))

        let presentation = ProtocolExperimentPresentation.make(item)
        #expect(presentation.progress == "Running \u{00B7} night 9 of 14")
        #expect(presentation.chip == "Running")
        // ICP R1-NEW-12, R1-SEN-19: the verdict first, then what the strip measures and who started it.
        #expect(presentation.verdict == "Too early to say. Night 9 of 14.")
        #expect(presentation.measuresLine == "Minutes of deep sleep")
        #expect(presentation.startedLine == "You started this on Mon 6 Nov.")
        #expect(presentation.rangeLine == nil, "No range while running")
        // The statistics wait behind How this works, in reading order, with the spread's statistic named.
        #expect(presentation.howItWorks.count == 5)
        #expect(presentation.howItWorks[0] == call.sentence && presentation.howItWorks[1] == call.stillNeeded)
        #expect(presentation.howItWorks[2] == ExperimentCopy.spreadExplanation(spread: 9, unit: "min"))
        #expect(presentation.howItWorks[3] == ExperimentCopy.outcomeFixed(.deepSleep))
        #expect(presentation.howItWorks[4] == "Alternating days in a fixed order, not random, decided before night 1.")
        #expect(presentation.effect == nil, "No hero number while running")
        #expect(presentation.alsoMoved == nil)
        #expect(!presentation.canKeep && !presentation.isKept)
    }

    @Test func runningWithEnoughNightsNeedsNoCount() throws {
        let call = ProtocolExperimentCall.make(try ProtocolExperimentTestData.running(minimum: 3))
        #expect(call.lead == "Too early to say.")
        #expect(call.stillNeeded == nil)
    }

    @Test func aFinishedResultClaimsADifferenceWithItsRange() throws {
        let item = try ProtocolExperimentTestData.finished(canKeep: true)
        let presentation = ProtocolExperimentPresentation.make(item)
        #expect(presentation.chip == "Strong" && presentation.claimsDifference)
        #expect(presentation.call.lead == nil && presentation.call.stillNeeded == nil)
        #expect(presentation.call.sentence.hasPrefix("Deep sleep was 20 minutes higher on magnesium nights than on the other nights."))
        #expect(presentation.call.sentence.contains("and the whole range sits outside your usual spread"))
        #expect(!presentation.call.sentence.contains("caused"))
        #expect(presentation.resultHeader == "Experiment finished \u{00B7} 14 nights")
        #expect(presentation.effect == 20)
        // ICP R1-VET-11: the row and the result page carry the range and the nights on each side.
        let range = try #require(item.report.range)
        let likely = "95% range \(ExperimentCopy.signed(range.lowerBound)) to \(ExperimentCopy.signed(range.upperBound))"
        #expect(presentation.rowSubtitle == "Deep sleep +20 min, \(likely) \u{00B7} 7 nights each")
        #expect(presentation.rangeLine == "\(likely) min \u{00B7} 7 nights each")
        // ICP R2-SEN-13: the result page leads with the change in words, and the call under the number does not
        // repeat it.
        #expect(presentation.headline == "Deep sleep was 20 minutes higher on magnesium nights than on the other nights.")
        #expect(presentation.resultCall.sentence.hasPrefix("The 95% range is "))
        #expect(presentation.resultCall.sentence.hasSuffix(ExperimentCopy.footnote))
        #expect(presentation.howItWorks.contains(ExperimentCopy.rangeExplanation()))
        #expect(presentation.designLine == "Alternating days in a fixed order, not random, decided before night 1")
        #expect(presentation.outcomeLine == "Deep sleep, fixed on day 1")
        #expect(presentation.alsoMoved == [], "Checked, and nothing else moved")
        #expect(presentation.canKeep)
    }

    @Test func aKeptResultSaysKeptAndOffersNoSecondKeep() throws {
        let presentation = ProtocolExperimentPresentation.make(try ProtocolExperimentTestData.finished(keptVersion: 8, canKeep: true))
        #expect(presentation.rowSubtitle.hasSuffix(" \u{00B7} kept"))
        #expect(presentation.isKept && presentation.keptVersion == 8)
        #expect(!presentation.canKeep)
        #expect(ProtocolExperimentText.kept(version: 8) == "Kept in version 8")
    }

    @Test func noChangeSaysTheRangeSitsInsideTheSpread() throws {
        let presentation = ProtocolExperimentPresentation.make(
            try ProtocolExperimentTestData.finished(on: ProtocolExperimentTestData.sameOn, off: ProtocolExperimentTestData.sameOff))
        #expect(presentation.chip == "No change" && !presentation.claimsDifference)
        #expect(presentation.call.sentence.hasPrefix("Deep sleep looked about the same on magnesium nights and the other nights."))
        #expect(presentation.call.sentence.contains("inside your usual spread of 5"))
        #expect(presentation.rowSubtitle.hasPrefix("Deep sleep ") && presentation.rowSubtitle.hasSuffix(" \u{00B7} 7 nights each"))
    }

    @Test func stoppedEarlySaysSoAndClaimsNothing() throws {
        let item = try ProtocolExperimentTestData.finished(status: .stopped, endNight: 6)
        #expect(item.experiment.stoppedEarly)
        let presentation = ProtocolExperimentPresentation.make(item)
        #expect(presentation.call.text == "You stopped this one after 6 of 14 nights, so Loopr does not claim a result.")
        #expect(presentation.chip == "Stopped" && !presentation.claimsDifference)
        #expect(presentation.effect == nil && presentation.alsoMoved == nil)
        #expect(presentation.rowSubtitle == "Stopped \u{00B7} 6 nights")
        #expect(presentation.resultHeader == "Experiment stopped \u{00B7} 6 nights")
        #expect(!presentation.canKeep)
    }

    @Test func withoutABaselineLooprSaysItCannotShowAResult() throws {
        let startDay = ProtocolExperimentTestData.day(11, 6)
        let experiment = Experiment(start: try ProtocolExperimentTestData.start(startDay: startDay, planned: 14, minimum: 7))
        let item = ProtocolExperimentTestData.item(
            experiment, nights: try ProtocolExperimentTestData.nights(experiment, on: [86, 81, 90, 79], off: [76, 82, 74, 80]),
            baseline: [:])
        let call = ProtocolExperimentCall.make(item)
        #expect(call.lead == nil && call.stillNeeded == nil)
        #expect(call.sentence.hasPrefix("Loopr cannot show a result for this one."))
    }

    @Test func theSegmentsOwnSentencesArePlain() {
        // ICP R1-VET-19: the pattern is named by what it links, not "Test alcohol on purpose".
        #expect(ProtocolExperimentText.fromPattern(title: "Alcohol", outcome: "HRV") == "Alcohol and HRV")
        #expect(ProtocolExperimentText.fromPattern(title: "late dinner", outcome: "Deep sleep") == "Late dinner and deep sleep")
        #expect(ProtocolExperimentText.fromPattern(title: "Leg day", outcome: nil) == "Leg day")
        #expect(ProtocolExperimentText.fromPattern(title: "  ", outcome: "HRV") == ProtocolExperimentText.noPattern)
        #expect(ProtocolExperimentText.resultHeader("Finished \u{00B7} 28 nights") == "Experiment finished \u{00B7} 28 nights")
        #expect(ProtocolExperimentText.stillNeeded(on: 1, off: 0, minimum: 7, interventionName: "Magnesium")
            == "So far 1 magnesium night and 0 other nights count. Each side needs 7.")
        let sentences = [ProtocolExperimentText.noExperiment, ProtocolExperimentText.noneRunning, ProtocolExperimentText.unavailable,
                         ProtocolExperimentText.notKeepable, ProtocolExperimentText.nothingElseMoved, ProtocolExperimentText.notChecked,
                         ProtocolExperimentText.noPattern, ProtocolExperimentText.stopped(nights: 6, planned: 14),
                         ProtocolExperimentText.intro, ProtocolExperimentText.fromGitHubDetail, ProtocolExperimentText.hrvGloss,
                         ProtocolExperimentText.measures(.hrv), ProtocolExperimentText.measures(.sleepHeartRate)]
        for sentence in sentences {
            #expect(!sentence.contains("!") && !sentence.contains("\u{2014}") && !sentence.contains("caused"), "\(sentence)")
            #expect(!sentence.contains("(") && !sentence.contains("Strong pattern"), "\(sentence)")
        }
    }

    // MARK: ICP round 1 copy rules

    @Test func theStripSaysWhatItMeasuresAndHRVGetsItsGloss() {
        #expect(ProtocolExperimentText.measures(.timeToFallAsleep) == "Minutes to fall asleep")
        #expect(ProtocolExperimentText.measures(.hrv) == "HRV in milliseconds. HRV is heart rate variability, a sign of recovery.")
        #expect(ProtocolExperimentText.mentionsHRV("Alcohol and HRV") && ProtocolExperimentText.mentionsHRV("HRV."))
        #expect(!ProtocolExperimentText.mentionsHRV("SHRVE") && !ProtocolExperimentText.mentionsHRV("Deep sleep"))
    }

    @Test func aRangeWiderThanTheSpreadIsNoClearChangeAndClaimsNothing() throws {
        // A level difference with noisy on nights: the range reaches past the spread on both sides.
        let item = try ProtocolExperimentTestData.finished(on: [40, 80, 45, 78, 42, 79, 61], off: ProtocolExperimentTestData.sameOff)
        guard item.report.state == .notCalled else { return }
        let presentation = ProtocolExperimentPresentation.make(item)
        #expect(presentation.chip == "No clear change" && !presentation.claimsDifference)
        #expect(presentation.rowSubtitle.contains(", 95% range "))
    }

    @Test func clearIsOnlyEverShownWithTheWholeRangeOutsideTheSpread() throws {
        for item in [try ProtocolExperimentTestData.finished(),
                     try ProtocolExperimentTestData.finished(on: ProtocolExperimentTestData.sameOn, off: ProtocolExperimentTestData.sameOff)] {
            let presentation = ProtocolExperimentPresentation.make(item)
            if presentation.claimsDifference {
                #expect(item.report.rangeOutsideSpread, "\(presentation.chip) without the range outside the spread")
            }
        }
    }

    @Test func theStartDateIsWrittenTheSameInEveryLocale() {
        #expect(ProtocolExperimentText.started(ProtocolExperimentTestData.day(11, 6)) == "You started this on Mon 6 Nov.")
        #expect(ProtocolExperimentText.started(DayIdentity(year: 2024, month: 2, day: 29)) == "You started this on Thu 29 Feb.")
    }
}
