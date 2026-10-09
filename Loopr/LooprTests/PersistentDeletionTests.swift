import BluetoothKit
import CycleKit
import DeviceCenterKit
import DataKit
import Foundation
import HealthKitBridge
import OnboardingKit
import ProfileKit
import RouteKit
import StorageKit
import Testing
@testable import Loopr

@MainActor
struct PersistentDeletionTests {
    @Test
    func cycleWritesThrowAfterTheDatabaseCloses() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loopr-cycle-write-failure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try StorageDatabase(
            url: root.appendingPathComponent("product.sqlite"),
            applicationVersion: "1.0 (1)"
        )
        let repository = try SQLiteCycleRepository(database: database)
        try database.databasePool.close()

        await #expect(throws: (any Error).self) {
            try await repository.optIn()
        }
        await #expect(throws: (any Error).self) {
            _ = try await repository.log(CycleEntry(day: "2026-08-18", kind: .periodStart))
        }
        await #expect(throws: (any Error).self) {
            _ = try await repository.export()
        }
    }

    @Test
    func routeReadsAndWritesThrowAfterTheDatabaseCloses() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loopr-route-write-failure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try StorageDatabase(
            url: root.appendingPathComponent("product.sqlite"),
            applicationVersion: "1.0 (1)"
        )
        let repository = try SQLiteRouteStore(database: database)
        try database.databasePool.close()

        await #expect(throws: (any Error).self) {
            try await repository.save(RouteRecord(workoutID: "closed", activity: .run))
        }
        await #expect(throws: (any Error).self) {
            _ = try await repository.route(workoutID: "closed")
        }
    }

    @Test
    func deleteAllClearsProductNamespacesBluetoothHistoryAndIdentifiers() async throws {
        try await withDeletionGraph { graph in

        _ = try await graph.profile.saveProfile(ProfileDraft(displayName: "Delete me", unitSystem: .metric))
        try await graph.device.saveIdentity(DeviceCenterStateFixtures.sampleDevice)
        try await graph.onboarding.save(OnboardingSnapshot(
            stage: .profileSetup,
            pairingRequested: true,
            lastUpdatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        try graph.productStore.write("payload", key: "sample")
        try await graph.provisioning.saveBluetoothIdentifier(graph.identifier)
        try graph.historyDatabase.write { db in
            try db.execute(
                sql: "INSERT INTO sync_batch(batch_id, state, received_at, updated_at, error) VALUES (?, ?, ?, ?, ?)",
                arguments: ["delete-test", "committed", 1, 1, nil]
            )
        }
        for key in ProductRepositoryKeys.allOwnedDefaultsKeys {
            graph.defaults.set("owned-value", forKey: key)
        }

        let effects = PersistentOnboardingDataEffects(
            profile: graph.profile,
            device: graph.device,
            onboarding: graph.onboarding,
            database: graph.database,
            defaults: graph.defaults,
            accessoryProvisioningStore: graph.provisioning,
            productStores: [NamedProductStore(name: "today", store: graph.productStore)],
            externalDeleters: [SQLiteFileDataDeletionDeleter(
                storeName: "bluetooth.history.sqlite",
                databaseURL: graph.historyURL,
                applicationVersion: "1.0 (1)"
            )]
        )

        let receipt = await effects.deleteAllDataWithReceipt()
        #expect(receipt.isComplete)
        #expect(receipt.failures.isEmpty)
        #expect(receipt.clearedStores.contains("product.sqlite-ledger"))
        #expect(receipt.clearedStores.contains("product.namespace.today"))
        #expect(receipt.clearedStores.contains("bluetooth.history.sqlite"))
        #expect(try await graph.profile.readProfile() == nil)
        #expect(try await graph.device.readIdentity() == nil)
        #expect(try await graph.onboarding.load() == nil)
        #expect(await graph.provisioning.loadBluetoothIdentifier() == nil)
        #expect(ProductRepositoryKeys.allOwnedDefaultsKeys.allSatisfy {
            graph.defaults.object(forKey: $0) == nil
        })

        let reopenedProduct = try StorageDatabase(url: graph.databaseURL, applicationVersion: "1.0 (1)")
        let reopenedStore = try StorageDocumentStore(database: reopenedProduct, namespace: "today")
        #expect(try reopenedStore.readData(key: "sample") == nil)
        let reopenedHistory = try StorageDatabase(url: graph.historyURL, applicationVersion: "1.0 (1)")
        #expect(try reopenedHistory.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_batch") } == 0)

        // A second pass is safe and remains truthful after all rows are gone.
        let secondReceipt = await effects.deleteAllDataWithReceipt()
        #expect(secondReceipt.isComplete)
        #expect(secondReceipt.failures.isEmpty)
        }
    }

    @Test
    func standardDefaultsDeletionRegistryCoversEveryShippingWriter() {
        #expect(Set(ProductRepositoryKeys.allOwnedDefaultsKeys) == [
            "loopr.product.onboarding.v1",
            "loopr.product.profile.v1",
            "loopr.product.device.v1",
            "com.loopr.bluetooth.provisionedAccessory.bluetoothIdentifier",
            "com.loopr.bluetooth.experimentalGen5.enabled",
            "com.loopr.bluetooth.experimentalGen5.whoop5.enabled",
            "com.loopr.bluetooth.experimentalGen5.whoopMG.enabled",
            "com.loopr.onboarding.experimentalBandConsent.v1",
            "loopr.ai.provider.endpoint.v1",
            "loopr.ai.provider.model.v1",
            "loopr.launch.onboarding-completed.v1",
            "loopr.today.launch-snapshot.v1",
            "loopr.days.default-day.v1",
            "loopr.today.preferences.v1"
        ])
    }

    @Test
    func perDayExportAndDeletionOnlyAffectDataScreenRecords() async throws {
        try await withDeletionGraph { graph in
            let repository = try SQLiteDataRepository(database: graph.database)
            let selected = DataRecord(id: "selected", day: "2026-08-17", table: "metrics",
                payload: ["value": "42"], provenance: .looprComputed, algorithmVersion: 1)
            let other = DataRecord(id: "other", day: "2026-08-18", table: "metrics",
                payload: ["value": "43"], provenance: .looprComputed, algorithmVersion: 1)
            try await repository.insert(selected)
            try await repository.insert(other)
            try graph.historyDatabase.write { db in
                try db.execute(sql: "INSERT INTO sync_batch(batch_id, state, received_at, updated_at, error) VALUES (?, ?, ?, ?, ?)",
                    arguments: ["history-stays", "committed", 1, 1, nil])
            }

            let backup = try await repository.exportDayChecked("2026-08-17")
            #expect(backup.records == [selected])
            try await repository.deleteDayChecked("2026-08-17")

            #expect(try await repository.recordsChecked() == [other])
            #expect(try await repository.exportDayChecked("2026-08-17").records.isEmpty)
            #expect(try graph.historyDatabase.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_batch WHERE batch_id = ?", arguments: ["history-stays"])
            } == 1)
        }
    }

    @Test
    func fullDeletionRegistryIncludesBothKeychainServicesAndLeavesHealthKitSeparate() {
        #expect(Set(LooprPlatformOwnedArtifacts.keychainServices) == [
            "com.loopr.ios.loopr-owned", "com.loopr.ios.ai-provider"
        ])
        #expect(DataDisclosureCopy.deleteAllData.contains("HealthKit samples stay where they are"))
    }

    @Test
    func explicitHealthKitDeletionUsesThePlatformClientBeforeClearingInventory() async throws {
        try await withDeletionGraph { graph in
            let client = RecordingHealthSampleDeletionClient(result: .success(3))
            let repository = try SQLiteDataRepository(
                database: graph.database,
                healthSampleDeletionClient: client
            )
            try await repository.setInventoryChecked(DataStoreInventory(healthKitSamples: 3))

            try await repository.removeHealthKitSamplesChecked()

            #expect(await client.callCount() == 1)
            #expect(try await repository.inventorySnapshotChecked().healthKitSamples == 0)
        }
    }

    @Test
    func failedHealthKitDeletionDoesNotClaimTheInventoryWasCleared() async throws {
        try await withDeletionGraph { graph in
            let client = RecordingHealthSampleDeletionClient(result: .failure(HealthDeletionFixtureError.failed))
            let repository = try SQLiteDataRepository(
                database: graph.database,
                healthSampleDeletionClient: client
            )
            try await repository.setInventoryChecked(DataStoreInventory(healthKitSamples: 2))

            await #expect(throws: HealthDeletionFixtureError.failed) {
                try await repository.removeHealthKitSamplesChecked()
            }

            #expect(await client.callCount() == 1)
            #expect(try await repository.inventorySnapshotChecked().healthKitSamples == 2)
        }
    }

    @Test
    func resetProfileAndForgetBandDoNotEraseUnrelatedState() async throws {
        try await withDeletionGraph { graph in
        _ = try await graph.profile.saveProfile(ProfileDraft(displayName: "Keep device", unitSystem: .metric))
        try await graph.device.saveIdentity(DeviceCenterStateFixtures.sampleDevice)
        try await graph.onboarding.save(OnboardingSnapshot(stage: .profileSetup, pairingRequested: false, lastUpdatedAt: Date()))
        try await graph.provisioning.saveBluetoothIdentifier(graph.identifier)

        let effects = PersistentOnboardingDataEffects(
            profile: graph.profile,
            device: graph.device,
            onboarding: graph.onboarding,
            database: graph.database,
            defaults: graph.defaults,
            accessoryProvisioningStore: graph.provisioning,
            productStores: [],
            externalDeleters: []
        )

        try await effects.resetProfile()
        #expect(try await graph.profile.readProfile() == nil)
        #expect(try await graph.device.readIdentity() != nil)
        #expect(try await graph.onboarding.load() != nil)
        #expect(await graph.provisioning.loadBluetoothIdentifier() == graph.identifier)

        try await effects.forgetBand()
        #expect(try await graph.device.readIdentity() == nil)
        #expect(try await graph.onboarding.load() != nil)
        #expect(await graph.provisioning.loadBluetoothIdentifier() == graph.identifier)
        }
    }

    @Test
    func partialExternalDeletionIsReportedAndThrowingApiNeverClaimsSuccess() async throws {
        try await withDeletionGraph { graph in
        let effects = PersistentOnboardingDataEffects(
            profile: graph.profile,
            device: graph.device,
            onboarding: graph.onboarding,
            database: graph.database,
            defaults: graph.defaults,
            accessoryProvisioningStore: graph.provisioning,
            productStores: [],
            externalDeleters: [FailingDeletionDeleter(storeName: "keychain")]
        )

        let receipt = await effects.deleteAllDataWithReceipt()
        #expect(!receipt.isComplete)
        #expect(receipt.failures.map(\.storeName) == ["keychain"])
        do {
            try await effects.deleteAllData()
            Issue.record("partial deletion must throw instead of reporting success")
        } catch let error as PersistentDataDeletionError {
            #expect(error.receipt.failures.map(\.storeName) == ["keychain"])
        }
        }
    }

    @Test
    func runtimeDeletionPhaseCompletesBeforeHistoryDeletion() async throws {
        try await withDeletionGraph { graph in
        let order = DeletionOrderRecorder()
        let effects = PersistentOnboardingDataEffects(
            profile: graph.profile,
            device: graph.device,
            onboarding: graph.onboarding,
            database: graph.database,
            defaults: graph.defaults,
            accessoryProvisioningStore: graph.provisioning,
            productStores: [],
            runtimeDataDeleter: OrderedDeletionDeleter(name: "runtime", recorder: order),
            externalDeleters: [OrderedDeletionDeleter(name: "history", recorder: order)]
        )

        let receipt = await effects.deleteAllDataWithReceipt()

        #expect(receipt.isComplete)
        #expect(await order.values() == ["runtime", "history"])
        }
    }

    @Test
    func runtimeDeletionFailurePreventsProductAndHistoryDeletion() async throws {
        try await withDeletionGraph { graph in
        try graph.productStore.write("keep", key: "sample")
        let order = DeletionOrderRecorder()
        let effects = PersistentOnboardingDataEffects(
            profile: graph.profile,
            device: graph.device,
            onboarding: graph.onboarding,
            database: graph.database,
            defaults: graph.defaults,
            accessoryProvisioningStore: graph.provisioning,
            productStores: [NamedProductStore(name: "today", store: graph.productStore)],
            runtimeDataDeleter: OrderedDeletionDeleter(name: "runtime", recorder: order, shouldFail: true),
            externalDeleters: [OrderedDeletionDeleter(name: "history", recorder: order)]
        )

        let receipt = await effects.deleteAllDataWithReceipt()

        #expect(!receipt.isComplete)
        #expect(receipt.failures.map(\.storeName) == ["runtime"])
        #expect(await order.values() == ["runtime"])
        #expect(try graph.productStore.read(String.self, key: "sample") == "keep")
        }
    }
}

private struct DeletionGraph {
    let rootURL: URL
    let databaseURL: URL
    let historyURL: URL
    let database: StorageDatabase
    let historyDatabase: StorageDatabase
    let defaults: UserDefaults
    let profile: SQLiteProfileRepository
    let device: SQLiteDeviceCenterRepository
    let onboarding: SQLiteOnboardingRepository
    let productStore: StorageDocumentStore
    let provisioning: UserDefaultsAccessoryProvisioningStore
    let identifier: UUID
}

private func makeDeletionGraph() throws -> DeletionGraph {
    let identifier = UUID().uuidString
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("loopr-deletion-\(identifier)", isDirectory: true)
    let databaseURL = rootURL.appendingPathComponent("product.sqlite")
    let historyURL = rootURL.appendingPathComponent("bluetooth.sqlite")
    let database = try StorageDatabase(url: databaseURL, applicationVersion: "1.0 (1)")
    let historyDatabase = try StorageDatabase(url: historyURL, applicationVersion: "1.0 (1)")
    let defaults = try #require(UserDefaults(suiteName: "LooprDeletionTests.\(identifier)"))
    let profile = try SQLiteProfileRepository(database: database)
    let device = try SQLiteDeviceCenterRepository(database: database)
    let onboarding = try SQLiteOnboardingRepository(database: database)
    let productStore = try StorageDocumentStore(database: database, namespace: "today")
    let provisioning = UserDefaultsAccessoryProvisioningStore(defaults: defaults)
    return DeletionGraph(
        rootURL: rootURL,
        databaseURL: databaseURL,
        historyURL: historyURL,
        database: database,
        historyDatabase: historyDatabase,
        defaults: defaults,
        profile: profile,
        device: device,
        onboarding: onboarding,
        productStore: productStore,
        provisioning: provisioning,
        identifier: UUID(uuidString: "00000000-0000-0000-0000-000000000616")!
    )
}

@MainActor
private func withDeletionGraph(
    _ body: @MainActor (DeletionGraph) async throws -> Void
) async throws {
    var graph: DeletionGraph? = try makeDeletionGraph()
    let rootURL = graph!.rootURL
    do {
        try await body(graph!)
        graph = nil
        try FileManager.default.removeItem(at: rootURL)
    } catch {
        graph = nil
        try? FileManager.default.removeItem(at: rootURL)
        throw error
    }
}

private struct FailingDeletionDeleter: PersistentDataDeletionDeleter {
    let storeName: String

    func deleteAll() async throws {
        throw PersistentDataDeletionError.unavailableExternalStore(storeName)
    }
}

private enum HealthDeletionFixtureError: Error {
    case failed
}

private actor RecordingHealthSampleDeletionClient: HealthSampleDeletionClient {
    private let result: Result<Int, any Error>
    private var calls = 0

    init(result: Result<Int, any Error>) {
        self.result = result
    }

    func deleteLooprCreatedSamples() throws -> Int {
        calls += 1
        return try result.get()
    }

    func callCount() -> Int { calls }
}

private actor DeletionOrderRecorder {
    private var entries: [String] = []
    func append(_ value: String) { entries.append(value) }
    func values() -> [String] { entries }
}

private struct OrderedDeletionDeleter: PersistentDataDeletionDeleter {
    let name: String
    let recorder: DeletionOrderRecorder
    var shouldFail = false

    var storeName: String { name }

    func deleteAll() async throws {
        await recorder.append(name)
        if shouldFail {
            throw PersistentDataDeletionError.unavailableExternalStore(name)
        }
    }
}
