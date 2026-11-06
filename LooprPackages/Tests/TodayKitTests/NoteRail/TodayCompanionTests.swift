import DesignSystem
import Foundation
import Testing
@testable import TodayKit

/// LV-04 step 3: which note shows when, the first-evening card, the experiment strip and the receipt layout.
@Suite("LV-04.3 Today companion")
struct TodayCompanionTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    private func at(_ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: hour, minute: minute))!
    }

    private let morning = TodayNoteCard(kind: .morning, runs: [TodayNoteRun(text: "Morning.")],
                                        chips: [TodayNoteChip(action: .explainOutcome, label: "Why 49?")])
    private let evening = TodayNoteCard(kind: .evening, runs: [TodayNoteRun(text: "Evening.")],
                                        chips: [TodayNoteChip(action: .startWindDown, label: "Start wind-down"),
                                                TodayNoteChip(action: .ask, label: "Ask")])

    private func content(now: Date, pinned: Bool = true, bedtime: Bool = false, offers: Bool = true,
                         isToday: Bool = true, evening: TodayNoteCard? = nil) -> TodayCompanionContent {
        TodayCompanionContent(morning: .note(morning), evening: evening ?? self.evening, rail: .noProtocol, bedtimeEnabled: bedtime,
                              offersFirstEvening: offers, isToday: isToday, now: now, isClockPinned: pinned, calendar: calendar)
    }

    @Test("Before 18:00 the morning note shows; from 18:00 the evening note replaces it")
    func noteFollowsTheClock() {
        #expect(content(now: at(7, 12)).note(for: content(now: at(7, 12)).mode(at: Date())) == .note(morning))
        let evening = content(now: at(19, 49))
        #expect(evening.mode(at: Date()) == .evening)
        #expect(evening.note(for: .evening)?.card?.kind == .evening)
        #expect(content(now: at(17, 59)).mode(at: Date()) == .morning)
        #expect(content(now: at(18, 0)).mode(at: Date()) == .evening)
        // A past day stays in the morning, and an unpinned clock follows the instant it is asked about.
        #expect(content(now: at(19, 49), isToday: false).mode(at: Date()) == .morning)
        #expect(content(now: at(7, 0), pinned: false).mode(at: at(20, 0)) == .evening)
    }

    @Test("Without an evening note the morning note stays after 18:00")
    func morningStaysWithoutEveningNote() {
        var value = content(now: at(19, 49))
        value.evening = nil
        #expect(value.note(for: .evening) == .note(morning))
    }

    @Test("Start wind-down shows in the note only once the bedtime activity is on; until then the first-evening card offers it")
    func windDownAndFirstEvening() {
        let off = content(now: at(19, 49))
        #expect(off.note(for: .evening)?.card?.chips.map(\.action) == [])
        #expect(off.showsFirstEvening(for: .evening))
        #expect(!off.showsFirstEvening(for: .morning))
        let on = content(now: at(19, 49), bedtime: true)
        #expect(on.note(for: .evening)?.card?.chips.map(\.action) == [.startWindDown])
        #expect(!on.showsFirstEvening(for: .evening))
        #expect(!content(now: at(19, 49), offers: false).showsFirstEvening(for: .evening))
        // Nothing left to wind down for: no offer.
        let done = TodayNoteCard(kind: .evening, runs: [TodayNoteRun(text: "Done.")], chips: [TodayNoteChip(action: .ask, label: "Ask")])
        #expect(!content(now: at(19, 49), evening: done).showsFirstEvening(for: .evening))
    }

    @Test("The first-evening card writes 18:00 in the locale's clock (ICP R2-UPG-16)")
    func firstEveningClock() {
        let us = TodayFirstEveningCopy.body(locale: Locale(identifier: "en_US"))
        #expect(us.hasPrefix("From 6:00"), "\(us)")
        #expect(!us.contains("18:00"))
        #expect(TodayFirstEveningCopy.body(locale: Locale(identifier: "en_GB")).hasPrefix("From 18:00 Loopr counts down"))
    }

    @Test("The rail state follows the source: rules, no protocol, or nothing without a store")
    func railState() {
        var value = content(now: at(7, 12))
        #expect(value.rail(for: .morning) == .noProtocol)
        value.rail = nil
        #expect(value.rail(for: .morning) == nil)
        value.rail = .rules([TodayRailRuleInput(key: "a", title: "A", state: .pending)])
        guard case .rules(let rail)? = value.rail(for: .morning) else {
            Issue.record("Expected rules")
            return
        }
        #expect(rail.rows.map(\.id) == ["a"])
    }

    // MARK: Experiment strip

    private func input(running: Bool = true, night: Int = 9, tonight: String? = "Tonight is a magnesium night.") -> TodayExperimentInput {
        TodayExperimentInput(title: "Magnesium before bed", night: night, plannedNights: 14, outcome: "Deep sleep",
                             tonight: tonight, isRunning: running)
    }

    @Test("The strip shows the running experiment's night, outcome and tonight's line")
    func stripWhenRunning() throws {
        let strip = try #require(TodayExperimentStrip.make(input()))
        #expect(strip.progress == "Night 9 of 14")
        #expect(strip.title == "Magnesium before bed")
        #expect(strip.detail == "Outcome: deep sleep. Tonight is a magnesium night.")
        #expect(strip.accessibilityLabel == "Experiment, night 9 of 14, Magnesium before bed. Outcome: deep sleep. Tonight is a magnesium night.")
        let hrv = TodayExperimentInput(title: "Cold shower", night: 2, plannedNights: 14, outcome: "HRV", tonight: nil)
        #expect(TodayExperimentStrip.make(hrv)?.detail == "Outcome: HRV.")
    }

    @Test("Nothing at all when no experiment is running or the night is outside the plan")
    func noStripWithoutRunningExperiment() {
        #expect(TodayExperimentStrip.make(nil) == nil)
        #expect(TodayExperimentStrip.make(input(running: false)) == nil)
        #expect(TodayExperimentStrip.make(input(night: 0)) == nil)
        #expect(TodayExperimentStrip.make(input(night: 15)) == nil)
    }

    // MARK: Receipt

    @Test("The receipt lays the two groups side by side with every night as a dot and last night ringed")
    func receiptLayout() throws {
        let receipt = TodayNoteReceipt(outcome: "Sleep heart rate", unit: "bpm", groups: [
            TodayNoteReceiptGroup(id: "long", label: "3 nights, 4 h or more", nightCount: 3, mean: 49, values: [48, 50, 49],
                                  isLikeLastNight: true),
            TodayNoteReceiptGroup(id: "short", label: "2 nights, less", nightCount: 2, mean: 54, values: [53, 55],
                                  isLikeLastNight: false)
        ], lastNightValue: 49)
        let layout = TodayNoteReceiptLayout(receipt: receipt, size: CGSize(width: 300, height: 76))
        #expect(layout.lanes.count == 2)
        #expect(layout.lanes.map(\.dots.count) == [3, 2])
        #expect(layout.lanes[0].frame.maxX < layout.lanes[1].frame.minX)
        // A higher value sits higher on the chart, and every dot is inside its lane.
        #expect(layout.lanes[1].meanY < layout.lanes[0].meanY)
        for lane in layout.lanes {
            for dot in lane.dots {
                #expect(lane.frame.insetBy(dx: -0.5, dy: -0.5).contains(dot.center))
            }
        }
        let marker = try #require(layout.lastNight)
        #expect(marker == layout.lanes[0].dots.last?.center)
        #expect(TodayNoteReceiptLayout(receipt: TodayNoteReceipt(outcome: "x", unit: "", groups: [], lastNightValue: nil),
                                       size: CGSize(width: 300, height: 76)).lanes.isEmpty)
    }
}
