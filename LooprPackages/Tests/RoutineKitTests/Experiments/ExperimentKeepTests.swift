import DomainKit
import Foundation
import StorageKit
import Testing
@testable import RoutineKit

private final class KeepTestDatabase {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ExperimentKeepTests-\(UUID().uuidString)")
    let database: StorageDatabase
    var routine: RoutineStore { RoutineStore(database: database) }

    init() throws {
        database = try StorageDatabase(url: root.appendingPathComponent("keep.sqlite"), applicationVersion: "experiment-keep-tests")
    }

    deinit {
        try? database.databasePool.close()
        try? FileManager.default.removeItem(at: root)
    }

    static let lightsOut = ProtocolRule(key: "lights-out", title: "Lights out", group: .sleep)
    static let magnesium = ProtocolRule(key: "magnesium", title: "Magnesium glycinate, 300 mg", group: .supplements)

    @discardableResult
    func createProtocol(rules: [ProtocolRule]) throws -> ProtocolVersion {
        try routine.createProtocol(RoutineProtocol(id: ExpFixtures.protocolID, name: "Sleep first", createdAt: ExpFixtures.createdAt),
                                   rules: rules)
    }
}

/// LV-07.3: "Keep it in my protocol" saves exactly one new version through `RoutineStore.saveVersion`, leaves every
/// earlier version as it was, and a second Keep writes nothing.
struct ExperimentKeepTests {
    private let keptAt = ExpFixtures.createdAt.addingTimeInterval(30 * 86_400)

    private func finished(on: [Double] = ExpFixtures.clearOn, off: [Double] = ExpFixtures.clearOff) throws -> (Experiment, ExperimentReport) {
        let experiment = try ExpFixtures.experiment(status: .finished, endDay: ExpFixtures.night(13))
        return (experiment, ExpFixtures.report(experiment, nights: try ExpFixtures.nights(for: experiment, on: on, off: off)))
    }

    @Test func keepAddsTheRuleAsOneNewVersionAndASecondKeepDoesNothing() throws {
        let context = try KeepTestDatabase()
        let first = try context.createProtocol(rules: [KeepTestDatabase.lightsOut])
        let (experiment, report) = try finished()
        #expect(ExperimentKeep.canKeep(experiment, report: report, versions: [first]))
        #expect(ExperimentKeep.keptVersion(of: experiment, report: report, in: [first]) == nil)

        let saved = try context.routine.keep(experiment, report: report, at: keptAt)
        guard case .saved(let version) = saved else { Issue.record("Expected a saved version, got \(saved)"); return }
        #expect(version.number == 2)
        #expect(version.rules.map(\.key) == ["lights-out", "magnesium"])
        #expect(version.rule(for: "magnesium")?.title == "Magnesium glycinate, 300 mg")
        #expect(version.note == "Kept after an experiment of 14 nights. Deep sleep +20 min.")

        let versions = try context.routine.versions(protocolID: ExpFixtures.protocolID)
        #expect(versions.count == 2)
        #expect(versions.first == first, "Version 1 stays exactly as it was saved")
        #expect(ExperimentKeep.keptVersion(of: experiment, report: report, in: versions) == version)
        #expect(!ExperimentKeep.canKeep(experiment, report: report, versions: versions))

        let again = try context.routine.keep(experiment, report: report, at: keptAt.addingTimeInterval(60))
        #expect(again == .alreadyKept(version))
        #expect(try context.routine.versions(protocolID: ExpFixtures.protocolID) == versions, "A second Keep writes nothing")
        #expect(try context.routine.activeProtocol()?.latestVersion.number == 2)
    }

    @Test func aRuleAlreadyInTheProtocolKeepsItsRulesAndRecordsTheResult() throws {
        let context = try KeepTestDatabase()
        let first = try context.createProtocol(rules: [KeepTestDatabase.lightsOut, KeepTestDatabase.magnesium])
        let (experiment, report) = try finished()
        let version = try context.routine.keep(experiment, report: report, at: keptAt).version
        #expect(version.number == 2 && version.rules == first.rules)
        #expect(version.note?.hasPrefix("Kept after an experiment of 14 nights.") == true)
        #expect(try context.routine.keep(experiment, report: report, at: keptAt) == .alreadyKept(version))
        #expect(try context.routine.versions(protocolID: ExpFixtures.protocolID).count == 2)
    }

    @Test func onlyAKeepableResultChangesTheProtocol() throws {
        let context = try KeepTestDatabase()
        let first = try context.createProtocol(rules: [KeepTestDatabase.lightsOut])

        let noChange = try finished(on: ExpFixtures.sameOn, off: ExpFixtures.sameOff)
        #expect(noChange.1.label == .noChange)
        #expect(throws: ExperimentKeepError.notKeepable) {
            try context.routine.keep(noChange.0, report: noChange.1, at: keptAt)
        }
        #expect(!ExperimentKeep.canKeep(noChange.0, report: noChange.1, versions: [first]))

        let running = try ExpFixtures.experiment()
        let report = ExpFixtures.report(running, nights: try ExpFixtures.nights(for: running, on: ExpFixtures.clearOn,
                                                                                off: ExpFixtures.clearOff))
        #expect(throws: ExperimentKeepError.notKeepable) { try context.routine.keep(running, report: report, at: keptAt) }

        #expect(try context.routine.versions(protocolID: ExpFixtures.protocolID) == [first], "A refused Keep writes nothing")
    }

    @Test func keepingIntoAMissingProtocolFails() throws {
        let context = try KeepTestDatabase()
        let (experiment, report) = try finished()
        #expect(throws: RoutineError.missingProtocol) { try context.routine.keep(experiment, report: report, at: keptAt) }
    }
}
