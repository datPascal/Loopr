import SwiftUI
import Testing
import UIKit
@testable import DesignSystem

/// LV-01.3: hero numbers count up as their dots land, show the exact value when the last lands, read
/// the final value to VoiceOver and never show 0 for a missing value.
@MainActor struct LooprHeroNumberTests {
    private static let english = Locale(identifier: "en_US")

    @Test func eachLandingAdvancesItsShareAndTheLastShowsTheExactValue() {
        var count = LooprCountUp(from: 1_240, to: 1_663, total: 3)
        #expect(count.value == 1_240)
        count = count.landing()
        #expect(abs(count.value - 1_381) < 0.0001)
        count = count.landing()
        #expect(abs(count.value - 1_522) < 0.0001)
        count = count.landing()
        #expect(count.value == 1_663)
        #expect(count.isComplete)
        #expect(count.landing() == count)
    }

    @Test func aCountWithNoDotsShowsTheFinalValue() {
        #expect(LooprCountUp(from: 10, to: 20, total: 0).value == 20)
        #expect(LooprCountUp(from: 10, to: 20, total: 4, landed: 9).value == 20)
        #expect(LooprCountUp(from: 20, to: 10, total: 2, landed: 1).value == 15)
    }

    @Test func shownValueFollowsTheCountUnlessMotionIsReduced() {
        let count = LooprCountUp(from: 0, to: 100, total: 4, landed: 1)
        #expect(LooprHeroNumber(100, countUp: count).shown == 25)
        #expect(LooprHeroNumber(100).shown == 100)
        DesignSystemRuntime.apply(.init(reduceMotion: true))
        defer { DesignSystemRuntime.reset() }
        #expect(LooprHeroNumber(100, countUp: count).shown == 100)
    }

    @Test func absentValueIsNeverZero() {
        let number = LooprHeroNumber(nil, unit: "ms", countUp: LooprCountUp(from: 0, to: 0, total: 3))
        #expect(number.shown == nil)
        #expect(LooprHeroNumberAbsent.defaultText == "Not measured")
        #expect(LooprHeroNumberAbsent().text == "Not measured")
        #expect(LooprHeroNumberAbsent("No reading yet").text == "No reading yet")
        #expect(!LooprHeroNumberAbsent.defaultText.contains("0"))
        #expect(!LooprHeroNumberAbsent.defaultText.contains("\u{2014}"))
    }

    @Test func numbersAreGroupedAndRoundedForTheLocale() {
        #expect(LooprHeroNumberFormat.text(8_888, locale: Self.english) == "8,888")
        #expect(LooprHeroNumberFormat.text(8_888, locale: Locale(identifier: "de_DE")) == "8.888")
        #expect(LooprHeroNumberFormat.text(38.44, fractionDigits: 1, locale: Self.english) == "38.4")
        #expect(LooprHeroNumberFormat.text(38.44, fractionDigits: 1, locale: Locale(identifier: "de_DE")) == "38,4")
        #expect(LooprHeroNumberFormat.text(61.6, locale: Self.english) == "62")
        #expect(LooprHeroNumberFormat.text(-0.2, locale: Self.english) == "0")
        #expect(LooprHeroNumberFormat.text(.nan, locale: Self.english).isEmpty)
    }

    @Test func voiceOverReadsTheFinalValueWithItsUnit() {
        #expect(LooprHeroNumberFormat.accessibilityLabel(1_663, unit: "kilocalories", locale: Self.english) == "1,663 kilocalories")
        #expect(LooprHeroNumberFormat.accessibilityLabel(62, unit: "ms", prefix: "+", locale: Self.english) == "plus 62 ms")
        #expect(LooprHeroNumberFormat.accessibilityLabel(7, unit: nil, suffix: "days", locale: Self.english) == "7 days")
        #expect(LooprHeroNumberFormat.accessibilityLabel(7, unit: "", locale: Self.english) == "7")
    }

    @Test func voiceOverIgnoresTheCountInBetween() {
        let host = UIHostingController(rootView: LooprHeroNumber(1_663, unit: "kcal", spokenUnit: "kilocalories",
                                                                 countUp: LooprCountUp(from: 1_240, to: 1_663, total: 10, landed: 3),
                                                                 locale: Self.english))
        host.view.frame = CGRect(x: 0, y: 0, width: 393, height: 200)
        host.view.layoutIfNeeded()
        let labels = Self.accessibilityLabels(in: host.view)
        #expect(!labels.contains { $0.contains("1,367") })
        #expect(LooprHeroNumberFormat.accessibilityLabel(1_663, unit: "kilocalories", locale: Self.english) == "1,663 kilocalories")
    }

    @Test func styleIsAlwaysAHeroNumeral() {
        for style in LooprTextStyle.heroNumerals {
            _ = LooprHeroNumber(48, style: style)
        }
        #expect(LooprTextStyle.heroNumeralUnit.baseSize < LooprTextStyle.heroNumeralLarge.baseSize)
        #expect(!LooprTextStyle.heroNumeralUnit.isHeroNumeral)
    }

    @Test func heroNumberRendersPresentAndAbsent() {
        for view in [AnyView(LooprHeroNumber(1_663, unit: "kcal")), AnyView(LooprHeroNumber(nil)),
                     AnyView(LooprHeroNumber(nil) { Text(verbatim: "Wear the band tonight") })] {
            let host = UIHostingController(rootView: view)
            host.view.frame = CGRect(x: 0, y: 0, width: 393, height: 160)
            host.view.layoutIfNeeded()
            #expect(host.sizeThatFits(in: CGSize(width: 393, height: 400)).height > 0)
        }
    }

    private static func accessibilityLabels(in view: UIView) -> [String] {
        var labels: [String] = []
        if let label = view.accessibilityLabel { labels.append(label) }
        for element in view.accessibilityElements ?? [] {
            if let element = element as? NSObject, let label = element.accessibilityLabel { labels.append(label) }
        }
        return labels + view.subviews.flatMap(accessibilityLabels)
    }
}
