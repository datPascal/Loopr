import SwiftUI

/// One row that names what it holds and opens it in place underneath: "More from today", "Fitness checks", "More
/// about this week". The UX simplification (2026-11-01) put each tab's depth behind one of these, so the first screen
/// answers the tab's question and nothing is lost. It starts closed unless `isOpen` says otherwise.
public struct LooprFoldSection<Content: View>: View {
    private let title: String
    private let summary: String
    private let identifier: String
    private let spacing: CGFloat
    private let rowPadding: CGFloat
    @Binding private var isOpen: Bool
    private let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - summary: one line under the title saying what opens, such as "Experiment, your day and timeline".
    ///   - spacing: the gap between the row and the content, and between the content's own children.
    ///   - rowPadding: horizontal inset of the row alone, for a parent whose content brings its own gutter.
    public init(_ title: String, summary: String, identifier: String, isOpen: Binding<Bool>,
                spacing: CGFloat = LooprSpacing.cardStack, rowPadding: CGFloat = 0,
                @ViewBuilder content: () -> Content) {
        self.title = title
        self.summary = summary
        self.identifier = identifier
        self.spacing = spacing
        self.rowPadding = rowPadding
        self._isOpen = isOpen
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            Button {
                withAnimation(LooprMotion.reducesMotion(reduceMotion) ? nil : LooprMotion.stateChange) { isOpen.toggle() }
            } label: {
                HStack(alignment: .center, spacing: LooprSpacing.sm) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .looprTypography(.rowTitle)
                            .foregroundStyle(Color.loopr(.ink))
                        if !summary.isEmpty {
                            Text(summary)
                                .looprTypography(.caption)
                                .foregroundStyle(Color.loopr(.inkSecondary))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.loopr(.inkSecondary))
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                        .accessibilityHidden(true)
                }
                .padding(.vertical, LooprSpacing.sm)
                .padding(.horizontal, LooprSpacing.cardHorizontal)
                .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
                .looprCardBackground()
                .contentShape(Rectangle())
            }
            .buttonStyle(.looprPressableCard)
            .padding(.horizontal, rowPadding)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(summary.isEmpty ? title : "\(title). \(summary)")
            .accessibilityValue(isOpen ? "Open" : "Closed")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier(identifier)

            if isOpen {
                VStack(alignment: .leading, spacing: spacing) {
                    content
                }
                // Every card keeps its ideal height. Without this the timeline's two-line rows were squeezed into each
                // other inside the fold (UX R2-VET-03).
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
            }
        }
    }
}

public enum LooprFoldSummary {
    /// Debug builds launched with `-loopr-open-folds YES` start every fold open, so a screenshot tour can show what the
    /// folds hold without tapping. Always false in release.
    public static var opensForCapture: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "loopr-open-folds")
        #else
        false
        #endif
    }

    /// "Experiment, your day and timeline": the first part as written, the rest in lower case, "and" before the last.
    public static func list(_ parts: [String]) -> String {
        let words = parts.enumerated().map { $0.offset == 0 ? $0.element : $0.element.lowercased() }
        guard let last = words.last else { return "" }
        return words.count == 1 ? last : words.dropLast().joined(separator: ", ") + " and " + last
    }
}
