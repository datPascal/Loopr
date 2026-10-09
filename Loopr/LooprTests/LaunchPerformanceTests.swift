import Foundation
import StorageKit
import Testing
import WorkoutKit

@testable import Loopr

private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
}

struct LooprProductionDatabasesTests {
    @Test @MainActor
    func theDefaultPathsAreTheOnesProductionOpens() throws {
        let paths = LooprProductionDatabases.defaultProductionURLs().map(\.standardizedFileURL.path)
        let history = try ProductionBluetoothAdoptionStore.historyDatabaseURL().standardizedFileURL.path
        let products = try #require(AppEnvironment.production().storageURL).standardizedFileURL.path
        #expect(paths == [history, products])
    }

    @Test
    func aProductionFileOpensOnceAndDefersItsCheck() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("loopr.sqlite")
        let registry = LooprProductionDatabases(productionURLs: [url])
        let first = try registry.database(at: url, applicationVersion: "1.0 (1)")
        let second = try registry.database(at: url, applicationVersion: "1.0 (1)")
        #expect(first === second)
        #expect(registry.isShared(url))
        // The check still runs, just not inside the open.
        #expect(first.coldLaunchIntegrityResult == .ok)
    }

    @Test
    func concurrentFirstOpensShareOneDatabase() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("loopr.sqlite")
        let registry = LooprProductionDatabases(productionURLs: [url])
        let opened = await withTaskGroup(of: ObjectIdentifier?.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    (try? registry.database(at: url, applicationVersion: "1.0 (1)")).map(ObjectIdentifier.init)
                }
            }
            var identities: Set<ObjectIdentifier?> = []
            for await identity in group { identities.insert(identity) }
            return identities
        }
        #expect(opened.count == 1)
        #expect(opened.first! != nil)
    }

    @Test
    func otherFilesOpenFreshWithTheCheckAtOpen() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("history.sqlite")
        let registry = LooprProductionDatabases(productionURLs: [root.appendingPathComponent("loopr.sqlite")])
        let first = try registry.database(at: url, applicationVersion: "1.0 (1)")
        let second = try registry.database(at: url, applicationVersion: "1.0 (1)")
        #expect(first !== second)
        #expect(first.hasColdLaunchIntegrityResult)
        #expect(!registry.isShared(url))
    }
}

struct WorkoutListingStoreTests {
    @Test
    func theSQLiteStoreListsRowsWithoutSamples() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try StorageDatabase(url: root.appendingPathComponent("products.sqlite"))
        let store = try SQLiteWorkoutStore(database: database)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let start = now.addingTimeInterval(-7_200)
        let samples = (0..<600).map { index in
            WorkoutSample(timestamp: start.addingTimeInterval(TimeInterval(index)), heartRate: 130,
                          distanceMeters: index.isMultiple(of: 60) ? Double(index) * 2.5 : nil)
        }
        let recent = WorkoutRecord(id: UUID(), identity: WorkoutIdentity(canonicalKey: "recent"), activity: .run,
                                   source: .live, state: .completed, createdAt: start, startedAt: start,
                                   endedAt: start.addingTimeInterval(600), samples: samples)
        let old = WorkoutRecord(id: UUID(), identity: WorkoutIdentity(canonicalKey: "old"), activity: .walk,
                                source: .manual, state: .completed, createdAt: now.addingTimeInterval(-200 * 86_400),
                                startedAt: now.addingTimeInterval(-200 * 86_400))
        try await store.save(recent)
        try await store.save(old)

        let rows = await store.listingRows(WorkoutLogQuery(range: .threeMonths, now: now))
        #expect(rows == [recent.listingRow])
        #expect(rows.first?.samples.count == 1)
        #expect(rows.first?.samples.first?.distanceMeters == 540 * 2.5)
        // The full record is still there for detail screens.
        #expect(await store.workout(id: recent.id) == recent)
    }
}

@MainActor
private final class RunCounter {
    var value = 0
}

@MainActor
struct ProductionRefreshCoordinatorTests {
    @Test
    func anImmediateRequestSkipsTheDebounce() async throws {
        let coordinator = ProductionRefreshCoordinator(debounce: 60)
        let runs = RunCounter()
        coordinator.request { runs.value += 1 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(runs.value == 1)
        // A normal request inside the window would wait a minute; an
        // immediate one runs now.
        coordinator.request(immediately: true) { runs.value += 1 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(runs.value == 2)
    }
}
