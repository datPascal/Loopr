import SwiftUI

/// A hairline row that expands controls in place, rather than navigating away.
public struct LooprReviewRow: View {
    @Environment(\.dynamicTypeSize) private var size
    private let title: String
    private let detail: String
    private let value: String
    private let state: String?
    private let accent: LooprColorToken
    private let expanded: Bool
    private let identifier: String
    private let action: () -> Void
    public init(title: String, detail: String, value: String, state: String?, accent: LooprColorToken,
                expanded: Bool, identifier: String, action: @escaping () -> Void) {
        self.title = title; self.detail = detail; self.value = value; self.state = state; self.accent = accent
        self.expanded = expanded; self.identifier = identifier; self.action = action
    }
    public var accessibilitySummary: String { [title, detail, state, value].compactMap { $0 }.joined(separator: ", ") }
    public var body: some View {
        Button(action: action) {
            let layout = size.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: LooprSpacing.sm)) : AnyLayout(HStackLayout(spacing: LooprSpacing.md))
            layout {
                VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                    LooprText(title, style: .rowTitle)
                    LooprText(detail, style: .caption, color: .inkSecondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: LooprSpacing.md) {
                    if let state { StatusChip(state, symbol: state == "Sure" ? "checkmark.circle" : nil, accent: accent) }
                    LooprText(value, style: .metricValue)
                }
            }.padding(.horizontal, LooprSpacing.cardHorizontal).padding(.vertical, LooprSpacing.metricRowVertical)
                .frame(minHeight: LooprSpacing.interactiveRowHeight)
                .contentShape(Rectangle())
        }.buttonStyle(.looprPressableRow)
            .accessibilityElement(children: .ignore).accessibilityLabel(accessibilitySummary)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed").accessibilityHint("Edit this item")
            .accessibilityIdentifier(identifier)
    }
}

public struct LooprAmountSlider: View {
    private let title: String
    @Binding private var value: Double
    private let range: ClosedRange<Double>
    private let step: Double
    private let identifier: String
    public init(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, identifier: String) {
        self.title = title; _value = value; self.range = range; self.step = step; self.identifier = identifier
    }
    public var body: some View {
        // A stepped Slider draws an iOS 26 tick row; snapping in the binding keeps whole steps without it.
        Slider(value: Binding(get: { value }, set: { value = Self.snapped($0, step: step, range: range) }), in: range) { Text(title) }
            .tint(Color.loopr(.brand)).frame(minHeight: LooprSpacing.interactiveRowHeight)
            .accessibilityLabel(title).accessibilityIdentifier(identifier)
    }
    public static func snapped(_ value: Double, step: Double, range: ClosedRange<Double>) -> Double {
        guard step > 0 else { return min(max(value, range.lowerBound), range.upperBound) }
        let stepped = range.lowerBound + ((value - range.lowerBound) / step).rounded() * step
        return min(max(stepped, range.lowerBound), range.upperBound)
    }
}

#Preview("Review item") {
    LooprCard(density: .flush) {
        LooprReviewRow(title: "White rice", detail: "180 g", value: "234", state: "Check", accent: .energy,
            expanded: true, identifier: "review-preview") {}
    }.padding()
}
