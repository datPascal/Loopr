import SwiftUI

/// A round sticker for a meal with no photo: a soft disc in the meal's colours inside the white rim of a photo
/// sticker, with the first item's initial, or the meal's symbol when there is no letter. Food's eating-window rail and
/// Today's dial both draw it, so a meal looks the same on both tabs.
///
/// ```swift
/// LooprDrawnSticker(meal: "Dinner", initial: "P", diameter: 44)
/// ```
public struct LooprDrawnSticker: View {
    /// The disc's light and deep colour.
    public struct Palette: Equatable, Sendable {
        public let light: Color
        public let deep: Color

        public init(light: Color, deep: Color) {
            self.light = light
            self.deep = deep
        }
    }

    /// The white rim is this share of the diameter on each side when the caller gives none (2.5 of a 33-point sticker,
    /// as on Today's dial).
    public nonisolated static let rimShare: CGFloat = 2.5 / 33

    private let meal: String
    private let initial: String?
    private let diameter: CGFloat
    private let rim: CGFloat

    /// - Parameters:
    ///   - meal: The meal slot's title, "Breakfast", "Lunch", "Snack" or "Dinner". It picks the colours and symbol.
    ///   - initial: The first item's initial. Nil shows the meal's symbol.
    ///   - rim: The white rim's width. Nil uses `rimShare` of the diameter.
    public init(meal: String, initial: String? = nil, diameter: CGFloat, rim: CGFloat? = nil) {
        self.meal = meal
        self.initial = initial
        self.diameter = diameter
        self.rim = rim ?? diameter * Self.rimShare
    }

    /// Morning amber, a green lunch, a berry snack, an indigo dinner. Anything else is dinner's.
    public nonisolated static func palette(forMeal title: String) -> Palette {
        switch title.lowercased() {
        case "breakfast": Palette(light: Color(red: 0.96, green: 0.78, blue: 0.49), deep: Color(red: 0.86, green: 0.48, blue: 0.2))
        case "lunch": Palette(light: Color(red: 0.73, green: 0.89, blue: 0.62), deep: Color(red: 0.24, green: 0.58, blue: 0.4))
        case "snack": Palette(light: Color(red: 0.96, green: 0.7, blue: 0.77), deep: Color(red: 0.76, green: 0.27, blue: 0.42))
        default: Palette(light: Color(red: 0.72, green: 0.74, blue: 0.96), deep: Color(red: 0.33, green: 0.3, blue: 0.69))
        }
    }

    /// The symbol for a meal slot's title. Anything else gets a knife and fork.
    public nonisolated static func symbol(forMeal title: String) -> String {
        switch title.lowercased() {
        case "breakfast": "sunrise.fill"
        case "snack": "carrot.fill"
        case "dinner": "moon.stars.fill"
        default: "fork.knife"
        }
    }

    public var body: some View {
        let palette = Self.palette(forMeal: meal)
        ZStack {
            Circle().fill(RadialGradient(colors: [palette.light, palette.deep], center: .init(x: 0.34, y: 0.3), startRadius: 2,
                                         endRadius: diameter * 0.7))
            Circle().fill(RadialGradient(colors: [.white.opacity(0.5), .clear], center: .init(x: 0.32, y: 0.26), startRadius: 0,
                                         endRadius: diameter * 0.28))
            if let initial {
                Text(initial)
                    .font(.custom("SpaceGrotesk-SemiBold", size: diameter * 0.4))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                    .dynamicTypeSize(.large)
            } else {
                Image(systemName: Self.symbol(forMeal: meal))
                    .font(.system(size: diameter * 0.34, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .padding(rim)
        .background(Circle().fill(.white))
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }
}

/// The gallery entry for the drawn sticker, one per meal slot.
struct LooprDrawnStickerGallery: View {
    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Drawn stickers", detail: "For a meal with no photo. Food's rail and Today's dial share it.")
            HStack(spacing: LooprSpacing.sm) {
                LooprDrawnSticker(meal: "Breakfast", initial: "O", diameter: 44)
                LooprDrawnSticker(meal: "Lunch", diameter: 44)
                LooprDrawnSticker(meal: "Snack", initial: "A", diameter: 44)
                LooprDrawnSticker(meal: "Dinner", diameter: 44)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Drawn stickers for breakfast, lunch, snack and dinner")
            .accessibilityIdentifier("gallery-drawn-sticker")
        }
    }
}
