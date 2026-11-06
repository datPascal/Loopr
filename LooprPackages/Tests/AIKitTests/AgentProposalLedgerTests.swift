import AIKit
import Foundation
import Testing

private actor CountingApplier: AIProposalApplier {
    private(set) var applied: [(proposal: AIProposal, id: UUID?)] = []
    private let failFirst: Bool
    private var failed = false
    private let pause: Duration?
    init(failFirst: Bool = false, pause: Duration? = nil) { self.failFirst = failFirst; self.pause = pause }
    func apply(_ proposal: AIProposal) async throws { try await apply(proposal, id: UUID()) }
    func apply(_ proposal: AIProposal, id: UUID) async throws {
        if let pause { try? await Task.sleep(for: pause) }
        if failFirst && !failed { failed = true; throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Disk is full."]) }
        applied.append((proposal, id))
    }
    var count: Int { applied.count }
}

private final class MemoryPersistence: AIProposalPersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [UUID: StoredAIProposal] = [:]
    var saves = 0
    func load() throws -> [StoredAIProposal] { lock.withLock { Array(rows.values) } }
    func save(_ row: StoredAIProposal) throws { lock.withLock { rows[row.id] = row; saves += 1 } }
    func remove(ids: [UUID]) throws { lock.withLock { for id in ids { rows[id] = nil } } }
    func removeAll() throws { lock.withLock { rows = [:] } }
}

@Suite(.serialized) struct AgentProposalLedgerTests {
    private func row(_ proposal: AIProposal = .journalQuestion(name: "Screens", question: "Screens late?"), conversation: UUID = UUID()) -> StoredAIProposal {
        StoredAIProposal(id: UUID(), conversationID: conversation, proposal: proposal, messageID: UUID(),
                         card: AIProposalCard(title: "Add this question?", lines: ["Screens"], confirmTitle: "Add question", doneText: "Question added."),
                         createdAt: Date(timeIntervalSince1970: 1_790_000_000))
    }

    @Test func manyTapsAtOnceApplyExactlyOnce() async throws {
        let ledger = AIProposalLedger(persistence: MemoryPersistence())
        let applier = CountingApplier(pause: .milliseconds(80))
        let item = row()
        try await ledger.create(item)
        let results = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 { group.addTask { (try? await ledger.confirmAndApply(id: item.id, at: Date(), using: applier)) ?? false } }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(results.filter { $0 }.count == 1)
        #expect(await applier.count == 1)
        #expect(await ledger.proposal(id: item.id)?.state == .applied)
        #expect(await applier.applied.first?.id == item.id, "the applier is told the proposal id")
    }

    @Test func aFailedApplyKeepsTheProposalConfirmable() async throws {
        let ledger = AIProposalLedger(persistence: MemoryPersistence())
        let applier = CountingApplier(failFirst: true)
        let item = row()
        try await ledger.create(item)
        await #expect(throws: (any Error).self) { try await ledger.confirmAndApply(id: item.id, at: Date(), using: applier) }
        let failed = try #require(await ledger.proposal(id: item.id))
        #expect(failed.state == .failed && failed.failure == "Disk is full." && failed.appliedAt == nil && failed.confirmedAt != nil)
        #expect(try await ledger.confirmAndApply(id: item.id, at: Date(), using: applier))
        let done = await ledger.proposal(id: item.id)
        #expect(done?.state == .applied && done?.failure == nil)
        #expect(await applier.count == 1)
    }

    @Test func dismissedAndAppliedProposalsAreFinal() async throws {
        let ledger = AIProposalLedger(persistence: MemoryPersistence())
        let applier = CountingApplier()
        let dismissed = row(), applied = row()
        try await ledger.create(dismissed); try await ledger.create(applied)
        #expect(await ledger.dismiss(id: dismissed.id, at: Date()))
        #expect(try await ledger.confirmAndApply(id: dismissed.id, at: Date(), using: applier) == false)
        #expect(try await ledger.confirmAndApply(id: applied.id, at: Date(), using: applier))
        #expect(await ledger.dismiss(id: applied.id, at: Date()) == false)
        #expect(await applier.count == 1)
    }

    @Test func rowsReloadFromPersistenceAndDeleteWithTheirChat() async throws {
        let store = MemoryPersistence()
        let chat = UUID()
        let first = AIProposalLedger(persistence: store)
        let kept = row(conversation: UUID()), dropped = row(conversation: chat)
        try await first.create(kept); try await first.create(dropped)
        let second = AIProposalLedger(persistence: store)
        #expect(await second.proposal(id: dropped.id)?.card?.title == "Add this question?")
        #expect(await second.proposals(conversationID: chat).map(\.id) == [dropped.id])
        await second.delete(conversationID: chat)
        let third = AIProposalLedger(persistence: store)
        let droppedRow = await third.proposal(id: dropped.id), keptRow = await third.proposal(id: kept.id)
        #expect(droppedRow == nil && keptRow != nil)
        await third.deleteAll()
        #expect(await AIProposalLedger(persistence: store).proposal(id: kept.id) == nil)
    }

    @Test func createDoesNotOverwriteAnExistingProposal() async throws {
        let ledger = AIProposalLedger(persistence: MemoryPersistence())
        let item = row()
        try await ledger.create(item)
        _ = try await ledger.confirmAndApply(id: item.id, at: Date(), using: CountingApplier())
        var again = item; again.appliedAt = nil
        try await ledger.create(again)
        #expect(await ledger.proposal(id: item.id)?.state == .applied)
    }

    @Test func everyProposalKindEncodesAndDecodes() throws {
        let kinds: [AIProposal] = [
            .journal(text: "n", tags: ["t"]), .goalAdjustment(goalID: UUID(), value: 3),
            .meal(estimateJSON: "{}", slot: "dinner", occurredAt: Date(timeIntervalSince1970: 1_790_000_000), timeZoneID: "Australia/Perth", provider: "anthropic", model: "m"),
            .journalQuestion(name: "a", question: "b?"), .templateEdit(templateID: UUID(), expectedRevision: 3, editJSON: "{}"),
            .programDraft(json: "{}"), .reminder(title: "t", body: "b", minuteOfDay: 1_215, repeatsDaily: true),
            .test(candidateID: "food.lateMeal", metric: "sleepScore", reminderMinuteOfDay: nil)
        ]
        for kind in kinds {
            let stored = StoredAIProposal(id: UUID(), conversationID: UUID(), proposal: kind)
            let again = try JSONDecoder().decode(StoredAIProposal.self, from: JSONEncoder().encode(stored))
            #expect(again == stored)
        }
    }

    @Test func aProposalSavedByTheOlderLedgerStillDecodes() throws {
        let id = UUID(), chat = UUID()
        let old = #"{"id":"\#(id)","conversationID":"\#(chat)","proposal":{"journal":{"text":"note","tags":["tag"]}},"confirmedAt":800000000}"#
        let row = try JSONDecoder().decode(StoredAIProposal.self, from: Data(old.utf8))
        #expect(row.id == id && row.conversationID == chat && row.messageID == nil && row.card == nil && row.dismissedAt == nil)
        #expect(row.state == .pending && row.confirmedAt != nil)
    }

    @Test func theFileLedgerKeepsWorkingForExistingCallers() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "proposals-\(UUID().uuidString)/proposals.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = row()
        await AIProposalLedger(persistenceURL: url).store(item)
        let applier = CountingApplier()
        let restored = AIProposalLedger(persistenceURL: url)
        #expect(try await restored.confirmAndApply(id: item.id, at: Date(), using: applier))
        #expect(try await AIProposalLedger(persistenceURL: url).confirmAndApply(id: item.id, at: Date(), using: applier) == false)
        #expect(await applier.count == 1)
    }
}
