import Foundation
import StorageKit
import TrainKit

/// The actor keeps SQLite reads and writes off the main thread. Screens call it
/// through their models; none of them touch `TrainStore` directly.
actor AppTrainRepository {
    private var train: TrainStore?
    #if DEBUG
    private var fixtureDatabase: StorageDatabase?
    private var fixtureRoot: URL?
    /// True for a store named by `--loopr-train-fixture-store`, which outlives the process.
    private var fixtureRootIsStable = false
    private let seedsFixture: Bool
    private let fixtureStoreName: String?
    #endif
    private let environment: AppEnvironment

    /// - Parameters:
    ///   - seedsFixture: Fills a fixture database with Alex's plans. Nil follows `--loopr-train-fixture`.
    ///   - fixtureStoreName: Keeps the fixture database under this name across launches, so a UI test can
    ///     relaunch and find what it saved. Nil follows `--loopr-train-fixture-store=<name>`, and a launch
    ///     without it gets a throwaway database.
    init(store: TrainStore? = nil, environment: AppEnvironment, seedsFixture: Bool? = nil, fixtureStoreName: String? = nil) {
        train = store; self.environment = environment
        #if DEBUG
        self.seedsFixture = seedsFixture ?? AppTrainFixtures.isRequested()
        self.fixtureStoreName = fixtureStoreName ?? AppTrainFixtures.storeName()
        #endif
    }

    deinit {
        #if DEBUG
        try? fixtureDatabase?.databasePool.close()
        if let fixtureRoot, !fixtureRootIsStable { try? FileManager.default.removeItem(at: fixtureRoot) }
        #endif
    }

    /// Production uses the app's own database. Every other composition gets a
    /// separate temporary database, so a fixture can never write into real data.
    private func ready() throws -> TrainStore {
        if let train { return train }
        #if DEBUG
        guard environment.composition != .production else { throw TrainError.missingRecord }
        let root = fixtureStoreName.map { AppTrainFixtures.stableRoot(named: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("LooprTrainFixture-\(UUID().uuidString)")
        fixtureRoot = root
        fixtureRootIsStable = fixtureStoreName != nil
        let url = root.appendingPathComponent("train.sqlite")
        // A named store seeds once. The second launch opens what the first one left.
        let alreadySeeded = fixtureStoreName != nil && FileManager.default.fileExists(atPath: url.path)
        let database = try StorageDatabase(url: url, applicationVersion: "train-fixture")
        fixtureDatabase = database
        let store = TrainStore(database: database)
        if seedsFixture, !alreadySeeded { try AppTrainFixtures.seed(store) }
        train = store
        return store
        #else
        throw TrainError.missingRecord
        #endif
    }

    func templates() throws -> [WorkoutTemplate] { try ready().templates() }
    func template(id: UUID) throws -> WorkoutTemplate? { try ready().template(id: id) }
    func saveTemplate(_ template: WorkoutTemplate, at date: Date) throws -> WorkoutTemplate { try ready().saveTemplate(template, at: date) }
    func deleteTemplate(id: UUID, expectedRevision: Int) throws { try ready().deleteTemplate(id: id, expectedRevision: expectedRevision) }

    func programs() throws -> [Program] { try ready().programs() }
    func program(id: UUID) throws -> Program? { try ready().program(id: id) }
    func saveProgram(_ program: Program, at date: Date) throws -> Program { try ready().saveProgram(program, at: date) }
    func deleteProgram(id: UUID, expectedRevision: Int) throws { try ready().deleteProgram(id: id, expectedRevision: expectedRevision) }

    /// Changes a program's rules against the stored copy, so two quick toggles never collide on a revision.
    func updateProgramRules(id: UUID, at date: Date, edit: @Sendable (ProgramRules) -> ProgramRules) throws -> Program {
        let store = try ready()
        guard var program = try store.program(id: id) else { throw TrainError.missingRecord }
        program.rules = edit(program.rules)
        return try store.saveProgram(program, at: date)
    }

    /// Stores an agent draft. FT-05 calls this with the JSON the agent produced.
    ///
    /// The decoder checks template names against the saved templates and exercise names against `library`. A refused
    /// draft throws a `ProgramDraftError` and stores nothing. A stored draft has status `.draft`: it never schedules,
    /// shows in the week or exports to Calendar until `acceptDraft`.
    func createProgramDraft(json: String, library: ExerciseLibrary?, defaultStartDay: String, at date: Date) throws -> Program {
        let store = try ready()
        let decoder = ProgramDraftDecoder(templates: try store.templates(), library: library, defaultStartDay: defaultStartDay)
        return try store.saveProgram(try decoder.decode(json), at: date)
    }

    func acceptDraft(id: UUID, expectedRevision: Int, at date: Date) throws -> Program {
        try ready().acceptProgramDraft(id: id, expectedRevision: expectedRevision, at: date)
    }

    func discardDraft(id: UUID, expectedRevision: Int) throws {
        try ready().discardProgramDraft(id: id, expectedRevision: expectedRevision)
    }

    func customExercises() throws -> [ExerciseDefinition] { try ready().customExercises() }
    func saveCustomExercise(_ exercise: ExerciseDefinition) throws -> ExerciseDefinition { try ready().saveCustomExercise(exercise) }
    func deleteCustomExercise(key: String, expectedRevision: Int) throws { try ready().deleteCustomExercise(key: key, expectedRevision: expectedRevision) }

    /// Saves the decisions the scheduler made when it planned the current week, such as a light week or a
    /// moved session, so a rule never decides the same week twice. Returns true when a program changed.
    @discardableResult
    func recordAdjustments(_ pending: [PendingProgramAdjustments], at date: Date) throws -> Bool {
        let store = try ready()
        var changed = false
        for entry in pending {
            guard let program = try store.program(id: entry.programID),
                  let merged = ProgramAdjustmentPlanner.merge(entry.adjustments, into: program) else { continue }
            _ = try store.saveProgram(merged, at: date)
            changed = true
        }
        return changed
    }

    func sessions(localDay: String? = nil) throws -> [TrainSession] { try ready().sessions(localDay: localDay) }
    func recentSessions(limit: Int, status: TrainSessionStatus? = .completed) throws -> [TrainSession] { try ready().recentSessions(limit: limit, status: status) }
    func session(id: UUID) throws -> TrainSession? { try ready().session(id: id) }
    func session(workoutID: UUID) throws -> TrainSession? { try ready().session(workoutID: workoutID) }
    func saveSession(_ session: TrainSession) throws -> TrainSession { try ready().saveSession(session) }
    func deleteSession(id: UUID, expectedRevision: Int) throws { try ready().deleteSession(id: id, expectedRevision: expectedRevision) }
}

extension ProductRepositoryContainer {
    /// The Train repository for this composition. Production reads the app's own database. Every other
    /// composition shares one fixture repository, so every Train screen sees the same plans.
    func makeTrainRepository() -> AppTrainRepository {
        if let persistent { return AppTrainRepository(store: persistent.train, environment: environment) }
        #if DEBUG
        return fixtureTrainRepository
        #else
        return AppTrainRepository(environment: environment)
        #endif
    }
}
