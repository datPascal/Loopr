import DesignSystem
import DomainKit
import Foundation
import SwiftUI
import Testing
@testable import TodayKit

/// Scrubbing the rim, stepping through the hours, what flies onto the dial, the notes under it and the glue the
/// section uses.
struct TodayDialInteractionTests {
    typealias F = DialFixture

    // MARK: Scrub

    @Test
    func aPointOnTheRimIsItsTimeOfDay() {
        #expect(TodayDialScrub.minuteOfDay(at: CGPoint(x: 170, y: 10), side: 340) == 720)
        #expect(TodayDialScrub.minuteOfDay(at: CGPoint(x: 330, y: 170), side: 340) == 1_080)
        #expect(TodayDialScrub.minuteOfDay(at: CGPoint(x: 170, y: 330), side: 340) == 0)
        #expect(TodayDialScrub.minuteOfDay(at: CGPoint(x: 10, y: 170), side: 340) == 360)
        #expect(TodayDialScrub.minuteOfDay(at: CGPoint(x: 85, y: 5), side: 170) == 720)
        // Inside the centre the finger reads nothing.
        #expect(TodayDialScrub.minuteOfDay(at: CGPoint(x: 170, y: 170), side: 340) == nil)
        #expect(TodayDialScrub.minuteOfDay(at: CGPoint(x: 1, y: 1), side: 0) == nil)
        #expect(TodayDialScrub.hour(1_080) == 18 && TodayDialScrub.hour(59) == 0)
    }

    @Test
    func theReadingNamesWhatHappenedAtThatTime() {
        var inputs = F.inputs(now: F.date(F.day, 13))
        inputs.lastNight = F.night()
        inputs.meals = [F.meal("Breakfast", F.date(F.day, 7, 5))]
        inputs.rules = [F.screensOffRule]
        let model = F.model(inputs)
        #expect(TodayDialScrub.reading(model, minuteOfDay: 23 * 60 + 30, locale: F.locale).lines == ["Deep sleep"])
        #expect(TodayDialScrub.reading(model, minuteOfDay: 420, locale: F.locale).lines == ["Breakfast at 07:05"])
        #expect(TodayDialScrub.reading(model, minuteOfDay: 1_290, locale: F.locale).lines == ["Screens off at 21:45, to do"])
        let quiet = TodayDialScrub.reading(model, minuteOfDay: 840, locale: F.locale)
        #expect(quiet.lines == ["Nothing recorded"])
        #expect(quiet.spoken == "14:00. Nothing recorded.")
    }

    @Test
    func theEveningReadingNamesTonightsWindow() {
        var inputs = F.inputs(now: F.date(F.day, 19, 49))
        inputs.rules = [F.inBedRule]
        inputs.alarm = TodayDialAlarmInput(wakeMinuteOfDay: 375, ringsToday: true, ringsTomorrow: true)
        let model = F.model(inputs)
        #expect(TodayDialScrub.reading(model, minuteOfDay: 120, locale: F.locale).lines == ["Tonight's sleep window"])
        #expect(TodayDialScrub.reading(model, minuteOfDay: 1_350, locale: F.locale).lines == ["Tonight's sleep window", "Bed at 22:30"])
        #expect(TodayDialScrub.reading(model, minuteOfDay: 380, locale: F.locale).lines.last == "Alarm at 06:15 tomorrow")
    }

    // MARK: Arrivals

    private func dayWithArrivals(now: Date = F.date(F.day, 19)) -> TodayDialModel {
        var inputs = F.inputs(now: now)
        inputs.meals = [F.meal("salad", F.date(F.day, 12, 40))]
        inputs.workouts = [
            TodayDialWorkoutInput(id: "ride", title: "Cycling", start: F.date(F.day, 17, 30), end: F.date(F.day, 18, 18), provenance: .band(device: "")),
            TodayDialWorkoutInput(id: "walk", title: "Walking", start: F.date(F.day, 18, 50), end: nil, provenance: .band(device: ""))
        ]
        inputs.rules = [F.zone2Rule]
        return F.model(inputs)
    }

    @Test
    func theFirstVisitRecordsWithoutFlyingAndLaterArrivalsFlyOnce() throws {
        let model = dayWithArrivals()
        #expect(TodayDialArrivals.ids(model) == ["meal-salad", "workout-ride"])
        #expect(TodayDialArrivals.plan(model, seen: nil).isEmpty)

        let both = TodayDialArrivals.plan(model, seen: [])
        #expect(both.map(\.id) == ["meal-salad", "workout-ride"])
        let meal = try #require(both.first)
        #expect(meal.kind == .meal && meal.tint == .energy && meal.targetRadius == 96)
        let ride = both[1]
        #expect(ride.kind == .workout && ride.tint == .strain && ride.targetRadius == 80)
        #expect(F.close(ride.targetSweep, 12))

        #expect(TodayDialArrivals.plan(model, seen: ["meal-salad"]).map(\.id) == ["workout-ride"])
        #expect(TodayDialArrivals.plan(model, seen: ["meal-salad", "workout-ride"]).isEmpty)
        // A past day never flies.
        #expect(TodayDialArrivals.plan(dayWithArrivals(now: F.date(F.shifted(F.day, by: 1), 9)), seen: []).isEmpty)
    }

    @Test
    func theArrivalStoreKeepsEachDaysShownItemsAndForgetsOldDays() throws {
        let suite = "today-dial-arrivals-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TodayDialArrivalStore(defaults: defaults)
        #expect(store.seen(day: "2026-10-22") == nil)
        store.record(["meal-a"], day: "2026-10-22")
        store.record(["workout-b"], day: "2026-10-22")
        #expect(store.seen(day: "2026-10-22") == ["meal-a", "workout-b"])
        for day in ["2026-10-23", "2026-10-24", "2026-10-25"] { store.record([], day: day) }
        #expect(store.seen(day: "2026-10-22") == nil)
        #expect(store.seen(day: "2026-10-25") == [])
    }

    @Test
    func flightsStartAtTheSourceAndLandOnTheTargetArcInTheHostsPoints() {
        let frame = CGRect(x: 10, y: 20, width: 170, height: 170)
        let top = TodayDialFlightPlan.point(radius: 120, angle: 0, in: frame)
        #expect(F.close(top.x, 95) && F.close(top.y, 45))
        let arrival = TodayDialArrival(id: "meal-a", kind: .meal, sourceAngle: 0, sourceRadius: 96, targetRadius: 96, targetStartAngle: 0,
                                       targetSweep: 90, tint: .energy)
        var random = SystemRandomNumberGenerator()
        let request = TodayDialFlightPlan.request(arrival, in: frame, using: &random)
        #expect(request.landings.count == TodayDialArrival.dotCount)
        // Every dot lands on the eating ring, between noon and 18:00.
        for landing in request.landings {
            let dx = Double(landing.target.x - frame.midX), dy = Double(landing.target.y - frame.midY)
            #expect(F.close(hypot(dx, dy), 48, tolerance: 0.001))
            #expect(dx >= -0.001 && dy <= 0.001)
        }
    }

    // MARK: Notes and glue

    @Test
    func theNotesSayWhatIsMissingWithoutRepeatingTheCentre() {
        #expect(TodayDialNotes.lines(for: F.model(F.inputs()))
            == ["Nothing recorded yet. Sleep, meals, training and daylight land on this dial as they come in."])

        var inputs = F.inputs()
        inputs.lastNight = F.night()
        inputs.recentNights = F.nights(beds: Array(repeating: 630, count: 14))
        inputs.meals = [F.meal("Breakfast", F.date(F.day, 7, 5))]
        #expect(TodayDialNotes.lines(for: F.model(inputs)) == ["No training logged today.", "No time in daylight from Apple Health today."])

        inputs.lastNight = nil
        #expect(!TodayDialNotes.lines(for: F.model(inputs)).contains { $0.hasPrefix("No sleep recorded") })
    }

    @Test
    func theContentRebuildsTheModelOnTheClockUnlessItIsPinned() throws {
        var inputs = F.inputs(now: F.date(F.day, 7, 12))
        inputs.rules = [F.inBedRule]
        let hero = TodayHeroState.scored(TodayRecoveryReading(score: 78, band: .high, driver: "HRV is 12% above your usual.", guidance: nil))
        let live = TodayDialContent(inputs: inputs, isClockPinned: false)
        let evening = try #require(live.model(at: F.date(F.day, 19, 49), recovery: hero))
        #expect(evening.mode == .evening)
        guard case .countdown(let countdown) = evening.centre else {
            Issue.record("Expected the countdown")
            return
        }
        #expect(countdown.text == "2:41")

        let pinned = TodayDialContent(inputs: inputs, isClockPinned: true)
        let morning = try #require(pinned.model(at: F.date(F.day, 19, 49), recovery: hero))
        #expect(morning.mode == .morning)
        #expect(morning.readouts.last?.text == "78")
    }

    @Test
    func theRecoveryReadoutReadsTheWholeHeroAndTheOthersReadTheirSource() {
        let hero = TodayHeroState.scored(TodayRecoveryReading(score: 78, band: .high, driver: "HRV is 12% above your usual.", guidance: nil))
        var inputs = F.inputs()
        inputs.recovery = hero
        inputs.sleepHeartRate = .value(49, .band(device: "WHOOP 4.0"))
        let readouts = F.model(inputs).readouts
        #expect(TodayDialReadoutCell.recoveryLabel(readout: readouts[2], hero: hero)
            == "Recovery 78 out of 100, high recovery, ready. HRV is 12% above your usual.")
        #expect(TodayDialReadoutCell.spokenLabel(readouts[0]) == "Sleep heart rate, 49, usual after 5 nights, From WHOOP 4.0, last night")
        #expect(TodayDialReadoutCell.spokenLabel(readouts[1]) == "Regularity, after 5 nights")
    }

    @Test
    func recoveryStaysOneTapAwayInTheEvening() {
        let hero = TodayHeroState.scored(TodayRecoveryReading(score: 78, band: .high, driver: "HRV is 12% above your usual.", guidance: nil))
        var inputs = F.inputs(now: F.date(F.day, 19, 49))
        inputs.recovery = hero
        let evening = F.model(inputs)
        #expect(evening.readouts.map(\.id) == [.lastMeal, .zone2, .steps])
        #expect(evening.recovery.id == .recovery && evening.recovery.text == "78" && evening.recovery.opensWhatShapedIt)
        #expect(TodayDialRecoveryRow.summary(evening.recovery) == "Recovery 78 · ready")

        inputs.recovery = nil
        #expect(TodayDialRecoveryRow.summary(F.model(inputs).recovery) == "Recovery · no score")
        // In the morning the same readout is the third under the dial.
        inputs.now = F.date(F.day, 7, 12)
        inputs.recovery = hero
        let morning = F.model(inputs)
        #expect(morning.readouts.last == morning.recovery)
    }
}
