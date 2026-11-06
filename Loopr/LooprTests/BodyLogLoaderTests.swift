import BodyKit
import DesignSystem
import FoodKit
import Foundation
import HealthKitBridge
import StorageKit
import Testing
@testable import Loopr

/// The weight and body composition log's app side: Apple Health reads mapped with their sources, typed entries kept
/// in the Food weight table and `body_composition`, and the merged log the Body screen and the log screen read.
private let now = Date(timeIntervalSince1970: 1_792_483_200)

private func sample(_ kind: AppleHealthSourceKind, _ value: Double, hoursAgo: Double, source: String = "Withings",
                    bundle: String? = nil, device: String? = nil, userEntered: Bool? = nil) -> AppleHealthSample {
    let date = now.addingTimeInterval(-hoursAgo * 3_600)
    return AppleHealthSample(kind: kind, value: value, original: AppleHealthOriginalReading(value: value, unit: kind.storeUnit),
                             start: date, end: date,
                             provenance: AppleHealthProvenance(sourceName: source, sourceBundleIdentifier: bundle,
                                                               deviceName: device, wasUserEntered: userEntered))
}

private nonisolated struct StubHealth: BodyLogHealthReading {
    let results: [AppleHealthSourceKind: AppleHealthReadResult]
    func read(now: Date) async -> (samples: [BodyLogHealthSample], status: BodyLogHealthStatus) {
        BodyLogHealthMapping.map(results)
    }
}

private struct TemporaryStore {
    let database: StorageDatabase
    let food: FoodStore
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("body-log-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try StorageDatabase(url: root.appendingPathComponent("products.sqlite"))
        food = FoodStore(database: database)
    }

    func cleanup() {
        try? database.databasePool.close()
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite struct BodyLogHealthMappingTests {
    @Test func appleHealthSamplesKeepTheirValueUnitAndWritingApp() throws {
        let results: [AppleHealthSourceKind: AppleHealthReadResult] = [
            .weight: .values([sample(.weight, 79.1, hoursAgo: 5, source: "Pascal's iPhone", bundle: "com.apple.health.9F2", device: "iPhone")]),
            .bodyFat: .values([sample(.bodyFat, 21.5, hoursAgo: 5)]),
            .leanMass: .absent(.noSamples)]
        let mapped = BodyLogHealthMapping.map(results)
        #expect(mapped.status == .reading)
        let weight = try #require(mapped.samples.first { $0.quantity == .weight })
        #expect(weight.value == 79.1)
        #expect(weight.sourceName == "iPhone", "Apple's own sources are named after the device")
        let fat = try #require(mapped.samples.first { $0.quantity == .bodyFat })
        #expect(fat.value == 21.5, "body fat stays a 0 to 100 percent")
        #expect(fat.sourceName == "Withings")
        #expect(!mapped.samples.contains { $0.quantity == .leanMass }, "an absent kind adds no sample, never a zero")
    }

    @Test func aSampleTheUserTypedIntoAppleHealthIsFlagged() {
        let mapped = BodyLogHealthMapping.map([.weight: .values([sample(.weight, 80, hoursAgo: 1, source: "Health", userEntered: true)])])
        #expect(mapped.samples.first?.typedIntoHealth == true)
    }

    @Test func eachAbsenceReasonMapsToItsStatus() {
        func status(_ absence: AppleHealthAbsence) -> BodyLogHealthStatus {
            BodyLogHealthMapping.map([.weight: .absent(absence), .bodyFat: .absent(absence), .leanMass: .absent(absence)]).status
        }
        #expect(status(.noSamples) == .noSamples)
        #expect(status(.notAuthorized) == .notShared)
        #expect(status(.switchedOff) == .switchedOff)
        #expect(status(.unavailable) == .unavailable)
        #expect(status(.queryFailed("locked")) == .failed)
        #expect(BodyLogHealthMapping.map([:]).samples.isEmpty)
    }

    @Test func otherAppleHealthKindsAreNotBodyQuantities() {
        for kind in AppleHealthSourceKind.allCases where ![.weight, .bodyFat, .leanMass].contains(kind) {
            #expect(BodyLogHealthMapping.bodyQuantity(kind) == nil, "\(kind)")
        }
        #expect(BodyLogHealthMapping.bodyQuantity(.weight) == .weight)
    }

    @Test func theWeightRangeMatchesTheFoodWeightStore() {
        #expect(BodyLogLimits.weightKilograms == FoodWeightEntry.validRange)
        #expect(BodyLogLimits.bodyFatPercent == FoodBodyComposition.bodyFatRange)
        #expect(BodyLogLimits.leanMassKilograms == FoodBodyComposition.leanMassRange)
    }
}

@Suite struct BodyLogProviderTests {
    private func provider(_ store: any BodyLogTypedStoring, health: [AppleHealthSourceKind: AppleHealthReadResult] = [:]) -> AppBodyLogProvider {
        AppBodyLogProvider(typed: store, health: StubHealth(results: health), announcesChanges: false)
    }

    @Test func aTypedWeightLandsInTheFoodWeightTableAndTheRestInBodyComposition() async throws {
        let rig = try TemporaryStore()
        defer { rig.cleanup() }
        let provider = provider(FoodBodyLogStore(food: rig.food))
        let input = BodyLogInput(weightKilograms: 78.4, bodyFatPercent: 21.5, leanMassKilograms: 61.2, measuredAt: now)
        let saved = try await provider.save(input, timeZoneIdentifier: "UTC")

        let weights = try rig.food.weights()
        #expect(weights.count == 1, "the Food lens reads the same reading")
        #expect(weights.first?.id == saved.id)
        #expect(weights.first?.kilograms == 78.4)
        let composition = try #require(try rig.food.bodyCompositions()[saved.id])
        #expect(composition.bodyFatPercent == 21.5)
        #expect(composition.leanMassKilograms == 61.2)

        let snapshot = await provider.snapshot(now: now)
        #expect(snapshot.typed == [saved])
    }

    @Test func aWeightWithoutBodyFatOrLeanMassWritesNoCompositionRow() async throws {
        let rig = try TemporaryStore()
        defer { rig.cleanup() }
        let provider = provider(FoodBodyLogStore(food: rig.food))
        let saved = try await provider.save(BodyLogInput(weightKilograms: 80, bodyFatPercent: nil, leanMassKilograms: nil, measuredAt: now),
                                            timeZoneIdentifier: "UTC")
        #expect(try rig.database.tableRowCounts()["body_composition"] == 0)
        let snapshot = await provider.snapshot(now: now)
        #expect(snapshot.typed.first?.bodyFatPercent == nil)
        #expect(snapshot.typed.first?.leanMassKilograms == nil)
        #expect(snapshot.typed.first?.id == saved.id)
    }

    @Test func aWeightTypedInFoodShowsInTheLogWithoutBodyFat() async throws {
        let rig = try TemporaryStore()
        defer { rig.cleanup() }
        try rig.food.saveWeight(FoodWeightEntry(measuredAt: now, timeZoneIdentifier: "UTC", kilograms: 77.7))
        let snapshot = await provider(FoodBodyLogStore(food: rig.food)).snapshot(now: now)
        #expect(snapshot.typed.map(\.weightKilograms) == [77.7])
        #expect(snapshot.typed.first?.bodyFatPercent == nil)
    }

    @Test func deletingAnEntryRemovesItsCompositionAndUndoBringsBothBack() async throws {
        let rig = try TemporaryStore()
        defer { rig.cleanup() }
        let provider = provider(FoodBodyLogStore(food: rig.food))
        let saved = try await provider.save(BodyLogInput(weightKilograms: 78.4, bodyFatPercent: 21.5, leanMassKilograms: nil, measuredAt: now),
                                            timeZoneIdentifier: "UTC")
        try await provider.delete(id: saved.id)
        #expect(try rig.database.tableRowCounts()["food_weight"] == 0)
        #expect(try rig.database.tableRowCounts()["body_composition"] == 0)
        #expect(await provider.snapshot(now: now).typed.isEmpty)

        try await provider.restore(saved)
        let back = await provider.snapshot(now: now).typed
        #expect(back == [saved], "same id, same time, same values")
    }

    @Test func aValueOutsideTheRangesIsRefusedAndStoresNothing() async throws {
        let rig = try TemporaryStore()
        defer { rig.cleanup() }
        let provider = provider(FoodBodyLogStore(food: rig.food))
        await #expect(throws: (any Error).self) {
            _ = try await provider.save(BodyLogInput(weightKilograms: 78, bodyFatPercent: 90, leanMassKilograms: nil, measuredAt: now),
                                        timeZoneIdentifier: "UTC")
        }
        await #expect(throws: (any Error).self) {
            _ = try await provider.save(BodyLogInput(weightKilograms: 78, bodyFatPercent: nil, leanMassKilograms: 78, measuredAt: now),
                                        timeZoneIdentifier: "UTC")
        }
        #expect(try rig.database.tableRowCounts()["food_weight"] == 0, "the weight is not stored without its composition")
    }

    @Test func theLogMergesTypedEntriesWithStubbedAppleHealthResultsAndNeverCombinesThem() async throws {
        let store = MemoryBodyLogStore()
        let provider = provider(store, health: [
            .weight: .values([sample(.weight, 79.1, hoursAgo: 0)]),
            .bodyFat: .absent(.noSamples),
            .leanMass: .absent(.noSamples)])
        _ = try await provider.save(BodyLogInput(weightKilograms: 78.4, bodyFatPercent: nil, leanMassKilograms: nil, measuredAt: now),
                                    timeZoneIdentifier: "UTC")
        let snapshot = await provider.snapshot(now: now)
        #expect(snapshot.healthStatus == .reading)
        let entries = BodyLogMerge.entries(typed: snapshot.typed, health: snapshot.health)
        #expect(entries.count == 2)
        #expect(entries.compactMap(\.weightKilograms) == [78.4, 79.1])
        let summary = BodyLogSummary.make(entries)
        #expect(summary.weight?.provenance == .typedIn)
        #expect(summary.bodyFat == nil, "no body fat anywhere stays absent")
    }

    @Test func nothingTypedAndNoAppleHealthAccessGivesAnEmptyLogWithTheReason() async {
        let provider = provider(MemoryBodyLogStore(), health: [.weight: .absent(.notAuthorized), .bodyFat: .absent(.notAuthorized),
                                                               .leanMass: .absent(.notAuthorized)])
        let snapshot = await provider.snapshot(now: now)
        #expect(snapshot.typed.isEmpty && snapshot.health.isEmpty)
        #expect(snapshot.healthStatus == .notShared)
        #expect(BodyLogMerge.entries(typed: snapshot.typed, health: snapshot.health).isEmpty)
    }

    @Test func aBuildWithoutADatabaseRefusesToSaveAndReadsEmpty() async {
        let provider = provider(UnavailableBodyLogStore())
        #expect(await provider.snapshot(now: now).typed.isEmpty)
        await #expect(throws: (any Error).self) {
            _ = try await provider.save(BodyLogInput(weightKilograms: 78, bodyFatPercent: nil, leanMassKilograms: nil, measuredAt: now),
                                        timeZoneIdentifier: "UTC")
        }
    }

    @Test func appleHealthEntriesCarryNothingToDelete() async throws {
        let provider = provider(MemoryBodyLogStore(), health: [.weight: .values([sample(.weight, 79.1, hoursAgo: 4)])])
        let snapshot = await provider.snapshot(now: now)
        let entries = BodyLogMerge.entries(typed: snapshot.typed, health: snapshot.health)
        #expect(entries.allSatisfy { $0.typedID == nil && !$0.isTyped })
    }
}

@MainActor @Suite struct BodyLogSummaryLoaderTests {
    @Test func theBodyScreenReadsTheNewestTypedOrAppleHealthValueWithItsSource() async throws {
        let store = MemoryBodyLogStore([BodyLogTypedRecord(measuredAt: now.addingTimeInterval(-86_400), timeZoneIdentifier: "UTC",
                                                           weightKilograms: 78.4, bodyFatPercent: 20.0)])
        let provider = AppBodyLogProvider(typed: store, health: StubHealth(results: [
            .weight: .values([sample(.weight, 79.1, hoursAgo: 2)])]), announcesChanges: false)
        let loader = BodyLogSummaryLoader(provider: provider, now: { now })
        #expect(loader.summary == nil, "nothing is claimed before the first read")
        await loader.load()
        let summary = try #require(loader.summary)
        #expect(summary.weight?.value == 79.1)
        #expect(summary.weight?.provenance == .appleHealth(source: "Withings", typedIn: false))
        #expect(summary.bodyFat?.value == 20.0)
        #expect(summary.bodyFat?.provenance == .typedIn)
        #expect(summary.leanMass == nil)
    }

    @Test func aFreshInstallReadsAnEmptySummaryNotZeros() async throws {
        let provider = AppBodyLogProvider(typed: MemoryBodyLogStore(), health: NoBodyLogHealth(status: .unavailable), announcesChanges: false)
        let loader = BodyLogSummaryLoader(provider: provider, now: { now })
        await loader.load()
        #expect(loader.summary == .empty)
    }

    @Test func savingPostsTheChangeNotification() async throws {
        let provider = AppBodyLogProvider(typed: MemoryBodyLogStore(), health: NoBodyLogHealth())
        let posted = Locked(false)
        let token = NotificationCenter.default.addObserver(forName: looprBodyLogChanged, object: nil, queue: nil) { _ in posted.set(true) }
        defer { NotificationCenter.default.removeObserver(token) }
        _ = try await provider.save(BodyLogInput(weightKilograms: 78, bodyFatPercent: nil, leanMassKilograms: nil, measuredAt: now),
                                    timeZoneIdentifier: "UTC")
        #expect(posted.value)
    }
}

@Suite struct BodyLogRouteTests {
    @Test func theBodyLogOpensFromTheBodyScreenAndFromTheStartAtArgument() {
        #expect(MainTabLaunchState.restoring("body-log") == .init(tab: .data, healthPath: [.bodyHome, .bodyLog]))
        #expect(MainTabLaunchState.startingAt(["--loopr-start-at=body-log"]) == .init(tab: .data, healthPath: [.bodyHome, .bodyLog]))
        #expect(MainTabLaunchState.restoring("body") == .init(tab: .data, healthPath: [.bodyHome]))
        #expect(AppHealthRoute.bodyLog != AppHealthRoute.bodyHome)
    }
}

#if DEBUG
@Suite struct BodyLogFixtureTests {
    @Test func theFixtureHasAppleHealthWeightsAndNoBodyFat() async {
        let samples = BodyLogFixtures.samples(now: now)
        #expect(samples.allSatisfy { $0.quantity == .weight && $0.sourceName == "Withings" })
        let reading = await FixtureBodyLogHealth(samples: samples).read(now: now)
        #expect(reading.status == .reading)
        let summary = BodyLogSummary.make(BodyLogMerge.entries(typed: [], health: reading.samples))
        #expect(summary.weight?.value == 79.2)
        #expect(summary.bodyFat == nil)
    }
}
#endif

private nonisolated final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func set(_ value: Value) { lock.withLock { stored = value } }
}
