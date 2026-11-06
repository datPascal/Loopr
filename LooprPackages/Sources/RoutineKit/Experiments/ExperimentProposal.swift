import Foundation

/// What keeping a result would write: the rules of the next protocol version and the note that goes with it.
public struct ProposedProtocolChange: Equatable, Sendable {
    public let rules: [ProtocolRule]
    public let note: String
    /// True when the intervention rule was not in the version and the proposal adds it.
    public let addsRule: Bool
}

public enum ExperimentProposal {
    /// The rules to save as a new protocol version when the person keeps a result. Pure: step 3 saves it.
    ///
    /// Only a result that says the nights differed (Strong or Clear) and that points the way the person fixed as
    /// better is offered. Early, No change, a result that went the wrong way, and anything Loopr did not call are
    /// never turned into a change to the protocol. When the version already holds the rule, its rules stay as they
    /// are and the new version records the result in its note. When it does not, the rule joins the end of the list
    /// as a plain done-or-not rule.
    public static func keepingResult(of experiment: Experiment, report: ExperimentReport,
                                     in version: ProtocolVersion) -> ProposedProtocolChange? {
        guard experiment.status == .finished, report.experimentID == experiment.id,
              let label = report.label, label.claimsDifference, report.favors == .better,
              let headline = ExperimentCopy.resultHeadline(report: report) else { return nil }
        let key = experiment.start.ruleKey
        let note = "Kept after an experiment of \(ExperimentCopy.nights(report.nightsCompleted)). \(report.outcome.title) \(headline)."
        if version.rule(for: key) != nil {
            return ProposedProtocolChange(rules: version.rules, note: note, addsRule: false)
        }
        let rule = ProtocolRule(key: key, title: experiment.start.title)
        return ProposedProtocolChange(rules: version.rules + [rule], note: note, addsRule: true)
    }
}
