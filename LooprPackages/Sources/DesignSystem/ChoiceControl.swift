import SwiftUI

public struct LooprChoice: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public init(_ id: String, title: String? = nil) { self.id = id; self.title = title ?? id }
}

/// Shared choices for segments, ratings and Yes/No answers. Nil stays unselected.
public struct LooprChoiceControl: View {
    public enum Style: Equatable { case segments, rating }
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let title: String
    private let choices: [LooprChoice]
    private let selection: String?
    private let accent: LooprColorToken
    private let style: Style
    private let allowsClear: Bool
    private let identifier: String
    private let onSelect: (String?) -> Void

    public init(_ title: String, choices: [LooprChoice], selection: String?,
                accent: LooprColorToken, style: Style = .segments, allowsClear: Bool = false,
                identifier: String, onSelect: @escaping (String?) -> Void) {
        self.title = title; self.choices = choices; self.selection = selection
        self.accent = accent; self.style = style; self.allowsClear = allowsClear
        self.identifier = identifier; self.onSelect = onSelect
    }

    public var accessibilitySummary: String {
        "\(title), \(choices.first { $0.id == selection }?.title ?? "Unanswered")"
    }

    public var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: LooprSpacing.xs) { buttons }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: style == .rating ? LooprSpacing.xs : LooprSpacing.xxs) { buttons }
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: LooprSpacing.xs) { buttons }
                }
            }
        }
        .padding(style == .segments ? LooprSpacing.xxs : LooprSpacing.none)
        .background(style == .segments ? Color.loopr(.surfaceElevated) : .clear,
                    in: controlShape)
        // The new choice's fill eases in while the old one fades, and the pick ticks under the finger.
        .animation(LooprMotion.stateChange, value: selection)
        .sensoryFeedback(.selection, trigger: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }

    private var controlShape: AnyShape {
        style == .segments ? AnyShape(Capsule()) : AnyShape(RoundedRectangle(cornerRadius: LooprRadius.control))
    }

    private var buttons: some View {
        ForEach(choices) { choice in
            let selected = choice.id == selection
            Button { onSelect(allowsClear && selected ? nil : choice.id) } label: {
                LooprText(choice.title, style: style == .rating ? .metricValue : .label,
                          color: selected ? accent.spectralChipLabel : .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minWidth: LooprSpacing.interactiveRowHeight, maxWidth: .infinity,
                           minHeight: LooprSpacing.interactiveRowHeight)
                    .background(selected ? Color.loopr(accent).opacity(0.16) : Color.loopr(.surfaceElevated),
                                in: controlShape)
                    .overlay {
                        if selected {
                            controlShape
                                .stroke(Color.loopr(accent), lineWidth: LooprSpacing.hairline)
                                .accessibilityHidden(true)
                        }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.looprPressableRow)
            .accessibilityLabel("\(title), \(choice.title)")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityHint(allowsClear && selected ? "Tap again to clear this answer" : "")
            .accessibilityIdentifier("\(identifier)-\(choice.id)")
        }
    }
}

#Preview {
    LooprCard {
        VStack(spacing: LooprSpacing.md) {
            LooprChoiceControl("Mood", choices: (1...5).map { LooprChoice(String($0)) }, selection: "4",
                accent: .cyclePlum, style: .rating, allowsClear: true, identifier: "mood") { _ in }
            LooprChoiceControl("Alcohol", choices: [LooprChoice("no", title: "No"), LooprChoice("yes", title: "Yes")],
                selection: nil, accent: .cyclePlum, identifier: "alcohol") { _ in }
        }
    }.padding()
}
