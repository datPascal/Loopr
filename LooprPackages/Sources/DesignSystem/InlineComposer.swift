import SwiftUI

public struct LooprInlineTextField: View {
    @Binding private var text: String
    private let placeholder: String
    private let label: String
    private let identifier: String
    public init(_ placeholder: String, text: Binding<String>, label: String, identifier: String) {
        self.placeholder = placeholder; _text = text; self.label = label; self.identifier = identifier
    }
    public var body: some View {
        LooprCard(density: .flush) {
            TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Color.loopr(.inkSecondary)), axis: .vertical)
                .looprTypography(.body).foregroundStyle(Color.loopr(.ink)).tint(Color.loopr(.brand))
                .padding(.horizontal, LooprSpacing.cardHorizontal).padding(.vertical, LooprSpacing.sm)
                .frame(minHeight: LooprSpacing.interactiveRowHeight)
                .accessibilityLabel(label).accessibilityIdentifier(identifier)
        }
    }
}

/// One draft field with explicit dictation and submission actions.
public struct LooprInlineComposer: View {
    @Binding private var text: String
    private let placeholder: String
    private let recording: Bool
    private let identifier: String
    private let voiceLabel: String
    private let submitLabel: String
    private let submitIdentifier: String
    private let voice: () -> Void
    private let submit: () -> Void
    public init(_ placeholder: String, text: Binding<String>, recording: Bool, identifier: String,
                voiceLabel: String, submitLabel: String, submitIdentifier: String? = nil, voice: @escaping () -> Void, submit: @escaping () -> Void) {
        self.placeholder = placeholder; _text = text; self.recording = recording; self.identifier = identifier
        self.voiceLabel = voiceLabel; self.submitLabel = submitLabel; self.voice = voice; self.submit = submit
        self.submitIdentifier = submitIdentifier ?? identifier + "-send"
    }
    public var body: some View {
        LooprCard(density: .flush) {
            HStack(spacing: LooprSpacing.xxs) {
                Button(action: voice) { Image(systemName: recording ? "stop.fill" : "mic").looprTypography(.title) }
                    .buttonStyle(LooprButtonStyle(prominent: false, accent: .inkSecondary, quiet: true))
                    .frame(width: LooprSpacing.interactiveRowHeight)
                    .accessibilityLabel(voiceLabel).accessibilityIdentifier(identifier + "-voice")
                TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Color.loopr(.inkSecondary)), axis: .vertical)
                    .looprTypography(.body).foregroundStyle(Color.loopr(.ink)).tint(Color.loopr(.brand))
                    .padding(.trailing, LooprSpacing.md).padding(.vertical, LooprSpacing.sm)
                    .accessibilityLabel(placeholder).accessibilityIdentifier(identifier + "-text")
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button(action: submit) { Image(systemName: "arrow.up").looprTypography(.title) }
                        .buttonStyle(LooprButtonStyle(prominent: false, quiet: true))
                        .frame(width: LooprSpacing.interactiveRowHeight)
                        .accessibilityLabel(submitLabel).accessibilityIdentifier(submitIdentifier)
                }
            }.frame(minHeight: LooprSpacing.interactiveRowHeight)
        }
    }
}

public struct LooprInlineActionRow: View {
    private let title: String
    private let symbol: String
    private let identifier: String
    private let action: () -> Void
    public init(_ title: String, symbol: String, identifier: String, action: @escaping () -> Void) {
        self.title = title; self.symbol = symbol; self.identifier = identifier; self.action = action
    }
    public var body: some View {
        Button(action: action) {
            HStack(spacing: LooprSpacing.md) {
                Image(systemName: symbol).accessibilityHidden(true)
                LooprText(title, style: .rowTitle, color: .brandInk)
                Spacer(minLength: 0)
            }.foregroundStyle(Color.loopr(.brandInk)).looprTypography(.rowTitle)
                .padding(.horizontal, LooprSpacing.cardHorizontal).padding(.vertical, LooprSpacing.sm)
                .frame(minHeight: LooprSpacing.interactiveRowHeight).contentShape(Rectangle())
        }.buttonStyle(.looprPressableRow).accessibilityIdentifier(identifier)
    }
}

#Preview {
    VStack {
        LooprInlineComposer("Correct the food", text: .constant(""), recording: false, identifier: "preview",
            voiceLabel: "Dictate correction", submitLabel: "Review correction", voice: {}, submit: {})
        LooprCard(density: .flush) { LooprInlineActionRow("Add something it missed", symbol: "plus", identifier: "add", action: {}) }
    }.padding()
}
