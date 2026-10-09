import Foundation
import Testing
import DomainKit
import ProfileKit
import StorageKit

struct SQLiteProfileRepositoryTests {
    @Test
    func reopenPreservesProfileGoalsAndMigrationIsIdempotent() async throws {
        let url = try SQLiteProfileTestFixture.makeURL(named: "reopen")
        defer { SQLiteProfileTestFixture.remove(url) }

        let firstDatabase = try StorageDatabase(url: url, applicationVersion: "1.0 (1)")
        let repository = try SQLiteProfileRepository(
            database: firstDatabase,
            dateProvider: SQLiteFixedDateProvider(),
            uuidProvider: SQLiteFixedUUIDProvider(values: [
                UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
                UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
            ])
        )
        let expectedProfile = try await repository.saveProfile(
            ProfileDraft(
                displayName: " Ari ",
                birthYear: 1990,
                heightCentimeters: 180,
                timezoneIdentifier: "UTC",
                unitSystem: .metric
            )
        )
        let expectedGoal = try await repository.saveGoal(type: .steps, target: 10_000, unit: "steps")
        #expect(try firstDatabase.readInteger(
            sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = ?",
            arguments: [ProfileStorageMigrations.migrationIdentifier]
        ) == 1)
        #expect(try firstDatabase.schemaMetadata().contains {
            $0.migrationIdentifier == ProfileStorageMigrations.migrationIdentifier
        })
        try firstDatabase.databasePool.close()

        let reopenedDatabase = try StorageDatabase(url: url, applicationVersion: "1.0 (1)")
        let reopenedRepository = try SQLiteProfileRepository(database: reopenedDatabase)
        #expect(try await reopenedRepository.readProfile() == expectedProfile)
        #expect(try await reopenedRepository.readGoals() == [expectedGoal])
        #expect(try reopenedDatabase.readInteger(
            sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = ?",
            arguments: [ProfileStorageMigrations.migrationIdentifier]
        ) == 1)
        #expect(try reopenedDatabase.hasPendingMigrations() == false)
        try reopenedDatabase.databasePool.close()
    }

    @Test
    func legacyRowsMigrateWithoutDataLossAndApplyingAgainIsIdempotent() async throws {
        let url = try SQLiteProfileTestFixture.makeURL(named: "legacy")
        defer { SQLiteProfileTestFixture.remove(url) }

        let database = try StorageDatabase(url: url, applicationVersion: "1.0 (1)")
        let profileID = "00000000-0000-0000-0000-000000000201"
        let goalID = "00000000-0000-0000-0000-000000000202"
        try database.write { db in
            try db.execute(sql: """
                CREATE TABLE profile_legacy (
                    id TEXT PRIMARY KEY,
                    display_name TEXT NOT NULL,
                    birth_year INTEGER,
                    biological_sex TEXT,
                    height_centimeters REAL,
                    weight_kilograms REAL,
                    timezone_identifier TEXT,
                    unit_system TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE TABLE profile_goals_legacy (
                    id TEXT PRIMARY KEY,
                    profile_id TEXT,
                    type TEXT NOT NULL,
                    target REAL NOT NULL,
                    unit TEXT NOT NULL,
                    is_enabled INTEGER NOT NULL,
                    updated_at REAL NOT NULL
                )
                """)
            try db.execute(
                sql: """
                INSERT INTO profile_legacy
                    (id, display_name, birth_year, biological_sex,
                     height_centimeters, weight_kilograms, timezone_identifier,
                     unit_system, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [profileID, "Legacy", 1988, "undisclosed", 172.5, nil, "UTC", "imperial", 1_700_000_000, 1_700_000_100]
            )
            try db.execute(
                sql: "INSERT INTO profile_goals_legacy (id, profile_id, type, target, unit, is_enabled, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
                arguments: [goalID, profileID, "sleep", 8.0, "hours", 1, 1_700_000_100]
            )
        }

        let repository = try SQLiteProfileRepository(database: database)
        let profile = try await repository.readProfile()
        #expect(profile?.id == UUID(uuidString: profileID))
        #expect(profile?.displayName == "Legacy")
        #expect(profile?.birthYear == 1988)
        #expect(profile?.heightCentimeters == 172.5)
        #expect(profile?.weightKilograms == nil)
        #expect(profile?.unitSystem == .imperial)
        #expect(try await repository.readGoals().map(\.id) == [UUID(uuidString: goalID)!])
        #expect(try database.tableNames().contains("profile_legacy") == false)
        #expect(try database.tableNames().contains("profile_goals_legacy") == false)

        try ProfileStorageMigrations.apply(to: database)
        #expect(try database.readInteger(
            sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = ?",
            arguments: [ProfileStorageMigrations.migrationIdentifier]
        ) == 1)
        #expect(try await repository.readProfile()?.displayName == "Legacy")
        try database.databasePool.close()
    }

    @Test
    func resetClearsOwnedDataButLeavesUnrelatedBandIdentityData() async throws {
        let url = try SQLiteProfileTestFixture.makeURL(named: "reset-isolation")
        defer { SQLiteProfileTestFixture.remove(url) }

        let database = try StorageDatabase(url: url, applicationVersion: "1.0 (1)")
        try database.write { db in
            try db.execute(sql: "CREATE TABLE device_identity_fixture (id TEXT PRIMARY KEY, name TEXT NOT NULL)")
            try db.execute(sql: "INSERT INTO device_identity_fixture (id, name) VALUES (?, ?)", arguments: ["band-1", "Loopr band"])
        }
        let repository = try SQLiteProfileRepository(
            database: database,
            dateProvider: SQLiteFixedDateProvider(),
            uuidProvider: SQLiteFixedUUIDProvider()
        )
        _ = try await repository.saveProfile(ProfileDraft(displayName: "Ari", unitSystem: .metric))
        _ = try await repository.saveGoal(type: .sleep, target: 8, unit: "hours")

        try await repository.resetProfile()
        #expect(try await repository.readProfile() == nil)
        #expect(try await repository.readGoals().isEmpty)
        #expect(try database.readInteger(sql: "SELECT COUNT(*) FROM profile") == 0)
        #expect(try database.readInteger(sql: "SELECT COUNT(*) FROM profile_units") == 0)
        #expect(try database.readInteger(sql: "SELECT COUNT(*) FROM profile_goals") == 0)
        #expect(try database.readInteger(sql: "SELECT COUNT(*) FROM device_identity_fixture") == 1)
        #expect(try database.readString(sql: "SELECT name FROM device_identity_fixture WHERE id = 'band-1'") == "Loopr band")

        try await repository.deleteAllData()
        #expect(try database.readInteger(sql: "SELECT COUNT(*) FROM device_identity_fixture") == 1)
        try database.databasePool.close()
    }
}

private enum SQLiteProfileTestFixture {
    static func makeURL(named name: String) throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp/loopr-profile-" + name + "-" + UUID().uuidString + ".sqlite")
        remove(url)
        return url
    }

    static func remove(_ url: URL) {
        let manager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            try? manager.removeItem(atPath: url.path + suffix)
        }
    }
}

private struct SQLiteFixedDateProvider: DateProviding {
    func now() -> Date { Date(timeIntervalSince1970: 1_700_000_000) }
}

private actor SQLiteFixedUUIDProvider: UUIDProviding {
    private var values: [UUID]

    init(values: [UUID] = [UUID(uuidString: "00000000-0000-0000-0000-000000000301")!]) {
        self.values = values
    }

    func nextUUID() -> UUID {
        if values.count > 1 { return values.removeFirst() }
        return values[0]
    }
}
