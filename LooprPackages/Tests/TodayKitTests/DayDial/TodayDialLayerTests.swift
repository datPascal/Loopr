import DesignSystem
import DomainKit
import Foundation
import Testing
@testable import TodayKit

/// Each layer from stored data, and its designed absence.
struct TodayDialLayerTests {
    typealias F = DialFixture

    // MARK: Sleep

    @Test
    func lastNightIsARadialHypnogramOnTheSleepRing() throws {
        var inputs = F.inputs()
        inputs.lastNight = F.night()
        let model = F.model(inputs)
        guard case .present(.lastNight(let night)) = model.sleep else {
            Issue.record("Expected last night's hypnogram")
            return
        }
        #expect(night.spans.map(\.stage) == [.light, .deep, .rem, .awake, .light])
        #expect(night.spans.allSatisfy { $0.radius == 120 })
        #expect(night.spans.map(\.width) == [13, 22, 16, 5, 13])
        let deep = night.spans[1]
        #expect(deep.innerRadius == 109 && deep.outerRadius == 131)
        // Deep runs 23:00 to 00:00: 15 degrees from 165.
        #expect(F.close(deep.arc.startAngle, 165))
        #expect(F.close(deep.arc.sweep, 15))
        #expect(night.asleepMinutes == 468)
        #expect(night.provenance == .band(device: "WHOOP 4.0"))
    }

    @Test
    func withoutACountedTotalTheSpansGiveTheTimeAsleep() {
        var night = F.night()
        night.asleepMinutes = nil
        var inputs = F.inputs()
        inputs.lastNight = night
        guard case .present(.lastNight(let hypnogram)) = F.model(inputs).sleep else {
            Issue.record("Expected last night's hypnogram")
            return
        }
        #expect(hypnogram.asleepMinutes == 463)
    }

    @Test
    func aPastDayWithoutANightDrawsTheAbsentShapeWithItsSentence() {
        var inputs = F.inputs()
        inputs.now = F.date(F.day, 7, 12, zone: F.berlin).addingTimeInterval(2 * 86_400)
        let model = F.model(inputs)
        #expect(!model.isToday)
        #expect(model.sleep.absence?.message == "The band has no night for this day. It fills in if the band syncs one later.")
        #expect(model.centre == .absent(TodayDialAbsence(gap: .noData, message: "No night recorded")))
        #expect(model.hand == nil)
        #expect(TodayDialNotes.lines(for: model).contains("The band has no night for this day. It fills in if the band syncs one later."))
    }

    @Test
    func aPastDayCountsTheNightsBeforeItAndSaysOnThisDay() {
        var inputs = F.inputs()
        inputs.now = F.date(F.day, 7, 12, zone: F.berlin).addingTimeInterval(2 * 86_400)
        inputs.meals = [F.meal("berries", F.date(F.day, 7, 5))]
        inputs.sleepHeartRateBefore = Array(repeating: 52, count: 26)
        let model = F.model(inputs)
        #expect(model.render.nightsMeasured == 26)
        #expect(model.render.kind != .learning)
        let lines = TodayDialNotes.lines(for: model)
        #expect(!lines.contains { $0.contains("None yet") || $0.contains("so far") })
        #expect(lines.contains("No time in daylight from Apple Health on this day."))
        #expect(lines.contains("No training logged on this day."))
        #expect(!lines.contains { $0.hasSuffix("today.") })

        // A past day without a night and no history before it still makes no claim about nights to come.
        inputs.sleepHeartRateBefore = []
        #expect(F.model(inputs).render.kind != .learning)
        #expect(F.model(inputs).render.message == nil)
    }

    @Test
    func noNightMeansAnAbsentSleepLayerInTheMorning() {
        let model = F.model(F.inputs())
        #expect(model.sleep.absence?.message == "No sleep recorded for last night. It fills in after your next tracked night.")
        #expect(model.render.absentLayers.contains(.sleep))
    }

    @Test
    func tonightsWindowLightsUpInTheEvening() throws {
        var inputs = F.inputs(now: F.date(F.day, 19, 49))
        inputs.lastNight = F.night()
        inputs.rules = [F.inBedRule, F.screensOffRule]
        inputs.alarm = TodayDialAlarmInput(wakeMinuteOfDay: 375, ringsToday: true, ringsTomorrow: true)
        let model = F.model(inputs)
        guard case .present(.tonight(let tonight)) = model.sleep else {
            Issue.record("Expected tonight's window")
            return
        }
        #expect(tonight.bedtime.at == F.date(F.day, 22, 30))
        #expect(tonight.bedtime.source == .rule(key: "in-bed", state: .pending))
        let window = try #require(tonight.window)
        #expect(window.end == F.date(F.shifted(F.day, by: 1), 6, 15))
        #expect(F.close(window.startAngle, 157.5))
        #expect(F.close(window.sweep, 116.25))
        #expect(tonight.wakeSource == .alarm)
        let windDown = try #require(tonight.windDown)
        #expect(windDown.start == F.date(F.day, 21, 45))
        #expect(F.close(windDown.sweep, 11.25))
        #expect(F.close(tonight.labelAngle, 169.5))
    }

    @Test
    func sleepsPlanGivesTheBedtimeWhenTheProtocolHasNone() throws {
        var inputs = F.inputs(now: F.date(F.day, 20))
        inputs.tonight = TodayDialTonightInput(bedtimeMinuteOfDay: 1_385, wakeMinuteOfDay: 420, sleepMinutes: 455)
        let model = F.model(inputs)
        let bedtime = try #require(model.bedtime)
        #expect(bedtime.at == F.date(F.day, 23, 5))
        #expect(bedtime.source == .sleepPlan)
        #expect(bedtime.qualifier == "Sleep plan")
        guard case .present(.tonight(let tonight)) = model.sleep else {
            Issue.record("Expected tonight's window")
            return
        }
        #expect(tonight.window?.end == F.date(F.shifted(F.day, by: 1), 7))
        #expect(tonight.wakeSource == .sleepPlan)
        #expect(tonight.windDown == nil)
    }

    @Test
    func noBedtimeMeansAnAbsentWindowInTheEvening() {
        let model = F.model(F.inputs(now: F.date(F.day, 20)))
        #expect(model.bedtime == nil)
        #expect(model.sleep.absence?.message
            == "No bedtime for tonight yet. Add an in-bed rule, or sleep three nights for a suggested one.")
    }

    // MARK: Eating

    @Test
    func theEatingWindowRunsFirstToLastMealWithStickers() throws {
        var inputs = F.inputs(now: F.date(F.day, 13))
        inputs.meals = [F.meal("salad", F.date(F.day, 12, 40)), F.meal("berries", F.date(F.day, 7, 5)),
                        F.meal("snack", F.date(F.day, 10), sticker: false)]
        inputs.rules = [F.kitchenRule]
        let eating = try #require(F.model(inputs).eating.value)
        #expect(eating.meals.map(\.id) == ["berries", "snack", "salad"])
        #expect(eating.meals.allSatisfy { $0.radius == 96 })
        #expect(eating.meals[0].sticker?.fileName == "berries.jpg")
        #expect(eating.meals[1].sticker == nil)
        #expect(eating.meals[0].provenance == .food(.photoEstimate))
        #expect(F.close(eating.window.startAngle, 286.25))
        #expect(F.close(eating.window.sweep, 83.75))
        // The kitchen closes at its limit, 18:30, not at its 18:00 reminder.
        let planned = try #require(eating.planned)
        #expect(planned.end == F.date(F.day, 18, 30))
        #expect(F.close(planned.sweep, 171.25))
    }

    @Test
    func aMealAfterMidnightSitsAtTheBottomAndOpensTheWindow() throws {
        var inputs = F.inputs(now: F.date(F.day, 9))
        inputs.meals = [F.meal("late", F.date(F.day, 0, 30)), F.meal("breakfast", F.date(F.day, 8)),
                        F.meal("tomorrow", F.date(F.shifted(F.day, by: 1), 0, 30)),
                        F.meal("yesterday", F.date(F.shifted(F.day, by: -1), 23, 50))]
        let eating = try #require(F.model(inputs).eating.value)
        #expect(eating.meals.map(\.id) == ["late", "breakfast"])
        #expect(F.close(eating.meals[0].angle, 187.5))
        #expect(eating.window.start == F.date(F.day, 0, 30))
        #expect(eating.planned == nil)
    }

    @Test
    func noMealsMeansAnAbsentEatingLayer() {
        let model = F.model(F.inputs())
        #expect(model.eating.absence == TodayDialAbsence(gap: .noData, message: "No meals logged today. Log one and it lands on the dial."))
    }

    // MARK: Training

    @Test
    func aTimedTrainingRuleIsAPlannedBlockUntilAWorkoutMeetsIt() throws {
        var inputs = F.inputs()
        inputs.rules = [F.zone2Rule]
        let planned = try #require(F.model(inputs).training.value)
        #expect(planned.count == 1)
        #expect(planned[0].isPlanned)
        #expect(planned[0].ruleState == .pending)
        #expect(F.close(planned[0].arc.startAngle, 82.5))
        #expect(F.close(planned[0].arc.sweep, 11.25))
        #expect(F.model(inputs).beads.isEmpty)

        inputs.now = F.date(F.day, 19, 49)
        inputs.workouts = [TodayDialWorkoutInput(id: "ride", title: "Cycling", start: F.date(F.day, 17, 30), end: F.date(F.day, 18, 18),
                                                 provenance: .band(device: ""))]
        let done = try #require(F.model(inputs).training.value)
        #expect(done.map(\.id) == ["ride"])
        #expect(!done[0].isPlanned)
        #expect(F.close(done[0].arc.sweep, 12))
    }

    @Test
    func aWorkoutAcrossSixIsOneBlockAndTheDialIsInEveningMode() throws {
        var inputs = F.inputs(now: F.date(F.day, 18, 10))
        inputs.workouts = [TodayDialWorkoutInput(id: "run", title: "Running", start: F.date(F.day, 17, 30), end: nil,
                                                 provenance: .band(device: ""))]
        let ongoing = F.model(inputs)
        #expect(ongoing.mode == .evening)
        let block = try #require(ongoing.training.value?.first)
        #expect(block.isOngoing)
        #expect(block.arc.end == F.date(F.day, 18, 10))
        #expect(F.close(block.arc.sweep, 10))

        inputs.now = F.date(F.day, 18, 40)
        inputs.workouts[0].end = F.date(F.day, 18, 30)
        let finished = try #require(F.model(inputs).training.value?.first)
        #expect(!finished.isOngoing)
        #expect(F.close(finished.arc.startAngle, 82.5))
        #expect(F.close(finished.arc.sweep, 15))
    }

    @Test
    func aPlannedSessionWithoutALengthIsAPoint() throws {
        var inputs = F.inputs()
        inputs.plannedSessions = [TodayDialPlannedSessionInput(id: "legs", title: "Legs", startMinuteOfDay: 1_020, durationMinutes: nil)]
        let block = try #require(F.model(inputs).training.value?.first)
        #expect(block.id == "plan-legs")
        #expect(block.isPlanned)
        #expect(block.arc.sweep == 0)
    }

    @Test
    func noTrainingMeansAnAbsentTrainingLayer() {
        #expect(F.model(F.inputs()).training.absence?.message == "No training logged today.")
    }

    // MARK: Daylight

    @Test
    func aDailyTotalIsSpreadAsDotsOverTheDaytimeSoFar() throws {
        var inputs = F.inputs(now: F.date(F.day, 7, 12))
        inputs.daylight = .dailyTotal(minutes: 12, provenance: .appleHealth(source: "Apple Watch"))
        let daylight = try #require(F.model(inputs).daylight.value)
        #expect(daylight.placement == .spreadAcrossDay)
        #expect(daylight.minutes == 12)
        #expect(daylight.dotAngles.count == 3)
        #expect(F.close(daylight.dotAngles[0], 273))
        #expect(F.close(daylight.dotAngles[2], 285))
        #expect(daylight.provenance == .appleHealth(source: "Apple Watch"))

        // A past day spreads over 06:00 to 18:00: 90 minutes are 18 dots, 40 minutes apart.
        var past = F.inputs(now: F.date(F.shifted(F.day, by: 1), 9))
        past.daylight = .dailyTotal(minutes: 90, provenance: .appleHealth(source: ""))
        let spread = try #require(F.model(past).daylight.value)
        #expect(spread.dotAngles.count == 18)
        #expect(F.close(spread.dotAngles[0], 275))
    }

    @Test
    func aMeasuredZeroIsALayerWithNoDotsNotAnAbsence() throws {
        var inputs = F.inputs()
        inputs.daylight = .dailyTotal(minutes: 0, provenance: .appleHealth(source: ""))
        let daylight = try #require(F.model(inputs).daylight.value)
        #expect(daylight.dotAngles.isEmpty)
        #expect(daylight.minutes == 0)
    }

    @Test
    func daylightWithTimesSitsWhereItHappened() throws {
        var inputs = F.inputs(now: F.date(F.day, 7, 12))
        inputs.daylight = .intervals([DateInterval(start: F.date(F.day, 6, 40), end: F.date(F.day, 6, 52)),
                                      DateInterval(start: F.date(F.day, 12), end: F.date(F.day, 12, 30))],
                                     provenance: .appleHealth(source: ""))
        let daylight = try #require(F.model(inputs).daylight.value)
        #expect(daylight.placement == .atTimes)
        // The later interval has not happened yet at 07:12.
        #expect(daylight.dotAngles.count == 9)
        #expect(daylight.minutes == 12)
        #expect(F.close(daylight.dotAngles[0], 280))
    }

    @Test
    func missingDaylightSaysWhy() {
        func message(_ gap: TodayDialGap) -> String? {
            var inputs = F.inputs()
            inputs.daylight = .missing(gap)
            return F.model(inputs).daylight.absence?.message
        }
        #expect(message(.noData) == "No time in daylight from Apple Health today.")
        #expect(message(.switchedOff) == "Time in daylight is switched off in Settings.")
        #expect(message(.notAllowed) == "Allow time in daylight in Apple Health to see it here.")
        #expect(message(.unavailable) == "Time in daylight comes from Apple Health, which this iPhone does not have.")
    }

    // MARK: Beads

    @Test
    func eachTimedRuleIsABeadAtItsTime() throws {
        var inputs = F.inputs()
        var light = TodayDialRuleInput(key: "light", title: "Morning light", metric: "daylight_minutes", timeOfDayMinutes: 420,
                                       targetValue: 10, source: .appleHealth, state: .kept)
        let anytime = TodayDialRuleInput(key: "protein", title: "Protein 130 g", metric: "protein_g", targetValue: 130,
                                         source: .food, state: .pending)
        inputs.rules = [F.screensOffRule, F.kitchenRule, F.inBedRule, F.zone2Rule, light, anytime]
        let beads = F.model(inputs).beads
        #expect(beads.map(\.id) == ["light", "kitchen", "screens-off"])

        let kitchen = beads[1]
        #expect(kitchen.kind == .kitchenCloses)
        #expect(kitchen.minuteOfDay == 1_110)
        #expect(kitchen.radius == 96 && kitchen.size == 4)
        #expect(F.close(kitchen.angle, 97.5))

        let screens = beads[2]
        #expect(screens.kind == .routine)
        #expect(screens.radius == 142 && screens.size == 4.2)
        #expect(F.close(screens.angle, 146.25))
        #expect(screens.isEvening)
        #expect(beads[0].state == .kept)

        light.state = .missed
        inputs.rules = [light]
        #expect(F.model(inputs).beads.first?.state == .missed)
    }

    @Test
    func theInBedRuleBecomesTheBedtimeGem() throws {
        var inputs = F.inputs()
        inputs.rules = [F.inBedRule]
        let model = F.model(inputs)
        #expect(model.beads.isEmpty)
        let bedtime = try #require(model.bedtime)
        #expect(F.close(bedtime.angle, 157.5))
        #expect(bedtime.qualifier == "Your protocol")
        #expect(TodayDialGeometry.morningBedtimeGemSide == 10 && TodayDialGeometry.eveningBedtimeGemSide == 12)
    }

    // MARK: Alarm

    @Test
    func theAlarmBeadShowsThisMorningsAlarmUntilItRingsThenTomorrows() throws {
        var inputs = F.inputs(now: F.date(F.day, 5))
        inputs.alarm = TodayDialAlarmInput(wakeMinuteOfDay: 390, smartWindowMinutes: 20, ringsToday: true, ringsTomorrow: true)
        let early = try #require(F.model(inputs).alarm)
        #expect(!early.isTomorrow)
        #expect(early.wake == F.date(F.day, 6, 30))
        #expect(early.radius == 120)
        #expect(F.close(early.smartWindow?.sweep, 5))

        inputs.now = F.date(F.day, 7, 12)
        let later = try #require(F.model(inputs).alarm)
        #expect(later.isTomorrow)
        #expect(later.wake == F.date(F.shifted(F.day, by: 1), 6, 30))

        inputs.alarm?.ringsTomorrow = false
        #expect(F.model(inputs).alarm == nil)

        inputs.now = F.date(F.shifted(F.day, by: 1), 12)
        inputs.alarm?.ringsTomorrow = true
        #expect(F.model(inputs).alarm == nil)
    }
}
