import Foundation
import Testing
@testable import DesignSystem

/// LV-10.4: the entrance intervals the performance UI suites measure. The names must match
/// `XCTOSSignpostMetric(name:)` in `EntrancePerformanceUITests`, and every begin needs one end.
@Suite(.serialized) struct LooprPerformanceSignpostsTests {
    @Test func subsystemAndCategoryMatchTheMetric() {
        #expect(LooprPerformanceSignposts.subsystem == "com.loopr.ios")
        #expect(LooprPerformanceSignposts.category == "performance")
    }

    @Test func everyTabHasItsOwnEntranceName() {
        let names = LooprColorFieldTab.allCases.map { LooprPerformanceSignposts.entranceMetricName(for: $0) }
        #expect(names == ["entrance.today", "entrance.food", "entrance.fitness", "entrance.protocol", "entrance.data"])
        #expect(Set(names).count == LooprColorFieldTab.allCases.count)
    }

    @Test func beginAndEndPairUp() {
        let name: StaticString = "entrance.test-pair"
        let before = LooprPerformanceSignposts.counts(of: name)
        let first = LooprPerformanceSignposts.beginAnimationInterval(name)
        let second = LooprPerformanceSignposts.beginAnimationInterval(name)
        let open = LooprPerformanceSignposts.counts(of: name)
        #expect(open.begun - before.begun == 2)
        #expect(open.ended - before.ended == 0)
        LooprPerformanceSignposts.endInterval(first)
        LooprPerformanceSignposts.endInterval(second)
        let closed = LooprPerformanceSignposts.counts(of: name)
        #expect(closed.begun - before.begun == 2)
        #expect(closed.ended - before.ended == 2)
    }

    @Test func entranceIntervalsOpenForTheFiveTabsOnly() {
        for tab in LooprColorFieldTab.allCases {
            let name = LooprPerformanceSignposts.entranceName(for: tab)
            let before = LooprPerformanceSignposts.counts(of: name)
            let interval = LooprPerformanceSignposts.beginEntrance(tab: tab.rawValue)
            #expect(interval != nil)
            #expect(LooprPerformanceSignposts.counts(of: name).begun - before.begun == 1)
            if let interval { LooprPerformanceSignposts.endInterval(interval) }
            #expect(LooprPerformanceSignposts.counts(of: name).ended - before.ended == 1)
        }
        // The note rail, the protocol strip and the gallery are not tabs.
        #expect(LooprPerformanceSignposts.beginEntrance(tab: "today-note-receipt") == nil)
        #expect(LooprPerformanceSignposts.beginEntrance(tab: "gallery") == nil)
    }

    #if DEBUG
    @Test func theResetArgumentForgetsEveryRecordedEntrance() throws {
        let suite = "loopr.entrance-reset-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let calendar = Calendar(identifier: .gregorian)
        let now: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_800_000_000) }
        let first = LooprEntranceStore(defaults: defaults, calendar: calendar, now: now, arguments: [])
        for tab in ["today", "food", "today-note-receipt"] { first.recordPlayed(tab) }
        defaults.set("kept", forKey: "loopr.other")
        // A relaunch without the argument keeps them.
        let kept = LooprEntranceStore(defaults: defaults, calendar: calendar, now: now, arguments: ["Loopr"])
        #expect(kept.hasPlayedToday("today"))
        // A relaunch with it plays every entrance again and leaves other defaults alone.
        let reset = LooprEntranceStore(defaults: defaults, calendar: calendar, now: now,
                                       arguments: ["Loopr", LooprEntranceStore.resetLaunchArgument])
        for tab in ["today", "food", "today-note-receipt"] {
            #expect(reset.shouldAnimate(tab, reduceMotion: false), Comment(rawValue: tab))
        }
        #expect(defaults.string(forKey: "loopr.other") == "kept")
        #expect(LooprEntranceStore.resetLaunchArgument == "--loopr-entrance-reset")
    }
    #endif
}
