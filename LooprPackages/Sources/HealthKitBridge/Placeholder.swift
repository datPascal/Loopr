import Foundation

public enum HealthDataType: String, CaseIterable, Codable, Hashable, Sendable {
    case dateOfBirth, vo2Max, height, bodyMass, bodyFatPercentage, leanBodyMass
}

public enum HealthFeature: Sendable { case bodyCompositionImport, ageInsightsImport, metricExport }

public struct HealthAuthorizationScope: Equatable, Sendable {
    public var read: Set<HealthDataType>
    public var share: Set<ExportMetricKind>
    public init(read: Set<HealthDataType> = [], share: Set<ExportMetricKind> = []) {
        self.read = read; self.share = share
    }
    public static func contextual(for feature: HealthFeature) -> Self {
        switch feature {
        case .bodyCompositionImport:
            .init(read: [.height, .bodyMass, .bodyFatPercentage, .leanBodyMass])
        case .ageInsightsImport:
            .init(read: [.dateOfBirth, .vo2Max])
        case .metricExport:
            .init(share: Set(ExportMetricKind.allCases))
        }
    }
}

public enum HealthAuthorizationState: Equatable, Sendable {
    case notDetermined, authorized, denied, unavailable
}
public enum HealthAuthorizationError: Error, Equatable, Sendable {
    case unavailable, cancelled, denied(Set<HealthDataType>), requestFailed(String)
}
public protocol HealthAuthorizationClient: Sendable {
    func request(_ scope: HealthAuthorizationScope) async throws -> Bool
    func status(for type: HealthDataType) async -> HealthAuthorizationState
}

/// Has no launch hook by design. Only an explicit settings action can call `enable(_:)`.
public actor ContextualHealthAuthorization {
    private let client: any HealthAuthorizationClient
    private(set) public var requestCount = 0
    public init(client: any HealthAuthorizationClient) { self.client = client }
    @discardableResult
    public func enable(_ feature: HealthFeature) async throws -> HealthAuthorizationScope {
        let scope = HealthAuthorizationScope.contextual(for: feature)
        requestCount += 1
        guard try await client.request(scope) else { throw HealthAuthorizationError.cancelled }
        return scope
    }
    public func currentState(for requiredTypes: Set<HealthDataType>) async -> HealthAuthorizationState {
        guard !requiredTypes.isEmpty else { return .authorized }
        var unavailable = false
        for type in requiredTypes {
            switch await client.status(for: type) {
            case .denied: return .denied
            case .unavailable: unavailable = true
            case .notDetermined: return .notDetermined
            case .authorized: break
            }
        }
        return unavailable ? .unavailable : .authorized
    }
}

public enum ImportedSampleDeletionState: Equatable, Codable, Sendable {
    case active
    case deleted(at: Date)
}
public struct ImportedHealthSample: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public let type: HealthDataType
    public let source: String
    public let device: String?
    public let unit: String
    public let value: Double
    public let startDate: Date
    public let endDate: Date
    public let importedAt: Date
    public var deletionState: ImportedSampleDeletionState
    public init(id: UUID, type: HealthDataType, source: String, device: String?, unit: String,
                value: Double, startDate: Date, endDate: Date, importedAt: Date,
                deletionState: ImportedSampleDeletionState = .active) {
        self.id = id; self.type = type; self.source = source; self.device = device
        self.unit = unit; self.value = value; self.startDate = startDate; self.endDate = endDate
        self.importedAt = importedAt; self.deletionState = deletionState
    }
}
public struct AnchoredHealthChanges: Equatable, Sendable {
    public let samples: [ImportedHealthSample]
    public let deletedSampleIDs: [UUID]
    public let nextAnchor: Data
    public init(samples: [ImportedHealthSample], deletedSampleIDs: [UUID], nextAnchor: Data) {
        self.samples = samples; self.deletedSampleIDs = deletedSampleIDs; self.nextAnchor = nextAnchor
    }
}
public protocol AnchoredHealthQueryClient: Sendable {
    func changes(for type: HealthDataType, after anchor: Data?) async throws -> AnchoredHealthChanges
}
public actor HealthImportLedger {
    private var samples: [UUID: ImportedHealthSample] = [:]
    private var anchors: [HealthDataType: Data] = [:]
    private let persistenceURL: URL?

    private struct PersistentState: Codable {
        var samples: [UUID: ImportedHealthSample]
        var anchors: [HealthDataType: Data]
    }

    public init(persistenceURL: URL? = nil) {
        self.persistenceURL = persistenceURL
        guard let persistenceURL,
              let data = try? Data(contentsOf: persistenceURL),
              let state = try? JSONDecoder().decode(PersistentState.self, from: data) else { return }
        samples = state.samples
        anchors = state.anchors
    }
    public func apply(_ changes: AnchoredHealthChanges, for type: HealthDataType, deletedAt: Date) {
        for sample in changes.samples { samples[sample.id] = sample }
        for id in changes.deletedSampleIDs where samples[id] != nil {
            samples[id]?.deletionState = .deleted(at: deletedAt)
        }
        anchors[type] = changes.nextAnchor
        persist()
    }
    public func anchor(for type: HealthDataType) -> Data? { anchors[type] }
    public func sample(id: UUID) -> ImportedHealthSample? { samples[id] }
    public func allSamples() -> [ImportedHealthSample] { samples.values.sorted { $0.id.uuidString < $1.id.uuidString } }

    private func persist() {
        guard let persistenceURL,
              let data = try? JSONEncoder().encode(PersistentState(samples: samples, anchors: anchors)) else { return }
        try? FileManager.default.createDirectory(
            at: persistenceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: persistenceURL, options: [.atomic])
    }
}
public actor AnchoredHealthImporter {
    private let query: any AnchoredHealthQueryClient
    private let ledger: HealthImportLedger
    public init(query: any AnchoredHealthQueryClient, ledger: HealthImportLedger) {
        self.query = query; self.ledger = ledger
    }
    public func importChanges(for type: HealthDataType, now: Date) async throws {
        let changes = try await query.changes(for: type, after: await ledger.anchor(for: type))
        await ledger.apply(changes, for: type, deletedAt: now)
    }
}

public enum ExportMetricKind: String, CaseIterable, Codable, Hashable, Sendable {
    case heartRate, restingHeartRate, heartRateVariabilitySDNN, respiratoryRate
    case sleepStages, steps, activeEnergy, completedWorkout
}
public enum ExportFirewallError: Error, Equatable, Sendable { case forbiddenMetric(String) }
public enum HealthExportFirewall {
    public static let forbidden = Set(["readiness", "strain", "stress", "rmssd",
        "uncalibratedOpticalOxygen", "relativeTemperature", "cardioAge", "looprAge"])
    public static func metric(named name: String) throws -> ExportMetricKind {
        guard let metric = ExportMetricKind(rawValue: name) else {
            throw ExportFirewallError.forbiddenMetric(name)
        }
        return metric
    }
}
public struct HealthExportObject: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public let metric: ExportMetricKind
    public let value: Double
    public let unit: String
    public let startDate: Date
    public let endDate: Date
    public init(id: UUID, metric: ExportMetricKind, value: Double, unit: String,
                startDate: Date, endDate: Date) {
        self.id = id; self.metric = metric; self.value = value; self.unit = unit
        self.startDate = startDate; self.endDate = endDate
    }
}
public enum ExportLedgerStatus: Equatable, Codable, Sendable {
    case pending, exported(at: Date), failed(message: String)
}
public enum HealthExportLedgerError: Error, Equatable, Sendable {
    case unreadable
}
public actor HealthExportLedger {
    private var rows: [UUID: ExportLedgerStatus] = [:]
    private let persistenceURL: URL?
    private let restorationFailed: Bool
    public init(persistenceURL: URL? = nil) {
        self.persistenceURL = persistenceURL
        guard let persistenceURL,
              FileManager.default.fileExists(atPath: persistenceURL.path) else {
            restorationFailed = false
            return
        }
        do {
            let data = try Data(contentsOf: persistenceURL)
            rows = try JSONDecoder().decode([UUID: ExportLedgerStatus].self, from: data)
            restorationFailed = false
        } catch {
            restorationFailed = true
        }
    }
    public func status(for id: UUID) throws -> ExportLedgerStatus? {
        guard !restorationFailed else { throw HealthExportLedgerError.unreadable }
        return rows[id]
    }
    public func set(_ status: ExportLedgerStatus, for id: UUID) throws {
        guard !restorationFailed else { throw HealthExportLedgerError.unreadable }
        let previous = rows[id]
        rows[id] = status
        do {
            try persist()
        } catch {
            rows[id] = previous
            throw error
        }
    }
    public func allRows() throws -> [UUID: ExportLedgerStatus] {
        guard !restorationFailed else { throw HealthExportLedgerError.unreadable }
        return rows
    }

    private func persist() throws {
        guard let persistenceURL else { return }
        let data = try JSONEncoder().encode(rows)
        try FileManager.default.createDirectory(
            at: persistenceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: persistenceURL, options: [.atomic])
    }
}
public protocol HealthExportClient: Sendable { func save(_ object: HealthExportObject) async throws }
public protocol HealthSampleDeletionClient: Sendable {
    /// Deletes only samples written by this application and returns the number
    /// of removed HealthKit objects.
    func deleteLooprCreatedSamples() async throws -> Int
}
public actor HealthExportScheduler {
    private let client: any HealthExportClient
    private let ledger: HealthExportLedger
    public init(client: any HealthExportClient, ledger: HealthExportLedger) {
        self.client = client; self.ledger = ledger
    }
    public func export(_ objects: [HealthExportObject], now: Date) async throws {
        for object in objects {
            if case .exported = try await ledger.status(for: object.id) { continue }
            try await ledger.set(.pending, for: object.id)
            do {
                try await client.save(object)
            } catch {
                try await ledger.set(.failed(message: String(describing: error)), for: object.id)
                continue
            }
            try await ledger.set(.exported(at: now), for: object.id)
        }
    }
}
public enum HealthDateWindows {
    public static func localDay(containing date: Date, calendar input: Calendar) -> DateInterval? {
        var calendar = input
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar.dateInterval(of: .day, for: date)
    }
}
