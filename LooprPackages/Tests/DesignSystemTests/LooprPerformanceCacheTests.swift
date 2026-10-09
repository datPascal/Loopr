import DesignSystem
import Foundation
import SwiftUI
import Testing

@Suite(.serialized)
struct LooprColorCacheTests {
    @Test
    func aTokenReturnsAnEqualColourOnEveryRead() {
        DesignSystemRuntime.reset()
        defer { DesignSystemRuntime.reset() }
        #expect(Color.loopr(.ink) == Color.loopr(.ink))
        #expect(LooprColorToken.surface.color == Color.loopr(.surface))
        #expect(Color.loopr(.ink) != Color.loopr(.background))
    }

    @Test
    func anAppearanceChangeHandsOutNewColours() {
        DesignSystemRuntime.reset()
        defer { DesignSystemRuntime.reset() }
        let before = Color.loopr(.ink)
        DesignSystemRuntime.apply(.init(appearance: .dark))
        let after = Color.loopr(.ink)
        #expect(before != after)
        #expect(after == Color.loopr(.ink))
    }

    @Test
    func aUnitChangeKeepsTheColours() {
        DesignSystemRuntime.reset()
        defer { DesignSystemRuntime.reset() }
        let before = Color.loopr(.ink)
        DesignSystemRuntime.apply(.init(measurementSystem: .imperial))
        #expect(before == Color.loopr(.ink))
    }
}

struct LooprDateFormatterCacheTests {
    @Test
    func theSameFormatAndCalendarShareOneFormatter() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Perth")!
        let first = LooprDateFormatterCache.formatter("EEE d MMM", calendar: calendar)
        let second = LooprDateFormatterCache.formatter("EEE d MMM", calendar: calendar)
        #expect(first === second)
    }

    @Test
    func aDifferentTimeZoneGetsItsOwnFormatter() {
        var perth = Calendar(identifier: .gregorian)
        perth.timeZone = TimeZone(identifier: "Australia/Perth")!
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_700_000_000) // 22:13 UTC on the 14th, 06:13 on the 15th in UTC+8
        #expect(LooprDateFormatterCache.string(from: date, format: "d", calendar: utc) == "14")
        #expect(LooprDateFormatterCache.string(from: date, format: "d", calendar: perth) == "15")
    }
}
