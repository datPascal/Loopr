import Foundation

// Apple Health as a read source (DEC-12.16).
//
// Loopr reads eight kinds of value from Apple Health and keeps the source of
// each one: the app or device that wrote the sample, for example "Apple Watch"
// or "Withings". Nothing here writes to Apple Health, and no Loopr score is
// read back or exported (DEC-02.8 is unchanged).
//
// HealthKit stays behind `AppleHealthSourceStore`, so the unit conversion,
// blood pressure pairing, daily aggregation and absent states in this file run
// against a fake store in tests. The live store is in
// `AppleHealthSourcesHealthKit.swift`.
//
// Missing data stays missing (golden rule 6). A read that finds nothing returns
// `.absent` with a reason. It never returns zero.

/// The eight kinds Apple Health supplies.
public enum AppleHealthSourceKind: String, CaseIterable, Codable, Hashable, Sendable {
    case vo2Max
    /// Minutes in daylight, summed per local day.
    case daylight
    /// Systolic and diastolic from the blood pressure correlation.
    case bloodPressure
    case weight
    case bodyFat
    case leanMass
    case bloodGlucose
    /// Steps, summed per local day.
    case steps

    /// The HealthKit identifiers this kind needs read access to. Blood
    /// pressure needs two, because HealthKit asks for the systolic and
    /// diastolic types and not for the correlation.
    public var healthKitIdentifiers: [String] {
        switch self {
        case .vo2Max: ["HKQuantityTypeIdentifierVO2Max"]
        case .daylight: ["HKQuantityTypeIdentifierTimeInDaylight"]
        case .bloodPressure: ["HKQuantityTypeIdentifierBloodPressureSystolic",
                              "HKQuantityTypeIdentifierBloodPressureDiastolic"]
        case .weight: ["HKQuantityTypeIdentifierBodyMass"]
        case .bodyFat: ["HKQuantityTypeIdentifierBodyFatPercentage"]
        case .leanMass: ["HKQuantityTypeIdentifierLeanBodyMass"]
        case .bloodGlucose: ["HKQuantityTypeIdentifierBloodGlucose"]
        case .steps: ["HKQuantityTypeIdentifierStepCount"]
        }
    }

    /// Daylight and steps arrive as one total per local day. The rest arrive
    /// as the samples that were written.
    public var isDailyAggregate: Bool { self == .daylight || self == .steps }

    /// The unit of `AppleHealthSample.value`.
    public var canonicalUnit: AppleHealthUnit {
        switch self {
        case .vo2Max: .mlPerKgPerMin
        case .daylight: .minutesPerDay
        case .bloodPressure: .mmHg
        case .weight, .leanMass: .kilograms
        case .bodyFat: .percent
        case .bloodGlucose: .mmolPerLiter
        case .steps: .stepsPerDay
        }
    }

    /// The unit a store hands values over in, before conversion.
    public var storeUnit: AppleHealthUnit {
        switch self {
        case .vo2Max: .mlPerKgPerMin
        case .daylight: .minutes
        case .bloodPressure: .mmHg
        case .weight, .leanMass: .kilograms
        case .bodyFat: .fraction
        case .bloodGlucose: .mgPerDeciliter
        case .steps: .count
        }
    }

    /// The history quantity that already covers this kind, and so already has
    /// a switch in Settings. Nil for the six kinds added by DEC-12.16.
    public var historyQuantity: HealthHistoryQuantity? {
        switch self {
        case .vo2Max: .vo2Max
        case .steps: .steps
        case .daylight, .bloodPressure, .weight, .bodyFat, .leanMass, .bloodGlucose: nil
        }
    }

    /// The kinds that are new in DEC-12.16, in the order Settings lists them.
    public static let addedReads: [AppleHealthSourceKind] = [
        .daylight, .bloodPressure, .weight, .bodyFat, .leanMass, .bloodGlucose
    ]
}

public enum AppleHealthUnit: String, Codable, Hashable, Sendable {
    case mlPerKgPerMin = "mL/kg/min"
    case minutes = "min"
    case minutesPerDay = "min/day"
    case mmHg = "mmHg"
    case kilograms = "kg"
    /// A 0...1 share, as HealthKit stores body fat.
    case fraction = "fraction"
    /// A 0...100 share.
    case percent = "%"
    case mgPerDeciliter = "mg/dL"
    case mmolPerLiter = "mmol/L"
    case count = "count"
    case stepsPerDay = "steps/day"
}

/// Who wrote a sample.
public struct AppleHealthProvenance: Equatable, Hashable, Codable, Sendable {
    /// `HKSource.name`. Empty only when Apple Health gave no name.
    public let sourceName: String
    public let sourceBundleIdentifier: String?
    /// `HKDevice.name`, for example "Apple Watch", when the sample has one.
    public let deviceName: String?
    /// `HKDevice.model`, when the sample has one.
    public let deviceModel: String?
    /// `HKMetadataKeyWasUserEntered`. True when the person typed the value
    /// into Apple Health. False when the sample carries no such flag. Nil for
    /// daily totals, because Apple Health statistics do not carry metadata.
    public let wasUserEntered: Bool?

    public init(sourceName: String, sourceBundleIdentifier: String? = nil, deviceName: String? = nil,
                deviceModel: String? = nil, wasUserEntered: Bool? = nil) {
        self.sourceName = sourceName
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.deviceName = deviceName
        self.deviceModel = deviceModel
        self.wasUserEntered = wasUserEntered
    }

    /// For a daily total whose contributing source is not known.
    public static let unknown = AppleHealthProvenance(sourceName: "")

    /// The same source with the manual-entry flag cleared to unknown. Daily
    /// totals use it, since Apple Health statistics do not carry metadata.
    public var withoutManualFlag: AppleHealthProvenance {
        AppleHealthProvenance(sourceName: sourceName, sourceBundleIdentifier: sourceBundleIdentifier,
                              deviceName: deviceName, deviceModel: deviceModel, wasUserEntered: nil)
    }

    /// The name to show next to a value. Apple's own sources are named after
    /// the person's device ("Pascal's Apple Watch"), so for those the device
    /// name ("Apple Watch") is used. Nil when nothing names the source.
    public var label: String? {
        let source = sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let device = (deviceName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !device.isEmpty, let bundle = sourceBundleIdentifier, bundle.hasPrefix("com.apple.health.") { return device }
        if !source.isEmpty { return source }
        return device.isEmpty ? nil : device
    }
}

/// The number as the store handed it over, before conversion.
public struct AppleHealthOriginalReading: Equatable, Hashable, Codable, Sendable {
    public let value: Double
    public let unit: AppleHealthUnit
    public init(value: Double, unit: AppleHealthUnit) { self.value = value; self.unit = unit }
}

/// One reading, in canonical units, with its source.
public struct AppleHealthSample: Equatable, Hashable, Codable, Sendable {
    public let kind: AppleHealthSourceKind
    /// In `kind.canonicalUnit`. For blood pressure this is the systolic value.
    public let value: Double
    /// The diastolic value. Set for blood pressure and nil for every other kind.
    public let diastolic: Double?
    public let unit: AppleHealthUnit
    /// What the store reported before conversion, so a converted value can be
    /// checked against Apple Health. For blood glucose this is the mg/dL
    /// number. Apple Health does not say which unit the writing app used, so
    /// mg/dL is the unit the number was read in. For blood pressure it is the
    /// systolic number.
    public let original: AppleHealthOriginalReading
    /// For a daily total, the start of the local day and the earlier of the
    /// end of that day and now. Otherwise the sample's own interval.
    public let start: Date
    public let end: Date
    /// `YYYY-MM-DD` in the reader's calendar. Set for daily totals only.
    public let localDay: String?
    public let provenance: AppleHealthProvenance
    /// Daily totals only: the other sources that added to the same day, by
    /// label, so a day made of Apple Watch and iPhone steps says so.
    public let additionalSourceNames: [String]

    public init(kind: AppleHealthSourceKind, value: Double, diastolic: Double? = nil,
                original: AppleHealthOriginalReading, start: Date, end: Date, localDay: String? = nil,
                provenance: AppleHealthProvenance, additionalSourceNames: [String] = []) {
        self.kind = kind
        self.value = value
        self.diastolic = diastolic
        self.unit = kind.canonicalUnit
        self.original = original
        self.start = start
        self.end = end
        self.localDay = localDay
        self.provenance = provenance
        self.additionalSourceNames = additionalSourceNames
    }
}

/// Why a read has no value. None of these is zero.
public enum AppleHealthAbsence: Equatable, Sendable {
    /// The query ran and found nothing. Apple Health does not reveal whether
    /// the person denied read access or simply has no data, so both land here.
    case noSamples
    /// Loopr has not asked for this type yet, or Apple Health refused the
    /// query as not authorized.
    case notAuthorized
    /// The person switched this read off in Loopr.
    case switchedOff
    /// This device or OS has no Apple Health, or no such type.
    case unavailable
    /// Apple Health failed the query, for example while the phone is locked.
    /// Try again later.
    case queryFailed(String)
}

public enum AppleHealthReadResult: Equatable, Sendable {
    /// At least one sample, oldest first.
    case values([AppleHealthSample])
    case absent(AppleHealthAbsence)

    public var samples: [AppleHealthSample] {
        if case .values(let samples) = self { samples } else { [] }
    }

    public var absence: AppleHealthAbsence? {
        if case .absent(let reason) = self { reason } else { nil }
    }

    /// The most recent sample by end date, with its source. The source summary
    /// for the Data tab reads this per kind.
    public var latest: AppleHealthSample? {
        samples.max { ($0.end, $0.start) < ($1.end, $1.start) }
    }
}

// MARK: - Store boundary

public enum AppleHealthStoreAccess: Equatable, Sendable {
    /// No Apple Health on this device, or this OS has no such type.
    case unavailable
    /// Loopr has not shown the read request for this kind yet.
    case notRequested
    /// The request was shown. HealthKit does not say what the person chose.
    case requested
}

public enum AppleHealthStoreError: Error, Equatable, Sendable {
    case authorizationDenied
    case unavailable
    case failed(String)
}

/// A sample as the store read it, in `kind.storeUnit`.
public struct AppleHealthRawSample: Equatable, Sendable {
    public let value: Double
    public let start: Date
    public let end: Date
    public let provenance: AppleHealthProvenance
    public init(value: Double, start: Date, end: Date, provenance: AppleHealthProvenance) {
        self.value = value; self.start = start; self.end = end; self.provenance = provenance
    }
}

/// One blood pressure correlation: the systolic and diastolic samples it
/// holds, and who wrote it. mmHg.
public struct AppleHealthRawBloodPressure: Equatable, Sendable {
    public let systolic: [AppleHealthRawSample]
    public let diastolic: [AppleHealthRawSample]
    public let start: Date
    public let end: Date
    public let provenance: AppleHealthProvenance
    public init(systolic: [AppleHealthRawSample], diastolic: [AppleHealthRawSample],
                start: Date, end: Date, provenance: AppleHealthProvenance) {
        self.systolic = systolic; self.diastolic = diastolic
        self.start = start; self.end = end; self.provenance = provenance
    }
}

public struct AppleHealthRawContribution: Equatable, Sendable {
    public let provenance: AppleHealthProvenance
    public let sum: Double
    public init(provenance: AppleHealthProvenance, sum: Double) { self.provenance = provenance; self.sum = sum }
}

/// One local day of cumulative statistics, in `kind.storeUnit`.
public struct AppleHealthRawDailyBucket: Equatable, Sendable {
    public let dayStart: Date
    /// Nil when nothing was recorded that day. Zero only when Apple Health
    /// itself reports zero.
    public let sum: Double?
    public let contributions: [AppleHealthRawContribution]
    public init(dayStart: Date, sum: Double?, contributions: [AppleHealthRawContribution] = []) {
        self.dayStart = dayStart; self.sum = sum; self.contributions = contributions
    }
}

/// Reads Apple Health. The live implementation is `LiveAppleHealthSourceStore`.
/// Implementations leave out samples written by a source whose bundle
/// identifier starts with one of `excludingBundlePrefixes`, so Loopr's own
/// estimated steps are never read back as outside data.
public protocol AppleHealthSourceStore: Sendable {
    func access(for kind: AppleHealthSourceKind) async -> AppleHealthStoreAccess

    /// The newest `limit` samples that overlap the window, in any order.
    func samples(of kind: AppleHealthSourceKind, from start: Date, to end: Date, limit: Int,
                 excludingBundlePrefixes: [String]) async throws -> [AppleHealthRawSample]

    /// The newest `limit` blood pressure correlations in the window.
    func bloodPressure(from start: Date, to end: Date, limit: Int,
                       excludingBundlePrefixes: [String]) async throws -> [AppleHealthRawBloodPressure]

    /// One bucket per local day of `calendar`, from the start of the day that
    /// holds `start`. The store must cut days with the calendar it is given,
    /// so a 23 or 25 hour day is one bucket and a different time zone gives
    /// different days. A day with no samples is left out.
    func dailyBuckets(of kind: AppleHealthSourceKind, from start: Date, to end: Date, calendar: Calendar,
                      excludingBundlePrefixes: [String]) async throws -> [AppleHealthRawDailyBucket]
}

/// The store for a build or device without Apple Health.
public struct UnavailableAppleHealthSourceStore: AppleHealthSourceStore {
    public init() {}
    public func access(for kind: AppleHealthSourceKind) async -> AppleHealthStoreAccess { .unavailable }
    public func samples(of kind: AppleHealthSourceKind, from start: Date, to end: Date, limit: Int,
                        excludingBundlePrefixes: [String]) async throws -> [AppleHealthRawSample] { throw AppleHealthStoreError.unavailable }
    public func bloodPressure(from start: Date, to end: Date, limit: Int,
                              excludingBundlePrefixes: [String]) async throws -> [AppleHealthRawBloodPressure] { throw AppleHealthStoreError.unavailable }
    public func dailyBuckets(of kind: AppleHealthSourceKind, from start: Date, to end: Date, calendar: Calendar,
                             excludingBundlePrefixes: [String]) async throws -> [AppleHealthRawDailyBucket] { throw AppleHealthStoreError.unavailable }
}

// MARK: - Conversion

public enum AppleHealthConversion {
    /// Molar mass of glucose, g/mol. This is HealthKit's
    /// `HKUnitMolarMassBloodGlucose`, so a value converted here matches one
    /// HealthKit converts itself.
    public static let glucoseMolarMass = 180.15588

    public static func mmolPerLiter(fromMgPerDeciliter mgPerDl: Double) -> Double {
        mgPerDl * 10 / glucoseMolarMass
    }

    /// Body fat as a 0...100 percent, rounded to six decimals so 0.215 reads
    /// as 21.5 and not 21.499999999999996.
    public static func percent(fromFraction fraction: Double) -> Double {
        (fraction * 100 * 1_000_000).rounded() / 1_000_000
    }

    /// The canonical value for one store value, or nil when it cannot be a
    /// real reading of that kind (not finite, zero or negative where that is
    /// impossible, a body fat outside 0...1).
    public static func canonicalValue(_ kind: AppleHealthSourceKind, fromStoreValue value: Double) -> Double? {
        guard value.isFinite else { return nil }
        switch kind {
        case .vo2Max, .weight, .leanMass, .bloodPressure:
            return value > 0 ? value : nil
        case .bodyFat:
            return value > 0 && value <= 1 ? percent(fromFraction: value) : nil
        case .bloodGlucose:
            return value > 0 ? mmolPerLiter(fromMgPerDeciliter: value) : nil
        case .daylight, .steps:
            // A day total of zero is real only when Apple Health reports it.
            return value >= 0 ? value : nil
        }
    }
}

// MARK: - Reader

/// What the app and the other packages ask.
public protocol AppleHealthSourceReading: Sendable {
    /// Reads one kind over a window. Never throws. A failure, a denial, an
    /// empty result and an unsupported type each come back as `.absent`.
    func read(_ kind: AppleHealthSourceKind, from start: Date, to end: Date) async -> AppleHealthReadResult
}

public struct AppleHealthSourceReader: AppleHealthSourceReading {
    /// The default cap on raw samples. A continuous glucose monitor writes
    /// hundreds a day, so a long window keeps the newest ones.
    public static let defaultSampleLimit = 5_000

    private let store: any AppleHealthSourceStore
    private let calendar: Calendar
    private let clock: @Sendable () -> Date
    private let excludedBundlePrefixes: [String]
    private let sampleLimit: Int

    /// `calendar` carries the time zone that cuts local days. `clock` supplies
    /// "now", which ends today's partial total.
    public init(store: any AppleHealthSourceStore, calendar: Calendar, clock: @escaping @Sendable () -> Date,
                excludingBundlePrefixes: [String] = [], sampleLimit: Int = AppleHealthSourceReader.defaultSampleLimit) {
        self.store = store
        self.calendar = calendar
        self.clock = clock
        self.excludedBundlePrefixes = excludingBundlePrefixes.filter { !$0.isEmpty }
        self.sampleLimit = max(1, sampleLimit)
    }

    public func read(_ kind: AppleHealthSourceKind, from start: Date, to end: Date) async -> AppleHealthReadResult {
        switch await store.access(for: kind) {
        case .unavailable: return .absent(.unavailable)
        case .notRequested: return .absent(.notAuthorized)
        case .requested: break
        }
        guard start < end else { return .absent(.noSamples) }
        do {
            let samples: [AppleHealthSample]
            switch kind {
            case .bloodPressure:
                let correlations = try await store.bloodPressure(from: start, to: end, limit: sampleLimit,
                                                                 excludingBundlePrefixes: excludedBundlePrefixes)
                samples = Self.bloodPressureSamples(correlations)
            case .daylight, .steps:
                let buckets = try await store.dailyBuckets(of: kind, from: start, to: end, calendar: calendar,
                                                           excludingBundlePrefixes: excludedBundlePrefixes)
                samples = Self.dailySamples(kind, buckets: buckets, window: start..<end, calendar: calendar, now: clock())
            case .vo2Max, .weight, .bodyFat, .leanMass, .bloodGlucose:
                let raw = try await store.samples(of: kind, from: start, to: end, limit: sampleLimit,
                                                  excludingBundlePrefixes: excludedBundlePrefixes)
                samples = Self.discreteSamples(kind, raw: raw)
            }
            return samples.isEmpty ? .absent(.noSamples) : .values(samples)
        } catch let error as AppleHealthStoreError {
            switch error {
            case .authorizationDenied: return .absent(.notAuthorized)
            case .unavailable: return .absent(.unavailable)
            case .failed(let message): return .absent(.queryFailed(message))
            }
        } catch {
            return .absent(.queryFailed(String(describing: error)))
        }
    }

    // MARK: Mapping, pure so tests pin the rules

    static func discreteSamples(_ kind: AppleHealthSourceKind, raw: [AppleHealthRawSample]) -> [AppleHealthSample] {
        raw.compactMap { sample -> AppleHealthSample? in
            guard sample.start <= sample.end,
                  let value = AppleHealthConversion.canonicalValue(kind, fromStoreValue: sample.value) else { return nil }
            return AppleHealthSample(kind: kind, value: value,
                original: AppleHealthOriginalReading(value: sample.value, unit: kind.storeUnit),
                start: sample.start, end: sample.end, provenance: sample.provenance)
        }
        .sorted(by: ordered)
    }

    /// Pairs the systolic and diastolic sample inside each correlation. A
    /// correlation missing either half is dropped, never filled in. When a
    /// correlation holds more than one of a half, the latest one is used.
    static func bloodPressureSamples(_ correlations: [AppleHealthRawBloodPressure]) -> [AppleHealthSample] {
        correlations.compactMap { correlation -> AppleHealthSample? in
            guard correlation.start <= correlation.end,
                  let systolic = latest(correlation.systolic),
                  let diastolic = latest(correlation.diastolic),
                  let systolicValue = AppleHealthConversion.canonicalValue(.bloodPressure, fromStoreValue: systolic.value),
                  let diastolicValue = AppleHealthConversion.canonicalValue(.bloodPressure, fromStoreValue: diastolic.value)
            else { return nil }
            return AppleHealthSample(kind: .bloodPressure, value: systolicValue, diastolic: diastolicValue,
                original: AppleHealthOriginalReading(value: systolic.value, unit: .mmHg),
                start: correlation.start, end: correlation.end, provenance: correlation.provenance)
        }
        .sorted(by: ordered)
    }

    /// One sample per local day. The day runs from its start to the earlier of
    /// its end and `now`, so today's partial total says it is partial, and a
    /// 23 or 25 hour day on a daylight saving change is its true length.
    static func dailySamples(_ kind: AppleHealthSourceKind, buckets: [AppleHealthRawDailyBucket],
                             window: Range<Date>, calendar: Calendar, now: Date) -> [AppleHealthSample] {
        var byDay: [String: AppleHealthSample] = [:]
        for bucket in buckets {
            guard let sum = bucket.sum, let value = AppleHealthConversion.canonicalValue(kind, fromStoreValue: sum),
                  bucket.dayStart < window.upperBound,
                  let day = calendar.dateInterval(of: .day, for: bucket.dayStart) else { continue }
            let end = min(day.end, now, window.upperBound)
            guard day.start < end else { continue }
            let contributors = bucket.contributions
                .filter { $0.sum.isFinite && $0.sum > 0 }
                .sorted { ($1.sum, $0.provenance.label ?? "") < ($0.sum, $1.provenance.label ?? "") }
            let dominant = contributors.first?.provenance.withoutManualFlag ?? .unknown
            var others: [String] = []
            for contributor in contributors.dropFirst() {
                if let label = contributor.provenance.label, label != dominant.label, !others.contains(label) {
                    others.append(label)
                }
            }
            let localDay = HealthHistoryDay.localDay(for: day.start, calendar: calendar)
            byDay[localDay] = AppleHealthSample(kind: kind, value: value,
                original: AppleHealthOriginalReading(value: sum, unit: kind.storeUnit),
                start: day.start, end: end, localDay: localDay, provenance: dominant,
                additionalSourceNames: others.sorted())
        }
        return byDay.values.sorted(by: ordered)
    }

    private static func latest(_ samples: [AppleHealthRawSample]) -> AppleHealthRawSample? {
        samples.max { ($0.end, $0.start) < ($1.end, $1.start) }
    }

    private static func ordered(_ lhs: AppleHealthSample, _ rhs: AppleHealthSample) -> Bool {
        (lhs.start, lhs.end) < (rhs.start, rhs.end)
    }
}

/// Which days a daily total covers. Pure, so a daylight saving change and a
/// time zone change are pinned by tests.
public enum AppleHealthDailyAggregation {
    /// The local days of `calendar` from the day holding `start` up to `end`.
    public static func dayIntervals(from start: Date, to end: Date, calendar: Calendar) -> [DateInterval] {
        var result: [DateInterval] = []
        var cursor = calendar.startOfDay(for: start)
        while cursor < end, result.count < 1_000 {
            guard let interval = calendar.dateInterval(of: .day, for: cursor), interval.end > cursor else { break }
            result.append(interval)
            cursor = interval.end
        }
        return result
    }
}
