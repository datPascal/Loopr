import DesignSystem
import Foundation

/// One night of a running experiment on the strip's bead row.
public struct TodayExperimentBead: Equatable, Sendable {
    public enum Arm: String, Equatable, Sendable { case on, off, washout }
    public enum Phase: String, Equatable, Sendable { case past, tonight, future }

    public let arm: Arm
    public let phase: Phase

    public init(arm: Arm, phase: Phase) {
        self.arm = arm
        self.phase = phase
    }
}

/// What the app read about the running experiment (DEC-12.13). Nil when none is running.
public struct TodayExperimentInput: Equatable, Sendable {
    public var title: String
    /// Tonight's night number, from 1.
    public var night: Int
    public var plannedNights: Int
    /// "Deep sleep", fixed on day 1.
    public var outcome: String
    /// RoutineKit's line for tonight from the schedule: "Tonight is a magnesium night." Nil when tonight is outside.
    public var tonight: String?
    public var beads: [TodayExperimentBead]
    public var isRunning: Bool

    public init(title: String, night: Int, plannedNights: Int, outcome: String, tonight: String?,
                beads: [TodayExperimentBead] = [], isRunning: Bool = true) {
        self.title = title
        self.night = night
        self.plannedNights = plannedNights
        self.outcome = outcome
        self.tonight = tonight
        self.beads = beads
        self.isRunning = isRunning
    }
}

/// The strip under the rail: "Experiment night 9 of 14", the title, the outcome and tonight's arm.
public struct TodayExperimentStrip: Equatable, Sendable {
    /// "Night 9 of 14".
    public let progress: String
    public let title: String
    /// "Outcome: deep sleep. Tonight is a magnesium night."
    public let detail: String
    public let beads: [TodayExperimentBead]

    /// Nil when nothing is running, or the input has no night inside the plan. The strip then draws nothing at all.
    public static func make(_ input: TodayExperimentInput?) -> TodayExperimentStrip? {
        guard let input, input.isRunning, input.plannedNights > 0, (1...input.plannedNights).contains(input.night),
              !input.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let outcome = "Outcome: \(input.outcome.lowercasedKeepingAcronyms)."
        let detail = [outcome, input.tonight].compactMap { $0 }.joined(separator: " ")
        return TodayExperimentStrip(progress: "Night \(input.night) of \(input.plannedNights)", title: input.title,
                                    detail: detail, beads: input.beads)
    }

    /// "Experiment, night 9 of 14, Magnesium before bed. Outcome: deep sleep. Tonight is a magnesium night."
    public var accessibilityLabel: String { "Experiment, \(progress.lowercased()), \(title). \(detail)" }
}
