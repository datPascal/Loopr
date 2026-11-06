import Foundation
import Observation
import StorageKit
import AIKit
#if DEBUG
import DomainKit
import JournalKit
import ImportKit
import WorkoutKit
#endif

@MainActor @Observable
final class YourDataBackupCoordinator {
    static let shared = YourDataBackupCoordinator()
    let preferences: FilesBackupPreferences
    private(set) var isRunning = false
    private(set) var error: String?
    private var generation = 0
    init(defaults: UserDefaults? = .standard) { preferences = FilesBackupPreferences(defaults: defaults) }

    func run(exporter: YourDataExporter, ifDue: Bool, now: Date = Date(),
             writer: @escaping @Sendable (URL, Data) throws -> Data? = FilesBackupWriter.save) async {
        guard !isRunning, let bookmark = preferences.bookmark,
              !ifDue || preferences.isDue(at: now) else { return }
        let startingGeneration = generation
        isRunning = true; error = nil
        defer { isRunning = false }
        do {
            let renewed = try await YourDataFileWorker.run(qos: ifDue ? .utility : .userInitiated) {
                let archive = try exporter.prepare(.everything, now: now)
                defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
                return try writer(archive, bookmark)
            }
            guard generation == startingGeneration else { return }
            preferences.completed(at: now, renewedBookmark: renewed)
        } catch {
            guard generation == startingGeneration else { return }
            self.error = "Backup failed. Check the folder in Files, then try again."
        }
    }

    /// A deletion request invalidates callbacks before it waits for pending file
    /// work. The normal deletion cascade then clears every local export.
    func stopForDeletion() async {
        generation += 1
        preferences.clear()
        _ = try? await YourDataFileWorker.run { true }
    }
}

@MainActor @Observable
final class YourDataModel {
    private(set) var inventory: YourDataInventory?
    private(set) var error: String?
    private(set) var isLoading = false
    private(set) var isExporting = false
    private(set) var preparedArchive: URL?
    private var stores: YourDataStores?
    let access: AgentAccessPreferences
    /// The request log behind the "Request log" row. Fixture compositions get an empty one in memory.
    let requestLog: any AgentRequestLogStore
    let backup: YourDataBackupCoordinator
    private let defaults: UserDefaults?
    private let persistent: PersistentProductRepositories?
    /// Onboarding, pairing and empty launches list nothing, as a fresh install does (R3-NEW-3).
    private let startsFresh: Bool
    private(set) var configuredProviders = Set<CoachProvider>()
    private(set) var selectedProvider: CoachProvider?

    init(repositories: ProductRepositoryContainer?) {
        persistent = repositories?.persistent
        startsFresh = repositories?.environment.composition.startsFresh ?? false
        defaults = repositories?.environment.composition == .production ? .standard : nil
        access = AgentAccessPreferences(defaults: defaults)
        if let database = repositories?.persistent?.database, let log = try? SQLiteAgentRequestLog(database: database) { requestLog = log }
        else { requestLog = InMemoryAgentRequestLog() }
        backup = defaults == nil ? YourDataBackupCoordinator(defaults: nil) : .shared
    }
    static func stores(for persistent: PersistentProductRepositories) -> YourDataStores {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return YourDataStores(ledgers: [
            .init(name: "products", database: persistent.database),
            .init(name: "band-history", database: persistent.historyDatabase)
        ], supportDirectory: support, photosDirectory: support.appendingPathComponent("FoodPhotos", isDirectory: true))
    }
    static func preferencesData(defaults: UserDefaults?) throws -> Data {
        let excluded = [FilesBackupPreferences.bookmarkKey]
        let values = Dictionary(uniqueKeysWithValues: Set(ProductRepositoryKeys.allOwnedDefaultsKeys).sorted().filter { !excluded.contains($0) }.compactMap { key in
            defaults?.object(forKey: key).map { (key, $0) }
        })
        return try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
    }
    static func exporter(stores: YourDataStores, defaults: UserDefaults?) throws -> YourDataExporter {
        YourDataExporter(stores: stores, defaultsData: try preferencesData(defaults: defaults), temporaryDirectory: FileManager.default.temporaryDirectory)
    }
    func load() async {
        guard !isLoading else { return }
        isLoading = true; error = nil
        defer { isLoading = false }
        do {
            if stores == nil {
                if let persistent { stores = Self.stores(for: persistent) }
                else {
                    #if DEBUG
                    guard defaults == nil else { throw CocoaError(.fileReadUnknown) }
                    if startsFresh {
                        stores = try await YourDataFileWorker.run { try Self.emptyFixtureStores() }
                    } else {
                        stores = try await FiveTabDataFixture.stores()
                    }
                    #else
                    throw CocoaError(.fileReadUnknown)
                    #endif
                }
            }
            guard let stores else { return }
            inventory = try await YourDataFileWorker.run { try stores.inventory() }
            if defaults != nil {
                configuredProviders = Set(try await LooprAISettingsRuntime.shared.configurations().map(\.provider))
                selectedProvider = try await LooprAISettingsRuntime.shared.selectedConfiguration()?.provider
            }
        } catch { self.error = "Could not read local storage. Try again." }
    }
    func export(_ kind: YourDataExportKind) async {
        guard let stores, !isExporting else { return }
        isExporting = true; error = nil; preparedArchive = nil
        defer { isExporting = false }
        do {
            let exporter = try Self.exporter(stores: stores, defaults: defaults)
            preparedArchive = try await YourDataFileWorker.run { try exporter.prepare(kind) }
        } catch { self.error = "Export failed. Your saved data has not changed." }
    }
    func chooseFolder(_ url: URL) async {
        do {
            let bookmark = try await YourDataFileWorker.run { try FilesBackupWriter.bookmark(for: url) }
            backup.preferences.select(bookmark: bookmark, name: url.lastPathComponent)
            await backupNow()
        } catch { self.error = "Loopr could not use that folder. Choose a folder in Files again." }
    }
    func backupNow() async {
        guard let stores else { return }
        do { await backup.run(exporter: try Self.exporter(stores: stores, defaults: defaults), ifDue: false) }
        catch { self.error = "Could not prepare a backup. Try again." }
    }
    #if DEBUG
    /// Two empty ledgers, the inventory of a fresh install.
    nonisolated static func emptyFixtureStores() throws -> YourDataStores {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loopr-export-empty-\(UUID().uuidString)", isDirectory: true)
        let products = try StorageDatabase(url: root.appendingPathComponent("products.sqlite"))
        let history = try StorageDatabase(url: root.appendingPathComponent("history.sqlite"))
        return YourDataStores(ledgers: [.init(name: "products", database: products), .init(name: "band-history", database: history)],
                              supportDirectory: root, photosDirectory: root.appendingPathComponent("FoodPhotos"))
    }

    nonisolated static func fixtureStores() throws -> YourDataStores {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loopr-export-fixture-\(UUID().uuidString)", isDirectory: true)
        let products = try StorageDatabase(url: root.appendingPathComponent("products.sqlite"))
        let history = try StorageDatabase(url: root.appendingPathComponent("history.sqlite"))
        try history.write { db in
            for day in 1...28 {
                let date = String(format: "2026-09-%02d", day)
                for (key, value) in [("rmssd", 54.0 + Double(day % 9)), ("resting_heart_rate", 57.0 - Double(day % 5)), ("sleep_duration", 440.0 + Double(day % 8) * 5)] {
                    try db.execute(sql: "INSERT INTO metric_series(local_day, metric_key, source, value, updated_at) VALUES (?, ?, 'band', ?, 0)", arguments: [date, key, value])
                }
                try db.execute(sql: "INSERT INTO metric_series(local_day, metric_key, source, value, updated_at) VALUES (?, 'steps', 'apple_health', ?, 0)", arguments: [date, 6500 + day * 100])
            }
        }
        let workouts = try StorageDocumentStore(database: products, namespace: "workouts")
        try workouts.write(WorkoutFixtures.completedRun, key: "workout.\(WorkoutFixtures.completedRun.id.uuidString)")
        let journal = try StorageDocumentStore(database: products, namespace: "journal")
        try journal.write(JournalFixtures.privateEntry, key: "entry.\(JournalFixtures.privateEntry.id.uuidString)")
        let day = DayIdentity(year: 2026, month: 9, day: 28)
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let response = HabitResponse(habitID: HabitID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000902")!),
            behaviorDay: day, behaviorTimeZoneID: "Australia/Perth", answer: .yes,
            firstAnsweredAt: date, firstAnswerSource: .morningCheckIn)
        try journal.write(HabitDayRecord(behaviorDay: day, behaviorTimeZoneID: "Australia/Perth",
            responses: [response], completedAt: date, createdAt: date), key: "habit.day.2026-09-28")
        let importURL = root.appendingPathComponent("physiological_cycles.csv")
        let importCSV = """
        Cycle start time,Cycle timezone,Wake onset,Sleep onset,Asleep duration (min),Recovery score %,Resting heart rate (bpm),Heart rate variability (ms),Day Strain,Sleep need (min)
        2026-08-31 00:15:00,UTC+08:00,2026-08-31 08:00:00,2026-08-31 00:15:00,420,81,52,62,11.4,465
        """
        try Data(importCSV.utf8).write(to: importURL)
        _ = try WHOOPImportStore(database: history).apply(csvs: [importURL])
        try FileManager.default.removeItem(at: importURL)
        let food = try StorageDocumentStore(database: products, namespace: "food")
        // FT-03 replaces these inventory-only meal documents with FoodKit's
        // typed fixture. They are isolated from every production repository.
        for (index, meal) in ["Oats with berries", "Rice and vegetables", "Salmon and potatoes"].enumerated() {
            try food.write(["name": meal, "owner": "Alex", "timeZone": "Australia/Perth"], key: "meal.\(index)")
        }
        let photos = root.appendingPathComponent("FoodPhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4v8AIAARzAdIrgrZtAAAAAElFTkSuQmCC")!
        try image.write(to: photos.appendingPathComponent("fixture.png"))
        return YourDataStores(ledgers: [.init(name: "products", database: products), .init(name: "band-history", database: history)], supportDirectory: root, photosDirectory: root.appendingPathComponent("FoodPhotos"))
    }
    #endif
}
