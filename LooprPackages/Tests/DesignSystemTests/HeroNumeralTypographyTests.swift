import CoreText
import CryptoKit
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import DesignSystem

/// LV-01.1: hero numbers are Space Grotesk Light with tabular figures and tight tracking, sized
/// as the contract's `.num.lg`, `.num.xl` and `.num.xxl`. The font is read from the repository,
/// so the suite runs without the app bundle.
@MainActor struct HeroNumeralTypographyTests {
    private static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    private static let fontFile = repository.appendingPathComponent("Loopr/Loopr/Resources/Fonts/SpaceGrotesk/SpaceGrotesk-Light.ttf")
    /// `ttf/static/SpaceGrotesk-Light.ttf` from the Space Grotesk 2.0.0 release, as recorded in NOTICES.md.
    private static let releaseSHA256 = "48ebce72bd4fc089b7750a2a56c3424103f95c63fb4a25f39ca672bb39bb1913"

    @Test func heroNumeralsMatchTheContractSizes() {
        #expect(LooprTextStyle.heroNumerals == [.heroNumeralLarge, .heroNumeralXL, .heroNumeralXXL])
        #expect(LooprTextStyle.heroNumeralLarge.baseSize == 48)
        #expect(LooprTextStyle.heroNumeralXL.baseSize == 60)
        #expect(LooprTextStyle.heroNumeralXXL.baseSize == 76)
        for style in LooprTextStyle.heroNumerals {
            #expect((44...76).contains(style.baseSize), "\(style)")
            #expect(style.isHeroNumeral)
            // Tabular figures: `font` adds `monospacedDigit()` to every numeric style.
            #expect(style.isNumeric, "\(style)")
            #expect(abs(style.tracking + 0.05 * style.baseSize) < 0.0001, "\(style)")
            _ = style.font
        }
        #expect(LooprTextStyle.allCases.filter(\.isHeroNumeral) == LooprTextStyle.heroNumerals)
        #expect(!LooprTextStyle.hero.isHeroNumeral)
    }

    @Test func heroNumeralsScaleWithDynamicTypeUpToTheirCap() {
        #expect(LooprTextStyle.heroNumeralTextStyle == .largeTitle)
        #expect(LooprTextStyle.heroNumeralMaximumDynamicTypeSize == .accessibility1)
        let metrics = UIFontMetrics(forTextStyle: .largeTitle)
        for style in LooprTextStyle.heroNumerals {
            let atDefault = Self.size(of: style, at: .large)
            let atLarger = Self.size(of: style, at: .extraExtraExtraLarge)
            let atCap = Self.size(of: style, at: .accessibilityMedium)
            let atAX5 = metrics.scaledValue(for: style.baseSize, compatibleWith: UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge))
            #expect(abs(atDefault - style.baseSize) < 0.5, "\(style)")
            #expect(atLarger > atDefault, "\(style)")
            #expect(atCap > atLarger, "\(style)")
            // Without the cap AX5 would set the 76 pt style past 130 pt.
            #expect(atAX5 > atCap, "\(style)")
        }
    }

    @Test func heroNumeralsFitAPhoneAtTheirLargestSize() throws {
        Self.registerLightFont()
        // A 393 pt phone less the 20 pt gutters, before `minimumScaleFactor` shrinks anything.
        let width = 393 - 2 * LooprSpacing.screenGutter
        for style in LooprTextStyle.heroNumerals {
            let size = Self.size(of: style, at: .accessibilityMedium)
            let font = try #require(Self.tabularLight(size: size))
            let measured = NSAttributedString(string: "8,888", attributes: [.font: font, .kern: style.tracking]).size().width
            #expect(measured <= width, "\(style) at \(size) pt is \(measured) pt wide")
        }
        #expect(LooprTextStyle.heroNumeralMinimumScaleFactor > 0 && LooprTextStyle.heroNumeralMinimumScaleFactor < 1)
    }

    @Test func requestedFontNameIsTheBundledFilesPostScriptName() throws {
        let descriptors = try #require(CTFontManagerCreateFontDescriptorsFromURL(Self.fontFile as CFURL) as? [CTFontDescriptor])
        #expect(descriptors.count == 1)
        let descriptor = try #require(descriptors.first)
        let font = CTFontCreateWithFontDescriptor(descriptor, 60, nil)
        #expect(CTFontCopyPostScriptName(font) as String == LooprTextStyle.heroNumeralFontName)
        #expect(LooprTextStyle.heroNumeralFontName == "SpaceGrotesk-Light")
        #expect(CTFontCopyFamilyName(font) as String == "Space Grotesk")
        // OS/2 usWeightClass, a big-endian UInt16 at offset 4: 300 is Light.
        let os2 = try #require(CTFontCopyTable(font, CTFontTableTag(kCTFontTableOS2), []) as Data?)
        #expect(os2.count > 6)
        #expect(UInt16(os2[os2.startIndex + 4]) << 8 | UInt16(os2[os2.startIndex + 5]) == 300)
    }

    @Test func registeredFontResolvesByTheRequestedName() throws {
        Self.registerLightFont()
        let font = try #require(UIFont(name: LooprTextStyle.heroNumeralFontName, size: 60))
        #expect(font.fontName == LooprTextStyle.heroNumeralFontName)
    }

    @Test func lightFontSetsTabularDigitsOnlyWithTheMonospacedFeature() throws {
        Self.registerLightFont()
        let proportional = try #require(UIFont(name: LooprTextStyle.heroNumeralFontName, size: 100))
        let tabular = try #require(Self.tabularLight(size: 100))
        #expect(tabular.fontName == LooprTextStyle.heroNumeralFontName)
        func widths(_ font: UIFont) -> Set<Int> {
            Set("0123456789".map { digit in
                Int((NSAttributedString(string: String(digit), attributes: [.font: font]).size().width * 100).rounded())
            })
        }
        // Space Grotesk's default digits are proportional, which is why the style adds `monospacedDigit()`.
        #expect(widths(proportional).count > 1)
        #expect(widths(tabular).count == 1)
    }

    @Test func lightFontIsTheReleaseFileAndIsRegisteredAndCredited() throws {
        let data = try Data(contentsOf: Self.fontFile)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(digest == Self.releaseSHA256)

        let plist = try Data(contentsOf: Self.repository.appendingPathComponent("Loopr/Loopr/Info.plist"))
        let info = try #require(try PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any])
        let fonts = try #require(info["UIAppFonts"] as? [String])
        #expect(fonts.contains("SpaceGrotesk-Light.ttf"))

        let notices = try String(contentsOf: Self.repository.appendingPathComponent("NOTICES.md"), encoding: .utf8)
        #expect(notices.contains(Self.releaseSHA256))
        #expect(notices.contains("https://github.com/floriankarsten/space-grotesk/releases/tag/2.0.0"))
        let license = try String(contentsOf: Self.repository.appendingPathComponent("Loopr/Loopr/Resources/Fonts/SpaceGrotesk/SpaceGrotesk-OFL.txt"), encoding: .utf8)
        #expect(license.contains("SIL Open Font License, Version 1.1"))
    }

    // MARK: Helpers

    /// The point size SwiftUI sets for `style` at `category`, after the hero numeral cap.
    private static func size(of style: LooprTextStyle, at category: UIContentSizeCategory) -> CGFloat {
        UIFontMetrics(forTextStyle: .largeTitle)
            .scaledValue(for: style.baseSize, compatibleWith: UITraitCollection(preferredContentSizeCategory: category))
    }

    /// Space Grotesk Light with the monospaced-number feature that `monospacedDigit()` requests.
    private static func tabularLight(size: CGFloat) -> UIFont? {
        guard let base = UIFont(name: LooprTextStyle.heroNumeralFontName, size: size) else { return nil }
        let descriptor = base.fontDescriptor.addingAttributes([
            .featureSettings: [[
                UIFontDescriptor.FeatureKey.type: kNumberSpacingType,
                UIFontDescriptor.FeatureKey.selector: kMonospacedNumbersSelector
            ]]
        ])
        return UIFont(descriptor: descriptor, size: size)
    }

    /// Registers the repository's Light file for this process. A second call finds it registered.
    private static func registerLightFont() {
        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(fontFile as CFURL, .process, &error) { return }
        let code = error.map { CFErrorGetCode($0.takeRetainedValue()) }
        #expect(code == CTFontManagerError.alreadyRegistered.rawValue, "Registering \(fontFile.path) failed with \(String(describing: code))")
    }
}
