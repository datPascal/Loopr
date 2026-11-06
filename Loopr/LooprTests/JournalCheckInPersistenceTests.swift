import DomainKit
import Foundation
import JournalKit
import StorageKit
import Testing
@testable import Loopr

@MainActor struct JournalCheckInPersistenceTests {
    @Test func ratingsSorenessQuestionPeriodAndNoteSurviveReopeningWithoutFillingMissingAnswers() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("journal-check-in-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try StorageDatabase(url: root.appendingPathComponent("journal.sqlite"), applicationVersion: "test")
        let habits = try SQLiteHabitRepository(database: database)
        let journal = try SQLiteJournalRepository(database: database)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let day = DayIdentity(year: 2023, month: 11, day: 14)
        let question = HabitDefinition(id: HabitID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000001211")!),
            source: .custom, name: "Feeling sick", question: "Felt sick today?", sortOrder: 0,
            createdAt: now, questionPeriod: .today)
        try await habits.saveDefinition(question)
        let service = HabitCheckInService(store: habits, dateProvider: CheckInTestClock(value: now))
        try await service.rate(.mood, value: .four, day: day, timeZoneID: "Australia/Perth")
        try await service.setSoreness([.legs], day: day, timeZoneID: "Australia/Perth")
        let note = JournalEntry(id: UUID(uuidString: "00000000-0000-0000-0000-000000001212")!, day: day.habitKey,
            tags: ["work", "knee"], note: "Left knee sore after squats.", createdAt: now)
        _ = try await journal.save(note)
        let reopened = try SQLiteHabitRepository(database: database)
        let record = try #require(try await reopened.dayRecord(for: day))
        #expect(record.wellbeing?.mood == .four)
        #expect(record.wellbeing?.soreness == [.legs])
        #expect(record.wellbeing?.energy == nil)
        #expect(record.wellbeing?.stress == nil)
        #expect(record.responses.isEmpty)
        #expect(try await reopened.definition(id: question.id)?.questionPeriod == .today)
        let reopenedJournal = try SQLiteJournalRepository(database: database)
        #expect(await reopenedJournal.entry(id: note.id) == note)
        let export = await reopenedJournal.export(includeContent: true).includingHabits(
            definitions: try await reopened.definitions(), dayRecords: try await reopened.dayRecords())
        let decoded = try JSONDecoder().decode(JournalExport.self, from: JSONEncoder().encode(export))
        #expect(decoded.entries == [note])
        #expect(decoded.habitDayRecords == [record])
        #expect(decoded.habitDefinitions == [question])
        let redacted = await reopenedJournal.export(includeContent: false).includingHabits(definitions: [question], dayRecords: [record])
        #expect(redacted.habitDayRecords.isEmpty)
        #expect(redacted.entries.first?.note == nil)
    }
}

private nonisolated struct CheckInTestClock: DateProviding {
    let value: Date
    func now() -> Date { value }
}
