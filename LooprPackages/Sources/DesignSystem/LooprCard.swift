import SwiftUI

/// What a card says about its content.
public enum LooprCardStyle: Equatable, Sendable {
    /// The plain card every tab uses.
    case standard
    /// A slightly raised fill, for a card that sits on another surface.
    case elevated
    /// A card that leads a screen, tinted and outlined with its accent.
    case hero(LooprColorToken)
    /// Something that needs a look: an amber outline.
    case warning
    /// A recessed well with no shadow or outline.
    case sunk
}

/// How much room a card leaves around its content.
public enum LooprCardDensity: Equatable, Sendable {
    /// Regular cards: 16 by 18 pt.
    case regular
    /// Tiles and slim rows: 12 by 14 pt, with the compact radius.
    case compact
    /// No padding. Lists draw their own row insets.
    case flush

    var radiusIsCompact: Bool { self == .compact }

    var insets: EdgeInsets {
        switch self {
        case .regular:
            EdgeInsets(top: LooprSpacing.cardVertical, leading: LooprSpacing.cardHorizontal,
                       bottom: LooprSpacing.cardVertical, trailing: LooprSpacing.cardHorizontal)
        case .compact:
            EdgeInsets(top: LooprSpacing.compactCardVertical, leading: LooprSpacing.compactCardHorizontal,
                       bottom: LooprSpacing.compactCardVertical, trailing: LooprSpacing.compactCardHorizontal)
        case .flush:
            EdgeInsets()
        }
    }
}

/// The one card surface. Every tab card, tile and list draws its background
/// through this, so radius, fill, outline and shadow agree everywhere.
public struct LooprCard<Content: View>: View {
    private let style: LooprCardStyle
    private let density: LooprCardDensity
    private let content: Content

    public init(
        style: LooprCardStyle = .standard,
        density: LooprCardDensity = .regular,
        @ViewBuilder content: () -> Content
    ) {
        self.style = style
        self.density = density
        self.content = content()
    }

    public var body: some View {
        content
            .padding(density.insets)
            .frame(maxWidth: .infinity, alignment: .leading)
            .looprCardBackground(style, density: density)
    }
}

public extension View {
    /// Draws the card surface behind a view that sets its own padding.
    func looprCardBackground(_ style: LooprCardStyle = .standard, density: LooprCardDensity = .regular) -> some View {
        modifier(LooprCardBackground(style: style, compactRadius: density.radiusIsCompact))
    }
}

public struct LooprCardBackground: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    private let style: LooprCardStyle
    private let compactRadius: Bool

    public init(style: LooprCardStyle = .standard, compactRadius: Bool = false) {
        self.style = style
        self.compactRadius = compactRadius
    }

    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content
            .background(fill, in: shape)
            .overlay {
                if let tint {
                    shape.fill(tint).allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .overlay {
                if strokeWidth > 0 {
                    shape.strokeBorder(stroke, lineWidth: strokeWidth)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .shadow(color: shadow, radius: LooprRadius.surfaceShadow, y: LooprSpacing.surfaceShadowOffset)
            .shadow(color: heroShadow, radius: 15, y: 10)
    }

    private var isDark: Bool { LooprAppearance.isDark(colorScheme) }

    private var radius: CGFloat {
        compactRadius ? LooprRadius.compactCard : LooprRadius.surface(isDark: isDark)
    }

    private var fill: Color {
        switch style {
        case .standard, .hero, .warning: isDark ? Color.loopr(.surface) : Color.loopr(.sheetFill)
        case .elevated: Color.loopr(.surfaceElevated)
        case .sunk: Color.loopr(.surfaceSunk)
        }
    }

    private var tint: Color? {
        switch style {
        case .hero(let accent): Color.loopr(accent).opacity(isDark ? 0.06 : 0.03)
        case .warning: isDark ? Color.loopr(.strain).opacity(0.05) : nil
        default: nil
        }
    }

    private var stroke: Color {
        switch style {
        case .standard, .elevated: Color.loopr(.surfaceStroke)
        case .hero(let accent): Color.loopr(accent).opacity(isDark ? 0.30 : 0.25)
        case .warning: Color.loopr(.caution).opacity(isDark ? 0.35 : 0.30)
        case .sunk: .clear
        }
    }

    private var strokeWidth: CGFloat {
        switch style {
        case .warning: 1
        case .sunk: 0
        default: isDark ? 1 : 0
        }
    }

    private var shadow: Color {
        guard !isDark, style != .sunk else { return .clear }
        return Color.loopr(.ink).opacity(0.06)
    }

    private var heroShadow: Color {
        guard !isDark, case .hero = style else { return .clear }
        return Color.loopr(.ink).opacity(0.05)
    }
}
