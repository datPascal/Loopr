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
        #expect(LooprHeaderMeta.dayPhrase(navigation(today)) == "THU 24 SEP")
        #expect(LooprHeaderMeta.dayPhrase(navigation(LooprDay(year: 2026, month: 9, day: 23))) == "YESTERDAY · WED 23 SEP")
        #expect(LooprHeaderMeta.dayPhrase(navigation(LooprDay(year: 2026, month: 9, day: 21))) == "MON 21 SEP")
    }

    @Test func nightPhraseIsLastNightOnTodayAndTheRangeOtherwise() {
        #expect(LooprHeaderMeta.nightPhrase(navigation(today)) == "LAST NIGHT")
        #expect(LooprHeaderMeta.nightPhrase(navigation(LooprDay(year: 2026, month: 9, day: 23))) == "TUE 22 → WED 23 SEP")
    }

    @Test func freshnessFollowsTheBandIndicator() {
        let now = lastSync.addingTimeInterval(5 * 60)
        let sync = LooprHeaderFreshness.sync(lastSync: lastSync)

        #expect(LooprHeaderMeta.freshness(sync, indicator: nil, now: now)
                == .init(text: "SYNCED 5 MIN AGO", isActive: false))
        #expect(LooprHeaderMeta.freshness(sync, indicator: .init(link: .syncing), now: now)
                == .init(text: "SYNCING", isActive: true))
        #expect(LooprHeaderMeta.freshness(sync, indicator: .init(link: .notPaired), now: now) == nil)
        // A reconnect or a disconnect leaves the age alone; the badge carries it.
        #expect(LooprHeaderMeta.freshness(sync, indicator: .init(link: .disconnected), now: now)?.text
                == "SYNCED 5 MIN AGO")
        // The newer of the two sync times wins.
        let newer = LooprBandIndicator(link: .connected, lastSyncedAt: now.addingTimeInterval(-60))
        #expect(LooprHeaderMeta.freshness(sync, indicator: newer, now: now)?.text == "SYNCED 1 MIN AGO")
        #expect(LooprHeaderMeta.freshness(.live, indicator: .init(link: .syncing), now: now)
                == .init(text: "LIVE", isActive: true))
        #expect(LooprHeaderMeta.freshness(.hidden, indicator: nil, now: now) == nil)
        #expect(LooprHeaderMeta.freshness(.sync(lastSync: nil), indicator: nil, now: now) == nil)
    }

    @Test func pinnedClockWinsOverTheRealOne() {
        let pinned = lastSync.addingTimeInterval(2 * 60)
        let freshness = LooprHeaderMeta.freshness(.sync(lastSync: lastSync, now: pinned), indicator: nil,
                                                  now: lastSync.addingTimeInterval(9_000))
        #expect(freshness?.text == "SYNCED 2 MIN AGO")
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
        #expect(LooprRadius.surface(isDark: true) == LooprRadius.compactCard)
        #expect(LooprRadius.surface(isDark: false) == LooprRadius.card)
        // The header text lines up with the text inside a card.
        #expect(LooprSpacing.headerHorizontal == LooprSpacing.screenGutter + 4)
    }
}
