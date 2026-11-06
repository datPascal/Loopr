import SwiftUI
import Testing
import UIKit
@testable import DesignSystem

/// DEC-12.2: the Protocol tab accent resolves to the plum values everywhere.
@MainActor struct ProtocolTokenTests {
    private static let pairs: [(LooprColorToken, LooprColorToken)] = [(.protocol, .cyclePlum), (.protocolChip, .cyclePlumChip)]

    @Test func protocolPalettesMatchThePlumPalettes() {
        for (token, plum) in Self.pairs {
            let mine = token.rgbPalette, theirs = plum.rgbPalette
            #expect(mine.light == theirs.light, "\(token) light")
            #expect(mine.dark == theirs.dark, "\(token) dark")
            #expect(mine.highLight == theirs.highLight, "\(token) high-contrast light")
            #expect(mine.highDark == theirs.highDark, "\(token) high-contrast dark")
        }
        #expect(LooprColorToken.protocol.rgbPalette.light == 0xA257CC)
        #expect(LooprColorToken.protocol.rgbPalette.dark == 0xCFA2EE)
        #expect(LooprColorToken.protocol.rawValue == "protocol")
    }

    @Test func protocolResolvesToPlumForEveryTraitCombination() {
        DesignSystemRuntime.reset()
        defer { DesignSystemRuntime.reset() }
        for (token, plum) in Self.pairs {
            for style in [UIUserInterfaceStyle.light, .dark] {
                for contrast in [UIAccessibilityContrast.normal, .high] {
                    let traits = Self.traits(style, contrast)
                    #expect(Self.rgba(token.color, traits) == Self.rgba(plum.color, traits), "\(token) \(style.rawValue) \(contrast.rawValue)")
                }
            }
        }
    }

    @Test func protocolResolvesToPlumUnderEveryRuntimeOverride() {
        defer { DesignSystemRuntime.reset() }
        for appearance in LooprAppearanceOverride.allCases {
            for increasedContrast in [false, true] {
                DesignSystemRuntime.apply(.init(appearance: appearance, increasedContrast: increasedContrast))
                for (token, plum) in Self.pairs {
                    for style in [UIUserInterfaceStyle.light, .dark] {
                        let traits = Self.traits(style, .normal)
                        #expect(Self.rgba(Color.loopr(token), traits) == Self.rgba(Color.loopr(plum), traits),
                                "\(token) \(appearance) contrast \(increasedContrast)")
                    }
                }
            }
        }
    }

    @Test func protocolFollowsThePlumFamilyInDerivedTokens() {
        #expect(LooprColorToken.protocol.textInk == .protocolChip)
        #expect(LooprColorToken.protocol.spectralChipLabel == .protocolChip)
        #expect(LooprColorToken.protocolChip.textInk == .protocolChip)
        for (token, plum) in Self.pairs {
            #expect(token.spectralSweepPartner == plum.spectralSweepPartner)
            #expect(token.spectralStartAngle == plum.spectralStartAngle)
            #expect(token.spectralRotationPeriod == plum.spectralRotationPeriod)
            #expect(StatusChip.accentToken(for: token) == StatusChip.accentToken(for: plum))
        }
    }

    @Test func protocolLabelsMatchPlumLabels() {
        DesignSystemRuntime.reset()
        defer { DesignSystemRuntime.reset() }
        for style in [UIUserInterfaceStyle.light, .dark] {
            for contrast in [UIAccessibilityContrast.normal, .high] {
                let traits = Self.traits(style, contrast)
                #expect(Self.rgba(LooprColorToken.protocol.filledLabelColor, traits)
                    == Self.rgba(LooprColorToken.cyclePlum.filledLabelColor, traits))
                #expect(Self.rgba(LooprColorToken.protocol.tintedLabelColor, traits)
                    == Self.rgba(LooprColorToken.cyclePlum.tintedLabelColor, traits))
            }
        }
    }

    private static func rgba(_ color: Color, _ traits: UITraitCollection) -> [Int] {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(color).resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return [red, green, blue, alpha].map { Int(($0 * 255).rounded()) }
    }

    private static func traits(_ style: UIUserInterfaceStyle, _ contrast: UIAccessibilityContrast) -> UITraitCollection {
        UITraitCollection { traits in
            traits.userInterfaceStyle = style
            traits.accessibilityContrast = contrast
        }
    }
}
