import DomainKit
import Foundation
@testable import JournalKit
import XCTest

/// ICP R3-SEN-09: Protocol's evening sheet asks about the evening of the day it shows. An evening question reads "This
/// evening" and its answer lands on that day; the Journal's morning check-in keeps "Yesterday evening" and the day before.
@MainActor final class ProtocolEveningQuestionTests: XCTestCase {
    private let day = DayIdentity(year: 2023, month: 11, day: 14)
    private let zone = "Europe/Berlin"
    private let now = Date(timeIntervalSince1970: 1_699_987_740) // Tue 14 Nov 2023, 19:49 in Berlin

    private func model(_ store: InMemoryHabitStore) -> HabitViewModel {
        HabitViewModel(store: store, dateProvider: EveningClock(value: now),
                       timeZoneProvider: SystemTimeZoneProvider(timeZone: TimeZone(identifier: zone)!))
    }

    func testTheLabelNamesTheEveningTheAnswerIsAbout() {
        XCTAssertEqual(JournalQuestionsSection.periodTitle(.evening, eveningIsSameDay: true, isToday: true), "This evening")
        XCTAssertEqual(JournalQuestionsSection.periodTitle(.evening, eveningIsSameDay: true, isToday: false), "That evening")
        XCTAssertEqual(JournalQuestionsSection.periodTitle(.evening, eveningIsSameDay: false, isToday: true), "Yesterday evening")
        XCTAssertEqual(JournalQuestionsSection.periodTitle(.today, eveningIsSameDay: true, isToday: true), "Today")
    }

    func testASameEveningAnswerIsStoredOnTheDayItselfAndCounted() async throws {
        let late = HabitDefinition(id: HabitID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000003901")!),
            source: .custom, name: "Ate within 2 h of bed", question: "Ate late?", sortOrder: 0, createdAt: now)
        let store = InMemoryHabitStore(definitions: [late])
        let habits = model(store)
        await habits.load()
        let yesterday = DayIdentity(year: 2023, month: 11, day: 13)
        XCTAssertEqual(habits.behaviorDay(for: .evening, selectedDay: day), yesterday, "the Journal keeps the evening before")
        XCTAssertEqual(habits.behaviorDay(for: .evening, selectedDay: day, eveningIsSameDay: true), day)

        await habits.setCheckInAnswer(.yes, definition: late, selectedDay: day, eveningIsSameDay: true)
        let today = await store.dayRecord(for: day)
        let before = await store.dayRecord(for: yesterday)
        XCTAssertEqual(today?.response(for: late.id)?.answer, .yes)
        XCTAssertNil(before?.response(for: late.id), "nothing is written on Monday")
        XCTAssertEqual(habits.checkInProgress(on: day, eveningIsSameDay: true).answered, 1)
        XCTAssertEqual(habits.checkInProgress(on: day).answered, 0, "the Journal's count still reads the evening before")
    }
}

private struct EveningClock: DateProviding {
    let value: Date
    func now() -> Date { value }
}
