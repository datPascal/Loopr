import SwiftUI

// Layout and motion tokens for the shared tab header and the card system.
// They extend the base token enums in `DesignTokens.swift` the same way
// `Forms.swift` does, so every tab reads one set of numbers.

public extension LooprSpacing {
    /// Header text inset: the 16 pt card gutter plus a 4 pt optical inset, so
    /// the title lines up with the text inside the cards below it.
    static let headerHorizontal: CGFloat = 20
    static let headerVertical: CGFloat = 12
    /// How far the page scrolls before the header is fully collapsed.
    static let headerCollapseDistance: CGFloat = 44
    /// Height the meta line gives back when the header collapses.
    static let headerMetaCollapse: CGFloat = 10
    /// Gap between the chip, the day control and the band button.
    static let headerClusterSpacing: CGFloat = 8

    /// Padding inside a regular card.
    static let cardVertical: CGFloat = 16
    static let cardHorizontal: CGFloat = 18
    /// Padding inside a compact card, such as a number tile.
    static let compactCardVertical: CGFloat = 12
    static let compactCardHorizontal: CGFloat = 14
    /// Vertical padding of a row inside a hairline list.
    static let metricRowVertical: CGFloat = 13
    /// Space between the header and the first card on a tab.
    static let tabContentTop: CGFloat = 8
    /// Space between two cards that belong together.
    static let cardStack: CGFloat = 12
    /// Space between titled sections on a tab.
    static let tabSection: CGFloat = 24
}

public extension LooprRadius {
    /// The corner radius of a regular card: tighter on the dark set, softer on
    /// the white one.
    static func surface(isDark: Bool) -> CGFloat {
        isDark ? compactCard : card
    }
}

public extension LooprMotion {
    /// True when the system or the in-app setting asks for less motion.
    static func reducesMotion(_ environmentValue: Bool) -> Bool {
        environmentValue || DesignSystemRuntime.state().reduceMotion == true
    }

    /// The header settling to expanded or collapsed after a scroll.
    static var headerCollapse: Animation {
        DesignSystemRuntime.state().reduceMotion == true ? .linear(duration: 0) : .smooth(duration: 0.24)
    }

    /// A card being pressed or released.
    static let press: Animation = .snappy(duration: fast)

    /// Loading, content, empty and failed replacing each other.
    static func phaseChange(reduceMotion: Bool) -> Animation {
        reducesMotion(reduceMotion) ? .easeInOut(duration: fast) : .smooth(duration: standard)
    }
}
