import AnalyticsKit
import BluetoothKit
import DesignSystem
import Foundation
import HeartKit
import StorageKit
import StressKit

/// A clock is injected so a live measurement can be tested without waiting
/// for wall time.  Production uses `ContinuousClock`; the service never
/// substitutes a shorter duration just because a stream is quiet.
nonisolated protocol LiveSpotCheckClock: Sendable {
    nonisolated func now() -> Date
    nonisolated func sleep(for duration: Duration) async throws
}

struct ContinuousLiveSpotCheckClock: LiveSpotCheckClock {
    private let clock = ContinuousClock()

    func now() -> Date { Date() }

    func sleep(for duration: Duration) async throws {
        try await clock.sleep(for: duration)
    }
}

enum CanonicalLiveSpotCheckError: Error, Equatable, Sendable, LocalizedError {
    case invalidDuration
    case unavailable
    case cancelled
    case persistenceFailed

    var errorDescription: String? {
        switch self {
        case .invalidDuration:
            "Spot check duration must be greater than zero."
        case .unavailable:
            "Your band is not ready to send readings. Keep it near your iPhone and try again once it is connected."
        case .cancelled:
            "The spot check was cancelled before a result was saved."
        case .persistenceFailed:
            "The spot check could not be saved; no partial result was published."
        }
    }
}

/// The two package records are committed together.  Implementations must
/// either save both records or throw; a successful Heart result must never be
/// visible while its matching Stress provenance row is missing.
nonisolated protocol CanonicalSpotCheckPersistence: Sendable {
    func persist(heart: HeartSpotCheckResult, stress: SpotCheckResult) async throws
}

private struct SpotCheckCapture: Sendable {
    let startedAt: Date
    let endedAt: Date
    let rrIntervals: [Double]
    let rrTimestampsMilliseconds: [Double]
    let heartRates: [Double]
    let rejectedSampleCount: Int
}

/// Runs one bounded, generation-pinned cardiac session and publishes only
/// AnalyticsKit-derived values.  It owns no BLE transport and never decodes
/// bytes; SyncKit supplies `LiveStreamEvent` and HeartKit owns the canonical
/// compact-event mapper.
actor CanonicalLiveSpotCheckService: SpotCheckMechanism {
    static let productionDuration: Duration = .seconds(60)

    private static let provenance = "BLE-07.compactHeartRateRR -> ana02.rr-quality.v1 -> ana02.hrv.v1"
    private static let source = "BLE-07.compactHeartRateRR"

    private let runtime: any LooprHeartLiveRuntime
    private let persistence: any CanonicalSpotCheckPersistence
    private let clock: any LiveSpotCheckClock
    private let defaultDuration: Duration

    init(
        runtime: any LooprHeartLiveRuntime,
        persistence: any CanonicalSpotCheckPersistence,
        clock: any LiveSpotCheckClock = ContinuousLiveSpotCheckClock(),
        defaultDuration: Duration = CanonicalLiveSpotCheckService.productionDuration
    ) {
        self.runtime = runtime
        self.persistence = persistence
        self.clock = clock
        self.defaultDuration = defaultDuration
    }

    /// HeartKit's action entry point.  The matching Stress row is saved in
    /// the same transaction and is available to Stress history immediately.
    func runHeartSpotCheck(
        duration: Duration? = nil,
        generation: UUID = UUID()
    ) async throws -> HeartSpotCheckResult {
        let capture = try await capture(
            duration: duration ?? defaultDuration
        )
        let results = makeResults(capture: capture, duration: duration ?? defaultDuration, id: generation)
        try await persist(results)
        return results.heart
    }

    /// StressKit's existing action protocol.  The UUID is the logical action
    /// generation; the event subscription separately validates SyncKit's
    /// UInt64 connection generation.
    func measure(duration: Duration, generation: UUID) async throws -> SpotCheckResult {
        let capture = try await capture(duration: duration)
        let results = makeResults(capture: capture, duration: duration, id: generation)
        try await persist(results)
        return results.stress
    }

    private func persist(_ results: (heart: HeartSpotCheckResult, stress: SpotCheckResult)) async throws {
        do {
            try await persistence.persist(heart: results.heart, stress: results.stress)
        } catch is CancellationError {
            throw CanonicalLiveSpotCheckError.cancelled
        } catch {
            throw CanonicalLiveSpotCheckError.persistenceFailed
        }
    }

    private func capture(duration: Duration) async throws -> SpotCheckCapture {
        guard duration > .zero else { throw CanonicalLiveSpotCheckError.invalidDuration }
        if Task.isCancelled { throw CanonicalLiveSpotCheckError.cancelled }

        let startedAt = clock.now()
        let subscription: LiveStreamEventSubscription
        do {
            subscription = try await runtime.acquireLiveEventStream(
                kind: .compactHeartRateRR,
                consumer: .spotCheck
            )
        } catch is CancellationError {
            throw CanonicalLiveSpotCheckError.cancelled
        } catch {
            throw CanonicalLiveSpotCheckError.unavailable
        }

        let collector = Task { () -> SpotCheckCapture in
            var rrIntervals: [Double] = []
            var rrTimestampsMilliseconds: [Double] = []
            var heartRates: [Double] = []
            var rejectedSampleCount = 0
            var lastPacketTimestampSeconds: UInt32?

            for await event in subscription.stream {
                guard !Task.isCancelled else { break }
                guard event.generation == subscription.generation else {
                    rejectedSampleCount += 1
                    continue
                }
                guard let sample = HeartLiveEventMapper.decode(event), sample.wearing else {
                    rejectedSampleCount += 1
                    continue
                }

                guard sample.heartRateBPM.isFinite, sample.heartRateBPM > 0 else {
                    rejectedSampleCount += 1
                    continue
                }
                if let lastPacketTimestampSeconds,
                   sample.deviceTimestampSeconds < lastPacketTimestampSeconds {
                    rejectedSampleCount += sample.rrIntervalsMilliseconds.count
                    continue
                }
                lastPacketTimestampSeconds = sample.deviceTimestampSeconds
                heartRates.append(sample.heartRateBPM)

                let validIntervals = sample.rrIntervalsMilliseconds.filter {
                    $0.isFinite && $0 > 0
                }
                rejectedSampleCount += sample.rrIntervalsMilliseconds.count - validIntervals.count
                rrIntervals.append(contentsOf: validIntervals)
                rrTimestampsMilliseconds.append(
                    contentsOf: repeatElement(
                        Double(sample.deviceTimestampSeconds) * 1_000,
                        count: validIntervals.count
                    )
                )
            }

            return SpotCheckCapture(
                startedAt: startedAt,
                endedAt: Date(),
                rrIntervals: rrIntervals,
                rrTimestampsMilliseconds: rrTimestampsMilliseconds,
                heartRates: heartRates,
                rejectedSampleCount: rejectedSampleCount
            )
        }

        do {
            try await clock.sleep(for: duration)
        } catch {
            _ = await subscription.cancel()
            _ = await collector.value
            throw CanonicalLiveSpotCheckError.cancelled
        }

        _ = await subscription.cancel()
        var capture = await collector.value
        if Task.isCancelled {
            throw CanonicalLiveSpotCheckError.cancelled
        }
        capture = SpotCheckCapture(
            startedAt: capture.startedAt,
            endedAt: clock.now(),
            rrIntervals: capture.rrIntervals,
            rrTimestampsMilliseconds: capture.rrTimestampsMilliseconds,
            heartRates: capture.heartRates,
            rejectedSampleCount: capture.rejectedSampleCount
        )
        return capture
    }

    private func makeResults(
        capture: SpotCheckCapture,
        duration: Duration,
        id: UUID
    ) -> (heart: HeartSpotCheckResult, stress: SpotCheckResult) {
        let correction = RRQuality.correct(
            capture.rrIntervals,
            beatTimestampsMilliseconds: capture.rrTimestampsMilliseconds
        )
        let gate = RRQuality.gated(
            capture.rrIntervals,
            beatTimestampsMilliseconds: capture.rrTimestampsMilliseconds
        )
        let hrv = gate.value.map {
            HRVTime.derive(
                $0.normalIntervalsMilliseconds,
                beatTimesMilliseconds: $0.normalTimesMilliseconds
            )
        }
        let complete = gate.value != nil && hrv?.value != nil
        let availability: SpotCheckAvailability = complete ? .complete : .insufficientQuality
        let heartAvailability: HeartSpotCheckAvailability = complete ? .complete : .insufficientQuality
        let state: MetricState = complete ? .partial : .lowConfidence
        let durationSeconds = max(0, Int(duration.components.seconds))
        let normalRRCount = gate.value?.normalIntervalsMilliseconds.count ?? correction.normalIntervalsMilliseconds.count
        let algorithmVersions = [AnalyticsAlgorithmVersion.rrQuality, AnalyticsAlgorithmVersion.hrv]
        let detail = gate.note ?? "RR quality was insufficient for a publishable spot check."
        let rmssd = hrv?.value?.rmssdMilliseconds
        let sdnn = hrv?.value?.sdnnMilliseconds
        let averageHeartRate = AnalyticsMath.mean(capture.heartRates)

        let heart = HeartSpotCheckResult(
            state: state,
            heartRateBPM: averageHeartRate,
            rmssdMilliseconds: complete ? rmssd : nil,
            sdnnMilliseconds: complete ? sdnn : nil,
            durationSeconds: durationSeconds,
            qualityDetail: detail,
            source: Self.source,
            availability: heartAvailability,
            rrSampleCount: capture.rrIntervals.count,
            normalRRCount: normalRRCount,
            cleanFraction: correction.cleanFraction,
            rejectedSampleCount: capture.rejectedSampleCount,
            algorithmVersions: algorithmVersions,
            provenance: Self.provenance,
            startedAt: capture.startedAt,
            endedAt: capture.endedAt
        )

        let stress = SpotCheckResult(
            id: id,
            startedAt: capture.startedAt,
            endedAt: capture.endedAt,
            rmssd: complete ? rmssd : nil,
            heartRate: averageHeartRate,
            quality: correction.cleanFraction,
            availability: availability,
            rrMilliseconds: capture.rrIntervals,
            rrSampleCount: capture.rrIntervals.count,
            normalRRCount: normalRRCount,
            cleanFraction: correction.cleanFraction,
            rejectedSampleCount: capture.rejectedSampleCount,
            algorithmVersions: algorithmVersions,
            provenance: Self.provenance
        )
        return (heart, stress)
    }
}

/// Atomic adapter for the app's existing namespaced document rows.  The
/// canonical Heart row and append-only Stress history row are written inside
/// one GRDB transaction; a thrown encode or SQL error rolls both back.
actor SQLiteCanonicalSpotCheckPersistence: CanonicalSpotCheckPersistence {
    private nonisolated static let table = "loopr_product_document"
    private let database: StorageDatabase
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(database: StorageDatabase) throws {
        self.database = database
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
        try database.write { db in
            try db.create(table: Self.table, ifNotExists: true) { table in
                table.column("namespace", .text).notNull()
                table.column("document_key", .text).notNull()
                table.column("payload", .blob).notNull()
                table.column("updated_at", .double).notNull()
                table.primaryKey(["namespace", "document_key"])
            }
        }
    }

    func persist(heart: HeartSpotCheckResult, stress: SpotCheckResult) async throws {
        let heartPayload = try encoder.encode(heart)
        let now = Date().timeIntervalSince1970

        try database.write { db in
            let existingStressPayload: Data? = try Data.fetchOne(
                db,
                sql: "SELECT payload FROM \(Self.table) WHERE namespace = ? AND document_key = ?",
                arguments: ["stress", "spot-checks"]
            )
            var stressRows = try existingStressPayload.map { try decoder.decode([SpotCheckResult].self, from: $0) } ?? []
            stressRows.removeAll { $0.id == stress.id }
            stressRows.append(stress)
            let stressPayload = try encoder.encode(stressRows)

            try db.execute(
                sql: """
                INSERT INTO \(Self.table)(namespace, document_key, payload, updated_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(namespace, document_key) DO UPDATE SET
                    payload = excluded.payload,
                    updated_at = excluded.updated_at
                """,
                arguments: ["heart", "spot-check", heartPayload, now]
            )
            try db.execute(
                sql: """
                INSERT INTO \(Self.table)(namespace, document_key, payload, updated_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(namespace, document_key) DO UPDATE SET
                    payload = excluded.payload,
                    updated_at = excluded.updated_at
                """,
                arguments: ["stress", "spot-checks", stressPayload, now]
            )
        }
    }
}

/// Test and preview persistence that still exercises the same atomic API.
actor InMemoryCanonicalSpotCheckPersistence: CanonicalSpotCheckPersistence {
    private(set) var heart: HeartSpotCheckResult?
    private(set) var stress: [SpotCheckResult] = []
    var shouldFail = false

    func persist(heart: HeartSpotCheckResult, stress: SpotCheckResult) async throws {
        if shouldFail { throw CanonicalLiveSpotCheckError.persistenceFailed }
        self.heart = heart
        self.stress.removeAll { $0.id == stress.id }
        self.stress.append(stress)
    }

    func setShouldFail(_ value: Bool) { shouldFail = value }
    func savedHeart() -> HeartSpotCheckResult? { heart }
    func savedStress() -> [SpotCheckResult] { stress }
}
