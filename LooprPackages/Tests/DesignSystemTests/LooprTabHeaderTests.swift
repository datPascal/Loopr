import Foundation
import SwiftUI
import Testing
#if canImport(UIKit)
import UIKit
#endif
@testable import DesignSystem

struct LooprTabHeaderTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Perth")!
        return calendar
    }()
    private let today = LooprDay(year: 2026, month: 9, day: 24)
    /// 23 Sep 22:15 in Perth.
    private let lastSync = Date(timeIntervalSince1970: 1_790_172_900)

    private func navigation(_ day: LooprDay) -> LooprDayNavigation {
        LooprDayNavigation(day: day, today: today, earliest: nil, calendar: calendar, onSelect: { _ in })
    }

    @Test func dayPhraseIsTheDateOnTodayAndNamesOtherDays() {
        #expect(LooprHeaderMeta.dayPhrase(navigation(today)) == "Thu 24 Sep")
        #expect(LooprHeaderMeta.dayPhrase(navigation(LooprDay(year: 2026, month: 9, day: 23))) == "Yesterday · Wed 23 Sep")
        #expect(LooprHeaderMeta.dayPhrase(navigation(LooprDay(year: 2026, month: 9, day: 21))) == "Mon 21 Sep")
    }

    @Test func nightPhraseIsLastNightOnTodayAndTheRangeOtherwise() {
        #expect(LooprHeaderMeta.nightPhrase(navigation(today)) == "Last night")
        #expect(LooprHeaderMeta.nightPhrase(navigation(LooprDay(year: 2026, month: 9, day: 23))) == "Tue 22 → Wed 23 Sep")
    }

    @Test func freshnessFollowsTheBandIndicator() {
        let now = lastSync.addingTimeInterval(5 * 60)
        let sync = LooprHeaderFreshness.sync(lastSync: lastSync)

        #expect(LooprHeaderMeta.freshness(sync, indicator: nil, now: now)
                == .init(text: "Synced 5 min ago", isActive: false))
        #expect(LooprHeaderMeta.freshness(sync, indicator: .init(link: .syncing), now: now)
                == .init(text: "Syncing", isActive: true))
        #expect(LooprHeaderMeta.freshness(sync, indicator: .init(link: .notPaired), now: now) == nil)
        // A reconnect or a disconnect leaves the age alone; the badge carries it.
        #expect(LooprHeaderMeta.freshness(sync, indicator: .init(link: .disconnected), now: now)?.text
                == "Synced 5 min ago")
        // The newer of the two sync times wins.
        let newer = LooprBandIndicator(link: .connected, lastSyncedAt: now.addingTimeInterval(-60))
        #expect(LooprHeaderMeta.freshness(sync, indicator: newer, now: now)?.text == "Synced 1 min ago")
        #expect(LooprHeaderMeta.freshness(.live, indicator: .init(link: .syncing), now: now)
                == .init(text: "Live", isActive: true))
        #expect(LooprHeaderMeta.freshness(.hidden, indicator: nil, now: now) == nil)
        #expect(LooprHeaderMeta.freshness(.sync(lastSync: nil), indicator: nil, now: now) == nil)
    }

    @Test func pinnedClockWinsOverTheRealOne() {
        let pinned = lastSync.addingTimeInterval(2 * 60)
        let freshness = LooprHeaderMeta.freshness(.sync(lastSync: lastSync, now: pinned), indicator: nil,
                                                  now: lastSync.addingTimeInterval(9_000))
        #expect(freshness?.text == "Synced 2 min ago")
    }

    @Test func metaLineJoinsWithOneSeparator() {
        let freshness = LooprHeaderMeta.Freshness(text: "SYNCED 2 MIN AGO", isActive: false)
        #expect(LooprHeaderMeta.line(dayPhrase: "TUE 14 NOV", freshness: freshness) == "TUE 14 NOV · SYNCED 2 MIN AGO")
        #expect(LooprHeaderMeta.line(dayPhrase: "TUE 14 NOV", freshness: nil) == "TUE 14 NOV")
        #expect(LooprHeaderMeta.line(dayPhrase: nil, freshness: freshness) == "SYNCED 2 MIN AGO")
    }

    @Test func bandButtonSpeaksOnlyWhatIsKnown() {
        #expect(LooprBandButtonStyle.spokenLabel(percent: nil, charging: nil) == "Open settings")
        #expect(LooprBandButtonStyle.spokenLabel(percent: nil, charging: true) == "Open settings, charging")
        #expect(LooprBandButtonStyle.spokenLabel(for: LooprBandIndicator(link: .connected, onWrist: false))
            == "Open settings, off wrist")
        #expect(LooprBandButtonStyle.spokenLabel(percent: 64, charging: false) == "Open settings, band battery 64 percent")
        #expect(LooprBandButtonStyle.spokenLabel(percent: 64, charging: true, link: .syncing)
                == "Open settings, band battery 64 percent, charging, syncing")
        #expect(LooprBandButtonStyle.spokenLabel(percent: nil, charging: nil, link: .bluetoothOff)
                == "Open settings, Bluetooth is off")
        #expect(LooprBandButtonStyle.spokenLabel(percent: 120, charging: nil, link: .reconnecting)
                == "Open settings, band battery 100 percent")
    }

    @Test func badgeStaysQuietForCalmStates() {
        #expect(LooprBandButtonStyle.badge(for: .connected) == nil)
        #expect(LooprBandButtonStyle.badge(for: .reconnecting) == nil)
        #expect(LooprBandButtonStyle.badge(for: .notPaired) == nil)
        #expect(LooprBandButtonStyle.badge(for: nil) == nil)
        #expect(LooprBandButtonStyle.badge(for: .syncing) == .syncing)
        #expect(LooprBandButtonStyle.badge(for: .disconnected) == .disconnected)
        #expect(LooprBandButtonStyle.badge(for: .bluetoothOff) == .bluetoothOff)
        #expect(LooprBandButtonStyle.badge(for: .needsAttention) == .needsAttention)
    }

    @Test func batteryRingUsesLevelTokens() {
        #expect(LooprBandButtonStyle.batteryTone(percent: 64) == .recoveryHigh)
        #expect(LooprBandButtonStyle.batteryTone(percent: 20) == .strain)
        #expect(LooprBandButtonStyle.batteryTone(percent: 10) == .critical)
    }

    @Test func batteryRingDimsOnlyWhileTheBandIsNotLinked() {
        #expect(!LooprBandButtonStyle.batteryIsStale(for: .connected))
        #expect(!LooprBandButtonStyle.batteryIsStale(for: .syncing))
        #expect(!LooprBandButtonStyle.batteryIsStale(for: nil))
        #expect(LooprBandButtonStyle.batteryIsStale(for: .reconnecting))
        #expect(LooprBandButtonStyle.batteryIsStale(for: .disconnected))
        #expect(LooprBandButtonStyle.batteryIsStale(for: .bluetoothOff))
        #expect(LooprBandButtonStyle.batteryIsStale(for: .needsAttention))
    }

    #if canImport(UIKit)
    @Test @MainActor
    func batteryTrackColorCanResolveOnTheRenderingExecutor() async {
        DesignSystemRuntime.reset()
        defer { DesignSystemRuntime.reset() }
        let color = LooprBatteryColors.darkTrack
        let alphas = await Task.detached {
            [UIAccessibilityContrast.normal, .high].map { contrast in
                let traits = UITraitCollection(traitsFrom: [
                    UITraitCollection(userInterfaceStyle: .dark),
                    UITraitCollection(accessibilityContrast: contrast)
                ])
                return color.resolvedColor(with: traits).cgColor.alpha
            }
        }.value
        #expect(abs(alphas[0] - 0.16) < 0.0001)
        #expect(abs(alphas[1] - 0.24) < 0.0001)
    }
    #endif

    @Test func scrollRestingInsideTheCollapseRangeSnapsToTheNearerEnd() {
        #expect(LooprHeaderSnap.adjustment(travelled: 0) == nil)
        #expect(LooprHeaderSnap.adjustment(travelled: 44) == nil)
        #expect(LooprHeaderSnap.adjustment(travelled: 300) == nil)
        #expect(LooprHeaderSnap.adjustment(travelled: 10) == -10)
        #expect(LooprHeaderSnap.adjustment(travelled: 30) == 14)
    }

    @Test func cardDensitiesUseTheSharedTokens() {
        #expect(LooprCardDensity.regular.insets.top == LooprSpacing.cardVertical)
        #expect(LooprCardDensity.regular.insets.leading == LooprSpacing.cardHorizontal)
        #expect(LooprCardDensity.compact.insets.leading == LooprSpacing.compactCardHorizontal)
        #expect(LooprCardDensity.flush.insets == EdgeInsets())
        #expect(LooprRadius.surface(isDark: true) == LooprRadius.card)
        #expect(LooprRadius.surface(isDark: false) == LooprRadius.card)
        // The header text lines up with the text inside a card.
        #expect(LooprSpacing.headerHorizontal == LooprSpacing.screenGutter + 4)
    }

    @MainActor
    @Test func secondaryActionDefaultsToNilAndSurvivesAlongsideADayControl() {
        let plain = LooprTabHeaderContent(title: "Today", accent: .brand)
        #expect(plain.secondaryAction == nil)
        let action = LooprHeaderAction(symbol: "sparkles", label: "Ask your coach", identifier: "x") {}
        let content = LooprTabHeaderContent(
            title: "Today", accent: .brand, control: .day(navigation(today)), secondaryAction: action)
        #expect(content.secondaryAction?.identifier == "x")
        if case .day = content.control {} else { Issue.record("the day control was replaced") }
    }

    // MARK: Top row

    @Test func theTopRowStaysOneRowWhileTheTitleFitsAtEightyFivePercent() {
        // 354 pt is a 402 pt iPhone less the header's two 24 pt insets.
        #expect(LooprHeaderTopRow.arrangement(width: 354, title: 70, cluster: 177, band: 56) == .oneRow)
        // Room for 85 % of the title keeps one row; a title a point wider than that moves the controls down.
        let room: CGFloat = 354 - 177 - 56 - LooprSpacing.headerClusterSpacing - LooprSpacing.sm
        #expect(LooprHeaderTopRow.arrangement(width: 354, title: (room - 0.5) / 0.85, cluster: 177, band: 56) == .oneRow)
        #expect(LooprHeaderTopRow.arrangement(width: 354, title: room / 0.85 + 1, cluster: 177, band: 56) == .twoRows)
        #expect(LooprHeaderTopRow.arrangement(width: .infinity, title: 900, cluster: 177, band: 56) == .oneRow)
        // The last resort lets the title go to 72 % before the controls move down.
        let wide = room / 0.85 + 1
        #expect(LooprHeaderTopRow.arrangement(width: 354, title: wide, cluster: 177, band: 56,
                                              titleScale: LooprHeaderTopRow.lastResortTitleScale) == .oneRow)
        #expect(LooprHeaderTopRow.arrangement(width: 354, title: room / 0.72 + 1, cluster: 177, band: 56,
                                              titleScale: LooprHeaderTopRow.lastResortTitleScale) == .twoRows)
    }

    #if canImport(UIKit)
    /// The height of the header for `content`, laid out 402 pt wide at the default text size.
    @MainActor private func height(_ content: LooprTabHeaderContent) -> CGFloat {
        let host = UIHostingController(rootView: LooprTabHeader(content).environment(\.dynamicTypeSize, .large))
        return host.sizeThatFits(in: CGSize(width: 402, height: 1_000)).height
    }

    @MainActor private func ask(_ id: String) -> LooprHeaderAction {
        LooprHeaderAction(symbol: "sparkles", label: "Ask", identifier: id) {}
    }

    /// Each tab with the controls it has keeps one row at the default size; a past day's Today pill moves Today's
    /// shortcut and day control under the title instead of cutting "Today".
    @MainActor @Test func eachTabKeepsOneRowAtTheDefaultSizeAndOnAPastDay() {
        let past = navigation(LooprDay(year: 2026, month: 9, day: 22))
        let plus = LooprHeaderAction(symbol: "plus", label: "Start a workout", identifier: "start") {}
        let tabs: [(LooprTabHeaderContent, String)] = [
            (LooprTabHeaderContent(title: "Today", accent: .brand, control: .day(navigation(today)), secondaryAction: ask("today")), "Today"),
            (LooprTabHeaderContent(title: "Food", accent: .energy, control: .day(navigation(today))), "Food"),
            (LooprTabHeaderContent(title: "Fitness", accent: .strain, control: .action(plus), secondaryAction: ask("fitness")), "Fitness"),
            (LooprTabHeaderContent(title: "Protocol", accent: .protocol, secondaryAction: ask("protocol")), "Protocol"),
            (LooprTabHeaderContent(title: "Data", accent: .brand, control: .day(navigation(today)), secondaryAction: ask("data")), "Data")
        ]
        // One row may grow to the 56 pt controls' height; a wrapped second row adds a whole control row on top.
        for (content, title) in tabs {
            let bare = height(LooprTabHeaderContent(title: title, accent: content.accent))
            #expect(height(content) < bare + 30, "\(title) wrapped its controls")
        }
        // A past day adds the Today pill. The controls stay on the title's row (the shortcut drops its word, then the
        // title shrinks to 80 %): a second row under the title read as a broken header (Pascal, 2026-11-03).
        for title in ["Today", "Data"] {
            let pastDay = LooprTabHeaderContent(title: title, accent: .brand, control: .day(past), secondaryAction: ask(title))
            let bare = height(LooprTabHeaderContent(title: title, accent: .brand))
            #expect(height(pastDay) < bare + 30, "\(title) wrapped its controls on a past day")
        }
    }
    #endif

    /// The tab bar's backing hides scrolled text under the labels, and turns solid with Reduce Transparency
    /// (R1-NEW-13).
    @MainActor @Test func tabBarScrimIsStrongUnderTheLabelsAndSolidWithReduceTransparency() {
        #expect(LooprTabBarScrim.strength(isDark: false, reduceTransparency: false) >= 0.85)
        #expect(LooprTabBarScrim.strength(isDark: true, reduceTransparency: false) >= 0.85)
        #expect(LooprTabBarScrim.strength(isDark: false, reduceTransparency: true) == 1)
        #expect(LooprTabBarScrim.strength(isDark: true, reduceTransparency: true) == 1)
    }
}
