import SwiftUI
import Testing
import UIKit
@testable import DesignSystem

/// Button and chip labels read against their own fill or tint in light mode. The light teal and orange
/// fills under light text read at 2.7:1 before; the darkened tinted labels must reach 4.5:1.
@MainActor
struct LabelContrastTests {
    private let accents: [LooprColorToken] = [.brand, .movement, .energy, .strain, .heart, .sleep, .cyclePlum,
                                              .recoveryHigh, .recoveryMid, .recoveryLow, .warning, .critical, .inkSecondary]

    @Test func filledLabelsReadOnTheirFill() {
        DesignSystemRuntime.reset(); defer { DesignSystemRuntime.reset() }
        for contrast in [UIAccessibilityContrast.normal, .high] {
            let light = traits(.light, contrast)
            for accent in accents {
                let ratio = Self.contrast(resolve(accent.filledLabelColor, light), resolve(Color.loopr(accent), light))
                #expect(ratio >= 3.4, "\(accent) filled label \(ratio)")
            }
        }
    }

    @Test func tintedLabelsReachAAOnTheirTint() {
        DesignSystemRuntime.reset(); defer { DesignSystemRuntime.reset() }
        let light = traits(.light, .normal)
        let page = resolve(Color.loopr(.background), light)
        for accent in accents {
            let fill = resolve(Color.loopr(accent), light)
            let tint = Self.mix(fill, over: page, weight: 0.10)
            let ratio = Self.contrast(resolve(accent.tintedLabelColor, light), tint)
            #expect(ratio >= 4.5, "\(accent) tinted label \(ratio)")
        }
    }

    @Test func darkModeKeepsItsLabels() {
        DesignSystemRuntime.reset(); defer { DesignSystemRuntime.reset() }
        let dark = traits(.dark, .normal)
        #expect(resolve(LooprColorToken.brand.filledLabelColor, dark) == resolve(Color.loopr(.background), dark))
        #expect(resolve(LooprColorToken.brand.tintedLabelColor, dark) == resolve(Color.loopr(.brand), dark))
    }

    private func resolve(_ color: Color, _ traits: UITraitCollection) -> [Double] {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(color).resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return [red, green, blue].map { (Double($0) * 1000).rounded() / 1000 }
    }

    private static func mix(_ color: [Double], over base: [Double], weight: Double) -> [Double] {
        zip(color, base).map { $0 * weight + $1 * (1 - weight) }
    }

    private static func contrast(_ a: [Double], _ b: [Double]) -> Double {
        func luminance(_ c: [Double]) -> Double {
            let l = c.map { $0 <= 0.03928 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return 0.2126 * l[0] + 0.7152 * l[1] + 0.0722 * l[2]
        }
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    private func traits(_ style: UIUserInterfaceStyle, _ contrast: UIAccessibilityContrast) -> UITraitCollection {
        UITraitCollection { $0.userInterfaceStyle = style; $0.accessibilityContrast = contrast }
    }
}
