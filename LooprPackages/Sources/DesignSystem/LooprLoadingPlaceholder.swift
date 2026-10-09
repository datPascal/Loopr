import SwiftUI

/// What a tab shows while its first numbers load.
///
/// It stays invisible for `revealDelay`: most loads finish inside it, and a
/// placeholder that flashes for a frame or two reads as flicker. After that it
/// fades in, shaped like the content it stands in for, with a soft highlight
/// that keeps sweeping across every block in step. With Reduce Motion the
/// blocks breathe in opacity instead.
public struct LooprLoadingPlaceholder: View {
    public enum Layout: Equatable, Sendable {
        /// A large ring with a line under it, a card of three small rings,
        /// then `cards` plain cards. Today.
        case ringHero(cards: Int)
        /// A card with a large number and a chart band, then `cards` cards.
        /// Sleep, Heart and Body.
        case heroCard(cards: Int)
        /// `count` plain cards. Workouts and lists.
        case cards(Int)
    }

    public static let revealDelay: Duration = .milliseconds(300)

    private let layout: Layout
    private let revealDelay: Duration
    @State private var revealed = false

    public init(_ layout: Layout, revealDelay: Duration = LooprLoadingPlaceholder.revealDelay) {
        self.layout = layout
        self.revealDelay = revealDelay
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.cardStack) {
            switch layout {
            case .ringHero(let cards):
                ringHero
                ringRow
                cardStack(cards)
            case .heroCard(let cards):
                heroCard
                cardStack(cards)
            case .cards(let count):
                cardStack(count)
            }
        }
        .padding(.horizontal, LooprSpacing.screenGutter)
        .padding(.top, LooprSpacing.tabContentTop)
        .opacity(revealed ? 1 : 0)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
        .accessibilityHidden(!revealed)
        .accessibilityIdentifier("loading-placeholder")
        .task {
            guard !revealed else { return }
            do { try await Task.sleep(for: revealDelay) } catch { return }
            withAnimation(.easeIn(duration: 0.2)) { revealed = true }
        }
    }

    private var ringHero: some View {
        VStack(spacing: LooprSpacing.md) {
            Circle()
                .stroke(LooprPlaceholderStyle.blockFill, lineWidth: 14)
                .frame(width: 176, height: 176)
                .looprShimmer()
            LooprPlaceholderBlock(width: 150, height: 12)
            LooprPlaceholderBlock(width: 220, height: 10)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, LooprSpacing.md)
    }

    private var ringRow: some View {
        LooprCard(density: .flush) {
            HStack(spacing: 0) {
                ForEach(0..<3, id: \.self) { _ in
                    VStack(spacing: LooprSpacing.xs) {
                        Circle()
                            .stroke(LooprPlaceholderStyle.blockFill, lineWidth: 6)
                            .frame(width: 56, height: 56)
                            .looprShimmer()
                        LooprPlaceholderBlock(width: 44, height: 9)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, LooprSpacing.lg)
        }
    }

    private var heroCard: some View {
        LooprCard {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                LooprPlaceholderBlock(width: 90, height: 10)
                LooprPlaceholderBlock(width: 140, height: 30)
                LooprPlaceholderBlock(height: 120, radius: 10)
                    .padding(.top, LooprSpacing.xs)
                LooprPlaceholderBlock(width: 210, height: 10)
            }
        }
    }

    private func cardStack(_ count: Int) -> some View {
        ForEach(0..<count, id: \.self) { index in
            LooprCard {
                VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                    LooprPlaceholderBlock(width: index.isMultiple(of: 2) ? 120 : 96, height: 11)
                    LooprPlaceholderBlock(height: 12)
                    LooprPlaceholderBlock(width: index.isMultiple(of: 2) ? 180 : 230, height: 12)
                }
            }
        }
    }
}

/// One grey block of a loading placeholder.
public struct LooprPlaceholderBlock: View {
    private let width: CGFloat?
    private let height: CGFloat
    private let radius: CGFloat

    public init(width: CGFloat? = nil, height: CGFloat, radius: CGFloat = 5) {
        self.width = width
        self.height = height
        self.radius = radius
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(LooprPlaceholderStyle.blockFill)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .looprShimmer()
            .accessibilityHidden(true)
    }
}

enum LooprPlaceholderStyle {
    static var blockFill: Color { Color.loopr(.ink).opacity(0.07) }
    static var highlight: Color { Color.loopr(.ink).opacity(0.07) }
}

public extension View {
    /// A soft highlight sweeping across the view, in step with every other
    /// shimmering view on screen. Reduce Motion swaps it for a slow fade.
    func looprShimmer() -> some View {
        modifier(LooprShimmer())
    }
}

struct LooprShimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One sweep plus the rest before the next.
    static let period: Double = 1.6
    static let bandWidth: CGFloat = 160
    /// The sweep covers this much of the screen in global coordinates, so a
    /// block at the left and one at the right light up one after the other.
    static let span: CGFloat = 520

    func body(content: Content) -> some View {
        if LooprMotion.reducesMotion(reduceMotion) {
            content.keyframeAnimator(initialValue: 1.0, repeating: true) { view, opacity in
                view.opacity(opacity)
            } keyframes: { _ in
                CubicKeyframe(0.55, duration: 1.1)
                CubicKeyframe(1.0, duration: 1.1)
            }
        } else {
            content
                .overlay {
                    GeometryReader { proxy in
                        let minX = proxy.frame(in: .global).minX
                        Color.clear.keyframeAnimator(initialValue: 0.0, repeating: true) { view, progress in
                            view.overlay(alignment: .leading) {
                                LinearGradient(
                                    colors: [.clear, LooprPlaceholderStyle.highlight, .clear],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                                .frame(width: Self.bandWidth)
                                .offset(x: -Self.bandWidth + progress * (Self.span + Self.bandWidth) - minX)
                            }
                        } keyframes: { _ in
                            LinearKeyframe(1.0, duration: Self.period * 0.8)
                            LinearKeyframe(1.0, duration: Self.period * 0.2)
                        }
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
        }
    }
}
