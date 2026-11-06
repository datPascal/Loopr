import SwiftUI

public enum LooprTextStyle: String, CaseIterable, Sendable {
    case hero
    case display
    case metric
    case metricCompact
    case titleLarge
    case title
    case body
    case label
    case caption
    case overline
    case screenTitle
    case settingsTitle
    case lensValue
    case cardTitle
    case rowTitle
    case settingsRow
    case prose
    case metricValue
    case metricUnit
    case headerMeta
    case sectionLabel
    case confidence
    case lensCaption
    case chip
    /// The label of a full-width button.
    case button
    /// Hero numbers, set in Space Grotesk Light with tabular figures and tight tracking. The three
    /// sizes are the contract's `.num.lg` (48 pt), `.num.xl` (60 pt) and `.num.xxl` (76 pt).
    case heroNumeralLarge
    case heroNumeralXL
    case heroNumeralXXL
    /// The unit beside a hero numeral (the contract's `.num small`), in secondary ink.
    case heroNumeralUnit

    /// The PostScript name of the bundled `SpaceGrotesk-Light.ttf`.
    public static let heroNumeralFontName = "SpaceGrotesk-Light"
    /// Hero numerals scale with Dynamic Type relative to this text style.
    public static let heroNumeralTextStyle: Font.TextStyle = .largeTitle
    /// Hero numerals grow with Dynamic Type up to this size and hold there, so a 76 pt number does
    /// not grow past the screen at the accessibility sizes.
    public static let heroNumeralMaximumDynamicTypeSize: DynamicTypeSize = .accessibility1
    /// A hero numeral wider than its space shrinks to this fraction instead of clipping.
    public static let heroNumeralMinimumScaleFactor: CGFloat = 0.5
    /// The hero numeral styles, smallest first.
    public static let heroNumerals: [LooprTextStyle] = [.heroNumeralLarge, .heroNumeralXL, .heroNumeralXXL]

    /// Space Grotesk throughout. Numbers use its tabular figures, so a value that counts up does not
    /// jitter; there is no separate mono face any more (redesign of 2026-10-22).
    public var font: Font {
        let font: Font = switch self {
        case .hero: .custom("SpaceGrotesk-Medium", size: 76, relativeTo: .largeTitle)
        case .display: .custom("SpaceGrotesk-Medium", size: 52, relativeTo: .largeTitle)
        case .metric: .custom("SpaceGrotesk-Medium", size: 32, relativeTo: .title)
        case .metricCompact: .custom("SpaceGrotesk-Medium", size: 24, relativeTo: .title2)
        case .titleLarge: .custom("SpaceGrotesk-SemiBold", size: 32, relativeTo: .largeTitle)
        case .title: .custom("SpaceGrotesk-SemiBold", size: 20, relativeTo: .title2)
        case .body: .custom("SpaceGrotesk-Regular", size: 15, relativeTo: .body)
        case .label: .custom("SpaceGrotesk-Medium", size: 15, relativeTo: .subheadline)
        case .caption: .custom("SpaceGrotesk-Regular", size: 13, relativeTo: .caption)
        case .overline: .custom("SpaceGrotesk-Medium", size: 12, relativeTo: .caption2)
        case .screenTitle: .custom("SpaceGrotesk-SemiBold", size: 34, relativeTo: .title)
        case .settingsTitle: .custom("SpaceGrotesk-SemiBold", size: 32, relativeTo: .largeTitle)
        case .lensValue: .custom("SpaceGrotesk-Medium", size: 44, relativeTo: .largeTitle)
        case .cardTitle: .custom("SpaceGrotesk-SemiBold", size: 20, relativeTo: .title2)
        case .rowTitle: .custom("SpaceGrotesk-Medium", size: 16, relativeTo: .subheadline)
        case .settingsRow: .custom("SpaceGrotesk-Regular", size: 16, relativeTo: .body)
        case .prose: .custom("SpaceGrotesk-Regular", size: 16, relativeTo: .body)
        case .metricValue: .custom("SpaceGrotesk-Medium", size: 18, relativeTo: .headline)
        case .metricUnit: .custom("SpaceGrotesk-Regular", size: 13, relativeTo: .caption)
        case .headerMeta: .custom("SpaceGrotesk-Medium", size: 14, relativeTo: .caption)
        case .sectionLabel: .custom("SpaceGrotesk-Medium", size: 14, relativeTo: .caption)
        case .confidence: .custom("SpaceGrotesk-Regular", size: 12, relativeTo: .caption2)
        case .lensCaption: .custom("SpaceGrotesk-Medium", size: 12, relativeTo: .caption2)
        case .chip: .custom("SpaceGrotesk-Medium", size: 12, relativeTo: .caption2)
        case .button: .custom("SpaceGrotesk-Medium", size: 17, relativeTo: .body)
        case .heroNumeralLarge, .heroNumeralXL, .heroNumeralXXL:
            .custom(Self.heroNumeralFontName, size: baseSize, relativeTo: Self.heroNumeralTextStyle)
        case .heroNumeralUnit: .custom("SpaceGrotesk-Regular", size: 22, relativeTo: .title2)
        }
        return isNumeric ? font.monospacedDigit() : font
    }

    /// Styles that set numbers.
    public var isNumeric: Bool {
        switch self {
        case .hero, .display, .metric, .metricCompact, .lensValue, .metricValue: true
        case .heroNumeralLarge, .heroNumeralXL, .heroNumeralXXL: true
        default: false
        }
    }

    /// Styles set in Space Grotesk Light for the one hero number on a screen.
    public var isHeroNumeral: Bool {
        switch self {
        case .heroNumeralLarge, .heroNumeralXL, .heroNumeralXXL: true
        default: false
        }
    }

    public var baseSize: CGFloat {
        switch self {
        case .hero: 76
        case .display: 52
        case .metric: 32
        case .metricCompact: 24
        case .titleLarge: 32
        case .title: 20
        case .body: 15
        case .label: 15
        case .caption: 13
        case .overline: 12
        case .screenTitle: 34
        case .settingsTitle: 32
        case .lensValue: 44
        case .cardTitle: 20
        case .rowTitle: 16
        case .settingsRow: 16
        case .prose: 16
        case .metricValue: 18
        case .metricUnit: 13
        case .headerMeta: 14
        case .sectionLabel: 14
        case .confidence: 12
        case .lensCaption: 12
        case .chip: 12
        case .button: 17
        case .heroNumeralLarge: 48
        case .heroNumeralXL: 60
        case .heroNumeralXXL: 76
        case .heroNumeralUnit: 22
        }
    }

    /// Tracking in points at the style's base size. `looprTypography(_:)` applies it.
    public var tracking: CGFloat {
        switch self {
        // The contract's `.num` letter-spacing is -0.05 em.
        case .heroNumeralLarge, .heroNumeralXL, .heroNumeralXXL: -0.05 * baseSize
        case .heroNumeralUnit: -0.01 * baseSize
        case .hero, .display: -0.035 * baseSize
        case .lensValue, .metric: -0.025 * baseSize
        case .titleLarge, .settingsTitle, .screenTitle: -0.025 * baseSize
        case .title, .cardTitle, .metricCompact: -0.015 * baseSize
        case .overline, .sectionLabel, .headerMeta, .confidence, .lensCaption, .chip: 0
        case .body, .label, .caption, .rowTitle, .settingsRow, .prose, .metricValue, .metricUnit, .button: 0
        }
    }
}

public struct LooprText: View {
    private let text: String
    private let style: LooprTextStyle
    private let color: LooprColorToken

    /// An all-caps `text` is set in sentence case, as every Loopr label is (see `LooprLabelCase`).
    public init(_ text: String, style: LooprTextStyle = .body, color: LooprColorToken = .ink) {
        self.text = text.looprLabelCased
        self.style = style
        self.color = color
    }

    public var body: some View {
        Text(text)
            .looprTypography(style)
            .foregroundStyle(Color.loopr(color))
    }
}

public struct MetricNumeral: View {
    private let value: String
    private let style: LooprTextStyle

    public init(_ value: String, compact: Bool = false) {
        self.value = value
        style = compact ? .metricCompact : .metric
    }

    public var body: some View {
        Text(value)
            .looprTypography(style)
            .foregroundStyle(Color.loopr(.ink))
            .contentTransition(.numericText())
    }
}

public extension View {
    /// Applies the bundled font, Dynamic Type category, and the style's tracking. A hero numeral
    /// stays on one line, stops growing at `heroNumeralMaximumDynamicTypeSize` and shrinks to fit
    /// rather than clip.
    @ViewBuilder func looprTypography(_ style: LooprTextStyle) -> some View {
        if style.isHeroNumeral {
            font(style.font)
                .tracking(style.tracking)
                .lineLimit(1)
                .minimumScaleFactor(LooprTextStyle.heroNumeralMinimumScaleFactor)
                .dynamicTypeSize(...LooprTextStyle.heroNumeralMaximumDynamicTypeSize)
        } else if style == .headerMeta || style == .sectionLabel || style == .overline {
            font(style.font)
                .tracking(style.tracking)
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        } else {
            font(style.font)
                .tracking(style.tracking)
        }
    }
}
