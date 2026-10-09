import Foundation
import DomainKit
import StorageKit

/// The durable schema owned by ProfileKit.  StorageKit owns the database
/// file and its base migrations; this migrator owns only profile data and is
/// deliberately separate so it can be applied again on every launch.
public enum ProfileStorageMigrations {
    public static let migrationIdentifier = "profile-001-canonical"
    public static let schemaVersion = 1

    private static let profileTable = "profile"
    private static let unitsTable = "profile_units"
    private static let goalsTable = "profile_goals"

    public static func makeMigrator(applicationVersion: String) -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration(migrationIdentifier) { db in
            try db.create(table: profileTable) { table in
                table.column("id", .text).primaryKey()
                table.column("display_name", .text).notNull()
                table.column("birth_year", .integer)
                table.column("biological_sex", .text)
                table.column("height_centimeters", .double)
                table.column("weight_kilograms", .double)
                table.column("timezone_identifier", .text)
                table.column("created_at", .double).notNull()
                table.column("updated_at", .double).notNull()
            }

            try db.create(table: unitsTable) { table in
                table.column("profile_id", .text)
                    .primaryKey()
                    .references(profileTable, onDelete: .cascade)
                table.column("unit_system", .text).notNull()
                table.column("updated_at", .double).notNull()
            }

            try db.create(table: goalsTable) { table in
                table.column("id", .text).primaryKey()
                // A goal can be captured before the profile stage is
                // complete.  Nil is intentional and differs from a missing
                // goal row; profile reset still removes both forms.
                table.column("profile_id", .text)
                    .references(profileTable, onDelete: .cascade)
                table.column("type", .text).notNull()
                table.column("target", .double).notNull()
                table.column("unit", .text).notNull()
                table.column("is_enabled", .integer).notNull()
                table.column("updated_at", .double).notNull()
            }

            try migrateLegacyRows(in: db)

            // StorageDatabase normally creates this ledger first.  The guard
            // keeps the ProfileKit migration usable in an isolated fixture.
            if try db.tableExists(StorageMigrations.metadataTable) {
                try db.execute(
                    sql: """
                    INSERT OR REPLACE INTO storage_schema_metadata
                        (migration_identifier, schema_version, application_version)
                    VALUES (?, ?, ?)
                    """,
                    arguments: [migrationIdentifier, String(schemaVersion), applicationVersion]
                )
            }
        }
        return migrator
    }

    /// Applies the ProfileKit migration.  GRDB records the migration
    /// identifier in `grdb_migrations`, making this operation idempotent.
    public static func apply(to database: StorageDatabase) throws {
        try makeMigrator(applicationVersion: database.applicationVersion).migrate(database.pool)
    }

    private static func migrateLegacyRows(in db: Database) throws {
        // ProfileKit did not previously own a durable schema.  These legacy
        // tables are accepted for databases created by an early integration
        // build and are dropped only after their rows have been copied.
        if try db.tableExists("profile_legacy") {
            try db.execute(
                sql: """
                INSERT OR IGNORE INTO profile
                    (id, display_name, birth_year, biological_sex,
                     height_centimeters, weight_kilograms, timezone_identifier,
                     created_at, updated_at)
                SELECT id, display_name, birth_year, biological_sex,
                       height_centimeters, weight_kilograms, timezone_identifier,
                       created_at, updated_at
                FROM profile_legacy
                """
            )
            try db.execute(
                sql: """
                INSERT OR IGNORE INTO profile_units (profile_id, unit_system, updated_at)
                SELECT id, unit_system, updated_at FROM profile_legacy
                """
            )
            try db.execute(sql: "DROP TABLE profile_legacy")
        }

        if try db.tableExists("profile_units_legacy") {
            try db.execute(
                sql: """
                INSERT OR IGNORE INTO profile_units (profile_id, unit_system, updated_at)
                SELECT profile_id, unit_system, updated_at FROM profile_units_legacy
                """
            )
            try db.execute(sql: "DROP TABLE profile_units_legacy")
        }

        if try db.tableExists("profile_goals_legacy") {
            try db.execute(
                sql: """
                INSERT OR IGNORE INTO profile_goals
                    (id, profile_id, type, target, unit, is_enabled, updated_at)
                SELECT id, profile_id, type, target, unit, is_enabled, updated_at
                FROM profile_goals_legacy
                """
            )
            try db.execute(sql: "DROP TABLE profile_goals_legacy")
        }
    }
}

/// GRDB-backed ProfileKit repository.  The actor serializes repository-level
/// read/modify/write operations while StorageDatabase serializes SQLite
/// writes, so callers can safely share one instance across app scenes.
public actor SQLiteProfileRepository: ProfileRepository, GoalsRepository {
    private let database: StorageDatabase
    private let dateProvider: any DateProviding
    private let uuidProvider: any UUIDProviding

    public init(
        database: StorageDatabase,
        dateProvider: any DateProviding = SystemDateProvider(),
        uuidProvider: any UUIDProviding = SystemUUIDProvider()
    ) throws {
        self.database = database
        self.dateProvider = dateProvider
        self.uuidProvider = uuidProvider
        try ProfileStorageMigrations.apply(to: database)
    }

    public init(
        url: URL,
        applicationVersion: String = StorageDatabase.defaultApplicationVersion,
        dateProvider: any DateProviding = SystemDateProvider(),
        uuidProvider: any UUIDProviding = SystemUUIDProvider()
    ) throws {
        let database = try StorageDatabase(url: url, applicationVersion: applicationVersion)
        self.database = database
        self.dateProvider = dateProvider
        self.uuidProvider = uuidProvider
        try ProfileStorageMigrations.apply(to: database)
    }

    public func readProfile() async throws -> Profile? {
        try readProfileSync()
    }

    public func saveProfile(_ draft: ProfileDraft) async throws -> Profile {
        let now = dateProvider.now()
        let existing = try readProfileSync()
        let id: UUID
        if let existingID = existing?.id {
            id = existingID
        } else {
            id = await uuidProvider.nextUUID()
        }
        let createdAt = existing?.createdAt ?? now
        let currentYear = Calendar(identifier: .gregorian).component(.year, from: now)
        let validated = try ProfileValidator.makeProfile(
            from: draft,
            id: id,
            now: now,
            currentYear: currentYear
        )
        let profile = Profile(
            id: validated.id,
            displayName: validated.displayName,
            birthYear: validated.birthYear,
            biologicalSex: validated.biologicalSex,
            heightCentimeters: validated.heightCentimeters,
            weightKilograms: validated.weightKilograms,
            timezoneIdentifier: validated.timezoneIdentifier,
            unitSystem: validated.unitSystem,
            createdAt: createdAt,
            updatedAt: now
        )

        try database.write { db in
            try db.execute(
                sql: """
                INSERT INTO profile
                    (id, display_name, birth_year, biological_sex,
                     height_centimeters, weight_kilograms, timezone_identifier,
                     created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    display_name = excluded.display_name,
                    birth_year = excluded.birth_year,
                    biological_sex = excluded.biological_sex,
                    height_centimeters = excluded.height_centimeters,
                    weight_kilograms = excluded.weight_kilograms,
                    timezone_identifier = excluded.timezone_identifier,
                    updated_at = excluded.updated_at
                """,
                arguments: profileArguments(profile)
            )
            try db.execute(
                sql: """
                INSERT INTO profile_units
                    (profile_id, unit_system, updated_at)
                VALUES (?, ?, ?)
                ON CONFLICT(profile_id) DO UPDATE SET
                    unit_system = excluded.unit_system,
                    updated_at = excluded.updated_at
                """,
                arguments: [profile.id.uuidString, profile.unitSystem.rawValue, profile.updatedAt.timeIntervalSince1970]
            )
        }
        return profile
    }

    public func resetProfile() async throws {
        try database.write { db in
            // Delete goals explicitly even though the foreign key also
            // cascades; this handles orphan goals saved before profile setup.
            try db.execute(sql: "DELETE FROM profile_goals")
            try db.execute(sql: "DELETE FROM profile")
        }
    }

    public func deleteAllData() async throws {
        try await resetProfile()
    }

    public func readGoals() async throws -> [Goal] {
        try readGoalsSync()
    }

    public func saveGoal(
        type: GoalType,
        target: Double,
        unit: String,
        isEnabled: Bool = true
    ) async throws -> Goal {
        try GoalValidator.validate(target: target, unit: unit)
        let trimmedUnit = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = dateProvider.now()
        let profileID = try readProfileSync()?.id.uuidString
        let goal = Goal(
            id: await uuidProvider.nextUUID(),
            type: type,
            target: target,
            unit: trimmedUnit,
            isEnabled: isEnabled,
            updatedAt: now
        )

        try database.write { db in
            if let profileID {
                try db.execute(
                    sql: "DELETE FROM profile_goals WHERE profile_id = ? AND type = ?",
                    arguments: [profileID, type.rawValue]
                )
            } else {
                try db.execute(
                    sql: "DELETE FROM profile_goals WHERE profile_id IS NULL AND type = ?",
                    arguments: [type.rawValue]
                )
            }
            try db.execute(
                sql: """
                INSERT INTO profile_goals
                    (id, profile_id, type, target, unit, is_enabled, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    goal.id.uuidString,
                    profileID,
                    goal.type.rawValue,
                    goal.target,
                    goal.unit,
                    goal.isEnabled ? 1 : 0,
                    goal.updatedAt.timeIntervalSince1970
                ]
            )
        }
        return goal
    }

    public func deleteGoals() async throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM profile_goals")
        }
    }

    public func exportSnapshot() async throws -> ProfileStoreSnapshot {
        ProfileStoreSnapshot(
            schemaVersion: ProfileSchemaMigration.currentVersion,
            profile: try readProfileSync(),
            goals: try readGoalsSync()
        )
    }

    public func restoreSnapshot(_ snapshot: ProfileStoreSnapshot) async throws {
        let migrated = try ProfileSchemaMigration.migrate(snapshot)
        if let profile = migrated.profile {
            try ProfileValidator.validate(profile.draft(), currentYear: Calendar(identifier: .gregorian).component(.year, from: profile.updatedAt))
        }
        for goal in migrated.goals {
            try GoalValidator.validate(target: goal.target, unit: goal.unit)
        }

        try database.write { db in
            try db.execute(sql: "DELETE FROM profile_goals")
            try db.execute(sql: "DELETE FROM profile")
            if let profile = migrated.profile {
                try db.execute(
                    sql: """
                    INSERT INTO profile
                        (id, display_name, birth_year, biological_sex,
                         height_centimeters, weight_kilograms, timezone_identifier,
                         created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: profileArguments(profile)
                )
                try db.execute(
                    sql: "INSERT INTO profile_units (profile_id, unit_system, updated_at) VALUES (?, ?, ?)",
                    arguments: [profile.id.uuidString, profile.unitSystem.rawValue, profile.updatedAt.timeIntervalSince1970]
                )
            }
            for goal in migrated.goals {
                try db.execute(
                    sql: """
                    INSERT INTO profile_goals
                        (id, profile_id, type, target, unit, is_enabled, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        goal.id.uuidString,
                        migrated.profile?.id.uuidString,
                        goal.type.rawValue,
                        goal.target,
                        goal.unit,
                        goal.isEnabled ? 1 : 0,
                        goal.updatedAt.timeIntervalSince1970
                    ]
                )
            }
        }
    }

    private func readProfileSync() throws -> Profile? {
        try database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT p.id, p.display_name, p.birth_year, p.biological_sex,
                       p.height_centimeters, p.weight_kilograms,
                       p.timezone_identifier, u.unit_system,
                       p.created_at, p.updated_at
                FROM profile AS p
                INNER JOIN profile_units AS u
                    ON u.profile_id = p.id
                LIMIT 1
                """
            ) else {
                return nil
            }

            guard
                let idText: String = row["id"],
                let id = UUID(uuidString: idText),
                let displayName: String = row["display_name"],
                let unitRaw: String = row["unit_system"],
                let unitSystem = UnitSystem(rawValue: unitRaw),
                let createdSeconds: Double = row["created_at"],
                let updatedSeconds: Double = row["updated_at"]
            else {
                throw ProfileRepositoryError.migrationFailed("Profile row is missing canonical fields.")
            }

            let birthYear = (row["birth_year"] as Int64?).map(Int.init)
            let biologicalSex = (row["biological_sex"] as String?).flatMap(BiologicalSex.init(rawValue:))
            if row["biological_sex"] != nil && biologicalSex == nil {
                throw ProfileRepositoryError.migrationFailed("Profile row contains an unknown biological sex.")
            }
            let timezone = row["timezone_identifier"] as String?
            if let timezone, TimeZone(identifier: timezone) == nil {
                throw ProfileRepositoryError.migrationFailed("Profile row contains an unknown timezone.")
            }
            return Profile(
                id: id,
                displayName: displayName,
                birthYear: birthYear,
                biologicalSex: biologicalSex,
                heightCentimeters: row["height_centimeters"] as Double?,
                weightKilograms: row["weight_kilograms"] as Double?,
                timezoneIdentifier: timezone,
                unitSystem: unitSystem,
                createdAt: Date(timeIntervalSince1970: createdSeconds),
                updatedAt: Date(timeIntervalSince1970: updatedSeconds)
            )
        }
    }

    private func readGoalsSync() throws -> [Goal] {
        try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT id, type, target, unit, is_enabled, updated_at
                FROM profile_goals
                ORDER BY type ASC, id ASC
                """
            ).map { row in
                guard
                    let idText: String = row["id"],
                    let id = UUID(uuidString: idText),
                    let typeRaw: String = row["type"],
                    let type = GoalType(rawValue: typeRaw),
                    let target: Double = row["target"],
                    let unit: String = row["unit"],
                    let enabled: Int64 = row["is_enabled"],
                    let updatedSeconds: Double = row["updated_at"]
                else {
                    throw ProfileRepositoryError.migrationFailed("Goal row is missing canonical fields.")
                }
                guard enabled == 0 || enabled == 1 else {
                    throw ProfileRepositoryError.migrationFailed("Goal row contains an invalid enabled state.")
                }
                try GoalValidator.validate(target: target, unit: unit)
                return Goal(
                    id: id,
                    type: type,
                    target: target,
                    unit: unit,
                    isEnabled: enabled == 1,
                    updatedAt: Date(timeIntervalSince1970: updatedSeconds)
                )
            }
        }
    }

    private func profileArguments(_ profile: Profile) -> StatementArguments {
        [
            profile.id.uuidString,
            profile.displayName,
            profile.birthYear.map { Int64($0) },
            profile.biologicalSex?.rawValue,
            profile.heightCentimeters,
            profile.weightKilograms,
            profile.timezoneIdentifier,
            profile.createdAt.timeIntervalSince1970,
            profile.updatedAt.timeIntervalSince1970
        ]
    }
}

// Kept in one place so SQL cannot drift between migration and repository
// operations.  The names are public only to make schema assertions possible
// in package integration tests; consumers should use the repository APIs.
public extension ProfileStorageMigrations {
    static var profileTableForTesting: String { "profile" }
    static var unitsTableForTesting: String { "profile_units" }
    static var goalsTableForTesting: String { "profile_goals" }
}
