import DomainKit
import FoodKit
import Foundation
import JournalKit
import StorageKit
import Testing
import WorkoutKit
@testable import Loopr

private typealias F = PatternsFixtures4b

/// DEC-07 line 2. Deleting a workout, a habit answer, a day or a meal hides every found pattern that used it in the
/// same save. Patterns counts again after a short wait, once for a run of deletions. Dismissals stay.
@Suite(.serialized)
struct PatternsInvalidationTests {
    private static func moved(_ pattern: FoundPattern, windowEnd: String, nights: PatternNights? = nil) -> FoundPattern {
        FoundPattern(candidateID: pattern.candidateID, habitID: pattern.habitID, title: pattern.title, predicate: pattern.predicate,
                     metric: pattern.metric, strength: pattern.strength, effect: pattern.effect, nights: nights ?? pattern.nights,
                     windowEnd: windowEnd, algorithmVersion: pattern.algorithmVersion, foundAt: pattern.foundAt)
    }

    /// A pattern found long ago, whose window cannot hold a day in October.
    private static var oldPattern: FoundPattern { moved(F.legDay, windowEnd: "2026-03-01") }

    private func wait(_ seconds: Double = 5, until condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    private func engine(store: any PatternStore, data: PatternDataBox = PatternDataBox(), delay: Duration = .seconds(60), now: Date = F.now) -> PatternsEngine {
        F.engine(store: store, data: data, now: now, recountDelay: delay)
    }

    // MARK: Hiding, in the same save

    @Test func aDeletedDayHidesThePatternsThatCountedItBeforeAnyRecount() async throws {
        let store = InMemoryPatternStore()
        let box = F.lateDinnerData()
        let engine = engine(store: store, data: box)
        try await engine.setLookForNewPatterns(true)
        try await store.replaceFoundPatterns([F.lateDinner, F.alcohol, Self.oldPattern])
        #expect(try await engine.snapshot().found.count == 3)

        await engine.sourceDataDidChange(.day("2026-10-10"))

        let found = try await engine.snapshot().found
        #expect(found.map(\.key) == [Self.oldPattern.key], "only the pattern whose window never held that day is left")
        #expect(box.foodReads == 0, "nothing was recounted yet")
    }

    @Test func aDeletedAnswerHidesOnlyThatHabitsPatterns() async throws {
        let store = InMemoryPatternStore()
        let engine = engine(store: store)
        try await store.replaceFoundPatterns([F.lateDinner, F.alcohol])
        await engine.sourceDataDidChange(.answer(habit: F.alcohol.habitID, day: "2026-10-12"))
        #expect(try await engine.snapshot().found.map(\.key) == [F.lateDinner.key])
    }

    @Test func aDeletedAnswerOutsideTheWindowHidesNothing() async throws {
        let store = InMemoryPatternStore()
        let engine = engine(store: store)
        try await store.replaceFoundPatterns([F.alcohol])
        await engine.sourceDataDidChange(.answer(habit: F.alcohol.habitID, day: "2025-01-01"))
        #expect(try await engine.snapshot().found.map(\.key) == [F.alcohol.key])
    }

    @Test func aDeletedHabitHidesItsPatterns() async throws {
        let store = InMemoryPatternStore()
        let engine = engine(store: store)
        try await store.replaceFoundPatterns([F.lateDinner, F.alcohol])
        await engine.sourceDataDidChange(.habit(F.alcohol.habitID))
        #expect(try await engine.snapshot().found.map(\.key) == [F.lateDinner.key])
    }

    @Test func aDeletionWithNoKnownDayHidesEveryFoundPattern() async throws {
        let store = InMemoryPatternStore()
        let engine = engine(store: store)
        try await store.replaceFoundPatterns([F.lateDinner, F.alcohol, Self.oldPattern])
        await engine.sourceDataDidChange(.anything)
        #expect(try await engine.snapshot().found.isEmpty)
    }

    @Test func aReviewThatMentionsAHiddenPatternGoesToo() async throws {
        let store = InMemoryPatternStore()
        let engine = engine(store: store)
        try await store.replaceFoundPatterns([F.lateDinner, F.alcohol])
        try await store.saveReview(WeeklyReview(weekStartDay: "2026-10-05", weekEndDay: "2026-10-11", text: "Late dinners.",
                                                patternKeys: [F.lateDinner.key], generatedAt: F.now))
        try await store.saveReview(WeeklyReview(weekStartDay: "2026-09-28", weekEndDay: "2026-10-04", text: "Alcohol.",
                                                patternKeys: [F.alcohol.key], generatedAt: F.now))
        await engine.sourceDataDidChange(.answer(habit: F.alcohol.habitID, day: "2026-10-01"))
        #expect(try await store.reviews().map(\.weekStartDay) == ["2026-10-05"])
    }

    // MARK: Recount after a short wait

    @Test func threeDeletionsInOneBurstCauseOneRecount() async throws {
        let store = InMemoryPatternStore()
        let box = F.lateDinnerData()
        let counter = F.lateDinnerData()
        _ = try await F.engine(data: counter).discover(force: true)
        let readsPerRun = counter.foodReads
        #expect(readsPerRun > 0)

        let engine = engine(store: store, data: box, delay: .milliseconds(250))
        try await engine.setLookForNewPatterns(true)
        await engine.sourceDataDidChange(.day("2026-10-10"))
        await engine.sourceDataDidChange(.day("2026-10-11"))
        await engine.sourceDataDidChange(.day("2026-10-12"))
        #expect(box.foodReads == 0, "the wait has not passed")

        let done = await wait { (try? await store.settings())?.lastDiscoveryDay == F.today }
        #expect(done, "the recount ran")
        try await Task.sleep(for: .milliseconds(600))
        #expect(box.foodReads == readsPerRun, "one recount for three deletions")
        #expect(try await engine.snapshot().found.contains { $0.candidateID == "food.lateMeal" }, "what still holds comes back with new counts")
        #expect(try await store.settings().needsRecompute == false)
    }

    @Test func theSevenDayWaitDoesNotApplyToARecountAfterADeletion() async throws {
        let store = InMemoryPatternStore()
        let box = F.lateDinnerData()
        let engine = engine(store: store, data: box, delay: .milliseconds(50))
        try await engine.setLookForNewPatterns(true)
        var settings = try await store.settings()
        settings.lastDiscoveryDay = "2026-10-15"
        try await store.saveSettings(settings)
        #expect(try await engine.discover() == nil, "an ordinary run would wait")

        await engine.sourceDataDidChange(.day("2026-10-10"))

        #expect(await wait { box.foodReads > 0 })
        #expect(await wait { (try? await store.settings())?.lastDiscoveryAt != nil })
    }

    @Test func withDiscoveryOffNothingIsRecounted() async throws {
        let store = InMemoryPatternStore()
        let box = F.lateDinnerData()
        let engine = engine(store: store, data: box, delay: .milliseconds(50))
        try await store.replaceFoundPatterns([F.lateDinner])
        await engine.sourceDataDidChange(.day("2026-10-10"))
        try await Task.sleep(for: .milliseconds(400))
        #expect(box.foodReads == 0)
        #expect(try await store.settings().needsRecompute == false)
        #expect(try await engine.snapshot().found.isEmpty)
    }

    // MARK: Dismissals stay

    @Test func aDismissedPatternStaysDismissedThroughADeletionAndTheRecount() async throws {
        let store = InMemoryPatternStore()
        let box = F.lateDinnerData()
        let engine = engine(store: store, data: box, delay: .milliseconds(50))
        try await engine.setLookForNewPatterns(true)
        _ = try await engine.discover(force: true)
        let late = try #require(try await engine.snapshot().found.first { $0.candidateID == "food.lateMeal" })
        try await engine.dismiss(key: late.key)

        await engine.sourceDataDidChange(.day("2026-10-01"))
        #expect(try await store.dismissedPatterns().map(\.key) == [late.key], "the dismissal survives the deletion")
        #expect(try await engine.snapshot().dismissed.isEmpty, "its old numbers are not shown")

        #expect(await wait { (try? await store.settings())?.needsRecompute == false })
        let snapshot = try await engine.snapshot()
        #expect(!snapshot.found.contains { $0.key == late.key }, "it does not come back into the list")
        #expect(snapshot.dismissed.map(\.key) == [late.key], "it is dismissed, with the numbers of the new count")
    }

    @Test func restoreNeverReturnsNumbersFromBeforeTheDeletion() async throws {
        let store = InMemoryPatternStore()
        let box = F.lateDinnerData()
        let engine = engine(store: store, data: box, delay: .milliseconds(50))
        try await engine.setLookForNewPatterns(true)
        _ = try await engine.discover(force: true)
        let late = try #require(try await engine.snapshot().found.first { $0.candidateID == "food.lateMeal" })
        // The dismissal holds counts that no discovery would produce.
        try await store.dismiss(Self.moved(late, windowEnd: late.windowEnd, nights: PatternNights(with: 99, without: 99)), at: F.now)
        try await store.replaceFoundPatterns([])

        await engine.sourceDataDidChange(.day("2026-10-01"))
        #expect(await wait { (try? await store.settings())?.needsRecompute == false })

        let restored = try await engine.restore(key: late.key)
        #expect(restored != nil && restored?.nights != PatternNights(with: 99, without: 99), "the new count is what comes back")
        #expect(restored?.nights.total ?? 0 > 0)
    }

    @Test func restoreAfterADeletionThatEndedThePatternReturnsNothing() async throws {
        let store = InMemoryPatternStore()
        let box = F.lateDinnerData()
        let engine = engine(store: store, data: box, delay: .milliseconds(50))
        try await engine.setLookForNewPatterns(true)
        _ = try await engine.discover(force: true)
        let late = try #require(try await engine.snapshot().found.first { $0.candidateID == "food.lateMeal" })
        try await engine.dismiss(key: late.key)
        box.update { $0.food = [:]; $0.outcomes = [:] }

        await engine.sourceDataDidChange(.day("2026-10-01"))
        #expect(await wait { (try? await store.settings())?.needsRecompute == false })

        #expect(try await engine.restore(key: late.key) == nil, "the old numbers do not come back")
        #expect(try await engine.snapshot().found.isEmpty)
    }

    // MARK: A quit before the recount, and a failed one

    @Test func aQuitBeforeTheRecountLeavesAFlagTheNextForegroundRunClears() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("patterns-invalidation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("products.sqlite")
        do {
            let database = try StorageDatabase(url: url)
            let store = try SQLitePatternStore(database: database)
            try await store.replaceFoundPatterns([F.lateDinner])
            var settings = try await store.settings(); settings.lookForNewPatterns = true
            try await store.saveSettings(settings)
            try await store.hideFoundPatterns(affectedBy: .day("2026-10-10"))
            #expect(try await store.foundPatterns().isEmpty)
            #expect(try await store.settings().needsRecompute)
        }
        // A new process.
        let database = try StorageDatabase(url: url)
        let store = try SQLitePatternStore(database: database)
        #expect(try await store.settings().needsRecompute, "the flag is stored")
        let box = F.lateDinnerData()
        let engine = F.engine(store: store, data: box)
        await engine.recountIfNeeded()
        #expect(box.foodReads > 0)
        #expect(try await store.settings().needsRecompute == false)
        #expect(try await engine.snapshot().found.contains { $0.candidateID == "food.lateMeal" })
    }

    @Test func aRecountThatFailsKeepsTheFlagForTheNextRun() async throws {
        let store = InMemoryPatternStore()
        let failing = FailingSourceData()
        let engine = PatternsEngine(
            store: store, provider: LooprPatternExposureProvider(data: failing, timeZone: { F.zone }, policy: F.shortPolicy),
            policy: F.shortPolicy, now: { F.now }, timeZone: { F.zone }, recountDelay: .milliseconds(30))
        try await engine.setLookForNewPatterns(true)
        try await store.replaceFoundPatterns([F.lateDinner])
        await engine.sourceDataDidChange(.day("2026-10-10"))
        #expect(await wait { failing.reads > 0 })
        try await Task.sleep(for: .milliseconds(200))
        #expect(try await store.settings().needsRecompute, "the failed look left the flag")
        #expect(try await engine.snapshot().found.isEmpty, "hidden is the safe state")
    }

    // MARK: SQLite

    private func sqlite() throws -> (database: StorageDatabase, store: SQLitePatternStore, cleanup: () -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("patterns-sqlite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = try StorageDatabase(url: root.appendingPathComponent("products.sqlite"))
        return (database, try SQLitePatternStore(database: database), { try? FileManager.default.removeItem(at: root) })
    }

    @Test func clearingDerivedDataKeepsDismissalsAndMarksTheirNumbersOutOfDate() async throws {
        let rig = try sqlite(); defer { rig.cleanup() }
        try await rig.store.replaceFoundPatterns([F.lateDinner, F.alcohol])
        try await rig.store.dismiss(F.alcohol, at: F.now)
        try await rig.store.saveReview(WeeklyReview(weekStartDay: "2026-10-05", weekEndDay: "2026-10-11", text: "x", patternKeys: [], generatedAt: F.now))

        try await rig.store.clearDerived()

        #expect(try await rig.store.foundPatterns().isEmpty)
        #expect(try await rig.store.reviews().isEmpty)
        let kept = try await rig.store.dismissedPatterns()
        #expect(kept.map(\.key) == [F.alcohol.key] && kept.first?.evidenceIsStale == true)
        #expect(try await rig.store.restore(key: F.alcohol.key) == nil, "the old numbers do not come back")
    }

    @Test func hidingInATransactionLeavesTestsAndUnaffectedPatternsAlone() async throws {
        let rig = try sqlite(); defer { rig.cleanup() }
        try await rig.store.replaceFoundPatterns([F.lateDinner, Self.oldPattern])
        let test = try PatternTest.start(candidate: .trainingDay, metric: .sleepScore, now: F.now, timeZone: F.zone)
        try await rig.store.saveTest(test)
        try await rig.store.hideFoundPatterns(affectedBy: .day("2026-10-10"))
        #expect(try await rig.store.foundPatterns().map(\.key) == [Self.oldPattern.key])
        #expect(try await rig.store.tests().map(\.id) == [test.id])
    }

    @Test func aStaleDismissalTakesTheNewNumbersWhenTheRecountFindsThePatternAgain() async throws {
        let rig = try sqlite(); defer { rig.cleanup() }
        try await rig.store.dismiss(F.lateDinner, at: F.now)
        try await rig.store.hideFoundPatterns(affectedBy: .day("2026-10-10"))
        #expect(try await rig.store.dismissedPatterns().first?.evidenceIsStale == true)
        let fresh = Self.moved(F.lateDinner, windowEnd: F.today, nights: PatternNights(with: 11, without: 36))
        try await rig.store.replaceFoundPatterns([fresh])
        let dismissed = try #require(try await rig.store.dismissedPatterns().first)
        #expect(!dismissed.evidenceIsStale && dismissed.evidence.nights == fresh.nights)
        #expect(try await rig.store.visibleFoundPatterns().isEmpty, "still dismissed")
    }

    // MARK: The real deletion paths

    @Test func deletingADayThroughTheRepositoryHidesPatternsInTheSameSave() async throws {
        let rig = try sqlite(); defer { rig.cleanup() }
        let repository = try SQLiteDataRepository(database: rig.database)
        try await rig.store.replaceFoundPatterns([F.lateDinner, Self.oldPattern])
        var settings = try await rig.store.settings(); settings.lookForNewPatterns = true
        try await rig.store.saveSettings(settings)

        try await repository.deleteDayChecked("2026-10-10")

        // No engine ran. The hiding came with the deletion.
        #expect(try await rig.store.foundPatterns().map(\.key) == [Self.oldPattern.key])
        #expect(try await rig.store.settings().needsRecompute)
    }

    @Test func deletingAWorkoutHidesPatternsThatCountedItsDay() async throws {
        let rig = try sqlite(); defer { rig.cleanup() }
        let workouts = try SQLiteWorkoutStore(database: rig.database)
        let workout = WorkoutFixtures.completedRun
        try await workouts.save(workout)
        let day = try #require(PatternDays.key(at: try #require(workout.startedAt ?? workout.createdAt), timeZoneID: TimeZone.current.identifier))
        let near = Self.moved(F.legDay, windowEnd: day)
        let far = Self.moved(F.lateDinner, windowEnd: PatternDays.add(-300, to: day) ?? "2020-01-01")
        try await rig.store.replaceFoundPatterns([near, far])

        try await workouts.removeChecked(id: workout.id)

        #expect(try await rig.store.foundPatterns().map(\.key) == [far.key])
    }

    @Test func deletingAMealOrADrinkHidesPatternsThatCountedItsDay() async throws {
        let rig = try sqlite(); defer { rig.cleanup() }
        let food = FoodStore(database: rig.database)
        let repository = AppFoodRepository(store: food, environment: .make(arguments: ["--loopr-launch-mode=populated"], environment: [:]))
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = F.zone
        let noon = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 12)))
        let meal = try food.confirm(FoodMealDraft(slot: .dinner, occurredAt: noon, timeZoneIdentifier: F.zoneID,
                                                  items: [FoodItemFixture.item(name: "Pasta", energy: 700)]), at: noon)
        let drink = try FoodDrink(kind: .alcohol, name: "Wine", occurredAt: noon, timeZoneIdentifier: F.zoneID, alcoholUnits: 1.5, confirmedAt: noon)
        try food.confirmDrink(drink)

        try await rig.store.replaceFoundPatterns([F.lateDinner, Self.oldPattern])
        try await repository.deleteMeal(id: meal.id, expectedRevision: meal.revision)
        #expect(try await rig.store.foundPatterns().map(\.key) == [Self.oldPattern.key])
        #expect(try food.meals(localDay: meal.localDay).isEmpty)

        try await rig.store.replaceFoundPatterns([F.lateDinner, Self.oldPattern])
        try await repository.deleteDrink(id: drink.id)
        #expect(try await rig.store.foundPatterns().map(\.key) == [Self.oldPattern.key])
        #expect(try food.drinks().isEmpty)
        try await repository.deleteDrink(id: drink.id)
        #expect(try await rig.store.foundPatterns().map(\.key) == [Self.oldPattern.key], "a drink that is already gone changes nothing")
    }

    @Test func clearingAHabitAnswerHidesThatHabitsPatternsAndKeepsOthers() async throws {
        let rig = try sqlite(); defer { rig.cleanup() }
        let habits = try SQLiteHabitRepository(database: rig.database)
        let day = DayIdentity(habitKey: "2026-10-12")!
        let alcohol = HabitDefinition(id: F.alcohol.habitID, source: .custom, name: "Alcohol", question: "Alcohol?", sortOrder: 0, createdAt: F.now)
        try await habits.saveDefinition(alcohol)
        try await HabitCheckInService(store: habits).answer(habitID: alcohol.id, day: day, timeZoneID: F.zoneID, answer: .yes, source: .sameDay)
        try await rig.store.replaceFoundPatterns([F.alcohol, F.lateDinner])

        try await HabitCheckInService(store: habits).clearAnswer(habitID: alcohol.id, day: day)

        #expect(try await rig.store.foundPatterns().map(\.key) == [F.lateDinner.key])
    }

    @Test func answeringAHabitDoesNotHidePatterns() async throws {
        let rig = try sqlite(); defer { rig.cleanup() }
        let habits = try SQLiteHabitRepository(database: rig.database)
        let day = DayIdentity(habitKey: "2026-10-12")!
        let alcohol = HabitDefinition(id: F.alcohol.habitID, source: .custom, name: "Alcohol", question: "Alcohol?", sortOrder: 0, createdAt: F.now)
        try await habits.saveDefinition(alcohol)
        try await rig.store.replaceFoundPatterns([F.alcohol])
        try await HabitCheckInService(store: habits).answer(habitID: alcohol.id, day: day, timeZoneID: F.zoneID, answer: .yes, source: .sameDay)
        #expect(try await rig.store.foundPatterns().map(\.key) == [F.alcohol.key])
    }

    @Test func deletingAHabitHidesItsPatterns() async throws {
        let rig = try sqlite(); defer { rig.cleanup() }
        let habits = try SQLiteHabitRepository(database: rig.database)
        let alcohol = HabitDefinition(id: F.alcohol.habitID, source: .custom, name: "Alcohol", question: "Alcohol?", sortOrder: 0, createdAt: F.now)
        try await habits.saveDefinition(alcohol)
        try await rig.store.replaceFoundPatterns([F.alcohol, F.lateDinner])
        try await habits.deleteHabit(id: alcohol.id)
        #expect(try await rig.store.foundPatterns().map(\.key) == [F.lateDinner.key])
    }

    @Test func aDeletionTellsThePatternsRuntimeAfterItCommits() async throws {
        let store = InMemoryPatternStore()
        let box = F.lateDinnerData()
        let engine = engine(store: store, data: box, delay: .milliseconds(30))
        try await engine.setLookForNewPatterns(true)
        try await store.replaceFoundPatterns([F.lateDinner])
        await MainActor.run { LooprPatternsRuntime.shared.install(engine) }
        defer { Task { @MainActor in LooprPatternsRuntime.shared.install(engine); await LooprPatternsRuntime.shared.resetAfterDeletion() } }

        PatternSourceDeletions.committed(.day("2026-10-10"))

        #expect(await wait { box.foodReads > 0 }, "the runtime asked the engine to count again")
    }
}

/// A source that reads, then fails, as a full disk or a locked database would.
private final class FailingSourceData: PatternSourceData, @unchecked Sendable {
    struct Failure: Error {}
    private let lock = NSLock()
    private var count = 0
    var reads: Int { lock.withLock { count } }
    private func fail() throws -> Never { lock.withLock { count += 1 }; throw Failure() }
    func journalDefinitions() async throws -> [HabitDefinition] { try fail() }
    func journalRecords() async throws -> [HabitDayRecord] { try fail() }
    func foodAnswers(endingOn day: String) async throws -> [FoodAssociationKind: [PatternExposureDay]] { try fail() }
    func training(from firstDay: String, to lastDay: String) async throws -> PatternTrainingInput { try fail() }
    func steps(from firstDay: String, to lastDay: String) async throws -> [String: Double] { try fail() }
    func outcomes(forRecords records: [HabitDayRecord]) async throws -> PatternOutcomeSet { try fail() }
}
