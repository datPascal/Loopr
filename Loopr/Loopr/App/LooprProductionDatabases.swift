import Foundation
import OSLog
import StorageKit

/// The app's two SQLite files, each opened once per process.
///
/// The per-second history file used to be opened twice at launch: once by the
/// Bluetooth store in a detached task, and again on the main thread when the
/// product repositories were built, each time with a full integrity check.
/// Now every production caller shares one `StorageDatabase` per file:
///
/// - The Bluetooth store and the product repositories get the same pool, so
///   the history file has one writer.
/// - `prewarmLaunchStores()` opens both files off the main thread while the
///   launch screen is up, so building the repositories finds them ready.
/// - The full `PRAGMA integrity_check` still runs on every launch, but in a
///   utility task after the first frame instead of inside the open. A failure
///   is logged as a fault and kept in `integrityResults`.
///
/// Paths that are not the production files (tests use temporary
/// directories) are opened fresh on every call with the check at open,
/// exactly as before.
nonisolated final class LooprProductionDatabases: @unchecked Sendable {
    static let shared = LooprProductionDatabases()

    /// How long after the launch milestone the deferred check waits, so the
    /// first screens finish their reads before the check walks the file.
    static let integrityCheckDelay: Duration = .seconds(4)

    private static let logger = Logger(subsystem: "com.loopr.ios", category: "Storage")

    private let lock = NSLock()
    private var databases: [String: StorageDatabase] = [:]
    private var openLocks: [String: NSLock] = [:]
    private var results: [String: IntegrityCheckResult] = [:]
    private let productionPaths: Set<String>

    init(productionURLs: [URL]? = nil) {
        let urls = productionURLs ?? Self.defaultProductionURLs()
        productionPaths = Set(urls.map(\.standardizedFileURL.path))
    }

    /// The history file the Bluetooth store writes
    /// (`ProductionBluetoothAdoptionStore.historyDatabaseURL()`) and the
    /// product database (`AppEnvironment.production().storageURL`). Both are
    /// main-actor API, and this registry is reached from detached tasks, so
    /// the two paths are spelled out here; a test keeps them in step.
    static func defaultProductionURLs(fileManager: FileManager = .default) -> [URL] {
        guard let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return []
        }
        return [
            applicationSupport.appendingPathComponent("Loopr", isDirectory: true)
                .appendingPathComponent("loopr.sqlite", isDirectory: false),
            applicationSupport.appendingPathComponent("Loopr.sqlite", isDirectory: false)
        ]
    }

    func isShared(_ url: URL) -> Bool {
        productionPaths.contains(url.standardizedFileURL.path)
    }

    /// The database at `url`. A production file is opened once and shared;
    /// a second caller that arrives while the first open is running waits for
    /// it rather than opening the file again. A failed open is not cached,
    /// so a retry opens the file again.
    func database(at url: URL, applicationVersion: String) throws -> StorageDatabase {
        let path = url.standardizedFileURL.path
        guard productionPaths.contains(path) else {
            return try StorageDatabase(url: url, applicationVersion: applicationVersion)
        }
        let openLock = lockForOpening(path)
        openLock.lock()
        defer { openLock.unlock() }
        if let existing = cached(path) { return existing }
        let database = try StorageDatabase(url: url, applicationVersion: applicationVersion, integrityCheck: .deferred)
        lock.lock()
        databases[path] = database
        lock.unlock()
        scheduleIntegrityCheck(database)
        return database
    }

    /// Opens both production files in parallel, off the main thread. Errors
    /// are left for the real callers, which report them as they always have.
    func prewarmLaunchStores() {
        let version = StorageDatabase.defaultApplicationVersion
        for path in productionPaths {
            Task.detached(priority: .userInitiated) {
                _ = try? self.database(at: URL(fileURLWithPath: path), applicationVersion: version)
            }
        }
    }

    /// Results of the deferred checks that have finished, by file path.
    var integrityResults: [String: IntegrityCheckResult] {
        lock.lock()
        defer { lock.unlock() }
        return results
    }

    private func cached(_ path: String) -> StorageDatabase? {
        lock.lock()
        defer { lock.unlock() }
        return databases[path]
    }

    private func lockForOpening(_ path: String) -> NSLock {
        lock.lock()
        defer { lock.unlock() }
        if let existing = openLocks[path] { return existing }
        let created = NSLock()
        openLocks[path] = created
        return created
    }

    private func scheduleIntegrityCheck(_ database: StorageDatabase) {
        Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(for: Self.integrityCheckDelay)
            let result = database.coldLaunchIntegrityResult
            self?.record(result, for: database.path)
        }
    }

    private func record(_ result: IntegrityCheckResult, for path: String) {
        lock.lock()
        results[path] = result
        lock.unlock()
        let name = URL(fileURLWithPath: path).lastPathComponent
        switch result {
        case .ok:
            Self.logger.info("integrity check passed for \(name, privacy: .public)")
        case .failed(let failure):
            Self.logger.fault("integrity check failed for \(name, privacy: .public): \(failure.messages.joined(separator: "; "), privacy: .public)")
        }
    }
}
