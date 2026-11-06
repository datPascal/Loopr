import DomainKit
import Foundation

/// What a Keep did.
public enum ExperimentKeepResult: Equatable, Sendable {
    /// A new protocol version holds the result.
    case saved(ProtocolVersion)
    /// An earlier Keep already saved this version. Nothing was written.
    case alreadyKept(ProtocolVersion)

    public var version: ProtocolVersion {
        switch self {
        case .saved(let version), .alreadyKept(let version): version
        }
    }
}

public enum ExperimentKeepError: Error, Equatable, LocalizedError, Sendable {
    /// The result is not one `ExperimentProposal` turns into a change: not finished, not Strong or Clear, or it went
    /// the other way.
    case notKeepable

    public var errorDescription: String? {
        switch self {
        case .notKeepable: "Loopr keeps a result only when it is Strong or Clear and went the way you wanted."
        }
    }
}

/// "Keep it in my protocol": the experiment's rule goes into the next protocol version through
/// `RoutineStore.saveVersion`, so every earlier version stays as it was (DEC-12.5).
///
/// A kept result is recognised by the version it wrote: a version of the experiment's protocol, saved after the
/// experiment started, that holds the rule and carries the note `ExperimentProposal` writes for this result. A second
/// Keep finds that version and writes nothing.
public enum ExperimentKeep {
    /// The version that kept this result, or nil when it is not kept. `versions` are the protocol's versions in any
    /// order; the earliest match wins.
    public static func keptVersion(of experiment: Experiment, report: ExperimentReport,
                                   in versions: [ProtocolVersion]) -> ProtocolVersion? {
        let ordered = versions.sorted { $0.number < $1.number }
        guard let latest = ordered.last,
              let note = ExperimentProposal.keepingResult(of: experiment, report: report, in: latest)?.note else { return nil }
        let start = experiment.start
        return ordered.first { version in
            version.protocolID == start.protocolID && version.note == note
                && version.rule(for: start.ruleKey) != nil && version.createdAt >= start.createdAt
        }
    }

    /// True when Keep would save a new version now.
    public static func canKeep(_ experiment: Experiment, report: ExperimentReport, versions: [ProtocolVersion]) -> Bool {
        guard keptVersion(of: experiment, report: report, in: versions) == nil,
              let latest = versions.max(by: { $0.number < $1.number }) else { return false }
        return ExperimentProposal.keepingResult(of: experiment, report: report, in: latest) != nil
    }
}

public extension RoutineStore {
    /// Saves the experiment's rule as the next version of its protocol, with the result in the version's note. Keeping
    /// a result that is already kept returns the version that holds it and writes nothing.
    @discardableResult
    func keep(_ experiment: Experiment, report: ExperimentReport, at date: Date) throws -> ExperimentKeepResult {
        let saved = try versions(protocolID: experiment.start.protocolID)
        guard let latest = saved.last else { throw RoutineError.missingProtocol }
        if let kept = ExperimentKeep.keptVersion(of: experiment, report: report, in: saved) { return .alreadyKept(kept) }
        guard let change = ExperimentProposal.keepingResult(of: experiment, report: report, in: latest) else {
            throw ExperimentKeepError.notKeepable
        }
        return .saved(try saveVersion(protocolID: experiment.start.protocolID, rules: change.rules, note: change.note, at: date))
    }
}
