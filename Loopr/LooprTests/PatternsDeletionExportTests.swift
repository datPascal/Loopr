import AIKit
import BluetoothKit
import DomainKit
import Foundation
import JournalKit
import StorageKit
import Testing
@testable import Loopr

private typealias F = PatternsFixtures4b

/// Patterns data is Journal data: it leaves in an export, goes in Delete all, and is rebuilt from what is left
/// when its sources change. Perth, Alex, and no network.
@MainActor
@Suite(.serialized)
struct PatternsDeletionExportTests {
    private struct Graph {
        let persistent: PersistentProductRepositories
        let store: SQLitePatternStore
        let root: URL
        let suite: AgentFixtures.Suite
    }

    private func graph() throws -> Graph {
        let suite = AgentFixtures.Suite()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("patterns-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Loopr"), withIntermediateDirectories: true)
        let environment = AppEnvironment(composition: .production, root: .main, storageURL: root.appendingPathComponent("Loopr.sqlite"),
            applicationVersion: "patterns-4b", dateProvider: SystemDateProvider(), calendarProvider: SystemCalendarProvider(),
            timeZoneProvider: SystemTimeZoneProvider(), uuidProvider: SystemUUIDProvider(), scheduler: SystemScheduler())
        let persistent = try PersistentProductRepositories(environment: environment, defaults: suite.defaults)
        return Graph(persistent: persistent, store: try SQLitePatternStore(database: persistent.database), root: root, suite: suite)
    }

    private func seed(_ store: SQLitePatternStore) async throws -> PatternTest {
        let test = try PatternTest.start(candidate: .trainingDay, metric: .sleepScore, now: F.now, timeZone: F.zone, reminder: PatternReminder())
        try await store.saveTest(test)
        try await store.replaceFoundPatterns([F.alcohol, F.lateDinner])
        try await store.dismiss(F.legDay, at: F.now)
        try await store.saveReview(WeeklyReview(weekStartDay: "2026-10-05", weekEndDay: "2026-10-11", text: "Recovery averaged 71.", patternKeys: [F.alcohol.key], generatedAt: F.now))
        try await store.saveSettings(PatternSettings(lookForNewPatterns: true))
        return test
    }

    // MARK: Export

    @Test func anExportCarriesEveryKindOfPatternsRowWithItsEvidence() async throws {
        let graph = try graph(); defer { try? FileManager.default.removeItem(at: graph.root) }
        _ = try await seed(graph.store)
        let contents = graph.root.appendingPathComponent("export", isDirectory: true)
        let exporter = YourDataExporter(stores: YourDataModel.stores(for: graph.persistent), defaultsData: Data(), temporaryDirectory: graph.root)
        try await YourDataFileWorker.run { try exporter.stage(.everything, at: contents, now: F.now) }

        let data = try Data(contentsOf: contents.appendingPathComponent("products/loopr_product_document.json"))
        let rows = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let patterns = rows.filter { $0["namespace"] as? String == "patterns" }
        let keys = patterns.compactMap { $0["document_key"] as? String }
        for prefix in ["test.", "found.", "dismissed.", "review."] {
            #expect(keys.contains { $0.hasPrefix(prefix) }, "no \(prefix) row in the export")
        }
        #expect(keys.contains("settings"))
        // The dismissed row carries the evidence, so Restore works from a backup.
        let dismissed = try #require(patterns.first { ($0["document_key"] as? String)?.hasPrefix("dismissed.") == true })
        let payload = try #require((dismissed["payload"] as? [String: Any])?["base64"] as? String)
        let text = String(decoding: try #require(Data(base64Encoded: payload)), as: UTF8.self)
        #expect(text.contains("Leg day") && text.contains("restingHeartRate"))
        let manifest = try String(contentsOf: contents.appendingPathComponent("manifest.json"), encoding: .utf8)
        #expect(manifest.contains("loopr_product_document"))
    }

    @Test func theInventoryCountsPatternsUnderJournal() async throws {
        let graph = try graph(); defer { try? FileManager.default.removeItem(at: graph.root) }
        #expect(YourDataDomain.document(SQLitePatternStore.namespace) == .journal)
        let stores = YourDataModel.stores(for: graph.persistent)
        let before = try await YourDataFileWorker.run { try stores.inventory() }.contentBytes[.journal, default: 0]
        _ = try await seed(graph.store)
        let after = try await YourDataFileWorker.run { try stores.inventory() }.contentBytes[.journal, default: 0]
        #expect(after > before, "patterns rows were not counted as Journal data")
    }

    // MARK: Delete all

    @Test func deleteAllRemovesEveryPatternsRowAndSaysSo() async throws {
        let graph = try graph(); defer { try? FileManager.default.removeItem(at: graph.root) }
        _ = try await seed(graph.store)
        #expect(try await graph.store.tests().count == 1)

        // The product's own stores and the Coach deleter, without the Keychain and app-group deleters, which belong to the host app.
        let persistent = graph.persistent
        LooprPatternsRuntime.shared.install(F.engine())
        let effects = PersistentOnboardingDataEffects(
            profile: persistent.profile, device: persistent.device, onboarding: persistent.onboarding, database: persistent.database,
            defaults: graph.suite.defaults, accessoryProvisioningStore: UserDefaultsAccessoryProvisioningStore(defaults: graph.suite.defaults),
            productStores: persistent.destructiveEffects.productStores, coachDataDeleter: LooprCoachDataDeletionDeleter())
        let receipt = await effects.deleteAllDataWithReceipt()
        #expect(receipt.isComplete && receipt.failures.isEmpty, Comment(rawValue: String(describing: receipt.failures)))
        #expect(receipt.clearedStores.contains("coach.runtime"))
        #expect(LooprPatternsRuntime.shared.engine == nil, "Delete all must drop the running engine")
        #expect(receipt.clearedStores.contains("product.namespace.patterns"))
        #expect(try await graph.store.tests().isEmpty)
        #expect(try await graph.store.foundPatterns().isEmpty)
        #expect(try await graph.store.dismissedPatterns().isEmpty)
        #expect(try await graph.store.reviews().isEmpty)
        #expect(try await graph.store.settings() == PatternSettings(), "settings reset too, and Look for new patterns is off again")
    }

    @Test func deleteAllStopsRemindersAndTurnsProposeTestOff() async throws {
        let reminders = SpyPatternReminders()
        let runtime = LooprPatternsRuntime()
        let engine = F.engine(data: F.lateDinnerData(), reminders: reminders)
        runtime.install(engine)
        LooprAgentRuntime.shared.testStarter.set(PatternTestStarter(engine: engine))
        #expect(LooprAgentRuntime.shared.testStarter.isSet)

        await runtime.resetAfterDeletion()
        #expect(reminders.cancelledAll == 1)
        #expect(runtime.engine == nil)
        #expect(!LooprAgentRuntime.shared.testStarter.isSet, "propose_test must stay off after Delete all")
    }

    // MARK: Source data deleted

    @Test func deletingSourceDataRebuildsTheFoundListFromWhatIsLeft() async throws {
        let store = InMemoryPatternStore()
        let box = F.lateDinnerData()
        let engine = F.engine(store: store, data: box)
        try await engine.setLookForNewPatterns(true)
        let test = try await engine.startTest(candidateID: "training", metric: nil, reminderMinuteOfDay: nil)
        _ = try await engine.discover(force: true)
        let late = try #require(try await engine.snapshot().found.first { $0.candidateID == "food.lateMeal" })
        try await engine.dismiss(key: late.key)
        try await store.saveReview(WeeklyReview(weekStartDay: "2026-10-05", weekEndDay: "2026-10-11", text: "Old review.", patternKeys: [late.key], generatedAt: F.now))

        // Meals and sleep are deleted. What discovery reads is gone.
        box.update { $0.food = [:]; $0.outcomes = [:] }
        await engine.rebuildAfterSourceDeletion()

        let snapshot = try await engine.snapshot()
        #expect(snapshot.found.isEmpty && snapshot.dismissed.isEmpty && snapshot.review == nil,
                "nothing derived from the deleted data may stay")
        #expect(snapshot.tests.map(\.id) == [test.id], "a running test is the person's own plan and stays")
        #expect(snapshot.settings.lookForNewPatterns && snapshot.settings.lastDiscoveryDay == F.today, "discovery ran again on what was left")
    }

    @Test func withDiscoveryOffTheFoundListEmptiesAndStaysEmpty() async throws {
        let store = InMemoryPatternStore()
        let box = F.lateDinnerData()
        let engine = F.engine(store: store, data: box)
        _ = try await engine.discover(force: true)
        #expect(!(try await engine.snapshot().found.isEmpty))
        let reads = box.mainThreadReads.count
        await engine.rebuildAfterSourceDeletion()
        #expect(try await engine.snapshot().found.isEmpty)
        #expect(box.mainThreadReads.count == reads, "Look for new patterns is off, so nothing was read")
    }
}
