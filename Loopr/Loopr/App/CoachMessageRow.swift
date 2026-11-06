import AIKit
import DesignSystem
import SwiftUI

/// One message in the thread. The scroll view compares rows with `==`, so while a reply
/// streams only the last row re-evaluates.
struct CoachMessageRow: View, Equatable {
    let message: CoachChatMessage
    let providerName: String
    /// False when a problem card already explains why this reply stopped.
    var showsStopCaption = true
    /// The confirmation cards under this reply, loaded from the proposal store. The message's
    /// attachments say which ones belong here. The card's state comes from this list, not from the chat file.
    var proposals: [StoredAIProposal] = []
    let onSave: (CoachChatMessage) -> Void
    let onCopy: (CoachChatMessage) -> Void
    /// A source button. The app closes Ask and opens the record.
    var onOpenSource: (@MainActor @Sendable (AgentSourceLink) -> Void)?
    var onConfirmProposal: (@MainActor @Sendable (UUID) async -> Void)?
    var onDismissProposal: (@MainActor @Sendable (UUID) async -> Void)?
    @State private var copied = false

    static func == (lhs: CoachMessageRow, rhs: CoachMessageRow) -> Bool {
        lhs.message == rhs.message && lhs.providerName == rhs.providerName && lhs.showsStopCaption == rhs.showsStopCaption
            && lhs.proposals == rhs.proposals
    }

    private var isUser: Bool { message.role == .user }
    private var isStreaming: Bool { message.status == .streaming }
    private var canSave: Bool { message.role == .assistant && message.status == .complete && message.journalEntryID == nil }
    /// The reply as plain words. Only read once the reply is complete: while it streams, building it
    /// on every token would strip the whole Markdown text each time.
    private var plainText: String {
        isUser ? message.text : CoachMarkdownParser.plainText(CoachMarkdownParser.cachedParse(message.text))
    }

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: LooprSpacing.xs) {
            if isUser {
                userBubble
            } else {
                Label(providerName, systemImage: "sparkles")
                    .looprTypography(.rowTitle)
                    .foregroundStyle(Color.loopr(.inkSecondary))
                    .accessibilityHidden(true)
                if showsBubble { assistantBubble }
                attachments
                if showsStopCaption, let caption = stopCaption { caption }
                if message.status == .complete { actionRow }
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    /// Charts, the source strip and confirmation cards, in the order the reply saved them.
    @ViewBuilder private var attachments: some View {
        ForEach(Array(message.attachments.enumerated()), id: \.offset) { _, attachment in
            switch attachment {
            case .chart(let chart):
                AgentChartCard(chart: chart)
            case .sources(let sources):
                AgentSourceStrip(sources: sources, open: onOpenSource)
            case .proposal(let id):
                if let proposal = proposals.first(where: { $0.id == id }) {
                    AgentConfirmationCard(
                        proposal: proposal,
                        confirm: { @MainActor @Sendable in await onConfirmProposal?(id) },
                        dismiss: { @MainActor @Sendable in await onDismissProposal?(id) })
                }
            }
        }
    }

    private var userBubble: some View {
        HStack(spacing: 0) {
            Spacer(minLength: LooprSpacing.xxl)
            Text(verbatim: message.text)
                .looprTypography(.settingsRow)
                .foregroundStyle(Color.loopr(.ink))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, LooprSpacing.compactCardHorizontal)
                .padding(.vertical, LooprSpacing.compactCardVertical)
                .background(Color.loopr(.brandSoft), in: RoundedRectangle(cornerRadius: LooprRadius.control, style: .continuous))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("You said")
        .accessibilityValue(message.text)
        .accessibilityActions { copyAction }
        .accessibilityIdentifier("coach-user-message")
    }

    private var showsBubble: Bool { !message.text.isEmpty || isStreaming }

    private var assistantBubble: some View {
        Group {
            if message.text.isEmpty {
                CoachTypingIndicator()
            } else {
                CoachMarkdownView(text: message.text, streaming: isStreaming)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, LooprSpacing.xxs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(message.text.isEmpty || isStreaming ? "\(providerName) is replying" : "\(providerName) said")
        .accessibilityValue(message.text.isEmpty || isStreaming ? "" : plainText)
        .accessibilityActions {
            if message.status == .complete {
                copyAction
                if canSave { Button("Save to notes") { onSave(message) } }
            }
        }
        .accessibilityIdentifier("coach-assistant-message")
    }

    @ViewBuilder private var copyAction: some View {
        if !message.text.isEmpty { Button("Copy") { copy() } }
    }

    private var stopCaption: AnyView? {
        guard message.role == .assistant, message.status != .complete, !isStreaming else { return nil }
        let symbol: String, text: String, token: LooprColorToken
        switch (message.stopReason, message.status) {
        case (.stopped, _):
            symbol = "stop.circle"; text = "Reply stopped"; token = .inkSecondary
        case (.connectionLost, _):
            symbol = "bolt.horizontal"; text = message.text.isEmpty ? "Connection dropped before a reply" : "Connection dropped. This reply is unfinished."; token = .caution
        case (.failed, _), (nil, .failed):
            symbol = "exclamationmark.triangle"; text = message.text.isEmpty ? "No reply" : "Reply failed. This reply is unfinished."; token = .caution
        default:
            symbol = "pause.circle"; text = "Reply interrupted"; token = .inkSecondary
        }
        return AnyView(
            Label(text, systemImage: symbol)
                .looprTypography(.caption)
                .foregroundStyle(Color.loopr(token))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, LooprSpacing.xxs)
                .accessibilityElement(children: .combine)
        )
    }

    private var actionRow: some View {
        HStack(spacing: 0) {
            Button(action: copy) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .accessibilityLabel(copied ? "Reply copied" : "Copy reply")
            .accessibilityIdentifier("coach-copy-reply")
            ShareLink(item: plainText) { Image(systemName: "square.and.arrow.up") }
                .accessibilityLabel("Share reply")
                .accessibilityIdentifier("coach-share-reply")
            Button { onSave(message) } label: {
                Image(systemName: message.journalEntryID == nil ? "book.closed" : "checkmark.circle.fill")
            }
            .disabled(message.journalEntryID != nil)
            .accessibilityLabel(message.journalEntryID == nil ? "Save to notes" : "Saved to notes")
            .accessibilityIdentifier("coach-save-reply")
        }
        .buttonStyle(CoachIconButtonStyle())
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    private func copy() {
        copied = true
        onCopy(message)
    }
}

/// Three dots that rise in turn. With Reduce Motion it is the words "Replying…".
struct CoachTypingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if LooprMotion.reducesMotion(reduceMotion) {
                Text("Replying…")
                    .looprTypography(.settingsRow)
                    .foregroundStyle(Color.loopr(.inkSecondary))
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    let time = context.date.timeIntervalSinceReferenceDate
                    HStack(spacing: LooprSpacing.xs) {
                        ForEach(0..<3, id: \.self) { index in
                            let wave = (sin(time * 5 - Double(index) * 0.9) + 1) / 2
                            Circle()
                                .fill(Color.loopr(.brand))
                                .frame(width: 8, height: 8)
                                .opacity(0.3 + 0.7 * wave)
                                .offset(y: -3 * wave)
                        }
                    }
                }
            }
        }
        .frame(minHeight: 24, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Replying")
    }
}

/// A 44 pt icon button with a soft pressed state, for the reply actions.
struct CoachIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .looprTypography(.label)
            .foregroundStyle(Color.loopr(isEnabled ? .brandInk : .inkSecondary))
            .frame(minWidth: 44, minHeight: 44)
            .background(Circle().fill(Color.loopr(.brandSoft)).opacity(configuration.isPressed ? 1 : 0))
            .contentShape(Rectangle())
    }
}
