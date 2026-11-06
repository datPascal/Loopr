import Foundation

#if canImport(HealthKit)
import HealthKit

/// Reads workouts other apps saved to Apple Health, and the heart rate inside
/// them (R1-VET-01). It never writes. `LiveHealthHistoryClient` asks for read
/// access to `readTypes` in the same sheet as the heart rate history.
public final class LiveAppleHealthWorkoutStore: AppleHealthWorkoutStore, @unchecked Sendable {
    private let store: HKHealthStore

    public init(store: HKHealthStore = HKHealthStore()) { self.store = store }

    /// Workouts, their heart rate, energy and distance. Keep in step with
    /// `NSHealthShareUsageDescription`.
    public static var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [HKObjectType.workoutType()]
        let quantities: [HKQuantityTypeIdentifier] = [
            .heartRate, .activeEnergyBurned, .distanceWalkingRunning, .distanceCycling, .distanceSwimming, .distanceRowing
        ]
        for identifier in quantities { types.insert(HKQuantityType(identifier)) }
        return types
    }

    public func access() async -> AppleHealthStoreAccess {
        guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }
        return await withCheckedContinuation { continuation in
            store.getRequestStatusForAuthorization(toShare: [], read: [HKObjectType.workoutType()]) { status, error in
                continuation.resume(returning: error == nil && status == .shouldRequest ? .notRequested : .requested)
            }
        }
    }

    public func workouts(from start: Date, to end: Date, limit: Int,
                         excludingBundlePrefixes: [String]) async throws -> [AppleHealthRawWorkout]? {
        guard HKHealthStore.isHealthDataAvailable() else { throw AppleHealthStoreError.unavailable }
        do {
            let all = try await HKSourceQueryDescriptor(predicate: .workout()).result(for: store)
            guard let sources = Self.included(all, excluding: excludingBundlePrefixes) else { return nil }
            let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate),
                HKQuery.predicateForObjects(from: sources)
            ])
            let descriptor = HKSampleQueryDescriptor(predicates: [.workout(predicate)],
                                                     sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)],
                                                     limit: limit)
            return try await descriptor.result(for: store).map(Self.raw)
        } catch {
            throw LiveAppleHealthSourceStore.map(error)
        }
    }

    public func heartRate(from start: Date, to end: Date, limit: Int,
                          excludingBundlePrefixes: [String]) async throws -> [AppleHealthRawHeartRate] {
        guard HKHealthStore.isHealthDataAvailable(), start < end else { return [] }
        let type = HKQuantityType(.heartRate)
        do {
            let all = try await HKSourceQueryDescriptor(predicate: .quantitySample(type: type)).result(for: store)
            guard let sources = Self.included(all, excluding: excludingBundlePrefixes) else { return [] }
            let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                HKQuery.predicateForSamples(withStart: start, end: end, options: []),
                HKQuery.predicateForObjects(from: sources)
            ])
            let descriptor = HKSampleQueryDescriptor(predicates: [.quantitySample(type: type, predicate: predicate)],
                                                     sortDescriptors: [SortDescriptor(\.startDate)], limit: limit)
            let unit = HKUnit.count().unitDivided(by: .minute())
            return try await descriptor.result(for: store).map {
                AppleHealthRawHeartRate(time: $0.startDate, bpm: $0.quantity.doubleValue(for: unit),
                                        sourceBundleIdentifier: $0.sourceRevision.source.bundleIdentifier)
            }
        } catch {
            throw LiveAppleHealthSourceStore.map(error)
        }
    }

    // MARK: Mapping

    static func raw(_ workout: HKWorkout) -> AppleHealthRawWorkout {
        let bpm = HKUnit.count().unitDivided(by: .minute())
        let heart = workout.statistics(for: HKQuantityType(.heartRate))
        let energy = workout.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie())
        let distances: [HKQuantityTypeIdentifier] = [.distanceWalkingRunning, .distanceCycling, .distanceSwimming, .distanceRowing]
        let distance = distances.lazy.compactMap {
            workout.statistics(for: HKQuantityType($0))?.sumQuantity()?.doubleValue(for: .meter())
        }.first
        let metadata = workout.metadata ?? [:]
        return AppleHealthRawWorkout(
            id: workout.uuid, activity: activity(for: workout.workoutActivityType),
            activityName: name(for: workout.workoutActivityType),
            start: workout.startDate, end: workout.endDate, distanceMeters: distance, energyKcal: energy,
            averageHeartRate: heart?.averageQuantity()?.doubleValue(for: bpm),
            maximumHeartRate: heart?.maximumQuantity()?.doubleValue(for: bpm),
            provenance: LiveAppleHealthSourceStore.provenance(of: workout),
            syncIdentifier: metadata[HKMetadataKeySyncIdentifier] as? String,
            metadataKeys: Set(metadata.keys))
    }

    /// Loopr's activity for an Apple Health one. Anything without a clear home
    /// stays `other`, as WorkoutKit's catalogue asks.
    public static func activity(for type: HKWorkoutActivityType) -> AppleHealthWorkoutActivity {
        switch type {
        case .running, .trackAndField: .run
        case .cycling, .handCycling: .cycle
        case .walking, .wheelchairWalkPace: .walk
        case .hiking: .hike
        case .traditionalStrengthTraining, .functionalStrengthTraining, .coreTraining: .strength
        // Apple Health's cross training is where CrossFit boxes and SugarWOD save a WOD.
        case .crossTraining: .crossfit
        case .swimming, .waterFitness: .swim
        case .mixedCardio, .elliptical, .stairClimbing, .stairs, .stepTraining, .jumpRope, .fitnessGaming: .cardio
        case .highIntensityIntervalTraining: .hiit
        case .yoga, .mindAndBody, .taiChi: .yoga
        case .pilates, .barre: .pilates
        case .flexibility, .cooldown, .preparationAndRecovery: .mobility
        case .rowing: .rowing
        case .climbing: .climbing
        case .cardioDance, .socialDance: .dance
        case .americanFootball, .australianFootball, .baseball, .basketball, .cricket, .handball, .hockey,
             .lacrosse, .rugby, .soccer, .softball, .volleyball, .discSports, .badminton, .racquetball, .squash,
             .tableTennis, .tennis, .pickleball, .golf, .boxing, .kickboxing, .martialArts, .wrestling, .fencing:
            .sport
        default: .other
        }
    }

    /// Apple Health's own name for the activity, in sentence case. The dose
    /// reads it, so "Functional strength training" and "Tai chi" count where
    /// they belong.
    public static func name(for type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: "Running"
        case .trackAndField: "Track and field"
        case .cycling: "Cycling"
        case .handCycling: "Hand cycling"
        case .walking: "Walking"
        case .wheelchairWalkPace: "Wheelchair"
        case .hiking: "Hiking"
        case .traditionalStrengthTraining: "Traditional strength training"
        case .functionalStrengthTraining: "Functional strength training"
        case .coreTraining: "Core training"
        case .crossTraining: "Cross training"
        case .swimming: "Swimming"
        case .waterFitness: "Water fitness"
        case .mixedCardio: "Mixed cardio"
        case .elliptical: "Elliptical"
        case .stairClimbing, .stairs: "Stairs"
        case .stepTraining: "Step training"
        case .jumpRope: "Jump rope"
        case .fitnessGaming: "Fitness gaming"
        case .highIntensityIntervalTraining: "HIIT"
        case .yoga: "Yoga"
        case .mindAndBody: "Mind and body"
        case .taiChi: "Tai chi"
        case .pilates: "Pilates"
        case .barre: "Barre"
        case .flexibility: "Flexibility"
        case .cooldown: "Cooldown"
        case .preparationAndRecovery: "Preparation and recovery"
        case .rowing: "Rowing"
        case .climbing: "Climbing"
        case .cardioDance: "Cardio dance"
        case .socialDance: "Social dance"
        case .americanFootball: "American football"
        case .australianFootball: "Australian football"
        case .baseball: "Baseball"
        case .basketball: "Basketball"
        case .cricket: "Cricket"
        case .handball: "Handball"
        case .hockey: "Hockey"
        case .lacrosse: "Lacrosse"
        case .rugby: "Rugby"
        case .soccer: "Soccer"
        case .softball: "Softball"
        case .volleyball: "Volleyball"
        case .discSports: "Disc sports"
        case .badminton: "Badminton"
        case .racquetball: "Racquetball"
        case .squash: "Squash"
        case .tableTennis: "Table tennis"
        case .tennis: "Tennis"
        case .pickleball: "Pickleball"
        case .golf: "Golf"
        case .boxing: "Boxing"
        case .kickboxing: "Kickboxing"
        case .martialArts: "Martial arts"
        case .wrestling: "Wrestling"
        case .fencing: "Fencing"
        default: "Other"
        }
    }

    /// The sources minus Loopr's own. Nil when nothing else is left.
    private static func included(_ all: some Sequence<HKSource>, excluding prefixes: [String]) -> Set<HKSource>? {
        let own = HKSource.default().bundleIdentifier
        let included = all.filter { source in
            source.bundleIdentifier != own && !HealthHistorySourceFilter.isExcluded(source.bundleIdentifier, prefixes: prefixes)
        }
        return included.isEmpty ? nil : Set(included)
    }
}
#endif
