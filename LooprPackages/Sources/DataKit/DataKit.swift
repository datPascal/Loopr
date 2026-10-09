import Foundation

public enum DataProvenance: String, Codable, CaseIterable, Sendable {
    case looprComputed = "Loopr-computed"
    case imported
    case edgeMerged = "Edge-merged"
    case whoopCSV = "WHOOP-CSV"
    case noopRaw = "NOOP/raw"
    case healthKit

    public var displayName: String {
        switch self {
        case .looprComputed: "Calculated by Loopr"
        case .imported: "Imported"
        case .edgeMerged: "Merged on this device"
        case .whoopCSV: "Account export"
        case .noopRaw: "Raw device data"
        case .healthKit: "Apple Health"
        }
    }
}

public struct DataRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let day: String
    public let table: String
    public var payload: [String: String]
    public var provenance: DataProvenance
    public var algorithmVersion: Int?
    public init(id: String, day: String, table: String, payload: [String: String], provenance: DataProvenance, algorithmVersion: Int? = nil) { self.id = id; self.day = day; self.table = table; self.payload = payload; self.provenance = provenance; self.algorithmVersion = algorithmVersion }
}

public struct DataBackup: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let records: [DataRecord]
    public init(schemaVersion: Int = 1, records: [DataRecord]) { self.schemaVersion = schemaVersion; self.records = records.sorted { $0.id < $1.id } }
}

public enum ImportSource: String, Codable, Sendable { case looprBackup, edgeMerge, whoopCSV, noopRaw, legacyCloud }
public struct ImportConflict: Codable, Equatable, Sendable { public let recordID: String; public let existing: DataRecord; public let incoming: DataRecord; public init(recordID: String, existing: DataRecord, incoming: DataRecord) { self.recordID = recordID; self.existing = existing; self.incoming = incoming } }
public struct ImportPreview: Codable, Equatable, Sendable { public let source: ImportSource; public let additions: [DataRecord]; public let updates: [DataRecord]; public let conflicts: [ImportConflict]; public init(source: ImportSource, additions: [DataRecord], updates: [DataRecord], conflicts: [ImportConflict]) { self.source = source; self.additions = additions; self.updates = updates; self.conflicts = conflicts } }
public struct ImportReceipt: Codable, Equatable, Sendable { public let token: UUID; public let preview: ImportPreview; public init(token: UUID = UUID(), preview: ImportPreview) { self.token = token; self.preview = preview } }

public enum DataError: Error, Equatable, Sendable, LocalizedError {
    case invalidBackup
    case conflictRequiresResolution
    case unknownReceipt
    case alreadyMigrated
    case legacyUnavailable
    case invalidDay
    case invalidImport
    case repositoryUnavailable
    case healthKitUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidBackup: "The backup is invalid."
        case .conflictRequiresResolution: "Import conflicts require an explicit resolution."
        case .unknownReceipt: "The import receipt is unknown or expired."
        case .alreadyMigrated: "Legacy data has already been migrated."
        case .legacyUnavailable: "Legacy data is not available for migration."
        case .invalidDay: "The local day is invalid."
        case .invalidImport: "The import is invalid."
        case .repositoryUnavailable: "Data storage is unavailable."
        case .healthKitUnavailable: "HealthKit sample removal is unavailable."
        }
    }
}

public enum DataDisclosureCopy {
    public static let deleteAllData = "This permanently removes every Loopr record on this iPhone: local records, files, snapshots, keychain items, notification data, live activities, re-analysis ledgers, your profile, and the paired strap. Loopr restarts at onboarding. HealthKit samples stay where they are."
}

public struct ReanalysisStatus: Codable, Equatable, Sendable { public let day: String; public let algorithmVersion: Int; public let state: String; public init(day: String, algorithmVersion: Int, state: String) { self.day = day; self.algorithmVersion = algorithmVersion; self.state = state } }

public struct DataStoreInventory: Codable, Equatable, Sendable {
    public var sqliteRows: Int
    public var files: Int?
    public var appGroupSnapshots: Int?
    public var keychainItems: Int?
    public var notifications: Int?
    public var liveActivities: Int?
    public var ledgers: Int?
    public var healthKitSamples: Int?
    public init(
        sqliteRows: Int = 0,
        files: Int? = nil,
        appGroupSnapshots: Int? = nil,
        keychainItems: Int? = nil,
        notifications: Int? = nil,
        liveActivities: Int? = nil,
        ledgers: Int? = nil,
        healthKitSamples: Int? = nil
    ) {
        self.sqliteRows = sqliteRows
        self.files = files
        self.appGroupSnapshots = appGroupSnapshots
        self.keychainItems = keychainItems
        self.notifications = notifications
        self.liveActivities = liveActivities
        self.ledgers = ledgers
        self.healthKitSamples = healthKitSamples
    }
    public var nonHealthKitIsEmpty: Bool {
        sqliteRows == 0
            && files == 0
            && appGroupSnapshots == 0
            && keychainItems == 0
            && notifications == 0
            && liveActivities == 0
            && ledgers == 0
    }
}

private func inventoryCountDescription(_ value: Int?) -> String {
    value.map(String.init) ?? "unknown"
}

public struct DiagnosticSnapshot: Codable, Equatable, Sendable {
    public let capture: String
    public let storage: String
    public let frame: String
    public let compute: String
    public let reanalysis: [ReanalysisStatus]
    public init(capture: String, storage: String, frame: String, compute: String, reanalysis: [ReanalysisStatus]) { self.capture = capture; self.storage = storage; self.frame = frame; self.compute = compute; self.reanalysis = reanalysis }
}

public enum LegacyMigrationState: String, Codable, Sendable {
    case notAvailable, ready, completed, refusedAlreadyMigrated

    public var displayName: String {
        switch self {
        case .notAvailable: "Not found"
        case .ready: "Ready to migrate"
        case .completed: "Migration complete"
        case .refusedAlreadyMigrated: "Already migrated"
        }
    }
}

/// Canonical DataKit persistence seam.  The in-memory actor remains the DEBUG
/// fixture implementation; production composes the same UI with the
/// StorageKit-backed adapter supplied by the app target.
public protocol DataStore: Sendable {
    func records() async -> [DataRecord]
    func insert(_ record: DataRecord) async throws
    func exportBackup() async -> DataBackup
    func exportJSON() async throws -> Data
    func preview(source: ImportSource, incoming: [DataRecord]) async -> ImportPreview
    func validatedPreview(source: ImportSource, incoming: [DataRecord]) async throws -> ImportPreview
    func beginImport(_ preview: ImportPreview) async throws -> ImportReceipt
    func rollback(_ receipt: ImportReceipt) async throws
    func restore(_ backup: DataBackup) async throws
    func exportDay(_ day: String) async -> DataBackup
    func deleteDay(_ day: String) async
    func reanalyze(day: String, algorithmVersion: Int) async -> ReanalysisStatus
    func reanalyzeAll(algorithmVersion: Int) async -> [ReanalysisStatus]
    func reanalysisStatus() async -> [ReanalysisStatus]
    func setInventory(_ value: DataStoreInventory) async
    func inventorySnapshot() async -> DataStoreInventory
    func completeDeletion() async
    func removeHealthKitSamples() async
    func setLegacyMigrationAvailable() async
    func legacyMigrationState() async -> LegacyMigrationState
    func runLegacyMigration(records imported: [DataRecord]) async throws -> [DataRecord]
    func diagnostics(capture: String, storage: String, frame: String, compute: String) async -> DiagnosticSnapshot

    // Checked variants are the application boundary for durable stores. The
    // legacy non-throwing methods remain available to deterministic fixtures,
    // while production adapters override these requirements to propagate a
    // SQLite/file error instead of reporting false success.
    func deleteDayChecked(_ day: String) async throws
    func reanalyzeChecked(day: String, algorithmVersion: Int) async throws -> ReanalysisStatus
    func reanalyzeAllChecked(algorithmVersion: Int) async throws -> [ReanalysisStatus]
    func completeDeletionChecked() async throws
    func removeHealthKitSamplesChecked() async throws
    func setInventoryChecked(_ value: DataStoreInventory) async throws
}

public extension DataStore {
    func deleteDayChecked(_ day: String) async throws { await deleteDay(day) }
    func reanalyzeChecked(day: String, algorithmVersion: Int) async throws -> ReanalysisStatus {
        await reanalyze(day: day, algorithmVersion: algorithmVersion)
    }
    func reanalyzeAllChecked(algorithmVersion: Int) async throws -> [ReanalysisStatus] {
        await reanalyzeAll(algorithmVersion: algorithmVersion)
    }
    func completeDeletionChecked() async throws { await completeDeletion() }
    func removeHealthKitSamplesChecked() async throws { await removeHealthKitSamples() }
    func setInventoryChecked(_ value: DataStoreInventory) async throws { await setInventory(value) }

    /// Builds diagnostics from the store's observed inventory and generation
    /// ledger. It intentionally does not reuse the backup/export path, so a
    /// diagnostics action cannot accidentally include private record payloads.
    func runtimeDiagnostics() async -> DiagnosticSnapshot {
        let inventory = await inventorySnapshot()
        let statuses = await reanalysisStatus()
        let storage = inventory.nonHealthKitIsEmpty
            ? "empty"
            : "rows:" + String(inventory.sqliteRows) + ",files:" + inventoryCountDescription(inventory.files) + ",ledgers:" + inventoryCountDescription(inventory.ledgers)
        let compute = statuses.isEmpty ? "idle" : "generations:" + String(statuses.count)
        return DiagnosticSnapshot(
            capture: "local-redacted",
            storage: storage,
            frame: "payloads-omitted",
            compute: compute,
            reanalysis: statuses
        )
    }

    func exportRuntimeDiagnosticsJSON() async throws -> Data {
        let value: DiagnosticSnapshot
        if let checked = self as? any CheckedDataStore {
            let inventory = try await checked.inventorySnapshotChecked()
            let statuses = try await checked.reanalysisStatusChecked()
            let storage = inventory.nonHealthKitIsEmpty ? "empty" : "rows:" + String(inventory.sqliteRows) + ",files:" + inventoryCountDescription(inventory.files) + ",ledgers:" + inventoryCountDescription(inventory.ledgers)
            let compute = statuses.isEmpty ? "idle" : "generations:" + String(statuses.count)
            value = DiagnosticSnapshot(capture: "local-redacted", storage: storage, frame: "payloads-omitted", compute: compute, reanalysis: statuses)
        } else {
            value = await runtimeDiagnostics()
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}

/// Durable adapters can opt into throwing reads as well as throwing writes.
/// The fixture-compatible DataStore methods stay source-compatible, while UI
/// compositions that care about persistence integrity can require this seam
/// and render a recoverable error instead of treating a failed read as zero.
public protocol CheckedDataStore: DataStore {
    func recordsChecked() async throws -> [DataRecord]
    func exportBackupChecked() async throws -> DataBackup
    func exportDayChecked(_ day: String) async throws -> DataBackup
    func exportJSONChecked() async throws -> Data
    func validatedPreviewChecked(source: ImportSource, incoming: [DataRecord]) async throws -> ImportPreview
    func restoreChecked(_ backup: DataBackup) async throws
    func reanalysisStatusChecked() async throws -> [ReanalysisStatus]
    func inventorySnapshotChecked() async throws -> DataStoreInventory
}

public extension CheckedDataStore {
    func recordsChecked() async throws -> [DataRecord] { await records() }
    func exportBackupChecked() async throws -> DataBackup { await exportBackup() }
    func exportDayChecked(_ day: String) async throws -> DataBackup { await exportDay(day) }
    func exportJSONChecked() async throws -> Data {
        try await exportJSON()
    }
    func validatedPreviewChecked(source: ImportSource, incoming: [DataRecord]) async throws -> ImportPreview {
        try await validatedPreview(source: source, incoming: incoming)
    }
    func restoreChecked(_ backup: DataBackup) async throws {
        try await restore(backup)
    }
    func reanalysisStatusChecked() async throws -> [ReanalysisStatus] { await reanalysisStatus() }
    func inventorySnapshotChecked() async throws -> DataStoreInventory { await inventorySnapshot() }
}

public actor DataRepository: CheckedDataStore {
    private var rows: [String: DataRecord] = [:]
    private var receipts: [UUID: DataBackup] = [:]
    private var migrationState: LegacyMigrationState = .notAvailable
    private var inventory = DataStoreInventory()
    private var generations: [String: ReanalysisStatus] = [:]

    public init() {}
    public func records() -> [DataRecord] { rows.values.sorted { $0.id < $1.id } }
    public func insert(_ record: DataRecord) throws { guard Self.isValidDay(record.day) else { throw DataError.invalidDay }; rows[record.id] = record; inventory.sqliteRows = rows.count }
    public func exportBackup() -> DataBackup { DataBackup(records: records()) }
    public func exportJSON() throws -> Data { try JSONEncoder.loopr.encode(exportBackup()) }

    public func preview(source: ImportSource, incoming: [DataRecord]) -> ImportPreview {
        var additions: [DataRecord] = [], updates: [DataRecord] = [], conflicts: [ImportConflict] = []
        for record in incoming {
            let normalized = Self.withProvenance(record, source: source)
            guard let existing = rows[record.id] else { additions.append(normalized); continue }
            if existing == normalized { continue }
            if existing.provenance == .looprComputed && normalized.provenance != .looprComputed { conflicts.append(ImportConflict(recordID: record.id, existing: existing, incoming: normalized)) }
            else { updates.append(normalized) }
        }
        return ImportPreview(source: source, additions: additions, updates: updates, conflicts: conflicts)
    }

    public func validatedPreview(source: ImportSource, incoming: [DataRecord]) throws -> ImportPreview {
        try validateImport(source: source, incoming: incoming)
        return preview(source: source, incoming: incoming)
    }

    public func beginImport(_ preview: ImportPreview) throws -> ImportReceipt {
        guard preview.conflicts.isEmpty else { throw DataError.conflictRequiresResolution }
        let backup = exportBackup(); let token = UUID(); receipts[token] = backup
        for row in preview.additions + preview.updates { rows[row.id] = row }
        inventory.sqliteRows = rows.count
        return ImportReceipt(token: token, preview: preview)
    }

    public func rollback(_ receipt: ImportReceipt) throws {
        guard let backup = receipts.removeValue(forKey: receipt.token) else { throw DataError.unknownReceipt }
        rows = Dictionary(uniqueKeysWithValues: backup.records.map { ($0.id, $0) }); inventory.sqliteRows = rows.count
    }

    public func restore(_ backup: DataBackup) throws {
        guard backup.schemaVersion == 1 else { throw DataError.invalidBackup }
        rows = Dictionary(uniqueKeysWithValues: backup.records.map { ($0.id, $0) }); inventory.sqliteRows = rows.count
    }

    public func exportDay(_ day: String) -> DataBackup { DataBackup(records: records().filter { $0.day == day }) }
    public func deleteDay(_ day: String) { rows = rows.filter { $0.value.day != day }; generations = generations.filter { $0.value.day != day }; inventory.sqliteRows = rows.count }
    public func reanalyze(day: String, algorithmVersion: Int) async -> ReanalysisStatus {
        let status = ReanalysisStatus(day: day, algorithmVersion: algorithmVersion, state: "completed")
        generations[day] = status
        let ids = Array(rows.keys)
        for id in ids where rows[id]?.day == day { rows[id]?.algorithmVersion = algorithmVersion }
        return status
    }
    public func reanalyzeAll(algorithmVersion: Int) async -> [ReanalysisStatus] {
        let days = Array(Set(rows.values.map(\.day))).sorted()
        let ids = Array(rows.keys)
        for id in ids { rows[id]?.algorithmVersion = algorithmVersion }
        return days.map { day in
            let status = ReanalysisStatus(day: day, algorithmVersion: algorithmVersion, state: "completed")
            generations[day] = status
            return status
        }
    }
    public func reanalysisStatus() -> [ReanalysisStatus] { generations.values.sorted { $0.day < $1.day } }

    public func setInventory(_ value: DataStoreInventory) { inventory = value; inventory.sqliteRows = rows.count }
    public func inventorySnapshot() -> DataStoreInventory { inventory }
    /// Complete deletion intentionally leaves HealthKit samples for the
    /// separate, explicit HealthKit-removal action.
    public func completeDeletion() { rows.removeAll(); receipts.removeAll(); generations.removeAll(); inventory.sqliteRows = 0; inventory.files = 0; inventory.appGroupSnapshots = 0; inventory.keychainItems = 0; inventory.notifications = 0; inventory.liveActivities = 0; inventory.ledgers = 0 }
    public func removeHealthKitSamples() { inventory.healthKitSamples = 0 }

    public func setLegacyMigrationAvailable() { migrationState = .ready }
    public func legacyMigrationState() -> LegacyMigrationState { migrationState }
    public func runLegacyMigration(records imported: [DataRecord]) throws -> [DataRecord] {
        guard migrationState == .ready else { if migrationState == .completed { throw DataError.alreadyMigrated }; throw DataError.legacyUnavailable }
        try validateImport(source: .legacyCloud, incoming: imported)
        for row in imported { rows[row.id] = Self.withProvenance(row, source: .legacyCloud) }
        migrationState = .completed; inventory.sqliteRows = rows.count
        return imported.map { Self.withProvenance($0, source: .legacyCloud) }
    }

    public func diagnostics(capture: String = "unknown", storage: String = "ready", frame: String = "ready", compute: String = "idle") -> DiagnosticSnapshot { DiagnosticSnapshot(capture: capture, storage: storage, frame: frame, compute: compute, reanalysis: reanalysisStatus()) }

    private static func withProvenance(_ record: DataRecord, source: ImportSource) -> DataRecord {
        var result = record
        result.provenance = switch source { case .looprBackup: .looprComputed; case .edgeMerge: .edgeMerged; case .whoopCSV: .whoopCSV; case .noopRaw: .noopRaw; case .legacyCloud: .imported }
        if result.provenance != .looprComputed { result.algorithmVersion = nil }
        return result
    }

    private func validateImport(source: ImportSource, incoming: [DataRecord]) throws {
        guard !incoming.isEmpty else { throw DataError.invalidImport }
        for row in incoming {
            guard Self.isValidDay(row.day) else { throw DataError.invalidDay }
            if source == .noopRaw && row.payload.isEmpty { throw DataError.invalidImport }
        }
    }

    private static func isValidDay(_ day: String) -> Bool {
        guard day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return false }
        let pieces = day.split(separator: "-").compactMap { Int($0) }
        guard pieces.count == 3 else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: pieces[0], month: pieces[1], day: pieces[2])) else { return false }
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return components.year == pieces[0] && components.month == pieces[1] && components.day == pieces[2]
    }
}

private extension JSONEncoder {
    static var loopr: JSONEncoder { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return encoder }
}

public struct DataScreenSnapshot: Equatable, Sendable {
    public enum State: String, CaseIterable, Sendable { case loading, noRecords, absent, measuredZero, partial, lowConfidence, settling, stale, disconnected, bluetoothOff, permissionDenied, unsupportedHardware, recoverableError, destructiveFailure, migrationFailure, preview, conflict, rollback, ready }
    public let state: State
    public init(state: State) { self.state = state }
}
