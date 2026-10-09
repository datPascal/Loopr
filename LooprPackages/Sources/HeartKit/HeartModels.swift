import Foundation
import DomainKit
import DesignSystem
import BluetoothKit

public enum HeartMetricID: String, Codable, CaseIterable, Hashable, Sendable {
    case restingHeartRate
    case rmssd
    case sdnn
    case pNN50
    case frequencyDomain
    case respiration
    case heartRateDip
    case sleepingHeartRate
    case maxHeartRate
    case quality

    public var title: String {
        switch self {
        case .restingHeartRate: "Resting heart rate"
        case .rmssd: "HRV"
        case .sdnn: "SDNN"
        case .pNN50: "pNN50"
        case .frequencyDomain: "Frequency-domain HRV"
        case .respiration: "Respiratory rate"
        case .heartRateDip: "Heart rate dip"
        case .sleepingHeartRate: "Sleeping heart rate"
        case .maxHeartRate: "Max heart rate"
        case .quality: "Signal quality"
        }
    }
}

public struct HeartMetricValue: Codable, Equatable, Sendable, Identifiable {
    public let id: HeartMetricID
    public let title: String
    public let value: String?
    public let unit: String
    public let numericValue: Double?
    public let numericUnit: HeartMetricUnitID?
    public let state: MetricState
    public let confidence: String?
    public let trend: String?
    public let qualityDetail: String?
    public let source: String
    public let algorithmVersion: String?

    public init(id: HeartMetricID, title: String, value: String?, unit: String, state: MetricState, confidence: String? = nil, trend: String? = nil, qualityDetail: String? = nil, source: String, algorithmVersion: String? = nil, numericValue: Double? = nil, numericUnit: HeartMetricUnitID? = nil) {
        self.id = id
        self.title = title
        self.value = value
        self.unit = unit
        self.numericValue = numericValue?.isFinite == true ? numericValue : nil
        self.numericUnit = numericUnit
        self.state = state
        self.confidence = confidence
        self.trend = trend
        self.qualityDetail = qualityDetail
        self.source = source
        self.algorithmVersion = algorithmVersion
    }

    private enum CodingKeys: String, CodingKey { case id, title, value, unit, numericValue, numericUnit, state, confidence, trend, qualityDetail, source, algorithmVersion }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(HeartMetricID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        value = try container.decodeIfPresent(String.self, forKey: .value)
        unit = try container.decode(String.self, forKey: .unit)
        let decodedNumeric = try container.decodeIfPresent(Double.self, forKey: .numericValue)
        numericValue = decodedNumeric?.isFinite == true ? decodedNumeric : nil
        numericUnit = try container.decodeIfPresent(HeartMetricUnitID.self, forKey: .numericUnit)
        state = try container.decode(MetricState.self, forKey: .state)
        confidence = try container.decodeIfPresent(String.self, forKey: .confidence)
        trend = try container.decodeIfPresent(String.self, forKey: .trend)
        qualityDetail = try container.decodeIfPresent(String.self, forKey: .qualityDetail)
        source = try container.decode(String.self, forKey: .source)
        algorithmVersion = try container.decodeIfPresent(String.self, forKey: .algorithmVersion)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(value, forKey: .value)
        try container.encode(unit, forKey: .unit)
        try container.encodeIfPresent(numericValue, forKey: .numericValue)
        try container.encodeIfPresent(numericUnit, forKey: .numericUnit)
        try container.encode(state, forKey: .state)
        try container.encodeIfPresent(confidence, forKey: .confidence)
        try container.encodeIfPresent(trend, forKey: .trend)
        try container.encodeIfPresent(qualityDetail, forKey: .qualityDetail)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(algorithmVersion, forKey: .algorithmVersion)
    }

    public var accessibilitySummary: String {
        guard let value else { return "\(title). \(state.title). \(state.detail)" }
        return [title, value, unit, confidence, trend, qualityDetail, state == .measuredZero ? state.title : nil].compactMap { $0 }.joined(separator: ", ")
    }
}

public enum HeartMetricUnitID: String, Codable, Sendable {
    case milliseconds
    case beatsPerMinute
    case percentagePoints
    case breathsPerMinute
    case unknown
}

public enum HeartTrendRange: String, CaseIterable, Hashable, Sendable {
    case week
    case month

    public var title: String {
        switch self {
        case .week: "Week"
        case .month: "Month"
        }
    }

    fileprivate var dayCount: Int {
        switch self {
        case .week: 7
        case .month: 31
        }
    }
}

/// Cross-day values are already derived by ANA-02. HeartKit only presents
/// the canonical local-day labels and never calculates a trend itself.
public struct HeartTrendPoint: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let metric: HeartMetricID
    public let localDay: String
    public let value: String?
    public let unit: String
    public let state: MetricState
    public let source: String
    public let algorithmVersion: String?

    public init(id: String, metric: HeartMetricID, localDay: String, value: String?, unit: String, state: MetricState, source: String, algorithmVersion: String? = nil) {
        self.id = id
        self.metric = metric
        self.localDay = localDay
        self.value = value
        self.unit = unit
        self.state = state
        self.source = source
        self.algorithmVersion = algorithmVersion
    }
}

public enum HeartTrendFilter {
    public static func points(_ points: [HeartTrendPoint], range: HeartTrendRange) -> [HeartTrendPoint] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parsed = points.compactMap { point -> (HeartTrendPoint, Date)? in
            guard let date = localDayDate(point.localDay, calendar: calendar) else { return nil }
            return (point, date)
        }
        guard let latest = parsed.map(\.1).max(),
              let earliest = calendar.date(byAdding: .day, value: -(range.dayCount - 1), to: latest)
        else { return [] }
        return parsed
            .filter { $0.1 >= earliest && $0.1 <= latest }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                return lhs.0.id < rhs.0.id
            }
            .map(\.0)
    }

    private static func localDayDate(_ value: String, calendar: Calendar) -> Date? {
        let components = value.split(separator: "-").compactMap { Int($0) }
        guard components.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: components[0], month: components[1], day: components[2]))
    }
}

public struct HeartDaySnapshot: Codable, Equatable, Sendable {
    public let day: DayIdentity
    public let state: MetricState
    public let metrics: [HeartMetricValue]
    public let liveState: MetricState
    public let source: String
    public let algorithmVersion: String?
    public let trend: [HeartTrendPoint]
    /// Overnight skin temperature, oxygen and beat-to-beat data. Nil for
    /// fixtures and for generations saved before vitals existed.
    public let vitals: HeartVitalsSnapshot?

    public init(day: DayIdentity, state: MetricState, metrics: [HeartMetricValue], liveState: MetricState = .absent, source: String, algorithmVersion: String? = nil, trend: [HeartTrendPoint] = [], vitals: HeartVitalsSnapshot? = nil) {
        self.day = day
        self.state = state
        self.metrics = metrics
        self.liveState = liveState
        self.source = source
        self.algorithmVersion = algorithmVersion
        self.trend = trend
        self.vitals = vitals
    }

    private enum CodingKeys: String, CodingKey {
        case day, state, metrics, liveState, source, algorithmVersion, trend, vitals
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        day = try container.decode(DayIdentity.self, forKey: .day)
        state = try container.decode(MetricState.self, forKey: .state)
        metrics = try container.decode([HeartMetricValue].self, forKey: .metrics)
        liveState = try container.decode(MetricState.self, forKey: .liveState)
        source = try container.decode(String.self, forKey: .source)
        algorithmVersion = try container.decodeIfPresent(String.self, forKey: .algorithmVersion)
        trend = try container.decodeIfPresent([HeartTrendPoint].self, forKey: .trend) ?? []
        vitals = try container.decodeIfPresent(HeartVitalsSnapshot.self, forKey: .vitals)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(day, forKey: .day)
        try container.encode(state, forKey: .state)
        try container.encode(metrics, forKey: .metrics)
        try container.encode(liveState, forKey: .liveState)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(algorithmVersion, forKey: .algorithmVersion)
        try container.encode(trend, forKey: .trend)
        try container.encodeIfPresent(vitals, forKey: .vitals)
    }

    public func metric(_ id: HeartMetricID) -> HeartMetricValue? { metrics.first { $0.id == id } }
}

public protocol HeartRepository: Sendable {
    func readHeartDay(for day: DayIdentity) async throws -> HeartDaySnapshot?
}

public enum HeartSpotCheckAvailability: String, Codable, Equatable, Sendable {
    case complete
    case insufficientQuality
    case unavailable
}

public struct HeartSpotCheckResult: Codable, Equatable, Sendable {
    public let state: MetricState
    public let heartRateBPM: Double?
    public let rmssdMilliseconds: Double?
    public let sdnnMilliseconds: Double?
    public let durationSeconds: Int
    public let qualityDetail: String?
    public let source: String
    /// Optional fields were added after the original spot-check row shape so
    /// existing local records remain decodable.  A missing value is not
    /// promoted to a neutral quality score.
    public let availability: HeartSpotCheckAvailability?
    public let rrSampleCount: Int?
    public let normalRRCount: Int?
    public let cleanFraction: Double?
    public let rejectedSampleCount: Int?
    public let algorithmVersions: [String]?
    public let provenance: String?
    public let startedAt: Date?
    public let endedAt: Date?

    public init(
        state: MetricState,
        heartRateBPM: Double?,
        rmssdMilliseconds: Double?,
        sdnnMilliseconds: Double?,
        durationSeconds: Int,
        qualityDetail: String? = nil,
        source: String,
        availability: HeartSpotCheckAvailability? = nil,
        rrSampleCount: Int? = nil,
        normalRRCount: Int? = nil,
        cleanFraction: Double? = nil,
        rejectedSampleCount: Int? = nil,
        algorithmVersions: [String]? = nil,
        provenance: String? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil
    ) {
        self.state = state
        self.heartRateBPM = heartRateBPM
        self.rmssdMilliseconds = rmssdMilliseconds
        self.sdnnMilliseconds = sdnnMilliseconds
        self.durationSeconds = durationSeconds
        self.qualityDetail = qualityDetail
        self.source = source
        self.availability = availability
        self.rrSampleCount = rrSampleCount
        self.normalRRCount = normalRRCount
        self.cleanFraction = cleanFraction
        self.rejectedSampleCount = rejectedSampleCount
        self.algorithmVersions = algorithmVersions
        self.provenance = provenance
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    public var resolvedAvailability: HeartSpotCheckAvailability {
        availability ?? (rmssdMilliseconds != nil ? .complete : .unavailable)
    }
}

public protocol HeartSpotCheckRepository: Sendable {
    func runSpotCheck() async throws -> HeartSpotCheckResult
    func saveSpotCheck(_ result: HeartSpotCheckResult) async throws
}

/// A live runner owns measurement and canonical persistence. It is separate
/// from `HeartSpotCheckRepository` so a service-backed run cannot be mistaken
/// for a repository read or silently fall back to an old stored result.
public protocol HeartSpotCheckRunner: Sendable {
    func runSpotCheck() async throws -> HeartSpotCheckResult
}

/// A package-neutral release-once lease.  The production adapter wraps the
/// BLE-07 `LiveStreamConsumerHandle`; tests can use the public initializer.
public final class HeartLiveConsumerLease: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private let releaseAction: @Sendable () async -> Void

    public init(releaseAction: @escaping @Sendable () async -> Void) { self.releaseAction = releaseAction }

    @discardableResult
    public func release() async -> Bool {
        let shouldRelease = lock.withLock {
            guard !released else { return false }
            released = true
            return true
        }
        guard shouldRelease else { return false }
        await releaseAction()
        return true
    }

    public var isReleased: Bool { lock.withLock { released } }
}

public struct HeartLiveSample: Codable, Equatable, Sendable {
    public let kind: LiveStreamKind
    public let heartRateBPM: Double?
    public let rrMilliseconds: Double?
    public let receivedAt: Date
    /// Raw bytes remain opaque until the canonical live-packet decoder is
    /// available. Keeping them here prevents an adapter from guessing a
    /// heart-rate value or silently dropping a valid shared-stream sample.
    public let rawPayload: Data?

    public init(kind: LiveStreamKind, heartRateBPM: Double?, rrMilliseconds: Double?, receivedAt: Date, rawPayload: Data? = nil) {
        self.kind = kind
        self.heartRateBPM = heartRateBPM
        self.rrMilliseconds = rrMilliseconds
        self.receivedAt = receivedAt
        self.rawPayload = rawPayload.map { Data($0) }
    }
}

/// A fully decoded compact live event for Heart and other feature adapters.
/// The legacy `HeartLiveSample` keeps its single-RR compatibility shape; this
/// value preserves every verified RR slot and the connection generation.
public struct HeartLiveDecodedSample: Equatable, Sendable {
    public let kind: LiveStreamKind
    public let generation: UInt64
    public let deviceTimestampSeconds: UInt32
    public let heartRateBPM: Double
    public let rrIntervalsMilliseconds: [Double]
    public let wearing: Bool
    public let receivedAt: Date
    public let rawPayload: Data

    public init(
        kind: LiveStreamKind,
        generation: UInt64,
        deviceTimestampSeconds: UInt32,
        heartRateBPM: Double,
        rrIntervalsMilliseconds: [Double],
        wearing: Bool,
        receivedAt: Date,
        rawPayload: Data
    ) {
        self.kind = kind
        self.generation = generation
        self.deviceTimestampSeconds = deviceTimestampSeconds
        self.heartRateBPM = heartRateBPM
        self.rrIntervalsMilliseconds = rrIntervalsMilliseconds
        self.wearing = wearing
        self.receivedAt = receivedAt
        self.rawPayload = Data(rawPayload)
    }

    /// Compatibility projection for surfaces that still render one RR value.
    public var legacySample: HeartLiveSample {
        HeartLiveSample(
            kind: kind,
            heartRateBPM: heartRateBPM,
            rrMilliseconds: rrIntervalsMilliseconds.first,
            receivedAt: receivedAt,
            rawPayload: rawPayload
        )
    }
}

/// A generation-pinned decoded event subscription. The app adapter owns the
/// underlying SyncKit lease; HeartKit owns only the typed stream and its
/// release-once cancellation boundary.
public final class HeartLiveEventSubscription: @unchecked Sendable {
    public let generation: UInt64
    public let stream: AsyncStream<HeartLiveDecodedSample>

    private let lock = NSLock()
    private var cancelled = false
    private let cancelAction: @Sendable () async -> Bool

    public init(
        generation: UInt64,
        stream: AsyncStream<HeartLiveDecodedSample>,
        cancelAction: @escaping @Sendable () async -> Bool
    ) {
        self.generation = generation
        self.stream = stream
        self.cancelAction = cancelAction
    }

    @discardableResult
    public func cancel() async -> Bool {
        let shouldCancel = lock.withLock {
            guard !cancelled else { return false }
            cancelled = true
            return true
        }
        guard shouldCancel else { return false }
        return await cancelAction()
    }

    public var isCancelled: Bool { lock.withLock { cancelled } }
}

public enum HeartLiveEventMapper {
    /// Maps only verified, worn compact HR/RR events. Malformed and
    /// off-wrist packets remain absent rather than becoming zero-valued UI
    /// samples.
    public static func decode(_ event: LiveStreamEvent) -> HeartLiveDecodedSample? {
        guard let decoded = LiveStreamEventDecoder.decodeCardiac(event) else {
            return nil
        }
        let sample = decoded.sample
        return HeartLiveDecodedSample(
            kind: event.kind,
            generation: event.generation,
            deviceTimestampSeconds: sample.timestampSeconds,
            heartRateBPM: Double(sample.heartRateBPM),
            rrIntervalsMilliseconds: sample.rrMillisecondsAsDouble,
            wearing: sample.wearing,
            receivedAt: event.receivedAt,
            rawPayload: sample.rawPayload
        )
    }
}

public protocol HeartLiveStreamClient: Sendable {
    func acquire(kind: LiveStreamKind, consumer: LiveStreamConsumer) async throws -> HeartLiveConsumerLease
    func samples(for kind: LiveStreamKind) async -> [HeartLiveSample]
}

/// Typed live events are the production path. Implementations must preserve
/// the source generation and reject stale events before yielding them.
public protocol HeartLiveEventStreamClient: Sendable {
    func acquireEventStream(kind: LiveStreamKind, consumer: LiveStreamConsumer) async throws -> HeartLiveEventSubscription
}

public actor InMemoryHeartRepository: HeartRepository {
    private var values: [DayIdentity: HeartDaySnapshot]
    public init(values: [DayIdentity: HeartDaySnapshot] = [:]) { self.values = values }
    public func readHeartDay(for day: DayIdentity) async throws -> HeartDaySnapshot? { values[day] }
    public func replace(_ snapshot: HeartDaySnapshot, for day: DayIdentity) { values[day] = snapshot }
    public func deleteAll() { values.removeAll(keepingCapacity: true) }
}

public actor InMemoryHeartSpotCheckRepository: HeartSpotCheckRepository {
    private var result: HeartSpotCheckResult
    public init(result: HeartSpotCheckResult) { self.result = result }
    public func runSpotCheck() async throws -> HeartSpotCheckResult { result }
    public func saveSpotCheck(_ result: HeartSpotCheckResult) async throws { self.result = result }
    public func replace(_ result: HeartSpotCheckResult) { self.result = result }
}

public actor InMemoryHeartLiveStreamClient: HeartLiveStreamClient {
    private var values: [LiveStreamKind: [HeartLiveSample]]
    private var acquisitions: [(LiveStreamKind, LiveStreamConsumer)] = []
    private var releases = 0

    public init(values: [LiveStreamKind: [HeartLiveSample]] = [:]) { self.values = values }

    public func acquire(kind: LiveStreamKind, consumer: LiveStreamConsumer) async throws -> HeartLiveConsumerLease {
        acquisitions.append((kind, consumer))
        return HeartLiveConsumerLease { [weak self] in
            guard let self else { return }
            await self.recordRelease()
        }
    }

    public func samples(for kind: LiveStreamKind) async -> [HeartLiveSample] { values[kind] ?? [] }
    public func acquisitionsMade() -> [(LiveStreamKind, LiveStreamConsumer)] { acquisitions }
    public func releaseCount() -> Int { releases }
    private func recordRelease() { releases += 1 }
}
