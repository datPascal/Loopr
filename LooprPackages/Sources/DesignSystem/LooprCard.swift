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

/// The edge a card catches the light on. Cards stay solid fills; the edge is what lifts them off
/// the colour field, never glass.
public enum LooprCardEdge: Equatable, Sendable {
    /// No lit edge: a recessed well.
    case none
    /// The neutral lit edge (`surfaceEdge`).
    case lit
    /// The lead card: lit in its accent from the top.
    case accent(LooprColorToken)
    /// The amber outline of a card that needs a look.
    case caution

    public static func forStyle(_ style: LooprCardStyle) -> Self {
        switch style {
        case .standard, .elevated: .lit
        case .hero(let accent): .accent(accent)
        case .warning: .caution
        case .sunk: .none
        }
    }

    /// How far down the card the dark-mode highlight fades out, as a fraction of its height.
    static let darkHighlightFade = 0.35
    /// The highlight's width: the contract's 0.5 px inset edge, drawn a little firmer for a phone.
    static let width: CGFloat = 0.75
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
                if let litEdge {
                    shape.strokeBorder(litEdge, lineWidth: LooprCardEdge.width)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .overlay {
                if strokeWidth > 0 {
                    shape.strokeBorder(stroke, lineWidth: strokeWidth)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .shadow(color: shadow, radius: 18, y: 6)
    }

    /// The neutral lit edge. In dark mode a highlight runs along the top edge and fades down the
    /// sides; on paper a warm hairline goes round the card. Hero cards draw their accent edge
    /// instead, below.
    private var litEdge: AnyShapeStyle? {
        guard LooprCardEdge.forStyle(style) == .lit else { return nil }
        let edge = Color.loopr(.surfaceEdge)
        guard isDark else { return AnyShapeStyle(edge) }
        return AnyShapeStyle(LinearGradient(stops: [.init(color: edge, location: 0),
                                                    .init(color: edge.opacity(0), location: LooprCardEdge.darkHighlightFade)],
                                            startPoint: .top, endPoint: .bottom))
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

    /// A lead card is lit from its top edge in its accent: a wash that fades down the card and an
    /// edge that catches the light, then disappears towards the bottom.
    private var tint: AnyShapeStyle? {
        switch style {
        case .hero(let accent):
            AnyShapeStyle(LinearGradient(colors: [Color.loopr(accent).opacity(isDark ? 0.11 : 0.06), .clear],
                                         startPoint: .top, endPoint: .bottom))
        case .warning: isDark ? AnyShapeStyle(Color.loopr(.strain).opacity(0.06)) : nil
        default: nil
        }
    }

    private var stroke: AnyShapeStyle {
        switch style {
        case .hero(let accent):
            AnyShapeStyle(LinearGradient(colors: [Color.loopr(accent).opacity(isDark ? 0.34 : 0.22), Color.loopr(accent).opacity(0)],
                                         startPoint: .top, endPoint: .center))
        case .warning: AnyShapeStyle(Color.loopr(.caution).opacity(isDark ? 0.30 : 0.26))
        default: AnyShapeStyle(Color.loopr(.surfaceStroke))
        }
    }

    /// Plain cards have no outline: the fill is enough on warm black and the shadow on paper.
    private var strokeWidth: CGFloat {
        switch style {
        case .warning, .hero: 1
        case .standard, .elevated, .sunk: 0
        }
    }

    private var shadow: Color {
        guard !isDark, style != .sunk else { return .clear }
        return Color.loopr(.ink).opacity(0.05)
    }
}
