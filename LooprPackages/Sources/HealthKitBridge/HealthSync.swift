import Foundation

/// A logical sample keeps its identity when its value or interval is corrected.
public struct HealthSyncSample: Codable, Equatable, Sendable {
    public let identifier: String
    public let metric: ExportMetricKind
    public let value: Double
    public let start: Date
    public let end: Date
    public let provenance: String
    public let algorithm: String
    public let timeZone: String
    public let workoutActivity: String?

    public init(identifier: String, metric: ExportMetricKind, value: Double, start: Date, end: Date,
                provenance: String, algorithm: String, timeZone: String, workoutActivity: String? = nil) {
        self.identifier = identifier; self.metric = metric; self.value = value
        self.start = start; self.end = end; self.provenance = provenance
        self.algorithm = algorithm; self.timeZone = timeZone; self.workoutActivity = workoutActivity
    }
}

public protocol HealthSyncClient: Sendable {
    func writeAuthorization(for metric: ExportMetricKind) async -> HealthAuthorizationState
    func requestWriteAuthorization(for metrics: Set<ExportMetricKind>) async throws
    func save(_ sample: HealthSyncSample, version: Int) async throws
    func remove(metric: ExportMetricKind, identifiers: [String]) async throws
}

public struct HealthSyncPreferences: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var disabledRead: Set<HealthHistoryQuantity>
    public var sleepReadEnabled: Bool
    public var disabledWrite: Set<ExportMetricKind>
    /// Pin export day assignment so travelling cannot duplicate cumulative totals.
    public let timeZoneIdentifier: String
    public init(enabled: Bool = true, disabledRead: Set<HealthHistoryQuantity> = [], sleepReadEnabled: Bool = true,
                disabledWrite: Set<ExportMetricKind> = [], timeZoneIdentifier: String = TimeZone.current.identifier) {
        self.enabled = enabled; self.disabledRead = disabledRead; self.sleepReadEnabled = sleepReadEnabled
        self.disabledWrite = disabledWrite
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    private enum CodingKeys: String, CodingKey { case enabled, disabledRead, sleepReadEnabled, disabledWrite, timeZoneIdentifier }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        disabledRead = try values.decodeIfPresent(Set<HealthHistoryQuantity>.self, forKey: .disabledRead) ?? []
        sleepReadEnabled = try values.decodeIfPresent(Bool.self, forKey: .sleepReadEnabled) ?? true
        disabledWrite = try values.decodeIfPresent(Set<ExportMetricKind>.self, forKey: .disabledWrite) ?? []
        timeZoneIdentifier = try values.decode(String.self, forKey: .timeZoneIdentifier)
    }
}

public struct HealthSyncPartition: Codable, Equatable, Sendable {
    public var samples: [HealthSyncSample]
    public var version: Int
    public var saved: Set<String>
    public var obsolete: Set<String>
    public var lastError: String?
    public var completedAt: Date?

    public init(samples: [HealthSyncSample], version: Int, saved: Set<String>, obsolete: Set<String>,
                lastError: String?, completedAt: Date?) {
        self.samples = samples; self.version = version; self.saved = saved
        self.obsolete = obsolete; self.lastError = lastError; self.completedAt = completedAt
    }

    public var pendingCount: Int { samples.filter { !saved.contains($0.identifier) }.count + obsolete.count }
}

/// Implementations must commit each write atomically and throw on unreadable state.
public protocol HealthSyncStore: Sendable {
    func preferences() throws -> HealthSyncPreferences
    func savePreferences(_ value: HealthSyncPreferences) throws
    func partition(_ key: String) throws -> HealthSyncPartition?
    func savePartition(_ value: HealthSyncPartition, key: String) throws
    func partitionKeys() throws -> [String]
}

public struct HealthSyncReport: Equatable, Sendable {
    public var saved = 0
    public var pending = 0
    public var error: String?
    public init() {}
}

/// Serialize attempts, persist progress per sample, and re-check the local
/// switch and system permission before each external mutation. HealthKit sync
/// metadata covers a crash after a save but before its local acknowledgement.
public actor HealthSyncEngine {
    private let store: any HealthSyncStore
    private let client: any HealthSyncClient
    private var processing = false
    private var stopped = false
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private var attemptWaiters: [CheckedContinuation<Void, Never>] = []

    public init(store: any HealthSyncStore, client: any HealthSyncClient) {
        self.store = store; self.client = client
    }

    public func stop() async {
        stopped = true
        if processing { await withCheckedContinuation { stopWaiters.append($0) } }
    }

    public func synchronize(key: String, metric: ExportMetricKind, samples: [HealthSyncSample], now: Date) async throws -> HealthSyncReport {
        while processing { await withCheckedContinuation { attemptWaiters.append($0) } }
        guard !stopped, try store.preferences().enabled,
              !(try store.preferences()).disabledWrite.contains(metric) else { return HealthSyncReport() }
        guard samples.allSatisfy({ $0.metric == metric && $0.value.isFinite && $0.start <= $0.end }),
              Set(samples.map(\.identifier)).count == samples.count else { throw HealthSyncError.invalidSamples }
        processing = true
        defer {
            processing = false
            let waiters = stopWaiters
            stopWaiters = []
            for waiter in waiters { waiter.resume() }
            let attempts = attemptWaiters
            attemptWaiters = []
            for waiter in attempts { waiter.resume() }
        }
        var partition = try store.partition(key)
        if partition == nil && samples.isEmpty { return HealthSyncReport() }
        if partition?.samples != samples {
            let previous = partition
            let nextIDs = Set(samples.map(\.identifier))
            let previousIDs = Set(previous?.samples.map(\.identifier) ?? []).union(previous?.obsolete ?? [])
            let previousSamples = Dictionary(uniqueKeysWithValues: (previous?.samples ?? []).map { ($0.identifier, $0) })
            let unchanged = Set(samples.filter {
                previous?.saved.contains($0.identifier) == true && previousSamples[$0.identifier] == $0
            }.map(\.identifier))
            // Wall-clock versions also remain newer after local data is reset.
            let version = max((previous?.version ?? 0) + 1, Int(now.timeIntervalSince1970 * 1_000_000))
            partition = HealthSyncPartition(samples: samples, version: version, saved: unchanged,
                obsolete: previousIDs.subtracting(nextIDs), lastError: nil, completedAt: nil)
            try store.savePartition(partition!, key: key)
        }
        guard var current = partition else { return HealthSyncReport() }
        var report = HealthSyncReport()
        for sample in current.samples where !current.saved.contains(sample.identifier) {
            guard !stopped, try store.preferences().enabled,
                  !(try store.preferences()).disabledWrite.contains(metric) else { break }
            guard await client.writeAuthorization(for: metric) == .authorized else { break }
            guard !stopped, try store.preferences().enabled,
                  !(try store.preferences()).disabledWrite.contains(metric) else { break }
            do {
                try Task.checkCancellation()
                try await client.save(sample, version: current.version)
                guard !stopped else { return report }
                current.saved.insert(sample.identifier)
                current.lastError = nil
                try store.savePartition(current, key: key)
                report.saved += 1
            } catch is CancellationError { throw CancellationError() }
            catch {
                guard !stopped else { return report }
                current.lastError = error.localizedDescription
                try store.savePartition(current, key: key)
                report.error = current.lastError
                // Retain every remaining sample and retry on the next pass.
                break
            }
        }
        // Save the replacement before removing intervals no longer present.
        if current.saved.count == current.samples.count, !current.obsolete.isEmpty,
           !stopped, try store.preferences().enabled,
           !(try store.preferences()).disabledWrite.contains(metric),
           await client.writeAuthorization(for: metric) == .authorized,
           !stopped, try store.preferences().enabled,
           !(try store.preferences()).disabledWrite.contains(metric) {
            do {
                try Task.checkCancellation()
                try await client.remove(metric: metric, identifiers: current.obsolete.sorted())
                guard !stopped else { return report }
                current.obsolete = []
                current.lastError = nil
                try store.savePartition(current, key: key)
            } catch is CancellationError { throw CancellationError() }
            catch {
                guard !stopped else { return report }
                current.lastError = error.localizedDescription
                try store.savePartition(current, key: key)
                report.error = current.lastError
            }
        }
        if !stopped, current.pendingCount == 0, current.completedAt == nil {
            current.completedAt = now
            current.lastError = nil
            try store.savePartition(current, key: key)
        }
        report.pending = current.pendingCount
        return report
    }
}

public enum HealthSyncError: Error, Equatable, Sendable {
    case invalidSamples
    case permissionRequired
}
