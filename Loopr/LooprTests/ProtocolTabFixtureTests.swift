#if DEBUG
import DomainKit
import Foundation
import JournalKit
import RoutineKit
import Testing
@testable import Loopr

/// LV-07.1: the DEBUG Protocol fixture starts every launch from its seeded state, which `ProtocolTabUITests` relies on.
@MainActor struct ProtocolTabFixtureTests {
    private let zone = TimeZone(identifier: "UTC")!
    /// The fixture clock: Tue 14 Nov 2023, 22:13 UTC.
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let tuesday = DayIdentity(year: 2023, month: 11, day: 14)

    private func loader(_ store: RoutineStore) -> ProtocolTabLoader {
        let zone = zone
        return ProtocolTabLoader(store: store, timeZone: { zone },
                                 snapshots: { day, zone, now in ProtocolTabFixture.snapshots(day: day, timeZone: zone, now: now) },
                                 locale: Locale(identifier: "en_GB"))
    }

    /// Today's rosette, counting the rules due today as Today's list does (ICP R4 Q3): the blood panel waits for February.
    private func today(_ store: RoutineStore) async throws -> ProtocolDayPresentation {
        let data = try #require(await loader(store).load(now: now).routineData)
        let input = try #require(data.countedToday)
        return ProtocolDayPresentation.make(input, week: ProtocolWeekCalendar(timeZone: zone, locale: Locale(identifier: "en_GB")))
    }

    @Test func aNewStoreDropsEverythingAnEarlierLaunchAnswered() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("protocol-fixture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let leftover = directory.appendingPathComponent("loopr-protocol-fixture-\(UUID().uuidString.lowercased()).sqlite")
        #expect(FileManager.default.createFile(atPath: leftover.path, contents: Data("old".utf8)))

        // The first launch answers Magnesium, then ends: its store is released before the next launch opens one.
        do {
            let first = try ProtocolTabFixture.makeStore(in: directory, now: now, timeZone: zone)
            #expect(!FileManager.default.fileExists(atPath: leftover.path), "A fixture file from an older build is removed")
            #expect(try await today(first).accessibilitySummary == "Today, Tuesday, 3 of 10 rules kept, 6 pending, 1 not known")
            try await loader(first).tick("magnesium", day: tuesday, now: now)
            #expect(try await today(first).accessibilitySummary == "Today, Tuesday, 4 of 10 rules kept, 5 pending, 1 not known")
        }

        let second = try ProtocolTabFixture.makeStore(in: directory, now: now, timeZone: zone)
        let active = try #require(try second.activeProtocol())
        #expect(try second.protocols().count == 1, "The new launch holds one protocol, not two")
        // Before anything evaluates today, the new store holds no answer for Magnesium at all.
        #expect(try second.check(protocolID: active.routineProtocol.id, ruleKey: "magnesium", day: tuesday) == nil)
        #expect(try await today(second).accessibilitySummary == "Today, Tuesday, 3 of 10 rules kept, 6 pending, 1 not known")
        // Evaluating today stores what the rule is now: still open.
        #expect(try second.check(protocolID: active.routineProtocol.id, ruleKey: "magnesium", day: tuesday)?.state == .pending)
    }

    @Test func undoOnTheFixtureReturnsTodayToItsSeededState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("protocol-fixture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ProtocolTabFixture.makeStore(in: directory, now: now, timeZone: zone)
        let active = try #require(try store.activeProtocol())
        try await loader(store).tick("magnesium", day: tuesday, now: now)
        #expect(try store.check(protocolID: active.routineProtocol.id, ruleKey: "magnesium", day: tuesday)?.state == .kept)
        try await loader(store).clear("magnesium", day: tuesday, now: now)
        // Undo removes the tick and evaluates the day again: the rule is open, and no manual answer is left.
        let undone = try #require(try store.check(protocolID: active.routineProtocol.id, ruleKey: "magnesium", day: tuesday))
        #expect(undone.state == .pending)
        #expect(!undone.overriddenByPerson)
        #expect(try await today(store).accessibilitySummary == "Today, Tuesday, 3 of 10 rules kept, 6 pending, 1 not known")
    }
}
#endif
