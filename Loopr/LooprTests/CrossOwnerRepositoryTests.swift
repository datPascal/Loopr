import DomainKit
import Foundation
import JournalKit
import SleepKit
import StorageKit
import Testing

@testable import Loopr

private func temporaryDatabase() throws -> (StorageDatabase, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    return (try StorageDatabase(url: root.appendingPathComponent("products.sqlite")), root)
}

// MARK: - Journal (features request P2)

struct PersistentJournalRepositoryTests {
    @Test
    func aProposalHasToBeReviewedBeforeItBecomesAnEntry() async throws {
        let (database, root) = try temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try SQLiteJournalRepository(database: database)
        let proposal = JournalProposal(day: "2026-09-21", tags: ["coffee"], note: "Late cup")

        await #expect(throws: JournalError.proposalNotReviewed) {
            _ = try await repository.saveProposal(proposal, accepted: true)
        }

        await repository.approve(proposal)
        let saved = try await repository.saveProposal(proposal, accepted: true)
        #expect(saved?.day == "2026-09-21")
    }

    @Test
    func aRejectedProposalStillSavesNothing() async throws {
        let (database, root) = try temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try SQLiteJournalRepository(database: database)
        let proposal = JournalProposal(day: "2026-09-21", tags: [], note: "")
        await repository.approve(proposal)
        let saved = try await repository.saveProposal(proposal, accepted: false)
        #expect(saved == nil)
    }

    @Test
    func theCheckedWipeReportsSuccessAndLeavesNoRecordedFailure() async throws {
        let (database, root) = try temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try SQLiteJournalRepository(database: database)
        _ = try await repository.create(day: "2026-09-21", note: "kept")
        try await repository.deleteAllChecked()
        #expect(await repository.history(descending: false).isEmpty)
        #expect(await repository.lastDeleteAllFailure == nil)
    }
}

// MARK: - Sleep corrections (features request A3)

struct SleepCorrectionWriterTests {
    private static let day = DayIdentity(year: 2026, month: 9, day: 7)
    private static let now = Date(timeIntervalSince1970: 1_788_760_000)

    @Test
    func theFirstNightSeenIsNotACorrection() {
        let correction = LooprDerivedDataPublisher.sleepCorrection(
            previousMinutes: nil, minutes: 462, day: Self.day,
            algorithmVersion: "sleep.v1", now: Self.now)
        #expect(correction == nil)
    }

    @Test
    func anUnchangedNightWritesNothing() {
        let correction = LooprDerivedDataPublisher.sleepCorrection(
            previousMinutes: 462, minutes: 462, day: Self.day,
            algorithmVersion: "sleep.v1", now: Self.now)
        #expect(correction == nil)
    }

    @Test
    func aChangedNightRecordsBeforeAndAfter() throws {
        let correction = try #require(LooprDerivedDataPublisher.sleepCorrection(
            previousMinutes: 462, minutes: 488, day: Self.day,
            algorithmVersion: "sleep.v1", now: Self.now))
        #expect(correction.day == Self.day)
        #expect(correction.target == "sleep.duration.minutes")
        #expect(correction.before == "462")
        #expect(correction.after == "488")
        #expect(correction.source == "derivation")
        #expect(correction.createdAt == Self.now)
    }

    @Test
    func anEntryRoundTripsThroughTheAuditRepository() async throws {
        let correction = try #require(LooprDerivedDataPublisher.sleepCorrection(
            previousMinutes: 400, minutes: 430, day: Self.day,
            algorithmVersion: "sleep.v1", now: Self.now))
        let repository = InMemorySleepCorrectionRepository()
        try await repository.append(correction)
        let history = try await repository.history(for: Self.day)
        #expect(history.map(\.after) == ["430"])
    }
}
