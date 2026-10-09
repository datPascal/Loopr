import Foundation

public enum HealthObjectIdentifier {
    public static func identifier(for type: HealthDataType) -> String {
        switch type {
        case .dateOfBirth: "HKCharacteristicTypeIdentifierDateOfBirth"
        case .vo2Max: "HKQuantityTypeIdentifierVO2Max"
        case .height: "HKQuantityTypeIdentifierHeight"
        case .bodyMass: "HKQuantityTypeIdentifierBodyMass"
        case .bodyFatPercentage: "HKQuantityTypeIdentifierBodyFatPercentage"
        case .leanBodyMass: "HKQuantityTypeIdentifierLeanBodyMass"
        }
    }

    public static func identifier(for metric: ExportMetricKind) -> String {
        switch metric {
        case .heartRate: "HKQuantityTypeIdentifierHeartRate"
        case .restingHeartRate: "HKQuantityTypeIdentifierRestingHeartRate"
        case .heartRateVariabilitySDNN: "HKQuantityTypeIdentifierHeartRateVariabilitySDNN"
        case .respiratoryRate: "HKQuantityTypeIdentifierRespiratoryRate"
        case .sleepStages: "HKCategoryTypeIdentifierSleepAnalysis"
        case .steps: "HKQuantityTypeIdentifierStepCount"
        case .activeEnergy: "HKQuantityTypeIdentifierActiveEnergyBurned"
        case .completedWorkout: "HKWorkoutTypeIdentifier"
        }
    }
}

public enum HealthDependentScreenState: Equatable, Sendable {
    case loading
    case valueAvailable
    case permissionDenied
    case unavailable
    case recoverableError(String)
}

public enum HealthRevocationProjection {
    public static func screenState(
        authorization: HealthAuthorizationState,
        hasCachedValue: Bool
    ) -> HealthDependentScreenState {
        switch authorization {
        case .authorized: hasCachedValue ? .valueAvailable : .loading
        case .denied: .permissionDenied
        case .unavailable: .unavailable
        case .notDetermined: .loading
        }
    }
}

public enum WorkoutFinalizationSource: String, CaseIterable, Codable, Sendable {
    case manual, detected, live, recovered
}

public struct WorkoutFinalizationEnvelope: Equatable, Codable, Sendable {
    public let workoutID: UUID
    public let source: WorkoutFinalizationSource
    public let startedAt: Date
    public let endedAt: Date

    public init(workoutID: UUID, source: WorkoutFinalizationSource, startedAt: Date, endedAt: Date) {
        self.workoutID = workoutID
        self.source = source
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

public enum WorkoutFinalizationStage: String, CaseIterable, Codable, Hashable, Sendable {
    case commitLocalData
    case enqueueHealthKitExport
    case publishSurfaceSnapshot
    case endLiveActivity
    case clearActiveState
}

public protocol WorkoutFinalizationEffects: Sendable {
    func commitLocalData(_ workout: WorkoutFinalizationEnvelope) async throws
    func enqueueHealthKitExport(_ workout: WorkoutFinalizationEnvelope) async throws
    func publishSurfaceSnapshot(_ workout: WorkoutFinalizationEnvelope) async throws
    func endLiveActivity(_ workout: WorkoutFinalizationEnvelope) async throws
    func clearActiveState(_ workout: WorkoutFinalizationEnvelope) async throws
}

public actor WorkoutHealthExportFinalizer {
    private let effects: any WorkoutFinalizationEffects
    private let persistenceURL: URL?
    private var completedStages: [UUID: Set<WorkoutFinalizationStage>] = [:]

    public init(effects: any WorkoutFinalizationEffects, persistenceURL: URL? = nil) {
        self.effects = effects; self.persistenceURL = persistenceURL
        guard let persistenceURL, let data = try? Data(contentsOf: persistenceURL),
              let restored = try? JSONDecoder().decode(
                [UUID: Set<WorkoutFinalizationStage>].self, from: data
              ) else { return }
        completedStages = restored
    }

    /// Runs the required five-stage finalization barrier once per workout.
    /// Active state is deliberately cleared last and remains recoverable if
    /// any durable enqueue/snapshot/activity stage fails.
    public func finalize(_ workout: WorkoutFinalizationEnvelope) async throws {
        for stage in WorkoutFinalizationStage.allCases
            where completedStages[workout.workoutID, default: []].contains(stage) == false {
            switch stage {
            case .commitLocalData: try await effects.commitLocalData(workout)
            case .enqueueHealthKitExport: try await effects.enqueueHealthKitExport(workout)
            case .publishSurfaceSnapshot: try await effects.publishSurfaceSnapshot(workout)
            case .endLiveActivity: try await effects.endLiveActivity(workout)
            case .clearActiveState: try await effects.clearActiveState(workout)
            }
            completedStages[workout.workoutID, default: []].insert(stage)
            persist()
        }
    }

    private func persist() {
        guard let persistenceURL, let data = try? JSONEncoder().encode(completedStages) else { return }
        try? FileManager.default.createDirectory(at: persistenceURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: persistenceURL, options: .atomic)
    }
}

#if canImport(HealthKit)
import HealthKit

public enum LiveHealthKitError: Error, Equatable, Sendable {
    case unavailable
    case unsupportedType(String)
    case invalidUnit(String)
    case queryFailed(String)
}

/// A type with no write decision cannot contain samples this app saved.
/// A denied type may contain older exports after permission was revoked, so
/// its deletion error must be reported.
public enum HealthKitDeletionErrorPolicy {
    public static func canIgnore(_ error: NSError) -> Bool {
        error.domain == HKError.errorDomain
            && error.code == HKError.errorAuthorizationNotDetermined.rawValue
    }
}

public final class LiveHealthKitClient: @unchecked Sendable,
    HealthAuthorizationClient, AnchoredHealthQueryClient, HealthExportClient,
    HealthSampleDeletionClient, HealthSyncClient {
    private let store: HKHealthStore

    public init(store: HKHealthStore = HKHealthStore()) { self.store = store }

    public func writeAuthorization(for metric: ExportMetricKind) async -> HealthAuthorizationState {
        guard HKHealthStore.isHealthDataAvailable(), let type = try? sampleType(for: metric) else { return .unavailable }
        switch store.authorizationStatus(for: type) {
        case .sharingAuthorized: return .authorized
        case .sharingDenied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .unavailable
        }
    }

    public func requestWriteAuthorization(for metrics: Set<ExportMetricKind>) async throws {
        guard try await request(HealthAuthorizationScope(share: metrics)) else {
            throw HealthAuthorizationError.cancelled
        }
    }

    public func save(_ sample: HealthSyncSample, version: Int) async throws {
        guard await writeAuthorization(for: sample.metric) == .authorized else { throw HealthSyncError.permissionRequired }
        guard sample.value.isFinite, sample.start <= sample.end else { throw HealthSyncError.invalidSamples }
        let metadata: [String: Any] = [
            HKMetadataKeySyncIdentifier: sample.identifier,
            HKMetadataKeySyncVersion: version,
            HKMetadataKeyTimeZone: sample.timeZone,
            "com.loopr.provenance": sample.provenance,
            "com.loopr.algorithm": sample.algorithm
        ]
        if sample.metric == .completedWorkout {
            let configuration = HKWorkoutConfiguration()
            configuration.activityType = Self.workoutActivity(sample.workoutActivity)
            configuration.locationType = .unknown
            let builder = HKWorkoutBuilder(healthStore: store, configuration: configuration, device: nil)
            do {
                try await builder.beginCollection(at: sample.start)
                try await builder.addMetadata(metadata)
                try await builder.endCollection(at: sample.end)
                _ = try await builder.finishWorkout()
            } catch {
                builder.discardWorkout()
                throw error
            }
            return
        }
        let object: HKSample
        if sample.metric == .sleepStages {
            guard let type = try sampleType(for: sample.metric) as? HKCategoryType,
                  let category = Int(exactly: sample.value), [0, 1, 2, 3, 4, 5].contains(category) else {
                throw HealthSyncError.invalidSamples
            }
            object = HKCategorySample(type: type, value: category, start: sample.start, end: sample.end, metadata: metadata)
        } else {
            guard let type = try sampleType(for: sample.metric) as? HKQuantityType else { throw HealthSyncError.invalidSamples }
            object = HKQuantitySample(type: type,
                quantity: HKQuantity(unit: try Self.unit(named: "", metric: sample.metric), doubleValue: sample.value),
                start: sample.start, end: sample.end, metadata: metadata)
        }
        try await store.save(object)
    }

    public func remove(metric: ExportMetricKind, identifiers: [String]) async throws {
        guard !identifiers.isEmpty else { return }
        guard await writeAuthorization(for: metric) == .authorized else { throw HealthSyncError.permissionRequired }
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(from: HKSource.default()),
            HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncIdentifier, allowedValues: identifiers)
        ])
        let type = try sampleType(for: metric)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            store.deleteObjects(of: type, predicate: predicate) { success, _, error in
                if let error { continuation.resume(throwing: error) }
                else if success { continuation.resume() }
                else { continuation.resume(throwing: LiveHealthKitError.queryFailed("Apple Health could not remove an outdated sample.")) }
            }
        }
    }

    public static func workoutActivity(_ value: String?) -> HKWorkoutActivityType {
        switch value {
        case "run": .running
        case "cycle": .cycling
        case "walk": .walking
        case "hike": .hiking
        case "strength": .traditionalStrengthTraining
        case "swim": .swimming
        case "cardio": .mixedCardio
        case "yoga": .yoga
        case "hiit": .highIntensityIntervalTraining
        default: .other
        }
    }

    public func request(_ scope: HealthAuthorizationScope) async throws -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { throw LiveHealthKitError.unavailable }
        let readTypes = try Set(scope.read.map(objectType(for:)))
        let shareTypes = try Set(scope.share.map(sampleType(for:)))
        return try await withCheckedThrowingContinuation { continuation in
            store.requestAuthorization(toShare: shareTypes, read: readTypes) { granted, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: granted) }
            }
        }
    }

    public func status(for type: HealthDataType) async -> HealthAuthorizationState {
        guard HKHealthStore.isHealthDataAvailable(), let sample = try? sampleType(for: type) else {
            return .unavailable
        }
        switch store.authorizationStatus(for: sample) {
        case .sharingAuthorized: return .authorized
        case .sharingDenied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .unavailable
        }
    }

    public func changes(
        for type: HealthDataType,
        after anchorData: Data?
    ) async throws -> AnchoredHealthChanges {
        guard type != .dateOfBirth else {
            throw LiveHealthKitError.unsupportedType(HealthObjectIdentifier.identifier(for: type))
        }
        let sampleType = try sampleType(for: type)
        let anchor: HKQueryAnchor? = try anchorData.map {
            guard let value = try NSKeyedUnarchiver.unarchivedObject(
                ofClass: HKQueryAnchor.self,
                from: $0
            ) else { throw LiveHealthKitError.queryFailed("Unreadable HealthKit anchor") }
            return value
        }
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(
                type: sampleType,
                predicate: nil,
                anchor: anchor,
                limit: HKObjectQueryNoLimit
            ) { [weak self] _, samples, deleted, nextAnchor, error in
                guard let self else {
                    continuation.resume(throwing: LiveHealthKitError.queryFailed("HealthKit client released"))
                    return
                }
                if let error {
                    continuation.resume(throwing: LiveHealthKitError.queryFailed(String(describing: error)))
                    return
                }
                do {
                    let imported = try (samples ?? []).compactMap { try self.importedSample($0, as: type) }
                    let anchorData = try nextAnchor.map {
                        try NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true)
                    } ?? Data()
                    continuation.resume(returning: AnchoredHealthChanges(
                        samples: imported,
                        deletedSampleIDs: (deleted ?? []).map(\.uuid),
                        nextAnchor: anchorData
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            store.execute(query)
        }
    }

    public func save(_ object: HealthExportObject) async throws {
        if object.metric == .completedWorkout {
            try await saveWorkout(object)
            return
        }
        let sample = try exportSample(object)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            store.save(sample) { success, error in
                if let error { continuation.resume(throwing: error) }
                else if success { continuation.resume() }
                else { continuation.resume(throwing: LiveHealthKitError.queryFailed("HealthKit rejected save")) }
            }
        }
    }

    public func deleteLooprCreatedSamples() async throws -> Int {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw LiveHealthKitError.unavailable
        }
        let predicate = HKQuery.predicateForObjects(from: HKSource.default())
        var deletedCount = 0
        // People grant Health write access per type, so the first type Loopr
        // was never allowed to write throws. Stopping there would leave every
        // later type's samples in Health while the app reports the delete as
        // failed. Each type is attempted on its own and the first real failure
        // is reported only after all of them have been tried.
        var firstFailure: (any Error)?
        for metric in ExportMetricKind.allCases {
            do {
                let type = try sampleType(for: metric)
                deletedCount += try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Int, any Error>) in
                    store.deleteObjects(of: type, predicate: predicate) { success, count, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else if success {
                            continuation.resume(returning: count)
                        } else {
                            continuation.resume(throwing: LiveHealthKitError.queryFailed(
                                "HealthKit rejected sample removal for \(metric.rawValue)"
                            ))
                        }
                    }
                }
            } catch let error as NSError {
                // A denied type might contain exports saved before access was
                // revoked. Only a never-requested write type is safe to skip.
                if HealthKitDeletionErrorPolicy.canIgnore(error) {
                    continue
                }
                if firstFailure == nil { firstFailure = error }
            }
        }
        if let firstFailure { throw firstFailure }
        return deletedCount
    }

    private func saveWorkout(_ object: HealthExportObject) async throws {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .other
        configuration.locationType = .unknown
        let builder = HKWorkoutBuilder(
            healthStore: store,
            configuration: configuration,
            device: nil
        )
        try await builder.beginCollection(at: object.startDate)
        try await builder.addMetadata([HKMetadataKeyExternalUUID: object.id.uuidString])
        try await builder.endCollection(at: object.endDate)
        _ = try await builder.finishWorkout()
    }

    private func objectType(for type: HealthDataType) throws -> HKObjectType {
        switch type {
        case .dateOfBirth:
            guard let value = HKObjectType.characteristicType(forIdentifier: .dateOfBirth) else {
                throw LiveHealthKitError.unsupportedType(HealthObjectIdentifier.identifier(for: type))
            }
            return value
        default: return try sampleType(for: type)
        }
    }

    private func sampleType(for type: HealthDataType) throws -> HKSampleType {
        let identifier: HKQuantityTypeIdentifier = switch type {
        case .vo2Max: .vo2Max
        case .height: .height
        case .bodyMass: .bodyMass
        case .bodyFatPercentage: .bodyFatPercentage
        case .leanBodyMass: .leanBodyMass
        case .dateOfBirth:
            throw LiveHealthKitError.unsupportedType(HealthObjectIdentifier.identifier(for: type))
        }
        guard let value = HKObjectType.quantityType(forIdentifier: identifier) else {
            throw LiveHealthKitError.unsupportedType(identifier.rawValue)
        }
        return value
    }

    private func sampleType(for metric: ExportMetricKind) throws -> HKSampleType {
        switch metric {
        case .sleepStages:
            guard let value = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
                throw LiveHealthKitError.unsupportedType(HealthObjectIdentifier.identifier(for: metric))
            }
            return value
        case .completedWorkout: return HKObjectType.workoutType()
        case .heartRate, .restingHeartRate, .heartRateVariabilitySDNN, .respiratoryRate, .steps, .activeEnergy:
            let identifier: HKQuantityTypeIdentifier
            switch metric {
            case .heartRate: identifier = .heartRate
            case .restingHeartRate: identifier = .restingHeartRate
            case .heartRateVariabilitySDNN: identifier = .heartRateVariabilitySDNN
            case .respiratoryRate: identifier = .respiratoryRate
            case .steps: identifier = .stepCount
            case .activeEnergy: identifier = .activeEnergyBurned
            case .sleepStages, .completedWorkout:
                throw LiveHealthKitError.unsupportedType(HealthObjectIdentifier.identifier(for: metric))
            }
            guard let value = HKObjectType.quantityType(forIdentifier: identifier) else {
                throw LiveHealthKitError.unsupportedType(identifier.rawValue)
            }
            return value
        }
    }

    private func importedSample(_ sample: HKSample, as type: HealthDataType) throws -> ImportedHealthSample? {
        guard let quantity = sample as? HKQuantitySample else { return nil }
        let unit: HKUnit = switch type {
        case .vo2Max: HKUnit(from: "ml/kg*min")
        case .height: .meter()
        case .bodyMass, .leanBodyMass: .gramUnit(with: .kilo)
        case .bodyFatPercentage: .percent()
        case .dateOfBirth: throw LiveHealthKitError.unsupportedType(HealthObjectIdentifier.identifier(for: type))
        }
        return ImportedHealthSample(
            id: sample.uuid,
            type: type,
            source: sample.sourceRevision.source.name,
            device: sample.device?.name,
            unit: unit.unitString,
            value: quantity.quantity.doubleValue(for: unit),
            startDate: sample.startDate,
            endDate: sample.endDate,
            importedAt: Date(),
            deletionState: .active
        )
    }

    private func exportSample(_ object: HealthExportObject) throws -> HKSample {
        if object.metric == .sleepStages {
            guard let type = try sampleType(for: object.metric) as? HKCategoryType else {
                throw LiveHealthKitError.unsupportedType(HealthObjectIdentifier.identifier(for: object.metric))
            }
            return HKCategorySample(
                type: type,
                value: Int(object.value),
                start: object.startDate,
                end: object.endDate,
                metadata: [HKMetadataKeyExternalUUID: object.id.uuidString]
            )
        }
        guard let type = try sampleType(for: object.metric) as? HKQuantityType else {
            throw LiveHealthKitError.unsupportedType(HealthObjectIdentifier.identifier(for: object.metric))
        }
        let unit = try Self.unit(named: object.unit, metric: object.metric)
        return HKQuantitySample(
            type: type,
            quantity: HKQuantity(unit: unit, doubleValue: object.value),
            start: object.startDate,
            end: object.endDate,
            metadata: [HKMetadataKeyExternalUUID: object.id.uuidString]
        )
    }

    private static func unit(named unit: String, metric: ExportMetricKind) throws -> HKUnit {
        switch metric {
        case .heartRate, .restingHeartRate, .respiratoryRate: return HKUnit.count().unitDivided(by: .minute())
        case .heartRateVariabilitySDNN: return .secondUnit(with: .milli)
        case .steps: return .count()
        case .activeEnergy: return .kilocalorie()
        case .sleepStages, .completedWorkout: throw LiveHealthKitError.invalidUnit(unit)
        }
    }
}
#endif
