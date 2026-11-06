import DomainKit
import JournalKit

nonisolated struct AppJournalInsightPreparation: Sendable {
    let store: any HabitStore
    let resolver: AppHabitOutcomeResolver

    func refresh() async throws {
        let records = try await store.dayRecords()
        for record in records {
            try Task.checkCancellation()
            let resolution = await resolver.resolve(record: record)
            try Task.checkCancellation()
            switch resolution {
            case .outcome(let outcome):
                try await store.saveOutcome(outcome)
                try await store.removeOutcomeExclusion(for: record.behaviorDay)
            case .excluded(let exclusion):
                try await store.removeOutcome(for: record.behaviorDay)
                try await store.saveOutcomeExclusion(exclusion)
            }
        }
    }
}
