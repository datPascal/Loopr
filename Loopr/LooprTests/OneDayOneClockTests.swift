#if DEBUG
import DomainKit
import Foundation
import JournalKit
import RoutineKit
import Testing
import TodayKit
@testable import Loopr

/// ICP R3-OPT-1, R3-OPT-2, R3-OPT-5: one fixture launch has one clock. Today's rail, the Protocol tab, Food and Fitness
/// read it, so Today and Protocol count the same kept rules at the morning and evening clocks, and a rule edit saved on
/// Protocol is in force on Today the moment it is saved.
@MainActor struct OneDayOneClockTests {
    private let populated = AppEnvironment.make(arguments: ["--loopr-launch-mode=populated"], environment: [:])

    private func clock(_ name: String) -> (now: Date, calendar: Calendar) {
        TodayDialFixtureClock.clock(environment: populated, arguments: ["--loopr-today-clock=\(name)"])
    }

    private func stores(_ clock: (now: Date, calendar: Calendar)) throws -> (ProtocolTabFixture.Stores, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("one-clock-\(UUID().uuidString)")
        return (try ProtocolTabFixture.makeStores(in: directory, now: clock.now, timeZone: clock.calendar.timeZone), directory)
    }

    private func protocolLoader(_ store: RoutineStore, zone: TimeZone) -> ProtocolTabLoader {
        ProtocolTabLoader(store: store, timeZone: { zone },
                          snapshots: { day, zone, now in ProtocolTabFixture.snapshots(day: day, timeZone: zone, now: now) },
                          locale: Locale(identifier: "en_GB"))
    }

    private func todayDay(_ store: RoutineStore, _ clock: (now: Date, calendar: Calendar)) async throws -> TodayRailProtocolDay {
        let day = populated.productDay(fixture: TodayFixtures.day)
        return try #require(try await TodayNoteRailReaders.protocolDay(
            store: store, day: day, now: clock.now, zone: clock.calendar.timeZone) { day, zone, now in
                ProtocolTabFixture.snapshots(day: day, timeZone: zone, now: now)
            })
    }

    private func kept(_ day: TodayRailProtocolDay) -> Set<RuleKey> {
        Set(day.checks.filter { $0.state == .kept }.map(\.ruleKey))
    }

    @Test func theProtocolTabReadsTodaysClockAndZone() {
        let repositories = ProductRepositoryContainer(environment: populated)
        let today = TodayDialLoader(environment: populated, repositories: repositories, history: EmptyMetricHistoryProvider())
            .clock(for: TodayFixtures.day)
        let tab = ProtocolTabComposition.clock(repositories: repositories)
        #expect(tab.now() == today.now)
        #expect(tab.timeZone == today.calendar.timeZone)
        // Food keeps its own zone but reads the same hour.
        var perth = Calendar(identifier: .gregorian)
        perth.timeZone = TimeZone(identifier: "Australia/Perth")!
        let food = TodayDialFixtureClock.now(sameDayAs: today.now, calendar: perth, arguments: [])
        let foodParts = perth.dateComponents([.hour, .minute], from: food)
        let todayParts = today.calendar.dateComponents([.hour, .minute], from: today.now)
        #expect(foodParts.hour == todayParts.hour && foodParts.minute == todayParts.minute)
    }

    @Test(arguments: [("morning", 1), ("evening", 3)])
    func todayAndProtocolKeepTheSameRules(_ name: String, keptCount: Int) async throws {
        let clock = clock(name)
        let (stores, directory) = try stores(clock)
        defer { try? FileManager.default.removeItem(at: directory) }
        let zone = clock.calendar.timeZone

        let today = try await todayDay(stores.routine, clock)
        let data = try #require(await protocolLoader(stores.routine, zone: zone).load(now: clock.now).routineData)
        let input = try #require(data.todayInput)
        let onProtocol = Set(input.rules.filter { $0.state == .kept }.map(\.rule.key))

        #expect(kept(today) == onProtocol, "Today \(kept(today)), Protocol \(onProtocol)")
        #expect(onProtocol.count == keptCount)
        if name == "morning" {
            // The 18:30 kitchen limit is still ahead in the morning.
            #expect(!onProtocol.contains("kitchen-closed"))
        }
    }

    @Test func aRaisedTargetIsCheckedAgainstTheNewAmountOnBothTabs() async throws {
        let clock = clock("evening")
        let (stores, directory) = try stores(clock)
        defer { try? FileManager.default.removeItem(at: directory) }
        let zone = clock.calendar.timeZone
        let loader = protocolLoader(stores.routine, zone: zone)
        #expect(kept(try await todayDay(stores.routine, clock)).contains("morning-light"), "22 min keeps the 10-minute rule")

        let active = try #require(try stores.routine.activeProtocol())
        let raised = active.latestVersion.rules.map { rule -> ProtocolRule in
            guard rule.key == "morning-light" else { return rule }
            return rule.with(title: "Morning light, 30 min",
                             target: RuleTarget(kind: .atLeast, metric: RoutineMetric.daylightMinutes.rawValue, value: 30, unit: "min"))
        }
        _ = try await loader.saveRules(raised, now: clock.now)

        let today = try await todayDay(stores.routine, clock)
        let light = try #require(today.checks.first { $0.ruleKey == "morning-light" })
        #expect(light.state != .kept, "22 of 30 min is not kept")
        #expect(today.rules.first { $0.key == "morning-light" }?.target.value == 30, "the row's target is the one the check read")
        let input = try #require(await loader.load(now: clock.now).routineData?.todayInput)
        #expect(input.rules.first { $0.rule.key == "morning-light" }?.state == light.state)
        #expect(input.rules.filter { $0.state == .kept }.count == 2)
    }
}
#endif
