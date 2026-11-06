import SwiftUI

/// How a glass control draws. iOS 26 glass by default; a solid fill under Reduce Transparency;
/// an outline in the high-contrast tokens under Increase Contrast.
public struct LooprGlassAppearance: Equatable, Sendable {
    public let usesGlass: Bool
    public let isOutlined: Bool

    public init(reduceTransparency: Bool, increasedContrast: Bool) {
        usesGlass = !reduceTransparency
        isOutlined = increasedContrast
    }

    /// The solid fill used instead of glass.
    public nonisolated static let solidFill: LooprColorToken = .surfaceElevated
    /// The outline under Increase Contrast. Its high-contrast values are the ones that show.
    public nonisolated static let outline: LooprColorToken = .surfaceEdge
}

/// Glass, or its solid fallback, behind a control in `shape`.
struct LooprGlassBackground<S: InsettableShape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    let shape: S
    var interactive = true

    func body(content: Content) -> some View {
        let appearance = LooprGlassAppearance(
            reduceTransparency: reduceTransparency,
            increasedContrast: colorSchemeContrast == .increased || DesignSystemRuntime.state().increasedContrast
        )
        Group {
            if appearance.usesGlass {
                content.glassEffect(.regular.interactive(interactive), in: shape)
            } else {
                content.background(Color.loopr(LooprGlassAppearance.solidFill), in: shape)
            }
        }
        .overlay {
            if appearance.isOutlined {
                shape.strokeBorder(Color.loopr(LooprGlassAppearance.outline), lineWidth: LooprSpacing.hairline)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

public extension View {
    /// iOS 26 glass in `shape`, solid under Reduce Transparency and outlined under Increase Contrast.
    func looprGlass<S: InsettableShape>(in shape: S, interactive: Bool = true) -> some View {
        modifier(LooprGlassBackground(shape: shape, interactive: interactive))
    }
}

/// A glass control in the header or over a picture: a round icon button (the contract's `.gbtn`
/// and `.gcirc`) or a pill (`.gpill`). The prominent pill is a solid ink fill, never glass.
///
/// ```swift
/// LooprGlassButton(symbol: "plus", accessibilityLabel: "Add a rule", identifier: "protocol-add") { ... }
/// LooprGlassButton("This week", symbol: "calendar", identifier: "protocol-week") { ... }
/// ```
public struct LooprGlassButton: View {
    /// The round button's drawn size. Every size keeps at least a 48 pt hit target.
    public enum Size: CaseIterable, Sendable {
        /// 40 pt, the contract's `.gcirc.sm`.
        case small
        /// 44 pt, a header button (`.gbtn`).
        case regular
        /// 54 pt, a capture or start button (`.gcirc`).
        case large

        public var diameter: CGFloat {
            switch self {
            case .small: 40
            case .regular: 44
            case .large: 54
            }
        }

        /// The tappable square around the drawn circle.
        public var hitTarget: CGFloat { max(diameter, LooprGlassButton.minimumHitTarget) }

        var symbolStyle: LooprTextStyle { self == .large ? .title : .metricValue }
    }

    private enum Kind {
        case icon(symbol: String, size: Size)
        case pill(title: String, symbol: String?, prominent: Bool)
    }

    /// The smallest tappable size of any glass control, above the 44 pt minimum.
    public nonisolated static let minimumHitTarget: CGFloat = LooprSpacing.headerControlDiameter

    private let kind: Kind
    private let accessibilityLabel: String
    private let tint: LooprColorToken
    private let identifier: String
    private let action: () -> Void

    /// A round icon button. `accessibilityLabel` is what VoiceOver reads for the symbol.
    public init(symbol: String, accessibilityLabel: String, size: Size = .regular, tint: LooprColorToken = .ink,
                identifier: String, action: @escaping () -> Void) {
        kind = .icon(symbol: symbol, size: size)
        self.accessibilityLabel = accessibilityLabel
        self.tint = tint
        self.identifier = identifier
        self.action = action
    }

    /// A pill with a title and an optional leading symbol.
    public init(_ title: String, symbol: String? = nil, prominent: Bool = false, identifier: String,
                action: @escaping () -> Void) {
        kind = .pill(title: title, symbol: symbol, prominent: prominent)
        accessibilityLabel = title
        tint = .ink
        self.identifier = identifier
        self.action = action
    }

    public var body: some View {
        Button(action: action) { label }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityIdentifier(identifier)
    }

    @ViewBuilder private var label: some View {
        switch kind {
        case let .icon(symbol, size):
            Image(systemName: symbol)
                .looprTypography(size.symbolStyle)
                .foregroundStyle(Color.loopr(tint))
                .frame(width: size.diameter, height: size.diameter)
                .looprGlass(in: Circle())
                .frame(width: size.hitTarget, height: size.hitTarget)
                .contentShape(.interaction, Rectangle())
        case let .pill(title, symbol, prominent):
            let content = HStack(spacing: LooprSpacing.xxs + 2) {
                if let symbol { Image(systemName: symbol).imageScale(.small) }
                Text(title).looprTypography(.label)
            }
            .padding(.vertical, LooprSpacing.xs + 1)
            .padding(.horizontal, LooprSpacing.md - 2)
            Group {
                if prominent {
                    content
                        .foregroundStyle(Color.loopr(.background))
                        .background(Color.loopr(.ink), in: Capsule(style: .continuous))
                } else {
                    content
                        .foregroundStyle(Color.loopr(.ink))
                        .looprGlass(in: Capsule(style: .continuous))
                }
            }
            .frame(minHeight: Self.minimumHitTarget)
            .contentShape(.interaction, Rectangle())
        }
    }
}

/// One option of a `LooprGlassSegmentedControl`.
public struct LooprGlassSegment<Value: Hashable>: Identifiable {
    public let value: Value
    public let title: String
    /// The accessibility identifier of this option's button.
    public let identifier: String
    public var id: String { identifier }

    public init(_ title: String, value: Value, identifier: String) {
        self.title = title
        self.value = value
        self.identifier = identifier
    }
}

/// A glass segmented control (the contract's `.gseg`): a glass capsule with the chosen option
/// lifted inside it. Each option is a button of at least 44 pt with its own identifier.
public struct LooprGlassSegmentedControl<Value: Hashable>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selectionNamespace
    @Binding private var selection: Value
    private let label: String
    private let segments: [LooprGlassSegment<Value>]
    private let identifier: String

    /// The smallest height of one option.
    public nonisolated static var segmentHeight: CGFloat { 44 }
    /// The gap between the capsule and the options.
    public nonisolated static var inset: CGFloat { LooprSpacing.xxs }

    public init(_ label: String, segments: [LooprGlassSegment<Value>], selection: Binding<Value>, identifier: String) {
        self.label = label
        self.segments = segments
        _selection = selection
        self.identifier = identifier
    }

    public var body: some View {
        HStack(spacing: LooprSpacing.none) {
            ForEach(segments) { segment in
                option(segment)
            }
        }
        .padding(Self.inset)
        .looprGlass(in: Capsule(style: .continuous), interactive: false)
        .sensoryFeedback(.selection, trigger: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    private func option(_ segment: LooprGlassSegment<Value>) -> some View {
        let isSelected = segment.value == selection
        return Button {
            withAnimation(LooprMotion.reducesMotion(reduceMotion) ? nil : LooprMotion.stateChange) {
                selection = segment.value
            }
        } label: {
            Text(segment.title)
                .looprTypography(.label)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(Color.loopr(isSelected ? .ink : .inkSecondary))
                .padding(.horizontal, LooprSpacing.xs)
                .frame(maxWidth: .infinity, minHeight: Self.segmentHeight)
                .background {
                    if isSelected {
                        Capsule(style: .continuous)
                            .fill(Color.loopr(.divider))
                            .overlay(Capsule(style: .continuous).strokeBorder(
                                LinearGradient(colors: [Color.loopr(.surfaceEdge), .clear], startPoint: .top, endPoint: .center),
                                lineWidth: LooprCardEdge.width))
                            .matchedGeometryEffect(id: "selection", in: selectionNamespace)
                    }
                }
                .contentShape(.interaction, Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(segment.identifier)
    }
}
