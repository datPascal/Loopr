import Foundation

/// Asks for Apple Health access in a single sheet: write access for export
/// and read access for the history import.
public protocol HealthHistoryAuthorizing: Sendable {
    func requestAuthorization(sharing share: Set<ExportMetricKind>, reading: Set<HealthHistoryQuantity>,
                              readSleep: Bool) async throws
}

#if canImport(HealthKit)
import HealthKit

/// Reads daily Apple Health history for the metric charts.
public final class LiveHealthHistoryClient: HealthHistoryQueryClient, HealthHistoryAuthorizing, @unchecked Sendable {
    private let store: HKHealthStore

    public init(store: HKHealthStore = HKHealthStore()) { self.store = store }

    /// Every type the history import reads. Keep in step with
    /// `NSHealthShareUsageDescription`.
    public static var readTypes: Set<HKObjectType> {
        readTypes(for: Set(HealthHistoryQuantity.allCases), readSleep: true)
    }

    public static func readTypes(for quantities: Set<HealthHistoryQuantity>, readSleep: Bool) -> Set<HKObjectType> {
        var types = Set<HKObjectType>(quantities.intersection(Set(HealthHistoryQuantity.allCases)).compactMap { quantityType($0) })
        if readSleep, let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { types.insert(sleep) }
        return types
    }

    public func requestAuthorization(sharing share: Set<ExportMetricKind>, reading: Set<HealthHistoryQuantity>,
                                     readSleep: Bool) async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw LiveHealthKitError.unavailable }
        let shareTypes = Set(share.compactMap(Self.shareType(for:)))
        let readTypes = Self.readTypes(for: reading, readSleep: readSleep)
        guard !shareTypes.isEmpty || !readTypes.isEmpty else { return }
        try await store.requestAuthorization(toShare: shareTypes, read: readTypes)
    }

    public func historyReadAccessRequested() async -> Bool {
        await historyReadAccessRequested(reading: Set(HealthHistoryQuantity.allCases), readSleep: true)
    }

    public func historyReadAccessRequested(reading: Set<HealthHistoryQuantity>, readSleep: Bool) async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        return await withCheckedContinuation { continuation in
            store.getRequestStatusForAuthorization(toShare: [], read: Self.readTypes(for: reading, readSleep: readSleep)) { status, error in
                continuation.resume(returning: error == nil && status == .unnecessary)
            }
        }
    }

    public func dailyStatistics(for quantity: HealthHistoryQuantity, from start: Date, to end: Date,
                                calendar: Calendar, excludingBundlePrefixes: [String]) async throws -> [HealthDailyStatistic] {
        guard HKHealthStore.isHealthDataAvailable(), start < end,
              let type = Self.quantityType(quantity) else { return [] }
        guard let sources = try await includedSources(for: .quantitySample(type: type),
                                                      excluding: excludingBundlePrefixes) else { return [] }
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForSamples(withStart: start, end: end, options: []),
            HKQuery.predicateForObjects(from: sources)
        ])
        let options: HKStatisticsOptions = quantity.isCumulative
            ? .cumulativeSum
            : [.discreteAverage, .discreteMin, .discreteMax]
        let anchor = calendar.startOfDay(for: start)
        let descriptor = HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(type: type, predicate: predicate),
            options: options, anchorDate: anchor, intervalComponents: DateComponents(day: 1))
        let collection = try await descriptor.result(for: store)
        let unit = Self.unit(for: quantity)
        var result: [HealthDailyStatistic] = []
        collection.enumerateStatistics(from: anchor, to: end) { statistics, _ in
            let value = HealthDailyStatistic(
                dayStart: statistics.startDate,
                average: statistics.averageQuantity()?.doubleValue(for: unit),
                minimum: statistics.minimumQuantity()?.doubleValue(for: unit),
                maximum: statistics.maximumQuantity()?.doubleValue(for: unit),
                sum: statistics.sumQuantity()?.doubleValue(for: unit))
            if value.average != nil || value.maximum != nil || value.sum != nil { result.append(value) }
        }
        return result
    }

    public func sleepSamples(from start: Date, to end: Date,
                             excludingBundlePrefixes: [String]) async throws -> [HealthSleepSample] {
        guard HKHealthStore.isHealthDataAvailable(), start < end,
              let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return [] }
        guard let sources = try await includedSources(for: .categorySample(type: type),
                                                      excluding: excludingBundlePrefixes) else { return [] }
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForSamples(withStart: start, end: end, options: []),
            HKQuery.predicateForObjects(from: sources)
        ])
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: type, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate)])
        return try await descriptor.result(for: store).compactMap { sample in
            guard let stage = HealthSleepStage(healthKitValue: sample.value) else { return nil }
            return HealthSleepSample(start: sample.startDate, end: sample.endDate, stage: stage,
                                     sourceBundleIdentifier: sample.sourceRevision.source.bundleIdentifier)
        }
    }

    /// The sources that wrote this type, minus Loopr's own. Nil when nothing
    /// else wrote it, so no query is made at all.
    private func includedSources<Sample: HKSample>(for predicate: HKSamplePredicate<Sample>,
                                                   excluding prefixes: [String]) async throws -> Set<HKSource>? {
        let all = try await HKSourceQueryDescriptor(predicate: predicate).result(for: store)
        let own = HKSource.default().bundleIdentifier
        let included = all.filter { source in
            source.bundleIdentifier != own
                && !HealthHistorySourceFilter.isExcluded(source.bundleIdentifier, prefixes: prefixes)
        }
        return included.isEmpty ? nil : Set(included)
    }

    static func quantityType(_ quantity: HealthHistoryQuantity) -> HKQuantityType? {
        guard HealthHistoryQuantity.allCases.contains(quantity) else { return nil }
        return HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: quantity.healthKitIdentifier))
    }

    static func unit(for quantity: HealthHistoryQuantity) -> HKUnit {
        switch quantity {
        case .restingHeartRate, .respiratoryRate, .heartRate: HKUnit.count().unitDivided(by: .minute())
        case .heartRateVariabilitySDNN: .secondUnit(with: .milli)
        case .oxygenSaturation: .percent()
        case .vo2Max: HKUnit(from: "ml/kg*min")
        case .steps: .count()
        case .activeEnergy: .kilocalorie()
        }
    }

    static func shareType(for metric: ExportMetricKind) -> HKSampleType? {
        switch metric {
        case .sleepStages: HKObjectType.categoryType(forIdentifier: .sleepAnalysis)
        case .completedWorkout: HKObjectType.workoutType()
        case .heartRate, .restingHeartRate, .heartRateVariabilitySDNN, .respiratoryRate, .steps, .activeEnergy:
            HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(
                rawValue: HealthObjectIdentifier.identifier(for: metric)))
        }
    }
}
#endif

#if canImport(HealthKit)
/// The export client asks for history read access in the same sheet.
/// HealthKit authorization is app-wide, so the history client's store answers
/// for both.
extension LiveHealthKitClient: HealthHistoryAuthorizing {
    public func requestAuthorization(sharing share: Set<ExportMetricKind>, reading: Set<HealthHistoryQuantity>,
                                     readSleep: Bool) async throws {
        try await LiveHealthHistoryClient().requestAuthorization(sharing: share, reading: reading, readSleep: readSleep)
    }
}
#endif
