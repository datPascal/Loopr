import AIKit
import Foundation
import Observation

nonisolated extension AgentDataDomain {
    var title: String {
        switch self {
        case .metrics: "Band metrics and sleep"
        case .food: "Food log"
        case .training: "Training"
        case .journalAnswers: "Journal answers"
        case .journalNotes: "Journal notes"
        case .cycle: "Cycle"
        case .supplements: "Supplements and medication"
        case .labs: "Blood tests"
        }
    }
    var detail: String? {
        switch self {
        case .food: "Names and amounts, no photos"
        case .journalNotes: "Your own words"
        case .supplements: "What you took and skipped, no prescriber or notes"
        case .labs: "Values and ranges as the lab printed them"
        default: nil
        }
    }
    /// Journal notes, cycle, supplements and medication, and blood tests start off, for a new install and for a
    /// saved preference from an earlier build that has no entry for them.
    var defaultAllowed: Bool {
        switch self {
        case .metrics, .food, .training, .journalAnswers: true
        case .journalNotes, .cycle, .supplements, .labs: false
        }
    }
}

/// The device-wide switches in Your data. `AgentAccessGate` reads them again at every tool call
/// and every summary, so a flip takes effect on the next read, mid-chat included.
@MainActor @Observable
final class AgentAccessPreferences {
    nonisolated static let key = "loopr.agent-access.v1"
    /// Reads the saved switch now, without an instance. Nothing is cached.
    nonisolated static func isAllowed(_ domain: AgentDataDomain, defaults: UserDefaults?) -> Bool {
        let saved = defaults?.dictionary(forKey: key) as? [String: Bool]
        return saved?[domain.rawValue] ?? domain.defaultAllowed
    }
    private let defaults: UserDefaults?
    private var values: [String: Bool]
    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        values = (defaults?.dictionary(forKey: Self.key) as? [String: Bool]) ?? [:]
    }
    func allows(_ domain: AgentDataDomain) -> Bool { values[domain.rawValue] ?? domain.defaultAllowed }
    func set(_ domain: AgentDataDomain, allowed: Bool) {
        values[domain.rawValue] = allowed
        defaults?.set(values, forKey: Self.key)
    }
}
