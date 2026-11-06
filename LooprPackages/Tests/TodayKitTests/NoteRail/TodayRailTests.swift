import DesignSystem
import Foundation
import Testing
@testable import TodayKit

/// LV-04 step 3: the protocol rail's order, labels, kept and live progress text, and when a rule can be ticked.
@Suite("LV-04.3 protocol rail")
struct TodayRailTests {
    private let gb = Locale(identifier: "en_GB")

    private let light = TodayRailRuleInput(key: "light", title: "Morning light", group: .sleep, source: .appleHealth,
                                           metric: "daylight_minutes", targetKind: .atLeast, targetValue: 10, unit: .minutes,
                                           timeOfDayMinutes: 7 * 60, state: .kept, measuredValue: 22)
    private let stack = TodayRailRuleInput(key: "stack", title: "Supplements", group: .supplements, source: .food,
                                           metric: "supplements_all_taken", unit: .tick, timeOfDayMinutes: 7 * 60 + 30,
                                           state: .pending)
    private let protein = TodayRailRuleInput(key: "protein", title: "Protein 130 g", group: .food, source: .food,
                                             metric: "protein_g", targetKind: .atLeast, targetValue: 130, unit: .grams,
                                             state: .pending, measuredValue: 38)
    private let zone2 = TodayRailRuleInput(key: "zone-2", title: "Zone 2, 45 min", group: .fitness, source: .band,
                                           metric: "zone2_minutes", targetKind: .atLeast, targetValue: 45, unit: .minutes,
                                           timeOfDayMinutes: 17 * 60 + 30, state: .kept, measuredValue: 48)
    private let kitchen = TodayRailRuleInput(key: "kitchen", title: "Kitchen closes", group: .food, source: .food,
                                             metric: "last_meal_time", targetKind: .atMost, targetValue: 1_110,
                                             unit: .minutesAfterMidnight, timeOfDayMinutes: 18 * 60 + 30, isEvening: true,
                                             state: .kept, measuredValue: 1_100)
    private let screens = TodayRailRuleInput(key: "screens", title: "Screens off", group: .sleep, source: .manual,
                                             timeOfDayMinutes: 21 * 60 + 45, isEvening: true, state: .pending)
    private let bed = TodayRailRuleInput(key: "bed", title: "In bed by 22:30", group: .sleep, source: .band,
                                         metric: "in_bed_time", targetKind: .atMost, targetValue: 1_350,
                                         unit: .minutesAfterMidnight, timeOfDayMinutes: 22 * 60 + 30, isEvening: true,
                                         state: .pending)

    private var all: [TodayRailRuleInput] { [bed, screens, kitchen, zone2, protein, stack, light] }

    @Test("Rules run in time order: all-day rules first, then by time, evening rules after midnight after the late evening")
    func ordering() {
        var late = screens
        late.key = "late"; late.timeOfDayMinutes = 30
        var untimedEvening = screens
        untimedEvening.key = "untimed-evening"; untimedEvening.timeOfDayMinutes = nil
        var earlyMorning = light
        earlyMorning.key = "early"; earlyMorning.timeOfDayMinutes = 6 * 60
        let ordered = TodayRailRules.ordered(all + [late, untimedEvening, earlyMorning]).map(\.key)
        #expect(ordered == ["protein", "early", "light", "stack", "zone-2", "kitchen", "screens", "bed", "late", "untimed-evening"])
    }

    @Test("Equal times keep the version's order")
    func tiesKeepVersionOrder() {
        var first = screens; first.key = "a-second"
        var second = screens; second.key = "b-first"
        #expect(TodayRailRules.ordered([second, first]).map(\.key) == ["b-first", "a-second"])
    }

    @Test("Morning light and supplements are chips; the rest are rows")
    func chips() {
        let content = TodayRailRules.content(all, isToday: true, mode: .morning, locale: gb)
        #expect(content.chips.map(\.id) == ["light", "stack"])
        #expect(content.rows.map(\.id) == ["protein", "zone-2", "kitchen", "screens", "bed"])
        #expect(content.keptCount == 3)
        #expect(content.ruleCount == 7)
        #expect(content.summary == "3 of 7 rules kept")
        #expect(content.chips.first?.accessibilityLabel == "Morning light, kept")
    }

    @Test("An evening supplement keeps its time among the rows (ICP R2-UPG-4)")
    func eveningSupplementIsARow() {
        let magnesium = TodayRailRuleInput(key: "magnesium", title: "Magnesium, 300 mg", group: .supplements,
                                           timeOfDayMinutes: 21 * 60 + 30, isEvening: true, state: .pending)
        let content = TodayRailRules.content(all + [magnesium], isToday: true, mode: .evening, locale: gb)
        #expect(content.chips.map(\.id) == ["light", "stack"])
        #expect(content.rows.map(\.id) == ["protein", "zone-2", "kitchen", "magnesium", "screens", "bed"])
    }

    @Test("The ring's label and every row's time column (ICP R2-UPG-22, R2-UPG-23)")
    func ringLabelAndTimeColumn() {
        let content = TodayRailRules.content(all, isToday: true, mode: .morning, locale: Locale(identifier: "en_US"))
        #expect(TodayRailContent.ringLabel(kept: content.keptCount, total: content.ruleCount) == "3 of 7 kept")
        #expect(TodayRailContent.ringLabel(kept: 9, total: 7) == "7 of 7 kept")
        #expect(Set(content.timeTexts) == Set(content.rows.map(\.timeText)))
        #expect(content.timeTexts.contains("All day"))
    }

    @Test("Each row says what checks it")
    func labelsByCheckSource() {
        let rows = Dictionary(uniqueKeysWithValues: TodayRailRules.content(all, isToday: true, mode: .morning, locale: gb)
            .rows.map { ($0.id, $0) })
        #expect(rows["bed"]?.detail == "The band checks it")
        #expect(rows["screens"]?.detail == "Tap to tick")
        #expect(rows["protein"]?.detail == "38 g so far · Food checks it")
        #expect(TodayRailRules.sourcePhrase(.fitness) == "Fitness checks it")
        #expect(TodayRailRules.sourcePhrase(.appleHealth) == "Apple Health checks it")
        var openKitchen = kitchen
        openKitchen.state = .pending; openKitchen.measuredValue = 425
        #expect(TodayRailRules.content([openKitchen], isToday: true, mode: .morning, locale: gb).rows.first?.detail
            == "By 18:30 · Food checks it")
        var ride = zone2
        ride.state = .pending; ride.measuredValue = nil
        #expect(TodayRailRules.content([ride], isToday: true, mode: .morning, locale: gb).rows.first?.detail == "The band checks it")
        var unknown = bed
        unknown.state = .unknown
        #expect(TodayRailRules.content([unknown], isToday: true, mode: .morning, locale: gb).rows.first?.detail
            == "No reading yet · the band checks it")
    }

    @Test("Kept rules say what kept them; pending rules show live progress where the source has it")
    func keptAndProgressText() {
        let rows = Dictionary(uniqueKeysWithValues: TodayRailRules.content(all, isToday: true, mode: .evening, locale: gb)
            .rows.map { ($0.id, $0) })
        #expect(rows["zone-2"]?.detail == "48 min in zone 2")
        #expect(rows["kitchen"]?.detail == "10 minutes early")
        // More than an hour early, the row gives the time instead (ICP R2-OPT-8).
        var lunch = kitchen
        lunch.measuredValue = 750
        #expect(TodayRailRules.keptText(lunch, locale: gb) == "At 12:30")
        #expect(rows["zone-2"]?.symbol == "checkmark")
        #expect(rows["protein"]?.progress.map { abs($0 - 38.0 / 130) < 0.0001 } == true)
        #expect(rows["kitchen"]?.progress == nil)
        #expect(rows["screens"]?.detail == "Tap to tick")
        var onTime = kitchen; onTime.measuredValue = 1_110
        #expect(TodayRailRules.keptText(onTime, locale: gb) == "Right on time")
        var oneEarly = kitchen; oneEarly.measuredValue = 1_109
        #expect(TodayRailRules.keptText(oneEarly, locale: gb) == "1 minute early")
        var ticked = screens; ticked.state = .kept
        #expect(TodayRailRules.keptText(ticked, locale: gb) == "Ticked")
        var taken = stack; taken.state = .kept; taken.measuredValue = 1
        #expect(TodayRailRules.keptText(taken, locale: gb) == "All taken")
        var eaten = protein; eaten.state = .kept; eaten.measuredValue = 132
        #expect(TodayRailRules.keptText(eaten, locale: gb) == "132 g today")
        // A missing reading stays missing: no "0 g so far".
        var empty = protein; empty.measuredValue = nil
        #expect(TodayRailRules.progressText(empty, locale: gb) == nil)
    }

    @Test("Only a manual rule that is not kept, on today's rail, can be ticked; a kept one has nothing left to tick")
    func tickability() {
        let today = TodayRailRules.content(all, isToday: true, mode: .evening, locale: gb)
        #expect(today.rows.filter(\.canTick).map(\.id) == ["screens"])
        var kept = screens; kept.state = .kept
        #expect(TodayRailRules.content([kept], isToday: true, mode: .evening, locale: gb).rows.first?.canTick == false)
        #expect(TodayRailRules.content(all, isToday: false, mode: .morning, locale: gb).rows.allSatisfy { !$0.canTick })
        var manualChip = stack
        manualChip.source = .manual
        #expect(TodayRailRules.content([manualChip], isToday: true, mode: .morning, locale: gb).chips.first?.canTick == true)
    }

    @Test("Rule titles follow the locale's clock")
    func titlesInTheLocaleClock() {
        let us = TodayRailRules.content([bed], isToday: true, mode: .morning, locale: Locale(identifier: "en_US"))
        #expect(us.rows.first?.title.contains("10:30") == true)
        #expect(us.rows.first?.timeText.contains("10:30") == true)
        #expect(TodayRailRules.timeText(nil, locale: gb) == "All day")
    }

    @Test("Rows take the protocol plum for manual rules and the domain accent otherwise")
    func accents() {
        let rows = Dictionary(uniqueKeysWithValues: TodayRailRules.content(all, isToday: true, mode: .morning, locale: gb)
            .rows.map { ($0.id, $0) })
        #expect(rows["screens"]?.accent == .protocol)
        #expect(rows["protein"]?.accent == .energy)
        #expect(rows["zone-2"]?.accent == .strain)
        #expect(rows["bed"]?.accent == .sleep)
    }
}
