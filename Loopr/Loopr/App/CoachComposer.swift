import DesignSystem
import SwiftUI
import UIKit

/// The message field in one rounded card: a camera button on the left, dictation on the right,
/// and Send once there is something to send. The field stays editable while a reply streams;
/// only the Send button turns into Stop.
struct CoachComposer: View {
    @ObservedObject var model: CoachChatViewModel
    @ObservedObject var dictation: CoachDictation
    var focus: FocusState<Bool>.Binding
    let sendOrStop: () -> Void
    let toggleDictation: () -> Void
    /// Opens Food photo capture. Nil hides the camera button.
    var attachPhoto: (@MainActor @Sendable () -> Void)?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL
    @ScaledMetric(relativeTo: .body) private var buttonSize: CGFloat = 44

    private var side: CGFloat { min(max(buttonSize, 44), 64) }
    private var trimmedIsEmpty: Bool { model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var canSend: Bool { model.sending || (!trimmedIsEmpty && !model.draftIsTooLong) }

    private var showsSend: Bool { model.sending || !trimmedIsEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            if let issue = dictation.issue { issueView(issue) }
            if dictation.recording {
                Text("Listening on this iPhone. Review your draft before sending.")
                    .looprTypography(.caption)
                    .foregroundStyle(Color.loopr(.inkSecondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            card
            if model.draftCharacterCount >= 7000 { counter }
        }
        .padding(.horizontal, LooprSpacing.screenGutter)
        .padding(.vertical, LooprSpacing.xs)
        .background(Color.loopr(.background).ignoresSafeArea(edges: .bottom))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ask-composer")
    }

    @ViewBuilder private var card: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                    field
                    HStack(spacing: LooprSpacing.xs) { photoButton; Spacer(minLength: 0); micButton; sendButton }
                }
            } else {
                HStack(alignment: .bottom, spacing: LooprSpacing.xxs) { photoButton; field; micButton; sendButton }
            }
        }
        .padding(.horizontal, LooprSpacing.xxs)
        .padding(.vertical, LooprSpacing.xxs)
        // The same fill and outline as the Ask field on Today, so the two fields look alike.
        .looprCardBackground()
    }

    private var field: some View {
        TextField("", text: $model.draft, prompt: Text("Ask about your data").foregroundStyle(Color.loopr(.inkSecondary)), axis: .vertical)
            .lineLimit(1...(dynamicTypeSize.isAccessibilitySize ? 3 : 5))
            .looprTypography(.settingsRow)
            .foregroundStyle(Color.loopr(.ink))
            .tint(Color.loopr(.brand))
            .focused(focus)
            .padding(.horizontal, LooprSpacing.xs)
            .padding(.vertical, LooprSpacing.xs + 2)
            .frame(minHeight: side)
            .accessibilityLabel("Message")
            .accessibilityIdentifier("coach-composer")
    }

    @ViewBuilder private var photoButton: some View {
        if let attachPhoto {
            Button(action: attachPhoto) {
                Image(systemName: "photo")
                    .looprTypography(.cardTitle)
                    .foregroundStyle(Color.loopr(.inkSecondary))
                    .frame(width: side, height: side)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.sending)
            .accessibilityLabel("Log a meal from a photo")
            .looprAccessibilityHint("Opens the Food camera. Ask closes.")
            .accessibilityIdentifier("ask-photo")
        }
    }

    private var micButton: some View {
        Button(action: toggleDictation) {
            Image(systemName: dictation.recording ? "mic.fill" : "mic")
                .looprTypography(.cardTitle)
                .foregroundStyle(Color.loopr(dictation.recording ? .critical : .inkSecondary))
                .symbolEffect(.pulse, isActive: dictation.recording && !LooprMotion.reducesMotion(reduceMotion))
                .frame(width: side, height: side)
                .background(Circle().fill(Color.loopr(.heartSoft)).opacity(dictation.recording ? 1 : 0))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(dictation.recording ? "Stop dictation" : "Dictate message")
        .accessibilityValue(dictation.recording ? "Listening" : "")
        .accessibilityIdentifier("coach-dictate")
    }

    @ViewBuilder private var sendButton: some View {
        if showsSend {
            let isDark = LooprAppearance.isDark(colorScheme)
            Button(action: sendOrStop) {
                Image(systemName: model.sending ? "stop.fill" : "arrow.up")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(canSend ? coachOnBrandColor(isDark: isDark) : Color.loopr(.inkSecondary))
                    .frame(width: side, height: side)
                    .background(Circle().fill(Color.loopr(.brand).opacity(canSend ? 1 : 0.10)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityLabel(model.sending ? "Stop reply" : "Send message")
            .accessibilityIdentifier("coach-send")
        }
    }

    private var counter: some View {
        let over = model.draftIsTooLong
        let near = model.draftCharacterCount >= CoachChatViewModel.draftLimit - 200
        let text = "\(model.draftCharacterCount.formatted()) of \(CoachChatViewModel.draftLimit.formatted()) characters"
        return Text(over ? text + ". Shorten it to send." : text)
            .looprTypography(.caption)
            .foregroundStyle(Color.loopr(over ? .critical : near ? .caution : .inkSecondary))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("coach-character-count")
    }

    private func issueView(_ issue: CoachDictationIssue) -> some View {
        HStack(alignment: .top, spacing: LooprSpacing.xs) {
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                LooprInlineMessage(issue.message, tone: issue.isFailure ? .warning : .neutral)
                if issue.needsSettings {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    .buttonStyle(CoachCardButtonStyle())
                }
            }
            Button { dictation.clearIssue() } label: {
                Image(systemName: "xmark")
                    .looprTypography(.caption)
                    .foregroundStyle(Color.loopr(.inkSecondary))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .task(id: issue) {
            guard !issue.isFailure else { return }
            try? await Task.sleep(for: .seconds(8))
            if dictation.issue == issue { dictation.clearIssue() }
        }
    }
}
