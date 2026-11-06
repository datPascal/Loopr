import Foundation
@testable import HealthKitBridge
import XCTest
#if canImport(HealthKit)
import HealthKit
#endif

// LV-11.1: the eight Apple Health kinds read with their source. Every test
// runs against a fake store. No test calls HealthKit.

private struct CumulativeEntry: Sendable {
    let start: Date
    let value: Double
    let provenance: AppleHealthProvenance
}

/// A fake Apple Health store. For daily kinds it holds cumulative samples and
/// cuts them into days with the calendar the reader passes, the way the live
/// store's contract says it must.
private actor FakeAppleHealthStore: AppleHealthSourceStore {
    private var accessByKind: [AppleHealthSourceKind: AppleHealthStoreAccess] = [:]
    private var samplesByKind: [AppleHealthSourceKind: [AppleHealthRawSample]] = [:]
    private var correlations: [AppleHealthRawBloodPressure] = []
    private var cumulative: [AppleHealthSourceKind: [CumulativeEntry]] = [:]
    private var failure: AppleHealthStoreError?
    private var rawFailure: (any Error)?
    private(set) var excludedPrefixesSeen: [[String]] = []
    private(set) var calendarsSeen: [String] = []
    private(set) var limitsSeen: [Int] = []
    private(set) var queryCount = 0

    func setAccess(_ access: AppleHealthStoreAccess, for kind: AppleHealthSourceKind) { accessByKind[kind] = access }
    func setSamples(_ samples: [AppleHealthRawSample], for kind: AppleHealthSourceKind) { samplesByKind[kind] = samples }
    func setCorrelations(_ value: [AppleHealthRawBloodPressure]) { correlations = value }
    func setCumulative(_ entries: [CumulativeEntry], for kind: AppleHealthSourceKind) { cumulative[kind] = entries }
    func setFailure(_ error: AppleHealthStoreError?) { failure = error }
    func setRawFailure(_ error: (any Error)?) { rawFailure = error }

    func access(for kind: AppleHealthSourceKind) async -> AppleHealthStoreAccess { accessByKind[kind] ?? .requested }

    private func check() throws {
        queryCount += 1
        if let failure { throw failure }
        if let rawFailure { throw rawFailure }
    }

    func samples(of kind: AppleHealthSourceKind, from start: Date, to end: Date, limit: Int,
                 excludingBundlePrefixes: [String]) async throws -> [AppleHealthRawSample] {
        try check()
        excludedPrefixesSeen.append(excludingBundlePrefixes)
        limitsSeen.append(limit)
        return (samplesByKind[kind] ?? [])
            .filter { $0.end > start && $0.start < end }
            .filter { !HealthHistorySourceFilter.isExcluded($0.provenance.sourceBundleIdentifier, prefixes: excludingBundlePrefixes) }
            .sorted { $0.end > $1.end }
            .prefix(limit).map { $0 }
    }

    func bloodPressure(from start: Date, to end: Date, limit: Int,
                       excludingBundlePrefixes: [String]) async throws -> [AppleHealthRawBloodPressure] {
        try check()
        excludedPrefixesSeen.append(excludingBundlePrefixes)
        return correlations.filter { $0.end > start && $0.start < end }
            .filter { !HealthHistorySourceFilter.isExcluded($0.provenance.sourceBundleIdentifier, prefixes: excludingBundlePrefixes) }
            .sorted { $0.end > $1.end }.prefix(limit).map { $0 }
    }

    func dailyBuckets(of kind: AppleHealthSourceKind, from start: Date, to end: Date, calendar: Calendar,
                      excludingBundlePrefixes: [String]) async throws -> [AppleHealthRawDailyBucket] {
        try check()
        excludedPrefixesSeen.append(excludingBundlePrefixes)
        calendarsSeen.append(calendar.timeZone.identifier)
        let anchor = calendar.startOfDay(for: start)
        let kept = (cumulative[kind] ?? []).filter {
            $0.start >= anchor && $0.start < end
                && !HealthHistorySourceFilter.isExcluded($0.provenance.sourceBundleIdentifier, prefixes: excludingBundlePrefixes)
        }
        let byDay = Dictionary(grouping: kept) { calendar.startOfDay(for: $0.start) }
        return byDay.keys.sorted().map { day in
            let entries = byDay[day] ?? []
            var perSource: [AppleHealthProvenance: Double] = [:]
            for entry in entries { perSource[entry.provenance, default: 0] += entry.value }
            return AppleHealthRawDailyBucket(
                dayStart: day, sum: entries.reduce(0) { $0 + $1.value },
                contributions: perSource.map { AppleHealthRawContribution(provenance: $0.key, sum: $0.value) })
        }
    }
}

private enum Zone {
    static func calendar(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, in calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }
}

private let watch = AppleHealthProvenance(sourceName: "Pascal's Apple Watch",
    sourceBundleIdentifier: "com.apple.health.7A2C", deviceName: "Apple Watch", deviceModel: "Watch7,1", wasUserEntered: false)
private let phone = AppleHealthProvenance(sourceName: "Pascal's iPhone",
    sourceBundleIdentifier: "com.apple.health.91B0", deviceName: "iPhone", deviceModel: "iPhone17,1", wasUserEntered: false)
private let withings = AppleHealthProvenance(sourceName: "Withings", sourceBundleIdentifier: "com.withings.wiScaleNG",
    deviceName: "Body+", deviceModel: "WBS05", wasUserEntered: false)
private let byHand = AppleHealthProvenance(sourceName: "Health", sourceBundleIdentifier: "com.apple.Health",
    deviceName: nil, deviceModel: nil, wasUserEntered: true)
private let looprOwn = AppleHealthProvenance(sourceName: "Loopr", sourceBundleIdentifier: "com.loopr.ios", wasUserEntered: false)

private let utc = Zone.calendar("UTC")
private let t0 = Zone.date(2026, 10, 20, 8, 0, in: utc)

private func reader(_ store: FakeAppleHealthStore, calendar: Calendar = utc, now: Date = Zone.date(2026, 10, 24, 12, 0, in: utc),
                    prefixes: [String] = [], limit: Int = AppleHealthSourceReader.defaultSampleLimit) -> AppleHealthSourceReader {
    AppleHealthSourceReader(store: store, calendar: calendar, clock: { now },
                            excludingBundlePrefixes: prefixes, sampleLimit: limit)
}

private let windowStart = Zone.date(2026, 9, 1, in: utc)
private let windowEnd = Zone.date(2026, 10, 24, 12, 0, in: utc)

private func raw(_ value: Double, at start: Date = t0, length: TimeInterval = 0, _ provenance: AppleHealthProvenance = watch) -> AppleHealthRawSample {
    AppleHealthRawSample(value: value, start: start, end: start.addingTimeInterval(length), provenance: provenance)
}

final class AppleHealthSourceKindTests: XCTestCase {
    func testEightKindsWithCanonicalUnitsAndTypes() {
        XCTAssertEqual(AppleHealthSourceKind.allCases.count, 8)
        let units = Dictionary(uniqueKeysWithValues: AppleHealthSourceKind.allCases.map { ($0, $0.canonicalUnit.rawValue) })
        XCTAssertEqual(units, [.vo2Max: "mL/kg/min", .daylight: "min/day", .bloodPressure: "mmHg", .weight: "kg",
                               .bodyFat: "%", .leanMass: "kg", .bloodGlucose: "mmol/L", .steps: "steps/day"])
        XCTAssertEqual(AppleHealthSourceKind.bloodPressure.healthKitIdentifiers.count, 2)
        XCTAssertEqual(AppleHealthSourceKind.allCases.flatMap(\.healthKitIdentifiers).count, 9)
        XCTAssertTrue(AppleHealthSourceKind.allCases.flatMap(\.healthKitIdentifiers).allSatisfy { $0.hasPrefix("HKQuantityTypeIdentifier") })
        XCTAssertEqual(Set(AppleHealthSourceKind.allCases.filter(\.isDailyAggregate)), [.daylight, .steps])
    }

    func testSixKindsAreNewAndTwoShareTheHistorySwitches() {
        XCTAssertEqual(Set(AppleHealthSourceKind.addedReads), [.daylight, .bloodPressure, .weight, .bodyFat, .leanMass, .bloodGlucose])
        XCTAssertEqual(AppleHealthSourceKind.vo2Max.historyQuantity, .vo2Max)
        XCTAssertEqual(AppleHealthSourceKind.steps.historyQuantity, .steps)
        XCTAssertTrue(AppleHealthSourceKind.addedReads.allSatisfy { $0.historyQuantity == nil })
    }

    func testPreferencesKeepSourceSwitchesAndOldSavesDecodeWithAllOn() throws {
        let saved = HealthSyncPreferences(disabledSources: [.weight, .bloodGlucose], timeZoneIdentifier: "UTC")
        let reopened = try JSONDecoder().decode(HealthSyncPreferences.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(reopened.disabledSources, [.weight, .bloodGlucose])
        let old = Data(#"{"enabled":true,"disabledRead":[],"sleepReadEnabled":true,"disabledWrite":[],"timeZoneIdentifier":"UTC"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(HealthSyncPreferences.self, from: old).disabledSources, [])
    }

    func testWriteSetIsUnchangedAndOnlyStepsOverlapTheNewReads() {
        XCTAssertEqual(Set(ExportMetricKind.allCases.map(\.rawValue)), Set([
            "heartRate", "restingHeartRate", "heartRateVariabilitySDNN", "respiratoryRate",
            "sleepStages", "steps", "activeEnergy", "completedWorkout"]))
        let written = Set(ExportMetricKind.allCases.map(HealthObjectIdentifier.identifier(for:)))
        let read = Set(AppleHealthSourceKind.allCases.flatMap(\.healthKitIdentifiers))
        XCTAssertEqual(written.intersection(read), ["HKQuantityTypeIdentifierStepCount"])
    }

    #if canImport(HealthKit)
    func testReadAuthorizationCoversEveryKindAndBloodPressureAsTwoTypes() {
        let types = LiveAppleHealthSourceStore.readTypes(for: Set(AppleHealthSourceKind.allCases))
        XCTAssertEqual(types.count, 9)
        let identifiers = Set(types.compactMap { ($0 as? HKQuantityType)?.identifier })
        XCTAssertTrue(identifiers.contains(HKQuantityTypeIdentifier.bloodPressureSystolic.rawValue))
        XCTAssertTrue(identifiers.contains(HKQuantityTypeIdentifier.bloodPressureDiastolic.rawValue))
        XCTAssertTrue(identifiers.contains(HKQuantityTypeIdentifier.timeInDaylight.rawValue))
        XCTAssertTrue(LiveAppleHealthSourceStore.readTypes(for: []).isEmpty)
    }
    #endif
}

private actor AuthorizationRecorder: HealthHistoryAuthorizing {
    private(set) var calls: [(Set<ExportMetricKind>, Set<HealthHistoryQuantity>, Bool)] = []
    func requestAuthorization(sharing share: Set<ExportMetricKind>, reading: Set<HealthHistoryQuantity>,
                              readSleep: Bool) async throws {
        calls.append((share, reading, readSleep))
    }
}

final class AppleHealthAuthorizationRoutingTests: XCTestCase {
    func testAnAuthorizerWithoutSourceSupportStillGetsTheOneSheetRequest() async throws {
        let recorder = AuthorizationRecorder()
        try await recorder.requestAuthorization(sharing: [.heartRate], reading: [.vo2Max], readSleep: true,
                                                sources: Set(AppleHealthSourceKind.allCases))
        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.0, Set<ExportMetricKind>([.heartRate]))
        XCTAssertEqual(calls.first?.1, Set<HealthHistoryQuantity>([.vo2Max]))
        XCTAssertEqual(calls.first?.2, true)
    }
}

final class AppleHealthProvenanceTests: XCTestCase {
    func testLabelNamesTheDeviceForAppleSourcesAndTheAppForOthers() {
        XCTAssertEqual(watch.label, "Apple Watch")
        XCTAssertEqual(phone.label, "iPhone")
        XCTAssertEqual(withings.label, "Withings")
        XCTAssertEqual(byHand.label, "Health")
        XCTAssertEqual(AppleHealthProvenance(sourceName: "", deviceName: "Body+").label, "Body+")
        XCTAssertNil(AppleHealthProvenance.unknown.label)
        XCTAssertNil(AppleHealthProvenance(sourceName: "  ", deviceName: " ").label)
    }

    func testManualEntryFlagReachesTheSampleAndOtherSamplesAreNotFlagged() async {
        let store = FakeAppleHealthStore()
        await store.setSamples([raw(81.2, at: t0, byHand), raw(80.6, at: t0.addingTimeInterval(86_400), withings)], for: .weight)
        let result = await reader(store).read(.weight, from: windowStart, to: windowEnd)
        XCTAssertEqual(result.samples.map(\.provenance.wasUserEntered), [true, false])
        XCTAssertEqual(result.samples.map(\.provenance.label), ["Health", "Withings"])
        XCTAssertEqual(result.samples.first?.provenance.sourceBundleIdentifier, "com.apple.Health")
        XCTAssertEqual(result.latest?.provenance.deviceModel, "WBS05")
    }
}

final class AppleHealthConversionTests: XCTestCase {
    func testBodyFatFractionBecomesPercent() {
        XCTAssertEqual(AppleHealthConversion.percent(fromFraction: 0.215), 21.5)
        XCTAssertEqual(AppleHealthConversion.canonicalValue(.bodyFat, fromStoreValue: 0.183), 18.3)
        XCTAssertNil(AppleHealthConversion.canonicalValue(.bodyFat, fromStoreValue: 21.5), "a percent is not a fraction")
        XCTAssertNil(AppleHealthConversion.canonicalValue(.bodyFat, fromStoreValue: 0))
    }

    func testGlucoseMgPerDeciliterBecomesMmolPerLiter() {
        XCTAssertEqual(AppleHealthConversion.mmolPerLiter(fromMgPerDeciliter: 180.15588), 10, accuracy: 1e-9)
        XCTAssertEqual(AppleHealthConversion.mmolPerLiter(fromMgPerDeciliter: 99), 5.49523, accuracy: 1e-4)
    }

    func testImpossibleValuesAreNotReadings() {
        for kind in AppleHealthSourceKind.allCases {
            XCTAssertNil(AppleHealthConversion.canonicalValue(kind, fromStoreValue: .nan), "\(kind)")
            XCTAssertNil(AppleHealthConversion.canonicalValue(kind, fromStoreValue: .infinity), "\(kind)")
            XCTAssertNil(AppleHealthConversion.canonicalValue(kind, fromStoreValue: -1), "\(kind)")
        }
        for kind in [AppleHealthSourceKind.vo2Max, .weight, .leanMass, .bloodGlucose, .bloodPressure] {
            XCTAssertNil(AppleHealthConversion.canonicalValue(kind, fromStoreValue: 0), "\(kind) of zero is not a reading")
        }
    }
}

final class AppleHealthDiscreteReadTests: XCTestCase {
    func testVO2MaxReadsInCanonicalUnitWithSourceOldestFirst() async throws {
        let store = FakeAppleHealthStore()
        let later = t0.addingTimeInterval(3 * 86_400)
        await store.setSamples([raw(46.1, at: later, length: 1_800), raw(44.2, at: t0, length: 1_800)], for: .vo2Max)
        let result = await reader(store).read(.vo2Max, from: windowStart, to: windowEnd)
        XCTAssertEqual(result.samples.map(\.value), [44.2, 46.1])
        let first = try XCTUnwrap(result.samples.first)
        XCTAssertEqual(first.kind, .vo2Max)
        XCTAssertEqual(first.unit, .mlPerKgPerMin)
        XCTAssertEqual(first.provenance.label, "Apple Watch")
        XCTAssertEqual(first.start, t0)
        XCTAssertEqual(first.end, t0.addingTimeInterval(1_800))
        XCTAssertNil(first.localDay)
        XCTAssertNil(first.diastolic)
        XCTAssertEqual(result.latest?.value, 46.1)
    }

    func testWeightAndLeanMassReadInKilograms() async {
        let store = FakeAppleHealthStore()
        await store.setSamples([raw(82.4, withings)], for: .weight)
        await store.setSamples([raw(64.9, withings)], for: .leanMass)
        let weight = await reader(store).read(.weight, from: windowStart, to: windowEnd)
        let lean = await reader(store).read(.leanMass, from: windowStart, to: windowEnd)
        XCTAssertEqual(weight.samples.first?.value, 82.4)
        XCTAssertEqual(weight.samples.first?.unit, .kilograms)
        XCTAssertEqual(lean.samples.first?.value, 64.9)
        XCTAssertEqual(lean.samples.first?.unit, .kilograms)
        XCTAssertEqual(lean.samples.first?.provenance.label, "Withings")
    }

    func testBodyFatIsStoredAsPercentAndKeepsTheOriginalFraction() async {
        let store = FakeAppleHealthStore()
        await store.setSamples([raw(0.215, withings)], for: .bodyFat)
        let sample = await reader(store).read(.bodyFat, from: windowStart, to: windowEnd).samples.first
        XCTAssertEqual(sample?.value, 21.5)
        XCTAssertEqual(sample?.unit, .percent)
        XCTAssertEqual(sample?.original, AppleHealthOriginalReading(value: 0.215, unit: .fraction))
    }

    func testGlucoseIsMmolPerLiterAndKeepsTheOriginalMgPerDeciliter() async throws {
        let store = FakeAppleHealthStore()
        await store.setSamples([raw(99, at: t0, length: 0, phone)], for: .bloodGlucose)
        let sample = await reader(store).read(.bloodGlucose, from: windowStart, to: windowEnd).samples.first
        XCTAssertEqual(try XCTUnwrap(sample?.value), 5.49523, accuracy: 1e-4)
        XCTAssertEqual(sample?.unit, .mmolPerLiter)
        XCTAssertEqual(sample?.original, AppleHealthOriginalReading(value: 99, unit: .mgPerDeciliter))
        XCTAssertEqual(sample?.provenance.label, "iPhone")
    }

    func testWindowAndSampleLimitKeepTheNewestSamples() async {
        let store = FakeAppleHealthStore()
        let days = (0..<5).map { raw(60 + Double($0), at: t0.addingTimeInterval(Double($0) * 86_400)) }
        await store.setSamples(days, for: .vo2Max)
        let result = await reader(store, limit: 3).read(.vo2Max, from: windowStart, to: windowEnd)
        XCTAssertEqual(result.samples.map(\.value), [62, 63, 64])
        let limits = await store.limitsSeen
        XCTAssertEqual(limits, [3])
        let outside = await reader(store).read(.vo2Max, from: Zone.date(2027, 1, 1, in: utc), to: Zone.date(2027, 2, 1, in: utc))
        XCTAssertEqual(outside, .absent(.noSamples))
    }

    func testLoprsOwnSamplesAreLeftOut() async {
        let store = FakeAppleHealthStore()
        await store.setSamples([raw(80, looprOwn), raw(81, withings)], for: .weight)
        let result = await reader(store, prefixes: ["com.loopr.ios", ""]).read(.weight, from: windowStart, to: windowEnd)
        XCTAssertEqual(result.samples.map(\.value), [81])
        let prefixes = await store.excludedPrefixesSeen
        XCTAssertEqual(prefixes, [["com.loopr.ios"]])
    }

    func testLatestPicksTheMostRecentEndWithItsSource() async {
        let store = FakeAppleHealthStore()
        await store.setSamples([raw(70, at: t0, withings), raw(71, at: t0.addingTimeInterval(86_400), byHand)], for: .weight)
        let result = await reader(store).read(.weight, from: windowStart, to: windowEnd)
        XCTAssertEqual(result.latest?.value, 71)
        XCTAssertEqual(result.latest?.provenance.wasUserEntered, true)
        XCTAssertNil(AppleHealthReadResult.absent(.noSamples).latest)
    }
}

final class AppleHealthBloodPressureTests: XCTestCase {
    private func correlation(_ systolic: [Double], _ diastolic: [Double], at start: Date = t0,
                             _ provenance: AppleHealthProvenance = withings) -> AppleHealthRawBloodPressure {
        AppleHealthRawBloodPressure(
            systolic: systolic.enumerated().map { raw($0.element, at: start.addingTimeInterval(Double($0.offset)), provenance) },
            diastolic: diastolic.enumerated().map { raw($0.element, at: start.addingTimeInterval(Double($0.offset)), provenance) },
            start: start, end: start.addingTimeInterval(5), provenance: provenance)
    }

    func testSystolicAndDiastolicArePairedFromOneCorrelation() async {
        let store = FakeAppleHealthStore()
        await store.setCorrelations([correlation([118], [76]), correlation([126], [82], at: t0.addingTimeInterval(86_400), byHand)])
        let result = await reader(store).read(.bloodPressure, from: windowStart, to: windowEnd)
        XCTAssertEqual(result.samples.map(\.value), [118, 126])
        XCTAssertEqual(result.samples.map(\.diastolic), [76, 82])
        XCTAssertEqual(result.samples.first?.unit, .mmHg)
        XCTAssertEqual(result.samples.first?.provenance.label, "Withings")
        XCTAssertEqual(result.samples.last?.provenance.wasUserEntered, true)
        XCTAssertEqual(result.samples.first?.start, t0)
        XCTAssertEqual(result.samples.first?.end, t0.addingTimeInterval(5))
    }

    func testACorrelationMissingAHalfIsDroppedAndNeverFilledIn() async {
        let store = FakeAppleHealthStore()
        await store.setCorrelations([correlation([118], []), correlation([], [76], at: t0.addingTimeInterval(60)),
                                     correlation([121], [79], at: t0.addingTimeInterval(120))])
        let result = await reader(store).read(.bloodPressure, from: windowStart, to: windowEnd)
        XCTAssertEqual(result.samples.map(\.value), [121])
        XCTAssertEqual(result.samples.map(\.diastolic), [79])
    }

    func testOnlyIncompleteCorrelationsReadAsNoSamplesNotZero() async {
        let store = FakeAppleHealthStore()
        await store.setCorrelations([correlation([118], []), correlation([0], [0], at: t0.addingTimeInterval(60))])
        let result = await reader(store).read(.bloodPressure, from: windowStart, to: windowEnd)
        XCTAssertEqual(result, .absent(.noSamples))
    }

    func testACorrelationWithTwoOfAHalfUsesTheLatest() async {
        let store = FakeAppleHealthStore()
        await store.setCorrelations([correlation([110, 119], [70, 77])])
        let sample = await reader(store).read(.bloodPressure, from: windowStart, to: windowEnd).samples.first
        XCTAssertEqual(sample?.value, 119)
        XCTAssertEqual(sample?.diastolic, 77)
    }
}

final class AppleHealthDailyTotalTests: XCTestCase {
    private func entry(_ start: Date, _ value: Double, _ provenance: AppleHealthProvenance = watch) -> CumulativeEntry {
        CumulativeEntry(start: start, value: value, provenance: provenance)
    }

    func testStepsAreOneTotalPerLocalDayWithTheDominantSource() async {
        let store = FakeAppleHealthStore()
        let day = Zone.date(2026, 10, 20, in: utc)
        await store.setCumulative([
            entry(day.addingTimeInterval(8 * 3_600), 6_000, watch), entry(day.addingTimeInterval(13 * 3_600), 2_500, watch),
            entry(day.addingTimeInterval(15 * 3_600), 1_200, phone),
            entry(day.addingTimeInterval(86_400 + 3_600), 4_000, phone)
        ], for: .steps)
        let result = await reader(store).read(.steps, from: windowStart, to: windowEnd)
        XCTAssertEqual(result.samples.map(\.localDay), ["2026-10-20", "2026-10-21"])
        XCTAssertEqual(result.samples.map(\.value), [9_700, 4_000])
        XCTAssertEqual(result.samples.first?.unit, .stepsPerDay)
        XCTAssertEqual(result.samples.first?.provenance.label, "Apple Watch")
        XCTAssertEqual(result.samples.first?.additionalSourceNames, ["iPhone"])
        XCTAssertEqual(result.samples.last?.provenance.label, "iPhone")
        XCTAssertEqual(result.samples.last?.additionalSourceNames, [])
        XCTAssertNil(result.samples.first?.provenance.wasUserEntered, "a day total carries no manual flag")
        XCTAssertEqual(result.samples.first?.start, day)
        XCTAssertEqual(result.samples.first?.end, day.addingTimeInterval(86_400))
    }

    func testDaylightReadsAsMinutesPerDay() async {
        let store = FakeAppleHealthStore()
        let day = Zone.date(2026, 10, 20, in: utc)
        await store.setCumulative([entry(day.addingTimeInterval(9 * 3_600), 41), entry(day.addingTimeInterval(12 * 3_600), 19)], for: .daylight)
        let sample = await reader(store).read(.daylight, from: windowStart, to: windowEnd).samples.first
        XCTAssertEqual(sample?.value, 60)
        XCTAssertEqual(sample?.unit, .minutesPerDay)
        XCTAssertEqual(sample?.original, AppleHealthOriginalReading(value: 60, unit: .minutes))
    }

    func testTodayEndsAtNowAndSaysItIsPartial() async {
        let store = FakeAppleHealthStore()
        let today = Zone.date(2026, 10, 24, in: utc)
        await store.setCumulative([entry(today.addingTimeInterval(9 * 3_600), 22)], for: .daylight)
        let now = Zone.date(2026, 10, 24, 12, 0, in: utc)
        let sample = await reader(store, now: now).read(.daylight, from: windowStart, to: now).samples.first
        XCTAssertEqual(sample?.start, today)
        XCTAssertEqual(sample?.end, now)
        XCTAssertEqual(sample?.localDay, "2026-10-24")
    }

    func testADayWithNoSamplesIsLeftOutAndNotZero() async {
        let store = FakeAppleHealthStore()
        let monday = Zone.date(2026, 10, 19, in: utc)
        await store.setCumulative([entry(monday.addingTimeInterval(3_600), 5_000),
                                   entry(monday.addingTimeInterval(2 * 86_400 + 3_600), 7_000)], for: .steps)
        let result = await reader(store).read(.steps, from: windowStart, to: windowEnd)
        XCTAssertEqual(result.samples.map(\.localDay), ["2026-10-19", "2026-10-21"])
    }

    func testABucketWithoutASumIsAbsentAndARealZeroIsKept() {
        let day = Zone.date(2026, 10, 20, in: utc)
        let range = windowStart..<windowEnd
        let missing = AppleHealthSourceReader.dailySamples(.steps, buckets: [AppleHealthRawDailyBucket(dayStart: day, sum: nil)],
                                                           window: range, calendar: utc, now: windowEnd)
        XCTAssertTrue(missing.isEmpty)
        let zero = AppleHealthSourceReader.dailySamples(.steps, buckets: [AppleHealthRawDailyBucket(dayStart: day, sum: 0)],
                                                        window: range, calendar: utc, now: windowEnd)
        XCTAssertEqual(zero.map(\.value), [0], "zero is kept only when Apple Health itself reports zero")
        let negative = AppleHealthSourceReader.dailySamples(.steps, buckets: [AppleHealthRawDailyBucket(dayStart: day, sum: -4)],
                                                            window: range, calendar: utc, now: windowEnd)
        XCTAssertTrue(negative.isEmpty)
    }

    func testTiedSourcesPickTheSameDominantSourceEveryTime() {
        let day = Zone.date(2026, 10, 20, in: utc)
        let bucket = AppleHealthRawDailyBucket(dayStart: day, sum: 2_000, contributions: [
            AppleHealthRawContribution(provenance: phone, sum: 1_000), AppleHealthRawContribution(provenance: watch, sum: 1_000)])
        let sample = AppleHealthSourceReader.dailySamples(.steps, buckets: [bucket], window: windowStart..<windowEnd,
                                                          calendar: utc, now: windowEnd).first
        XCTAssertEqual(sample?.provenance.label, "Apple Watch")
        XCTAssertEqual(sample?.additionalSourceNames, ["iPhone"])
    }

    func testLoprsOwnEstimatedStepsAreNotReadBack() async {
        let store = FakeAppleHealthStore()
        let day = Zone.date(2026, 10, 20, in: utc)
        await store.setCumulative([entry(day.addingTimeInterval(3_600), 9_000, looprOwn)], for: .steps)
        let result = await reader(store, prefixes: ["com.loopr.ios"]).read(.steps, from: windowStart, to: windowEnd)
        XCTAssertEqual(result, .absent(.noSamples))
    }

    // MARK: Daylight saving

    func testSpringForwardDayIsTwentyThreeHoursAndHoldsItsOwnSamples() async throws {
        let ny = Zone.calendar("America/New_York")
        let store = FakeAppleHealthStore()
        let mar7 = Zone.date(2026, 3, 7, in: ny), mar8 = Zone.date(2026, 3, 8, in: ny), mar9 = Zone.date(2026, 3, 9, in: ny)
        await store.setCumulative([
            entry(Zone.date(2026, 3, 7, 23, 30, in: ny), 10),
            entry(Zone.date(2026, 3, 8, 0, 30, in: ny), 20), entry(Zone.date(2026, 3, 8, 23, 30, in: ny), 30),
            entry(Zone.date(2026, 3, 9, 0, 30, in: ny), 40)
        ], for: .daylight)
        let now = Zone.date(2026, 3, 12, in: ny)
        let result = await reader(store, calendar: ny, now: now)
            .read(.daylight, from: Zone.date(2026, 3, 7, 6, 0, in: ny), to: now)
        XCTAssertEqual(result.samples.map(\.localDay), ["2026-03-07", "2026-03-08", "2026-03-09"])
        XCTAssertEqual(result.samples.map(\.value), [10, 50, 40])
        let springDay = try XCTUnwrap(result.samples.dropFirst().first)
        XCTAssertEqual(springDay.start, mar8)
        XCTAssertEqual(springDay.end, mar9)
        XCTAssertEqual(springDay.end.timeIntervalSince(springDay.start), 23 * 3_600)
        XCTAssertEqual(result.samples.first?.start, mar7)
        XCTAssertEqual(result.samples.first?.end.timeIntervalSince(mar7), 24 * 3_600)
    }

    func testFallBackDayIsTwentyFiveHoursAndTheLateEveningStaysInIt() async {
        let ny = Zone.calendar("America/New_York")
        let store = FakeAppleHealthStore()
        let nov1 = Zone.date(2026, 11, 1, in: ny), nov2 = Zone.date(2026, 11, 2, in: ny)
        await store.setCumulative([entry(Zone.date(2026, 11, 1, 23, 45, in: ny), 7), entry(Zone.date(2026, 11, 2, 0, 15, in: ny), 9)], for: .steps)
        let now = Zone.date(2026, 11, 5, in: ny)
        let result = await reader(store, calendar: ny, now: now).read(.steps, from: Zone.date(2026, 10, 31, in: ny), to: now)
        XCTAssertEqual(result.samples.map(\.localDay), ["2026-11-01", "2026-11-02"])
        XCTAssertEqual(result.samples.map(\.value), [7, 9])
        XCTAssertEqual(result.samples.first?.start, nov1)
        XCTAssertEqual(result.samples.first?.end, nov2)
        XCTAssertEqual(nov2.timeIntervalSince(nov1), 25 * 3_600)
    }

    func testDayIntervalsFollowTheCalendarAcrossBothChanges() {
        let ny = Zone.calendar("America/New_York")
        let spring = AppleHealthDailyAggregation.dayIntervals(from: Zone.date(2026, 3, 7, 15, 0, in: ny),
                                                              to: Zone.date(2026, 3, 10, 1, 0, in: ny), calendar: ny)
        XCTAssertEqual(spring.map(\.duration), [24, 23, 24, 24].map { Double($0) * 3_600 })
        XCTAssertEqual(spring.first?.start, Zone.date(2026, 3, 7, in: ny))
        let fall = AppleHealthDailyAggregation.dayIntervals(from: Zone.date(2026, 10, 31, in: ny),
                                                            to: Zone.date(2026, 11, 3, in: ny), calendar: ny)
        XCTAssertEqual(fall.map(\.duration), [24, 25, 24].map { Double($0) * 3_600 })
    }

    // MARK: Time zone change

    func testTheSameInstantsLandOnDifferentDaysWhenTheTimeZoneChanges() async {
        let store = FakeAppleHealthStore()
        // 2026-06-10 02:00 UTC is 11:00 on June 10 in Tokyo and 19:00 on June 9 in Los Angeles.
        let instant = Zone.date(2026, 6, 10, 2, 0, in: utc)
        await store.setCumulative([entry(instant, 33)], for: .daylight)
        let now = Zone.date(2026, 6, 12, in: utc)
        let from = Zone.date(2026, 6, 8, in: utc)
        let tokyo = await reader(store, calendar: Zone.calendar("Asia/Tokyo"), now: now).read(.daylight, from: from, to: now)
        let losAngeles = await reader(store, calendar: Zone.calendar("America/Los_Angeles"), now: now).read(.daylight, from: from, to: now)
        XCTAssertEqual(tokyo.samples.map(\.localDay), ["2026-06-10"])
        XCTAssertEqual(losAngeles.samples.map(\.localDay), ["2026-06-09"])
        XCTAssertEqual(tokyo.samples.first?.value, 33)
        XCTAssertEqual(losAngeles.samples.first?.value, 33)
        let zones = await store.calendarsSeen
        XCTAssertEqual(zones, ["Asia/Tokyo", "America/Los_Angeles"], "the reader hands the store the calendar it was given")
    }

    func testAFlightAcrossTheDateLineSplitsTheSameTotalsIntoTheNewZonesDays() async {
        let store = FakeAppleHealthStore()
        let utcDay = Zone.date(2026, 6, 10, in: utc)
        await store.setCumulative([entry(utcDay.addingTimeInterval(1 * 3_600), 100), entry(utcDay.addingTimeInterval(20 * 3_600), 200)], for: .steps)
        let now = Zone.date(2026, 6, 12, in: utc)
        let from = Zone.date(2026, 6, 8, in: utc)
        let home = await reader(store, calendar: utc, now: now).read(.steps, from: from, to: now)
        let away = await reader(store, calendar: Zone.calendar("Pacific/Auckland"), now: now).read(.steps, from: from, to: now)
        XCTAssertEqual(home.samples.map(\.value), [300])
        XCTAssertEqual(away.samples.map(\.value), [100, 200], "Auckland is 12 hours ahead, so the same steps fall on two days")
        XCTAssertEqual(away.samples.reduce(0) { $0 + $1.value }, 300, "no steps are lost or added")
    }
}

final class AppleHealthAbsentStateTests: XCTestCase {
    func testNoSamplesAfterASuccessfulQueryIsAbsentWithANeutralReason() async {
        let store = FakeAppleHealthStore()
        for kind in AppleHealthSourceKind.allCases {
            let result = await reader(store).read(kind, from: windowStart, to: windowEnd)
            XCTAssertEqual(result, .absent(.noSamples), "\(kind)")
            XCTAssertTrue(result.samples.isEmpty)
            XCTAssertNil(result.latest)
        }
    }

    func testAKindNeverRequestedIsNotAuthorizedAndIsNotQueried() async {
        let store = FakeAppleHealthStore()
        await store.setAccess(.notRequested, for: .bloodGlucose)
        await store.setSamples([raw(99)], for: .bloodGlucose)
        let result = await reader(store).read(.bloodGlucose, from: windowStart, to: windowEnd)
        XCTAssertEqual(result, .absent(.notAuthorized))
        let queries = await store.queryCount
        XCTAssertEqual(queries, 0)
    }

    func testADeniedQueryIsNotAuthorized() async {
        for kind in AppleHealthSourceKind.allCases {
            let store = FakeAppleHealthStore()
            await store.setFailure(.authorizationDenied)
            let result = await reader(store).read(kind, from: windowStart, to: windowEnd)
            XCTAssertEqual(result, .absent(.notAuthorized), "\(kind)")
        }
    }

    func testAnUnavailableDeviceOrUnsupportedTypeIsUnavailable() async {
        let noHealth = FakeAppleHealthStore()
        await noHealth.setAccess(.unavailable, for: .daylight)
        let unsupported = FakeAppleHealthStore()
        await unsupported.setFailure(.unavailable)
        let first = await reader(noHealth).read(.daylight, from: windowStart, to: windowEnd)
        let second = await reader(unsupported).read(.weight, from: windowStart, to: windowEnd)
        XCTAssertEqual(first, .absent(.unavailable))
        XCTAssertEqual(second, .absent(.unavailable))
        for kind in AppleHealthSourceKind.allCases {
            let result = await AppleHealthSourceReader(store: UnavailableAppleHealthSourceStore(), calendar: utc, clock: { windowEnd })
                .read(kind, from: windowStart, to: windowEnd)
            XCTAssertEqual(result, .absent(.unavailable), "\(kind)")
        }
    }

    func testAFailedQueryIsAbsentWithItsMessage() async {
        struct Locked: Error {}
        let failing = FakeAppleHealthStore()
        await failing.setFailure(.failed("locked"))
        let other = FakeAppleHealthStore()
        await other.setRawFailure(Locked())
        let first = await reader(failing).read(.vo2Max, from: windowStart, to: windowEnd)
        let second = await reader(other).read(.vo2Max, from: windowStart, to: windowEnd)
        XCTAssertEqual(first, .absent(.queryFailed("locked")))
        guard case .absent(.queryFailed) = second else { return XCTFail("expected queryFailed, got \(second)") }
    }

    func testZeroAndGarbageValuesNeverBecomeReadings() async {
        let store = FakeAppleHealthStore()
        await store.setSamples([raw(0), raw(.nan), raw(-3)], for: .weight)
        await store.setSamples([raw(0), raw(1.4)], for: .bodyFat)
        await store.setSamples([raw(0)], for: .vo2Max)
        let weight = await reader(store).read(.weight, from: windowStart, to: windowEnd)
        let fat = await reader(store).read(.bodyFat, from: windowStart, to: windowEnd)
        let vo2 = await reader(store).read(.vo2Max, from: windowStart, to: windowEnd)
        XCTAssertEqual(weight, .absent(.noSamples))
        XCTAssertEqual(fat, .absent(.noSamples))
        XCTAssertEqual(vo2, .absent(.noSamples))
    }

    func testAnEmptyOrBackwardsWindowIsAbsent() async {
        let store = FakeAppleHealthStore()
        await store.setSamples([raw(80)], for: .weight)
        let result = await reader(store).read(.weight, from: windowEnd, to: windowStart)
        XCTAssertEqual(result, .absent(.noSamples))
    }

    func testAbsenceCasesAreDistinctAndAccessible() {
        let reasons: [AppleHealthAbsence] = [.noSamples, .notAuthorized, .switchedOff, .unavailable, .queryFailed("x")]
        XCTAssertEqual(Set(reasons.map { "\($0)" }).count, 5)
        XCTAssertEqual(AppleHealthReadResult.absent(.switchedOff).absence, .switchedOff)
        XCTAssertNil(AppleHealthReadResult.values([]).absence)
    }
}
