import Testing
import TodayKit
@testable import Loopr

/// LV-02 step 3: the strings that named the old tabs say Data, Fitness and Protocol, and Your data is a route on
/// Data's stack.
@MainActor
struct LongevityShellDataTests {
    @Test func yourDataRecordGroupsUseTheNewTabNames() {
        #expect(YourDataDomain.training.title == "Fitness")
        #expect(YourDataDomain.journal.title == "Protocol")
        #expect(YourDataDomain.band.title == "Band")
        #expect(YourDataDomain.food.title == "Food photos")
    }

    @Test func pinnedListLinkNamesData() {
        #expect(HealthPinnedSection.showAllTitle(total: 7, limit: 4) == "All 7 pinned numbers")
        #expect(HealthPinnedSection.showAllTitle(total: 4, limit: 4) == nil)
    }

    @Test func yourDataIsItsOwnRouteOnDatasStack() {
        let path: [AppHealthRoute] = [.sleepHome, .yourData]
        #expect(path.last == .yourData)
        #expect(AppHealthRoute.yourData != .recordsHome)
        #expect(Set<AppHealthRoute>([.yourData, .yourData]).count == 1)
    }
}
