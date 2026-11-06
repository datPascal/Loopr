import Foundation

/// Whether the shell shows "What's new in Loopr" (R1-UPG-2): once, on the first launch after the update from build 21,
/// never after a fresh install.
///
/// A fresh install shows the onboarding screen in this build, which marks the sheet not needed. Someone who finished
/// onboarding on an earlier build never sees that screen again, so the first shell launch with no decision stored is
/// the upgrade. The sheet stays pending until Continue, so a launch that ends before it shows it again.
nonisolated struct WhatsNewGate {
    enum State: String {
        /// Waiting for Continue.
        case pending
        case seen
        /// Onboarding ran in this version, so there is nothing new to explain.
        case notNeeded
    }

    static let key = "loopr.whats-new.longevity.v1"
    /// DEBUG and UI tests: `--loopr-whats-new=open` shows the sheet on any composition.
    static let openArgument = "--loopr-whats-new=open"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var state: State? { defaults.string(forKey: Self.key).flatMap(State.init(rawValue:)) }

    /// The onboarding screen appeared in this version.
    func markNotNeeded() {
        guard state == nil else { return }
        defaults.set(State.notNeeded.rawValue, forKey: Self.key)
    }

    /// Decides on the shell's first launch. Only production stores anything; fixture launches show the sheet only when
    /// asked to, and the asking never touches the stored decision.
    func shouldShow(isProduction: Bool, arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        if arguments.contains(Self.openArgument) { return true }
        guard isProduction else { return false }
        switch state {
        case nil:
            defaults.set(State.pending.rawValue, forKey: Self.key)
            return true
        case .pending: return true
        case .seen, .notNeeded: return false
        }
    }

    /// Continue.
    func markSeen(isProduction: Bool) {
        guard isProduction else { return }
        defaults.set(State.seen.rawValue, forKey: Self.key)
    }
}
