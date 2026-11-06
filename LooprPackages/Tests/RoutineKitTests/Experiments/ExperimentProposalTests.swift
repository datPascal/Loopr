import DomainKit
import Foundation
import Testing
@testable import RoutineKit

struct ExperimentProposalTests {
    private func version(withRule: Bool) throws -> ProtocolVersion {
        var rules = [ProtocolRule(key: "lights-out", title: "Lights out", group: .sleep)]
        if withRule { rules.append(ProtocolRule(key: "magnesium", title: "Magnesium glycinate, 300 mg", group: .supplements)) }
        return try ProtocolVersion(protocolID: ExpFixtures.protocolID, number: 3, createdAt: ExpFixtures.createdAt, rules: rules)
    }

    private func finished(on: [Double], off: [Double], minimum: Int = 3,
                          outcome: ExperimentMetric = .deepSleep) throws -> (Experiment, ExperimentReport) {
        let experiment = try ExpFixtures.experiment(minimum: minimum, outcome: outcome, status: .finished,
                                                    endDay: ExpFixtures.night(13))
        let nights = try ExpFixtures.nights(for: experiment, on: on, off: off)
        return (experiment, ExpFixtures.report(experiment, nights: nights))
    }

    @Test func aClearResultKeepsTheRuleAndRecordsItInTheNote() throws {
        let (experiment, report) = try finished(on: ExpFixtures.clearOn, off: ExpFixtures.clearOff)
        let current = try version(withRule: true)
        let change = try #require(ExperimentProposal.keepingResult(of: experiment, report: report, in: current))
        #expect(change.rules == current.rules && !change.addsRule)
        #expect(change.note == "Kept after an experiment of 14 nights. Deep sleep +20 min.")
    }

    @Test func aRuleMissingFromTheVersionIsAddedAtTheEnd() throws {
        let (experiment, report) = try finished(on: ExpFixtures.clearOn, off: ExpFixtures.clearOff)
        let current = try version(withRule: false)
        let change = try #require(ExperimentProposal.keepingResult(of: experiment, report: report, in: current))
        #expect(change.addsRule)
        #expect(change.rules.count == 2 && change.rules.first == current.rules.first)
        let added = try #require(change.rules.last)
        #expect(added.key == "magnesium" && added.title == "Magnesium glycinate, 300 mg" && added.target == .done)
        // The proposal is a valid next version.
        _ = try ProtocolVersion(protocolID: current.protocolID, number: current.number + 1, createdAt: ExpFixtures.createdAt,
                                note: change.note, rules: change.rules)
    }

    @Test func nothingElseBecomesAChangeToTheProtocol() throws {
        let current = try version(withRule: true)
        let none = try finished(on: ExpFixtures.sameOn, off: ExpFixtures.sameOff)
        #expect(none.1.label == .noChange)
        #expect(ExperimentProposal.keepingResult(of: none.0, report: none.1, in: current) == nil)

        let early = try finished(on: ExpFixtures.noisyOn, off: ExpFixtures.steadyOff)
        #expect(early.1.label == .early)
        #expect(ExperimentProposal.keepingResult(of: early.0, report: early.1, in: current) == nil)

        let uncalled = try finished(on: ExpFixtures.noisyOn, off: ExpFixtures.level66Off)
        #expect(ExperimentProposal.keepingResult(of: uncalled.0, report: uncalled.1, in: current) == nil)

        // A clear result that points the wrong way: lower heart rate is better, and on nights ran higher.
        let worse = try finished(on: ExpFixtures.clearOn, off: ExpFixtures.clearOff, outcome: .sleepHeartRate)
        #expect(worse.1.label == .strong && worse.1.favors == .worse)
        #expect(ExperimentProposal.keepingResult(of: worse.0, report: worse.1, in: current) == nil)

        // A running experiment never proposes, even when its numbers would already clear the spread.
        let running = try ExpFixtures.experiment()
        let report = ExpFixtures.report(running, nights: try ExpFixtures.nights(for: running, on: ExpFixtures.clearOn, off: ExpFixtures.clearOff))
        #expect(report.label == .strong)
        #expect(ExperimentProposal.keepingResult(of: running, report: report, in: current) == nil)

        // A report for another experiment is not accepted.
        let (experiment, clear) = try finished(on: ExpFixtures.clearOn, off: ExpFixtures.clearOff)
        let stranger = try ExpFixtures.experiment(id: ExperimentID(), status: .finished, endDay: ExpFixtures.night(13))
        #expect(ExperimentProposal.keepingResult(of: stranger, report: clear, in: current) == nil)
        #expect(ExperimentProposal.keepingResult(of: experiment, report: clear, in: current) != nil)
    }
}
