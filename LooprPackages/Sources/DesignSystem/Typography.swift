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

    public var font: Font {
        let font: Font = switch self {
        case .hero: .custom("SpaceGrotesk-Bold", size: 68, relativeTo: .largeTitle)
        case .display: .custom("SpaceGrotesk-SemiBold", size: 47, relativeTo: .largeTitle)
        case .metric: .custom("IBMPlexMono-SemiBold", size: 32, relativeTo: .title)
        case .metricCompact: .custom("IBMPlexMono-SemiBold", size: 23, relativeTo: .title2)
        case .titleLarge: .custom("SpaceGrotesk-SemiBold", size: 30, relativeTo: .largeTitle)
        case .title: .custom("SpaceGrotesk-SemiBold", size: 18, relativeTo: .title2)
        case .body: .custom("SpaceGrotesk-Regular", size: 13, relativeTo: .body)
        case .label: .custom("SpaceGrotesk-Medium", size: 14, relativeTo: .subheadline)
        case .caption: .custom("SpaceGrotesk-Regular", size: 12, relativeTo: .caption)
        case .overline: .custom("IBMPlexMono-Medium", size: 9, relativeTo: .caption2)
        case .screenTitle: .custom("SpaceGrotesk-SemiBold", size: 26, relativeTo: .title)
        case .settingsTitle: .custom("SpaceGrotesk-SemiBold", size: 30, relativeTo: .largeTitle)
        case .lensValue: .custom("SpaceGrotesk-SemiBold", size: 40, relativeTo: .largeTitle)
        case .cardTitle: .custom("SpaceGrotesk-SemiBold", size: 18, relativeTo: .title2)
        case .rowTitle: .custom("SpaceGrotesk-Medium", size: 14, relativeTo: .subheadline)
        case .settingsRow: .custom("SpaceGrotesk-Regular", size: 15, relativeTo: .body)
        case .prose: .custom("SpaceGrotesk-Regular", size: 13, relativeTo: .footnote)
        case .metricValue: .custom("IBMPlexMono-SemiBold", size: 17, relativeTo: .headline)
        case .metricUnit: .custom("IBMPlexMono-Regular", size: 11, relativeTo: .caption)
        case .headerMeta: .custom("IBMPlexMono-Regular", size: 10, relativeTo: .caption2)
        case .sectionLabel: .custom("IBMPlexMono-Medium", size: 9, relativeTo: .caption2)
        case .confidence: .custom("IBMPlexMono-Regular", size: 9, relativeTo: .caption2)
        case .lensCaption: .custom("IBMPlexMono-Medium", size: 9, relativeTo: .caption2)
        case .chip: .custom("IBMPlexMono-Medium", size: 9, relativeTo: .caption2)
        }
        return font
    }

    public var baseSize: CGFloat {
        switch self {
        case .hero: 68
        case .display: 47
        case .metric: 32
        case .metricCompact: 23
        case .titleLarge: 30
        case .title: 18
        case .body: 13
        case .label: 14
        case .caption: 12
        case .overline: 9
        case .screenTitle: 26
        case .settingsTitle: 30
        case .lensValue: 40
        case .cardTitle: 18
        case .rowTitle: 14
        case .settingsRow: 15
        case .prose: 13
        case .metricValue: 17
        case .metricUnit: 11
        case .headerMeta: 10
        case .sectionLabel: 9
        case .confidence: 9
        case .lensCaption: 9
        case .chip: 9
        }
    }

    /// Tracking in points at the style's base size. `looprTypography(_:)` applies it.
    public var tracking: CGFloat {
        switch self {
        case .hero: -0.025 * 68
        case .display: -0.025 * 47
        case .metric, .metricCompact, .body, .label, .caption, .rowTitle, .settingsRow, .prose, .metricValue, .metricUnit: 0
        case .titleLarge, .settingsTitle: -0.025 * baseSize
        case .title, .cardTitle: -0.02 * baseSize
        case .overline, .sectionLabel: 0.18 * baseSize
        case .screenTitle: -0.025 * baseSize
        case .lensValue: -0.03 * baseSize
        case .headerMeta, .confidence: 0.10 * baseSize
        case .lensCaption: 0.16 * baseSize
        case .chip: 0.12 * baseSize
        }
    }
}

public struct LooprText: View {
    private let text: String
    private let style: LooprTextStyle
    private let color: LooprColorToken

    public init(_ text: String, style: LooprTextStyle = .body, color: LooprColorToken = .ink) {
        self.text = text
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
    /// Applies the bundled font, Dynamic Type category, and the style's tracking.
    @ViewBuilder func looprTypography(_ style: LooprTextStyle) -> some View {
        if style == .headerMeta || style == .sectionLabel || style == .overline {
            font(style.font)
                .tracking(style.tracking)
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        } else {
            font(style.font)
                .tracking(style.tracking)
        }
    }
}
