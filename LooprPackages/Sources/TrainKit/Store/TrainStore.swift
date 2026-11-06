import Foundation
import StorageKit

/// Plans, programs, custom exercises and sessions in the app's SQLite container.
/// Reads and writes are synchronous GRDB calls; the app calls them from an actor, never the main thread.
///
/// Every record carries a `revision`. A save succeeds only when the revision on the
/// value matches the stored one (0 for a record that was never saved) and writes
/// `revision + 1`, so an editor holding an old copy cannot overwrite newer work.
public final class TrainStore: Sendable {
    let database: StorageDatabase
    public init(database: StorageDatabase) { self.database = database }

    // MARK: Templates

    public func templates() throws -> [WorkoutTemplate] {
        try database.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM workout_template ORDER BY name COLLATE NOCASE, id").map(Self.decodeTemplate)
        }
    }

    public func template(id: UUID) throws -> WorkoutTemplate? {
        try database.read { db in try Self.template(id: id, in: db) }
    }

    @discardableResult
    public func saveTemplate(_ template: WorkoutTemplate, at date: Date) throws -> WorkoutTemplate {
        try template.validate()
        return try database.write { db in
            let stored = try Self.storedRevision(table: "workout_template", column: "id", value: template.id.uuidString, in: db)
            try Self.checkRevision(template.revision, stored: stored)
            var saved = template
            saved.revision += 1
            saved.updatedAt = date
            if stored == nil { saved.createdAt = date }
            try saved.validate()
            try Self.write(saved, in: db)
            return saved
        }
    }

    public func deleteTemplate(id: UUID, expectedRevision: Int) throws {
        try database.write { db in
            let stored = try Self.storedRevision(table: "workout_template", column: "id", value: id.uuidString, in: db)
            guard stored != nil else { throw TrainError.missingRecord }
            try Self.checkRevision(expectedRevision, stored: stored)
            try db.execute(sql: "DELETE FROM workout_template WHERE id = ?", arguments: [id.uuidString])
        }
    }

    // MARK: Programs

    public func programs() throws -> [Program] {
        try database.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM workout_program ORDER BY name COLLATE NOCASE, id").map(Self.decodeProgram)
        }
    }

    public func program(id: UUID) throws -> Program? {
        try database.read { db in try Self.program(id: id, in: db) }
    }

    @discardableResult
    public func saveProgram(_ program: Program, at date: Date) throws -> Program {
        try program.validate()
        return try database.write { db in
            let stored = try Self.storedRevision(table: "workout_program", column: "id", value: program.id.uuidString, in: db)
            try Self.checkRevision(program.revision, stored: stored)
            var saved = program
            saved.revision += 1
            saved.updatedAt = date
            if stored == nil { saved.createdAt = date }
            try saved.validate()
            try Self.write(saved, in: db)
            return saved
        }
    }

    public func deleteProgram(id: UUID, expectedRevision: Int) throws {
        try database.write { db in
            let stored = try Self.storedRevision(table: "workout_program", column: "id", value: id.uuidString, in: db)
            guard stored != nil else { throw TrainError.missingRecord }
            try Self.checkRevision(expectedRevision, stored: stored)
            try db.execute(sql: "DELETE FROM workout_program WHERE id = ?", arguments: [id.uuidString])
        }
    }

    /// Accepts an agent draft in one transaction: saves the pending templates its slots use, then saves
    /// the program as active. Nothing is written if a slot points at a template that does not exist.
    ///
    /// - Throws: `missingRecord` for an unknown program or template, `invalidRecord` when the program is not
    ///   a draft, `staleRevision` when the draft changed since the caller loaded it.
    @discardableResult
    public func acceptProgramDraft(id: UUID, expectedRevision: Int, at date: Date) throws -> Program {
        try database.write { db in
            guard var program = try Self.program(id: id, in: db) else { throw TrainError.missingRecord }
            try Self.checkRevision(expectedRevision, stored: program.revision)
            guard program.status == .draft else { throw TrainError.invalidRecord }
            let used = program.templateIDs
            let pending = program.pendingTemplates ?? []
            for templateID in used where !pending.contains(where: { $0.id == templateID }) {
                guard try Self.template(id: templateID, in: db) != nil else { throw TrainError.missingRecord }
            }
            for var template in pending where used.contains(template.id) {
                guard try Self.storedRevision(table: "workout_template", column: "id", value: template.id.uuidString, in: db) == nil
                else { throw TrainError.invalidRecord }
                template.revision = 1
                template.createdAt = date
                template.updatedAt = date
                try template.validate()
                try Self.write(template, in: db)
            }
            program.pendingTemplates = nil
            program.status = .active
            program.revision += 1
            program.updatedAt = date
            try program.validate()
            try Self.write(program, in: db)
            return program
        }
    }

    /// Deletes an agent draft and the templates it carried. Only a draft can be discarded this way,
    /// so a stale tap can never delete a program the person already accepted.
    public func discardProgramDraft(id: UUID, expectedRevision: Int) throws {
        try database.write { db in
            guard let program = try Self.program(id: id, in: db) else { throw TrainError.missingRecord }
            try Self.checkRevision(expectedRevision, stored: program.revision)
            guard program.status == .draft else { throw TrainError.invalidRecord }
            try db.execute(sql: "DELETE FROM workout_program WHERE id = ?", arguments: [id.uuidString])
        }
    }

    // MARK: Custom exercises

    public func customExercises() throws -> [ExerciseDefinition] {
        try database.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM workout_exercise_custom ORDER BY name COLLATE NOCASE, key").map(Self.decodeExercise)
        }
    }

    public func customExercise(key: String) throws -> ExerciseDefinition? {
        try database.read { db in
            try Data.fetchOne(db, sql: "SELECT payload FROM workout_exercise_custom WHERE key = ?", arguments: [key]).map(Self.decodeExercise)
        }
    }

    @discardableResult
    public func saveCustomExercise(_ exercise: ExerciseDefinition) throws -> ExerciseDefinition {
        guard exercise.origin == .custom else { throw TrainError.invalidRecord }
        try exercise.validate()
        return try database.write { db in
            let stored = try Self.storedRevision(table: "workout_exercise_custom", column: "key", value: exercise.key, in: db)
            try Self.checkRevision(exercise.revision, stored: stored)
            var saved = exercise
            saved.revision += 1
            try Self.write(saved, in: db)
            return saved
        }
    }

    /// Past sessions keep the exercise name they recorded, so deleting a custom exercise never rewrites history.
    public func deleteCustomExercise(key: String, expectedRevision: Int) throws {
        try database.write { db in
            let stored = try Self.storedRevision(table: "workout_exercise_custom", column: "key", value: key, in: db)
            guard stored != nil else { throw TrainError.missingRecord }
            try Self.checkRevision(expectedRevision, stored: stored)
            try db.execute(sql: "DELETE FROM workout_exercise_custom WHERE key = ?", arguments: [key])
        }
    }

    // MARK: Sessions

    /// Sessions in start order, optionally for one local day.
    public func sessions(localDay: String? = nil) throws -> [TrainSession] {
        try database.read { db in
            let ids: [String]
            if let localDay {
                ids = try String.fetchAll(db, sql: "SELECT id FROM workout_session WHERE local_day = ? ORDER BY started_at, id", arguments: [localDay])
            } else {
                ids = try String.fetchAll(db, sql: "SELECT id FROM workout_session ORDER BY started_at, id")
            }
            return try ids.compactMap { try Self.session(idText: $0, in: db) }
        }
    }

    /// The newest sessions first, for prefill, expected strain and personal bests.
    public func recentSessions(limit: Int, status: TrainSessionStatus? = .completed) throws -> [TrainSession] {
        try database.read { db in
            let ids: [String]
            if let status {
                ids = try String.fetchAll(db, sql: "SELECT id FROM workout_session WHERE status = ? ORDER BY started_at DESC, id LIMIT ?",
                                          arguments: [status.rawValue, max(0, limit)])
            } else {
                ids = try String.fetchAll(db, sql: "SELECT id FROM workout_session ORDER BY started_at DESC, id LIMIT ?", arguments: [max(0, limit)])
            }
            return try ids.compactMap { try Self.session(idText: $0, in: db) }
        }
    }

    public func session(id: UUID) throws -> TrainSession? {
        try database.read { db in try Self.session(idText: id.uuidString, in: db) }
    }

    /// The session linked to a recorded workout, if any.
    public func session(workoutID: UUID) throws -> TrainSession? {
        try database.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM workout_session WHERE workout_id = ? ORDER BY started_at DESC LIMIT 1",
                                arguments: [workoutID.uuidString]).flatMap { try Self.session(idText: $0, in: db) }
        }
    }

    /// Saves the session and replaces its logged sets in one transaction.
    @discardableResult
    public func saveSession(_ session: TrainSession) throws -> TrainSession {
        try session.validate()
        return try database.write { db in
            let stored = try Self.storedRevision(table: "workout_session", column: "id", value: session.id.uuidString, in: db)
            try Self.checkRevision(session.revision, stored: stored)
            var saved = session
            saved.revision += 1
            try saved.validate()
            try Self.write(saved, in: db)
            return saved
        }
    }

    public func deleteSession(id: UUID, expectedRevision: Int) throws {
        try database.write { db in
            let stored = try Self.storedRevision(table: "workout_session", column: "id", value: id.uuidString, in: db)
            guard stored != nil else { throw TrainError.missingRecord }
            try Self.checkRevision(expectedRevision, stored: stored)
            try db.execute(sql: "DELETE FROM workout_set WHERE session_id = ?", arguments: [id.uuidString])
            try db.execute(sql: "DELETE FROM workout_session WHERE id = ?", arguments: [id.uuidString])
        }
    }

    // MARK: Lifecycle

    /// Removes the sessions of one local day and their sets. Templates, programs and
    /// custom exercises are plans, not day records, so they stay.
    public func deleteDay(_ localDay: String) throws {
        try database.write { db in try Self.deleteDay(localDay, in: db) }
    }

    public func deleteAll() throws {
        try database.write { db in try Self.deleteAll(in: db) }
    }

    public static func deleteDay(_ localDay: String, in db: Database) throws {
        try db.execute(sql: "DELETE FROM workout_set WHERE session_id IN (SELECT id FROM workout_session WHERE local_day = ?)", arguments: [localDay])
        try db.execute(sql: "DELETE FROM workout_session WHERE local_day = ?", arguments: [localDay])
    }

    public static func deleteAll(in db: Database) throws {
        for table in ["workout_set", "workout_session", "workout_exercise_custom", "workout_program", "workout_template"] {
            try db.execute(sql: "DELETE FROM \(table)")
        }
    }

    public func exportArchive(localDay: String? = nil) throws -> TrainArchive {
        try database.read { db in
            let ids: [String]
            if let localDay {
                ids = try String.fetchAll(db, sql: "SELECT id FROM workout_session WHERE local_day = ? ORDER BY started_at, id", arguments: [localDay])
            } else {
                ids = try String.fetchAll(db, sql: "SELECT id FROM workout_session ORDER BY started_at, id")
            }
            let sessions = try ids.compactMap { try Self.session(idText: $0, in: db) }
            guard localDay == nil else { return TrainArchive(sessions: sessions) }
            return TrainArchive(
                templates: try Data.fetchAll(db, sql: "SELECT payload FROM workout_template ORDER BY name COLLATE NOCASE, id").map(Self.decodeTemplate),
                programs: try Data.fetchAll(db, sql: "SELECT payload FROM workout_program ORDER BY name COLLATE NOCASE, id").map(Self.decodeProgram),
                customExercises: try Data.fetchAll(db, sql: "SELECT payload FROM workout_exercise_custom ORDER BY name COLLATE NOCASE, key").map(Self.decodeExercise),
                sessions: sessions)
        }
    }

    public func restore(_ archive: TrainArchive) throws {
        try archive.validate()
        try database.write { db in try Self.restore(archive, in: db) }
    }

    /// The caller owns the transaction when restoring several product domains.
    /// Validation and encoding finish before deletion; any insert failure rolls back both.
    public static func restore(_ archive: TrainArchive, in db: Database) throws {
        try archive.validate()
        let encoder = Self.encoder()
        let templates = try archive.templates.map { ($0, try encoder.encode($0)) }
        let programs = try archive.programs.map { ($0, try encoder.encode($0)) }
        let exercises = try archive.customExercises.map { ($0, try encoder.encode($0)) }
        let sessions = try archive.sessions.map { ($0, try Self.encodeSession($0, encoder: encoder)) }
        try deleteAll(in: db)
        for (template, payload) in templates { try insert(template, payload: payload, in: db) }
        for (program, payload) in programs { try insert(program, payload: payload, in: db) }
        for (exercise, payload) in exercises { try insert(exercise, payload: payload, in: db) }
        for (session, payload) in sessions { try insert(session, payload: payload, encoder: encoder, in: db) }
    }

    // MARK: Encoding

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    /// The session row stores the plan and outcome; its sets live in `workout_set` rows.
    private static func encodeSession(_ session: TrainSession, encoder: JSONEncoder) throws -> Data {
        var stripped = session
        for index in stripped.exercises.indices { stripped.exercises[index].sets = [] }
        return try encoder.encode(stripped)
    }

    private static func write(_ template: WorkoutTemplate, in db: Database) throws {
        try db.execute(sql: """
            INSERT INTO workout_template(id, name, updated_at, revision, schema_version, payload) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET name = excluded.name, updated_at = excluded.updated_at,
                revision = excluded.revision, schema_version = excluded.schema_version, payload = excluded.payload
            """, arguments: [template.id.uuidString, template.name, template.updatedAt.timeIntervalSince1970,
                template.revision, template.schemaVersion, try encoder().encode(template)])
    }

    private static func insert(_ template: WorkoutTemplate, payload: Data, in db: Database) throws {
        try db.execute(sql: "INSERT INTO workout_template(id, name, updated_at, revision, schema_version, payload) VALUES (?, ?, ?, ?, ?, ?)",
            arguments: [template.id.uuidString, template.name, template.updatedAt.timeIntervalSince1970, template.revision, template.schemaVersion, payload])
    }

    private static func write(_ program: Program, in db: Database) throws {
        try db.execute(sql: """
            INSERT INTO workout_program(id, name, status, updated_at, revision, schema_version, payload) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET name = excluded.name, status = excluded.status, updated_at = excluded.updated_at,
                revision = excluded.revision, schema_version = excluded.schema_version, payload = excluded.payload
            """, arguments: [program.id.uuidString, program.name, program.status.rawValue, program.updatedAt.timeIntervalSince1970,
                program.revision, program.schemaVersion, try encoder().encode(program)])
    }

    private static func insert(_ program: Program, payload: Data, in db: Database) throws {
        try db.execute(sql: "INSERT INTO workout_program(id, name, status, updated_at, revision, schema_version, payload) VALUES (?, ?, ?, ?, ?, ?, ?)",
            arguments: [program.id.uuidString, program.name, program.status.rawValue, program.updatedAt.timeIntervalSince1970,
                program.revision, program.schemaVersion, payload])
    }

    private static func write(_ exercise: ExerciseDefinition, in db: Database) throws {
        try db.execute(sql: """
            INSERT INTO workout_exercise_custom(key, name, revision, schema_version, payload) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET name = excluded.name, revision = excluded.revision,
                schema_version = excluded.schema_version, payload = excluded.payload
            """, arguments: [exercise.key, exercise.name, exercise.revision, exercise.schemaVersion, try encoder().encode(exercise)])
    }

    private static func insert(_ exercise: ExerciseDefinition, payload: Data, in db: Database) throws {
        try db.execute(sql: "INSERT INTO workout_exercise_custom(key, name, revision, schema_version, payload) VALUES (?, ?, ?, ?, ?)",
            arguments: [exercise.key, exercise.name, exercise.revision, exercise.schemaVersion, payload])
    }

    private static func write(_ session: TrainSession, in db: Database) throws {
        let encoder = Self.encoder()
        try db.execute(sql: """
            INSERT INTO workout_session(id, local_day, started_at, workout_id, status, revision, schema_version, payload)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET local_day = excluded.local_day, started_at = excluded.started_at,
                workout_id = excluded.workout_id, status = excluded.status, revision = excluded.revision,
                schema_version = excluded.schema_version, payload = excluded.payload
            """, arguments: sessionArguments(session, payload: try encodeSession(session, encoder: encoder)))
        try db.execute(sql: "DELETE FROM workout_set WHERE session_id = ?", arguments: [session.id.uuidString])
        try insertSets(of: session, encoder: encoder, in: db)
    }

    private static func insert(_ session: TrainSession, payload: Data, encoder: JSONEncoder, in db: Database) throws {
        try db.execute(sql: """
            INSERT INTO workout_session(id, local_day, started_at, workout_id, status, revision, schema_version, payload)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: sessionArguments(session, payload: payload))
        try insertSets(of: session, encoder: encoder, in: db)
    }

    private static func sessionArguments(_ session: TrainSession, payload: Data) -> StatementArguments {
        [session.id.uuidString, session.localDay, session.startedAt.timeIntervalSince1970, session.workoutID?.uuidString,
         session.status.rawValue, session.revision, session.schemaVersion, payload]
    }

    private static func insertSets(of session: TrainSession, encoder: JSONEncoder, in db: Database) throws {
        for line in session.exercises {
            for (position, set) in line.sets.enumerated() {
                try db.execute(sql: """
                    INSERT INTO workout_set(id, session_id, session_exercise_id, exercise_key, position, logged_at, payload)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [set.id.uuidString, session.id.uuidString, line.id.uuidString, line.exercise.key,
                        position, set.loggedAt.timeIntervalSince1970, try encoder.encode(set)])
            }
        }
    }

    // MARK: Decoding

    private static func decodeTemplate(_ data: Data) throws -> WorkoutTemplate {
        let result = try JSONDecoder().decode(WorkoutTemplate.self, from: data)
        try result.validate()
        return result
    }

    private static func decodeProgram(_ data: Data) throws -> Program {
        let result = try JSONDecoder().decode(Program.self, from: data)
        try result.validate()
        return result
    }

    private static func decodeExercise(_ data: Data) throws -> ExerciseDefinition {
        let result = try JSONDecoder().decode(ExerciseDefinition.self, from: data)
        try result.validate()
        return result
    }

    private static func template(id: UUID, in db: Database) throws -> WorkoutTemplate? {
        try Data.fetchOne(db, sql: "SELECT payload FROM workout_template WHERE id = ?", arguments: [id.uuidString]).map(decodeTemplate)
    }

    private static func program(id: UUID, in db: Database) throws -> Program? {
        try Data.fetchOne(db, sql: "SELECT payload FROM workout_program WHERE id = ?", arguments: [id.uuidString]).map(decodeProgram)
    }

    private static func session(idText: String, in db: Database) throws -> TrainSession? {
        guard let payload = try Data.fetchOne(db, sql: "SELECT payload FROM workout_session WHERE id = ?", arguments: [idText]) else { return nil }
        var session = try JSONDecoder().decode(TrainSession.self, from: payload)
        let rows = try Row.fetchAll(db, sql: "SELECT session_exercise_id, payload FROM workout_set WHERE session_id = ? ORDER BY position, logged_at, id",
                                    arguments: [idText])
        var byLine: [String: [LoggedSet]] = [:]
        for row in rows {
            byLine[row["session_exercise_id"] as String, default: []].append(try JSONDecoder().decode(LoggedSet.self, from: row["payload"] as Data))
        }
        for index in session.exercises.indices {
            session.exercises[index].sets = byLine.removeValue(forKey: session.exercises[index].id.uuidString) ?? []
        }
        guard byLine.isEmpty else { throw TrainError.invalidRecord }
        try session.validate()
        return session
    }

    // MARK: Revisions

    private static func storedRevision(table: String, column: String, value: String, in db: Database) throws -> Int? {
        try Int.fetchOne(db, sql: "SELECT revision FROM \(table) WHERE \(column) = ?", arguments: [value])
    }

    private static func checkRevision(_ revision: Int, stored: Int?) throws {
        guard revision < Int.max else { throw TrainError.staleRevision }
        if let stored {
            guard stored == revision else { throw TrainError.staleRevision }
        } else if revision != 0 {
            throw TrainError.missingRecord
        }
    }
}
