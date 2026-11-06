import AIKit

/// One switch in the consent sheet's "What to share" list. A row names the Your data domain it
/// covers and the chat switch it flips, so the consent sheet and Your data use the same words.
///
/// Journal answers and notes share the legacy journal switch, so they appear as one row. Supplements and
/// Blood tests have a row each, both off until the person turns them on for the chat. Food and training have
/// switches in `CoachSharing` but no row yet. When they get one, add it here and the sheet follows.
nonisolated struct CoachConsentDomain: Identifiable, Sendable {
    let domains: [AgentDataDomain]
    let title: String
    let detail: String
    let keyPath: WritableKeyPath<CoachSharing, Bool> & Sendable
    var id: String { domains.map(\.rawValue).joined(separator: "+") }

    static let rows: [CoachConsentDomain] = [
        .init(domains: [.metrics], title: AgentDataDomain.metrics.title,
              detail: "Sleep, recovery, heart rate, workouts and goals from the last 30 days.",
              keyPath: \.metrics),
        // The Journal is Protocol now, so the row says check-ins (ICP R2-OPT-26).
        .init(domains: [.journalAnswers, .journalNotes], title: "Check-ins and notes",
              detail: "Protocol check-ins, notes and tags from the last 30 days, up to 30 entries.",
              keyPath: \.journal),
        .init(domains: [.cycle], title: AgentDataDomain.cycle.title,
              detail: "Cycle entries from the last 30 days, up to 30 entries.",
              keyPath: \.cycle),
        .init(domains: [.supplements], title: AgentDataDomain.supplements.title,
              detail: "Ask can look up what you took and skipped. Prescriber and notes stay out.",
              keyPath: \.supplements),
        .init(domains: [.labs], title: AgentDataDomain.labs.title,
              detail: "Ask can look up your lab values with each lab's own range.",
              keyPath: \.labs),
    ]
}
