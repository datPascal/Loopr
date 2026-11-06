import DomainKit
import Foundation
import JournalKit
import XCTest

@MainActor final class JournalAutoFillTests: XCTestCase {
    private let day = DayIdentity(year: 2023, month: 11, day: 14)
    private let zone = "Australia/Perth"
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testMissingSourcesNeverInventNoAndFailedReadsKeepAnswers() async throws {
        let snapshot = try JournalAutoFillProjection.snapshot(day: day, timeZoneID: zone,
            food: .init(records: []), training: [])
        XCTAssertEqual(snapshot.resolvedQuestions, Set(JournalAutoFillQuestion.allCases))
        XCTAssertTrue(snapshot.answers.isEmpty)
        let definition = definition(.trainedToday)
        let store = InMemoryHabitStore(definitions: [definition])
        let service = JournalAutoFillService(store: store, clock: AutoFillClock(value: now))
        try await service.reconcile(trainingSnapshot())
        let before = await store.dayRecord(for: day)
        let model = HabitViewModel(store: store, dateProvider: AutoFillClock(value: now),
            timeZoneProvider: SystemTimeZoneProvider(timeZone: TimeZone(identifier: zone)!), autoFill: FailingAutoFill())
        await model.refreshAutoFill(on: day)
        let after = await store.dayRecord(for: day)
        XCTAssertEqual(after, before)
        XCTAssertNotNil(model.errorMessage)
    }

    func testFoodUsesLocalTimeTwoHourWindowAndSleepProvenance() throws {
        let coffee = intake("coffee", hour: 14, caffeine: 80)
        let dinner = intake("dinner", hour: 21, alcohol: 1, meal: true)
        let sleep = source("sleep", domain: .sleep, hour: 23)
        let snapshot = try JournalAutoFillProjection.snapshot(day: day, timeZoneID: zone,
            food: .init(records: [coffee, dinner], bedtime: sleep))
        XCTAssertEqual(snapshot.answers[.lateCaffeine]?.answer, .yes)
        XCTAssertEqual(snapshot.answers[.alcohol]?.answer, .yes)
        XCTAssertEqual(snapshot.answers[.lateMeal]?.answer, .yes)
        XCTAssertEqual(Set(snapshot.answers[.lateMeal]!.provenance.records.map(\.domain)), [.food, .sleep])
        let early = try JournalAutoFillProjection.snapshot(day: day, timeZoneID: zone,
            food: .init(records: [intake("early", hour: 13, caffeine: 80), intake("meal", hour: 20, meal: true)], bedtime: sleep))
        XCTAssertNil(early.answers[.lateCaffeine])
        XCTAssertNil(early.answers[.lateMeal])
    }

    func testNoRequiresCompletedLogAndUnknownNutrientsStayUnknown() throws {
        let completion = source("complete", domain: .food, hour: 23)
        let snapshot = try JournalAutoFillProjection.snapshot(day: day, timeZoneID: zone,
            food: .init(records: [intake("water", hour: 18)], completion: completion, bedtime: source("sleep", domain: .sleep, hour: 23)))
        XCTAssertEqual(snapshot.answers[.alcohol]?.answer, .no)
        XCTAssertEqual(snapshot.answers[.lateCaffeine]?.answer, .no)
        XCTAssertEqual(snapshot.answers[.lateMeal]?.answer, .no)
        let unknown = JournalIntakeRecord(source: source("unknown", domain: .food, hour: 18), alcoholUnits: nil,
            caffeineMilligrams: nil, isMeal: true)
        let partial = try JournalAutoFillProjection.snapshot(day: day, timeZoneID: zone,
            food: .init(records: [unknown], completion: completion))
        XCTAssertNil(partial.answers[.alcohol])
        XCTAssertNil(partial.answers[.lateCaffeine])
        XCTAssertNil(partial.answers[.lateMeal])
    }

    func testFillSourceChangesAndRemovalPreserveRatingsAndOtherSources() async throws {
        let train = definition(.trainedToday), alcohol = definition(.alcohol, id: 2)
        let store = InMemoryHabitStore(definitions: [train, alcohol])
        let checkIn = HabitCheckInService(store: store, dateProvider: AutoFillClock(value: now))
        try await checkIn.rate(.mood, value: .four, day: day, timeZoneID: zone)
        let service = JournalAutoFillService(store: store, clock: AutoFillClock(value: now))
        let full = try JournalAutoFillProjection.snapshot(day: day, timeZoneID: zone,
            food: .init(records: [intake("wine", hour: 21, alcohol: 1)]), training: [source("run", domain: .train, hour: 18)])
        try await service.reconcile(full)
        let first = await store.dayRecord(for: day)
        XCTAssertEqual(first?.response(for: train.id)?.answer, .yes)
        XCTAssertEqual(first?.response(for: alcohol.id)?.answer, .yes)
        try await service.reconcile(full)
        let unchanged = await store.dayRecord(for: day)
        XCTAssertEqual(unchanged, first)
        try await service.reconcile(trainingSnapshot(id: "changed"))
        let changed = await store.dayRecord(for: day)
        XCTAssertEqual(changed?.response(for: train.id)?.autoFillProvenance?.records.first?.id, "changed")
        try await service.reconcile(.init(day: day, timeZoneID: zone, resolvedQuestions: [.trainedToday], answers: [:]))
        let removed = await store.dayRecord(for: day)
        XCTAssertNil(removed?.response(for: train.id))
        XCTAssertEqual(removed?.response(for: alcohol.id)?.answer, .yes)
        XCTAssertEqual(removed?.wellbeing?.mood, .four)
    }

    func testManualAnswerAndExplicitClearingSurviveRoundTripAndSourceRemoval() async throws {
        let question = definition(.trainedToday)
        let store = InMemoryHabitStore(definitions: [question])
        let clock = AutoFillClock(value: now)
        let auto = JournalAutoFillService(store: store, clock: clock)
        let manual = HabitCheckInService(store: store, dateProvider: clock)
        try await auto.reconcile(trainingSnapshot())
        try await manual.answer(habitID: question.id, day: day, timeZoneID: zone, answer: .no, source: .sameDay)
        try await auto.reconcile(trainingSnapshot(id: "new-source"))
        let answered = await store.dayRecord(for: day)
        XCTAssertEqual(answered?.response(for: question.id)?.answer, .no)
        XCTAssertNil(answered?.response(for: question.id)?.autoFillProvenance)
        try await manual.clearAnswer(habitID: question.id, day: day)
        let storedRecord = await store.dayRecord(for: day)
        let stored = try XCTUnwrap(storedRecord)
        let restored = try JSONDecoder().decode(HabitDayRecord.self, from: JSONEncoder().encode(stored))
        let reopened = InMemoryHabitStore(definitions: [question], dayRecords: [restored])
        let reopenedAuto = JournalAutoFillService(store: reopened, clock: clock)
        try await reopenedAuto.reconcile(trainingSnapshot())
        try await reopenedAuto.reconcile(.init(day: day, timeZoneID: zone, resolvedQuestions: [.trainedToday], answers: [:]))
        let cleared = await reopened.dayRecord(for: day)
        XCTAssertNil(cleared?.response(for: question.id))
        XCTAssertTrue(cleared?.hasUserOverride(for: question.id) == true)
        try await reopened.deleteHabit(id: question.id)
        let deleted = await reopened.dayRecord(for: day)
        XCTAssertTrue(deleted?.userOverrideHabitIDs?.isEmpty == true)
    }

    func testLegacyManualAnswerWithoutOverrideFieldStillWins() async throws {
        let question = definition(.trainedToday)
        let response = HabitResponse(habitID: question.id, behaviorDay: day, behaviorTimeZoneID: zone,
            answer: .no, firstAnsweredAt: now, firstAnswerSource: .historyEdit)
        let store = InMemoryHabitStore(definitions: [question], dayRecords: [.init(behaviorDay: day,
            behaviorTimeZoneID: zone, responses: [response], createdAt: now)])
        try await JournalAutoFillService(store: store).reconcile(trainingSnapshot())
        let record = await store.dayRecord(for: day)
        XCTAssertEqual(record?.responses, [response])
    }

    func testEditedQuestionCannotBeAnsweredWithTheOldMeaningAndArchivedSourcesWithdraw() async throws {
        var question = definition(.trainedToday)
        let store = InMemoryHabitStore(definitions: [question])
        let service = JournalAutoFillService(store: store, clock: AutoFillClock(value: now))
        try await service.reconcile(trainingSnapshot())
        question.question = "Planned training today?"
        try await store.saveDefinition(question)
        try await service.reconcile(trainingSnapshot())
        let edited = await store.dayRecord(for: day)
        XCTAssertNil(edited?.response(for: question.id))
        question.question = HabitCatalog.byID["trained_today"]!.question
        try await store.saveDefinition(question)
        try await service.reconcile(trainingSnapshot())
        try await store.setArchived(true, habitID: question.id, at: now)
        try await service.reconcile(.init(day: day, timeZoneID: zone, resolvedQuestions: [.trainedToday], answers: [:]))
        let archived = await store.dayRecord(for: day)
        XCTAssertNil(archived?.response(for: question.id))
    }

    func testConcurrentManualAnswerAlwaysOverridesSourceRefresh() async throws {
        let question = definition(.trainedToday)
        let store = InMemoryHabitStore(definitions: [question])
        let clock = AutoFillClock(value: now), selectedDay = day, selectedZone = zone
        let snapshot = try trainingSnapshot()
        async let auto: Void = JournalAutoFillService(store: store, clock: clock).reconcile(snapshot)
        async let manual: Void = HabitCheckInService(store: store, dateProvider: clock).answer(
            habitID: question.id, day: selectedDay, timeZoneID: selectedZone, answer: .no, source: .sameDay)
        _ = try await (auto, manual)
        let record = await store.dayRecord(for: day)
        XCTAssertEqual(record?.response(for: question.id)?.answer, .no)
        XCTAssertTrue(record?.hasUserOverride(for: question.id) == true)
    }

    func testMalformedEvidenceAndTimezoneMismatchLeaveTheRecordUntouched() async throws {
        let question = definition(.trainedToday)
        let store = InMemoryHabitStore(definitions: [question])
        let service = JournalAutoFillService(store: store, clock: AutoFillClock(value: now))
        try await service.reconcile(trainingSnapshot())
        let original = await store.dayRecord(for: day)
        do {
            try await service.reconcile(.init(day: day, timeZoneID: "UTC", resolvedQuestions: [.trainedToday], answers: [:]))
            XCTFail("Mismatched zones must fail")
        } catch { XCTAssertEqual(error as? HabitStoreError, .timeZoneMismatch) }
        let bad = JournalAutoFillAnswer(.yes, provenance: .init(question: .trainedToday, records: [], summary: "Run"))
        do {
            try await service.reconcile(.init(day: day, timeZoneID: zone, resolvedQuestions: [.trainedToday], answers: [.trainedToday: bad]))
            XCTFail("Missing provenance must fail")
        } catch { XCTAssertEqual(error as? JournalAutoFillError, .invalidEvidence) }
        let after = await store.dayRecord(for: day)
        XCTAssertEqual(after, original)
    }

    func testOlderRefreshCannotRemoveNewerAnswers() async throws {
        let question = definition(.trainedToday)
        let store = InMemoryHabitStore(definitions: [question])
        let provider = PausedAutoFill(firstHasAnswer: false)
        let model = HabitViewModel(store: store, dateProvider: AutoFillClock(value: now),
            timeZoneProvider: SystemTimeZoneProvider(timeZone: TimeZone(identifier: zone)!), autoFill: provider)
        let selectedDay = day
        let older = Task { await model.refreshAutoFill(on: selectedDay) }
        await provider.waitUntilPaused()
        await model.refreshAutoFill(on: day)
        await provider.release()
        await older.value
        let yesterday = model.behaviorDay(for: .evening, selectedDay: day)
        let record = await store.dayRecord(for: yesterday)
        XCTAssertEqual(record?.response(for: question.id)?.answer, .yes)
    }

    func testCancelledRefreshCannotWriteAfterItsSourceReturns() async throws {
        let question = definition(.trainedToday)
        let store = InMemoryHabitStore(definitions: [question])
        let provider = PausedAutoFill(firstHasAnswer: true)
        let model = HabitViewModel(store: store, dateProvider: AutoFillClock(value: now),
            timeZoneProvider: SystemTimeZoneProvider(timeZone: TimeZone(identifier: zone)!), autoFill: provider)
        let selectedDay = day
        let task = Task { await model.refreshAutoFill(on: selectedDay) }
        await provider.waitUntilPaused()
        task.cancel()
        await provider.release()
        await task.value
        let records = await store.dayRecords()
        XCTAssertTrue(records.isEmpty)
        XCTAssertNil(model.errorMessage)
    }

    func testDayBoundaryUsesLocalCalendarAcrossDSTAndMealsCanCrossMidnight() throws {
        let dstDay = DayIdentity(year: 2026, month: 10, day: 4)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Sydney")!
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 4))!
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        XCTAssertEqual(end.timeIntervalSince(start), 23 * 3600)
        let included = JournalSourceRecord(id: "late", domain: .train, title: "Late session", occurredAt: end.addingTimeInterval(-1), updatedAt: now)
        let excluded = JournalSourceRecord(id: "next", domain: .train, title: "Next day", occurredAt: end, updatedAt: now)
        let snapshot = try JournalAutoFillProjection.snapshot(day: dstDay, timeZoneID: "Australia/Sydney", training: [included, excluded])
        XCTAssertEqual(snapshot.answers[.trainedToday]?.provenance.records.map(\.id), ["late"])
        let midnightMeal = JournalIntakeRecord(source: .init(id: "meal", domain: .food, title: "Meal",
            occurredAt: end.addingTimeInterval(15 * 60), updatedAt: now), alcoholUnits: 0, caffeineMilligrams: 0, isMeal: true)
        let sleep = JournalSourceRecord(id: "sleep", domain: .sleep, title: "Main sleep", occurredAt: end.addingTimeInterval(60 * 60), updatedAt: now)
        let overnight = try JournalAutoFillProjection.snapshot(day: dstDay, timeZoneID: "Australia/Sydney", food: .init(records: [midnightMeal], bedtime: sleep))
        XCTAssertEqual(overnight.answers[.lateMeal]?.answer, .yes)
    }

    private func definition(_ question: JournalAutoFillQuestion, id: Int = 1) -> HabitDefinition {
        let item = HabitCatalog.byID[question.rawValue]!
        return .init(id: HabitID(rawValue: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", id))!),
            source: .preset(catalogID: item.id), name: item.name, question: item.question, sortOrder: id, createdAt: now)
    }

    private func source(_ id: String, domain: JournalAutoFillDomain, hour: Int) -> JournalSourceRecord {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        let time = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: hour))!
        return .init(id: id, domain: domain, title: id.capitalized, occurredAt: time, updatedAt: now)
    }

    private func intake(_ id: String, hour: Int, alcohol: Double? = 0, caffeine: Double? = 0, meal: Bool = false) -> JournalIntakeRecord {
        .init(source: source(id, domain: .food, hour: hour), alcoholUnits: alcohol, caffeineMilligrams: caffeine, isMeal: meal)
    }

    private func trainingSnapshot(id: String = "run") throws -> JournalAutoFillSnapshot {
        try JournalAutoFillProjection.snapshot(day: day, timeZoneID: zone, training: [source(id, domain: .train, hour: 18)])
    }
}

private struct AutoFillClock: DateProviding {
    let value: Date
    func now() -> Date { value }
}

private struct FailingAutoFill: JournalAutoFillProviding {
    func snapshot(for day: DayIdentity, timeZoneID: String) async throws -> JournalAutoFillSnapshot {
        throw JournalAutoFillError.invalidEvidence
    }
}

private actor PausedAutoFill: JournalAutoFillProviding {
    let firstHasAnswer: Bool
    private var calls = 0
    private var paused = false
    private var pending: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    init(firstHasAnswer: Bool) { self.firstHasAnswer = firstHasAnswer }

    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() { pending?.resume(); pending = nil }

    func snapshot(for day: DayIdentity, timeZoneID: String) async throws -> JournalAutoFillSnapshot {
        calls += 1
        let first = calls == 1
        if first {
            await withCheckedContinuation { pending = $0; paused = true; observer?.resume(); observer = nil }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneID)!
        let date = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12))!
        let source = JournalSourceRecord(id: day.habitKey, domain: .train, title: "Training", occurredAt: date, updatedAt: date)
        return try JournalAutoFillProjection.snapshot(day: day, timeZoneID: timeZoneID,
            training: !first || firstHasAnswer ? [source] : [])
    }
}
