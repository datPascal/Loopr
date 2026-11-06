import CryptoKit
import Foundation
import StorageKit
import XCTest

/// TestFlight build 21 (commit 12464281) shipped every migration up to `storage-015-food-weight`. A database it wrote
/// must open in this build with no pending migration, gain every table the current schema requires, and keep every row
/// it held, byte for byte. The seed below is written through SQL in the shape build 21 wrote: the column lists come from
/// `FoodStore.confirm`, `FoodStore.saveWeight`, `TrainStore.insert` and `StorageDocumentStore.writeData` at that commit,
/// and the payloads are the JSON those stores wrote. StorageKit treats a payload as opaque bytes, so what this suite
/// proves is that the upgrade leaves it alone. `UpgradeFromBuild21AppTests` decodes the same kinds of payload with the
/// current types and runs the habit migration.
///
/// The new tables are not listed here. They are whatever a fresh database has today, so a migration added later is
/// covered without editing this file.
final class UpgradeFromBuild21Tests: XCTestCase {
    /// The registry at build 21, in order. A rename, removal or reorder of any of them breaks every shipped database.
    private static let build21Migrations = [
        "storage-001-schema-metadata", "storage-002-sensor-ledger", "storage-003-gen5-beta",
        "storage-004-release-action-audit", "storage-005-analytics-revision", "storage-006-analytics-range-revision",
        "storage-007-v24-adc-fields", "storage-008-metric-series-source", "storage-009-v24-skin-temperature",
        "storage-010-food", "storage-011-food-overview", "storage-012-food-capture", "storage-013-food-review",
        "storage-014-train", "storage-015-food-weight"
    ]
    private static let build21Version = "1.0 (21)"
    private static let currentVersion = "1.0 (22)"
    /// Tables the seed fills. Every one of them is compared row for row before and after the upgrade.
    private static let seededTables = ["food_meal", "food_photo", "food_weight", "workout_session", "workout_set",
                                       StorageDocumentStore.documentTable]

    private typealias Dump = [String: [[DatabaseValue]]]

    private var urls: [URL] = []

    override func tearDown() {
        for url in urls {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }
        urls = []
        super.tearDown()
    }

    private func makeURL(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("build21-\(name)-\(UUID().uuidString).sqlite")
        urls.append(url)
        return url
    }

    /// A database exactly as build 21 left it: migrations up to 015 only, then the seed. Returns what the seed wrote.
    private func makeBuild21Database() throws -> (url: URL, seeded: Dump, ledger: [[DatabaseValue]]) {
        let url = makeURL("old")
        // The configuration `StorageDatabase` opens with, so the file is in WAL mode as build 21 left it.
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.journalMode = .wal
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        try StorageMigrations.makeMigrator(applicationVersion: Self.build21Version).migrate(queue, upTo: "storage-015-food-weight")
        try queue.write { db in try Build21Seed.write(into: db) }
        let seeded = try queue.read { db in try Self.dump(db) }
        let ledger = try queue.read { db in try Self.ledger(db) }
        try queue.close()
        return (url, seeded, ledger)
    }

    /// GRDB's own ledger, in the order the migrations ran.
    private static func applied(_ db: Database) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
    }

    /// Build 21's rows in `storage_schema_metadata`: identifier, schema version and the application version that wrote them.
    private static func ledger(_ db: Database) throws -> [[DatabaseValue]] {
        try Row.fetchAll(db, sql: "SELECT * FROM storage_schema_metadata ORDER BY rowid").map { Array($0.databaseValues) }
    }

    private static func dump(_ db: Database) throws -> Dump {
        var result: Dump = [:]
        for table in seededTables {
            result[table] = try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY rowid").map { Array($0.databaseValues) }
        }
        return result
    }

    // MARK: The seed is a build 21 database

    func testTheSeedStartsFromExactlyTheBuild21Schema() throws {
        let (url, seeded, _) = try makeBuild21Database()
        let queue = try DatabaseQueue(path: url.path)
        defer { try? queue.close() }
        let migrator = StorageMigrations.makeMigrator(applicationVersion: Self.currentVersion)
        let registered = migrator.migrations
        XCTAssertEqual(Array(registered.prefix(Self.build21Migrations.count)), Self.build21Migrations,
                       "a shipped migration was renamed, removed or reordered")
        XCTAssertGreaterThan(registered.count, Self.build21Migrations.count, "this build adds migrations after 015")
        try queue.read { db in
            XCTAssertEqual(try Self.applied(db), Self.build21Migrations)
            XCTAssertFalse(try db.tableExists("routine_protocol"), "a build 21 database has no routine tables yet")
            XCTAssertTrue(try db.tableExists("food_weight"))
        }
        // Everything the brief lists is in the seed.
        XCTAssertEqual(seeded["food_meal"]?.count, 1)
        XCTAssertEqual(seeded["food_photo"]?.count, 1)
        XCTAssertEqual(seeded["food_weight"]?.count, 1)
        XCTAssertEqual(seeded["workout_session"]?.count, 1)
        XCTAssertEqual(seeded["workout_set"]?.count, 3)
        XCTAssertEqual(seeded[StorageDocumentStore.documentTable]?.count, Build21Seed.documentCount)
    }

    // MARK: The upgrade

    func testABuild21DatabaseOpensWithNoPendingMigrationAndTheCurrentSchema() throws {
        let (url, _, _) = try makeBuild21Database()
        let upgraded = try StorageDatabase(url: url, applicationVersion: Self.currentVersion)
        defer { try? upgraded.databasePool.close() }

        XCTAssertFalse(try upgraded.hasPendingMigrations())
        let registered = upgraded.migrator.migrations
        try upgraded.read { db in
            XCTAssertEqual(try Self.applied(db), registered, "every registered migration is applied once, in order")
        }

        // The current required set, taken from a fresh database instead of a list that would go stale.
        let fresh = try StorageDatabase(url: makeURL("fresh"), applicationVersion: Self.currentVersion)
        defer { try? fresh.databasePool.close() }
        let freshSnapshot = try fresh.schemaSnapshot()
        let upgradedSnapshot = try upgraded.schemaSnapshot()
        XCTAssertFalse(freshSnapshot.tableNames.isEmpty)
        for table in freshSnapshot.tableNames.sorted() {
            XCTAssertTrue(upgradedSnapshot.tableNames.contains(table), "\(table) was not created on upgrade")
        }
        // The document table is created on first use, so only the upgraded file has it. Everything else must match a
        // fresh install column for column, constraint for constraint.
        let withoutDocuments = StorageSchemaSnapshot(tables: upgradedSnapshot.tables.filter { $0.name != StorageDocumentStore.documentTable })
        XCTAssertTrue(withoutDocuments.isEquivalent(to: freshSnapshot), "an upgraded schema differs from a fresh install")
        XCTAssertNotNil(upgradedSnapshot.table(named: StorageDocumentStore.documentTable))

        // The same check the product runs on export: every required table is present and the file passes its integrity check.
        let exported = FileManager.default.temporaryDirectory.appendingPathComponent("build21-export-\(UUID().uuidString).sqlite")
        urls.append(exported)
        XCTAssertNoThrow(try upgraded.export(to: exported))
        XCTAssertTrue(upgraded.coldLaunchIntegrityResult.isHealthy)
    }

    func testEverySeededRowSurvivesTheUpgradeWithTheSameValues() throws {
        let (url, seeded, _) = try makeBuild21Database()
        let upgraded = try StorageDatabase(url: url, applicationVersion: Self.currentVersion)
        defer { try? upgraded.databasePool.close() }

        let after = try upgraded.read { db in try Self.dump(db) }
        for table in Self.seededTables {
            XCTAssertEqual(after[table], seeded[table], "\(table) changed in the upgrade")
        }

        try upgraded.read { db in
            // The meal, its photo and the weight entry.
            let meal = try XCTUnwrap(try Row.fetchOne(db, sql: "SELECT * FROM food_meal"))
            XCTAssertEqual(meal["id"] as String, Build21Seed.mealID)
            XCTAssertEqual(meal["local_day"] as String, "2026-10-20")
            XCTAssertEqual(meal["occurred_at"] as Double, Build21Seed.noon)
            XCTAssertEqual(meal["revision"] as Int, 1)
            XCTAssertEqual(meal["schema_version"] as Int, 1)
            let mealPayload = try XCTUnwrap(JSONSerialization.jsonObject(with: meal["payload"] as Data) as? [String: Any])
            let items = try XCTUnwrap(mealPayload["items"] as? [[String: Any]])
            XCTAssertEqual(items.compactMap { $0["name"] as? String }, ["Chicken salad", "Sourdough"])
            let photo = try XCTUnwrap(try Row.fetchOne(db, sql: "SELECT * FROM food_photo"))
            XCTAssertEqual(photo["meal_id"] as String, Build21Seed.mealID)
            XCTAssertEqual(photo["bytes"] as Data, Build21Seed.photoBytes)
            XCTAssertEqual(photo["sha256"] as String, Build21Seed.photoSHA256)
            let weight = try XCTUnwrap(try Row.fetchOne(db, sql: "SELECT * FROM food_weight"))
            XCTAssertEqual(weight["id"] as String, Build21Seed.weightID)
            XCTAssertEqual(weight["measured_at"] as Double, Build21Seed.noon)
            let weightPayload = try XCTUnwrap(JSONSerialization.jsonObject(with: weight["payload"] as Data) as? [String: Any])
            XCTAssertEqual(weightPayload["kilograms"] as? Double, 78.4)

            // The completed workout and its sets, in logged order.
            let session = try XCTUnwrap(try Row.fetchOne(db, sql: "SELECT * FROM workout_session"))
            XCTAssertEqual(session["id"] as String, Build21Seed.sessionID)
            XCTAssertEqual(session["status"] as String, "completed")
            XCTAssertEqual(session["local_day"] as String, "2026-10-20")
            let sets = try Row.fetchAll(db, sql: "SELECT * FROM workout_set WHERE session_id = ? ORDER BY position", arguments: [Build21Seed.sessionID])
            XCTAssertEqual(sets.map { $0["id"] as String }, Build21Seed.setIDs)
            XCTAssertEqual(sets.map { $0["position"] as Int }, [0, 1, 2])
            XCTAssertEqual(sets.map { $0["exercise_key"] as String }, Array(repeating: "barbell-bench-press", count: 3))

            // Documents: two habit questions with a week of answers, one coach chat, one settings snapshot.
            func documents(_ namespace: String, prefix: String) throws -> [String] {
                try String.fetchAll(db, sql: "SELECT document_key FROM \(StorageDocumentStore.documentTable) WHERE namespace = ? AND document_key LIKE ? ORDER BY document_key",
                                    arguments: [namespace, prefix + "%"])
            }
            XCTAssertEqual(try documents("journal", prefix: "habit.definition.").count, 2)
            XCTAssertEqual(try documents("journal", prefix: "habit.day."), Build21Seed.dayKeys.map { "habit.day.\($0)" })
            XCTAssertEqual(try documents("coach", prefix: "chat."), ["chat.\(Build21Seed.chatID)"])
            XCTAssertEqual(try documents("settings", prefix: "snapshot"), ["snapshot"])
        }

        // Read back through the document store the app uses.
        let settings = try StorageDocumentStore(database: upgraded, namespace: "settings")
        let snapshot = try XCTUnwrap(try settings.readData(key: "snapshot"))
        XCTAssertEqual(snapshot, try Build21Seed.settingsPayload())
        let journal = try StorageDocumentStore(database: upgraded, namespace: "journal")
        for (index, key) in Build21Seed.dayKeys.enumerated() {
            let record = try XCTUnwrap(try journal.readData(key: "habit.day.\(key)"))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: record) as? [String: Any])
            XCTAssertEqual((object["responses"] as? [[String: Any]])?.count, 2, "day \(key) lost an answer")
            XCTAssertEqual(record, try Build21Seed.dayPayload(index: index))
        }
    }

    func testReopeningTheUpgradedDatabaseAgainChangesNothingAndDuplicatesNothing() throws {
        let (url, seeded, build21Ledger) = try makeBuild21Database()
        let first = try StorageDatabase(url: url, applicationVersion: Self.currentVersion)
        let applied = try first.read { db in try Self.applied(db) }
        let schema = try first.schemaSnapshot()
        let metadata = try first.schemaMetadata()
        let counts = try first.tableRowCounts()
        try first.databasePool.close()

        let second = try StorageDatabase(url: url, applicationVersion: Self.currentVersion)
        defer { try? second.databasePool.close() }
        XCTAssertFalse(try second.hasPendingMigrations())
        XCTAssertEqual(try second.read { db in try Self.applied(db) }, applied)
        XCTAssertEqual(try second.schemaSnapshot(), schema)
        XCTAssertEqual(try second.schemaMetadata(), metadata, "a migration ran twice or its ledger row was rewritten")
        XCTAssertEqual(Set(metadata.map(\.migrationIdentifier)).count, metadata.count, "a ledger row is duplicated")
        XCTAssertEqual(try second.tableRowCounts(), counts)
        XCTAssertEqual(try second.read { db in try Self.dump(db) }, seeded, "a seeded row changed or was duplicated")

        // Build 21's own ledger rows are still the first rows, with the application version that wrote them.
        let ledger = try second.read { db in try Self.ledger(db) }
        XCTAssertEqual(Array(ledger.prefix(build21Ledger.count)), build21Ledger, "the upgrade rewrote a build 21 ledger row")
        XCTAssertFalse(build21Ledger.isEmpty)

        // Every migration added since carries this build's version. Which ones exist is read from the registry.
        let added = second.migrator.migrations.dropFirst(Self.build21Migrations.count)
        let byIdentifier = Dictionary(uniqueKeysWithValues: metadata.map { ($0.migrationIdentifier, $0.applicationVersion) })
        let recorded = added.filter { byIdentifier[$0] != nil }
        XCTAssertGreaterThanOrEqual(recorded.count, 5, "016 routine, 017 labs, 019 food longevity, 020 capacity and 021 experiments")
        for identifier in recorded {
            XCTAssertEqual(byIdentifier[identifier], Self.currentVersion, "\(identifier) carries the wrong application version")
        }
    }
}

/// What a build 21 install held after a week of use, written the way build 21 wrote it.
private enum Build21Seed {
    static let timeZone = "Australia/Perth"
    /// 2026-10-20 12:00 in Perth (04:00 UTC), in seconds since 1970. SQL columns hold this.
    static let noon = 1_792_468_800.0
    /// JSON payloads hold `Date` in seconds since 2001-01-01, the default `JSONEncoder` strategy.
    private static let referenceDateOffset = 978_307_200.0
    static func reference(_ unix: Double) -> Double { unix - referenceDateOffset }

    static let mealID = "4D1B6C0E-0000-4000-8000-000000000001"
    static let photoID = "4D1B6C0E-0000-4000-8000-000000000002"
    static let weightID = "4D1B6C0E-0000-4000-8000-000000000003"
    static let sessionID = "4D1B6C0E-0000-4000-8000-000000000004"
    static let lineID = "4D1B6C0E-0000-4000-8000-000000000005"
    static let setIDs = ["4D1B6C0E-0000-4000-8000-000000000011", "4D1B6C0E-0000-4000-8000-000000000012", "4D1B6C0E-0000-4000-8000-000000000013"]
    static let chatID = "4D1B6C0E-0000-4000-8000-000000000006"
    static let alcoholHabit = "00000000-0000-4000-8000-0000000000a1"
    static let walkHabit = "00000000-0000-4000-8000-0000000000a2"
    /// One week of answers, 14 to 20 October 2026.
    static let dayKeys = (14...20).map { String(format: "2026-10-%02d", $0) }
    /// Two habit definitions, seven day records, one chat, one settings snapshot.
    static let documentCount = 2 + 7 + 1 + 1

    static let photoBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    static var photoSHA256: String { SHA256.hash(data: photoBytes).map { String(format: "%02x", $0) }.joined() }

    private static func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    // MARK: Payloads

    static func mealPayload() throws -> Data {
        let provenance: [String: Any] = ["source": "typed", "recordedAt": reference(noon)]
        return try json([
            "schemaVersion": 1, "id": mealID, "revision": 1, "slot": "lunch", "occurredAt": reference(noon),
            "timeZoneIdentifier": timeZone, "localDay": "2026-10-20", "note": "", "confirmedAt": reference(noon + 60),
            // `FoodNutrients.values` is a dictionary keyed by an enum, which Codable writes as alternating key and value.
            "items": [
                ["id": "4D1B6C0E-0000-4000-8000-0000000000b1", "name": "Chicken salad", "amount": 350.0, "unit": "grams",
                 "nutrients": ["values": ["energy", 520.0, "protein", 38.0]], "provenance": [provenance]],
                ["id": "4D1B6C0E-0000-4000-8000-0000000000b2", "name": "Sourdough", "amount": 2.0, "unit": "piece",
                 "nutrients": ["values": ["energy", 160.0]], "provenance": [provenance]]
            ],
            "photos": [["id": photoID, "type": "image/png", "capturedAt": reference(noon - 30), "sha256": photoSHA256]]
        ])
    }

    static func weightPayload() throws -> Data {
        try json(["id": weightID, "measuredAt": reference(noon), "timeZoneIdentifier": timeZone, "localDay": "2026-10-20",
                  "kilograms": 78.4])
    }

    /// The row's payload holds the plan and outcome with every line's `sets` emptied; the sets live in `workout_set`.
    static func sessionPayload() throws -> Data {
        let bench: [String: Any] = ["key": "barbell-bench-press", "name": "Barbell bench press"]
        let planned: [String: Any] = ["id": "4D1B6C0E-0000-4000-8000-0000000000c1", "exercise": bench, "sets": 3, "repsMin": 6,
                                      "repsMax": 8, "loadKg": 80.0, "loadKind": "weight", "restSeconds": 150, "note": ""]
        let line: [String: Any] = ["id": lineID, "exercise": bench, "planned": planned, "status": "done", "sets": [Any]()]
        return try json([
            "schemaVersion": 1, "id": sessionID, "revision": 1, "name": "Upper A", "localDay": "2026-10-20",
            "timeZoneIdentifier": timeZone, "startedAt": reference(noon - 3_600), "endedAt": reference(noon),
            "status": "completed", "appliedAdjustments": [Any](), "exercises": [line], "bests": [Any]()
        ])
    }

    static func setPayload(index: Int) throws -> Data {
        try json(["id": setIDs[index], "loadKg": 80.0, "reps": 8 - index, "rpe": 7.0 + Double(index) / 2,
                  "loggedAt": reference(noon - 3_000 + Double(index) * 180), "prefillSource": index == 0 ? "template" : "previousSet",
                  "edited": index == 2, "skipped": false])
    }

    static func definitionPayload(habit: String) throws -> Data {
        let created = reference(noon - 30 * 86_400)
        let isAlcohol = habit == alcoholHabit
        var object: [String: Any] = [
            "id": ["rawValue": habit], "responseKind": "binary", "createdAt": created, "updatedAt": created, "schemaVersion": 1,
            "source": isAlcohol ? ["kind": "preset", "catalogID": "alcohol"] : ["kind": "custom"],
            "name": isAlcohol ? "Alcohol" : "Walk", "question": isAlcohol ? "Drank alcohol?" : "Walked 30 minutes?",
            "sortOrder": isAlcohol ? 0 : 1
        ]
        if !isAlcohol { object["questionPeriod"] = "Today" }
        return try json(object)
    }

    /// Alcohol answers (no, no, yes, no, no, yes, no) and Walk answers (yes, yes, skipped, yes, no, yes, yes).
    static let alcoholAnswers = ["no", "no", "yes", "no", "no", "yes", "no"]
    static let walkAnswers = ["yes", "yes", "skipped", "yes", "no", "yes", "yes"]

    static func dayPayload(index: Int) throws -> Data {
        let day: [String: Any] = ["era": 1, "year": 2026, "month": 10, "day": 14 + index]
        let answered = reference(noon - Double(6 - index) * 86_400 + 30_000)
        func response(_ habit: String, _ answer: String) -> [String: Any] {
            ["habitID": ["rawValue": habit], "behaviorDay": day, "behaviorTimeZoneID": timeZone, "answer": answer,
             "firstAnsweredAt": answered, "updatedAt": answered, "firstAnswerSource": "morningCheckIn",
             "lastUpdateSource": "morningCheckIn"]
        }
        return try json([
            "behaviorDay": day, "behaviorTimeZoneID": timeZone, "createdAt": answered, "updatedAt": answered, "schemaVersion": 1,
            "responses": [response(alcoholHabit, alcoholAnswers[index]), response(walkHabit, walkAnswers[index])]
        ])
    }

    static func chatPayload() throws -> Data {
        let created = reference(noon - 7_200)
        return try json([
            "id": chatID, "title": "Why was my sleep short?", "createdAt": created, "updatedAt": reference(noon - 7_000),
            "configuration": ["provider": "anthropic", "model": "claude-haiku-5-5", "revision": "4D1B6C0E-0000-4000-8000-0000000000d1"],
            // Build 21 wrote the `journal` compatibility key and had no supplements or labs switches.
            "sharing": ["metrics": true, "journal": false, "cycle": false, "food": true, "training": true,
                        "journalAnswers": false, "journalNotes": false],
            "context": "Health summary for Alex.", "instructions": "", "consentedAt": created,
            "messages": [
                ["id": "4D1B6C0E-0000-4000-8000-0000000000e1", "role": "user", "text": "Why was my sleep short last night?",
                 "status": "complete", "createdAt": created],
                ["id": "4D1B6C0E-0000-4000-8000-0000000000e2", "role": "assistant",
                 "text": "You went to bed 70 minutes later than your usual time.", "status": "complete", "createdAt": reference(noon - 7_000)]
            ],
            "draft": "", "isBriefing": false, "kind": "chat"
        ])
    }

    /// The Settings snapshot as build 21 wrote it: the surface switches have no bedtime key.
    static func settingsPayload() throws -> Data {
        try json([
            "profile": ["displayName": "Alex", "age": 41, "heightCentimeters": 182.0, "weightKilograms": 78.4],
            "units": "imperial", "appearance": "dark",
            "accessibility": ["increasedContrastPreview": false, "voiceOverHints": true],
            "goals": ["stepGoal": 12_000, "strainTarget": 14.0],
            "surfacePrivacy": ["todayWidget": true, "batteryWidget": true, "watchSnapshot": false, "liveActivity": true]
        ])
    }

    // MARK: Rows

    static func write(into db: Database) throws {
        // `FoodStore.confirm`: one meal row, then its photos.
        try db.execute(sql: """
            INSERT INTO food_meal(id, local_day, occurred_at, revision, schema_version, payload)
            VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [mealID, "2026-10-20", noon, 1, 1, try mealPayload()])
        try db.execute(sql: """
            INSERT INTO food_photo(id, meal_id, media_type, captured_at, sha256, bytes)
            VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [photoID, mealID, "image/png", noon - 30, photoSHA256, photoBytes])
        // `FoodStore.saveWeight`.
        try db.execute(sql: "INSERT INTO food_weight(id, local_day, measured_at, payload) VALUES (?, ?, ?, ?)",
                       arguments: [weightID, "2026-10-20", noon, try weightPayload()])
        // `TrainStore.insert(session)` and `insertSets`.
        try db.execute(sql: """
            INSERT INTO workout_session(id, local_day, started_at, workout_id, status, revision, schema_version, payload)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [sessionID, "2026-10-20", noon - 3_600, nil as String?, "completed", 1, 1, try sessionPayload()])
        for index in setIDs.indices {
            try db.execute(sql: """
                INSERT INTO workout_set(id, session_id, session_exercise_id, exercise_key, position, logged_at, payload)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [setIDs[index], sessionID, lineID, "barbell-bench-press", index,
                                 noon - 3_000 + Double(index) * 180, try setPayload(index: index)])
        }

        // `StorageDocumentStore` makes its table on first use, with exactly this definition.
        try db.create(table: StorageDocumentStore.documentTable, ifNotExists: true) { table in
            table.column("namespace", .text).notNull()
            table.column("document_key", .text).notNull()
            table.column("payload", .blob).notNull()
            table.column("updated_at", .double).notNull()
            table.primaryKey(["namespace", "document_key"])
        }
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS loopr_product_document_namespace ON \(StorageDocumentStore.documentTable)(namespace)")
        func document(_ namespace: String, _ key: String, _ payload: Data) throws {
            try db.execute(sql: "INSERT INTO \(StorageDocumentStore.documentTable)(namespace, document_key, payload, updated_at) VALUES (?, ?, ?, ?)",
                           arguments: [namespace, key, payload, noon])
        }
        // `SQLiteHabitRepository`: keys are `habit.definition.<lowercase uuid>` and `habit.day.<yyyy-MM-dd>`.
        for habit in [alcoholHabit, walkHabit] {
            try document("journal", "habit.definition.\(habit.lowercased())", try definitionPayload(habit: habit))
        }
        for (index, key) in dayKeys.enumerated() {
            try document("journal", "habit.day.\(key)", try dayPayload(index: index))
        }
        // `SQLiteCoachConversationRepository` and `SQLiteSettingsRepository`.
        try document("coach", "chat.\(chatID)", try chatPayload())
        try document("settings", "snapshot", try settingsPayload())
    }
}
