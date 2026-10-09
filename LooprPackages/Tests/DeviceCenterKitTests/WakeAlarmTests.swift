import Foundation
import Testing
@testable import DeviceCenterKit

struct WakeAlarmPlanTests {
    @Test
    func noSavedAlarmOpensAsSevenEveryDayWithASmartWindowSwitchedOff() {
        let plan = WakeAlarmPlan(configuration: nil)
        #expect(plan.isEnabled == false)
        #expect(plan.wakeMinute == 7 * 60)
        #expect(plan.smartWindowMinutes == StrapAlarmConfiguration.defaultWindowMinutes)
        #expect(plan.weekdays == Set(AlarmWeekday.allCases))
    }

    @Test
    func aLegacyExactAlarmKeepsItsStartAsTheWakeTimeAndHasNoWindow() throws {
        // Written by builds before wake windows existed: no `mode` key and a
        // twenty-minute "stop buzzing" end.
        let json = #"{"isEnabled":true,"startMinute":420,"endMinute":440,"weekdays":["monday","friday"]}"#
        let legacy = try JSONDecoder().decode(StrapAlarmConfiguration.self, from: Data(json.utf8))
        let plan = WakeAlarmPlan(configuration: legacy)

        #expect(plan.isEnabled)
        #expect(plan.wakeMinute == 420)
        #expect(plan.smartWindowMinutes == 0)
        #expect(plan.weekdays == [.monday, .friday])
        // Untouched, the plan does not count as an edit.
        #expect(plan.differs(from: WakeAlarmPlan(configuration: legacy)) == false)
    }

    @Test
    func aSavedWindowReadsBackAsItsLatestEdgeAndLength() {
        let saved = StrapAlarmConfiguration(
            isEnabled: true, startMinute: 6 * 60 + 30, endMinute: 7 * 60,
            weekdays: [.tuesday], mode: .wakeWindow
        )
        let plan = WakeAlarmPlan(configuration: saved)
        #expect(plan.wakeMinute == 7 * 60)
        #expect(plan.smartWindowMinutes == 30)
        #expect(plan.windowStartMinute == 6 * 60 + 30)
    }

    @Test
    func turningTheWindowOffSavesAnExactAlarmAtTheWakeTime() {
        let plan = WakeAlarmPlan(isEnabled: true, wakeMinute: 6 * 60 + 45, smartWindowMinutes: 0)
        let configuration = plan.configuration()
        #expect(configuration.mode == .exactTime)
        #expect(configuration.startMinute == 6 * 60 + 45)
        #expect(configuration.guaranteedMinute == 6 * 60 + 45)
        #expect(configuration.windowMinutes == 0)
        #expect(throws: Never.self) { try configuration.validated() }
    }

    @Test(arguments: [10, 20, 30])
    func eachWindowOptionEndsAtTheWakeTime(minutes: Int) {
        let plan = WakeAlarmPlan(isEnabled: true, wakeMinute: 7 * 60, smartWindowMinutes: minutes)
        let configuration = plan.configuration()
        #expect(configuration.mode == .wakeWindow)
        #expect(configuration.endMinute == 7 * 60)
        #expect(configuration.guaranteedMinute == 7 * 60)
        #expect(configuration.startMinute == 7 * 60 - minutes)
        #expect(configuration.windowMinutes == minutes)
        // Round trip.
        #expect(WakeAlarmPlan(configuration: configuration) == plan)
    }

    @Test
    func aWindowThatStartsBeforeMidnightWrapsTheStartMinute() {
        let plan = WakeAlarmPlan(isEnabled: true, wakeMinute: 10, smartWindowMinutes: 30)
        let configuration = plan.configuration()
        #expect(configuration.startMinute == 1_420)
        #expect(configuration.endMinute == 10)
        #expect(configuration.windowMinutes == 30)
    }

    @Test
    func aStoredWindowLengthOutsideTheOptionsIsStillOffered() {
        let plan = WakeAlarmPlan(isEnabled: true, wakeMinute: 420, smartWindowMinutes: 45)
        #expect(plan.windowOptions == [0, 10, 20, 30, 45])
        #expect(WakeAlarmPlan().windowOptions == [0, 10, 20, 30])
    }

    @Test
    func differsOnlyOnFieldsAPersonCanSee() {
        let saved = WakeAlarmPlan(isEnabled: true, wakeMinute: 420, smartWindowMinutes: 20)
        var draft = saved
        #expect(draft.differs(from: saved) == false)
        draft.isEnabled = false
        #expect(draft.differs(from: saved) == false)
        draft.wakeMinute = 421
        #expect(draft.differs(from: saved))
        #expect(saved.differs(from: nil))
    }

    @Test
    func suggestionsParseTheSleepKitClockLabel() {
        #expect(WakeAlarmSuggestion(localTime: "07:30", reason: "")?.minuteOfDay == 450)
        #expect(WakeAlarmSuggestion(localTime: "24:00", reason: "") == nil)
        #expect(WakeAlarmSuggestion(localTime: "half past seven", reason: "") == nil)
    }
}

struct WakeAlarmScheduleTests {
    private static func calendar(_ identifier: String = "Europe/Berlin") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_GB")
        calendar.timeZone = TimeZone(identifier: identifier)!
        calendar.firstWeekday = 2
        return calendar
    }

    private static func date(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int,
        in calendar: Calendar
    ) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private static let formatter = WakeAlarmFormatter(calendar: calendar(), locale: Locale(identifier: "en_GB"))

    @Test
    func weekdayOnlyAlarmSkipsTheWeekend() {
        let calendar = Self.calendar()
        // 2026-09-25 is a Friday.
        let now = Self.date(2026, 9, 25, 8, 0, in: calendar)
        let plan = WakeAlarmPlan(
            isEnabled: true, wakeMinute: 7 * 60, smartWindowMinutes: 0,
            weekdays: [.monday, .tuesday, .wednesday, .thursday, .friday]
        )
        let next = WakeAlarmSchedule.next(for: plan, after: now, calendar: calendar)
        #expect(next?.wake == Self.date(2026, 9, 28, 7, 0, in: calendar))
        #expect(next?.windowStart == nil)
        #expect(Self.formatter.sentence(for: next!.wake, now: now) == "Monday at 07:00, in 2 days 23 h")
    }

    @Test
    func anAlarmThatAlreadyWentTodayMovesToTomorrow() {
        let calendar = Self.calendar()
        let now = Self.date(2026, 9, 23, 22, 48, in: calendar)
        let plan = WakeAlarmPlan(isEnabled: true, wakeMinute: 7 * 60, smartWindowMinutes: 30)
        let next = WakeAlarmSchedule.next(for: plan, after: now, calendar: calendar)
        #expect(next?.wake == Self.date(2026, 9, 24, 7, 0, in: calendar))
        #expect(next?.windowStart == Self.date(2026, 9, 24, 6, 30, in: calendar))
        #expect(Self.formatter.sentence(for: next!.wake, now: now) == "Tomorrow at 07:00, in 8 h 12 min")
    }

    @Test
    func aWindowCrossingMidnightOpensTheEveningBefore() {
        let calendar = Self.calendar()
        let now = Self.date(2026, 9, 23, 21, 0, in: calendar)
        let plan = WakeAlarmPlan(isEnabled: true, wakeMinute: 10, smartWindowMinutes: 20)
        let next = WakeAlarmSchedule.next(for: plan, after: now, calendar: calendar)
        #expect(next?.wake == Self.date(2026, 9, 24, 0, 10, in: calendar))
        #expect(next?.windowStart == Self.date(2026, 9, 23, 23, 50, in: calendar))
    }

    @Test
    func insideAnOpenWindowTheWakeIsStillTheLatestEdge() {
        let calendar = Self.calendar()
        let now = Self.date(2026, 9, 24, 6, 45, in: calendar)
        let plan = WakeAlarmPlan(isEnabled: true, wakeMinute: 7 * 60, smartWindowMinutes: 30)
        let next = WakeAlarmSchedule.next(for: plan, after: now, calendar: calendar)
        #expect(next?.wake == Self.date(2026, 9, 24, 7, 0, in: calendar))
        #expect(Self.formatter.countdown(from: now, to: next!.wake) == "in 15 min")
    }

    @Test
    func theWindowEdgeItselfIsNotTheNextWake() {
        let calendar = Self.calendar()
        // At exactly 07:00 the alarm is due now, so the next one is tomorrow.
        let now = Self.date(2026, 9, 24, 7, 0, in: calendar)
        let plan = WakeAlarmPlan(isEnabled: true, wakeMinute: 7 * 60, smartWindowMinutes: 10)
        let next = WakeAlarmSchedule.next(for: plan, after: now, calendar: calendar)
        #expect(next?.wake == Self.date(2026, 9, 25, 7, 0, in: calendar))
        #expect(next?.windowStart == Self.date(2026, 9, 25, 6, 50, in: calendar))
    }

    @Test
    func springForwardShortensTheNightInsteadOfSlippingTheAlarm() {
        let calendar = Self.calendar()
        // Clocks go from 02:00 to 03:00 on Sunday 29 March 2026 in Berlin.
        let now = Self.date(2026, 3, 28, 23, 0, in: calendar)
        let plan = WakeAlarmPlan(isEnabled: true, wakeMinute: 7 * 60, smartWindowMinutes: 0)
        let next = WakeAlarmSchedule.next(for: plan, after: now, calendar: calendar)
        #expect(next?.wake == Self.date(2026, 3, 29, 7, 0, in: calendar))
        #expect(Self.formatter.sentence(for: next!.wake, now: now) == "Tomorrow at 07:00, in 7 h")
    }

    @Test
    func aWakeTimeInsideTheSkippedHourMovesToTheFirstRealMinute() {
        let calendar = Self.calendar()
        let now = Self.date(2026, 3, 28, 22, 0, in: calendar)
        let plan = WakeAlarmPlan(isEnabled: true, wakeMinute: 2 * 60 + 30, smartWindowMinutes: 0)
        let next = WakeAlarmSchedule.next(for: plan, after: now, calendar: calendar)
        #expect(next?.wake == Self.date(2026, 3, 29, 3, 0, in: calendar))
    }

    @Test
    func fallBackKeepsTheWallClockTimeAndAddsTheHourToTheCountdown() {
        let calendar = Self.calendar()
        // Clocks go from 03:00 back to 02:00 on Sunday 25 October 2026.
        let now = Self.date(2026, 10, 24, 23, 0, in: calendar)
        let plan = WakeAlarmPlan(isEnabled: true, wakeMinute: 7 * 60, smartWindowMinutes: 0)
        let next = WakeAlarmSchedule.next(for: plan, after: now, calendar: calendar)
        #expect(next?.wake == Self.date(2026, 10, 25, 7, 0, in: calendar))
        #expect(Self.formatter.countdown(from: now, to: next!.wake) == "in 9 h")
    }

    @Test
    func anAlarmWithNoDaysOrSwitchedOffHasNoNextWake() {
        let calendar = Self.calendar()
        let now = Self.date(2026, 9, 23, 22, 0, in: calendar)
        #expect(WakeAlarmSchedule.next(
            for: WakeAlarmPlan(isEnabled: true, weekdays: []), after: now, calendar: calendar
        ) == nil)
        #expect(WakeAlarmSchedule.next(
            for: WakeAlarmPlan(isEnabled: false), after: now, calendar: calendar
        ) == nil)
    }
}

struct WakeAlarmFormatterTests {
    private static let formatter: WakeAlarmFormatter = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar.firstWeekday = 2
        return WakeAlarmFormatter(calendar: calendar, locale: Locale(identifier: "en_GB"))
    }()

    @Test
    func countdownRoundsUpToTheMinuteAndNeverReadsZero() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(Self.formatter.countdown(from: now, to: now.addingTimeInterval(20)) == "in 1 min")
        #expect(Self.formatter.countdown(from: now, to: now.addingTimeInterval(3_600)) == "in 1 h")
        #expect(Self.formatter.countdown(from: now, to: now.addingTimeInterval(3_660)) == "in 1 h 1 min")
        #expect(Self.formatter.countdown(from: now, to: now.addingTimeInterval(86_400)) == "in 1 day")
        #expect(Self.formatter.countdown(from: now, to: now.addingTimeInterval(86_400 * 2 + 7_200)) == "in 2 days 2 h")
    }

    @Test
    func repeatSummaryNamesTheCommonSets() {
        #expect(Self.formatter.repeatSummary(Set(AlarmWeekday.allCases)) == "Every day")
        #expect(Self.formatter.repeatSummary([.monday, .tuesday, .wednesday, .thursday, .friday]) == "Weekdays")
        #expect(Self.formatter.repeatSummary([.saturday, .sunday]) == "Weekends")
        #expect(Self.formatter.repeatSummary([.sunday, .monday, .wednesday]) == "Mon, Wed, Sun")
        #expect(Self.formatter.repeatSummary([]) == "No days")
    }

    @Test
    func weekStartsOnTheCalendarsFirstDay() {
        #expect(Self.formatter.orderedWeekdays.first == .monday)
        #expect(Self.formatter.orderedWeekdays.last == .sunday)
        #expect(Self.formatter.time(minuteOfDay: 7 * 60 + 5) == "07:05")
    }
}

struct WakeAlarmLayerTests {
    @Test
    func bandLayerOnlySaysConfirmedWhenTheBandDid() {
        let confirmed = StrapAlarmAssurance(band: .confirmed)
        #expect(WakeAlarmBandLayer(assurance: confirmed, alarmEnabled: true, bandConnected: false) == .confirmed)
        #expect(WakeAlarmBandLayer(assurance: StrapAlarmAssurance(band: .unconfirmed), alarmEnabled: true, bandConnected: true) == .notConfirmed)
        #expect(WakeAlarmBandLayer(assurance: StrapAlarmAssurance(band: .notArmed), alarmEnabled: true, bandConnected: true) == .notArmed)
        #expect(WakeAlarmBandLayer(assurance: StrapAlarmAssurance(band: .waiting), alarmEnabled: true, bandConnected: true) == .waiting)
    }

    @Test
    func aDisconnectedBandIsNotConnectedRatherThanFailed() {
        for state: StrapAlarmAssurance.BandState in [.off, .waiting, .unconfirmed, .notArmed] {
            #expect(WakeAlarmBandLayer(
                assurance: StrapAlarmAssurance(band: state), alarmEnabled: true, bandConnected: false
            ) == .notConnected)
        }
        // Connected with nothing on record yet: the next reconcile writes it.
        #expect(WakeAlarmBandLayer(assurance: nil, alarmEnabled: true, bandConnected: true) == .waiting)
        #expect(WakeAlarmBandLayer(assurance: StrapAlarmAssurance(band: .confirmed), alarmEnabled: false, bandConnected: true) == .off)
    }

    @Test
    func retryIsOfferedOnlyForAnUnconfirmedAlarm() {
        #expect(WakeAlarmBandLayer.notConfirmed.canRetry)
        #expect(WakeAlarmBandLayer.notArmed.canRetry)
        #expect(!WakeAlarmBandLayer.confirmed.canRetry)
        #expect(!WakeAlarmBandLayer.notConnected.canRetry)
    }

    @Test
    func phoneLayerFollowsThePreferenceFirst() {
        #expect(WakeAlarmPhoneLayer(backup: .systemAlarm, alarmEnabled: true, layerEnabled: false) == .disabled)
        #expect(WakeAlarmPhoneLayer(backup: .systemAlarm, alarmEnabled: false, layerEnabled: true) == .idle)
        #expect(WakeAlarmPhoneLayer(backup: .systemAlarm, alarmEnabled: true, layerEnabled: true) == .systemAlarm)
        #expect(WakeAlarmPhoneLayer(backup: .notification, alarmEnabled: true, layerEnabled: true) == .notification)
        #expect(WakeAlarmPhoneLayer(backup: .unavailable("No"), alarmEnabled: true, layerEnabled: true) == .unavailable("No"))
        if case .unavailable = WakeAlarmPhoneLayer(backup: nil, alarmEnabled: true, layerEnabled: true) {} else {
            Issue.record("A missing outcome must not read as scheduled")
        }
    }
}

struct WakeAlarmCardStateTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar.firstWeekday = 2
        return calendar
    }()
    private static let formatter = WakeAlarmFormatter(calendar: calendar, locale: Locale(identifier: "en_GB"))
    private static let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 22, minute: 48))!

    @Test
    func noAlarmShowsSetAWakeAlarmWithAnySuggestion() {
        let suggestion = WakeAlarmSuggestion(minuteOfDay: 450, reason: "Recent nights")
        let state = WakeAlarmCardState.make(
            configuration: nil, band: .off, phone: .idle, suggestion: suggestion,
            now: Self.now, formatter: Self.formatter
        )
        #expect(state == .notSet(lastWakeMinute: nil, suggestion: suggestion))
    }

    @Test
    func aSwitchedOffAlarmOffersItsLastTimeBack() {
        let off = WakeAlarmPlan(isEnabled: false, wakeMinute: 6 * 60 + 15).configuration()
        let state = WakeAlarmCardState.make(
            configuration: off, band: .off, phone: .idle, now: Self.now, formatter: Self.formatter
        )
        #expect(state == .notSet(lastWakeMinute: 6 * 60 + 15, suggestion: nil))
    }

    @Test
    func anAlarmThatIsOnShowsTimeCountdownAndWindow() {
        let on = WakeAlarmPlan(isEnabled: true, wakeMinute: 7 * 60, smartWindowMinutes: 30).configuration()
        let state = WakeAlarmCardState.make(
            configuration: on, band: .confirmed, phone: .systemAlarm, now: Self.now, formatter: Self.formatter
        )
        #expect(state == .scheduled(WakeAlarmCardSummary(
            wakeTime: "07:00",
            when: "Tomorrow, in 8 h 12 min",
            smartWindow: "Smart wake from 06:30",
            repeatSummary: "Every day",
            warning: nil
        )))
    }

    @Test
    func theCardWarnsWhenALayerNeedsALook() {
        let on = WakeAlarmPlan(isEnabled: true, wakeMinute: 7 * 60, smartWindowMinutes: 0).configuration()
        func warning(_ band: WakeAlarmBandLayer, _ phone: WakeAlarmPhoneLayer) -> String? {
            guard case .scheduled(let summary) = WakeAlarmCardState.make(
                configuration: on, band: band, phone: phone, now: Self.now, formatter: Self.formatter
            ) else { return "not scheduled" }
            return summary.warning
        }
        #expect(warning(.notConfirmed, .systemAlarm) == "Band did not confirm. Your phone alarm is set.")
        #expect(warning(.notArmed, .disabled) == "Band did not confirm. Open to check.")
        #expect(warning(.confirmed, .disabled) == "Phone alarm is off.")
        #expect(warning(.notConnected, .unavailable("x")) == "Phone alarm is not scheduled.")
        #expect(warning(.waiting, .systemAlarm) == nil)
    }
}

#if canImport(SwiftUI)
import SwiftUI

struct WakeAlarmHapticsTests {
    @Test
    func settingOrChangingAnAlarmSucceedsAndSwitchingItOffTapsLightly() {
        var on = WakeAlarmPlan(configuration: nil)
        on.isEnabled = true
        var later = on.withWakeMinute(8 * 60)
        later.isEnabled = true
        var off = on
        off.isEnabled = false
        #expect(WakeAlarmHaptics.feedback(from: nil, to: on) == .success)
        #expect(WakeAlarmHaptics.feedback(from: on, to: later) == .success)
        #expect(WakeAlarmHaptics.feedback(from: on, to: off) == .impact(weight: .light))
        #expect(WakeAlarmHaptics.feedback(from: on, to: on) == nil)
        #expect(WakeAlarmHaptics.feedback(from: nil, to: off) == nil)
    }
}
#endif
