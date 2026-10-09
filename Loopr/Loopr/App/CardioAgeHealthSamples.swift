import SwiftUI
import AnalyticsKit
import BodyKit
import HealthKitBridge
#if canImport(HealthKit)
import HealthKit
#endif

/// Body reads VO2 max methods directly because daily Health statistics drop
/// the metadata that distinguishes exercise tests from other predictions.
struct CardioAgeHealthSamplesModifier: ViewModifier {
    let enabled: Bool
    let runtime: LooprHealthSyncRuntime?
    @Environment(\.scenePhase) private var scenePhase
    @State private var samples: [HealthKitVO2MaxSample] = []
    @State private var readGeneration = 0

    func body(content: Content) -> some View {
        content
            .environment(\.bodyAppleHealthVO2Max, samples)
            .task(id: scenePhase) {
                guard enabled, scenePhase == .active else { return }
                await refresh()
            }
            .onReceive(NotificationCenter.default.publisher(for: looprHealthReadPreferencesChanged)) { _ in
                Task { await refresh() }
            }
    }

    private func refresh() async {
        readGeneration += 1
        let generation = readGeneration
        guard enabled, let runtime, await runtime.allowsRead(.vo2Max) else {
            samples = []
            return
        }
        let result = await LiveCardioAgeHealthReader.samples(now: Date())
        if generation == readGeneration { samples = result }
    }
}

enum LiveCardioAgeHealthReader {
    static func samples(now: Date) async -> [HealthKitVO2MaxSample] {
        #if canImport(HealthKit)
        guard HKHealthStore.isHealthDataAvailable(),
              let type = HKObjectType.quantityType(forIdentifier: .vo2Max) else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: now.addingTimeInterval(-42 * 86_400), end: now)
        let store = HKHealthStore()
        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate,
                                      limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, results, _ in
                let mapped = (results ?? []).compactMap { item -> HealthKitVO2MaxSample? in
                    guard let sample = item as? HKQuantitySample else { return nil }
                    let rawType = (sample.metadata?[HKMetadataKeyVO2MaxTestType] as? NSNumber)?.intValue
                    let testType: HealthKitVO2MaxTestType? = switch rawType {
                    case HKVO2MaxTestType.maxExercise.rawValue: .maxExercise
                    case HKVO2MaxTestType.predictionSubMaxExercise.rawValue: .predictionSubMaxExercise
                    case HKVO2MaxTestType.predictionNonExercise.rawValue: .predictionNonExercise
                    default: nil
                    }
                    return HealthKitVO2MaxSample(
                        vo2max: sample.quantity.doubleValue(for: HKUnit(from: "ml/kg*min")),
                        sampledAt: sample.endDate,
                        sourceIdentifier: sample.sourceRevision.source.bundleIdentifier,
                        testType: testType)
                }
                continuation.resume(returning: mapped)
            }
            store.execute(query)
        }
        #else
        return []
        #endif
    }
}
