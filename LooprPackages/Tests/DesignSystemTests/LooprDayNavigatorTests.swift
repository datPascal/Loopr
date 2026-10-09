import Foundation
import SwiftUI
import Testing
#if canImport(UIKit)
import UIKit
#endif
@testable import DesignSystem

@MainActor
struct LooprDayNavigatorTests {
    #if canImport(UIKit)
    @Test func horizontalChartPanDoesNotStartADaySwipe() {
        let page = UIScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 600))
        page.contentSize = CGSize(width: 320, height: 1400)
        let chart = UIScrollView(frame: CGRect(x: 0, y: 200, width: 320, height: 186))
        chart.contentSize = CGSize(width: 2560, height: 186)
        let plot = UIView(frame: chart.bounds)
        page.addSubview(chart)
        chart.addSubview(plot)
        #expect(LooprDaySwipeRecognizer.Coordinator.startsInHorizontalScrollView(plot))
        #expect(!LooprDaySwipeRecognizer.Coordinator.startsInHorizontalScrollView(page))
        chart.contentSize.width = chart.bounds.width
        #expect(!LooprDaySwipeRecognizer.Coordinator.startsInHorizontalScrollView(plot))
    }
    #endif

    private func calendar(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
    }

    private let perth = TimeZone(identifier: "Australia/Perth")!

    private func navigation(day: LooprDay, today: LooprDay, earliest: LooprDay?,
                            calendar: Calendar, selected: Box<LooprDay?> = Box(nil)) -> LooprDayNavigation {
        LooprDayNavigation(day: day, today: today, earliest: earliest, calendar: calendar,
                           onSelect: { selected.value = $0 })
    }

    final class Box<Value>: @unchecked Sendable {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    // MARK: Labels

    @Test func titlesAreTodayYesterdayThenTheDate() {
        let calendar = calendar("Australia/Perth")
        let today = LooprDay(year: 2026, month: 9, day: 24)
        #expect(LooprDayLabel.title(for: today, today: today, calendar: calendar) == "Today")
        #expect(LooprDayLabel.title(for: LooprDay(year: 2026, month: 9, day: 23), today: today, calendar: calendar) == "Yesterday")
        #expect(LooprDayLabel.title(for: LooprDay(year: 2026, month: 9, day: 22), today: today, calendar: calendar) == "Tue 22 Sep")
        #expect(LooprDayLabel.title(for: LooprDay(year: 2025, month: 12, day: 30), today: today, calendar: calendar) == "Tue 30 Dec 2025")
    }

    @Test func yesterdayAcrossAYearAndAMonthBoundary() {
        let calendar = calendar("Europe/Berlin")
        let newYear = LooprDay(year: 2027, month: 1, day: 1)
        #expect(LooprDayLabel.title(for: LooprDay(year: 2026, month: 12, day: 31), today: newYear, calendar: calendar) == "Yesterday")
        #expect(LooprDayLabel.nightRange(for: newYear, today: newYear, calendar: calendar) == "Thu 31 Dec → Fri 1 Jan")
        let october = LooprDay(year: 2026, month: 10, day: 1)
        #expect(LooprDayLabel.nightRange(for: october, today: october, calendar: calendar) == "Wed 30 Sep → Thu 1 Oct")
    }

    @Test func nightNamesTheEveningBeforeAndTheMorningOfTheDay() {
        let calendar = calendar("Australia/Perth")
        let today = LooprDay(year: 2026, month: 9, day: 24)
        #expect(LooprDayLabel.nightTitle(for: today, today: today, calendar: calendar) == "Last night")
        #expect(LooprDayLabel.nightRange(for: today, today: today, calendar: calendar) == "Wed 23 → Thu 24 Sep")
        let yesterday = LooprDay(year: 2026, month: 9, day: 23)
        #expect(LooprDayLabel.nightTitle(for: yesterday, today: today, calendar: calendar) == "Tue 22 → Wed 23 Sep")
    }

    @Test func spokenTitleSpellsTheDateOut() {
        let calendar = calendar("Australia/Perth")
        let today = LooprDay(year: 2026, month: 9, day: 24)
        #expect(LooprDayLabel.spokenTitle(for: LooprDay(year: 2026, month: 9, day: 23), today: today, calendar: calendar)
                == "Yesterday, Wednesday 23 September")
        #expect(LooprDayLabel.spokenTitle(for: LooprDay(year: 2026, month: 9, day: 21), today: today, calendar: calendar)
                == "Monday 21 September")
    }

    // MARK: Day arithmetic across DST

    @Test func steppingCrossesDaylightSavingChangesOneCivilDayAtATime() {
        // Europe/Berlin leaves summer time on Sun 25 Oct 2026: that day lasts 25 hours.
        let berlin = calendar("Europe/Berlin")
        let sunday = LooprDay(year: 2026, month: 10, day: 25)
        #expect(sunday.adding(days: 1, calendar: berlin) == LooprDay(year: 2026, month: 10, day: 26))
        #expect(sunday.adding(days: -1, calendar: berlin) == LooprDay(year: 2026, month: 10, day: 24))
        #expect(LooprDay(year: 2026, month: 10, day: 26).days(since: LooprDay(year: 2026, month: 10, day: 24), calendar: berlin) == 2)
        // America/Sao_Paulo used to skip midnight itself (18 Oct 2015 began at 01:00).
        let saoPaulo = calendar("America/Sao_Paulo")
        let skipped = LooprDay(year: 2015, month: 10, day: 18)
        #expect(skipped.adding(days: -1, calendar: saoPaulo) == LooprDay(year: 2015, month: 10, day: 17))
        #expect(skipped.adding(days: 1, calendar: saoPaulo) == LooprDay(year: 2015, month: 10, day: 19))
        #expect(skipped.start(in: saoPaulo) != nil)
    }

    @Test func civilDayFollowsTheCalendarTimeZone() {
        // 23 Sep 22:15 in Perth (UTC+8) is 14:15 UTC.
        let instant = Date(timeIntervalSince1970: 1_790_172_900)
        #expect(LooprDay(date: instant, calendar: calendar("Australia/Perth")) == LooprDay(year: 2026, month: 9, day: 23))
        #expect(LooprDay(date: instant.addingTimeInterval(2 * 3600), calendar: calendar("Australia/Perth")) == LooprDay(year: 2026, month: 9, day: 24))
        #expect(LooprDay(date: instant.addingTimeInterval(2 * 3600), calendar: calendar("UTC")) == LooprDay(year: 2026, month: 9, day: 23))
    }

    // MARK: Bounds

    @Test func navigatorIsBoundedByTheEarliestRecordedDayAndToday() {
        let calendar = calendar("Australia/Perth")
        let today = LooprDay(year: 2026, month: 9, day: 24)
        let earliest = LooprDay(year: 2026, month: 9, day: 21)
        let onToday = navigation(day: today, today: today, earliest: earliest, calendar: calendar)
        #expect(onToday.canGoBack)
        #expect(!onToday.canGoForward)
        #expect(onToday.clamped(5) == today)
        let onFirst = navigation(day: earliest, today: today, earliest: earliest, calendar: calendar)
        #expect(!onFirst.canGoBack)
        #expect(onFirst.canGoForward)
        #expect(onFirst.clamped(-3) == earliest)
        #expect(onFirst.clamped(10) == today)
    }

    @Test func withoutAnyDataTheNavigatorStaysOnToday() {
        let calendar = calendar("UTC")
        let today = LooprDay(year: 2026, month: 9, day: 24)
        let nav = navigation(day: today, today: today, earliest: nil, calendar: calendar)
        #expect(!nav.canGoBack)
        #expect(!nav.canGoForward)
        #expect(nav.lowerBound == today)
    }

    @Test func steppingCallsBackWithTheClampedDayAndIgnoresNoOps() {
        let calendar = calendar("Australia/Perth")
        let today = LooprDay(year: 2026, month: 9, day: 24)
        let selected = Box<LooprDay?>(nil)
        let nav = navigation(day: LooprDay(year: 2026, month: 9, day: 22), today: today,
                             earliest: LooprDay(year: 2026, month: 9, day: 22), calendar: calendar, selected: selected)
        nav.goBack()
        #expect(selected.value == nil)
        nav.goForward()
        #expect(selected.value == LooprDay(year: 2026, month: 9, day: 23))
        nav.goToToday()
        #expect(selected.value == today)
        nav.select(LooprDay(year: 2027, month: 1, day: 1))
        #expect(selected.value == today)
    }

    @Test func anEarliestDayAfterTodayNeverLocksTheNavigator() {
        // A clock moved backwards: stored data looks newer than today.
        let calendar = calendar("UTC")
        let today = LooprDay(year: 2026, month: 9, day: 24)
        let nav = navigation(day: today, today: today, earliest: LooprDay(year: 2026, month: 9, day: 26), calendar: calendar)
        #expect(nav.lowerBound == today)
        #expect(!nav.canGoBack)
    }

    // MARK: Swipe

    @Test func onlyAQuickClearlyHorizontalFlickChangesTheDay() {
        #expect(LooprDaySwipe.step(translation: CGSize(width: 120, height: 10), predictedEnd: CGSize(width: 200, height: 10), duration: 0.2) == -1)
        #expect(LooprDaySwipe.step(translation: CGSize(width: -90, height: 20), predictedEnd: CGSize(width: -150, height: 20), duration: 0.3) == 1)
        // A short but thrown flick.
        #expect(LooprDaySwipe.step(translation: CGSize(width: 40, height: 5), predictedEnd: CGSize(width: 220, height: 5), duration: 0.12) == -1)
        // A vertical scroll that drifts sideways.
        #expect(LooprDaySwipe.step(translation: CGSize(width: 80, height: 200), predictedEnd: CGSize(width: 120, height: 600), duration: 0.3) == nil)
        // A diagonal that is not horizontal enough.
        #expect(LooprDaySwipe.step(translation: CGSize(width: 100, height: 70), predictedEnd: CGSize(width: 180, height: 120), duration: 0.3) == nil)
        // A chart scrub: hold, then a slow drag.
        #expect(LooprDaySwipe.step(translation: CGSize(width: 150, height: 4), predictedEnd: CGSize(width: 160, height: 4), duration: 1.4) == nil)
        // Too small.
        #expect(LooprDaySwipe.step(translation: CGSize(width: 30, height: 2), predictedEnd: CGSize(width: 60, height: 2), duration: 0.2) == nil)
    }

    @Test func onlyASidewaysStartWithoutAHoldMayBegin() {
        #expect(LooprDaySwipe.mayBegin(velocity: CGPoint(x: 900, y: 80), heldFor: 0.05))
        #expect(!LooprDaySwipe.mayBegin(velocity: CGPoint(x: 300, y: 400), heldFor: 0.05))
        #expect(!LooprDaySwipe.mayBegin(velocity: CGPoint(x: 900, y: 20), heldFor: 0.4))
    }

    // MARK: Sync age

    @Test func syncAgeReadsMinutesThenHoursThenDays() {
        #expect(LooprSyncAge.label(ageMinutes: 0) == "Synced just now")
        #expect(LooprSyncAge.label(ageMinutes: -4) == "Synced just now")
        #expect(LooprSyncAge.label(ageMinutes: 1) == "Synced 1 min ago")
        #expect(LooprSyncAge.label(ageMinutes: 59) == "Synced 59 min ago")
        #expect(LooprSyncAge.label(ageMinutes: 60) == "Synced 1 h ago")
        #expect(LooprSyncAge.label(ageMinutes: 642) == "Synced 10 h ago")
        #expect(LooprSyncAge.label(ageMinutes: 1_439) == "Synced 23 h ago")
        #expect(LooprSyncAge.label(ageMinutes: 1_440) == "Synced 1 day ago")
        #expect(LooprSyncAge.label(ageMinutes: 2 * 1_440 + 30) == "Synced 2 days ago")
        let now = Date(timeIntervalSince1970: 1_790_200_000)
        #expect(LooprSyncAge.label(lastSync: nil, now: now) == nil)
        #expect(LooprSyncAge.label(lastSync: now.addingTimeInterval(-17 * 3600 - 59), now: now) == "Synced 17 h ago")
        #expect(LooprSyncAge.label(lastSync: now.addingTimeInterval(300), now: now) == "Synced just now")
    }

    // MARK: Header chip

    @Test func headerChipOnlyForStatesSomeoneCanActOn() {
        for quiet in [MetricState.loading, .noRecords, .absent, .measuredZero, .partial, .lowConfidence, .settling, .unsupportedHardware] {
            #expect(LooprHeaderStatus.actionableState(quiet, isToday: true) == nil)
        }
        #expect(LooprHeaderStatus.actionableState(nil, isToday: true) == nil)
        #expect(LooprHeaderStatus.actionableState(.stale, isToday: true) == .stale)
        #expect(LooprHeaderStatus.actionableState(.stale, isToday: false) == nil)
        #expect(LooprHeaderStatus.actionableState(.stale, isToday: true, dayIsEmpty: true) == nil)
        #expect(LooprHeaderStatus.actionableState(.recoverableError, isToday: true, dayIsEmpty: true) == .recoverableError)
        for loud in [MetricState.disconnected, .bluetoothOff, .permissionDenied, .recoverableError, .destructiveFailure] {
            #expect(LooprHeaderStatus.actionableState(loud, isToday: false) == loud)
        }
        #expect(LooprHeaderStatus.chip(for: .partial, isToday: true, accent: .sleep) == nil)
        #expect(LooprHeaderStatus.chip(for: .recoverableError, isToday: true, accent: .sleep)?.accessibilitySummary == "Could not load data")
    }

    // MARK: Empty day

    @Test func emptyDayCopyNamesTheDayAndTheNextStep() {
        let calendar = calendar("Australia/Perth")
        let today = LooprDay(year: 2026, month: 9, day: 24)
        let now = Date(timeIntervalSince1970: 1_790_172_900 + 11 * 3600)
        let onToday = LooprDayNavigation(day: today, today: today, earliest: LooprDay(year: 2026, month: 9, day: 21),
                                         calendar: calendar, status: .noData,
                                         latestDayWithData: LooprDay(year: 2026, month: 9, day: 23),
                                         lastSyncedAt: Date(timeIntervalSince1970: 1_790_172_900), onSelect: { _ in })
        #expect(LooprDayEmptyState.title(for: onToday) == "Nothing for today yet")
        #expect(LooprDayEmptyState.detail(for: onToday, now: now) == "Today's numbers appear after your band syncs. Synced 11 h ago.")
        #expect(LooprDayEmptyState.suggestedDay(for: onToday) == LooprDay(year: 2026, month: 9, day: 23))

        let gap = LooprDayNavigation(day: LooprDay(year: 2026, month: 9, day: 22), today: today, earliest: nil,
                                     calendar: calendar, status: .noData,
                                     latestDayWithData: LooprDay(year: 2026, month: 9, day: 23), onSelect: { _ in })
        #expect(LooprDayEmptyState.title(for: gap) == "Nothing recorded on Tue 22 Sep")
        #expect(LooprDayEmptyState.detail(for: gap, now: now) == "Loopr has no band data for this day.")
        #expect(LooprDayEmptyState.suggestedDay(for: gap) == nil)

        let yesterday = LooprDayNavigation(day: LooprDay(year: 2026, month: 9, day: 23), today: today, earliest: nil,
                                           calendar: calendar, status: .noData,
                                           latestDayWithData: LooprDay(year: 2026, month: 9, day: 23), onSelect: { _ in })
        #expect(LooprDayEmptyState.title(for: yesterday) == "Nothing recorded yesterday")
        #expect(LooprDayEmptyState.suggestedDay(for: yesterday) == nil)

        let neverSynced = LooprDayNavigation(day: today, today: today, earliest: nil, calendar: calendar,
                                             status: .noData, onSelect: { _ in })
        #expect(LooprDayEmptyState.detail(for: neverSynced, now: now).hasPrefix("Wear your band"))
    }

    @Test func navigationEqualityIgnoresTheCallback() {
        let calendar = calendar("UTC")
        let today = LooprDay(year: 2026, month: 9, day: 24)
        let a = LooprDayNavigation(day: today, today: today, earliest: nil, calendar: calendar, onSelect: { _ in })
        let b = LooprDayNavigation(day: today, today: today, earliest: nil, calendar: calendar, onSelect: { _ in print("other") })
        #expect(a == b)
        let c = LooprDayNavigation(day: today, today: today, earliest: nil, calendar: calendar, status: .noData, onSelect: { _ in })
        #expect(a != c)
    }
}
