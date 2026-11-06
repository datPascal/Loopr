import Foundation
import NotificationKit
import SettingsKit
import Testing
import TodayKit
@testable import Loopr

/// LV-02 step 2: every link build 21 accepted still resolves, the new tab names resolve, and the saved
/// selection restores under both the stored strings and the new names.
@MainActor
struct LongevityShellRoutesTests {
    private func link(_ string: String) -> ShellDeepLink? { URL(string: string).flatMap { ShellDeepLink(url: $0) } }

    @Test func everyBuild21URLHostStillResolves() {
        let expected: [(String, ShellDeepLink)] = [
            ("loopr://today", .todayHome),
            ("loopr://food", .foodHome),
            ("loopr://health", .dataHome),
            ("loopr://journal", .protocolHome),
            ("loopr://train", .fitnessHome),
            ("loopr://workouts", .fitnessHome),
            ("loopr://train/detail", .workoutsDetail),
            ("loopr://workouts/detail", .workoutsDetail),
            ("loopr://train/intervals", .intervals),
            ("loopr://workouts/intervals", .intervals),
            ("loopr://intervals", .intervals),
            ("loopr://sleep", .sleepDetail),
            ("loopr://heart", .heartHome),
            ("loopr://heart/detail", .heartDetail),
            ("loopr://heart/trends", .heartTrends),
            ("loopr://body", .bodyDetail),
            ("loopr://breathing", .breathing(start: false, bandPacing: false)),
            ("loopr://breathing?start=true&band=true", .breathing(start: true, bandPacing: true)),
            ("loopr://breathing?start=true", .breathing(start: true, bandPacing: false)),
        ]
        for (url, route) in expected { #expect(link(url) == route, "\(url)") }
    }

    @Test func theNewTabHostsOpenTheirTabs() {
        #expect(link("loopr://fitness") == .fitnessHome)
        #expect(link("loopr://fitness/detail") == .workoutsDetail)
        #expect(link("loopr://fitness/intervals") == .intervals)
        #expect(link("loopr://protocol") == .protocolHome)
        #expect(link("loopr://data") == .dataHome)
    }

    @Test func newAndOldHostsReachTheSameRoute() {
        #expect(link("loopr://fitness") == link("loopr://train"))
        #expect(link("loopr://fitness") == link("loopr://workouts"))
        #expect(link("loopr://protocol") == link("loopr://journal"))
        #expect(link("loopr://data") == link("loopr://health"))
    }

    @Test func hostsAreCaseInsensitiveAndUnknownOnesAreIgnored() {
        #expect(link("LOOPR://Protocol") == .protocolHome)
        #expect(link("loopr://Data") == .dataHome)
        #expect(link("loopr://settings") == nil)
        #expect(link("loopr://") == nil)
        #expect(link("https://example.com/data") == nil)
        #expect(link("looprx://data") == nil)
    }

    @Test func widgetIntentAndQuickActionURLsParse() {
        // The URLs the widgets, App Intents and quick actions open. None names a renamed tab.
        #expect(link("loopr://today") == .todayHome)
        #expect(link("loopr://intervals") == .intervals)
        #expect(link("loopr://breathing?start=true&band=true") == .breathing(start: true, bandPacing: true))
        #expect(link("loopr://breathing?start=true&band=false") == .breathing(start: true, bandPacing: false))
    }

    @Test func everyNotificationLinkKeepsItsDestination() {
        let workout = UUID(uuidString: "00000000-0000-0000-0000-000000000701")!
        let chat = UUID(uuidString: "00000000-0000-0000-0000-000000000702")!
        let expected: [(NotificationDeepLink, ShellDeepLink)] = [
            (.today("day"), .todayDetail),
            (.heart("sample"), .heartDetail),
            (.goals("goal"), .goals),
            (.workout(workout.uuidString), .workout(workout)),
            (.workout("not-an-id"), .workout(nil)),
            (.journal("2026-10-09"), .habitCheckIn("2026-10-09")),
            (.journal("insights"), .habitInsights),
            (.coach("briefing"), .coach),
            (.coach(chat.uuidString), .coachChat(chat)),
            (.sleep("day"), .sleepDetail),
            (.hydration("day"), .todayDetail),
            (.device("strap"), .settings(.deviceCenter)),
            (.stress("session"), .stress),
            (.cycle("day"), .settings(.cycle)),
            (.heartAlert("alert"), .settings(.heartAlerts)),
            (.ask("reminder"), .coach),
            (.patterns("test"), .patterns),
        ]
        for (input, route) in expected { #expect(ShellDeepLink(notification: input) == route, "\(input)") }
    }

    @Test func aStoredSelectionRestoresUnderTheStoredAndTheNewNames() {
        let expected: [(String, MainTab, [AppHealthRoute])] = [
            ("train", .fitness, []), ("fitness", .fitness, []), ("workouts", .fitness, []),
            ("journal", .protocol, []), ("protocol", .protocol, []),
            ("health", .data, []), ("data", .data, []),
            ("sleep", .data, [.sleepHome]), ("heart", .data, [.heartHome]), ("body", .data, [.bodyHome]),
            ("today", .today, []), ("food", .food, []),
        ]
        for (raw, tab, path) in expected {
            #expect(MainTabLaunchState.restoring(raw) == .init(tab: tab, healthPath: path), "\(raw)")
        }
    }

    @Test func theStoredStringsStayTheRawValues() {
        #expect(MainTab.fitness.rawValue == "train")
        #expect(MainTab.protocol.rawValue == "journal")
        #expect(MainTab.data.rawValue == "health")
        #expect(MainTab(rawValue: "train") == .fitness)
        #expect(MainTab(rawValue: "journal") == .protocol)
        #expect(MainTab(rawValue: "health") == .data)
    }

    @Test func todayRoutesAndRowsOpenTheRenamedTabs() {
        #expect(TodayTabOwnership.tab(for: .sleep) == .data)
        #expect(TodayTabOwnership.tab(for: .heart) == .data)
        #expect(TodayTabOwnership.tab(for: .body) == .data)
        #expect(TodayTabOwnership.tab(for: .coach) == nil)
        #expect(TodayAgentDestination.destination(for: .yourDayRow("train")) == .tab(.fitness))
        #expect(TodayAgentDestination.destination(for: .yourDayRow("journal")) == .tab(.protocol))
        #expect(TodayAgentDestination.destination(for: .timelineItem("workout-planned")) == .tab(.fitness))
    }

    #if DEBUG
    @Test func everyDebugLaunchLinkStillParses() {
        func parse(_ link: String) -> ShellDeepLink? { ShellDeepLink.parse(arguments: ["--loopr-deep-link=" + link]) }
        let expected: [(String, ShellDeepLink)] = [
            ("today", .todayHome), ("food", .foodHome), ("health", .dataHome), ("journal", .protocolHome),
            ("train", .fitnessHome), ("workouts", .fitnessHome), ("workouts/detail", .workoutsDetail),
            ("workouts/intervals", .intervals), ("sleep", .sleepDetail), ("sleep/detail", .sleepDetail),
            ("heart", .heartHome), ("heart/detail", .heartDetail), ("phase06/heart-trends", .heartTrends),
            ("body", .bodyDetail), ("body/detail", .bodyDetail),
            ("journal/habit-insights", .habitInsights), ("journal/habit-setup", .habitSetup),
            ("journal/habit-management", .habitManagement), ("journal/habit-history", .habitHistory),
            ("journal/habit-detail", .habitDetail), ("phase06/records-detail", .recordsDetail),
            ("phase06/records-recap", .recordsRecap),
            // The new names.
            ("fitness", .fitnessHome), ("protocol", .protocolHome), ("data", .dataHome),
        ]
        for (link, route) in expected { #expect(parse(link) == route, "\(link)") }
        #expect(parse("nonsense") == nil)
        #expect(ShellDeepLink.parse(arguments: ["--other"]) == nil)
    }
    #endif
}
