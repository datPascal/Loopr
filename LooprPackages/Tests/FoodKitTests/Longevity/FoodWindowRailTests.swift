import FoodKit
import Foundation
import Testing

struct FoodWindowRailTests {
    private let gb = Locale(identifier: "en_GB")

    private func meal(_ hour: Int, _ minute: Int = 0, slot: FoodMealSlot = .lunch, energy: Double? = 500, id: UUID = UUID()) -> FoodRailMeal {
        FoodRailMeal(id: id, minute: hour * 60 + minute, energy: energy, slot: slot, initial: "S", photoID: nil, title: "Soup")
    }

    @Test func theAxisRunsFromSixToNineAndWidensInThreeHourStepsToHoldEveryMark() {
        let plain = FoodWindowRail(railMeals: [meal(8), meal(13)], nowMinute: nil, closesMinute: nil)
        #expect(plain.startMinute == 360 && plain.endMinute == 1_260)
        #expect(plain.ticks == [360, 540, 720, 900, 1_080, 1_260])

        let early = FoodWindowRail(railMeals: [meal(5, 10, slot: .breakfast), meal(22, 15, slot: .dinner)], nowMinute: nil, closesMinute: nil)
        #expect(early.startMinute == 180 && early.endMinute == 1_440)
        #expect(early.ticks.first == 180 && early.ticks.last == 1_440)

        // The kitchen's closing time and now widen the axis too.
        let late = FoodWindowRail(railMeals: [], nowMinute: 23 * 60 + 5, closesMinute: 21 * 60 + 30)
        #expect(late.startMinute == 360 && late.endMinute == 1_440)
    }

    @Test func aMinuteSitsOnTheTrackInProportionAndStaysInside() {
        let rail = FoodWindowRail(railMeals: [meal(12)], nowMinute: nil, closesMinute: nil)
        #expect(rail.fraction(of: 360) == 0)
        #expect(rail.fraction(of: 810) == 0.5)
        #expect(rail.fraction(of: 1_260) == 1)
        #expect(rail.fraction(of: 0) == 0 && rail.fraction(of: 1_439) == 1)
    }

    @Test func theWindowRunsFromTheFirstMealToTheKitchenClosingTime() {
        let meals = [meal(12, 40), meal(7, 5, slot: .breakfast)]
        #expect(FoodWindowRail(railMeals: meals, nowMinute: nil, closesMinute: 1_110).window == 425...1_110)
        // Without a rule, or with one before the first meal, it ends at the last meal.
        #expect(FoodWindowRail(railMeals: meals, nowMinute: nil, closesMinute: nil).window == 425...760)
        #expect(FoodWindowRail(railMeals: meals, nowMinute: nil, closesMinute: 400).window == 425...760)
        #expect(FoodWindowRail(railMeals: [], nowMinute: 600, closesMinute: 1_110).window == nil)
        #expect(FoodWindowRail(railMeals: meals, nowMinute: nil, closesMinute: 1_110).windowText(locale: gb) == "07:05 to 18:30")
        #expect(FoodWindowRail(railMeals: [], nowMinute: 600, closesMinute: 1_110).windowText(locale: gb) == nil)
    }

    @Test func nowAndTheGhostShowOnTodayOnly() {
        let meals = [meal(7, 5, slot: .breakfast), meal(12, 40, slot: .lunch)]
        let today = FoodWindowRail(railMeals: meals, nowMinute: 13 * 60 + 4, closesMinute: 1_110)
        #expect(today.nowMinute == 784)
        // Lunch is in, so a snack is next, as the Log tiles say. It sits at its usual 15:30.
        #expect(today.ghost == FoodRailGhost(slot: .snack, minute: 930))
        // With the snack in too, dinner sits half an hour before the kitchen closes, earlier than its usual 18:30.
        let fed = FoodWindowRail(railMeals: meals + [meal(13, 0, slot: .snack)], nowMinute: 13 * 60 + 4, closesMinute: 1_110)
        #expect(fed.ghost == FoodRailGhost(slot: .dinner, minute: 1_080))
        let past = FoodWindowRail(railMeals: meals, nowMinute: nil, closesMinute: 1_110)
        #expect(past.nowMinute == nil && past.ghost == nil)
    }

    @Test func theGhostIsTheSlotTheLogTilesOfferAndNeverBeforeNow() {
        // 07:00 with nothing logged: breakfast at 08:00.
        #expect(FoodWindowRail(railMeals: [], nowMinute: 420, closesMinute: nil).ghost == FoodRailGhost(slot: .breakfast, minute: 480))
        // 13:04 with breakfast only: lunch, twenty minutes from now.
        #expect(FoodWindowRail(railMeals: [meal(7, slot: .breakfast)], nowMinute: 784, closesMinute: nil).ghost
                == FoodRailGhost(slot: .lunch, minute: 804))
        // Snack time with no snack: the snack, twenty minutes from now, the slot Manual and the Log tiles open too.
        for (minute, logged) in [(16 * 60, [FoodMealSlot.breakfast, .lunch]), (13 * 60, [.breakfast, .lunch]), (7 * 60, []), (19 * 60, [.lunch])] {
            let rail = FoodWindowRail(railMeals: logged.map { meal(7, slot: $0) }, nowMinute: minute, closesMinute: nil)
            #expect(rail.ghost?.slot == FoodMealSlot.toLog(minuteOfDay: minute, logged: Set(logged)).slot)
        }
        #expect(FoodWindowRail(railMeals: [meal(8, slot: .breakfast), meal(12, slot: .lunch)], nowMinute: 16 * 60, closesMinute: nil).ghost
                == FoodRailGhost(slot: .snack, minute: 980))
        // Late, with dinner still not logged: now plus twenty minutes, past the closing time.
        #expect(FoodWindowRail(railMeals: [meal(8, slot: .breakfast), meal(12, slot: .lunch)], nowMinute: 22 * 60, closesMinute: 1_110).ghost
                == FoodRailGhost(slot: .dinner, minute: 1_340))
        // Everything logged: no ghost.
        let all = [meal(8, slot: .breakfast), meal(12, slot: .lunch), meal(19, slot: .dinner)]
        #expect(FoodWindowRail(railMeals: all, nowMinute: 20 * 60, closesMinute: nil).ghost == nil)
    }

    @Test func mealsFarApartSitAtTheirTimes() {
        let rail = FoodWindowRail(railMeals: [meal(7, 30, slot: .breakfast), meal(12, 30), meal(19, slot: .dinner)], nowMinute: nil, closesMinute: nil)
        let placements = rail.placements(trackWidth: 300, stickerWidth: 56)
        #expect(placements.count == 3)
        #expect(Set(placements.map(\.stack)) == [0, 1, 2])
        for placement in placements where placement.timeX >= 28 && placement.timeX <= 272 { #expect(abs(placement.x - placement.timeX) < 1e-9) }
        #expect(abs(placements[1].x - 390.0 / 900 * 300) < 1e-9)
    }

    @Test func mealsCloserThanAStickerWidthStackAroundTheirMeanTime() {
        let first = meal(12, 0), second = meal(12, 20)
        let rail = FoodWindowRail(railMeals: [second, first], nowMinute: nil, closesMinute: nil)
        let placements = rail.placements(trackWidth: 300, stickerWidth: 56)
        #expect(placements.map(\.mealID) == [first.id, second.id])
        #expect(placements.allSatisfy { $0.stack == 0 })
        #expect(placements.map(\.order) == [0, 1])
        let spacing = placements[1].x - placements[0].x
        #expect(abs(spacing - 0.55 * 56) < 1e-9)
        let mean = (placements[0].timeX + placements[1].timeX) / 2
        #expect(abs((placements[0].x + placements[1].x) / 2 - mean) < 1e-9)
        let stacks = rail.stacks(trackWidth: 300, stickerWidth: 56)
        #expect(stacks.count == 1 && stacks[0].meals.map(\.id) == [first.id, second.id])
        #expect(FoodWindowRail.label(for: stacks[0].meals, locale: gb) == "12:00 · 2 meals · 1,000 kcal")
    }

    @Test func aStackAtTheEdgeStaysInsideTheTrack() {
        let rail = FoodWindowRail(railMeals: [meal(6, 0, slot: .breakfast), meal(6, 10, slot: .breakfast), meal(6, 20, slot: .breakfast)],
                                  nowMinute: nil, closesMinute: nil)
        let xs = rail.placements(trackWidth: 300, stickerWidth: 56).map(\.x)
        #expect(abs(xs[0] - 28) < 1e-9)
        #expect(xs.allSatisfy { $0 >= 28 && $0 <= 272 })
    }

    @Test func stacksThatTouchOnceFannedOutMergeIntoOne() {
        // Three meals each just over a width apart in time would fan into each other once the middle pair stacks.
        let meals = [meal(9, 0), meal(10, 0), meal(10, 10), meal(11, 10)]
        let placements = FoodWindowRail(railMeals: meals, nowMinute: nil, closesMinute: nil).placements(trackWidth: 300, stickerWidth: 56)
        let stacks = Dictionary(grouping: placements, by: \.stack)
        for (_, group) in stacks {
            let xs = group.map(\.x).sorted()
            for (left, right) in zip(xs, xs.dropFirst()) { #expect(right - left > 0) }
        }
        let ordered = placements.sorted { $0.x < $1.x }
        for (left, right) in zip(ordered, ordered.dropFirst()) where left.stack != right.stack { #expect(right.x - left.x >= 56 - 1e-9) }
    }

    @Test func aCrowdedTrackSqueezesTheStackToFit() {
        let meals = (0..<12).map { meal(12, $0) }
        let xs = FoodWindowRail(railMeals: meals, nowMinute: nil, closesMinute: nil).placements(trackWidth: 200, stickerWidth: 56).map(\.x)
        #expect(xs.allSatisfy { $0 >= 28 - 1e-9 && $0 <= 172 + 1e-9 })
        #expect(abs((xs[1] - xs[0]) - (200 - 56) / 11) < 1e-9)
    }

    @Test func theGhostSitsAWidthAfterTheLastSticker() {
        let rail = FoodWindowRail(railMeals: [meal(7, slot: .breakfast), meal(12, 50, slot: .lunch)], nowMinute: 12 * 60 + 55, closesMinute: nil)
        let placements = rail.placements(trackWidth: 300, stickerWidth: 56)
        let ghost = placements.last!
        #expect(ghost.mealID == nil && ghost.id == "ghost")
        #expect(ghost.x >= placements[1].x + 56 + 4 - 1e-9)
        #expect(ghost.stack == 2)
    }

    @Test func labelsThatWouldTouchDropToTheSecondRowAndStayInside() {
        let rows = FoodWindowRail.labelRows(centres: [40, 90, 200, 290], widths: [90, 90, 60, 80], trackWidth: 300)
        #expect(rows.map(\.row) == [0, 1, 0, 1])
        #expect(rows[0].x == 45)
        #expect(rows[3].x == 260)
    }

    @Test func labelsNameTheTimeAndKnownCalories() {
        #expect(FoodWindowRail.label(for: [meal(7, 5, energy: 470)], locale: gb) == "07:05 · 470 kcal")
        #expect(FoodWindowRail.label(for: [meal(7, 5, energy: nil)], locale: gb) == "07:05")
        #expect(FoodWindowRail.label(for: [meal(12, 40, energy: 640), meal(12, 50, energy: nil)], locale: gb) == "12:40 · 2 meals")
        #expect(FoodWindowRail.label(for: [meal(19, 15, energy: 600)], locale: Locale(identifier: "en_US")).contains("7:15"))
    }

    @Test func eachMealLeansTheSameWayEveryTime() {
        let ids = (0..<200).map { _ in UUID() }
        for id in ids {
            let lean = FoodWindowRail.rotation(for: id)
            #expect(lean == FoodWindowRail.rotation(for: id))
            #expect((2...6).contains(abs(lean)))
        }
        #expect(Set(ids.map { FoodWindowRail.rotation(for: $0) > 0 }).count == 2)
    }

    @Test func aMealTakesItsClockTimeFromTheCalendar() throws {
        let context = try LongevityStore()
        let saved = try context.meal(at: Longevity.instant(2026, 10, 21, 7, 5), zone: Longevity.berlin, items: [Longevity.typedItem("Porridge", nutrients: [.energy: 470])],
                                     slot: .breakfast)
        let rail = FoodWindowRail(meals: [saved], calendar: Longevity.calendar(Longevity.berlin), now: nil, closesMinute: nil)
        #expect(rail.meals.first?.minute == 425 && rail.meals.first?.initial == "P" && rail.meals.first?.energy == 470)
        #expect(rail.accessibilitySummary(locale: gb).contains("Breakfast at 07:05, 470 kilocalories."))
        #expect(FoodWindowRail(railMeals: [], nowMinute: 600, closesMinute: nil).accessibilitySummary(locale: gb).contains("Nothing logged yet today."))
    }
}
