import CoreGraphics
import DesignSystem
import DomainKit
import Foundation
import Testing
@testable import TodayKit

/// Tapping the dial: which element a touch picks, what its card says, and the peel from the ring to the stage chart.
struct TodayDialFocusTests {
    typealias F = DialFixture

    /// The morning of 22 October with last night (22:30 to 06:18) and breakfast at 08:00.
    private func morning(nutrition: TodayDialMealNutrition? = nil) -> TodayDialModel {
        var inputs = F.inputs()
        inputs.lastNight = F.night()
        var meal = F.meal("breakfast", F.date(F.day, 8))
        meal.nutrition = nutrition
        inputs.meals = [meal]
        return F.model(inputs)
    }

    private func point(radius: Double, minuteOfDay: Double) -> TodayDialPoint {
        TodayDialGeometry.point(radius: radius, angle: TodayDialGeometry.angle(minuteOfDay: minuteOfDay))
    }

    // MARK: Hit test

    @Test
    func theCentreOpensLastNightInTheMorning() {
        let model = morning()
        #expect(TodayDialHitTest.focus(at: TodayDialPoint(x: 170, y: 170), side: 340, model: model) == .lastNight)
    }

    @Test
    func theNightArcOpensLastNight() {
        // 02:00, in the middle of the night, on the sleep ring.
        #expect(TodayDialHitTest.focus(at: point(radius: TodayDialGeometry.sleepRadius, minuteOfDay: 120), side: 340,
                                       model: morning()) == .lastNight)
    }

    @Test
    func aStickerOpensItsMealEvenAFewPointsOff() {
        let model = morning()
        let sticker = point(radius: TodayDialGeometry.eatingRadius, minuteOfDay: 8 * 60)
        #expect(TodayDialHitTest.focus(at: sticker, side: 340, model: model) == .meal("breakfast"))
        // Just outside the sticker's rim still picks it: the touch target is larger than the drawing.
        let off = TodayDialPoint(x: sticker.x, y: sticker.y - TodayDialGeometry.stickerRadius - 8)
        #expect(TodayDialHitTest.focus(at: off, side: 340, model: model) == .meal("breakfast"))
    }

    @Test
    func anEmptyStretchOfTheFaceOpensNothing() {
        // 18:00 on the sleep ring: nothing there on this morning's dial.
        #expect(TodayDialHitTest.focus(at: point(radius: TodayDialGeometry.sleepRadius, minuteOfDay: 18 * 60), side: 340,
                                       model: morning()) == nil)
    }

    @Test
    func theSlopIsInScreenPointsSoASmallDialReachesFurtherInTheViewBox() {
        let model = morning()
        // 30 view-box points beyond the sticker's rim, outwards from the centre: past the slop on a 340-point dial,
        // within it on a 170-point one.
        let far = point(radius: TodayDialGeometry.eatingRadius + TodayDialGeometry.stickerRadius + 30, minuteOfDay: 8 * 60)
        #expect(TodayDialHitTest.focus(at: far, side: 340, model: model) != .meal("breakfast"))
        #expect(TodayDialHitTest.focus(at: far, side: 170, model: model) == .meal("breakfast"))
    }

    @Test
    func aBeadOnTheRimOpensItsRule() {
        var inputs = F.inputs()
        inputs.rules = [F.screensOffRule]
        let model = F.model(inputs)
        let bead = point(radius: TodayDialGeometry.rimRadius, minuteOfDay: 1_305)
        #expect(TodayDialHitTest.focus(at: bead, side: 340, model: model) == .bead("screens-off"))
    }

    // MARK: Anchors and what the dial stops drawing

    @Test
    func theMealAnchorIsItsSticker() throws {
        let anchor = try #require(TodayDialHitTest.anchor(for: .meal("breakfast"), in: morning()))
        let sticker = point(radius: TodayDialGeometry.eatingRadius, minuteOfDay: 8 * 60)
        #expect(F.close(anchor.center.x, sticker.x) && F.close(anchor.center.y, sticker.y))
        #expect(anchor.radius == TodayDialGeometry.stickerRadius)
        #expect(TodayDialHitTest.anchor(for: .meal("gone"), in: morning()) == nil)
    }

    @Test
    func lastNightCarriesEveryStageSpanOffTheDial() {
        let model = morning()
        let carried = TodayDialHitTest.carriedIDs(for: .lastNight, in: model)
        let drawn = Set(TodayDialDrawing(model).strokes.filter { $0.layer == .sleep }.map(\.id))
        #expect(!drawn.isEmpty)
        #expect(drawn.isSubset(of: carried))
        #expect(TodayDialHitTest.carriedIDs(for: .meal("breakfast"), in: model) == ["sticker-breakfast"])
    }

    // MARK: Cards

    @Test
    func theMealCardReadsCaloriesAndMacrosAsFoodWritesThem() throws {
        let nutrition = TodayDialMealNutrition(energyKcal: 520, proteinGrams: 32, carbsGrams: 72, fatGrams: 15, fibreGrams: nil,
                                               items: ["Greek yogurt", "berries", "granola"], isPartial: true)
        guard case .meal(let meal) = TodayDialFocusDetail.make(.meal("breakfast"), model: morning(nutrition: nutrition), locale: F.locale) else {
            Issue.record("Expected the meal card")
            return
        }
        #expect(meal.title == "breakfast")
        #expect(meal.time == "08:00")
        #expect(meal.energy == "520 kcal")
        #expect(meal.macros.map(\.text) == ["32 g", "72 g", "15 g", "– g"])
        #expect(meal.items == "Greek yogurt, berries, granola")
        #expect(meal.note == "Totals count only the foods with values.")
        // 128 + 288 + 135 kcal from the three macros.
        let shares = meal.macros.compactMap(\.energyShare)
        #expect(shares.count == 3)
        #expect(abs(shares.reduce(0, +) - 1) < 1e-9)
        #expect(F.close(shares[0], 128 / 551))
    }

    @Test
    func aMealWithoutNutritionShowsNoMacros() throws {
        guard case .meal(let meal) = TodayDialFocusDetail.make(.meal("breakfast"), model: morning(), locale: F.locale) else {
            Issue.record("Expected the meal card")
            return
        }
        #expect(meal.energy == nil)
        #expect(meal.macros.isEmpty)
        #expect(meal.note == nil)
    }

    @Test
    func aCardWhoseElementLeftTheDialIsNil() {
        #expect(TodayDialFocusDetail.make(.meal("deleted"), model: morning(), locale: F.locale) == nil)
        #expect(TodayDialFocusDetail.make(.tonight, model: morning(), locale: F.locale) == nil)
        #expect(TodayDialFocusDetail.make(.alarm, model: morning(), locale: F.locale) == nil)
    }

    @Test
    func theNightCardKeepsTheStagesAndTheirTimes() throws {
        guard case .lastNight(let night) = TodayDialFocusDetail.make(.lastNight, model: morning(), locale: F.locale) else {
            Issue.record("Expected the night card")
            return
        }
        #expect(night.spans.count == 5)
        #expect(night.range == "22:30 to 06:18")
        #expect(night.asleep == LooprUnitFormatter.duration(minutes: 468))
        #expect(night.stages.hasPrefix("Deep"))
    }

    @Test
    func onlyAManualRuleNotYetKeptCanBeTickedFromTheDial() throws {
        var inputs = F.inputs()
        inputs.rules = [F.screensOffRule, F.kitchenRule]
        let model = F.model(inputs)
        guard case .rule(let manual) = TodayDialFocusDetail.make(.bead("screens-off"), model: model, locale: F.locale),
              case .rule(let food) = TodayDialFocusDetail.make(.bead("kitchen"), model: model, locale: F.locale) else {
            Issue.record("Expected two rule cards")
            return
        }
        #expect(manual.canTick)
        #expect(manual.time == "At 21:45")
        #expect(!food.canTick)
        #expect(food.time == "By 18:30")
        #expect(food.source == "Food checks this from your meals.")
    }

    // MARK: The peel

    private func peel() throws -> (TodayDialSleepMorph, TodayDialStageChartLayout, TodayDialModel) {
        let model = morning()
        guard case .present(.lastNight(let night)) = model.sleep else { throw CancellationError() }
        let start = night.spans.map(\.arc.start).min()!, end = night.spans.map(\.arc.end).max()!
        let chart = TodayDialStageChartLayout(frame: CGRect(x: 14, y: 240, width: 310, height: 116), laneHeight: 24, labelWidth: 46,
                                              start: start, end: end)
        return (TodayDialSleepMorph(spans: night.spans, side: 340, chart: chart), chart, model)
    }

    @Test
    func thePeelStartsExactlyOnTheRing() throws {
        let (morph, _, _) = try peel()
        let first = try #require(morph.pieces.first)
        let outline = TodayDialSleepMorph.outline(first, progress: 0)
        for (a, b) in zip(outline, first.source) {
            #expect(abs(a.x - b.x) < 1e-9 && abs(a.y - b.y) < 1e-9)
        }
        #expect(first.source.count == (TodayDialSleepMorph.samples + 1) * 2)
    }

    @Test
    func thePeelLandsOnSleepsBarsInTheirLanes() throws {
        let (morph, chart, _) = try peel()
        for piece in morph.pieces {
            let outline = TodayDialSleepMorph.outline(piece, progress: 1)
            #expect(outline.count == piece.target.count)
            for (a, b) in zip(outline, piece.target) {
                #expect(abs(a.x - b.x) < 1e-6 && abs(a.y - b.y) < 1e-6)
            }
            let ys = outline.map(\.y)
            #expect(abs((ys.min()! + ys.max()!) / 2 - chart.laneMidY(piece.stage)) < 1e-6)
            #expect(outline.allSatisfy { $0.x >= chart.lanes.minX - 1e-6 && $0.x <= chart.lanes.maxX + 1e-6 })
        }
    }

    @Test
    func spansLeaveTheRingInTheOrderTheNightHappened() throws {
        let (morph, _, _) = try peel()
        let delays = morph.pieces.map(\.delay)
        #expect(delays == delays.sorted())
        #expect(delays.first == 0)
        #expect(F.close(delays.last, TodayDialSleepMorph.maximumDelay))
        // Half way through, the first span is further along than the last.
        #expect(TodayDialSleepMorph.local(morph.pieces.first!, progress: 0.5) > TodayDialSleepMorph.local(morph.pieces.last!, progress: 0.5))
    }

    @Test
    func noPieceTurnsInsideOutOnTheWay() throws {
        let (morph, _, _) = try peel()
        let n = TodayDialSleepMorph.samples
        for piece in morph.pieces where piece.target[n].x - piece.target[0].x > 4 {
            // The bar's first edge runs left to right, so the ring end it leaves from is the ring's visual left.
            let start = piece.source[0].x + piece.source[piece.source.count - 1].x
            let end = piece.source[n].x + piece.source[n + 1].x
            #expect(start <= end + 1e-6)
        }
    }
}
