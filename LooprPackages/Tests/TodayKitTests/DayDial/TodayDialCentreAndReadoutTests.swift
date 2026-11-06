import DesignSystem
import DomainKit
import Foundation
import Testing
@testable import TodayKit

/// The centre in both modes, the countdown across daylight saving, the readouts with their sources and the render
/// states.
struct TodayDialCentreAndReadoutTests {
    typealias F = DialFixture

    // MARK: Centre

    @Test
    func theMorningCentreIsLastNightAsleepWithTheOnTimeStreak() throws {
        var inputs = F.inputs()
        inputs.lastNight = F.night()
        // Eight late nights, then six within half an hour of the protocol's 22:30 (630 minutes after noon).
        inputs.recentNights = F.nights(beds: Array(repeating: 700, count: 8) + [625, 640, 630, 610, 655, 630])
        inputs.rules = [F.inBedRule]
        guard case .asleep(let asleep) = F.model(inputs).centre else {
            Issue.record("Expected the asleep centre")
            return
        }
        #expect(asleep.text == "7 h 48 m")
        #expect(asleep.hours == 7 && asleep.minutePart == 48)
        #expect(asleep.onTimeNights == 6)
        #expect(asleep.caption == "asleep · on time 6 nights running")
        #expect(asleep.provenance == .band(device: "WHOOP 4.0"))
    }

    @Test
    func withoutARuleTheMedianBedtimeIsTheReference() {
        let nights = F.nights(beds: [630, 640, 620, 635, 700, 630])
        #expect(TodayDialReadoutRules.onTimeNights(nights, ruleBedMinuteAfterNoon: nil) == 1)
        #expect(TodayDialReadoutRules.onTimeNights(F.nights(beds: [630, 640, 620, 635, 630, 900]), ruleBedMinuteAfterNoon: nil) == 0)
        // A night with no main sleep breaks the streak.
        #expect(TodayDialReadoutRules.onTimeNights(F.nights(beds: [630, 640, nil, 620, 635, 630]), ruleBedMinuteAfterNoon: 630) == 3)
    }

    @Test
    func theRegularityLineWaitsForFiveNights() {
        var inputs = F.inputs()
        inputs.lastNight = F.night()
        inputs.recentNights = F.nights(beds: [630, 635, 625, 630])
        guard case .asleep(let asleep) = F.model(inputs).centre else {
            Issue.record("Expected the asleep centre")
            return
        }
        #expect(asleep.onTimeNights == nil)
        #expect(asleep.caption == "asleep")
    }

    @Test
    func noNightMeansAnAbsentMorningCentre() {
        #expect(F.model(F.inputs()).centre == .absent(TodayDialAbsence(gap: .noData, message: "No sleep recorded for last night")))
    }

    @Test
    func theEveningCentreCountsDownToBed() {
        var inputs = F.inputs(now: F.date(F.day, 19, 49))
        inputs.rules = [F.inBedRule]
        guard case .countdown(let countdown) = F.model(inputs).centre else {
            Issue.record("Expected the countdown")
            return
        }
        #expect(countdown.text == "2:41")
        #expect(countdown.caption == "until bed at 22:30")
        #expect(countdown.remaining == 161 * 60)
        #expect(!countdown.isPastBedtime)
        #expect(countdown.qualifier == "Your protocol")
        #expect(countdown.provenance == .onThisPhone)

        inputs.now = F.date(F.day, 22, 50)
        guard case .countdown(let late) = F.model(inputs).centre else {
            Issue.record("Expected the countdown")
            return
        }
        #expect(late.isPastBedtime)
        #expect(late.text == "0:20")
        #expect(late.caption == "past bed at 22:30")
    }

    @Test
    func theProtocolBedtimeWinsOverSleepsPlan() throws {
        var inputs = F.inputs(now: F.date(F.day, 20))
        inputs.tonight = TodayDialTonightInput(bedtimeMinuteOfDay: 1_385, wakeMinuteOfDay: 420, sleepMinutes: 455)
        inputs.rules = [F.inBedRule]
        #expect(try #require(F.model(inputs).bedtime).at == F.date(F.day, 22, 30))
    }

    @Test
    func aBedtimeAfterMidnightCountsDownToTomorrow() {
        var inputs = F.inputs(now: F.date(F.day, 22))
        inputs.tonight = TodayDialTonightInput(bedtimeMinuteOfDay: 30, wakeMinuteOfDay: 480, sleepMinutes: 450)
        guard case .countdown(let countdown) = F.model(inputs).centre else {
            Issue.record("Expected the countdown")
            return
        }
        #expect(countdown.bedtime == F.date(F.shifted(F.day, by: 1), 0, 30))
        #expect(countdown.text == "2:30")
    }

    @Test
    func theCountdownIsRealTimeAcrossTheClockChange() {
        // The night of 24 to 25 October: clocks go back at 03:00. 22:00 to 03:30 is 5 h 30 m on the wall and 6 h 30 m real.
        let evening = DayIdentity(year: 2026, month: 10, day: 24)
        var inputs = F.inputs(day: evening, now: F.date(evening, 22))
        inputs.rules = [TodayDialRuleInput(key: "in-bed", title: "In bed", metric: "in_bed_time", targetValue: 210, state: .pending)]
        guard case .countdown(let autumn) = F.model(inputs).centre else {
            Issue.record("Expected the countdown")
            return
        }
        #expect(autumn.text == "6:30")

        // 28 to 29 March: clocks go forward at 02:00. 23:00 to 03:30 is 3 h 30 m real.
        let spring = DayIdentity(year: 2026, month: 3, day: 28)
        var forward = F.inputs(day: spring, now: F.date(spring, 23))
        forward.rules = inputs.rules
        guard case .countdown(let shorter) = F.model(forward).centre else {
            Issue.record("Expected the countdown")
            return
        }
        #expect(shorter.text == "3:30")
    }

    @Test
    func noBedtimeMeansAnAbsentEveningCentre() {
        #expect(F.model(F.inputs(now: F.date(F.day, 20))).centre
            == .absent(TodayDialAbsence(gap: .noData, message: "No bedtime set for tonight")))
    }

    // MARK: Morning readouts

    @Test
    func sleepHeartRateComparesWithTheUsualOfEarlierNights() throws {
        var inputs = F.inputs()
        inputs.sleepHeartRate = .value(49, .band(device: "WHOOP 4.0"))
        inputs.sleepHeartRateBefore = [53, 53, 52, 54, 53, 53]
        let readout = try #require(F.model(inputs).readouts.first)
        #expect(readout.id == .sleepHeartRate)
        #expect(readout.title == "Sleep heart rate")
        #expect(readout.text == "49" && readout.number == 49)
        #expect(readout.caption == "4 under usual")
        #expect(readout.tone == .good)
        #expect(readout.status == .measured)
        #expect(readout.provenance == .band(device: "WHOOP 4.0"))

        inputs.sleepHeartRate = .value(56, .band(device: ""))
        #expect(F.model(inputs).readouts.first?.caption == "3 over usual")
        #expect(F.model(inputs).readouts.first?.tone == .neutral)

        inputs.sleepHeartRateBefore = [52, 53]
        let learning = try #require(F.model(inputs).readouts.first)
        #expect(learning.status == .learning(have: 3, need: 5))
        #expect(learning.text == "56")
        #expect(learning.caption == "usual after 5 nights")
    }

    @Test
    func aMissingReadoutIsAbsentWithItsReasonAndNoSource() {
        var inputs = F.inputs()
        inputs.sleepHeartRate = .missing(.noData)
        let readout = F.model(inputs).readouts[0]
        #expect(readout.status == .absent(.noData))
        #expect(readout.text == nil && readout.number == nil)
        #expect(readout.caption == "not measured")
        #expect(readout.provenance == .absent)
        #expect(TodayDialReading.value(.nan, .onThisPhone).value == nil)
        #expect(TodayDialReading.value(.nan, .onThisPhone).gap == .noData)
    }

    @Test
    func regularityShowsItsScoreOrWaitsForNights() {
        var inputs = F.inputs()
        inputs.regularity = .value(91, .band(device: ""))
        let scored = F.model(inputs).readouts[1]
        #expect(scored.text == "91" && scored.caption == "of 100")

        inputs.regularity = .missing(.noData)
        inputs.lastNight = F.night()
        inputs.recentNights = F.nights(beds: [630, 640])
        let learning = F.model(inputs).readouts[1]
        #expect(learning.status == .learning(have: 2, need: 5))
        #expect(learning.caption == "after 5 nights")
        #expect(learning.text == nil)
    }

    @Test
    func recoveryReadsFromTodaysHeroAndOpensWhatShapedIt() {
        let reading = TodayRecoveryReading(score: 78, band: .high, driver: "HRV is 12% above your usual.", guidance: nil)
        func recovery(_ hero: TodayHeroState?) -> TodayDialReadout {
            var inputs = F.inputs()
            inputs.recovery = hero
            return F.model(inputs).readouts[2]
        }
        let scored = recovery(.scored(reading))
        #expect(scored.text == "78" && scored.caption == "ready")
        #expect(scored.tone == .recovery(.high))
        #expect(scored.opensWhatShapedIt)
        #expect(scored.provenance == .onThisPhone)

        let early = TodayRecoveryReading(score: 40, band: .middle, driver: "", guidance: nil, earlyEstimate: "Early estimate")
        #expect(recovery(.scored(early)).caption == "early estimate")
        #expect(recovery(.carried(reading, dayLabel: "Wed 21 Oct", reason: "")).caption == "from Wed 21 Oct")

        let learning = recovery(.learning(have: 3, need: 14, detail: ""))
        #expect(learning.status == .learning(have: 3, need: 14))
        #expect(learning.caption == "3 of 14 nights")
        #expect(learning.text == nil)

        let none = recovery(nil)
        #expect(none.status == .absent(.noData) && none.caption == "no score" && none.text == nil)
        #expect(recovery(.calculating(title: "", detail: "")).caption == "not in yet")
    }

    // MARK: Evening readouts

    @Test
    func theEveningReadoutsAreLastMealZone2AndSteps() {
        var inputs = F.inputs(now: F.date(F.day, 19, 49))
        inputs.meals = [F.meal("berries", F.date(F.day, 7, 5)), F.meal("dinner", F.date(F.day, 18, 20))]
        var kitchen = F.kitchenRule
        kitchen.state = .kept
        inputs.rules = [F.inBedRule, kitchen, F.zone2Rule]
        inputs.zone2Minutes = .value(48, .band(device: ""))
        inputs.steps = .value(9_812, .appleHealth(source: "iPhone"))
        let readouts = F.model(inputs).readouts
        #expect(readouts.map(\.id) == [.lastMeal, .zone2, .steps])

        #expect(readouts[0].text == "18:20")
        #expect(readouts[0].caption == "4 h 10 m to bed")
        #expect(readouts[0].tone == .good)
        #expect(readouts[0].provenance == .food(.photoEstimate))

        #expect(readouts[1].text == "48" && readouts[1].caption == "of 45 min" && readouts[1].tone == .good)

        #expect(readouts[2].text == "9,812" && readouts[2].caption == "today")
        #expect(readouts[2].provenance == .appleHealth(source: "iPhone"))
    }

    @Test
    func eveningReadoutsWithoutDataSayWhy() {
        var inputs = F.inputs(now: F.date(F.day, 20))
        inputs.steps = .missing(.switchedOff)
        inputs.zone2Minutes = .value(20, .band(device: ""))
        let readouts = F.model(inputs).readouts
        #expect(readouts[0].caption == "none logged" && readouts[0].status == .absent(.noData))
        #expect(readouts[1].caption == "min today" && readouts[1].tone == .neutral)
        #expect(readouts[2].caption == "off in Settings" && readouts[2].status == .absent(.switchedOff))
    }

    // MARK: Render states

    @Test
    func aDialWithNothingRecordedIsTheFirstDayDial() {
        let model = F.model(F.inputs())
        #expect(model.render.kind == .empty)
        #expect(model.render.message == "Nothing recorded yet. Sleep, meals, training and daylight land on this dial as they come in.")
        #expect(model.render.absentLayers == TodayDialLayerID.allCases)
    }

    @Test
    func fewerThanFiveNightsIsLearning() {
        var inputs = F.inputs()
        inputs.lastNight = F.night()
        inputs.recentNights = F.nights(beds: [nil, 630, 640])
        let model = F.model(inputs)
        #expect(model.render.kind == .learning)
        #expect(model.render.nightsMeasured == 2)
        #expect(model.render.message == "Your usual and regularity show after 5 nights. 2 so far.")

        var first = F.inputs()
        first.meals = [F.meal("berries", F.date(F.day, 7, 5))]
        #expect(F.model(first).render.kind == .learning)
        #expect(F.model(first).render.message == "Your usual and regularity show after 5 nights. None yet.")
    }

    @Test
    func someLayersMissingIsPartialAndAllPresentIsComplete() {
        var inputs = F.inputs()
        inputs.lastNight = F.night()
        inputs.recentNights = F.nights(beds: Array(repeating: 630, count: 14))
        inputs.meals = [F.meal("berries", F.date(F.day, 7, 5))]
        inputs.rules = [F.zone2Rule]
        let partial = F.model(inputs)
        #expect(partial.render.kind == .partial)
        #expect(partial.render.absentLayers == [.daylight])
        #expect(partial.render.message == nil)

        inputs.daylight = .dailyTotal(minutes: 12, provenance: .appleHealth(source: ""))
        let complete = F.model(inputs)
        #expect(complete.render.kind == .complete)
        #expect(complete.render.absentLayers.isEmpty)
    }

    @Test
    func theSummaryReadsTheDialInOrder() {
        var inputs = F.inputs(now: F.date(F.day, 19, 49))
        inputs.meals = [F.meal("berries", F.date(F.day, 7, 5)), F.meal("dinner", F.date(F.day, 18, 20))]
        inputs.rules = [F.inBedRule, F.screensOffRule]
        inputs.daylight = .dailyTotal(minutes: 45, provenance: .appleHealth(source: ""))
        let summary = F.model(inputs).accessibilitySummary
        #expect(summary.hasPrefix("Day dial, evening. 2 hours 41 minutes until bed at 22:30."))
        #expect(summary.contains("2 meals, from 07:05 to 18:20."))
        #expect(summary.contains("No training logged today."))
        #expect(summary.contains("45 minutes in daylight."))
        #expect(summary.contains("1 timed rule, 0 kept."))
    }

    /// ICP R2-UPG-14: the evening's last meal sets its day period small beside the time, so "12:30 PM" never breaks.
    @Test @MainActor
    func aClockReadoutSplitsItsDayPeriodFromTheTime() {
        let us = LooprClockFormat.text(minuteOfDay: 12 * 60 + 30, locale: Locale(identifier: "en_US"))
        let parts = TodayDialReadoutCell.clockParts(us)
        #expect(parts.time == "12:30")
        #expect(parts.period?.uppercased() == "PM")
        #expect(TodayDialReadoutCell.clockParts("18:20").time == "18:20")
        #expect(TodayDialReadoutCell.clockParts("18:20").period == nil)
        #expect(TodayDialReadoutCell.clockParts("9,812").period == nil)
    }
}
