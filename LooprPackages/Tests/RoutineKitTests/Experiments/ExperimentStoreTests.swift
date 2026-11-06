import DomainKit
import Foundation
import RoutineKit
import StorageKit
import Testing

private final class ExpTestDatabase {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ExperimentTests-\(UUID().uuidString)")
    private(set) var database: StorageDatabase
    var store: ExperimentStore { ExperimentStore(database: database) }
    var routine: RoutineStore { RoutineStore(database: database) }

    init() throws {
        database = try StorageDatabase(url: root.appendingPathComponent("experiments.sqlite"), applicationVersion: "experiment-tests")
    }

    deinit {
        try? database.databasePool.close()
        try? FileManager.default.removeItem(at: root)
    }

    /// Closes and opens the same file, as a relaunch would.
    func reopen() throws {
        try database.databasePool.close()
        database = try StorageDatabase(url: root.appendingPathComponent("experiments.sqlite"), applicationVersion: "experiment-tests")
    }

    @discardableResult
    func createProtocol(id: ProtocolID = ExpFixtures.protocolID) throws -> ProtocolVersion {
        try routine.createProtocol(
            RoutineProtocol(id: id, name: "Sleep first", createdAt: ExpFixtures.createdAt),
            rules: [ProtocolRule(key: "magnesium", title: "Magnesium glycinate, 300 mg", group: .supplements)],
            activate: false)
    }

    func execute(_ sql: String) throws {
        try database.write { db in try db.execute(sql: sql) }
    }

    func count(_ table: String) throws -> Int64 { try database.tableRowCounts()[table] ?? -1 }
}

private func make(id: ExperimentID = ExpFixtures.experimentID, design: ExperimentDesign = .alternatingDays, washout: Int = 0,
                  minimum: Int = 3, planned: Int = 14, outcome: ExperimentMetric = .deepSleep) throws -> ExperimentStart {
    try ExpFixtures.start(id: id, design: design, washout: washout, minimum: minimum, planned: planned, outcome: outcome)
}

struct ExperimentStoreTests {
    @Test func aStartedExperimentReadsBackWithEveryFieldAndSurvivesARestart() throws {
        let context = try ExpTestDatabase()
        try context.createProtocol()
        let start = try make(design: .blocks(length: 7), washout: 2, minimum: 5, planned: 28, outcome: .sleepHeartRate)
        let started = try context.store.start(start)
        #expect(started == Experiment(start: start, status: .running, endDay: nil))

        for _ in 0..<2 {
            let stored = try #require(try context.store.experiment(id: start.id))
            #expect(stored.start == start && stored.status == .running && stored.endDay == nil)
            #expect(stored.start.design == .blocks(length: 7) && stored.start.washout == 2)
            #expect(stored.start.outcome == .sleepHeartRate && stored.start.outcome.benefit == .lower)
            #expect(stored.start.ruleKey == "magnesium" && stored.start.interventionName == "magnesium")
            #expect(stored.start.startDay == ExpFixtures.startDay && stored.start.timeZoneIdentifier == "Europe/Berlin")
            #expect(try context.store.running() == stored)
            #expect(try context.store.experiments() == [stored])
            try context.reopen()
        }
        #expect(try context.store.experiment(id: ExperimentID()) == nil)
    }

    @Test func theOutcomeIsFixedOnDayOneAndNoCallChangesIt() throws {
        let context = try ExpTestDatabase()
        try context.createProtocol()
        try context.store.start(make())

        // A second start with the same id and another outcome is refused and leaves the first alone.
        #expect(throws: ExperimentError.duplicateExperiment) { try context.store.start(make(outcome: .hrv)) }
        #expect(try context.store.experiment(id: ExpFixtures.experimentID)?.start.outcome == .deepSleep)

        // Nothing the person does later touches it: nights, a stop, a restart.
        try context.store.recordNight(experimentID: ExpFixtures.experimentID, day: ExpFixtures.night(0), adherence: .kept,
                                      outcomeValue: 70, at: ExpFixtures.createdAt)
        try context.store.stop(id: ExpFixtures.experimentID, lastNight: ExpFixtures.night(3))
        try context.reopen()
        let stored = try #require(try context.store.experiment(id: ExpFixtures.experimentID))
        #expect(stored.start.outcome == .deepSleep && stored.start.outcome.benefit == .higher)
        #expect(stored.status == .stopped)

        // The database refuses it too, whichever code path writes.
        for sql in [
            "UPDATE experiment SET outcome_key = 'hrvRMSSD'",
            "UPDATE experiment SET outcome_title = 'HRV'",
            "UPDATE experiment SET outcome_unit = 'ms'",
            "UPDATE experiment SET outcome_direction = 'lower'",
            "UPDATE experiment SET design = 'blocks', design_length = 7",
            "UPDATE experiment SET washout = 0",
            "UPDATE experiment SET planned_nights = 20",
            "UPDATE experiment SET minimum_nights = 2",
            "UPDATE experiment SET start_day = '2026-10-13'",
            "UPDATE experiment SET rule_key = 'caffeine'",
            "UPDATE experiment SET title = 'Another'",
            "UPDATE experiment SET intervention_name = 'iron'"
        ] {
            #expect(throws: (any Error).self, "\(sql)") { try context.execute(sql) }
        }
        #expect(try context.store.experiment(id: ExpFixtures.experimentID) == stored)
    }

    @Test func aFinishedExperimentCannotMoveBackToRunning() throws {
        let context = try ExpTestDatabase()
        try context.createProtocol()
        try context.store.start(make())
        try context.store.finish(id: ExpFixtures.experimentID, lastNight: ExpFixtures.night(13))
        #expect(throws: (any Error).self) { try context.execute("UPDATE experiment SET status = 'running', end_day = NULL") }
        #expect(throws: (any Error).self) { try context.execute("UPDATE experiment SET end_day = '2026-10-01'") }
        // A running experiment must have no end day and an ended one must have one.
        #expect(throws: (any Error).self) {
            try context.execute("""
                INSERT INTO experiment(id, protocol_id, title, intervention_name, rule_key, design, washout, minimum_nights,
                    planned_nights, outcome_key, outcome_title, outcome_unit, outcome_direction, start_day,
                    time_zone_identifier, created_at, status, end_day)
                VALUES ('x', '\(ExpFixtures.protocolID.rawValue.uuidString)', 't', 'n', 'k', 'alternating', 0, 3, 14, 'k', 'T', 'min',
                    'higher', '2026-10-12', 'UTC', 1, 'running', '2026-10-20')
                """)
        }
    }

    @Test func onlyOneExperimentRunsAtATime() throws {
        let context = try ExpTestDatabase()
        try context.createProtocol()
        try context.store.start(make())
        let second = ExperimentID()
        #expect(throws: ExperimentError.anotherExperimentRunning) { try context.store.start(make(id: second)) }
        try context.store.stop(id: ExpFixtures.experimentID, lastNight: ExpFixtures.night(5))
        try context.store.start(make(id: second))
        #expect(try context.store.running()?.id == second)
        #expect(try context.store.experiments().count == 2)
    }

    @Test func anExperimentNeedsAnExistingProtocol() throws {
        let context = try ExpTestDatabase()
        #expect(throws: ExperimentError.missingProtocol) { try context.store.start(make()) }
        #expect(try context.count("experiment") == 0)
    }

    @Test func aNightTakesItsArmFromTheScheduleAndStoresAnAbsentOutcomeAsNull() throws {
        let context = try ExpTestDatabase()
        try context.createProtocol()
        let id = ExpFixtures.experimentID
        try context.store.start(make(design: .blocks(length: 7), washout: 2, minimum: 5, planned: 28))

        let on = try context.store.recordNight(experimentID: id, day: ExpFixtures.night(0), adherence: .kept, outcomeValue: 71,
                                               otherValues: ["timeToFallAsleepMinutes": 12], at: ExpFixtures.createdAt)
        #expect(on.arm == .on && !on.isWashout)
        let washout = try context.store.recordNight(experimentID: id, day: ExpFixtures.night(7), adherence: .unknown,
                                                    outcomeValue: 55, at: ExpFixtures.createdAt)
        #expect(washout.arm == .off && washout.isWashout)
        let absent = try context.store.recordNight(experimentID: id, day: ExpFixtures.night(10), adherence: .kept,
                                                   outcomeValue: nil, at: ExpFixtures.createdAt)
        #expect(absent.outcomeValue == nil && absent.arm == .off)
        let zero = try context.store.recordNight(experimentID: id, day: ExpFixtures.night(11), adherence: .kept,
                                                 outcomeValue: 0, at: ExpFixtures.createdAt)
        #expect(zero.outcomeValue == 0)

        let stored = try context.store.nights(experimentID: id)
        #expect(stored.map(\.day) == [ExpFixtures.night(0), ExpFixtures.night(7), ExpFixtures.night(10), ExpFixtures.night(11)])
        #expect(stored[0].otherValues == ["timeToFallAsleepMinutes": 12] && stored[0].outcomeValue == 71)
        #expect(stored[2].outcomeValue == nil && stored[3].outcomeValue == 0)
        #expect(try context.database.readInteger(sql: "SELECT COUNT(*) FROM experiment_night WHERE outcome_value IS NULL") == 1)
        #expect(try context.database.readInteger(sql: "SELECT COUNT(*) FROM experiment_night WHERE outcome_value = 0") == 1)

        #expect(throws: ExperimentError.outsideExperiment) {
            try context.store.recordNight(experimentID: id, day: ExpFixtures.night(-1), adherence: .kept, outcomeValue: 1, at: ExpFixtures.createdAt)
        }
        #expect(throws: ExperimentError.outsideExperiment) {
            try context.store.recordNight(experimentID: id, day: ExpFixtures.night(28), adherence: .kept, outcomeValue: 1, at: ExpFixtures.createdAt)
        }
        #expect(throws: ExperimentError.invalidNight) {
            try context.store.recordNight(experimentID: id, day: ExpFixtures.night(1), adherence: .kept, outcomeValue: .nan, at: ExpFixtures.createdAt)
        }
        #expect(throws: ExperimentError.missingExperiment) {
            try context.store.recordNight(experimentID: ExperimentID(), day: ExpFixtures.night(1), adherence: .kept, outcomeValue: 1, at: ExpFixtures.createdAt)
        }
        #expect(try context.count("experiment_night") == 4)
    }

    @Test func recordingTheSameDayAgainReplacesItWhenATimeZoneRepeatsADay() throws {
        let context = try ExpTestDatabase()
        try context.createProtocol()
        let id = ExpFixtures.experimentID
        try context.store.start(make())
        try context.store.recordNight(experimentID: id, day: ExpFixtures.night(2), adherence: .unknown, outcomeValue: nil, at: ExpFixtures.createdAt)
        try context.store.recordNight(experimentID: id, day: ExpFixtures.night(2), adherence: .kept, outcomeValue: 64, at: ExpFixtures.createdAt.addingTimeInterval(60))
        let stored = try context.store.nights(experimentID: id)
        #expect(stored.count == 1 && stored[0].outcomeValue == 64 && stored[0].adherence == .kept)
        #expect(stored[0].recordedAt == ExpFixtures.createdAt.addingTimeInterval(60))
    }

    @Test func finishNeedsThePlannedNightsToBeOver() throws {
        let context = try ExpTestDatabase()
        try context.createProtocol()
        let id = ExpFixtures.experimentID
        try context.store.start(make())
        #expect(throws: ExperimentError.plannedNightsNotOver) { try context.store.finish(id: id, lastNight: ExpFixtures.night(12)) }
        #expect(try context.store.experiment(id: id)?.status == .running)

        let finished = try context.store.finish(id: id, lastNight: ExpFixtures.night(20))
        #expect(finished.status == .finished && finished.endDay == ExpFixtures.night(13) && !finished.stoppedEarly)
        #expect(try context.store.running() == nil)
        #expect(throws: ExperimentError.notRunning) { try context.store.finish(id: id, lastNight: ExpFixtures.night(20)) }
        #expect(throws: ExperimentError.notRunning) { try context.store.stop(id: id, lastNight: ExpFixtures.night(20)) }
        #expect(throws: ExperimentError.notRunning) {
            try context.store.recordNight(experimentID: id, day: ExpFixtures.night(0), adherence: .kept, outcomeValue: 1, at: ExpFixtures.createdAt)
        }
        #expect(throws: ExperimentError.missingExperiment) { try context.store.finish(id: ExperimentID(), lastNight: ExpFixtures.night(20)) }
    }

    @Test func stoppingEndsTheNightsAtTheLastNightThatCounted() throws {
        let context = try ExpTestDatabase()
        try context.createProtocol()
        let id = ExpFixtures.experimentID
        try context.store.start(make())
        let stopped = try context.store.stop(id: id, lastNight: ExpFixtures.night(5))
        #expect(stopped.status == .stopped && stopped.endDay == ExpFixtures.night(5) && stopped.stoppedEarly)
        #expect(stopped.schedule.role(on: ExpFixtures.night(5)) == .off && stopped.schedule.role(on: ExpFixtures.night(6)) == .outside)
        #expect(try context.store.experiment(id: id) == stopped)

        let early = ExperimentID(), late = ExperimentID()
        try context.store.start(make(id: early))
        #expect(try context.store.stop(id: early, lastNight: ExpFixtures.night(-4)).endDay == ExpFixtures.night(0))
        try context.store.start(make(id: late))
        #expect(try context.store.stop(id: late, lastNight: ExpFixtures.night(40)).endDay == ExpFixtures.night(13))
    }

    @Test func aStoredExperimentReportsLikeTheAnalyzer() throws {
        let context = try ExpTestDatabase()
        try context.createProtocol()
        let id = ExpFixtures.experimentID
        try context.store.start(make())
        let experiment = try ExpFixtures.experiment()
        var on = ExpFixtures.clearOn[...], off = ExpFixtures.clearOff[...]
        for scheduled in experiment.schedule.nights {
            let value = scheduled.role == .on ? on.popFirst() : off.popFirst()
            try context.store.recordNight(experimentID: id, day: scheduled.day, adherence: .kept, outcomeValue: value, at: ExpFixtures.createdAt)
        }
        let report = try context.store.report(experimentID: id, baseline: ExpFixtures.baseline(), lastNight: ExpFixtures.night(13))
        #expect(report.label == .strong && report.difference == 20)
        let expected = ExperimentAnalyzer.report(experiment: experiment, nights: try context.store.nights(experimentID: id),
                                                 baseline: ExpFixtures.baseline(), lastNight: ExpFixtures.night(13))
        #expect(report == expected)
        #expect(throws: ExperimentError.missingExperiment) {
            try context.store.report(experimentID: ExperimentID(), baseline: [:], lastNight: ExpFixtures.night(13))
        }
    }

    @Test func adherenceComesFromTheRoutineCheckOnTheInterventionRule() throws {
        let context = try ExpTestDatabase()
        let version = try context.createProtocol()
        let experiment = try context.store.start(make())
        let rule: RuleKey = "magnesium"
        func check(_ offset: Int, _ state: CheckState) throws {
            try context.routine.recordCheck(
                RuleCheck(ruleKey: rule, day: ExpFixtures.night(offset), version: version.number, state: state, source: .manual,
                          recordedAt: ExpFixtures.createdAt), protocolID: ExpFixtures.protocolID)
        }
        try check(0, .kept)
        try check(1, .missed)
        try check(2, .pending)
        try check(3, .unknown)
        #expect(try context.store.adherence(of: experiment, on: ExpFixtures.night(0), routine: context.routine) == .kept)
        #expect(try context.store.adherence(of: experiment, on: ExpFixtures.night(1), routine: context.routine) == .missed)
        #expect(try context.store.adherence(of: experiment, on: ExpFixtures.night(2), routine: context.routine) == .unknown)
        #expect(try context.store.adherence(of: experiment, on: ExpFixtures.night(3), routine: context.routine) == .unknown)
        // No check at all is unknown, never missed.
        #expect(try context.store.adherence(of: experiment, on: ExpFixtures.night(4), routine: context.routine) == .unknown)
        // A tick by hand overrides what a source said.
        try context.routine.overrideCheck(protocolID: ExpFixtures.protocolID, ruleKey: rule, day: ExpFixtures.night(1),
                                          state: .kept, at: ExpFixtures.createdAt)
        #expect(try context.store.adherence(of: experiment, on: ExpFixtures.night(1), routine: context.routine) == .kept)
        #expect(ExperimentAdherence.from(nil) == .unknown)
    }

    @Test func deletingAProtocolRemovesItsExperimentsAndNights() throws {
        let context = try ExpTestDatabase()
        try context.createProtocol()
        let other = ProtocolID()
        try context.createProtocol(id: other)
        try context.store.start(make())
        try context.store.recordNight(experimentID: ExpFixtures.experimentID, day: ExpFixtures.night(0), adherence: .kept,
                                      outcomeValue: 70, at: ExpFixtures.createdAt)
        try context.store.stop(id: ExpFixtures.experimentID, lastNight: ExpFixtures.night(2))
        let keptStart = try ExperimentStart(protocolID: other, title: "Other", interventionName: "other", ruleKey: "magnesium",
                                            design: .alternatingDays, washout: 0, minimumNightsPerArm: 3, plannedNights: 14,
                                            outcome: .hrv, startDay: ExpFixtures.startDay, timeZoneIdentifier: "UTC",
                                            createdAt: ExpFixtures.createdAt)
        try context.store.start(keptStart)
        try context.store.recordNight(experimentID: keptStart.id, day: ExpFixtures.night(0), adherence: .kept, outcomeValue: 50, at: ExpFixtures.createdAt)

        #expect(try context.routine.deleteProtocol(id: ExpFixtures.protocolID))
        #expect(try context.store.experiment(id: ExpFixtures.experimentID) == nil)
        #expect(try context.count("experiment") == 1 && context.count("experiment_night") == 1)
        #expect(try context.store.experiments().map(\.id) == [keptStart.id])
    }

    @Test func deletingOneExperimentLeavesTheOthers() throws {
        let context = try ExpTestDatabase()
        try context.createProtocol()
        let id = ExpFixtures.experimentID
        try context.store.start(make())
        try context.store.recordNight(experimentID: id, day: ExpFixtures.night(0), adherence: .kept, outcomeValue: 70, at: ExpFixtures.createdAt)
        try context.store.stop(id: id, lastNight: ExpFixtures.night(1))
        let next = ExperimentID()
        try context.store.start(make(id: next))
        #expect(try context.store.delete(id: id))
        #expect(try context.count("experiment") == 1 && context.count("experiment_night") == 0)
        #expect(try context.store.delete(id: id) == false)
        #expect(try context.store.running()?.id == next)
    }

    @Test func deletingADayRemovesThatNightAndKeepsTheExperiment() throws {
        let context = try ExpTestDatabase()
        try context.createProtocol()
        let id = ExpFixtures.experimentID
        try context.store.start(make())
        for offset in 0..<3 {
            try context.store.recordNight(experimentID: id, day: ExpFixtures.night(offset), adherence: .kept, outcomeValue: 60, at: ExpFixtures.createdAt)
        }
        try context.database.delete(localDay: "2026-10-13")
        #expect(try context.store.nights(experimentID: id).map(\.day) == [ExpFixtures.night(0), ExpFixtures.night(2)])
        #expect(try context.store.experiment(id: id) != nil)
    }

    @Test func deletingAllAccountDataEmptiesTheExperimentTables() throws {
        let context = try ExpTestDatabase()
        try context.createProtocol()
        try context.store.start(make())
        try context.store.recordNight(experimentID: ExpFixtures.experimentID, day: ExpFixtures.night(0), adherence: .kept,
                                      outcomeValue: 70, at: ExpFixtures.createdAt)
        #expect(try context.count("experiment") == 1 && context.count("experiment_night") == 1)
        try context.database.deleteAllAccountData()
        let counts = try context.database.tableRowCounts()
        for table in ExperimentStorageSchema.tableNames { #expect(counts[table] == 0, "\(table)") }
    }

    @Test func aStartRecordIsValidatedWhenBuiltAndWhenDecoded() throws {
        #expect(throws: ExperimentError.missingTitle) {
            try ExperimentStart(protocolID: ExpFixtures.protocolID, title: "  ", interventionName: "x", ruleKey: "k",
                                design: .alternatingDays, washout: 0, minimumNightsPerArm: 3, plannedNights: 14, outcome: .hrv,
                                startDay: ExpFixtures.startDay, timeZoneIdentifier: "UTC", createdAt: ExpFixtures.createdAt)
        }
        #expect(throws: ExperimentError.missingInterventionName) {
            try ExperimentStart(protocolID: ExpFixtures.protocolID, title: "t", interventionName: "", ruleKey: "k",
                                design: .alternatingDays, washout: 0, minimumNightsPerArm: 3, plannedNights: 14, outcome: .hrv,
                                startDay: ExpFixtures.startDay, timeZoneIdentifier: "UTC", createdAt: ExpFixtures.createdAt)
        }
        #expect(throws: ExperimentError.invalidRuleKey) {
            try ExperimentStart(protocolID: ExpFixtures.protocolID, title: "t", interventionName: "x", ruleKey: " ",
                                design: .alternatingDays, washout: 0, minimumNightsPerArm: 3, plannedNights: 14, outcome: .hrv,
                                startDay: ExpFixtures.startDay, timeZoneIdentifier: "UTC", createdAt: ExpFixtures.createdAt)
        }
        #expect(throws: ExperimentError.invalidDay) {
            try ExperimentStart(protocolID: ExpFixtures.protocolID, title: "t", interventionName: "x", ruleKey: "k",
                                design: .alternatingDays, washout: 0, minimumNightsPerArm: 3, plannedNights: 14, outcome: .hrv,
                                startDay: DayIdentity(year: 2026, month: 13, day: 1), timeZoneIdentifier: "UTC", createdAt: ExpFixtures.createdAt)
        }
        #expect(throws: ExperimentError.invalidOutcome) {
            try ExperimentStart(protocolID: ExpFixtures.protocolID, title: "t", interventionName: "x", ruleKey: "k",
                                design: .alternatingDays, washout: 0, minimumNightsPerArm: 3, plannedNights: 14,
                                outcome: ExperimentMetric(key: "", title: "", unit: "", benefit: .higher),
                                startDay: ExpFixtures.startDay, timeZoneIdentifier: "UTC", createdAt: ExpFixtures.createdAt)
        }

        let start = try make(design: .blocks(length: 7), washout: 1, minimum: 5, planned: 28)
        let data = try JSONEncoder().encode(start)
        #expect(try JSONDecoder().decode(ExperimentStart.self, from: data) == start)
        let broken = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"washout\":1", with: "\"washout\":9")
        #expect(throws: ExperimentError.invalidWashout) { try JSONDecoder().decode(ExperimentStart.self, from: Data(broken.utf8)) }
    }

    @Test func aNightRefusesValuesItCannotUse() {
        #expect(throws: ExperimentError.invalidNight) {
            try ExperimentNight(experimentID: ExpFixtures.experimentID, day: ExpFixtures.startDay, arm: .on, isWashout: false,
                                adherence: .kept, outcomeValue: .infinity, recordedAt: ExpFixtures.createdAt)
        }
        #expect(throws: ExperimentError.invalidNight) {
            try ExperimentNight(experimentID: ExpFixtures.experimentID, day: ExpFixtures.startDay, arm: .on, isWashout: false,
                                adherence: .kept, outcomeValue: 1, otherValues: ["x": .nan], recordedAt: ExpFixtures.createdAt)
        }
        #expect(throws: ExperimentError.invalidDay) {
            try ExperimentNight(experimentID: ExpFixtures.experimentID, day: DayIdentity(year: 2026, month: 2, day: 30), arm: .on,
                                isWashout: false, adherence: .kept, outcomeValue: 1, recordedAt: ExpFixtures.createdAt)
        }
    }
}
