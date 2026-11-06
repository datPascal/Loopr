import DomainKit
import Foundation
import JournalKit
import XCTest

@MainActor final class JournalCheckInTests: XCTestCase {
    private let day = DayIdentity(year: 2026, month: 10, day: 13)
    private let zone = "Australia/Perth"
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testConcurrentRatingsAndHabitAnswerPreserveEachFieldAndMissingStress() async throws {
        let definition = HabitDefinition(id: HabitID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000001201")!),
            source: .custom, name: "Read", question: "Read?", sortOrder: 0, createdAt: now)
        let store = InMemoryHabitStore(definitions: [definition])
        let service = HabitCheckInService(store: store, dateProvider: CheckInClock(value: now))
        let testDay = day
        let testZone = zone
        async let mood: Void = service.rate(.mood, value: .four, day: testDay, timeZoneID: testZone)
        async let energy: Void = service.rate(.energy, value: .two, day: testDay, timeZoneID: testZone)
        async let answer: Void = service.answer(habitID: definition.id, day: testDay, timeZoneID: testZone, answer: .yes, source: .sameDay)
        _ = try await (mood, energy, answer)
        let record = await store.dayRecord(for: day)
        XCTAssertEqual(record?.wellbeing?.mood, .four)
        XCTAssertEqual(record?.wellbeing?.energy, .two)
        XCTAssertNil(record?.wellbeing?.stress)
        XCTAssertNil(record?.wellbeing?.soreness)
        XCTAssertEqual(record?.response(for: definition.id)?.answer, .yes)
        XCTAssertEqual(record?.createdAt, now)
        try await service.rate(.mood, value: nil, day: day, timeZoneID: zone)
        let cleared = await store.dayRecord(for: day)
        XCTAssertNil(cleared?.wellbeing?.mood)
        XCTAssertEqual(cleared?.wellbeing?.energy, .two)
        try await service.clearAnswer(habitID: definition.id, day: day)
        let unanswered = await store.dayRecord(for: day)
        XCTAssertTrue(unanswered?.responses.isEmpty == true)
        XCTAssertEqual(unanswered?.wellbeing?.energy, .two)
    }

    func testNoSorenessAndUnansweredRemainDistinctAndTimezoneMismatchDoesNotWrite() async throws {
        let store = InMemoryHabitStore()
        let service = HabitCheckInService(store: store, dateProvider: CheckInClock(value: now))
        try await service.setSoreness([], day: day, timeZoneID: zone)
        let explicitNone = await store.dayRecord(for: day)
        XCTAssertEqual(explicitNone?.wellbeing?.soreness, [])
        do {
            try await service.setSoreness([.legs], day: day, timeZoneID: "UTC")
            XCTFail("A different zone must not change an existing day")
        } catch { XCTAssertEqual(error as? HabitStoreError, .timeZoneMismatch) }
        let afterFailure = await store.dayRecord(for: day)
        XCTAssertEqual(afterFailure, explicitNone)
        try await service.setSoreness(nil, day: day, timeZoneID: zone)
        let cleared = await store.dayRecord(for: day)
        XCTAssertNil(cleared?.wellbeing?.soreness)
        XCTAssertTrue(cleared?.responses.isEmpty == true)
    }

    func testOldRecordsDecodeWithoutInventingRatingsAndInvalidRatingIsRejected() throws {
        let old = HabitDayRecord(behaviorDay: day, behaviorTimeZoneID: zone, createdAt: now)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        object.removeValue(forKey: "wellbeing")
        let decoded = try JSONDecoder().decode(HabitDayRecord.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.wellbeing)
        object["wellbeing"] = ["mood": 0]
        XCTAssertThrowsError(try JSONDecoder().decode(HabitDayRecord.self, from: JSONSerialization.data(withJSONObject: object)))
    }

    func testTwoHourQuestionDoesNotChangeLegacyThreeHourDefinition() {
        XCTAssertEqual(HabitCatalog.byID["late_meal"]?.question, "Ate a meal in the final three hours before sleep?")
        XCTAssertEqual(HabitCatalog.byID["meal_within_two_hours"]?.question, "Ate in the final two hours before sleep?")
    }

    func testQuestionPeriodAndYesterdayUseTheSelectedDay() async throws {
        let model = HabitViewModel(store: InMemoryHabitStore(), dateProvider: CheckInClock(value: now),
            timeZoneProvider: SystemTimeZoneProvider(timeZone: TimeZone(identifier: zone)!))
        XCTAssertEqual(model.behaviorDay(for: .evening, selectedDay: DayIdentity(year: 2026, month: 3, day: 1)),
                       DayIdentity(year: 2026, month: 2, day: 28))
        XCTAssertEqual(model.behaviorDay(for: .today, selectedDay: day), day)
        var definition = HabitDefinition(id: HabitID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000001202")!),
            source: .preset(catalogID: "feeling_sick"), name: "Feeling sick", question: "Sick?", sortOrder: 0, createdAt: now)
        XCTAssertEqual(definition.checkInPeriod, .today)
        definition.questionPeriod = .evening
        let decoded = try JSONDecoder().decode(HabitDefinition.self, from: JSONEncoder().encode(definition))
        XCTAssertEqual(decoded.checkInPeriod, .evening)
    }
}

private struct CheckInClock: DateProviding {
    let value: Date
    func now() -> Date { value }
}
