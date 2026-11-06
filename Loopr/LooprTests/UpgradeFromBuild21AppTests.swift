import AIKit
import DesignSystem
import DomainKit
import FoodKit
import Foundation
import JournalKit
import RoutineKit
import SettingsKit
import StorageKit
import Testing
import TrainKit
@testable import Loopr

// A database and a defaults domain written by TestFlight build 21 (commit 12464281) must open in this build, keep
// every record the app reads back with today's types, and move the Journal's habit questions into protocol version 1
// through the same entry point the app calls at launch (`RoutineJournalMigration.runOnce`).
//
// The seed is written through SQL against the schema at `storage-015-food-weight`, in the column lists build 21 used.
// `UpgradeFromBuild21Tests` in StorageKitTests proves the same upgrade at the byte level. This suite proves the
// payloads still decode and the migration reads them. Payloads come from the one source that cannot drift from the
// shape: the habit, chat and settings types encode themselves, minus the keys added after build 21 (`supplements` and
// `labs` on chat sharing, `bedtimeLiveActivity` on the surface switches), and `FoodStore` and `TrainStore` write the
// meal, weight and workout into a scratch database whose rows are then copied over by column. Those models changed
// since build 21 only by adding optional fields, so an untouched record encodes to the same bytes. The seed checks
// that none of the added keys are present.
private nonisolated let zoneID = "Australia/Perth"
/// 2026-10-20 12:00 in Perth.
private nonisolated let noon = Date(timeIntervalSince1970: 1_792_468_800)
private nonisolated let build21PinsKey = "loopr.health.pins.v1" // gitleaks:allow

private nonisolated func hid(_ n: Int) -> HabitID { HabitID(rawValue: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!) }
private nonisolated func perthDay(_ day: Int) -> DayIdentity { DayIdentity(year: 2026, month: 10, day: day) }

private nonisolated func encoded<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
}

/// Removes the keys a build after 21 added, so the payload is what build 21 wrote.
private nonisolated func asBuild21Wrote(_ data: Data) throws -> Data {
    func strip(_ value: Any) -> Any {
        if var object = value as? [String: Any] {
            if object["journalAnswers"] != nil { object["supplements"] = nil; object["labs"] = nil }
            if object["watchSnapshot"] != nil { object["bedtimeLiveActivity"] = nil }
            return object.mapValues(strip)
        }
        if let array = value as? [Any] { return array.map(strip) }
        return value
    }
    let object = try JSONSerialization.jsonObject(with: data)
    let result = try JSONSerialization.data(withJSONObject: strip(object), options: [.sortedKeys, .withoutEscapingSlashes])
    let text = String(decoding: result, as: UTF8.self)
    for added in ["supplements", "labs", "bedtimeLiveActivity", "novaGroup", "ingredientTags", "estimatedPlants", "plantEdits"] {
        #expect(!text.contains("\"\(added)\""), "\(added) did not exist in build 21")
    }
    return result
}

/// What the seed wrote, as the current types read it.
private nonisolated struct Expected {
    var definitions: [HabitDefinition]
    var records: [HabitDayRecord]
    var chat: CoachConversation
    var settings: SettingsSnapshot
    var mealID: UUID
    var weightID: UUID
    var sessionID: UUID
    /// Per habit, the answer for each of the seven days 14 to 20 October.
    var alcohol: [HabitAnswer]
    var walk: [HabitAnswer]
}

private nonisolated final class Build21Rig {
    static let version21 = "1.0 (21)"
    static let version22 = "1.0 (22)"
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("UpgradeFromBuild21-\(UUID().uuidString)")
    var url: URL { root.appendingPathComponent("loopr.sqlite") }
    private let databaseURL: URL
    let defaultsName = "UpgradeFromBuild21AppTests.\(UUID().uuidString)"
    let expected: Expected
    private var open: [StorageDatabase] = []

    init() throws {
        databaseURL = root.appendingPathComponent("loopr.sqlite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // Habit questions: Alcohol (a preset the Journal fills in from Food) and Walk (the person's own).
        let catalog = try #require(HabitCatalog.byID["alcohol"])
        let created = noon.addingTimeInterval(-30 * 86_400)
        let alcohol = HabitDefinition(id: hid(1), source: .preset(catalogID: "alcohol"), name: catalog.name,
                                      question: catalog.question, sortOrder: 0, createdAt: created)
        let walk = HabitDefinition(id: hid(2), source: .custom, name: "Walk", question: "Walked 30 minutes?", sortOrder: 1,
                                   createdAt: created, questionPeriod: .today)
        let alcoholAnswers: [HabitAnswer] = [.no, .no, .yes, .no, .no, .yes, .no]
        let walkAnswers: [HabitAnswer] = [.yes, .yes, .skipped, .yes, .no, .yes, .yes]
        let records: [HabitDayRecord] = (0..<7).map { index in
            let day = perthDay(14 + index)
            let answered = noon.addingTimeInterval(-Double(6 - index) * 86_400 + 30_000)
            let responses = [(alcohol, alcoholAnswers[index]), (walk, walkAnswers[index])].map { habit, answer in
                HabitResponse(habitID: habit.id, behaviorDay: day, behaviorTimeZoneID: zoneID, answer: answer,
                              firstAnsweredAt: answered, firstAnswerSource: .morningCheckIn)
            }
            return HabitDayRecord(behaviorDay: day, behaviorTimeZoneID: zoneID, responses: responses, createdAt: answered)
        }

        let chat: CoachConversation = {
            var chat = CoachConversation(id: UUID(uuidString: "4D1B6C0E-0000-4000-8000-000000000006")!,
                                         configuration: CoachProviderConfiguration(provider: .anthropic, model: "claude-haiku-5-5"),
                                         now: noon.addingTimeInterval(-7_200))
            chat.title = "Why was my sleep short?"
            chat.sharing = CoachSharing(metrics: true, cycle: false, food: true, training: true)
            chat.context = "Health summary for Alex."
            chat.consentedAt = noon.addingTimeInterval(-7_200)
            chat.messages = [
                CoachChatMessage(role: .user, text: "Why was my sleep short last night?", createdAt: noon.addingTimeInterval(-7_100)),
                CoachChatMessage(role: .assistant, text: "You went to bed 70 minutes later than your usual time.", createdAt: noon.addingTimeInterval(-7_000))
            ]
            chat.updatedAt = noon.addingTimeInterval(-7_000)
            return chat
        }()

        let settings = SettingsSnapshot(profile: ProfileSettings(displayName: "Alex", age: 41), units: .imperial, appearance: .dark,
                                        goals: GoalSettings(stepGoal: 12_000, strainTarget: 14),
                                        surfacePrivacy: SurfacePrivacySettings(watchSnapshot: false))

        // Meal, weight and workout: written into a scratch database by the stores, copied over as rows.
        let donor = try StorageDatabase(url: root.appendingPathComponent("donor.sqlite"), applicationVersion: "donor")
        let food = FoodStore(database: donor)
        let provenance = [FoodProvenance(source: .typed, recordedAt: noon)]
        let meal = try food.confirm(FoodMealDraft(slot: .lunch, occurredAt: noon, timeZoneIdentifier: zoneID, items: [
            FoodItem(name: "Chicken salad", amount: 350, unit: .grams, nutrients: FoodNutrients([.energy: 520, .protein: 38]), provenance: provenance),
            FoodItem(name: "Sourdough", amount: 2, unit: .piece, nutrients: FoodNutrients([.energy: 160]), provenance: provenance)
        ]), at: noon.addingTimeInterval(60))
        let weight = try FoodWeightEntry(measuredAt: noon, timeZoneIdentifier: zoneID, kilograms: 78.4)
        try food.saveWeight(weight)
        let train = TrainStore(database: donor)
        let bench = TemplateExercise(exercise: ExerciseRef(key: "barbell-bench-press", name: "Barbell bench press"), sets: 3,
                                     repsMin: 6, repsMax: 8, loadKg: 80, restSeconds: 150)
        let sets = (0..<3).map { index in
            LoggedSet(loadKg: 80, reps: 8 - index, rpe: 7 + Double(index) / 2, loggedAt: noon.addingTimeInterval(-3_000 + Double(index) * 180),
                      prefillSource: index == 0 ? .template : .previousSet, edited: index == 2)
        }
        let session = try train.saveSession(TrainSession(name: "Upper A", startedAt: noon.addingTimeInterval(-3_600), timeZoneIdentifier: zoneID,
                                                         endedAt: noon, status: .completed,
                                                         exercises: [SessionExercise(planned: bench, status: .done, sets: sets)]))
        // The columns and their order are the ones build 21 inserted with (`FoodStore.confirm`, `FoodStore.saveWeight`,
        // `TrainStore.insert` and `insertSets`).
        func fetch(_ sql: String) throws -> [[DatabaseValue]] {
            try donor.read { db in try Row.fetchAll(db, sql: sql).map { Array($0.databaseValues) } }
        }
        let mealColumns = "id, local_day, occurred_at, revision, schema_version, payload"
        let weightColumns = "id, local_day, measured_at, payload"
        let sessionColumns = "id, local_day, started_at, workout_id, status, revision, schema_version, payload"
        let setColumns = "id, session_id, session_exercise_id, exercise_key, position, logged_at, payload"
        let mealRows = try fetch("SELECT \(mealColumns) FROM food_meal")
        let weightRows = try fetch("SELECT \(weightColumns) FROM food_weight")
        let sessionRows = try fetch("SELECT \(sessionColumns) FROM workout_session")
        let setRows = try fetch("SELECT \(setColumns) FROM workout_set ORDER BY position")
        #expect(mealRows.count == 1 && weightRows.count == 1 && sessionRows.count == 1 && setRows.count == 3)
        for table in ["food_meal", "food_weight", "workout_session", "workout_set"] {
            for payload in try donor.read({ db in try Data.fetchAll(db, sql: "SELECT payload FROM \(table)") }) { _ = try asBuild21Wrote(payload) }
        }
        try donor.databasePool.close()

        // The build 21 database: the schema as of `storage-015-food-weight`, then every record.
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.journalMode = .wal
        let queue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
        try StorageMigrations.makeMigrator(applicationVersion: Self.version21).migrate(queue, upTo: "storage-015-food-weight")
        try queue.write { db in
            func arguments(_ values: [DatabaseValue]) -> StatementArguments {
                StatementArguments(values.map { $0 as (any DatabaseValueConvertible)? })
            }
            for row in mealRows {
                try db.execute(sql: "INSERT INTO food_meal(\(mealColumns)) VALUES (?, ?, ?, ?, ?, ?)", arguments: arguments(row))
            }
            for row in weightRows {
                try db.execute(sql: "INSERT INTO food_weight(\(weightColumns)) VALUES (?, ?, ?, ?)", arguments: arguments(row))
            }
            for row in sessionRows {
                try db.execute(sql: "INSERT INTO workout_session(\(sessionColumns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?)", arguments: arguments(row))
            }
            for row in setRows {
                try db.execute(sql: "INSERT INTO workout_set(\(setColumns)) VALUES (?, ?, ?, ?, ?, ?, ?)", arguments: arguments(row))
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
                               arguments: [namespace, key, try asBuild21Wrote(payload), noon.timeIntervalSince1970])
            }
            for definition in [alcohol, walk] {
                try document("journal", "habit.definition.\(definition.id.rawValue.uuidString.lowercased())", try encoded(definition))
            }
            for record in records { try document("journal", "habit.day.\(record.behaviorDay.habitKey)", try encoded(record)) }
            try document("coach", "chat.\(chat.id.uuidString)", try encoded(chat))
            try document("settings", "snapshot", try encoded(settings))
        }
        try queue.close()

        // Build 21 kept the pinned metrics in UserDefaults, as a JSON array of metric names.
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defaults.set(try JSONEncoder().encode(["steps", "rmssd"]), forKey: build21PinsKey)

        expected = Expected(definitions: [alcohol, walk], records: records, chat: chat, settings: settings,
                            mealID: meal.id, weightID: weight.id, sessionID: session.id, alcohol: alcoholAnswers, walk: walkAnswers)
    }

    /// Opens the file the way the app does at launch.
    func openCurrent() throws -> StorageDatabase {
        let database = try StorageDatabase(url: url, applicationVersion: Self.version22)
        open.append(database)
        return database
    }

    func close(_ database: StorageDatabase) throws {
        try database.databasePool.close()
        open.removeAll { $0 === database }
    }

    deinit {
        for database in open { try? database.databasePool.close() }
        UserDefaults(suiteName: defaultsName)?.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor struct UpgradeFromBuild21AppTests {
    private let now = Date(timeIntervalSince1970: 1_792_500_000)

    @Test func theSeedIsABuild21DatabaseWithNothingOfTheNewTables() throws {
        let rig = try Build21Rig()
        let queue = try DatabaseQueue(path: rig.url.path)
        defer { try? queue.close() }
        let applied = try queue.read { db in try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid") }
        let hasRoutine = try queue.read { db in try db.tableExists("routine_protocol") }
        let hasWeight = try queue.read { db in try db.tableExists("food_weight") }
        #expect(applied.last == "storage-015-food-weight" && applied.count == 15)
        #expect(!hasRoutine && hasWeight)
        #expect(HealthMetricPins.key == build21PinsKey, "the pins moved to another defaults key")
    }

    @Test func aBuild21DatabaseOpensAndEveryRecordReadsBackWithTodaysTypes() async throws {
        let rig = try Build21Rig()
        let database = try rig.openCurrent()
        #expect(try !database.hasPendingMigrations())
        let expected = rig.expected

        let food = FoodStore(database: database)
        let meals = try food.meals()
        #expect(meals.map(\.id) == [expected.mealID])
        #expect(meals.first?.localDay == "2026-10-20" && meals.first?.slot == .lunch)
        #expect(meals.first?.items.map(\.name) == ["Chicken salad", "Sourdough"])
        #expect(meals.first?.items.first?.nutrients[.energy] == 520 && meals.first?.items.first?.nutrients[.protein] == 38)
        let weights = try food.weights()
        #expect(weights.map(\.id) == [expected.weightID] && weights.first?.kilograms == 78.4)

        let sessions = try TrainStore(database: database).sessions()
        #expect(sessions.map(\.id) == [expected.sessionID])
        #expect(sessions.first?.status == .completed)
        #expect(sessions.first?.exercises.first?.sets.map(\.reps) == [8, 7, 6])
        #expect(sessions.first?.exercises.first?.sets.map(\.loadKg) == [80.0, 80.0, 80.0], "the stored load is exactly 80 kg")
        // `tonnageKg` is a Double. The expected value must be a Double too: an untyped integer expression is an Int in the
        // macro, and an Optional<Double> never equals an Int there, whatever the values.
        let expectedTonnage: Double = 80 * 8 + 80 * 7 + 80 * 6
        #expect(sessions.first?.tonnageKg == expectedTonnage)

        let habits = try SQLiteHabitRepository(database: database)
        let definitions = try await habits.definitions(includeArchived: true)
        #expect(definitions.sorted { $0.sortOrder < $1.sortOrder } == expected.definitions)
        let records = try await habits.dayRecords()
        #expect(records == expected.records)
        #expect(records.count == 7)

        let chatRepository = try SQLiteCoachConversationRepository(database: database)
        let chats = try await chatRepository.conversations()
        #expect(chats == [expected.chat])
        #expect(chats.first?.messages.count == 2)
        #expect(chats.first?.sharing.supplements == false && chats.first?.sharing.labs == false, "an older chat reads the new switches as off")

        let settingsRepository = try SQLiteSettingsRepository(database: database)
        let settings = await settingsRepository.snapshot()
        #expect(settings == expected.settings)
        #expect(settings.surfacePrivacy.bedtimeLiveActivity == false && settings.surfacePrivacy.watchSnapshot == false)
        #expect(settings.units == .imperial && settings.goals.stepGoal == 12_000 && settings.profile.displayName == "Alex")

        let defaults = try #require(UserDefaults(suiteName: rig.defaultsName))
        #expect(HealthMetricPins(storage: defaults).metrics == [.steps, .rmssd])
        try rig.close(database)
    }

    @Test func theHabitMigrationMakesVersionOneFromTheWeekOfAnswersAndRunsOnce() async throws {
        let rig = try Build21Rig()
        let database = try rig.openCurrent()
        let habits = try SQLiteHabitRepository(database: database)
        let routine = RoutineStore(database: database)
        let expected = rig.expected
        let definitionsBefore = try await habits.definitions(includeArchived: true)
        let recordsBefore = try await habits.dayRecords()
        #expect(try routine.protocols().isEmpty)
        #expect(try RoutineHabitMigration.isPending(database: database))

        let outcome = try #require(await RoutineJournalMigration.runOnce(database: database, habits: habits, now: now))
        guard case .created(let protocolID, let rules, let checks, let skipped) = outcome else { Issue.record("not created: \(outcome)"); return }
        let answered = (expected.alcohol + expected.walk).filter { $0 != .skipped }.count
        #expect(rules == 2 && checks == answered && answered == 13 && skipped.isEmpty)

        // One protocol with one version and one rule per active habit question.
        #expect(try routine.protocols().map(\.id) == [protocolID])
        #expect(try routine.activeProtocol()?.routineProtocol.id == protocolID)
        #expect(try routine.versions(protocolID: protocolID).map(\.number) == [1])
        let version = try #require(try routine.version(protocolID: protocolID, number: 1))
        let alcoholKey = RoutineHabitMigration.ruleKey(forHabit: hid(1).rawValue)
        let walkKey = RoutineHabitMigration.ruleKey(forHabit: hid(2).rawValue)
        #expect(version.rules.map(\.key) == [alcoholKey, walkKey])
        #expect(version.rules.map(\.title) == ["No alcohol", "Walk"])
        #expect(version.rules.map(\.source) == [.food, .manual])

        // Each past answer is reachable from its rule. Alcohol is written the other way round, so a "no" is kept.
        for (key, answers, avoid) in [(alcoholKey, expected.alcohol, true), (walkKey, expected.walk, false)] {
            let history = try routine.history(protocolID: protocolID, ruleKey: key)
            #expect(history.count == answers.filter { $0 != .skipped }.count, "\(key.rawValue)")
            for (index, answer) in answers.enumerated() {
                let check = try routine.check(protocolID: protocolID, ruleKey: key, day: perthDay(14 + index))
                switch answer {
                case .skipped:
                    #expect(check == nil, "a skipped answer is not a check")
                case .yes, .no:
                    let kept = avoid ? answer == .no : answer == .yes
                    #expect(check?.state == (kept ? .kept : .missed), "\(key.rawValue) on day \(14 + index)")
                    #expect(check?.version == 1)
                }
            }
        }

        // A second run, in the same launch and after a relaunch, creates nothing.
        let counts = try database.tableRowCounts()
        #expect(await RoutineJournalMigration.runOnce(database: database, habits: habits, now: now.addingTimeInterval(60)) == .alreadyDone)
        #expect(try database.tableRowCounts() == counts)
        #expect(try routine.protocols().count == 1 && routine.versions(protocolID: protocolID).count == 1)

        // The Journal still holds everything it held.
        #expect(try await habits.definitions(includeArchived: true) == definitionsBefore)
        #expect(try await habits.dayRecords() == recordsBefore)
        try rig.close(database)
    }

    @Test func reopeningAfterTheMigrationHasNoPendingMigrationsAndDuplicatesNothing() async throws {
        let rig = try Build21Rig()
        let first = try rig.openCurrent()
        let firstHabits = try SQLiteHabitRepository(database: first)
        let outcome = try #require(await RoutineJournalMigration.runOnce(database: first, habits: firstHabits, now: now))
        guard case .created(let protocolID, _, _, _) = outcome else { Issue.record("not created: \(outcome)"); return }
        let counts = try first.tableRowCounts()
        let schema = try first.schemaSnapshot()
        let metadata = try first.schemaMetadata()
        let version = try #require(try RoutineStore(database: first).latestVersion(protocolID: protocolID))
        try rig.close(first)

        let second = try rig.openCurrent()
        #expect(try !second.hasPendingMigrations())
        #expect(try second.tableRowCounts() == counts, "a row was added or lost on the second open")
        #expect(try second.schemaSnapshot() == schema)
        #expect(try second.schemaMetadata() == metadata)
        let habits = try SQLiteHabitRepository(database: second)
        #expect(await RoutineJournalMigration.runOnce(database: second, habits: habits, now: now.addingTimeInterval(86_400)) == .alreadyDone)
        let routine = RoutineStore(database: second)
        #expect(try routine.protocols().map(\.id) == [protocolID])
        #expect(try routine.latestVersion(protocolID: protocolID) == version)
        #expect(try second.tableRowCounts() == counts)
        #expect(try await habits.dayRecords() == rig.expected.records)
        #expect(try food(second).meals().count == 1 && food(second).weights().count == 1)
        try rig.close(second)
    }

    private func food(_ database: StorageDatabase) -> FoodStore { FoodStore(database: database) }
}
