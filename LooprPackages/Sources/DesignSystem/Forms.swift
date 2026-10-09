import SwiftUI

public extension LooprSpacing {
    static let none: CGFloat = 0
    static let hairline: CGFloat = 1
    static let formCardPadding: CGFloat = 17
    static let formRowVerticalPadding: CGFloat = 13
    static let toolbarSpace: CGFloat = 54
    static let interactiveRowHeight: CGFloat = 56
    static let formButtonHeight: CGFloat = 44
    static let surfaceShadowOffset: CGFloat = 1
}

public extension LooprRadius {
    static let surfaceShadow: CGFloat = 2
}

public enum LooprAppearance {
    public static func isDark(_ colorScheme: ColorScheme) -> Bool {
        switch DesignSystemRuntime.state().appearance {
        case .system: colorScheme == .dark
        case .light: false
        case .dark: true
        }
    }
}

public struct LooprFormCard<Content: View>: View {
    private let padding: CGFloat
    private let content: Content

    public init(
        padding: CGFloat = LooprSpacing.formCardPadding,
        @ViewBuilder content: () -> Content
    ) {
        self.padding = padding
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .looprCardBackground()
    }
}

public struct LooprSectionGroup<Content: View>: View {
    private let title: String
    private let content: Content

    public init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs + LooprSpacing.hairline) {
            LooprText(title.uppercased(), style: .sectionLabel, color: .inkSecondary)
                .accessibilityLabel(title)
                .accessibilityAddTraits(.isHeader)
            content
        }
    }
}

public struct LooprMenuItem: Identifiable {
    public let id: String
    public let title: String
    public let value: String?
    public let accessibilityIdentifier: String
    public let action: () -> Void

    public init(
        title: String,
        value: String? = nil,
        accessibilityIdentifier: String,
        action: @escaping () -> Void
    ) {
        id = title
        self.title = title
        self.value = value
        self.accessibilityIdentifier = accessibilityIdentifier
        self.action = action
    }
}

public struct LooprMenuGroup: View {
    let title: String
    let rows: [LooprMenuItem]
    let headingIdentifier: String?

    public init(title: String, rows: [LooprMenuItem], headingIdentifier: String? = nil) {
        self.title = title
        self.rows = rows
        self.headingIdentifier = headingIdentifier
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs + LooprSpacing.hairline) {
            heading
            LooprFormCard(padding: LooprSpacing.none) {
                VStack(spacing: LooprSpacing.none) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        Button(action: row.action) {
                            HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.sm) {
                                LooprText(row.title, style: .settingsRow)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .layoutPriority(1)

                                Spacer(minLength: LooprSpacing.sm)

                                if let value = row.value {
                                    LooprText(value, style: .metricUnit, color: .inkMuted)
                                        .multilineTextAlignment(.trailing)
                                        .fixedSize(horizontal: false, vertical: true)
                                }

                                LooprChevron()
                            }
                            .padding(.horizontal, LooprSpacing.formCardPadding)
                            .padding(.vertical, LooprSpacing.formRowVerticalPadding)
                            .frame(
                                maxWidth: .infinity,
                                minHeight: LooprSpacing.interactiveRowHeight,
                                alignment: .leading
                            )
                            .contentShape(Rectangle())
                        }
                        // The row dims under the finger, like every other
                        // row that opens something.
                        .buttonStyle(.looprPressableRow)
                        .accessibilityLabel(
                            [row.title, row.value, "Opens details"]
                                .compactMap { $0 }
                                .joined(separator: ", ")
                        )
                        .accessibilityIdentifier(row.accessibilityIdentifier)

                        if index < rows.count - 1 {
                            LooprHairline()
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var heading: some View {
        let label = LooprText(title.uppercased(), style: .sectionLabel, color: .inkSecondary)
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isHeader)
        if let headingIdentifier {
            label.accessibilityIdentifier(headingIdentifier)
        } else {
            label
        }
    }
}

public struct LooprHairline: View {
    public init() {}

    public var body: some View {
        Rectangle()
            .fill(Color.loopr(.divider))
            .frame(height: LooprSpacing.hairline)
            .accessibilityHidden(true)
    }
}

public struct LooprPrimaryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.isEnabled) private var isEnabled

    private let accent: LooprColorToken

    public init(accent: LooprColorToken = .brand) {
        self.accent = accent
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .looprTypography(.label)
            .foregroundStyle(labelColor)
            .frame(maxWidth: .infinity, minHeight: LooprSpacing.formButtonHeight)
            .background(fillColor, in: RoundedRectangle(cornerRadius: LooprRadius.control, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(
                accessibilityReduceMotion || DesignSystemRuntime.state().reduceMotion == true
                    ? .linear(duration: 0)
                    : LooprMotion.stateChange,
                value: configuration.isPressed
            )
    }

    private var labelColor: Color {
        Color.loopr(isEnabled ? .background : .inkMuted)
    }

    private var fillColor: Color {
        Color.loopr(accent).opacity(isEnabled ? 1 : 0.10)
    }
}

public struct LooprDestructiveButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.isEnabled) private var isEnabled

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .looprTypography(.label)
            .foregroundStyle(labelColor)
            .frame(maxWidth: .infinity, minHeight: LooprSpacing.formButtonHeight)
            .background(
                fillColor,
                in: RoundedRectangle(cornerRadius: LooprRadius.control, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: LooprRadius.control, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: LooprSpacing.hairline)
                    .allowsHitTesting(false)
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(
                accessibilityReduceMotion || DesignSystemRuntime.state().reduceMotion == true
                    ? .linear(duration: 0)
                    : LooprMotion.stateChange,
                value: configuration.isPressed
            )
    }

    private var labelColor: Color {
        Color.loopr(isEnabled ? .critical : .inkMuted)
    }

    private var fillColor: Color {
        Color.loopr(.critical).opacity(isEnabled ? 0.10 : 0.04)
    }

    private var borderColor: Color {
        Color.loopr(isEnabled ? .critical : .inkMuted).opacity(isEnabled ? 0.25 : 0.12)
    }
}

public struct LooprToolbarSpace: View {
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = LooprSpacing.toolbarSpace

    public init() {}

    public var body: some View {
        Color.loopr(.background).opacity(0)
            .frame(maxWidth: .infinity, minHeight: height)
            .accessibilityHidden(true)
    }
}

public struct LooprToggleRow: View {
    @Binding private var isOn: Bool

    private let title: String
    private let subtitle: String?

    public init(title: String, subtitle: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.subtitle = subtitle
        self._isOn = isOn
    }

    public var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                LooprText(title, style: .settingsRow)
                if let subtitle {
                    LooprText(subtitle, style: .prose, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .tint(Color.loopr(.brand))
        .padding(.horizontal, LooprSpacing.formCardPadding)
        .padding(.vertical, LooprSpacing.formRowVerticalPadding)
        .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
    }
}

public struct LooprTextFieldRow: View {
    @Binding private var text: String
    @FocusState private var isFocused: Bool

    private let title: String
    private let placeholder: String

    public init(title: String, placeholder: String, text: Binding<String>) {
        self.title = title
        self.placeholder = placeholder
        self._text = text
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.sm) {
            LooprText(title, style: .settingsRow)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)

            Spacer(minLength: LooprSpacing.sm)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .looprTypography(.metricUnit)
                .foregroundStyle(Color.loopr(.ink))
                .tint(Color.loopr(.brand))
                .multilineTextAlignment(.trailing)
                .focused($isFocused)
        }
        .padding(.horizontal, LooprSpacing.formCardPadding)
        .padding(.vertical, LooprSpacing.formRowVerticalPadding)
        .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
    }
}

public struct LooprPickerRow<Value: Hashable>: View {
    @Binding private var selection: Value

    private let title: String
    private let options: [Value]
    private let label: (Value) -> String

    public init(
        title: String,
        selection: Binding<Value>,
        options: [Value],
        label: @escaping (Value) -> String
    ) {
        self.title = title
        self._selection = selection
        self.options = options
        self.label = label
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.sm) {
            LooprText(title, style: .settingsRow)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)

            Spacer(minLength: LooprSpacing.sm)

            Picker(selection: $selection) {
                ForEach(options, id: \.self) { option in
                    Text(label(option))
                        .looprTypography(.metricUnit)
                        .tag(option)
                }
            } label: {
                LooprText(title, style: .settingsRow)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .looprTypography(.metricUnit)
            .foregroundStyle(Color.loopr(.inkMuted))
            .tint(Color.loopr(.inkMuted))
            .accessibilityLabel(title)
        }
        .padding(.horizontal, LooprSpacing.formCardPadding)
        .padding(.vertical, LooprSpacing.formRowVerticalPadding)
        .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
    }
}

public struct LooprTextEditorRow: View {
    @Binding private var text: String
    @FocusState private var isFocused: Bool

    private let title: String
    private let placeholder: String
    private let minimumHeight: CGFloat

    public init(
        title: String,
        placeholder: String,
        text: Binding<String>,
        minimumHeight: CGFloat = LooprSpacing.formButtonHeight * 2
    ) {
        self.title = title
        self.placeholder = placeholder
        self._text = text
        self.minimumHeight = minimumHeight
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprText(title, style: .settingsRow)
                .accessibilityHidden(true)

            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .scrollContentBackground(.hidden)
                    .looprTypography(.prose)
                    .foregroundStyle(Color.loopr(.ink))
                    .tint(Color.loopr(.brand))
                    .focused($isFocused)
                    .frame(minHeight: minimumHeight)
                    .accessibilityLabel(title)

                if text.isEmpty {
                    LooprText(placeholder, style: .prose, color: .inkMuted)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .padding(.leading, LooprSpacing.xxs)
                        .padding(.top, LooprSpacing.xxs)
                }
            }
        }
        .padding(.horizontal, LooprSpacing.formCardPadding)
        .padding(.vertical, LooprSpacing.formRowVerticalPadding)
        .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
    }
}

public struct LooprInlineMessage: View {
    private let text: String
    private let tone: ChipTone

    public init(_ text: String, tone: ChipTone) {
        self.text = text
        self.tone = tone
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.sm) {
            Image(systemName: tone.inlineMessageSymbol)
                .looprTypography(.rowTitle)
                .foregroundStyle(Color.loopr(tone.inlineMessageColor))
                .frame(width: LooprSpacing.lg, height: LooprSpacing.lg)
                .accessibilityHidden(true)

            LooprText(text, style: .prose, color: tone.inlineMessageColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

public struct LooprDetailScaffold<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                content
            }
            .padding(.horizontal, LooprSpacing.screenGutter)
            .padding(.top, LooprSpacing.md)
            .padding(.bottom, LooprSpacing.tabBarClearance)
        }
        // Rows scrolling under the title fade behind a defined edge instead
        // of reading through the back button and the title.
        .scrollEdgeEffectStyle(.hard, for: .top)
        .background(Color.loopr(.background).ignoresSafeArea())
    }
}

private extension ChipTone {
    var inlineMessageColor: LooprColorToken {
        switch self {
        case .neutral: .inkSecondary
        case .positive, .brand: .brand
        case .warning: .warning
        case .critical: .critical
        }
    }

    var inlineMessageSymbol: String {
        switch self {
        case .neutral: "info.circle"
        case .positive: "checkmark.circle"
        case .warning: "exclamationmark.triangle"
        case .critical: "xmark.octagon"
        case .brand: "sparkle"
        }
    }
}
