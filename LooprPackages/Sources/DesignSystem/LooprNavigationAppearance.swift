#if canImport(UIKit)
import UIKit

/// Navigation bar titles in Space Grotesk, so a pushed screen's title matches the tab headers.
/// The bar itself keeps the system's glass and scroll-edge behaviour.
public enum LooprNavigationAppearance {
    @MainActor public static func apply() {
        let bar = UINavigationBar.appearance()
        var inline = bar.titleTextAttributes ?? [:]
        if let font = UIFont(name: "SpaceGrotesk-SemiBold", size: 17) {
            inline[.font] = UIFontMetrics(forTextStyle: .headline).scaledFont(for: font)
        }
        bar.titleTextAttributes = inline
        var large = bar.largeTitleTextAttributes ?? [:]
        if let font = UIFont(name: "SpaceGrotesk-SemiBold", size: 32) {
            large[.font] = UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: font)
            large[.kern] = -0.8
        }
        bar.largeTitleTextAttributes = large
    }
}
#endif
