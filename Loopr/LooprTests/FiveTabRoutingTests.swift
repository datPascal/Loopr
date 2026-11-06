import AIKit
import Foundation
import NotificationKit
import Testing
@testable import Loopr

@MainActor
struct FiveTabRoutingTests {
    @Test func legacySelectionPreservesTheScreen() {
        #expect(MainTabLaunchState.restoring("sleep") == .init(tab: .data, healthPath: [.sleepHome]))
        #expect(MainTabLaunchState.restoring("heart") == .init(tab: .data, healthPath: [.heartHome]))
        #expect(MainTabLaunchState.restoring("body") == .init(tab: .data, healthPath: [.bodyHome]))
        #expect(MainTabLaunchState.restoring("workouts") == .init(tab: .fitness))
        #expect(MainTabLaunchState.restoring("future-tab") == .init(tab: .today))
        for tab in MainTab.allCases { #expect(MainTabLaunchState.restoring(tab.rawValue).tab == tab) }
    }

    @Test func oldExternalURLsResolveAlongsideNewTabs() throws {
        let links: [(String, ShellDeepLink)] = [("sleep", .sleepDetail), ("heart", .heartHome),
            ("heart/detail", .heartDetail), ("heart/trends", .heartTrends),
            ("workouts/detail", .workoutsDetail), ("workouts/intervals", .intervals), ("body", .bodyDetail), ("workouts", .fitnessHome),
            ("health", .dataHome), ("food", .foodHome), ("train", .fitnessHome), ("journal", .protocolHome)]
        for (path, expected) in links {
            #expect(ShellDeepLink(url: try #require(URL(string: "loopr://" + path))) == expected)
        }
        #expect(ShellDeepLink(url: URL(string: "https://example.com/sleep")!) == nil)
    }

    @Test func notificationsKeepTheirDomainDestination() {
        #expect(ShellDeepLink(notification: .sleep("2026-10-09")) == .sleepDetail)
        #expect(ShellDeepLink(notification: .heart("summary")) == .heartDetail)
        let workout = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
        #expect(ShellDeepLink(notification: .workout(workout.uuidString)) == .workout(workout))
        #expect(ShellDeepLink(notification: .journal("2026-10-09")) == .habitCheckIn("2026-10-09"))
    }

    @Test func originUsesTheSelectedDayInTheConsentPreview() async throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let origin = AskOrigin(screen: "HRV", day: "2026-10-09", date: date)
        let base = CapturingOriginContext()
        let result = try await OriginCoachContext(base: base, origin: origin)
            .summaryResult(sharing: .init(), at: date.addingTimeInterval(86_400))
        #expect(result.text == "Opened from HRV, selected day 2026-10-09.\nSaved measurements")
        #expect(result.daysWithData == 12)
        #expect(await base.date == date)
    }

    @Test func askFromAPastTodayReadsThatDayNotTheDayOfTheRequest() async throws {
        // Ask opened on Tue 10 Nov while today is later. The summary is built for the 10th, whatever time the
        // consent preview or the send asks for.
        let selected = Date(timeIntervalSince1970: 1_794_000_000)
        let origin = AskOrigin(screen: "Today", day: "2026-11-10", date: selected, dayLabel: "Tue 10 Nov", isPastDay: true)
        let base = CapturingOriginContext()
        let result = try await OriginCoachContext(base: base, origin: origin)
            .summaryResult(sharing: .init(), at: selected.addingTimeInterval(4 * 86_400))
        #expect(result.text.hasPrefix("Opened from Today, selected day 2026-11-10.\n"))
        #expect(await base.date == selected)
    }

    @Test func selectionIsPartOfCompleteLocalDeletion() {
        #expect(ProductRepositoryKeys.allOwnedDefaultsKeys.contains(MainTab.selectionKey))
    }
}

private actor CapturingOriginContext: LooprCoachContextSource {
    var date: Date?
    func summary(sharing: CoachSharing, at date: Date) -> String { "Saved measurements" }
    func summaryResult(sharing: CoachSharing, at date: Date) -> LooprCoachSummary {
        self.date = date
        return .init(text: "Saved measurements", daysWithData: 12)
    }
    func saveAdvice(message: CoachChatMessage, at date: Date) -> UUID { message.id }
}
