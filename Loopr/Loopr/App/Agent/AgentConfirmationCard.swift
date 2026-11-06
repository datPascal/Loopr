import AIKit
import DesignSystem
import SwiftUI

/// The card under an answer that proposes a change. Nothing is saved until the person taps the
/// action. Not now saves nothing. The state comes from the stored proposal, so the card is the same
/// after a restart.
struct AgentConfirmationCard: View {
    let proposal: StoredAIProposal
    let confirm: @MainActor @Sendable () async -> Void
    let dismiss: @MainActor @Sendable () async -> Void
    @State private var working = false
    @Environment(\.openURL) private var openURL

    private var card: AIProposalCard {
        proposal.card ?? AIProposalCard(title: "Save this change?", confirmTitle: "Save", doneText: "Saved.")
    }

    /// The card says notifications are refused, so it offers the way to turn them on.
    private var needsIOSSettings: Bool {
        proposal.failure == AgentProposalCopy.notificationsOffText
            || card.lines.contains(AgentProposalCopy.reminderNotificationsOffLine)
            || card.lines.contains(AgentProposalCopy.testNotificationsOffLine)
    }

    var body: some View {
        LooprCard(style: proposal.state == .pending || proposal.state == .failed ? .elevated : .sunk) {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                switch proposal.state {
                case .pending, .failed: openCard
                case .applied: settled(symbol: "checkmark.circle.fill", text: Self.display(card.doneText))
                case .dismissed: settled(symbol: "xmark.circle", text: AgentProposalCopy.dismissedText)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-proposal-card")
    }

    /// Times in a stored card ("Kitchen closed at 20:30") read in the phone's clock. The stored card does not change.
    static func display(_ text: String, locale: Locale = .current) -> String { LooprClockFormat.localizing(text, locale: locale) }

    @ViewBuilder private var openCard: some View {
        LooprText(Self.display(card.title), style: .cardTitle)
            .accessibilityAddTraits(.isHeader)
        ForEach(Array(card.lines.enumerated()), id: \.offset) { index, line in
            LooprText(Self.display(line), style: index == card.lines.count - 1 && card.lines.count > 1 ? .caption : .prose, color: .inkSecondary)
        }
        if proposal.state == .failed, let failure = proposal.failure {
            LooprInlineMessage(failure, tone: .warning)
        }
        if needsIOSSettings {
            Button("Open iOS Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .buttonStyle(LooprButtonStyle(prominent: false))
            .accessibilityIdentifier("agent-open-ios-settings-\(proposal.id.uuidString)")
        }
        HStack(spacing: LooprSpacing.sm) {
            Button(card.dismissTitle) { run(dismiss) }
                .buttonStyle(LooprButtonStyle(prominent: false))
                .accessibilityIdentifier("agent-dismiss-\(proposal.id.uuidString)")
            Button(proposal.state == .failed ? "Try again" : card.confirmTitle) { run(confirm) }
                .buttonStyle(LooprButtonStyle())
                .accessibilityIdentifier("agent-confirm-\(proposal.id.uuidString)")
        }
        .disabled(working)
    }

    private func settled(symbol: String, text: String) -> some View {
        HStack(spacing: LooprSpacing.sm) {
            Image(systemName: symbol).foregroundStyle(Color.loopr(.brand)).accessibilityHidden(true)
            LooprText(text, style: .prose, color: .inkSecondary)
        }
    }

    private func run(_ action: @escaping @MainActor @Sendable () async -> Void) {
        guard !working else { return }
        working = true
        Task { await action(); working = false }
    }
}
