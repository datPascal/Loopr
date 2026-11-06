import DesignSystem
import DomainKit
import Foundation
import Testing
@testable import TodayKit

/// Layers to drawing primitives: rings, widths, tokens, state styles, ghosts for absent layers and the sticker rule.
struct TodayDialDrawingTests {
    typealias F = DialFixture

    private func drawing(_ inputs: TodayDialInputs) -> TodayDialDrawing { TodayDialDrawing(F.model(inputs)) }

    @Test
    func theHypnogramIsOneButtStrokePerSpanInItsStageToken() {
        var inputs = F.inputs()
        inputs.lastNight = F.night()
        let sleep = drawing(inputs).strokes.filter { $0.layer == .sleep }
        #expect(sleep.map(\.tint) == [.sleepLight, .sleepDeep, .sleepREM, .sleepAwake, .sleepLight])
        #expect(sleep.map(\.width) == [13, 22, 16, 5, 13])
        #expect(sleep.allSatisfy { $0.radius == 120 && !$0.roundCaps && $0.dash.isEmpty })
        // 30 minutes is 7.5 degrees, less the hair of gap between spans.
        #expect(F.close(sleep[0].sweep, 7.32))
        #expect(sleep.map(\.revealStart) == sleep.map(\.revealStart).sorted())
        #expect(!drawing(inputs).strokes.contains { $0.layer == .tonight })
    }

    @Test
    func theEveningLightsTonightsWindowAndTheWindDown() throws {
        var inputs = F.inputs(now: F.date(F.day, 19, 49))
        inputs.lastNight = F.night()
        inputs.rules = [F.inBedRule, F.screensOffRule]
        inputs.alarm = TodayDialAlarmInput(wakeMinuteOfDay: 375, smartWindowMinutes: 20, ringsToday: true, ringsTomorrow: true)
        let evening = drawing(inputs)
        #expect(!evening.strokes.contains { $0.layer == .sleep })
        let window = try #require(evening.strokes.first { $0.layer == .tonight })
        #expect(window.tint == .sleep && window.opacity == 0.16 && window.width == 24)
        let edge = try #require(evening.strokes.first { $0.layer == .tonightEdge })
        #expect(edge.dash == [3, 4] && edge.width == 1.4)
        let windDown = try #require(evening.strokes.first { $0.layer == .windDown })
        #expect(windDown.tint == .protocol && windDown.glows && windDown.width == 10)
        #expect(F.close(evening.tonightLabelAngle, 169.5))
        let gem = try #require(evening.marks.first { $0.layer == .bedtime })
        #expect(gem.shape == .gem && gem.size == 6 && gem.tint == .ink)
        #expect(evening.bedtimeGemSide == 12)
        #expect(evening.strokes.contains { $0.layer == .smartWindow && $0.tint == .brand })
        let alarm = try #require(evening.marks.first { $0.layer == .alarm })
        #expect(alarm.radius == 120 && alarm.shape == .hollow(lineWidth: 1.6))
    }

    @Test
    func eatingIsAFaintPlanUnderTheLitWindowWithTimeTicks() throws {
        var inputs = F.inputs(now: F.date(F.day, 13))
        inputs.meals = [F.meal("berries", F.date(F.day, 7, 5)), F.meal("salad", F.date(F.day, 12, 40))]
        inputs.rules = [F.kitchenRule]
        let eating = drawing(inputs)
        let planned = try #require(eating.strokes.first { $0.layer == .eatingPlanned })
        #expect(planned.tint == .energy && planned.opacity == 0.22 && planned.width == 3 && planned.radius == 96)
        let window = try #require(eating.strokes.first { $0.layer == .eating })
        #expect(window.width == 3.4 && window.glows && window.roundCaps)
        #expect(eating.marks.filter { $0.layer == .mealTime }.count == 2)
        #expect(eating.stickers.map(\.id) == ["berries", "salad"])
        let kitchen = try #require(eating.marks.first { $0.layer == .kitchen })
        #expect(kitchen.shape == .hollow(lineWidth: 2) && kitchen.radius == 96 && kitchen.tint == .protocol)
    }

    @Test
    func plannedTrainingIsDashedAndDoneTrainingIsSolidAndLit() throws {
        var inputs = F.inputs()
        inputs.rules = [F.zone2Rule]
        inputs.workouts = [TodayDialWorkoutInput(id: "walk", title: "Walking", start: F.date(F.day, 6), end: F.date(F.day, 6, 40),
                                                 provenance: .band(device: ""))]
        inputs.plannedSessions = [TodayDialPlannedSessionInput(id: "legs", title: "Legs", startMinuteOfDay: 1_200, durationMinutes: nil)]
        let training = drawing(inputs)
        let planned = try #require(training.strokes.first { $0.id == "training-rule-zone2" })
        #expect(planned.dash == [2, 4] && planned.opacity == 0.7 && !planned.glows && planned.tint == .strain && planned.width == 7)
        let done = try #require(training.strokes.first { $0.id == "training-walk" })
        #expect(done.dash.isEmpty && done.glows && done.opacity == 1 && done.radius == 80)
        let point = try #require(training.marks.first { $0.id == "training-plan-legs" })
        #expect(point.layer == .plannedTraining && point.shape == .hollow(lineWidth: 1.4))
    }

    @Test
    func daylightIsBrandDotsOnTheRimAsInTheContract() {
        var inputs = F.inputs()
        inputs.daylight = .dailyTotal(minutes: 12, provenance: .appleHealth(source: ""))
        let dots = drawing(inputs).marks.filter { $0.layer == .daylight }
        #expect(dots.count == 3)
        #expect(dots.allSatisfy { $0.tint == .brand && $0.radius == 142 && $0.size == 1.9 && $0.glows })
    }

    @Test
    func absentLayersLeaveAFaintTrackSoTheDialKeepsItsShape() {
        let empty = drawing(F.inputs())
        let ghosts = empty.strokes.filter { $0.layer == .ghost }
        #expect(Set(ghosts.map(\.id)) == ["ghost-sleep", "ghost-eating", "ghost-training", "ghost-daylight"])
        #expect(ghosts.filter { $0.id != "ghost-daylight" }.allSatisfy { $0.sweep == 360 && $0.tint == .inkMuted })
        let daylight = ghosts.first { $0.id == "ghost-daylight" }
        #expect(daylight?.startAngle == 270 && daylight?.sweep == 180)
        #expect(empty.marks.isEmpty && empty.stickers.isEmpty)
        #expect(F.close(empty.handAngle, 288))
    }

    @Test
    func eachRuleStateHasItsOwnBeadStyle() {
        func bead(_ state: TodayDialRuleState, kitchen: Bool = false) -> TodayDialMark {
            TodayDialDrawing.bead(TodayDialBead(id: "b", title: "B", kind: kitchen ? .kitchenCloses : .routine, minuteOfDay: 600,
                                                angle: 330, radius: kitchen ? 96 : 142, size: kitchen ? 4 : 4.2, state: state, isEvening: false))
        }
        #expect(bead(.kept).shape == .dot && bead(.kept).tint == .protocol && bead(.kept).glows)
        #expect(bead(.pending).shape == .dot && bead(.pending).opacity == 0.6 && !bead(.pending).glows)
        #expect(bead(.missed).shape == .hollow(lineWidth: 1.4) && bead(.missed).tint == .inkSecondary)
        #expect(bead(.unknown).shape == .dashedHollow(lineWidth: 1.2) && bead(.unknown).tint == .inkMuted)
        #expect(bead(.pending, kitchen: true).shape == .hollow(lineWidth: 2) && bead(.pending, kitchen: true).layer == .kitchen)
        #expect(bead(.kept, kitchen: true).shape == .dot)
    }

    @Test
    func stickersCloserThanTheirSeparationMoveForwardAndACrowdBecomesPlusN() throws {
        var inputs = F.inputs(now: F.date(F.day, 19))
        inputs.meals = [F.meal("a", F.date(F.day, 12)), F.meal("b", F.date(F.day, 12, 20)), F.meal("c", F.date(F.day, 12, 40)),
                        F.meal("d", F.date(F.day, 13)), F.meal("e", F.date(F.day, 13, 10)), F.meal("dinner", F.date(F.day, 18))]
        let meals = try #require(F.model(inputs).eating.value?.meals)
        let marks = TodayDialStickerLayout.place(meals)
        #expect(marks.map(\.id) == ["a", "b", "c", "dinner"])
        let separation = TodayDialStickerLayout.minimumSeparation
        #expect(F.close(TodayDialStickerLayout.diameterDegrees, 19.79, tolerance: 0.01))
        #expect(F.close(marks[0].angle, 0))
        #expect(F.close(marks[1].angle, separation))
        #expect(F.close(marks[2].angle, separation * 2))
        #expect(marks[2].overflow == 2)
        #expect(marks[3].overflow == 0 && F.close(marks[3].angle, 90))
        // A sticker never sits before its meal.
        for mark in marks {
            #expect(TodayDialGeometry.normalized(mark.angle - 180) >= TodayDialGeometry.normalized(mark.mealAngle - 180) - 1e-9)
        }
        #expect(marks.map(\.revealStart) == marks.map(\.revealStart).sorted())
    }

    @Test
    func entranceProgressRunsFromEachStartForItsDuration() {
        #expect(TodayDialDrawing.progress(elapsed: 0, start: 0.5, duration: 1) == 0)
        #expect(TodayDialDrawing.progress(elapsed: 1, start: 0.5, duration: 1) == 0.5)
        #expect(TodayDialDrawing.progress(elapsed: TodayDialDrawing.entranceDuration, start: 1.1, duration: 0.35) == 1)
        #expect(TodayDialDrawing.progress(elapsed: 0, start: 0, duration: 0) == 1)
    }
}
