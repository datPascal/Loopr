import AIKit
import DesignSystem
import FoodKit
import Foundation
import JournalKit
import StorageKit
import Testing
import TrainKit
@testable import Loopr

/// An agent write is a proposal until the person confirms it. Nothing is saved before that, a second tap saves nothing more, and a
/// restart keeps both the waiting cards and the finished ones.
@Suite(.serialized)
struct AgentConfirmationTests {
    private static let templateID = UUID(uuidString: "7E1C0F52-5D6B-4B3A-9C58-2D1B6B0A1111")!
    private static func template() -> WorkoutTemplate {
        WorkoutTemplate(id: templateID, revision: 3, name: "Upper A", kind: .strength,
                        exercises: [TemplateExercise(exercise: ExerciseRef(key: "bench-press", name: "Bench press"), sets: 3, repsMin: 6, repsMax: 8, loadKg: 70, restSeconds: 120)])
    }
    private static let mealArguments: [String: Any] = ["slot": "dinner", "day": "2026-10-15", "time": "19:30", "estimate": AgentFixtures.estimate()]
    private static let allProposals: [(tool: String, arguments: [String: Any])] = [
        (AgentToolName.proposeMeal, mealArguments),
        (AgentToolName.proposeJournalQuestion, ["name": "Late screens", "question": "Did you use screens in the hour before bed?"]),
        (AgentToolName.proposeTemplateEdit, ["templateId": templateID.uuidString, "revision": 3,
                                             "changes": ["exercises": [["index": 0, "sets": 4, "loadKg": 72.5]]]]),
        (AgentToolName.proposeProgramDraft, ["program": ["schemaVersion": 1, "name": "Autumn base",
                                                        "weeks": [[["weekday": "monday", "template": "Upper A"]]]]]),
        (AgentToolName.proposeReminder, ["title": "Wind down", "body": "Screens off.", "time": "20:15"]),
        (AgentToolName.proposeTest, ["candidateId": "food.lateMeal", "metric": "sleepScore", "reminderTime": "20:00"])
    ]

    private func makeHarness() throws -> ProposalHarness {
        let writes = SpyWriteStore(); writes.stored = [Self.template()]
        return try ProposalHarness.make(writes: writes)
    }
    private let suite = AgentFixtures.Suite()
    private var gate: AgentAccessGate { AgentAccessGate(consent: AgentFixtures.everything, defaults: suite.defaults) }

    /// Runs a propose tool and returns the stored proposal's id.
    @discardableResult
    private func propose(_ harness: ProposalHarness, _ tool: String, _ arguments: [String: Any], conversationID: UUID = UUID(), messageID: UUID = UUID()) async throws -> UUID {
        let outcome = await harness.executor(gate: gate, conversationID: conversationID, messageID: messageID).execute(AgentFixtures.call(tool, arguments))
        #expect(!outcome.isError, "\(tool): \(outcome.content)")
        let json = try #require(JSONSerialization.jsonObject(with: Data(outcome.content.utf8)) as? [String: Any])
        #expect(json["status"] as? String == "awaiting_user_confirmation")
        return try #require((json["proposalId"] as? String).flatMap(UUID.init(uuidString:)))
    }

    // MARK: No write before Confirm

    @Test func proposingNeverWritesAnything() async throws {
        let harness = try makeHarness(); defer { harness.cleanup() }
        let chat = UUID(), message = UUID()
        for (tool, arguments) in Self.allProposals { try await propose(harness, tool, arguments, conversationID: chat, messageID: message) }

        #expect(harness.writes.writeCount == 0, "a proposal wrote to the stores")
        #expect(harness.writes.meals.isEmpty && harness.writes.habits.isEmpty && harness.writes.savedTemplates.isEmpty && harness.writes.programSaves.isEmpty)
        #expect(harness.reminders.scheduled.isEmpty, "a reminder was scheduled before Confirm")
        #expect(harness.tests.started.isEmpty)
        let rows = await harness.center.proposals(conversationID: chat)
        #expect(rows.count == 6)
        #expect(rows.allSatisfy { $0.state == .pending && $0.messageID == message && $0.card != nil && $0.appliedAt == nil && $0.confirmedAt == nil })
    }

    @Test func theModelCanNotReachTheApplierThroughAnyTool() async throws {
        // Every tool the registry offers, called with plausible arguments, leaves the write spies at zero.
        let harness = try makeHarness(); defer { harness.cleanup() }
        let specs = AgentToolRegistry.specs(allowed: Set(AgentDataDomain.allCases), capabilities: .init(listsPatterns: true, startsTests: true))
        let all = AgentFixtures.Suite(); all.setOnly(Set(AgentDataDomain.allCases))
        let run = harness.executor(gate: AgentAccessGate(consent: AgentFixtures.everything, defaults: all.defaults))
        for spec in specs { _ = await run.execute(AgentFixtures.call(spec.name, ["metrics": ["rmssd"], "chartId": "x", "metric": "rmssd"])) }
        for (tool, arguments) in Self.allProposals { _ = await run.execute(AgentFixtures.call(tool, arguments)) }
        #expect(harness.writes.writeCount == 0)
        #expect(harness.reminders.scheduled.isEmpty && harness.tests.started.isEmpty)
    }

    @Test func theCardNamesWhatWillHappen() async throws {
        let harness = try makeHarness(); defer { harness.cleanup() }
        let chat = UUID()
        for (tool, arguments) in Self.allProposals { try await propose(harness, tool, arguments, conversationID: chat) }
        let cards = Dictionary(uniqueKeysWithValues: await harness.center.proposals(conversationID: chat).compactMap(\.card).map { ($0.title, $0) })
        #expect(Set(cards.keys) == ["Log this meal?", "Add this question?", "Update this template?", "Save this program as a draft?", "Remind you at \(LooprClockFormat.text(minuteOfDay: 20 * 60 + 15))?", "Start this 14-day test?"])
        #expect(Set(cards.values.map(\.confirmTitle)) == ["Log meal", "Add question", "Update template", "Save draft", "Set reminder", "Start test"])
        #expect(cards.values.allSatisfy { $0.dismissTitle == "Not now" })
        let meal = try #require(cards["Log this meal?"])
        #expect(meal.lines.contains { $0.contains("640 kcal") } && meal.lines.last == AgentProposalCopy.estimatedLine)
        #expect(try #require(cards["Update this template?"]).lines.contains("Bench press: 4 sets, 72.5 kg"))
        #expect(try #require(cards["Save this program as a draft?"]).lines.contains(AgentProposalCopy.draftLine))
        #expect(AgentProposalCopy.dismissedText == "Nothing was saved.")
    }

    // MARK: Confirm

    @Test func confirmSavesOnceEvenWhenTappedManyTimesAtOnce() async throws {
        let harness = try makeHarness(); defer { harness.cleanup() }
        let id = try await propose(harness, AgentToolName.proposeMeal, Self.mealArguments)

        let results = await withTaskGroup(of: AgentConfirmResult.self) { group in
            for _ in 0..<6 { group.addTask { await harness.center.confirm(id: id, at: AgentFixtures.now) } }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(results.filter(\.applied).count == 1, "exactly one tap saves")
        #expect(harness.writes.meals.count == 1)
        let again = await harness.center.confirm(id: id)
        #expect(!again.applied && again.failure == nil)
        #expect(harness.writes.meals.count == 1)
        #expect(await harness.center.proposal(id: id)?.state == .applied)
    }

    @Test func theMealIsLoggedAsAnEstimateWithTheProposalAsItsId() async throws {
        let harness = try makeHarness(); defer { harness.cleanup() }
        let id = try await propose(harness, AgentToolName.proposeMeal, Self.mealArguments)
        _ = await harness.center.confirm(id: id, at: AgentFixtures.now)
        let draft = try #require(harness.writes.meals.first)
        #expect(draft.id == id, "the meal id is the proposal id, so a repeat finds the meal")
        #expect(draft.slot == .dinner && draft.timeZoneIdentifier == "Australia/Perth")
        #expect(try FoodMeal.day(at: draft.occurredAt, timeZoneIdentifier: "Australia/Perth") == "2026-10-15")
        let item = try #require(draft.items.first)
        #expect(item.isEstimated && item.provenance.last?.source == .agentText && item.confidence == .check)
        #expect(item.nutrients[.energy] == 640 && item.nutrients[.carbs] == nil, "unknown nutrients stay unknown, not zero")
    }

    @Test func everyKindAppliesOnConfirmAndOnlyThen() async throws {
        let harness = try makeHarness(); defer { harness.cleanup() }
        var ids: [String: UUID] = [:]
        for (tool, arguments) in Self.allProposals { ids[tool] = try await propose(harness, tool, arguments) }
        for tool in Self.allProposals.map(\.tool) { #expect(await harness.center.confirm(id: ids[tool]!, at: AgentFixtures.now).applied, "\(tool)") }

        #expect(harness.writes.meals.count == 1)
        let habit = try #require(harness.writes.habits.first)
        #expect(habit.name == "Late screens" && habit.question == "Did you use screens in the hour before bed?" && habit.id.rawValue == AgentIDs.derived(from: ids[AgentToolName.proposeJournalQuestion]!))
        let saved = try #require(harness.writes.savedTemplates.first)
        #expect(saved.exercises[0].sets == 4 && saved.exercises[0].loadKg == 72.5 && saved.name == "Upper A")
        #expect(harness.writes.programSaves == [ids[AgentToolName.proposeProgramDraft]!])
        let reminder = try #require(harness.reminders.scheduled.first)
        #expect(reminder.minute == 20 * 60 + 15 && !reminder.daily && reminder.title == "Wind down" && reminder.id == ids[AgentToolName.proposeReminder]!)
        #expect(harness.tests.started == ["food.lateMeal"])
    }

    @Test func aJournalQuestionIsNotAddedTwice() async throws {
        let harness = try makeHarness(); defer { harness.cleanup() }
        let id = try await propose(harness, AgentToolName.proposeJournalQuestion, ["name": "Late screens", "question": "Did you use screens late?"])
        _ = await harness.center.confirm(id: id)
        // The ledger lost the "applied" mark in a crash. The question exists, so applying again adds nothing.
        let second = try harness.restarted()
        #expect(await second.center.confirm(id: id).applied == false)
        #expect(harness.writes.habits.count == 1)
    }

    // MARK: Not now

    @Test func notNowSavesNothingAndABlockedConfirmFollows() async throws {
        let harness = try makeHarness(); defer { harness.cleanup() }
        let id = try await propose(harness, AgentToolName.proposeMeal, Self.mealArguments)
        let dismissed = await harness.center.dismiss(id: id)
        #expect(dismissed?.state == .dismissed)
        #expect(harness.writes.writeCount == 0)
        #expect(await harness.center.confirm(id: id).applied == false, "a dismissed card can not be confirmed by a late tap")
        #expect(harness.writes.writeCount == 0)
    }

    @Test func aConfirmedProposalCanNotBeDismissedBack() async throws {
        let harness = try makeHarness(); defer { harness.cleanup() }
        let id = try await propose(harness, AgentToolName.proposeMeal, Self.mealArguments)
        _ = await harness.center.confirm(id: id)
        let row = await harness.center.dismiss(id: id)
        #expect(row?.state == .applied)
    }

    // MARK: Restart

    @Test func cardsSurviveARestartPendingAndFinished() async throws {
        let first = try makeHarness(); defer { first.cleanup() }
        let chat = UUID(), message = UUID()
        let mealID = try await propose(first, AgentToolName.proposeMeal, Self.mealArguments, conversationID: chat, messageID: message)
        let questionID = try await propose(first, AgentToolName.proposeJournalQuestion, ["name": "Late screens", "question": "Did you use screens late?"], conversationID: chat, messageID: message)
        let reminderID = try await propose(first, AgentToolName.proposeReminder, ["title": "Wind down", "time": "20:15"], conversationID: chat, messageID: message)
        _ = await first.center.confirm(id: questionID)
        _ = await first.center.dismiss(id: reminderID)

        let second = try first.restarted()
        let rows = Dictionary(uniqueKeysWithValues: await second.center.proposals(conversationID: chat).map { ($0.id, $0) })
        #expect(rows[mealID]?.state == .pending && rows[mealID]?.card?.title == "Log this meal?" && rows[mealID]?.messageID == message)
        #expect(rows[questionID]?.state == .applied && rows[questionID]?.appliedAt != nil)
        #expect(rows[reminderID]?.state == .dismissed)
        #expect(first.writes.writeCount == 1, "restarting wrote nothing")

        // The waiting card still works after the restart, once.
        #expect(await second.center.confirm(id: mealID).applied)
        let third = try second.restarted()
        #expect(await third.center.confirm(id: mealID).applied == false)
        #expect(await third.center.confirm(id: questionID).applied == false)
        #expect(first.writes.meals.count == 1 && first.writes.habits.count == 1)
        #expect(await third.center.proposal(id: mealID)?.state == .applied)
    }

    @Test func aFailedSaveKeepsTheCardAndRetryWorksAfterARestart() async throws {
        let first = try makeHarness(); defer { first.cleanup() }
        first.writes.failMealOnce = true
        let id = try await propose(first, AgentToolName.proposeMeal, Self.mealArguments)
        let failed = await first.center.confirm(id: id)
        #expect(!failed.applied && failed.failure == "Storage is full." && failed.proposal?.state == .failed)
        #expect(first.writes.meals.isEmpty)

        let second = try first.restarted()
        #expect(await second.center.proposal(id: id)?.state == .failed)
        #expect(await second.center.confirm(id: id).applied)
        #expect(first.writes.meals.count == 1)
    }

    @Test func aCrashAfterTheWriteDoesNotLogTheMealTwice() async throws {
        let first = try makeHarness(); defer { first.cleanup() }
        let id = try await propose(first, AgentToolName.proposeMeal, Self.mealArguments)
        first.writes.existingMealIDs = [id]   // the meal was saved, then the app died before the card was marked
        #expect(await first.center.confirm(id: id).applied)
        #expect(first.writes.meals.isEmpty, "no second copy")
    }

    // MARK: Deleting a chat

    @Test func deletingAChatRemovesItsCardsAndNoOthers() async throws {
        let harness = try makeHarness(); defer { harness.cleanup() }
        let keep = UUID(), drop = UUID()
        let kept = try await propose(harness, AgentToolName.proposeMeal, Self.mealArguments, conversationID: keep)
        let dropped = try await propose(harness, AgentToolName.proposeJournalQuestion, ["name": "Late screens", "question": "Did you use screens late?"], conversationID: drop)
        await harness.center.deleteProposals(conversationID: drop)
        #expect(await harness.center.proposal(id: dropped) == nil)
        let second = try harness.restarted()
        #expect(await second.center.proposal(id: dropped) == nil)
        #expect(await second.center.proposal(id: kept)?.state == .pending)
        await second.center.deleteAll()
        #expect(await (try harness.restarted()).center.proposal(id: kept) == nil)
    }

    // MARK: Refusals

    @Test func badProposalsAreRefusedWithAReasonAndLeaveNothingBehind() async throws {
        let harness = try makeHarness(); defer { harness.cleanup() }
        let bad: [(String, [String: Any], String)] = [
            (AgentToolName.proposeMeal, ["slot": "brunch", "estimate": AgentFixtures.estimate()], "slot must be"),
            (AgentToolName.proposeMeal, ["slot": "dinner", "day": "2026-10-16", "time": "19:30", "estimate": AgentFixtures.estimate()], "in the future"),
            (AgentToolName.proposeMeal, ["slot": "dinner", "day": "2026-09-01", "estimate": AgentFixtures.estimate()], "up to 30 days back"),
            (AgentToolName.proposeMeal, ["slot": "dinner", "day": "2026-10-15", "estimate": ["items": [], "uncertainty": "x"]], "no items"),
            (AgentToolName.proposeMeal, ["slot": "dinner", "day": "2026-10-15", "estimate": ["items": [["name": "Toast"]], "uncertainty": "x"]], "does not match the schema"),
            (AgentToolName.proposeJournalQuestion, ["name": "Screens", "question": "Screens late"], "question mark"),
            (AgentToolName.proposeReminder, ["title": "Wind down", "time": "8pm"], "HH:mm"),
            (AgentToolName.proposeTemplateEdit, ["templateId": Self.templateID.uuidString, "revision": 2, "changes": ["name": "Upper B"]], "revision 3"),
            (AgentToolName.proposeTemplateEdit, ["templateId": Self.templateID.uuidString, "revision": 3, "changes": ["exercises": [["index": 9, "sets": 4]]]], "not in this template"),
            (AgentToolName.proposeTemplateEdit, ["templateId": Self.templateID.uuidString, "revision": 3, "changes": ["exercises": [["index": 0, "sets": 99]]]], "outside what a template can hold"),
            (AgentToolName.proposeTemplateEdit, ["templateId": UUID().uuidString, "revision": 1, "changes": ["name": "X"]], "No saved template"),
            (AgentToolName.proposeProgramDraft, ["program": ["schemaVersion": 1, "name": "X", "weeks": [[["weekday": "monday", "template": "Nope"]]]]], "no template named"),
            (AgentToolName.proposeTest, ["candidateId": "steps.unknown"], "cannot be tested")
        ]
        for (tool, arguments, expected) in bad {
            let outcome = await harness.executor(gate: gate).execute(AgentFixtures.call(tool, arguments))
            #expect(outcome.isError && !outcome.denied && outcome.content.contains(expected), "\(tool): \(outcome.content)")
        }
        #expect(harness.writes.writeCount == 0)
        #expect(await harness.center.ledger.proposals(conversationID: UUID()).isEmpty)
        #expect((try harness.restarted().database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM loopr_product_document WHERE namespace = 'agent'") }) == 0)
    }

    @Test func proposalToolsWorkWhileEveryReadDomainIsOff() async throws {
        // Switches govern reads. A write the person confirms is theirs.
        let off = AgentFixtures.Suite(); off.setOnly([])
        let harness = try makeHarness(); defer { harness.cleanup() }
        let run = harness.executor(gate: AgentAccessGate(consent: AgentFixtures.everything, defaults: off.defaults))
        let outcome = await run.execute(AgentFixtures.call(AgentToolName.proposeMeal, Self.mealArguments))
        #expect(!outcome.isError && !outcome.denied)
    }

    // MARK: Real food store

    private struct FoodBackedWrites: AgentWriteStore {
        let store: FoodStore
        func mealExists(id: UUID) async throws -> Bool { try store.meal(id: id) != nil }
        func confirmMeal(_ draft: FoodMealDraft, at date: Date) async throws { try store.confirm(draft, at: date) }
        func habitDefinitions() async throws -> [HabitDefinition] { [] }
        func saveHabitDefinition(_ definition: HabitDefinition) async throws {}
        func template(id: UUID) async throws -> WorkoutTemplate? { nil }
        func saveTemplate(_ template: WorkoutTemplate, at date: Date) async throws {}
        func checkProgramDraft(json: String, defaultStartDay: String) async throws {}
        func saveProgramDraft(json: String, defaultStartDay: String, proposalID: UUID, at date: Date) async throws {}
    }

    @Test func aConfirmedMealLandsInTheFoodStoreAsAnEstimateOnce() async throws {
        let (database, root) = try AgentFixtures.temporaryDatabase(); defer { try? FileManager.default.removeItem(at: root) }
        let food = FoodStore(database: database)
        let writes = FoodBackedWrites(store: food)
        let applier = AgentProposalApplier(writes: writes, reminders: SpyReminders(), now: { AgentFixtures.now }, timeZone: { AgentFixtures.zone })
        let center = AgentProposalCenter(ledger: AIProposalLedger(persistence: try StorageDocumentProposalPersistence(database: database)), applier: applier)
        let maker = AgentProposalMaker(writes: writes, tests: nil, provider: .anthropic, model: "claude-haiku-5-5", now: AgentFixtures.now, timeZone: AgentFixtures.zone)
        let made = try await maker.make(tool: AgentToolName.proposeMeal, args: Self.mealArguments)
        let id = UUID()
        try await center.create(StoredAIProposal(id: id, conversationID: UUID(), proposal: made.proposal, card: made.card, createdAt: AgentFixtures.now))

        #expect(try food.meals().isEmpty, "nothing in the food log before Confirm")
        #expect(await center.confirm(id: id, at: AgentFixtures.now).applied)
        #expect(await center.confirm(id: id, at: AgentFixtures.now).applied == false)
        let meals = try food.meals(localDay: "2026-10-15")
        #expect(meals.count == 1)
        let meal = try #require(meals.first)
        #expect(meal.id == id && meal.slot == .dinner && meal.items.count == 1)
        #expect(meal.items[0].isEstimated && meal.items[0].provenance.last?.source == .agentText)
        #expect(meal.items[0].nutrients[.energy] == 640 && meal.items[0].nutrients[.fat] == nil)
        #expect(meal.photos.isEmpty)
    }

    @Test func foodProvenanceFromTheAgentRoundTripsAndOldProvenanceStillDecodes() throws {
        let agent = FoodProvenance(source: .agentText, recordedAt: AgentFixtures.now, provider: "anthropic", model: "m", confidence: .guess)
        try agent.validate()
        let decoded = try JSONDecoder().decode(FoodProvenance.self, from: JSONEncoder().encode(agent))
        #expect(decoded == agent)
        let withoutProvider = FoodProvenance(source: .agentText, recordedAt: AgentFixtures.now)
        #expect(throws: FoodError.self) { try withoutProvider.validate() }
        let old = Data(#"{"source":"typed","recordedAt":800000000}"#.utf8)
        #expect(try JSONDecoder().decode(FoodProvenance.self, from: old).source == .typed)
    }
}
