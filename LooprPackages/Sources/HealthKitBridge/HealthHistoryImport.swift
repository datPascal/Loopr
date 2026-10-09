import Foundation

// Apple Health history import: daily values for the metric history charts.
//
// HealthKit itself stays behind `HealthHistoryQueryClient`, so everything in
// this file runs against a fake store in tests. The live client lives in
// `HealthHistoryHealthKit.swift`.

/// A HealthKit quantity Loopr reads as one value per day.
public enum HealthHistoryQuantity: String, CaseIterable, Codable, Hashable, Sendable {
    case restingHeartRate
    case heartRateVariabilitySDNN
    case respiratoryRate
    case oxygenSaturation
    case vo2Max
    /// Read only for the day's highest heart rate.
    case heartRate
    case steps
    case activeEnergy

    // Keep the legacy case decodable for saved preferences, but never offer
    // or import it. Product decision DEC-02.6 keeps oxygen out of HealthKit.
    public static let allCases: [HealthHistoryQuantity] = [
        .restingHeartRate, .heartRateVariabilitySDNN, .respiratoryRate,
        .vo2Max, .heartRate, .steps, .activeEnergy
    ]

    /// The HealthKit identifier this quantity is read from.
    public var healthKitIdentifier: String {
        switch self {
        case .restingHeartRate: "HKQuantityTypeIdentifierRestingHeartRate"
        case .heartRateVariabilitySDNN: "HKQuantityTypeIdentifierHeartRateVariabilitySDNN"
        case .respiratoryRate: "HKQuantityTypeIdentifierRespiratoryRate"
        case .oxygenSaturation: "HKQuantityTypeIdentifierOxygenSaturation"
        case .vo2Max: "HKQuantityTypeIdentifierVO2Max"
        case .heartRate: "HKQuantityTypeIdentifierHeartRate"
        case .steps: "HKQuantityTypeIdentifierStepCount"
        case .activeEnergy: "HKQuantityTypeIdentifierActiveEnergyBurned"
        }
    }

    /// Cumulative quantities are summed per day; the rest are discrete.
    public var isCumulative: Bool { self == .steps || self == .activeEnergy }
}

/// The metric-history keys the import writes. Raw values match the app's
/// `MetricKey` raw values exactly; a test in the app pins that.
public enum HealthHistoryMetric: String, CaseIterable, Codable, Hashable, Sendable {
    case restingHeartRate = "resting_heart_rate"
    /// Apple Health stores SDNN. It is never written as RMSSD.
    case sdnn
    case respiratoryRate = "respiratory_rate"
    case oxygenSaturation = "oxygen_saturation"
    case vo2Max = "vo2_max"
    case maxHeartRate = "max_heart_rate"
    case steps
    case activeEnergy = "active_energy"
    case sleepDuration = "sleep_duration"
    case deepSleep = "deep_sleep"
    case remSleep = "rem_sleep"
    case sleepEfficiency = "sleep_efficiency"

    public static let sleepMetrics: [HealthHistoryMetric] = [.sleepDuration, .deepSleep, .remSleep, .sleepEfficiency]
}

/// One day of HealthKit statistics in HealthKit's canonical unit for the
/// quantity: count/min for rates, ms for SDNN, a 0...1 fraction for oxygen
/// saturation, mL/(kg·min) for VO2 max, count for steps, kcal for energy.
public struct HealthDailyStatistic: Equatable, Sendable {
    public let dayStart: Date
    public let average: Double?
    public let minimum: Double?
    public let maximum: Double?
    public let sum: Double?

    public init(dayStart: Date, average: Double? = nil, minimum: Double? = nil, maximum: Double? = nil, sum: Double? = nil) {
        self.dayStart = dayStart
        self.average = average
        self.minimum = minimum
        self.maximum = maximum
        self.sum = sum
    }
}

public enum HealthSleepStage: String, Codable, Hashable, Sendable {
    case inBed, awake, asleepUnspecified, asleepCore, asleepDeep, asleepREM

    /// HKCategoryValueSleepAnalysis raw values.
    public init?(healthKitValue: Int) {
        switch healthKitValue {
        case 0: self = .inBed
        case 1: self = .asleepUnspecified
        case 2: self = .awake
        case 3: self = .asleepCore
        case 4: self = .asleepDeep
        case 5: self = .asleepREM
        default: return nil
        }
    }

    var isAsleep: Bool {
        switch self {
        case .asleepUnspecified, .asleepCore, .asleepDeep, .asleepREM: true
        case .inBed, .awake: false
        }
    }

    var isStage: Bool { self == .asleepCore || self == .asleepDeep || self == .asleepREM }
}

public struct HealthSleepSample: Equatable, Sendable {
    public let start: Date
    public let end: Date
    public let stage: HealthSleepStage
    public let sourceBundleIdentifier: String?

    public init(start: Date, end: Date, stage: HealthSleepStage, sourceBundleIdentifier: String? = nil) {
        self.start = start
        self.end = end
        self.stage = stage
        self.sourceBundleIdentifier = sourceBundleIdentifier
    }
}

/// One stored day for the metric history.
public struct HealthHistoryDayValue: Equatable, Hashable, Sendable {
    public let metric: HealthHistoryMetric
    /// `YYYY-MM-DD` in the importer's calendar.
    public let localDay: String
    public let value: Double
    public let low: Double?
    public let high: Double?

    public init(metric: HealthHistoryMetric, localDay: String, value: Double, low: Double? = nil, high: Double? = nil) {
        self.metric = metric
        self.localDay = localDay
        self.value = value
        self.low = low
        self.high = high
    }
}

/// Reads Apple Health. Implementations must leave out every sample written by
/// a source whose bundle identifier starts with one of `excludingBundlePrefixes`,
/// so Loopr's own exports are never read back as outside data.
public protocol HealthHistoryQueryClient: Sendable {
    func dailyStatistics(for quantity: HealthHistoryQuantity, from start: Date, to end: Date,
                         calendar: Calendar, excludingBundlePrefixes: [String]) async throws -> [HealthDailyStatistic]
    func sleepSamples(from start: Date, to end: Date,
                      excludingBundlePrefixes: [String]) async throws -> [HealthSleepSample]
    /// True once the person has answered Loopr's read request for the
    /// history types. HealthKit never reveals whether reading was allowed, so
    /// this is the most an app can know; a denied type simply reads as empty.
    func historyReadAccessRequested() async -> Bool
    func historyReadAccessRequested(reading: Set<HealthHistoryQuantity>, readSleep: Bool) async -> Bool
}

public extension HealthHistoryQueryClient {
    func historyReadAccessRequested(reading: Set<HealthHistoryQuantity>, readSleep: Bool) async -> Bool {
        await historyReadAccessRequested()
    }
}

/// Where imported days and import progress are kept.
public protocol HealthHistoryImportStore: Sendable {
    func importCursor(for key: String) throws -> Date?
    func setImportCursor(_ date: Date, for key: String) throws
    /// Replaces the stored Apple Health values of `metric` for every day in
    /// the inclusive range, deleting days that are not in `values`.
    func replaceDailyValues(_ metric: HealthHistoryMetric, from lowerDay: String, through upperDay: String,
                            values: [HealthHistoryDayValue]) throws
}

public struct HealthHistoryImportReport: Equatable, Sendable {
    public var importedDays: [HealthHistoryMetric: Int] = [:]
    public var failures: [String: String] = [:]
    public var skippedForAccess = false
    public init() {}
}

public enum HealthHistoryDay {
    public static func localDay(for date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// Maps one quantity's daily statistics to history values. Pure, so the
/// unit and key rules are pinned by tests.
public enum HealthHistoryMapping {
    public static func metric(for quantity: HealthHistoryQuantity) -> HealthHistoryMetric {
        switch quantity {
        case .restingHeartRate: .restingHeartRate
        case .heartRateVariabilitySDNN: .sdnn
        case .respiratoryRate: .respiratoryRate
        case .oxygenSaturation: .oxygenSaturation
        case .vo2Max: .vo2Max
        case .heartRate: .maxHeartRate
        case .steps: .steps
        case .activeEnergy: .activeEnergy
        }
    }

    public static func values(for quantity: HealthHistoryQuantity, statistics: [HealthDailyStatistic],
                              calendar: Calendar) -> [HealthHistoryDayValue] {
        let metric = metric(for: quantity)
        // Oxygen saturation arrives as a fraction; history stores percent.
        let scale = quantity == .oxygenSaturation ? 100.0 : 1.0
        func finite(_ value: Double?) -> Double? {
            guard let value, value.isFinite else { return nil }
            return value * scale
        }
        var byDay: [String: HealthHistoryDayValue] = [:]
        for statistic in statistics {
            let day = HealthHistoryDay.localDay(for: statistic.dayStart, calendar: calendar)
            let value: HealthHistoryDayValue?
            switch quantity {
            case .steps, .activeEnergy:
                // A day with no samples has no sum. Zero is only stored when
                // HealthKit itself reports zero.
                value = finite(statistic.sum).flatMap { $0 >= 0 ? HealthHistoryDayValue(metric: metric, localDay: day, value: $0) : nil }
            case .heartRate:
                value = finite(statistic.maximum).flatMap { $0 > 0 ? HealthHistoryDayValue(metric: metric, localDay: day, value: $0) : nil }
            case .restingHeartRate, .heartRateVariabilitySDNN, .respiratoryRate, .oxygenSaturation, .vo2Max:
                value = finite(statistic.average).flatMap {
                    $0 > 0 ? HealthHistoryDayValue(metric: metric, localDay: day, value: $0,
                        low: finite(statistic.minimum), high: finite(statistic.maximum)) : nil
                }
            }
            if let value { byDay[day] = value }
        }
        return byDay.values.sorted { $0.localDay < $1.localDay }
    }
}

/// Turns Apple Health sleep samples into one main sleep per wake day.
public enum HealthSleepAggregation {
    public struct Night: Equatable, Sendable {
        public let wakeDay: String
        public let asleepMinutes: Double
        /// Nil when no source recorded stages for the night. Zero is real
        /// only when stages were recorded and none of them was deep.
        public let deepMinutes: Double?
        public let remMinutes: Double?
        /// Nil when nothing recorded time in bed or awake, since the time in
        /// bed is then unknown.
        public let efficiencyPercent: Double?
    }

    /// Samples closer together than this belong to the same sleep.
    public static let sessionGapSeconds: TimeInterval = 60 * 60

    public static func nights(_ samples: [HealthSleepSample], calendar: Calendar) -> [Night] {
        let valid = samples.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        var sessions: [[HealthSleepSample]] = []
        var sessionEnd = Date.distantPast
        for sample in valid {
            if var last = sessions.last, sample.start <= sessionEnd.addingTimeInterval(sessionGapSeconds) {
                last.append(sample)
                sessions[sessions.count - 1] = last
                sessionEnd = max(sessionEnd, sample.end)
            } else {
                sessions.append([sample])
                sessionEnd = sample.end
            }
        }
        var best: [String: Night] = [:]
        for session in sessions {
            let asleep = union(session.filter { $0.stage.isAsleep })
            guard asleep > 0 else { continue }
            let hasStages = session.contains { $0.stage.isStage }
            let deep = hasStages ? union(session.filter { $0.stage == .asleepDeep }) : nil
            let rem = hasStages ? union(session.filter { $0.stage == .asleepREM }) : nil
            let knowsTimeInBed = session.contains { $0.stage == .inBed || $0.stage == .awake }
            let inBed = knowsTimeInBed ? union(session) : nil
            let efficiency = inBed.flatMap { $0 > 0 ? min(100, asleep / $0 * 100) : nil }
            let end = session.filter { $0.stage.isAsleep }.map(\.end).max() ?? session.map(\.end).max()!
            let night = Night(wakeDay: HealthHistoryDay.localDay(for: end, calendar: calendar),
                              asleepMinutes: asleep / 60, deepMinutes: deep.map { $0 / 60 },
                              remMinutes: rem.map { $0 / 60 }, efficiencyPercent: efficiency)
            if let current = best[night.wakeDay], current.asleepMinutes >= night.asleepMinutes { continue }
            best[night.wakeDay] = night
        }
        return best.values.sorted { $0.wakeDay < $1.wakeDay }
    }

    public static func values(_ nights: [Night]) -> [HealthHistoryDayValue] {
        nights.flatMap { night -> [HealthHistoryDayValue] in
            var values = [HealthHistoryDayValue(metric: .sleepDuration, localDay: night.wakeDay, value: night.asleepMinutes)]
            if let deep = night.deepMinutes { values.append(.init(metric: .deepSleep, localDay: night.wakeDay, value: deep)) }
            if let rem = night.remMinutes { values.append(.init(metric: .remSleep, localDay: night.wakeDay, value: rem)) }
            if let efficiency = night.efficiencyPercent {
                values.append(.init(metric: .sleepEfficiency, localDay: night.wakeDay, value: efficiency))
            }
            return values
        }
    }

    /// Seconds covered by the union of the samples' intervals, so two sources
    /// recording the same night are not counted twice.
    static func union(_ samples: [HealthSleepSample]) -> TimeInterval {
        let intervals = samples.map { ($0.start, $0.end) }.sorted { $0.0 < $1.0 }
        var total: TimeInterval = 0
        var current: (Date, Date)?
        for interval in intervals {
            if let open = current, interval.0 <= open.1 {
                current = (open.0, max(open.1, interval.1))
            } else {
                if let open = current { total += open.1.timeIntervalSince(open.0) }
                current = interval
            }
        }
        if let open = current { total += open.1.timeIntervalSince(open.0) }
        return total
    }
}

/// Imports up to a year of daily Apple Health values, then only the recent
/// days on later runs.
///
/// Each quantity keeps its own cursor: the time of its last finished import.
/// A later run re-reads from a few days before that, because today's totals
/// were still growing and a source may have added or deleted recent samples.
/// Every re-read day is replaced, so a sample deleted in Apple Health also
/// disappears from Loopr.
public actor HealthHistoryImporter {
    public static let maximumDays = 365
    public static let overlapDays = 3
    public static let cursorPrefix = "apple_health.daily."

    private let client: any HealthHistoryQueryClient
    private let store: any HealthHistoryImportStore
    private let calendar: Calendar
    private let excludedBundlePrefixes: [String]
    private let mayImport: @Sendable () -> Bool
    private let mayRead: @Sendable (HealthHistoryQuantity?) -> Bool
    private var running = false
    private var stopped = false

    public init(client: any HealthHistoryQueryClient, store: any HealthHistoryImportStore,
                calendar: Calendar, excludedBundlePrefixes: [String],
                mayImport: @escaping @Sendable () -> Bool = { true },
                mayRead: @escaping @Sendable (HealthHistoryQuantity?) -> Bool = { _ in true }) {
        self.client = client
        self.store = store
        self.calendar = calendar
        self.excludedBundlePrefixes = excludedBundlePrefixes.filter { !$0.isEmpty }
        self.mayImport = mayImport
        self.mayRead = mayRead
    }

    public func stop() { stopped = true }

    /// Returns nil when another import is already running.
    @discardableResult
    public func importHistory(now: Date) async -> HealthHistoryImportReport? {
        guard !running, !stopped else { return nil }
        running = true
        defer { running = false }
        var report = HealthHistoryImportReport()
        let enabledQuantities = Set(HealthHistoryQuantity.allCases.filter { mayRead($0) })
        let sleepEnabled = mayRead(nil)
        guard mayImport(), (!enabledQuantities.isEmpty || sleepEnabled),
              await client.historyReadAccessRequested(reading: enabledQuantities, readSleep: sleepEnabled) else {
            report.skippedForAccess = true
            return report
        }
        let today = calendar.startOfDay(for: now)
        guard let earliest = calendar.date(byAdding: .day, value: -(Self.maximumDays - 1), to: today) else { return report }
        let upperDay = HealthHistoryDay.localDay(for: today, calendar: calendar)

        for quantity in HealthHistoryQuantity.allCases {
            guard !stopped, !Task.isCancelled else { return report }
            guard mayImport(), mayRead(quantity) else { continue }
            let key = Self.cursorPrefix + quantity.rawValue
            do {
                let start = try windowStart(cursorKey: key, earliest: earliest)
                guard mayImport(), mayRead(quantity) else { continue }
                let statistics = try await client.dailyStatistics(for: quantity, from: start, to: now,
                    calendar: calendar, excludingBundlePrefixes: excludedBundlePrefixes)
                guard mayImport(), mayRead(quantity) else { continue }
                let values = HealthHistoryMapping.values(for: quantity, statistics: statistics, calendar: calendar)
                    .filter { $0.localDay <= upperDay }
                guard !stopped else { return report }
                let metric = HealthHistoryMapping.metric(for: quantity)
                try store.replaceDailyValues(metric, from: HealthHistoryDay.localDay(for: start, calendar: calendar),
                                             through: upperDay, values: values)
                try store.setImportCursor(now, for: key)
                report.importedDays[metric] = values.count
            } catch {
                report.failures[quantity.rawValue] = String(describing: error)
            }
        }

        guard !stopped, !Task.isCancelled else { return report }
        guard mayImport(), mayRead(nil) else { return report }
        let sleepKey = Self.cursorPrefix + "sleep"
        do {
            let start = try windowStart(cursorKey: sleepKey, earliest: earliest)
            // A night that ends on the first day of the window started the
            // evening before it.
            let queryStart = calendar.date(byAdding: .hour, value: -18, to: start) ?? start
            guard mayImport(), mayRead(nil) else { return report }
            let samples = try await client.sleepSamples(from: queryStart, to: now,
                                                        excludingBundlePrefixes: excludedBundlePrefixes)
                .filter { sample in !isExcluded(sample.sourceBundleIdentifier) }
            guard mayImport(), mayRead(nil) else { return report }
            let lowerDay = HealthHistoryDay.localDay(for: start, calendar: calendar)
            let values = HealthSleepAggregation.values(HealthSleepAggregation.nights(samples, calendar: calendar))
                .filter { $0.localDay >= lowerDay && $0.localDay <= upperDay }
            guard !stopped else { return report }
            for metric in HealthHistoryMetric.sleepMetrics {
                let metricValues = values.filter { $0.metric == metric }
                try store.replaceDailyValues(metric, from: lowerDay, through: upperDay, values: metricValues)
                report.importedDays[metric] = metricValues.count
            }
            try store.setImportCursor(now, for: sleepKey)
        } catch {
            report.failures["sleep"] = String(describing: error)
        }
        return report
    }

    private func windowStart(cursorKey: String, earliest: Date) throws -> Date {
        guard let cursor = try store.importCursor(for: cursorKey),
              let resumed = calendar.date(byAdding: .day, value: -Self.overlapDays, to: calendar.startOfDay(for: cursor)) else {
            return earliest
        }
        return max(earliest, resumed)
    }

    private func isExcluded(_ bundleIdentifier: String?) -> Bool {
        HealthHistorySourceFilter.isExcluded(bundleIdentifier, prefixes: excludedBundlePrefixes)
    }
}

public enum HealthHistorySourceFilter {
    /// True for a source Loopr itself wrote through, such as the app or its
    /// Watch app. Sources without a bundle identifier are kept.
    public static func isExcluded(_ bundleIdentifier: String?, prefixes: [String]) -> Bool {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return false }
        return prefixes.contains { !$0.isEmpty && (bundleIdentifier == $0 || bundleIdentifier.hasPrefix($0 + ".")) }
    }
}
