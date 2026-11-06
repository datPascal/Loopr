#if DEBUG
import DomainKit
import Foundation
import JournalKit
import RoutineKit
import Testing
@testable import Loopr

/// LV-07.3: the Protocol tab loader maps stored experiments to the running card, the finished rows and the result, and
/// Keep saves the next protocol version once. It runs on the DEBUG fixture (`ProtocolTabFixture`), which
/// `ProtocolExperimentUITests` also uses.
@MainActor struct ProtocolExperimentLoaderTests {
    private let zone = TimeZone(identifier: "UTC")!
    /// The fixture clock: Tue 14 Nov 2023, 22:13 UTC.
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private final class Context {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("protocol-experiments-\(UUID().uuidString)")
        let stores: ProtocolTabFixture.Stores
        init(now: Date, zone: TimeZone) throws {
            stores = try ProtocolTabFixture.makeStores(in: directory, now: now, timeZone: zone)
        }
        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    private func loader(_ stores: ProtocolTabFixture.Stores, experiments: Bool = true) -> ProtocolTabLoader {
        let zone = zone
        return ProtocolTabLoader(store: stores.routine, timeZone: { zone },
                                 snapshots: { day, zone, now in ProtocolTabFixture.snapshots(day: day, timeZone: zone, now: now) },
                                 locale: Locale(identifier: "en_GB"),
                                 experiments: experiments ? stores.experiments : nil,
                                 experimentInputs: { ProtocolTabFixture.experimentInputs($0) })
    }

    private func experimentData(_ loader: ProtocolTabLoader) async throws -> ProtocolExperimentsData {
        let content = await loader.load(now: now)
        return try #require(content.experimentData)
    }

    /// ICP R2-OPT-14: Patterns names the running experiment and its outcome before a second test starts on those nights.
    @Test func patternsNamesTheExperimentThatIsRunning() throws {
        let context = try Context(now: now, zone: zone)
        let running = try #require(try context.stores.experiments.running())
        #expect(PatternsRunningExperiment(running).warning
            == "Magnesium glycinate, 300 mg is running on deep sleep. A pattern test on the same nights mixes the two results.")
        // ICP R2-SEN-12: a blocked Try says the day it can start, with no quote glyphs (R2-DES-13). Night 9 of 14 is Tue
        // 14 Nov, so the last night is 19 Nov and the test ends on 20 Nov.
        #expect(PatternsCopy.startsAfter(PatternsRunningExperiment(running))
            == "You can start this after the magnesium test ends on 20 Nov. Loopr runs one test at a time, so two results never mix.")
    }

    @Test func storedExperimentsBecomeTheRunningCardAndTheFinishedRows() async throws {
        let context = try Context(now: now, zone: zone)
        let data = try await experimentData(self.loader(context.stores))

        let running = try #require(data.running)
        #expect(running.id == ProtocolTabFixture.magnesiumExperimentID)
        let card = ProtocolExperimentPresentation.make(running)
        #expect(card.progress == "Running \u{00B7} night 9 of 14")
        #expect(card.title == "Magnesium glycinate, 300 mg")
        #expect(card.verdict == "Too early to say. Night 9 of 14.")
        #expect(card.measuresLine == "Minutes of deep sleep")
        #expect(card.testsRule == "Tests your rule Magnesium, 300 mg", "ICP R2-VET-08: the card names the rule it tests")
        #expect(card.call.text == "Too early to say. Magnesium nights are 6 minutes ahead, inside your usual night-to-night spread of 9. Loopr shows a result after night 14, and only if it clears that spread. So far 4 magnesium nights and 4 other nights count. Each side needs 7.")
        let strip = ProtocolExperimentStrip.make(running, showsRange: false)
        #expect(strip.onDots.count == 4 && strip.offDots.count == 4)

        #expect(data.finished.map(\.id) == [ProtocolTabFixture.bedroomExperimentID, ProtocolTabFixture.mouthTapeExperimentID,
                                            ProtocolTabFixture.caffeineExperimentID], "Newest first")
        let rows = data.finished.map { ProtocolExperimentPresentation.make($0) }
        #expect(rows.map(\.chip) == ["Clear", "No change", "Clear"])
        // ICP R1-VET-11: each row carries its likely range and the nights on each side.
        #expect(rows[0].rowSubtitle.hasPrefix("Sleep heart rate \u{2212}4 bpm, 95% range \u{2212}"), "\(rows[0].rowSubtitle)")
        #expect(rows[0].rowSubtitle.hasSuffix(" \u{00B7} 7 nights each"), "\(rows[0].rowSubtitle)")
        #expect(rows[1].rowSubtitle.hasPrefix("Deep sleep ") && rows[1].rowSubtitle.contains(", 95% range "), "\(rows[1].rowSubtitle)")
        #expect(rows[2].rowSubtitle.hasPrefix("Deep sleep +14 min, 95% range +") && rows[2].rowSubtitle.hasSuffix(" \u{00B7} kept"),
                "\(rows[2].rowSubtitle)")
        #expect(rows[2].keptVersion == 2 && !rows[2].canKeep)
        #expect(rows[0].keptVersion == nil && rows[0].canKeep)
        #expect(!rows[1].canKeep, "No change is never kept")
    }

    @Test func theResultCarriesTheGroupsTheDesignAndAlsoMoved() async throws {
        let context = try Context(now: now, zone: zone)
        let data = try await experimentData(self.loader(context.stores))
        let bedroom = try #require(data.finished.first { $0.id == ProtocolTabFixture.bedroomExperimentID })
        let result = ProtocolExperimentPresentation.make(bedroom)
        #expect(result.resultHeader == "Experiment finished \u{00B7} 14 nights")
        #expect(result.effect == -4)
        #expect(result.call.sentence.hasPrefix("Sleep heart rate was 4 beats a minute lower on cool bedroom nights than on the other nights."))
        #expect(result.headline == "Sleep heart rate was 4 beats a minute lower on cool bedroom nights than on the other nights.")
        #expect(result.call.sentence.contains("the whole range sits outside your usual spread"))
        #expect(result.designLine == "Alternating days in a fixed order, not random, decided before night 1")
        #expect(result.outcomeLine == "Sleep heart rate, fixed on day 1")
        #expect(result.alsoMoved == ["Fell asleep 8 min sooner. Not the outcome, so shown, not claimed."])
        let strip = ProtocolExperimentStrip.make(bedroom, showsRange: true)
        #expect(strip.onDots.count == 7 && strip.offDots.count == 7 && strip.likelyRange != nil && strip.band != nil)

        let file = try #require(bedroom.resultFile)
        let decoded = try ExperimentResultFileCodec.decode(try ExperimentResultFileCodec.encode(file))
        #expect(decoded.title == "Bedroom at 18 °C" && decoded.result.label == .clear)
        #expect(decoded.nights == ExperimentResultFile.Nights(completed: 14, onCounted: 7, offCounted: 7, leftOut: 0))
        #expect(data.running?.resultFile == nil, "A running experiment shares no file")
    }

    @Test func keepAddsTheRuleAsTheNextVersionOnce() async throws {
        let context = try Context(now: now, zone: zone)
        let loader = self.loader(context.stores)
        let before = try #require(try context.stores.routine.activeProtocol())
        #expect(before.latestVersion.number == 3)
        let earlier = try context.stores.routine.versions(protocolID: before.routineProtocol.id)

        try await loader.keepExperiment(ProtocolTabFixture.bedroomExperimentID, now: now)
        let after = try #require(try context.stores.routine.activeProtocol())
        #expect(after.latestVersion.number == 4)
        #expect(after.latestVersion.rule(for: "bedroom-18")?.title == "Bedroom at 18 °C")
        #expect(after.latestVersion.rules.count == before.latestVersion.rules.count + 1)
        let versions = try context.stores.routine.versions(protocolID: before.routineProtocol.id)
        #expect(Array(versions.prefix(3)) == earlier, "Earlier versions stay as they were")

        let data = try await experimentData(loader)
        let bedroom = try #require(data.finished.first { $0.id == ProtocolTabFixture.bedroomExperimentID })
        #expect(bedroom.keptVersion == 4 && !bedroom.canKeep)
        #expect(ProtocolExperimentPresentation.make(bedroom).rowSubtitle.hasSuffix("\u{00B7} kept"))
        let header = try #require(await loader.load(now: now).routineData)
        #expect(header.version == 4)

        try await loader.keepExperiment(ProtocolTabFixture.bedroomExperimentID, now: now)
        #expect(try context.stores.routine.versions(protocolID: before.routineProtocol.id).count == 4, "A second Keep writes nothing")

        await #expect(throws: ExperimentKeepError.notKeepable) {
            try await loader.keepExperiment(ProtocolTabFixture.mouthTapeExperimentID, now: now)
        }
    }

    @Test func theKeptCaffeineVersionLeavesTodaysCheckInAsSeeded() async throws {
        let context = try Context(now: now, zone: zone)
        let content = await self.loader(context.stores).load(now: now)
        let routine = try #require(content.routineData)
        #expect(routine.version == 3 && routine.rules.count == ProtocolTabFixture.allRules.count)
        let today = try #require(routine.countedToday)
        let presentation = ProtocolDayPresentation.make(today, week: ProtocolWeekCalendar(timeZone: zone, locale: Locale(identifier: "en_GB")))
        #expect(presentation.accessibilitySummary == "Today, Tuesday, 3 of 10 rules kept, 6 pending, 1 not known")
    }

    @Test func aLoaderWithoutAnExperimentStoreLeavesThemOut() async throws {
        let context = try Context(now: now, zone: zone)
        let content = await self.loader(context.stores, experiments: false).load(now: now)
        #expect(content.designedExperiments == nil)
        await #expect(throws: ProtocolTabError.experimentsUnavailable) {
            try await self.loader(context.stores, experiments: false).keepExperiment(ProtocolTabFixture.bedroomExperimentID, now: now)
        }
    }

    @Test func theStartAtArgumentOpensTheExperimentsSegment() {
        let arguments = ["--loopr-launch-mode=populated", "--loopr-start-at=protocol-experiments"]
        #expect(MainTabLaunchState.startingAt(arguments) == .init(tab: .protocol))
        #expect(MainTabLaunchState.protocolSegment(arguments) == "experiments")
        #expect(MainTabLaunchState.protocolSegment(arguments).flatMap(ProtocolSegment.init(rawValue:)) == .experiments)
        #expect(MainTabLaunchState.startingAt(["--loopr-start-at=data"]) == .init(tab: .data))
        #expect(MainTabLaunchState.startingAt(["--loopr-launch-mode=populated"]) == nil)
        #expect(MainTabLaunchState.protocolSegment(["--loopr-start-at=data"]) == nil)
    }
}
#endif
