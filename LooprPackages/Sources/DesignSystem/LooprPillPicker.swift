import SwiftUI

/// One option of a `LooprPillPicker`: its value, the short label it shows and the words VoiceOver reads.
public struct LooprPillOption<Value: Hashable & Sendable>: Identifiable, Sendable {
    public let value: Value
    public let title: String
    public let spokenTitle: String
    public let identifier: String

    public var id: String { identifier }

    public init(_ value: Value, title: String, spokenTitle: String? = nil, identifier: String) {
        self.value = value
        self.title = title
        self.spokenTitle = spokenTitle ?? title
        self.identifier = identifier
    }
}

/// The range picker's capsule row for any set of options, such as Sleep's Night, 7D, 30D, 90D and 1Y (Data ICP R1).
/// It draws exactly like `LooprRangePicker`, so a page that switches between a night and its trends looks the same as
/// a chart that switches ranges.
public struct LooprPillPicker<Value: Hashable & Sendable>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Namespace private var indicator
    @Binding private var selection: Value
    private let options: [LooprPillOption<Value>]
    private let accent: LooprColorToken
    private let identifier: String
    private let label: String
    private let locked: Set<Value>

    /// - Parameter locked: options shown dimmed and not tappable, such as a range longer than the history (Data ICP R4).
    public init(selection: Binding<Value>, options: [LooprPillOption<Value>], accent: LooprColorToken,
                label: String = "Time range", identifier: String, locked: Set<Value> = []) {
        _selection = selection
        self.options = options
        self.accent = accent
        self.label = label
        self.identifier = identifier
        self.locked = locked
    }

    public var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: LooprSpacing.xxs) { buttons }
            } else {
                HStack(spacing: LooprSpacing.xxs) { buttons }
            }
        }
        .padding(LooprSpacing.xxs - 1)
        .background(Color.loopr(.ink).opacity(isDark ? 0.05 : 0.04),
                    in: RoundedRectangle(cornerRadius: dynamicTypeSize.isAccessibilitySize ? LooprRadius.control : 100, style: .continuous))
        .sensoryFeedback(.selection, trigger: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    private var buttons: some View {
        ForEach(options) { option in
            let selected = option.value == selection
            let isLocked = locked.contains(option.value)
            Button {
                guard !selected else { return }
                withAnimation(reduceMotion ? nil : .snappy(duration: LooprMotion.standard)) { selection = option.value }
            } label: {
                Text(option.title)
                    .looprTypography(.label)
                    .foregroundStyle(Color.loopr(selected ? accent.spectralChipLabel : .inkSecondary))
                    .opacity(isLocked ? 0.55 : 1)
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .background {
                        if selected {
                            Capsule(style: .continuous)
                                .fill(Color.loopr(accent).opacity(isDark ? 0.16 : 0.12))
                                .overlay {
                                    Capsule(style: .continuous)
                                        .strokeBorder(Color.loopr(accent).opacity(isDark ? 0.34 : 0.28), lineWidth: 1)
                                }
                                .matchedGeometryEffect(id: "selection", in: indicator)
                        }
                    }
                    .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isLocked)
            .accessibilityLabel(option.spokenTitle)
            .accessibilityHint(isLocked ? "Needs a longer history" : "")
            .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
            .accessibilityIdentifier(option.identifier)
        }
    }

    private var reduceMotion: Bool {
        accessibilityReduceMotion || DesignSystemRuntime.state().reduceMotion == true
    }

    private var isDark: Bool { LooprAppearance.isDark(colorScheme) }
}

public extension EnvironmentValues {
    /// The app's trend section for an area page: a range picker, a chart of the picked metric, one sentence and the
    /// method row. Strain, Body and Stress place it under their hero when Data provides one (Data ICP round 2).
    @Entry var looprAreaTrend: AnyView? = nil
}
