import Foundation
@testable import HealthKitBridge
import XCTest
#if canImport(HealthKit)
import HealthKit
#endif

// LV-11.2: the source summary for Data's Sources section, and the proof that
// Apple Health stays read-only for the new types.

private let watch = AppleHealthProvenance(sourceName: "Pascal's Apple Watch", sourceBundleIdentifier: "com.apple.health.7A2C",
                                          deviceName: "Apple Watch", deviceModel: "Watch7,1", wasUserEntered: false)
private let withings = AppleHealthProvenance(sourceName: "Withings", sourceBundleIdentifier: "com.withings.wiScaleNG",
                                             deviceName: "Body+", wasUserEntered: false)
private let byHand = AppleHealthProvenance(sourceName: "Health", sourceBundleIdentifier: "com.apple.Health", wasUserEntered: true)
private let nameless = AppleHealthProvenance.unknown

private func day(_ offset: Int) -> Date { Date(timeIntervalSince1970: 1_790_000_000 + Double(offset) * 86_400) }

private func sample(_ kind: AppleHealthSourceKind, _ value: Double, day offset: Int, _ provenance: AppleHealthProvenance,
                    others: [String] = []) -> AppleHealthSample {
    AppleHealthSample(kind: kind, value: value, original: AppleHealthOriginalReading(value: value, unit: kind.storeUnit),
                      start: day(offset), end: day(offset).addingTimeInterval(60), provenance: provenance,
                      additionalSourceNames: others)
}

final class AppleHealthSourceSummaryTests: XCTestCase {
    func testEveryKindHasARowInOrderAndAMissingResultReadsAsNoSamples() {
        let summary = AppleHealthSourceSummaryBuilder.build(results: [:])
        XCTAssertEqual(summary.kinds.map(\.kind), AppleHealthSourceKind.allCases)
        XCTAssertTrue(summary.kinds.allSatisfy { $0.latest == nil && $0.absence == .noSamples && $0.isEnabled })
        XCTAssertTrue(summary.sources.isEmpty)
        XCTAssertTrue(summary.suppliedKinds.isEmpty)
    }

    func testARowCarriesTheLatestValueDateAndSourceLabel() throws {
        let weights = [sample(.weight, 81.9, day: 1, withings), sample(.weight, 81.2, day: 5, withings), sample(.weight, 81.6, day: 3, withings)]
        let summary = AppleHealthSourceSummaryBuilder.build(results: [.weight: .values(weights)])
        let row = try XCTUnwrap(summary.summary(for: .weight))
        XCTAssertEqual(row.latest?.value, 81.2)
        XCTAssertEqual(row.date, day(5).addingTimeInterval(60))
        XCTAssertEqual(row.sourceLabel, "Withings")
        XCTAssertNil(row.absence)
        XCTAssertTrue(row.isEnabled)
        XCTAssertEqual(summary.suppliedKinds, [.weight])
    }

    func testBloodPressureRowKeepsBothNumbers() throws {
        let reading = AppleHealthSample(kind: .bloodPressure, value: 118, diastolic: 76,
            original: AppleHealthOriginalReading(value: 118, unit: .mmHg), start: day(2), end: day(2), provenance: withings)
        let row = try XCTUnwrap(AppleHealthSourceSummaryBuilder.build(results: [.bloodPressure: .values([reading])]).summary(for: .bloodPressure))
        XCTAssertEqual(row.latest?.value, 118)
        XCTAssertEqual(row.latest?.diastolic, 76)
    }

    func testSwitchedOffIsDisabledAndEveryOtherAbsenceStaysEnabledWithItsReason() {
        let results: [AppleHealthSourceKind: AppleHealthReadResult] = [
            .weight: .absent(.switchedOff), .bodyFat: .absent(.notAuthorized), .leanMass: .absent(.unavailable),
            .bloodGlucose: .absent(.queryFailed("locked")), .vo2Max: .absent(.noSamples)
        ]
        let summary = AppleHealthSourceSummaryBuilder.build(results: results)
        XCTAssertEqual(summary.summary(for: .weight)?.isEnabled, false)
        XCTAssertEqual(summary.summary(for: .weight)?.absence, .switchedOff)
        XCTAssertEqual(summary.summary(for: .bodyFat)?.absence, .notAuthorized)
        XCTAssertEqual(summary.summary(for: .leanMass)?.absence, .unavailable)
        XCTAssertEqual(summary.summary(for: .bloodGlucose)?.absence, .queryFailed("locked"))
        XCTAssertEqual(summary.summary(for: .vo2Max)?.absence, .noSamples)
        for kind in [AppleHealthSourceKind.bodyFat, .leanMass, .bloodGlucose, .vo2Max] {
            XCTAssertEqual(summary.summary(for: kind)?.isEnabled, true, "\(kind)")
            XCTAssertNil(summary.summary(for: kind)?.latest)
            XCTAssertNil(summary.summary(for: kind)?.date)
            XCTAssertNil(summary.summary(for: kind)?.sourceLabel)
        }
        XCTAssertTrue(summary.sources.isEmpty)
    }

    func testOneLinePerDistinctSourceListsTheKindsItSupplied() {
        let results: [AppleHealthSourceKind: AppleHealthReadResult] = [
            .vo2Max: .values([sample(.vo2Max, 44, day: 2, watch)]),
            .daylight: .values([sample(.daylight, 38, day: 4, watch)]),
            .steps: .values([sample(.steps, 9_000, day: 6, watch, others: ["iPhone"])]),
            .weight: .values([sample(.weight, 82, day: 1, withings), sample(.weight, 81, day: 9, byHand)]),
            .bodyFat: .values([sample(.bodyFat, 21, day: 3, withings)])
        ]
        let summary = AppleHealthSourceSummaryBuilder.build(results: results)
        XCTAssertEqual(summary.sources.map(\.label), ["Apple Watch", "Withings", "Health", "iPhone"])
        XCTAssertEqual(summary.sources.map(\.kinds), [[.vo2Max, .daylight, .steps], [.weight, .bodyFat], [.weight], [.steps]])
        XCTAssertEqual(summary.sources[0].lastSeen, day(6).addingTimeInterval(60))
        XCTAssertEqual(summary.sources[1].lastSeen, day(3).addingTimeInterval(60))
        XCTAssertEqual(summary.summary(for: .weight)?.sourceLabel, "Health", "the row shows the newest source")
        XCTAssertEqual(summary.suppliedKinds, [.vo2Max, .daylight, .weight, .bodyFat, .steps])
    }

    func testASourceWithNoNameGetsNoLine() {
        let summary = AppleHealthSourceSummaryBuilder.build(results: [.weight: .values([sample(.weight, 80, day: 1, nameless)])])
        XCTAssertEqual(summary.summary(for: .weight)?.latest?.value, 80)
        XCTAssertNil(summary.summary(for: .weight)?.sourceLabel)
        XCTAssertTrue(summary.sources.isEmpty)
    }

    func testEqualKindCountsSortByLabelSoTheOrderIsStable() {
        let results: [AppleHealthSourceKind: AppleHealthReadResult] = [
            .weight: .values([sample(.weight, 80, day: 1, withings)]),
            .vo2Max: .values([sample(.vo2Max, 40, day: 1, watch)])
        ]
        XCTAssertEqual(AppleHealthSourceSummaryBuilder.build(results: results).sources.map(\.label), ["Apple Watch", "Withings"])
    }

    func testEmptyValuesReadAsNoSamplesNotAsAValue() {
        let summary = AppleHealthSourceSummaryBuilder.build(results: [.steps: .values([])])
        XCTAssertNil(summary.summary(for: .steps)?.latest)
        XCTAssertEqual(summary.summary(for: .steps)?.absence, .noSamples)
    }
}

final class AppleHealthWriteRulesTests: XCTestCase {
    /// Build 21's write and share set, pinned by HealthKit identifier.
    private static let build21Writes: Set<String> = [
        "HKQuantityTypeIdentifierHeartRate", "HKQuantityTypeIdentifierRestingHeartRate",
        "HKQuantityTypeIdentifierHeartRateVariabilitySDNN", "HKQuantityTypeIdentifierRespiratoryRate",
        "HKCategoryTypeIdentifierSleepAnalysis", "HKQuantityTypeIdentifierStepCount",
        "HKQuantityTypeIdentifierActiveEnergyBurned", "HKWorkoutTypeIdentifier"
    ]

    func testTheExportSetEqualsBuild21Exactly() {
        XCTAssertEqual(ExportMetricKind.allCases.count, 8)
        XCTAssertEqual(Set(ExportMetricKind.allCases.map(HealthObjectIdentifier.identifier(for:))), Self.build21Writes)
    }

    func testOnlyTheMetricExportFeatureSharesAndItSharesExactlyTheExportSet() {
        XCTAssertEqual(HealthAuthorizationScope.contextual(for: .metricExport).share, Set(ExportMetricKind.allCases))
        XCTAssertTrue(HealthAuthorizationScope.contextual(for: .metricExport).read.isEmpty)
        XCTAssertTrue(HealthAuthorizationScope.contextual(for: .bodyCompositionImport).share.isEmpty)
        XCTAssertTrue(HealthAuthorizationScope.contextual(for: .ageInsightsImport).share.isEmpty)
    }

    func testNoNewReadKindHasAnExportPathExceptTheEstimatedStepsThatAlreadyExisted() {
        let exportNames = Set(ExportMetricKind.allCases.map(\.rawValue))
        for kind in AppleHealthSourceKind.allCases where kind != .steps {
            XCTAssertFalse(exportNames.contains(kind.rawValue), "\(kind) must not be exportable")
            XCTAssertThrowsError(try HealthExportFirewall.metric(named: kind.rawValue), "\(kind)")
        }
        let readIdentifiers = Set(AppleHealthSourceKind.allCases.flatMap(\.healthKitIdentifiers))
        XCTAssertEqual(readIdentifiers.intersection(Self.build21Writes), ["HKQuantityTypeIdentifierStepCount"])
        let dataTypes = Set(HealthDataType.allCases.map(HealthObjectIdentifier.identifier(for:)))
        XCTAssertTrue(dataTypes.isDisjoint(with: Self.build21Writes), "the body and fitness reads are never written")
    }

    func testBloodAgeCardioAgeRecoveryStrainAndEveryLooprScoreHaveNoExportPath() {
        let scores = ["bloodAge", "phenoAge", "cardioAge", "looprAge", "looprScore", "recovery", "readiness", "strain", "stress",
                      "sleepScore", "sleepPerformance", "rmssd", "relativeTemperature", "uncalibratedOpticalOxygen"]
        for name in scores {
            XCTAssertNil(ExportMetricKind(rawValue: name), name)
            XCTAssertThrowsError(try HealthExportFirewall.metric(named: name), name) { error in
                XCTAssertEqual(error as? ExportFirewallError, .forbiddenMetric(name))
            }
        }
        for name in ["bloodAge", "phenoAge", "cardioAge", "looprAge", "looprScore", "recovery", "readiness", "strain", "stress"] {
            XCTAssertTrue(HealthExportFirewall.forbidden.contains(name), name)
        }
        // The scheduler and the sync engine take an ExportMetricKind, so a score
        // cannot be handed to them at all.
        XCTAssertTrue(ExportMetricKind.allCases.allSatisfy { Self.build21Writes.contains(HealthObjectIdentifier.identifier(for: $0)) })
    }

    #if canImport(HealthKit)
    func testTheHealthKitShareTypesAreBuild21sAndNoReadTypeJoinsThem() {
        let shared = Set(ExportMetricKind.allCases.compactMap { LiveHealthHistoryClient.shareType(for: $0)?.identifier })
        XCTAssertEqual(shared, Self.build21Writes)
        let sources = LiveAppleHealthSourceStore.readTypes(for: Set(AppleHealthSourceKind.allCases)).map(\.identifier)
        XCTAssertEqual(Set(sources).intersection(shared), ["HKQuantityTypeIdentifierStepCount"])
        for blocked in [HKQuantityTypeIdentifier.bodyMass, .bodyFatPercentage, .leanBodyMass, .bloodGlucose, .bloodPressureSystolic,
                        .bloodPressureDiastolic, .timeInDaylight, .vo2Max] {
            XCTAssertFalse(shared.contains(blocked.rawValue), blocked.rawValue)
        }
    }
    #endif
}
