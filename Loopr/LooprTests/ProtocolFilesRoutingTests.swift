import DomainKit
import Foundation
import JournalKit
import RoutineKit
import StorageKit
import Testing
@testable import Loopr

/// LV-07.4: a protocol file opened from the share sheet, Files or the Rules segment's importer goes through
/// `RoutineFileInbox`, reaches the Protocol tab as a review, and "Use this protocol" saves the next version with the
/// file as its lineage. A refused file shows the validator's sentence and changes nothing.
@MainActor struct ProtocolFilesRoutingTests {
    private let zone = TimeZone(identifier: "UTC")!
    /// Tue 14 Nov 2023, 22:13 UTC.
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private final class Context {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("protocol-files-\(UUID().uuidString)")
        let database: StorageDatabase
        let store: RoutineStore
        init() throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            database = try StorageDatabase(url: root.appendingPathComponent("routine.sqlite"), applicationVersion: "protocol-files-tests")
            store = RoutineStore(database: database)
        }
        func write(_ data: Data, as name: String) throws -> URL {
            let url = root.appendingPathComponent(name)
            try data.write(to: url)
            return url
        }
        deinit { try? FileManager.default.removeItem(at: root) }
    }

    private func model(_ context: Context, inbox: RoutineFileInbox) async throws -> ProtocolTabModel {
        let mine = RoutineProtocol(name: "My protocol", createdAt: now.addingTimeInterval(-86_400 * 3))
        try context.store.createProtocol(mine, rules: [
            ProtocolRule(key: "in-bed", title: "In bed by 22:30", group: .sleep,
                         target: RuleTarget(kind: .atMost, metric: RoutineMetric.inBedTime.rawValue, value: 1_350, unit: "min"),
                         timeOfDayMinutes: 21 * 60 + 45, source: .band, isEvening: true, rebuttal: "Mine"),
            ProtocolRule(key: "walk", title: "Walk")
        ])
        let loader = ProtocolTabLoader(store: context.store, timeZone: { [zone] in zone },
                                       snapshots: { _, _, _ in RoutineSourceSnapshots() })
        let model = ProtocolTabModel(source: loader, habits: HabitViewModel(store: InMemoryHabitStore()), timeZone: zone,
                                     locale: Locale(identifier: "en_GB"), now: { [now] in now })
        model.openFile = { url in inbox.receive(url) }
        model.attach(incoming: inbox.incoming)
        await model.load()
        return model
    }

    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<100 where !condition() { try? await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func anOpenedFileReachesTheRulesReviewAndUseSavesTheNextVersion() async throws {
        let context = try Context()
        let inbox = RoutineFileInbox()
        let model = try await model(context, inbox: inbox)
        let url = try context.write(try ProtocolTemplate.sleepFirst.data(), as: "sleep-first.looprprotocol")

        #expect(inbox.receive(url), "the .onOpenURL hook hands the file to the inbox")
        await settle { model.importReview != nil }
        let review = try #require(model.importReview)
        #expect(review.name == "Sleep first")
        #expect(review.headline.hasPrefix("Against your version 1:"))
        #expect(model.requestedSegment == .rules)
        await settle { inbox.pending == nil }
        #expect(inbox.pending == nil, "the tab took the file")

        #expect(await model.useImport())
        let active = try #require(try context.store.activeProtocol())
        #expect(active.latestVersion.number == 2)
        #expect(active.routineProtocol.name == "Sleep first")
        #expect(active.routineProtocol.lineage == ProtocolLineage(forkedFromName: "Sleep first", forkedFromVersion: 1))
        #expect(active.latestVersion.rule(for: "in-bed")?.rebuttal == "Mine", "the person's own reason stays")
        #expect(model.routine?.version == 2)
    }

    @Test func aRefusedFileShowsTheValidatorsSentenceAndChangesNothing() async throws {
        let context = try Context()
        let inbox = RoutineFileInbox()
        let model = try await model(context, inbox: inbox)
        let before = try context.database.tableRowCounts()

        model.openPickedFile(try context.write(Data("nope".utf8), as: "broken.looprprotocol"))
        await settle { model.importError != nil }
        #expect(model.importError == ProtocolFileError.notJSON.errorDescription)
        #expect(model.importReview == nil)

        model.openPickedFile(try context.write(Data("x".utf8), as: "notes.txt"))
        #expect(model.importError == "Loopr opens protocol files that end in .looprprotocol or .json.")
        #expect(try context.database.tableRowCounts() == before)
    }

    @Test func theShareFileHoldsNoRebuttalAndTheRealSize() async throws {
        let context = try Context()
        let model = try await model(context, inbox: RoutineFileInbox())
        let content = try #require(await model.passContent())
        let text = try #require(String(data: content.document.data, encoding: .utf8))
        #expect(!text.contains("rebuttal") && !text.contains("\"Mine\""))
        #expect(content.pass.byteCount == content.document.data.count)
        #expect(content.document.fileName == "my-protocol.looprprotocol")
    }

    #if DEBUG
    @Test func theEmptyFixtureArgumentIsReadLikeStartAt() {
        #expect(ProtocolTabFixture.startsEmpty(["--loopr-launch-mode=populated", "--loopr-protocol-fixture=empty"]))
        #expect(!ProtocolTabFixture.startsEmpty(["--loopr-launch-mode=populated"]))
        #expect(MainTabLaunchState.protocolSegment(["--loopr-start-at=protocol-rules"]) == "rules")
    }
    #endif
}
