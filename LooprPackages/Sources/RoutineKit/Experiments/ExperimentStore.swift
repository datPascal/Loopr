import DomainKit
import Foundation
import StorageKit

/// Experiments and their nights in the app's one SQLite database (`storage-021-experiments`).
///
/// The store has no call that edits a start record. `start` writes it, `finish` and `stop` move the status forward,
/// and `recordNight` adds nights while the experiment runs. The database enforces the same rules with triggers, so a
/// raw UPDATE cannot change the outcome either. Deleting a protocol removes its experiments and their nights.
public final class ExperimentStore: Sendable {
    let database: StorageDatabase
    public init(database: StorageDatabase) { self.database = database }

    // MARK: Experiments

    /// Saves a new running experiment. The protocol must exist, the id must be new, and no other experiment may be
    /// running.
    @discardableResult
    public func start(_ start: ExperimentStart) throws -> Experiment {
        try database.write { db in
            guard try Int.fetchOne(db, sql: "SELECT 1 FROM routine_protocol WHERE id = ?",
                                   arguments: [start.protocolID.rawValue.uuidString]) != nil else {
                throw ExperimentError.missingProtocol
            }
            guard try Int.fetchOne(db, sql: "SELECT 1 FROM experiment WHERE id = ?",
                                   arguments: [start.id.rawValue.uuidString]) == nil else {
                throw ExperimentError.duplicateExperiment
            }
            guard try Int.fetchOne(db, sql: "SELECT 1 FROM experiment WHERE status = 'running'") == nil else {
                throw ExperimentError.anotherExperimentRunning
            }
            guard let dayKey = start.startDay.routineDayKey else { throw ExperimentError.invalidDay }
            try db.execute(sql: """
                INSERT INTO experiment(id, protocol_id, title, intervention_name, rule_key, design, design_length, washout,
                                       minimum_nights, planned_nights, outcome_key, outcome_title, outcome_unit,
                                       outcome_direction, start_day, time_zone_identifier, created_at, status, end_day)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'running', NULL)
                """, arguments: [start.id.rawValue.uuidString, start.protocolID.rawValue.uuidString, start.title,
                                 start.interventionName, start.ruleKey.rawValue, start.design.kind, start.design.length,
                                 start.washout, start.minimumNightsPerArm, start.plannedNights, start.outcome.key,
                                 start.outcome.title, start.outcome.unit, start.outcome.benefit.rawValue, dayKey,
                                 start.timeZoneIdentifier, start.createdAt.timeIntervalSince1970])
            return Experiment(start: start)
        }
    }

    public func experiment(id: ExperimentID) throws -> Experiment? {
        try database.read { db in try Self.experiment(id, in: db) }
    }

    /// Every experiment, newest first.
    public func experiments() throws -> [Experiment] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM experiment ORDER BY start_day DESC, created_at DESC, id")
                .map(Self.experiment(from:))
        }
    }

    /// The experiment that is running now, if any.
    public func running() throws -> Experiment? {
        try database.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM experiment WHERE status = 'running'").map(Self.experiment(from:))
        }
    }

    /// Ends a running experiment whose planned nights are over. `lastNight` is the latest night that is over.
    @discardableResult
    public func finish(id: ExperimentID, lastNight: DayIdentity) throws -> Experiment {
        try database.write { db in
            let experiment = try Self.runningExperiment(id, in: db)
            guard let remaining = experiment.start.lastPlannedDay.days(until: lastNight), remaining >= 0 else {
                throw ExperimentError.plannedNightsNotOver
            }
            return try Self.close(experiment, as: .finished, endDay: experiment.start.lastPlannedDay, in: db)
        }
    }

    /// Stops a running experiment. Nights up to `lastNight` count; later ones are outside. The day is held between
    /// night 1 and the last planned night.
    @discardableResult
    public func stop(id: ExperimentID, lastNight: DayIdentity) throws -> Experiment {
        try database.write { db in
            let experiment = try Self.runningExperiment(id, in: db)
            let start = experiment.start
            var endDay = lastNight
            if let before = start.startDay.days(until: lastNight), before < 0 { endDay = start.startDay }
            if let beyond = start.lastPlannedDay.days(until: lastNight), beyond > 0 { endDay = start.lastPlannedDay }
            return try Self.close(experiment, as: .stopped, endDay: endDay, in: db)
        }
    }

    /// Removes an experiment and its nights. Returns false when there was no such experiment.
    @discardableResult
    public func delete(id: ExperimentID) throws -> Bool {
        try database.write { db in
            try db.execute(sql: "DELETE FROM experiment WHERE id = ?", arguments: [id.rawValue.uuidString])
            return db.changesCount > 0
        }
    }

    // MARK: Nights

    /// Records one night, replacing an earlier record of the same day while the experiment runs. The arm and the
    /// washout flag come from the schedule, never from the caller. A night with no measurement passes
    /// `outcomeValue: nil` and is stored as absent.
    @discardableResult
    public func recordNight(experimentID: ExperimentID, day: DayIdentity, adherence: ExperimentAdherence,
                            outcomeValue: Double?, otherValues: [String: Double] = [:], at date: Date) throws -> ExperimentNight {
        try database.write { db in
            let experiment = try Self.runningExperiment(experimentID, in: db)
            let arm: ExperimentArm, washout: Bool
            switch experiment.schedule.role(on: day) {
            case .on: arm = .on; washout = false
            case .off: arm = .off; washout = false
            case .washout(let washoutArm): arm = washoutArm; washout = true
            case .outside: throw ExperimentError.outsideExperiment
            }
            let night = try ExperimentNight(experimentID: experimentID, day: day, arm: arm, isWashout: washout,
                                            adherence: adherence, outcomeValue: outcomeValue,
                                            otherValues: otherValues, recordedAt: date)
            guard let dayKey = day.routineDayKey else { throw ExperimentError.invalidDay }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let others = String(decoding: try encoder.encode(otherValues), as: UTF8.self)
            try db.execute(sql: """
                INSERT INTO experiment_night(experiment_id, local_day, arm, washout, adherence, outcome_value, other_values, recorded_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(experiment_id, local_day) DO UPDATE SET arm = excluded.arm, washout = excluded.washout,
                    adherence = excluded.adherence, outcome_value = excluded.outcome_value,
                    other_values = excluded.other_values, recorded_at = excluded.recorded_at
                """, arguments: [experimentID.rawValue.uuidString, dayKey, arm.rawValue, washout ? 1 : 0,
                                 adherence.rawValue, outcomeValue, others, date.timeIntervalSince1970])
            return night
        }
    }

    /// Every recorded night, oldest day first.
    public func nights(experimentID: ExperimentID) throws -> [ExperimentNight] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM experiment_night WHERE experiment_id = ? ORDER BY local_day",
                             arguments: [experimentID.rawValue.uuidString]).map(Self.night(from:))
        }
    }

    /// Reads the intervention rule's check for a day. A night with no check is unknown, never missed.
    public func adherence(of experiment: Experiment, on day: DayIdentity, routine: RoutineStore) throws -> ExperimentAdherence {
        .from(try routine.check(protocolID: experiment.start.protocolID, ruleKey: experiment.start.ruleKey, day: day))
    }

    // MARK: Reports

    /// The report for one stored experiment. See `ExperimentAnalyzer.report` for the inputs.
    public func report(experimentID: ExperimentID, baseline: [DayIdentity: Double],
                       otherBaselines: [String: [DayIdentity: Double]] = [:], alsoMetrics: [ExperimentMetric] = [],
                       lastNight: DayIdentity, policy: ExperimentPolicy = .standard,
                       seed: UInt64? = nil) throws -> ExperimentReport {
        guard let experiment = try experiment(id: experimentID) else { throw ExperimentError.missingExperiment }
        return ExperimentAnalyzer.report(experiment: experiment, nights: try nights(experimentID: experimentID),
                                         baseline: baseline, otherBaselines: otherBaselines, alsoMetrics: alsoMetrics,
                                         lastNight: lastNight, policy: policy, seed: seed)
    }

    // MARK: Storage helpers

    private static func runningExperiment(_ id: ExperimentID, in db: Database) throws -> Experiment {
        guard let experiment = try experiment(id, in: db) else { throw ExperimentError.missingExperiment }
        guard experiment.status == .running else { throw ExperimentError.notRunning }
        return experiment
    }

    private static func close(_ experiment: Experiment, as status: ExperimentStatus, endDay: DayIdentity,
                              in db: Database) throws -> Experiment {
        guard let key = endDay.routineDayKey else { throw ExperimentError.invalidDay }
        try db.execute(sql: "UPDATE experiment SET status = ?, end_day = ? WHERE id = ?",
                       arguments: [status.rawValue, key, experiment.id.rawValue.uuidString])
        return Experiment(start: experiment.start, status: status, endDay: endDay)
    }

    private static func experiment(_ id: ExperimentID, in db: Database) throws -> Experiment? {
        try Row.fetchOne(db, sql: "SELECT * FROM experiment WHERE id = ?", arguments: [id.rawValue.uuidString])
            .map(experiment(from:))
    }

    private static func experiment(from row: Row) throws -> Experiment {
        guard let id = UUID(uuidString: row["id"] as String),
              let protocolID = UUID(uuidString: row["protocol_id"] as String),
              let design = ExperimentDesign(kind: row["design"] as String, length: row["design_length"] as Int?),
              let benefit = ExperimentBenefit(rawValue: row["outcome_direction"] as String),
              let startDay = DayIdentity(routineDayKey: row["start_day"] as String),
              let status = ExperimentStatus(rawValue: row["status"] as String) else { throw ExperimentError.corruptRecord }
        let endDay: DayIdentity?
        if let key = row["end_day"] as String? {
            guard let day = DayIdentity(routineDayKey: key) else { throw ExperimentError.corruptRecord }
            endDay = day
        } else {
            endDay = nil
        }
        let start: ExperimentStart
        do {
            start = try ExperimentStart(
                id: ExperimentID(rawValue: id), protocolID: ProtocolID(rawValue: protocolID),
                title: row["title"] as String, interventionName: row["intervention_name"] as String,
                ruleKey: RuleKey(rawValue: row["rule_key"] as String), design: design, washout: row["washout"] as Int,
                minimumNightsPerArm: row["minimum_nights"] as Int, plannedNights: row["planned_nights"] as Int,
                outcome: ExperimentMetric(key: row["outcome_key"] as String, title: row["outcome_title"] as String,
                                          unit: row["outcome_unit"] as String, benefit: benefit),
                startDay: startDay, timeZoneIdentifier: row["time_zone_identifier"] as String,
                createdAt: Date(timeIntervalSince1970: row["created_at"] as Double))
        } catch { throw ExperimentError.corruptRecord }
        return Experiment(start: start, status: status, endDay: endDay)
    }

    private static func night(from row: Row) throws -> ExperimentNight {
        guard let id = UUID(uuidString: row["experiment_id"] as String),
              let day = DayIdentity(routineDayKey: row["local_day"] as String),
              let arm = ExperimentArm(rawValue: row["arm"] as String),
              let adherence = ExperimentAdherence(rawValue: row["adherence"] as String),
              let others = try? JSONDecoder().decode([String: Double].self, from: Data((row["other_values"] as String).utf8))
        else { throw ExperimentError.corruptRecord }
        do {
            return try ExperimentNight(experimentID: ExperimentID(rawValue: id), day: day, arm: arm,
                                       isWashout: (row["washout"] as Int) == 1, adherence: adherence,
                                       outcomeValue: row["outcome_value"] as Double?, otherValues: others,
                                       recordedAt: Date(timeIntervalSince1970: row["recorded_at"] as Double))
        } catch { throw ExperimentError.corruptRecord }
    }
}
