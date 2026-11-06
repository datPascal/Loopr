import Foundation

#if canImport(HealthKit)
import HealthKit

/// Reads the eight Apple Health source kinds (DEC-12.16). It never writes.
/// `LiveHealthHistoryClient` asks for read access in the same sheet as the
/// history import, using `readTypes(for:)`.
public final class LiveAppleHealthSourceStore: AppleHealthSourceStore, @unchecked Sendable {
    private let store: HKHealthStore

    public init(store: HKHealthStore = HKHealthStore()) { self.store = store }

    /// The types to ask read access for. Keep in step with
    /// `NSHealthShareUsageDescription`.
    public static func readTypes(for kinds: Set<AppleHealthSourceKind>) -> Set<HKObjectType> {
        Set(kinds.flatMap { quantityTypes(for: $0) }.map { $0 as HKObjectType })
    }

    /// Empty when this OS lacks any of the kind's types.
    static func quantityTypes(for kind: AppleHealthSourceKind) -> [HKQuantityType] {
        let types = kind.healthKitIdentifiers.compactMap {
            HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: $0))
        }
        return types.count == kind.healthKitIdentifiers.count ? types : []
    }

    /// The HealthKit unit for `kind.storeUnit`.
    static func unit(for kind: AppleHealthSourceKind) -> HKUnit {
        switch kind {
        case .vo2Max: HKUnit(from: "ml/kg*min")
        case .daylight: .minute()
        case .bloodPressure: .millimeterOfMercury()
        case .weight, .leanMass: .gramUnit(with: .kilo)
        case .bodyFat: .percent()
        case .bloodGlucose: HKUnit.gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci))
        case .steps: .count()
        }
    }

    public func access(for kind: AppleHealthSourceKind) async -> AppleHealthStoreAccess {
        guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }
        let types = Self.quantityTypes(for: kind)
        guard !types.isEmpty else { return .unavailable }
        return await withCheckedContinuation { continuation in
            store.getRequestStatusForAuthorization(toShare: [], read: Set(types.map { $0 as HKObjectType })) { status, error in
                // An error says nothing about the choice. Let the query run and
                // report its own failure.
                continuation.resume(returning: error == nil && status == .shouldRequest ? .notRequested : .requested)
            }
        }
    }

    public func samples(of kind: AppleHealthSourceKind, from start: Date, to end: Date, limit: Int,
                        excludingBundlePrefixes: [String]) async throws -> [AppleHealthRawSample] {
        guard HKHealthStore.isHealthDataAvailable(), kind != .bloodPressure,
              let type = Self.quantityTypes(for: kind).first else { throw AppleHealthStoreError.unavailable }
        do {
            guard let sources = try await includedSources(type: type, excluding: excludingBundlePrefixes) else { return [] }
            let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                HKQuery.predicateForSamples(withStart: start, end: end, options: []),
                HKQuery.predicateForObjects(from: sources)
            ])
            let descriptor = HKSampleQueryDescriptor(
                predicates: [.quantitySample(type: type, predicate: predicate)],
                sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)], limit: limit)
            let unit = Self.unit(for: kind)
            return try await descriptor.result(for: store).map { sample in
                AppleHealthRawSample(value: sample.quantity.doubleValue(for: unit), start: sample.startDate,
                                     end: sample.endDate, provenance: Self.provenance(of: sample))
            }
        } catch {
            throw Self.map(error)
        }
    }

    public func bloodPressure(from start: Date, to end: Date, limit: Int,
                              excludingBundlePrefixes: [String]) async throws -> [AppleHealthRawBloodPressure] {
        guard HKHealthStore.isHealthDataAvailable(),
              let correlationType = HKObjectType.correlationType(forIdentifier: .bloodPressure) else {
            throw AppleHealthStoreError.unavailable
        }
        let excluded = excludingBundlePrefixes
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[AppleHealthRawBloodPressure], any Error>) in
            let query = HKSampleQuery(
                sampleType: correlationType,
                predicate: HKQuery.predicateForSamples(withStart: start, end: end, options: []),
                limit: limit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
            ) { _, results, error in
                if let error {
                    continuation.resume(throwing: Self.map(error))
                } else {
                    // Mapped here, so only plain values leave the query handler.
                    continuation.resume(returning: Self.bloodPressure(from: results ?? [], excluding: excluded))
                }
            }
            store.execute(query)
        }
    }

    private static func bloodPressure(from results: [HKSample], excluding prefixes: [String]) -> [AppleHealthRawBloodPressure] {
        guard let systolicType = HKObjectType.quantityType(forIdentifier: .bloodPressureSystolic),
              let diastolicType = HKObjectType.quantityType(forIdentifier: .bloodPressureDiastolic) else { return [] }
        let unit = unit(for: .bloodPressure)
        let ownBundle = HKSource.default().bundleIdentifier
        func raw(_ sample: HKSample) -> AppleHealthRawSample? {
            guard let quantity = sample as? HKQuantitySample else { return nil }
            return AppleHealthRawSample(value: quantity.quantity.doubleValue(for: unit), start: quantity.startDate,
                                        end: quantity.endDate, provenance: provenance(of: quantity))
        }
        return results.compactMap { sample -> AppleHealthRawBloodPressure? in
            guard let correlation = sample as? HKCorrelation else { return nil }
            let bundle = correlation.sourceRevision.source.bundleIdentifier
            guard bundle != ownBundle, !HealthHistorySourceFilter.isExcluded(bundle, prefixes: prefixes) else { return nil }
            return AppleHealthRawBloodPressure(
                systolic: correlation.objects(for: systolicType).compactMap(raw),
                diastolic: correlation.objects(for: diastolicType).compactMap(raw),
                start: correlation.startDate, end: correlation.endDate, provenance: provenance(of: correlation))
        }
    }

    public func dailyBuckets(of kind: AppleHealthSourceKind, from start: Date, to end: Date, calendar: Calendar,
                             excludingBundlePrefixes: [String]) async throws -> [AppleHealthRawDailyBucket] {
        guard HKHealthStore.isHealthDataAvailable(), kind.isDailyAggregate,
              let type = Self.quantityTypes(for: kind).first else { throw AppleHealthStoreError.unavailable }
        guard start < end else { return [] }
        do {
            guard let sources = try await includedSources(type: type, excluding: excludingBundlePrefixes) else { return [] }
            let unit = Self.unit(for: kind)
            let anchor = calendar.startOfDay(for: start)
            let options: HKStatisticsOptions = [.cumulativeSum, .separateBySource]
            func predicate(from lower: Date, to upper: Date) -> NSPredicate {
                NSCompoundPredicate(andPredicateWithSubpredicates: [
                    HKQuery.predicateForSamples(withStart: lower, end: upper, options: []),
                    HKQuery.predicateForObjects(from: sources)
                ])
            }
            // The collection query cuts days in the device's time zone. When the
            // calendar uses another one, ask for each of its days on its own, so
            // the days are the calendar's.
            if calendar.timeZone.identifier == TimeZone.current.identifier {
                let descriptor = HKStatisticsCollectionQueryDescriptor(
                    predicate: .quantitySample(type: type, predicate: predicate(from: anchor, to: end)),
                    options: options, anchorDate: anchor, intervalComponents: DateComponents(day: 1))
                let collection = try await descriptor.result(for: store)
                var buckets: [AppleHealthRawDailyBucket] = []
                collection.enumerateStatistics(from: anchor, to: end) { statistics, _ in
                    if let bucket = Self.bucket(statistics, dayStart: statistics.startDate, unit: unit) { buckets.append(bucket) }
                }
                return buckets
            }
            var buckets: [AppleHealthRawDailyBucket] = []
            for day in AppleHealthDailyAggregation.dayIntervals(from: start, to: end, calendar: calendar) {
                let descriptor = HKStatisticsQueryDescriptor(
                    predicate: .quantitySample(type: type, predicate: predicate(from: day.start, to: day.end)),
                    options: options)
                if let statistics = try await descriptor.result(for: store),
                   let bucket = Self.bucket(statistics, dayStart: day.start, unit: unit) { buckets.append(bucket) }
            }
            return buckets
        } catch {
            throw Self.map(error)
        }
    }

    // MARK: Helpers

    private static func bucket(_ statistics: HKStatistics, dayStart: Date, unit: HKUnit) -> AppleHealthRawDailyBucket? {
        guard let sum = statistics.sumQuantity()?.doubleValue(for: unit) else { return nil }
        let contributions = (statistics.sources ?? []).compactMap { source -> AppleHealthRawContribution? in
            guard let part = statistics.sumQuantity(for: source)?.doubleValue(for: unit) else { return nil }
            return AppleHealthRawContribution(
                provenance: AppleHealthProvenance(sourceName: source.name, sourceBundleIdentifier: source.bundleIdentifier),
                sum: part)
        }
        return AppleHealthRawDailyBucket(dayStart: dayStart, sum: sum, contributions: contributions)
    }

    static func provenance(of sample: HKSample) -> AppleHealthProvenance {
        let source = sample.sourceRevision.source
        let entered = (sample.metadata?[HKMetadataKeyWasUserEntered] as? NSNumber)?.boolValue ?? false
        return AppleHealthProvenance(
            sourceName: source.name, sourceBundleIdentifier: source.bundleIdentifier,
            deviceName: sample.device?.name, deviceModel: sample.device?.model, wasUserEntered: entered)
    }

    /// The sources that wrote this type, minus Loopr's own. Nil when nothing
    /// else wrote it, so no query is made at all.
    private func includedSources(type: HKQuantityType, excluding prefixes: [String]) async throws -> Set<HKSource>? {
        let all = try await HKSourceQueryDescriptor(predicate: .quantitySample(type: type)).result(for: store)
        let own = HKSource.default().bundleIdentifier
        let included = all.filter { source in
            source.bundleIdentifier != own
                && !HealthHistorySourceFilter.isExcluded(source.bundleIdentifier, prefixes: prefixes)
        }
        return included.isEmpty ? nil : Set(included)
    }

    static func map(_ error: any Error) -> AppleHealthStoreError {
        if let known = error as? AppleHealthStoreError { return known }
        let nsError = error as NSError
        if nsError.domain == HKError.errorDomain {
            switch nsError.code {
            case HKError.Code.errorAuthorizationDenied.rawValue,
                 HKError.Code.errorAuthorizationNotDetermined.rawValue:
                return .authorizationDenied
            case HKError.Code.errorHealthDataUnavailable.rawValue:
                return .unavailable
            default: break
            }
        }
        return .failed(nsError.localizedDescription)
    }
}
#endif
