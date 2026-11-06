import BodyKit
import Combine
import DomainKit
import FoodKit
import Foundation
import HealthKitBridge

// LV-08b step 5: what the weight and body composition log reads and writes. This file maps stored entries and
// Apple Health reads onto BodyKit's plain types and decides nothing. A typed entry keeps its weight in the Food
// weight table, so the Food lens reads the same readings, and its body fat and lean mass in `body_composition`
// (`storage-022-body-composition`). Apple Health is read only: nothing here writes to it (DEC-12.15).

/// Posted after a typed entry is saved, deleted or put back, so the Body screen and the log read again.
nonisolated let looprBodyLogChanged = Notification.Name("com.loopr.body.log-changed")

// MARK: Typed entries

/// Where typed entries are kept: the app's database, or memory for fixture launches.
nonisolated protocol BodyLogTypedStoring: Sendable {
    func records() async throws -> [BodyLogTypedRecord]
    func save(_ record: BodyLogTypedRecord) async throws
    func delete(id: UUID) async throws
}

/// Weights in `food_weight` and the body fat and lean mass typed with them in `body_composition`.
nonisolated struct FoodBodyLogStore: BodyLogTypedStoring {
    let food: FoodStore

    @concurrent
    func records() async throws -> [BodyLogTypedRecord] {
        let weights = try food.weights()
        let compositions = try food.bodyCompositions()
        return weights.map { entry in
            BodyLogTypedRecord(id: entry.id, measuredAt: entry.measuredAt, timeZoneIdentifier: entry.timeZoneIdentifier,
                               weightKilograms: entry.kilograms, bodyFatPercent: compositions[entry.id]?.bodyFatPercent,
                               leanMassKilograms: compositions[entry.id]?.leanMassKilograms)
        }
    }

    @concurrent
    func save(_ record: BodyLogTypedRecord) async throws {
        let entry = try FoodWeightEntry(id: record.id, measuredAt: record.measuredAt,
                                        timeZoneIdentifier: record.timeZoneIdentifier, kilograms: record.weightKilograms)
        try food.saveWeight(entry, bodyFatPercent: record.bodyFatPercent, leanMassKilograms: record.leanMassKilograms)
    }

    @concurrent
    func delete(id: UUID) async throws { try food.deleteWeight(id: id) }
}

/// The fixture launches' entries. They live for the launch and never reach a stored database.
actor MemoryBodyLogStore: BodyLogTypedStoring {
    private var stored: [UUID: BodyLogTypedRecord]

    init(_ records: [BodyLogTypedRecord] = []) { stored = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) }) }

    func records() -> [BodyLogTypedRecord] { Array(stored.values) }
    func save(_ record: BodyLogTypedRecord) { stored[record.id] = record }
    func delete(id: UUID) { stored[id] = nil }
}

/// A build without a database cannot keep typed entries, so saving says so.
nonisolated struct UnavailableBodyLogStore: BodyLogTypedStoring {
    struct Unavailable: Error {}
    func records() async throws -> [BodyLogTypedRecord] { [] }
    func save(_ record: BodyLogTypedRecord) async throws { throw Unavailable() }
    func delete(id: UUID) async throws { throw Unavailable() }
}

// MARK: Apple Health

/// What Apple Health gave for the three quantities.
nonisolated protocol BodyLogHealthReading: Sendable {
    func read(now: Date) async -> (samples: [BodyLogHealthSample], status: BodyLogHealthStatus)
}

nonisolated enum BodyLogHealthMapping {
    /// The days of Apple Health history the log reads.
    static let windowDays = 365

    static func bodyQuantity(_ kind: AppleHealthSourceKind) -> BodyLogQuantity? {
        switch kind {
        case .weight: .weight
        case .bodyFat: .bodyFat
        case .leanMass: .leanMass
        case .vo2Max, .daylight, .bloodPressure, .bloodGlucose, .steps: nil
        }
    }

    static func status(_ result: AppleHealthReadResult) -> BodyLogHealthStatus {
        switch result {
        case .values(let samples): samples.isEmpty ? .noSamples : .reading
        case .absent(let reason):
            switch reason {
            case .noSamples: .noSamples
            case .notAuthorized: .notShared
            case .switchedOff: .switchedOff
            case .unavailable: .unavailable
            case .queryFailed: .failed
            }
        }
    }

    /// The samples in Apple Health's canonical units (kilograms, percent), each with the app or device that wrote it.
    /// A kind that came back absent adds nothing, never a zero.
    static func map(_ results: [AppleHealthSourceKind: AppleHealthReadResult])
        -> (samples: [BodyLogHealthSample], status: BodyLogHealthStatus) {
        var samples: [BodyLogHealthSample] = []
        var statuses: [BodyLogHealthStatus] = []
        for kind in [AppleHealthSourceKind.weight, .bodyFat, .leanMass] {
            guard let result = results[kind], let quantity = bodyQuantity(kind) else { statuses.append(.noSamples); continue }
            statuses.append(status(result))
            for sample in result.samples where sample.value.isFinite {
                samples.append(BodyLogHealthSample(quantity: quantity, value: sample.value, measuredAt: sample.end,
                                                   sourceName: sample.provenance.label ?? "",
                                                   typedIntoHealth: sample.provenance.wasUserEntered == true))
            }
        }
        return (samples, BodyLogHealthStatus.combine(statuses))
    }
}

/// Reads weight, body fat and lean mass through `AppleHealthSources`, which honours the person's switches.
nonisolated struct LiveBodyLogHealth: BodyLogHealthReading {
    let sources: AppleHealthSources
    var calendar: Calendar = .current

    @concurrent
    func read(now: Date) async -> (samples: [BodyLogHealthSample], status: BodyLogHealthStatus) {
        var results: [AppleHealthSourceKind: AppleHealthReadResult] = [:]
        for kind in [AppleHealthSourceKind.weight, .bodyFat, .leanMass] {
            results[kind] = await sources.read(kind, lastDays: BodyLogHealthMapping.windowDays, endingAt: now, calendar: calendar)
        }
        return BodyLogHealthMapping.map(results)
    }
}

/// A build or launch without Apple Health.
nonisolated struct NoBodyLogHealth: BodyLogHealthReading {
    var status: BodyLogHealthStatus = .unavailable
    func read(now: Date) async -> (samples: [BodyLogHealthSample], status: BodyLogHealthStatus) { ([], status) }
}

// MARK: Provider

nonisolated struct AppBodyLogProvider: BodyLogProviding {
    let typed: any BodyLogTypedStoring
    let health: any BodyLogHealthReading
    /// Posts `looprBodyLogChanged` after a write. Tests turn it off.
    var announcesChanges = true

    func snapshot(now: Date) async -> BodyLogSnapshot {
        async let stored = try? typed.records()
        async let read = health.read(now: now)
        let (records, healthRead) = await (stored, read)
        return BodyLogSnapshot(typed: records ?? [], health: healthRead.samples, healthStatus: healthRead.status)
    }

    func save(_ input: BodyLogInput, timeZoneIdentifier: String) async throws -> BodyLogTypedRecord {
        let record = BodyLogTypedRecord(measuredAt: input.measuredAt, timeZoneIdentifier: timeZoneIdentifier,
                                        weightKilograms: input.weightKilograms, bodyFatPercent: input.bodyFatPercent,
                                        leanMassKilograms: input.leanMassKilograms)
        try await typed.save(record)
        announce()
        return record
    }

    func delete(id: UUID) async throws {
        try await typed.delete(id: id)
        announce()
    }

    func restore(_ record: BodyLogTypedRecord) async throws {
        try await typed.save(record)
        announce()
    }

    private func announce() {
        guard announcesChanges else { return }
        NotificationCenter.default.post(name: looprBodyLogChanged, object: nil)
    }
}

@MainActor
enum BodyLogProviderFactory {
    static func make(environment: AppEnvironment, repositories: ProductRepositoryContainer?) -> AppBodyLogProvider {
        if let persistent = repositories?.persistent {
            return AppBodyLogProvider(typed: FoodBodyLogStore(food: persistent.food),
                                      health: LiveBodyLogHealth(sources: persistent.healthSync.appleHealthSources()))
        }
        #if DEBUG
        if repositories?.isFixtureComposition != false { return BodyLogFixtures.provider(for: environment) }
        #endif
        return AppBodyLogProvider(typed: UnavailableBodyLogStore(), health: NoBodyLogHealth())
    }
}

// MARK: Summary for the Body screen

/// Reads the log's newest values for the Body screen. A failed or empty read leaves the summary empty, so the
/// screen falls back to the profile.
@MainActor
final class BodyLogSummaryLoader: ObservableObject {
    @Published private(set) var summary: BodyLogSummary?
    private let provider: any BodyLogProviding
    private let now: @Sendable () -> Date

    init(provider: any BodyLogProviding, now: @escaping @Sendable () -> Date) {
        self.provider = provider
        self.now = now
    }

    func load() async {
        let snapshot = await provider.snapshot(now: now())
        guard !Task.isCancelled else { return }
        let next = BodyLogSummary.make(BodyLogMerge.entries(typed: snapshot.typed, health: snapshot.health))
        if next != summary { summary = next }
    }
}

#if DEBUG
/// The fixture launches' log: no typed entries, and for the populated launch two weights a smart scale wrote to
/// Apple Health, with no body fat, so the absent state shows. The state lives for the launch.
nonisolated enum BodyLogFixtures {
    private static let stores = FixtureStores()

    private nonisolated final class FixtureStores: @unchecked Sendable {
        private let lock = NSLock()
        private var made: [String: MemoryBodyLogStore] = [:]
        func store(_ key: String) -> MemoryBodyLogStore {
            lock.withLock {
                if let existing = made[key] { return existing }
                let created = MemoryBodyLogStore()
                made[key] = created
                return created
            }
        }
    }

    static func provider(for environment: AppEnvironment) -> AppBodyLogProvider {
        let key = environment.composition.rawValue
        let now = environment.dateProvider.now()
        let health: any BodyLogHealthReading = environment.composition == .populated
            ? FixtureBodyLogHealth(samples: samples(now: now)) : NoBodyLogHealth(status: .noSamples)
        return AppBodyLogProvider(typed: stores.store(key), health: health)
    }

    static func samples(now: Date) -> [BodyLogHealthSample] {
        [BodyLogHealthSample(quantity: .weight, value: 79.2, measuredAt: now.addingTimeInterval(-3 * 86_400), sourceName: "Withings"),
         BodyLogHealthSample(quantity: .weight, value: 79.8, measuredAt: now.addingTimeInterval(-10 * 86_400), sourceName: "Withings")]
    }
}

nonisolated struct FixtureBodyLogHealth: BodyLogHealthReading {
    let samples: [BodyLogHealthSample]
    func read(now: Date) async -> (samples: [BodyLogHealthSample], status: BodyLogHealthStatus) {
        (samples, samples.isEmpty ? .noSamples : .reading)
    }
}
#endif
