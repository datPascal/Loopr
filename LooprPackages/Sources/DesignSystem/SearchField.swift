import SwiftUI

public struct LooprSearchField: View {
    private let prompt: String
    private let identifier: String
    private let focus: FocusState<Bool>.Binding?
    @Binding private var text: String
    @FocusState private var localFocus: Bool

    public init(_ prompt: String, text: Binding<String>, identifier: String,
                focus: FocusState<Bool>.Binding? = nil) {
        self.prompt = prompt
        self.identifier = identifier
        self.focus = focus
        _text = text
    }

    public var body: some View {
        HStack(spacing: LooprSpacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.loopr(.inkSecondary))
                .accessibilityHidden(true)
            TextField(prompt, text: $text)
                .focused(focus ?? $localFocus)
                .looprTypography(.prose)
                .foregroundStyle(Color.loopr(.ink))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel(prompt)
                .accessibilityIdentifier(identifier)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.loopr(.inkSecondary))
                        .frame(width: LooprSpacing.interactiveRowHeight, height: LooprSpacing.interactiveRowHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .accessibilityIdentifier(identifier + "-clear")
            }
        }
        .looprTypography(.rowTitle)
        .frame(minHeight: LooprSpacing.interactiveRowHeight)
        .padding(.horizontal, LooprSpacing.md)
    }
}

#Preview {
    @Previewable @State var text = ""
    LooprCard(density: .flush) {
        LooprSearchField("Search metrics", text: $text, identifier: "search-preview")
    }
}
