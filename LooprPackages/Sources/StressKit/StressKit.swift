import Foundation
import BluetoothKit
import AnalyticsKit

public struct StressObservation: Codable, Equatable, Sendable {
    public let day: String
    public let value: Double
    public let coverage: Double
    public let confidence: Double
    public init(day: String, value: Double, coverage: Double, confidence: Double) { self.day = day; self.value = value; self.coverage = coverage; self.confidence = confidence }
}

public struct StressQualityGate: Sendable, Equatable {
    public let minimumCoverage: Double
    public let minimumConfidence: Double
    public init(minimumCoverage: Double = 0.50, minimumConfidence: Double = 0.40) { self.minimumCoverage = minimumCoverage; self.minimumConfidence = minimumConfidence }
    public func qualified(_ observation: StressObservation) -> Bool { observation.coverage >= minimumCoverage && observation.confidence >= minimumConfidence }
}

public struct StressDetail: Equatable, Sendable {
    public let value: Double?
    public let confidence: Double
    public let qualityMessage: String
    public init(observation: StressObservation?, gate: StressQualityGate = .init()) {
        guard let observation, gate.qualified(observation) else {
            value = nil; confidence = 0; qualityMessage = "Not enough signal coverage to show stress."; return
        }
        value = observation.value; confidence = observation.confidence; qualityMessage = "Quality-qualified estimate from local sensor data."
    }
}

/// Durable storage seam for stress observations and completed spot checks.
/// Live measurement remains an injected mechanism; this protocol only owns
/// canonical local records and never fabricates a value when hardware is
/// unavailable.
public protocol StressStore: Sendable {
    func hourlyStress() async throws -> HourlyStressDay?
    func latestObservation() async -> StressObservation?
    /// Same read as `latestObservation()`, but a storage failure throws instead
    /// of collapsing into "no data yet". Screens use it so a broken read shows
    /// an error rather than an empty day.
    func latestObservationChecked() async throws -> StressObservation?
    func saveObservation(_ observation: StressObservation) async throws
    func spotChecks() async -> [SpotCheckResult]
    func saveSpotCheck(_ result: SpotCheckResult) async throws
    func breathingHistory() async -> [BreathingResult]
    func saveBreathingResult(_ result: BreathingResult) async throws
    func deleteAll() async
}

extension StressStore {
    public func hourlyStress() async throws -> HourlyStressDay? { nil }
    public func latestObservationChecked() async throws -> StressObservation? {
        await latestObservation()
    }
}

public actor InMemoryStressStore: StressStore {
    private var observations: [String: StressObservation] = [:]
    private var results: [UUID: SpotCheckResult] = [:]
    private var breathingResults: [UUID: BreathingResult] = [:]

    public init(observations: [StressObservation] = [], spotChecks: [SpotCheckResult] = [], breathingHistory: [BreathingResult] = []) {
        for observation in observations { self.observations[observation.day] = observation }
        for result in spotChecks { self.results[result.id] = result }
        for result in breathingHistory { self.breathingResults[result.id] = result }
    }

    public func latestObservation() async -> StressObservation? {
        observations.values.sorted { $0.day > $1.day }.first
    }

    public func saveObservation(_ observation: StressObservation) async {
        observations[observation.day] = observation
    }

    public func spotChecks() async -> [SpotCheckResult] {
        results.values.sorted { ($0.startedAt, $0.id.uuidString) < ($1.startedAt, $1.id.uuidString) }
    }

    public func saveSpotCheck(_ result: SpotCheckResult) async {
        results[result.id] = result
    }

    public func breathingHistory() async -> [BreathingResult] {
        breathingResults.values.sorted { ($0.startedAt, $0.id.uuidString) < ($1.startedAt, $1.id.uuidString) }
    }

    public func saveBreathingResult(_ result: BreathingResult) async {
        breathingResults[result.id] = result
    }

    public func deleteAll() async {
        observations.removeAll(keepingCapacity: true)
        results.removeAll(keepingCapacity: true)
        breathingResults.removeAll(keepingCapacity: true)
    }
}

public struct LiveCardiacSample: Equatable, Sendable {
    public let timestamp: Date
    public let heartRate: Int?
    public let rrMilliseconds: [Double]
    public init(timestamp: Date, heartRate: Int? = nil, rrMilliseconds: [Double] = []) { self.timestamp = timestamp; self.heartRate = heartRate; self.rrMilliseconds = rrMilliseconds }
}

public enum StressLiveEventMapper {
    /// Converts the shared decoded compact HR/RR event into the StressKit
    /// consumer shape. It intentionally returns absence for malformed or
    /// off-wrist packets; RMSSD and quality are separate analytics concerns.
    public static func decode(_ event: LiveStreamEvent) -> LiveCardiacSample? {
        guard let decoded = LiveStreamEventDecoder.decodeCardiac(event) else {
            return nil
        }
        let sample = decoded.sample
        return LiveCardiacSample(
            timestamp: Date(timeIntervalSince1970: TimeInterval(sample.timestampSeconds)),
            heartRate: sample.heartRate,
            rrMilliseconds: sample.rrMillisecondsAsDouble
        )
    }
}

public protocol LiveConsumer: Sendable {
    func acquire(generation: UUID) async throws -> AsyncStream<LiveCardiacSample>
    func release(generation: UUID) async
}

public struct NoopLiveConsumer: LiveConsumer {
    public init() {}
    /// A missing live adapter is an unavailable capability, not an empty
    /// measurement.  Callers must surface this state instead of presenting a
    /// breathing session that cannot receive samples.
    public func acquire(generation: UUID) async throws -> AsyncStream<LiveCardiacSample> { throw StressError.liveUnavailable }
    public func release(generation: UUID) async {}
}

public protocol BreathingActivityHook: Sendable {
    func started(sessionID: UUID, cadence: Double) async
    func updated(sessionID: UUID, sample: LiveCardiacSample) async
    func interrupted(sessionID: UUID) async
    func ended(sessionID: UUID, result: BreathingResult?) async
}

public extension BreathingActivityHook {
    func interrupted(sessionID _: UUID) async {}
}

public struct NoopBreathingActivityHook: BreathingActivityHook {
    public init() {}
    public func started(sessionID: UUID, cadence: Double) async {}
    public func updated(sessionID: UUID, sample: LiveCardiacSample) async {}
    public func ended(sessionID: UUID, result: BreathingResult?) async {}
}

public enum BreathingState: String, Codable, Sendable { case ready, running, paused, interrupted, completed, cancelled, staleGeneration }

public struct BreathingResult: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let startedAt: Date
    public let endedAt: Date
    public let cadence: Double
    public let samples: Int
    public let averageHeartRate: Double?
    public let beforeHeartRate: Int?
    public let afterHeartRate: Int?
    public init(id: UUID = UUID(), startedAt: Date, endedAt: Date, cadence: Double, samples: Int, averageHeartRate: Double?, beforeHeartRate: Int? = nil, afterHeartRate: Int? = nil) {
        self.id = id; self.startedAt = startedAt; self.endedAt = endedAt; self.cadence = cadence; self.samples = samples; self.averageHeartRate = averageHeartRate
        self.beforeHeartRate = beforeHeartRate; self.afterHeartRate = afterHeartRate
    }
}

public enum SpotCheckAvailability: String, Codable, Equatable, Sendable {
    case complete
    case insufficientQuality
    case unavailable
}

public struct SpotCheckResult: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let startedAt: Date
    public let endedAt: Date
    public let rmssd: Double?
    public let heartRate: Double?
    /// Kept non-optional for source and persistence compatibility with the
    /// original StressKit row. `qualityAvailable` is the canonical gate;
    /// callers must not interpret this legacy field as a valid quality score
    /// when `availability` is insufficient or unavailable.
    public let quality: Double
    public let availability: SpotCheckAvailability?
    public let rrMilliseconds: [Double]?
    public let rrSampleCount: Int?
    public let normalRRCount: Int?
    public let cleanFraction: Double?
    public let rejectedSampleCount: Int?
    public let algorithmVersions: [String]?
    public let provenance: String?

    public init(
        id: UUID = UUID(),
        startedAt: Date,
        endedAt: Date,
        rmssd: Double?,
        heartRate: Double?,
        quality: Double,
        availability: SpotCheckAvailability? = nil,
        rrMilliseconds: [Double]? = nil,
        rrSampleCount: Int? = nil,
        normalRRCount: Int? = nil,
        cleanFraction: Double? = nil,
        rejectedSampleCount: Int? = nil,
        algorithmVersions: [String]? = nil,
        provenance: String? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.rmssd = rmssd
        self.heartRate = heartRate
        self.quality = quality
        self.availability = availability
        self.rrMilliseconds = rrMilliseconds
        self.rrSampleCount = rrSampleCount
        self.normalRRCount = normalRRCount
        self.cleanFraction = cleanFraction
        self.rejectedSampleCount = rejectedSampleCount
        self.algorithmVersions = algorithmVersions
        self.provenance = provenance
    }

    public var resolvedAvailability: SpotCheckAvailability {
        availability ?? (rmssd != nil ? .complete : .unavailable)
    }

    public var qualityAvailable: Double? {
        resolvedAvailability == .complete ? cleanFraction ?? quality : nil
    }
}

public protocol SpotCheckMechanism: Sendable {
    func measure(duration: Duration, generation: UUID) async throws -> SpotCheckResult
}

public struct UnavailableSpotCheckMechanism: SpotCheckMechanism {
    public init() {}
    public func measure(duration: Duration, generation: UUID) async throws -> SpotCheckResult { throw StressError.liveUnavailable }
}

public enum StressError: Error, Equatable, Sendable { case invalidCadence, notRunning, staleGeneration, liveUnavailable, noSession }

extension StressError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidCadence: "Choose a breathing pace between 1 and 30 breaths per minute."
        case .notRunning: "Start a breathing session first."
        case .staleGeneration: "The band connection changed. Start a new session."
        case .liveUnavailable: "A live reading is unavailable right now. Try again when your band is connected."
        case .noSession: "No breathing session is active."
        }
    }
}

/// Live Activities are deliberately an explicit boundary. StressKit can
/// persist a breathing result without claiming that a system Live Activity was
/// started; the app may inject a verified implementation when that capability
/// is available.
public enum StressLiveActivityAvailability: String, Codable, Equatable, Sendable {
    case unavailable
    case available
}

public protocol StressLiveActivityBoundary: Sendable {
    var availability: StressLiveActivityAvailability { get }
    func update(sessionID: UUID, result: BreathingResult?) async
    func finish(sessionID: UUID, result: BreathingResult?) async
}

public struct UnavailableStressLiveActivityBoundary: StressLiveActivityBoundary {
    public let availability: StressLiveActivityAvailability = .unavailable
    public init() {}
    public func update(sessionID: UUID, result: BreathingResult?) async {}
    public func finish(sessionID: UUID, result: BreathingResult?) async {}
}

public enum BreathingCuePhase: Equatable, Sendable {
    case inhale, exhale
    public static func phase(elapsed: TimeInterval, cadence: Double) -> Self? {
        guard elapsed.isFinite, cadence.isFinite, cadence > 0, cadence <= 30 else { return nil }
        let half = 30 / cadence
        return Int(max(0, elapsed) / half).isMultiple(of: 2) ? .inhale : .exhale
    }
}

public actor BreathingSessionController {
    public let consumer: any LiveConsumer
    public let hook: any BreathingActivityHook
    private var state: BreathingState = .ready
    private var sessionID: UUID?
    private var generation: UUID?
    private var startedAt: Date?
    private var cadence: Double = 6
    private var samples: [LiveCardiacSample] = []
    private var historyRows: [BreathingResult] = []
    private var streamTask: Task<Void, Never>?
    private var releasedGeneration: UUID?
    private let bandCue: (@Sendable (BreathingCuePhase, UUID) async -> Void)?
    private var pacingTask: Task<Void, Never>?
    private var bandPacing = false
    private var pacingStartedAt: Date?

    public init(consumer: any LiveConsumer = NoopLiveConsumer(), hook: any BreathingActivityHook = NoopBreathingActivityHook(), bandCue: (@Sendable (BreathingCuePhase, UUID) async -> Void)? = nil) {
        self.consumer = consumer; self.hook = hook; self.bandCue = bandCue
    }
    public func currentPacingStart() -> Date? { pacingStartedAt }
    public func currentState() -> BreathingState { state }
    /// Token used by the live stream bridge to reject samples from an older
    /// session after interruption or cancellation.
    public func currentGeneration() -> UUID? { generation }
    public func history() -> [BreathingResult] { historyRows.sorted { $0.startedAt < $1.startedAt } }

    @discardableResult
    public func start(cadence breathsPerMinute: Double = 6, now: Date = Date(), id: UUID = UUID(), paceWithBand: Bool = false) async throws -> UUID {
        guard breathsPerMinute > 0 && breathsPerMinute <= 30 else { throw StressError.invalidCadence }
        if state == .running || state == .paused { return sessionID ?? id }
        if state == .interrupted {
            try await resume()
            return sessionID ?? id
        }
        let generation = UUID()
        let stream: AsyncStream<LiveCardiacSample>
        do {
            stream = try await consumer.acquire(generation: generation)
        } catch {
            state = .ready
            sessionID = nil
            self.generation = nil
            throw error
        }
        self.generation = generation; releasedGeneration = nil; sessionID = id; startedAt = now; cadence = breathsPerMinute; samples.removeAll(); state = .running
        bandPacing = paceWithBand
        startPacing(at: now)
        streamTask = consume(stream, generation: generation)
        await hook.started(sessionID: id, cadence: breathsPerMinute)
        return id
    }

    public func append(_ sample: LiveCardiacSample, generation: UUID) async throws {
        guard self.generation == generation else { throw StressError.staleGeneration }
        guard state == .running else { throw StressError.notRunning }
        samples.append(sample); if let id = sessionID { await hook.updated(sessionID: id, sample: sample) }
    }

    public func pause() throws { guard state == .running else { throw StressError.notRunning }; state = .paused; pacingTask?.cancel(); pacingTask = nil }
    public func resume() async throws {
        guard state == .paused || state == .interrupted else { throw StressError.notRunning }
        if state == .paused {
            state = .running
            startPacing(at: Date())
            return
        }
        guard let id = sessionID else { throw StressError.noSession }
        let newGeneration = UUID()
        let stream: AsyncStream<LiveCardiacSample>
        do {
            stream = try await consumer.acquire(generation: newGeneration)
        } catch {
            state = .interrupted
            throw error
        }
        self.generation = newGeneration
        releasedGeneration = nil
        state = .running
        startPacing(at: Date())
        streamTask = consume(stream, generation: newGeneration)
        await hook.started(sessionID: id, cadence: cadence)
    }

    /// Ends the current live lease while retaining the partial session for an
    /// explicit resume or finish decision.  No samples are manufactured during
    /// the interruption.
    public func interrupt() async throws {
        guard let sessionID else { throw StressError.noSession }
        guard state == .running || state == .paused else { throw StressError.notRunning }
        await releaseCurrentGeneration()
        state = .interrupted
        await hook.interrupted(sessionID: sessionID)
    }

    @discardableResult
    public func finish(now: Date = Date()) async throws -> BreathingResult {
        guard let id = sessionID, let startedAt else { throw StressError.noSession }
        guard state == .running || state == .paused || state == .interrupted else { throw StressError.notRunning }
        let first = samples.first.flatMap { sample -> Int? in
            guard (0...10).contains(sample.timestamp.timeIntervalSince(startedAt)),
                  let bpm = sample.heartRate, bpm > 0 else { return nil }
            return bpm
        }
        let last = samples.last.flatMap { sample -> Int? in
            guard (0...10).contains(now.timeIntervalSince(sample.timestamp)),
                  let bpm = sample.heartRate, bpm > 0 else { return nil }
            return bpm
        }
        let result = BreathingResult(id: id, startedAt: startedAt, endedAt: now, cadence: cadence, samples: samples.count,
                                     averageHeartRate: averageHR, beforeHeartRate: first, afterHeartRate: last)
        await releaseCurrentGeneration()
        historyRows.append(result); state = .completed; sessionID = nil; self.generation = nil; self.startedAt = nil
        await hook.ended(sessionID: id, result: result); return result
    }

    public func cancel() async throws {
        guard let id = sessionID else { throw StressError.noSession }
        await releaseCurrentGeneration()
        state = .cancelled; sessionID = nil; self.generation = nil; startedAt = nil; samples.removeAll(); await hook.ended(sessionID: id, result: nil)
    }

    public func invalidateGeneration() async {
        let invalidatedSessionID = sessionID
        await releaseCurrentGeneration()
        state = .staleGeneration; sessionID = nil; self.generation = nil; startedAt = nil; samples.removeAll()
        if let invalidatedSessionID {
            await hook.ended(sessionID: invalidatedSessionID, result: nil)
        }
    }

    private func consume(_ stream: AsyncStream<LiveCardiacSample>, generation: UUID) -> Task<Void, Never> {
        Task { [self] in
            for await sample in stream {
                try? await append(sample, generation: generation)
            }
        }
    }

    private func releaseCurrentGeneration() async {
        pacingTask?.cancel(); pacingTask = nil
        streamTask?.cancel()
        streamTask = nil
        guard let generation, releasedGeneration != generation else { return }
        releasedGeneration = generation
        await consumer.release(generation: generation)
    }

    private func startPacing(at date: Date) {
        pacingTask?.cancel()
        pacingStartedAt = date
        guard bandPacing, let bandCue else { return }
        guard let token = generation else { return }
        let half = 30 / cadence
        pacingTask = Task { [weak self] in
            var lastIndex: Int?
            while !Task.isCancelled {
                guard let self, await self.currentGeneration() == token,
                      await self.currentState() == .running else { return }
                let elapsed = max(0, Date().timeIntervalSince(date))
                let index = Int(elapsed / half)
                if index != lastIndex {
                    lastIndex = index
                    await bandCue(index.isMultiple(of: 2) ? .inhale : .exhale, token)
                }
                do { try await Task.sleep(for: .seconds(max(0.01, Double(index + 1) * half - Date().timeIntervalSince(date)))) }
                catch { return }
            }
        }
    }

    private var averageHR: Double? {
        let values = samples.compactMap { $0.heartRate }.map(Double.init)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}

public actor SpotCheckHistory {
    private var rows: [SpotCheckResult] = []
    public init() {}
    public func append(_ result: SpotCheckResult) { rows.append(result) }
    public func all() -> [SpotCheckResult] { rows.sorted { $0.startedAt < $1.startedAt } }
    public func deleteAll() { rows.removeAll() }
}

/// Reuses the APP-05 mechanism rather than owning a second measurement path.
public actor SpotCheckController {
    private let mechanism: any SpotCheckMechanism
    private let consumer: (any LiveConsumer)?
    public let history: SpotCheckHistory
    private var activeGeneration: UUID?
    private var releasedGeneration: UUID?

    public init(
        mechanism: any SpotCheckMechanism,
        history: SpotCheckHistory = .init(),
        consumer: (any LiveConsumer)? = nil
    ) {
        self.mechanism = mechanism
        self.history = history
        self.consumer = consumer
    }

    public func run(duration: Duration = .seconds(60), generation: UUID = UUID()) async throws -> SpotCheckResult {
        if let consumer {
            _ = try await consumer.acquire(generation: generation)
            activeGeneration = generation
            releasedGeneration = nil
        }
        do {
            let result = try await mechanism.measure(duration: duration, generation: generation)
            await releaseCurrentGeneration()
            await history.append(result)
            return result
        } catch {
            await releaseCurrentGeneration()
            throw error
        }
    }

    public func interrupt() async {
        await releaseCurrentGeneration()
    }

    private func releaseCurrentGeneration() async {
        guard let generation = activeGeneration, releasedGeneration != generation else { return }
        releasedGeneration = generation
        activeGeneration = nil
        await consumer?.release(generation: generation)
    }
}

public struct StressScreenSnapshot: Equatable, Sendable {
    public enum State: String, CaseIterable, Sendable { case loading, noRecords, absent, measuredZero, partial, lowConfidence, settling, stale, disconnected, bluetoothOff, permissionDenied, unsupportedHardware, recoverableError, destructiveFailure, migrationFailure, ready }
    public let state: State
    public let stress: StressDetail?
    public let day: String?
    public init(state: State, stress: StressDetail? = nil, day: String? = nil) {
        self.state = state
        self.stress = stress
        self.day = day
    }
}
