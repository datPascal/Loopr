import Foundation
import Testing
@testable import CoachKit

@Suite("LV-09 note clock")
struct NoteClockTests {
    private func clock(_ minute: Int, _ locale: Locale) -> String { NoteFixtures.clock(minute, locale) }

    @Test("A 24-hour locale keeps the leading zero and a 12-hour locale writes the period")
    func leadingZero() {
        #expect(clock(7 * 60, NoteFixtures.enGB) == "07:00")
        #expect(clock(7 * 60 + 5, NoteFixtures.deDE) == "07:05")
        #expect(clock(0, NoteFixtures.enGB) == "00:00")
        #expect(clock(21 * 60 + 45, NoteFixtures.enGB) == "21:45")
        #expect(clock(7 * 60, NoteFixtures.enUS).hasPrefix("7:00"))
        #expect(clock(7 * 60, NoteFixtures.enUS).contains("AM"))
        #expect(clock(21 * 60 + 45, NoteFixtures.enUS).hasPrefix("9:45"))
    }

    @Test("Minutes outside a day wrap around the clock")
    func wraps() {
        #expect(clock(1_440 + 75, NoteFixtures.enGB) == "01:15")
        #expect(clock(-60, NoteFixtures.enGB) == "23:00")
    }

    @Test("Times inside a sentence are rewritten by the injected locale, and other digits are left alone")
    func localizesSentences() {
        let gb = NoteContext(locale: NoteFixtures.enGB, calendar: NoteFixtures.calendar)
        let us = NoteContext(locale: NoteFixtures.enUS, calendar: NoteFixtures.calendar)
        #expect(gb.localizingClock("Eating after 21:00 and 7:05") == "Eating after 21:00 and 07:05")
        #expect(us.localizingClock("Eating after 21:00").hasPrefix("Eating after 9:00"))
        #expect(gb.localizingClock("Zone 2, 45 min") == "Zone 2, 45 min")
        #expect(gb.localizingClock("9,812 steps at 25:99 or 1:2:3") == "9,812 steps at 25:99 or 1:2:3")
        #expect(gb.localizingClock("No time here") == "No time here")
    }
}
