import Foundation
import Testing
@testable import DesignSystem

// One clock for every screen: a 12-hour locale gets "9:00 pm", a 24-hour locale gets "21:00", and a stored sentence is
// rewritten at display time without changing what was stored.

struct LooprClockFormatTests {
    private let twentyFour = Locale(identifier: "en_GB")
    private let twelve = Locale(identifier: "en_AU")
    private func plain(_ text: String) -> String { text.replacingOccurrences(of: "\u{202F}", with: " ") }

    @Test func aTimeFollowsTheLocalesClock() {
        #expect(LooprClockFormat.text(minuteOfDay: 21 * 60, locale: twentyFour) == "21:00")
        #expect(plain(LooprClockFormat.text(minuteOfDay: 21 * 60, locale: twelve)) == "9:00 pm")
        #expect(plain(LooprClockFormat.text(minuteOfDay: 6 * 60 + 52, locale: twelve)) == "6:52 am")
        #expect(plain(LooprClockFormat.text(minuteOfDay: 12 * 60 + 40, locale: twelve)) == "12:40 pm")
    }

    @Test func aTwentyFourHourClockKeepsItsLeadingZero() {
        #expect(LooprClockFormat.text(minuteOfDay: 7 * 60 + 5, locale: twentyFour) == "07:05")
        #expect(LooprClockFormat.text(minuteOfDay: 7 * 60 + 5, locale: Locale(identifier: "de_DE")) == "07:05")
        #expect(LooprClockFormat.text(minuteOfDay: 0, locale: twentyFour) == "00:00")
    }

    @Test func minutesPastTheDayWrapAround() {
        #expect(LooprClockFormat.text(minuteOfDay: 24 * 60 + 30, locale: twentyFour) == LooprClockFormat.text(minuteOfDay: 30, locale: twentyFour))
        #expect(LooprClockFormat.text(minuteOfDay: -30, locale: twentyFour) == "23:30")
    }

    @Test func aSentenceKeepsItsWordsAndChangesOnlyItsTimes() {
        let stored = "Kitchen closed at 20:30, bed by 23:05 and up at 6:45."
        #expect(LooprClockFormat.localizing(stored, locale: twentyFour) == "Kitchen closed at 20:30, bed by 23:05 and up at 06:45.")
        #expect(plain(LooprClockFormat.localizing(stored, locale: twelve)) == "Kitchen closed at 8:30 pm, bed by 11:05 pm and up at 6:45 am.")
    }

    @Test func thingsThatAreNotTimesStayAsTheyAre() {
        for text in ["3 of 7 nights", "Score 5:3", "Protein 82 of 150 g", "1:2:3", "version 12:345", ""] {
            #expect(LooprClockFormat.localizing(text, locale: twelve) == text, "\(text)")
        }
    }

    @Test func aSentenceLocalizedTwiceKeepsOneDayPeriod() {
        let once = LooprClockFormat.localizing("Last meal after 21:00", locale: Locale(identifier: "en_US"))
        let twice = LooprClockFormat.localizing(once, locale: Locale(identifier: "en_US"))
        #expect(plain(twice) == "Last meal after 9:00 PM")
        #expect(plain(LooprClockFormat.localizing("up at 6:45 a.m.", locale: twelve)) == "up at 6:45 a.m.")
    }
}
