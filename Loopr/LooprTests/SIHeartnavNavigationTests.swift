import Testing
import TodayKit
@testable import Loopr

@MainActor
struct SIHeartnavNavigationTests {
    @Test func rootsSelectTheirOwningTab() {
        #expect(TodayTabOwnership.tab(for: .sleep) == .sleep)
        #expect(TodayTabOwnership.tab(for: .heart) == .heart)
        #expect(TodayTabOwnership.tab(for: .body) == .body)
    }

    @Test func detailAndUtilityRoutesStillPush() {
        for route in TodayRoute.allCases where ![.sleep, .heart, .body].contains(route) {
            #expect(TodayTabOwnership.tab(for: route) == nil)
        }
    }

    #if DEBUG
    @Test func homeAndLegacyDeepLinksRemainTyped() {
        let routes: [(String, ShellDeepLink)] = [("today", .todayHome), ("heart", .heartHome),
            ("sleep", .sleepDetail), ("sleep/detail", .sleepDetail), ("body/detail", .bodyDetail),
            ("heart/detail", .heartDetail), ("phase06/heart-trends", .heartTrends)]
        for (raw, expected) in routes {
            #expect(ShellDeepLink.parse(arguments: ["--loopr-deep-link=\(raw)"]) == expected)
        }
    }
    #endif
}
