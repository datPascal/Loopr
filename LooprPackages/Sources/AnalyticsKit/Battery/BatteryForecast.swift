import Foundation
import DomainKit

/// A seconds-only duration value that keeps the package's documented macOS
/// 10.15 host-build compatibility. Swift's standard-library `Duration` is
/// unavailable before macOS 13, while the pinned Edge battery algorithm only
/// needs whole seconds.
public struct BatteryDuration: Codable, Equatable, Comparable, Sendable {
    public struct Components: Equatable, Sendable {
        public let seconds: Int64
    }

    public let seconds: Int64

    public init(seconds: Int64) {
        self.seconds = seconds
    }

    public static let zero = BatteryDuration(seconds: 0)
    public static func seconds(_ value: Int64) -> BatteryDuration {
        BatteryDuration(seconds: value)
    }

    public var components: Components { Components(seconds: seconds) }

    public static func < (lhs: BatteryDuration, rhs: BatteryDuration) -> Bool {
        lhs.seconds < rhs.seconds
    }
}

public struct BatterySample: Codable, Equatable, Sendable {
    public let tsSec: Int
    public let pct: Double
    public let charging: Bool?

    public init(tsSec: Int, pct: Double, charging: Bool?) {
        self.tsSec = tsSec
        self.pct = pct
        self.charging = charging
    }
}

public enum ForecastNote {
    public static let charging = "charging"
    public static let chargingUnknown = "charging_unknown"
    public static let notDraining = "not_draining"
    public static let rateImplausible = "rate_implausible"

    public static func needHistory(_ have: Int, _ need: Int) -> String {
        "need_history:have=\(have),need=\(need)"
    }

    public static func needHistory(have: Int, need: Int) -> String {
        needHistory(have, need)
    }

    public static func needSpan(_ have: BatteryDuration, _ need: BatteryDuration) -> String {
        "need_span:have=\(have.components.seconds / 60)m,need=\(need.components.seconds / 60)m"
    }

    public static func needSpan(have: BatteryDuration, need: BatteryDuration) -> String {
        needSpan(have, need)
    }
}

public struct BatteryForecast: Codable, Equatable, Sendable {
    public let samplesUsed: Int
    public let spanUsed: BatteryDuration
    public let drainPctPerHour: Double?
    public let currentPct: Double?
    public let predictedPctAtWake: Double?
    public let predictedEmptyAt: Date?
    public let note: String?
    public let algorithmVersion: Int

    public init(
        samplesUsed: Int,
        spanUsed: BatteryDuration,
        drainPctPerHour: Double? = nil,
        currentPct: Double? = nil,
        predictedPctAtWake: Double? = nil,
        predictedEmptyAt: Date? = nil,
        note: String? = nil,
        algorithmVersion: Int = 1
    ) {
        self.samplesUsed = samplesUsed
        self.spanUsed = spanUsed
        self.drainPctPerHour = drainPctPerHour
        self.currentPct = currentPct
        self.predictedPctAtWake = predictedPctAtWake
        self.predictedEmptyAt = predictedEmptyAt
        self.note = note
        self.algorithmVersion = algorithmVersion
    }

    public static func abstain(
        reason: String,
        samplesUsed: Int = 0,
        spanUsed: BatteryDuration = .zero,
        algorithmVersion: Int = 1
    ) -> BatteryForecast {
        BatteryForecast(
            samplesUsed: samplesUsed,
            spanUsed: spanUsed,
            note: reason,
            algorithmVersion: algorithmVersion
        )
    }

    public var isUsable: Bool { drainPctPerHour != nil }

    private enum CodingKeys: String, CodingKey {
        case samplesUsed, spanUsedSeconds, drainPctPerHour, currentPct
        case predictedPctAtWake, predictedEmptyAt, note, algorithmVersion
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(samplesUsed, forKey: .samplesUsed)
        try container.encode(spanUsed.components.seconds, forKey: .spanUsedSeconds)
        try container.encodeIfPresent(drainPctPerHour, forKey: .drainPctPerHour)
        try container.encodeIfPresent(currentPct, forKey: .currentPct)
        try container.encodeIfPresent(predictedPctAtWake, forKey: .predictedPctAtWake)
        try container.encodeIfPresent(predictedEmptyAt, forKey: .predictedEmptyAt)
        try container.encodeIfPresent(note, forKey: .note)
        try container.encode(algorithmVersion, forKey: .algorithmVersion)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.samplesUsed = try container.decode(Int.self, forKey: .samplesUsed)
        self.spanUsed = .seconds(try container.decode(Int64.self, forKey: .spanUsedSeconds))
        self.drainPctPerHour = try container.decodeIfPresent(Double.self, forKey: .drainPctPerHour)
        self.currentPct = try container.decodeIfPresent(Double.self, forKey: .currentPct)
        self.predictedPctAtWake = try container.decodeIfPresent(Double.self, forKey: .predictedPctAtWake)
        self.predictedEmptyAt = try container.decodeIfPresent(Date.self, forKey: .predictedEmptyAt)
        self.note = try container.decodeIfPresent(String.self, forKey: .note)
        self.algorithmVersion = try container.decodeIfPresent(Int.self, forKey: .algorithmVersion) ?? 1
    }
}

/// Pure, I/O-free battery projection. The caller supplies `now`, so the
/// forecast is deterministic and does not secretly read a clock or database.
public struct BatteryForecaster: Sendable {
    public let minSamples: Int
    public let minSpan: BatteryDuration
    public let maxSampleAge: BatteryDuration
    public let maxPlausibleDrainPctPerHour: Double
    public let reservePct: Double
    public let algorithmVersion: Int

    public init(
        minSamples: Int = 4,
        minSpan: BatteryDuration = .seconds(2 * 60 * 60),
        maxSampleAge: BatteryDuration = .seconds(48 * 60 * 60),
        maxPlausibleDrainPctPerHour: Double = 25.0,
        reservePct: Double = 5.0,
        algorithmVersion: Int = 1
    ) {
        self.minSamples = minSamples
        self.minSpan = minSpan
        self.maxSampleAge = maxSampleAge
        self.maxPlausibleDrainPctPerHour = maxPlausibleDrainPctPerHour
        self.reservePct = reservePct
        self.algorithmVersion = algorithmVersion
    }

    public func forecast(
        samples: [BatterySample],
        now: Date,
        wakeAt: Date
    ) -> BatteryForecast {
        guard !samples.isEmpty else {
            return .abstain(reason: ForecastNote.needHistory(0, minSamples), algorithmVersion: algorithmVersion)
        }

        let nowSec = Int(now.timeIntervalSince1970.rounded(.down))
        let oldestAllowed = nowSec - Int(maxSampleAge.components.seconds)
        let fresh = samples
            .filter { $0.tsSec >= oldestAllowed && $0.tsSec <= nowSec }
            .sorted { $0.tsSec > $1.tsSec }

        guard !fresh.isEmpty else {
            return .abstain(reason: ForecastNote.needHistory(0, minSamples), algorithmVersion: algorithmVersion)
        }
        if fresh[0].charging == true {
            return .abstain(reason: ForecastNote.charging, algorithmVersion: algorithmVersion)
        }

        guard fresh[0].charging == false else {
            return .abstain(reason: ForecastNote.chargingUnknown, algorithmVersion: algorithmVersion)
        }
        var run: [BatterySample] = [fresh[0]]
        if fresh.count > 1 {
            for sample in fresh.dropFirst() {
                if sample.charging != false { break }
                if sample.pct < medianOfTail(run) - 1.0 { break }
                run.append(sample)
            }
        }

        guard run.count >= minSamples else {
            return .abstain(
                reason: ForecastNote.needHistory(run.count, minSamples),
                samplesUsed: run.count,
                algorithmVersion: algorithmVersion
            )
        }
        let spanSeconds = run[0].tsSec - run[run.count - 1].tsSec
        let span = BatteryDuration.seconds(Int64(max(0, spanSeconds)))
        guard span >= minSpan else {
            return .abstain(
                reason: ForecastNote.needSpan(span, minSpan),
                samplesUsed: run.count,
                spanUsed: span,
                algorithmVersion: algorithmVersion
            )
        }

        guard let rate = theilSenDrainPctPerHour(run), rate > 0 else {
            return .abstain(
                reason: ForecastNote.notDraining,
                samplesUsed: run.count,
                spanUsed: span,
                algorithmVersion: algorithmVersion
            )
        }
        guard rate <= maxPlausibleDrainPctPerHour else {
            return .abstain(
                reason: ForecastNote.rateImplausible,
                samplesUsed: run.count,
                spanUsed: span,
                algorithmVersion: algorithmVersion
            )
        }

        let currentPct = run[0].pct
        // Dart's Duration.inSeconds truncates toward zero. Int() preserves that
        // behavior for the (normally positive) wake interval.
        let secondsToWake = Int(wakeAt.timeIntervalSince(now))
        let hoursToWake = Double(secondsToWake) / 3600.0
        let predicted = currentPct - rate * hoursToWake
        let hoursToEmpty = currentPct / rate
        let empty = now.addingTimeInterval((hoursToEmpty * 3600).rounded())
        return BatteryForecast(
            samplesUsed: run.count,
            spanUsed: span,
            drainPctPerHour: rate,
            currentPct: currentPct,
            predictedPctAtWake: predicted,
            predictedEmptyAt: empty,
            algorithmVersion: algorithmVersion
        )
    }

    public func willNotSurvive(_ forecast: BatteryForecast) -> Bool {
        guard let predicted = forecast.predictedPctAtWake else { return false }
        return predicted <= reservePct
    }

    public static func nextWakeTime(
        _ now: Date,
        _ wakeMinuteOfDay: Int,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Date {
        let cal = calendar
        let h = wakeMinuteOfDay / 60
        let m = wakeMinuteOfDay % 60
        let base = cal.dateComponents([.era, .year, .month, .day], from: now)
        var today = base
        today.hour = h
        today.minute = m
        today.second = 0
        let candidate = cal.date(from: today) ?? now
        if candidate > now { return candidate }
        // Increment the civil day component and let Calendar normalize month
        // and year overflow. This preserves the wall-clock wake time across
        // DST transitions instead of adding 24 elapsed hours.
        var tomorrow = base
        tomorrow.day = (base.day ?? 0) + 1
        tomorrow.hour = h
        tomorrow.minute = m
        tomorrow.second = 0
        return cal.date(from: tomorrow) ?? candidate
    }

    public static func nextWakeTime(
        now: Date,
        wakeMinuteOfDay: Int,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Date {
        nextWakeTime(now, wakeMinuteOfDay, calendar: calendar)
    }

    public static func inEveningWindow(
        _ nowMinuteOfDay: Int,
        _ bedtimeMinuteOfDay: Int,
        leadMinutes: Int = 240
    ) -> Bool {
        let day = 1440
        let start = positiveModulo(bedtimeMinuteOfDay - leadMinutes, day)
        let end = positiveModulo(bedtimeMinuteOfDay, day)
        if start == end { return true }
        return start < end
            ? (nowMinuteOfDay >= start && nowMinuteOfDay < end)
            : (nowMinuteOfDay >= start || nowMinuteOfDay < end)
    }

    public static func inEveningWindow(
        nowMinuteOfDay: Int,
        bedtimeMinuteOfDay: Int,
        leadMinutes: Int = 240
    ) -> Bool {
        inEveningWindow(nowMinuteOfDay, bedtimeMinuteOfDay, leadMinutes: leadMinutes)
    }

    public static func describe(_ forecast: BatteryForecast, wakeAt: Date) -> String {
        guard let rate = forecast.drainPctPerHour,
              let pct = forecast.currentPct,
              let empty = forecast.predictedEmptyAt else { return "" }
        let h = String(format: "%02d", emptyHour(empty))
        let m = String(format: "%02d", emptyMinute(empty))
        let rateText = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), rate)
        let head = "At \(rateText)%/h it runs out around \(h):\(m)"
        _ = pct // Keep the field requirement explicit; text is rate/time only.
        return empty < wakeAt
            ? "\(head) — before you wake. Charge it now to keep tonight's sleep."
            : "\(head), after your usual wake time."
    }

    public static func hoursRemaining(_ forecast: BatteryForecast, now: Date) -> Int? {
        guard let empty = forecast.predictedEmptyAt else { return nil }
        let minutes = max(0, Int(empty.timeIntervalSince(now) / 60))
        return minutes / 60
    }

    private func medianOfTail(_ run: [BatterySample]) -> Double {
        let values = run.suffix(3).map(\.pct).sorted()
        let middle = values.count / 2
        guard !values.isEmpty else { return 0 }
        return values.count.isMultiple(of: 2)
            ? (values[middle - 1] + values[middle]) / 2
            : values[middle]
    }

    private func theilSenDrainPctPerHour(_ run: [BatterySample]) -> Double? {
        var slopes: [Double] = []
        for i in run.indices {
            for j in run.indices where j > i {
                let dtHours = Double(run[i].tsSec - run[j].tsSec) / 3600
                if abs(dtHours) < 0.25 { continue }
                slopes.append((run[j].pct - run[i].pct) / dtHours)
            }
        }
        guard !slopes.isEmpty else { return nil }
        slopes.sort()
        let middle = slopes.count / 2
        return slopes.count.isMultiple(of: 2)
            ? (slopes[middle - 1] + slopes[middle]) / 2
            : slopes[middle]
    }

    private static func positiveModulo(_ value: Int, _ modulus: Int) -> Int {
        let result = value % modulus
        return result >= 0 ? result : result + modulus
    }

    private static func emptyHour(_ date: Date) -> Int {
        Calendar.autoupdatingCurrent.component(.hour, from: date)
    }

    private static func emptyMinute(_ date: Date) -> Int {
        Calendar.autoupdatingCurrent.component(.minute, from: date)
    }
}

public protocol BatterySampleRepository: Sendable {
    func samples(through now: Date) async throws -> [BatterySample]
}

public protocol BatteryForecastRepository: CanonicalBatteryForecastRepository where Value == BatteryForecast {
    func forecast(now: Date, wakeAt: Date) async throws -> BatteryForecast
}

/// Canonical read path for the user-facing forecast. It performs the storage
/// read outside the pure forecaster and checks cancellation at both boundaries.
public actor BatteryObservationService: BatteryForecastRepository {
    public typealias Value = BatteryForecast
    private let sampleRepository: any BatterySampleRepository
    private let forecaster: BatteryForecaster
    private var latestForecast: BatteryForecast?

    public init(
        sampleRepository: any BatterySampleRepository,
        forecaster: BatteryForecaster = BatteryForecaster()
    ) {
        self.sampleRepository = sampleRepository
        self.forecaster = forecaster
    }

    public func forecast(now: Date, wakeAt: Date) async throws -> BatteryForecast {
        try Task.checkCancellation()
        let samples = try await sampleRepository.samples(through: now)
        try Task.checkCancellation()
        let result = forecaster.forecast(samples: samples, now: now, wakeAt: wakeAt)
        latestForecast = result
        return result
    }

    public func readLatestBatteryForecast() async throws -> BatteryForecast? { latestForecast }
}

public actor InMemoryBatterySampleRepository: BatterySampleRepository {
    private var values: [BatterySample]

    public init(samples: [BatterySample] = []) { self.values = samples }

    public func samples(through now: Date) -> [BatterySample] {
        let second = Int(now.timeIntervalSince1970.rounded(.down))
        return values.filter { $0.tsSec <= second }
    }

    public func replace(_ samples: [BatterySample]) { values = samples }
}
