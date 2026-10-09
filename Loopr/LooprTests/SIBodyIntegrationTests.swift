import AnalyticsKit
import BodyKit
import DomainKit
import Foundation
import ProfileKit
import StorageKit
import Testing
import TodayKit
import WorkoutKit
@testable import Loopr

@MainActor struct SIBodyIntegrationTests {
    @Test func storedTailProducesAndCachesRecoveryThenSurvivesRawDeletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let history = try StorageDatabase(url: root.appendingPathComponent("history.sqlite"))
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(600)
        try history.write { db in
            for offset in -300...123 {
                let timestamp = Int64(end.timeIntervalSince1970) + Int64(offset)
                let hr = offset <= 0 ? 165 : Int((165 - Double(offset) * 0.5).rounded())
                try db.execute(sql: "INSERT INTO decoded_second(physiological_timestamp, band_counter, absolute_timestamp, local_day, record_version, heart_rate) VALUES (?, ?, ?, '2027-01-15', 24, ?)",
                               arguments: [timestamp, offset + 300, timestamp, hr])
            }
        }
        let workout = WorkoutRecord(id: UUID(), identity: .init(canonicalKey: "synthetic"), activity: .run,
            source: .manual, state: .completed, createdAt: start, startedAt: start, endedAt: end)
        let products = try StorageDatabase(url: root.appendingPathComponent("products.sqlite"))
        let store = try SQLiteWorkoutStore(database: products)
        try await store.save(workout)
        let provider = StoredWorkoutRecoveryProvider(history: history, workouts: store,
            profile: InMemoryProfileRepository(), zoneSettings: .init(manualMaximum: 190))
        let shown = await provider.recovery(for: workout)
        #expect(shown.assessment.firstMinute?.dropBPM == 30)
        #expect(shown.assessment.secondMinute?.dropBPM == 60)
        let saved = try #require(await store.workout(id: workout.id))
        #expect(saved.heartRateRecovery == shown.assessment)
        try history.write { try $0.execute(sql: "UPDATE decoded_second SET skin_contact = 0 WHERE absolute_timestamp = ?",
                                           arguments: [Int64(end.timeIntervalSince1970) + 30]) }
        let unworn = WorkoutRecord(id: UUID(), identity: .init(canonicalKey: "unworn"), activity: .run,
            source: .manual, state: .completed, createdAt: start, startedAt: start, endedAt: end)
        #expect(await provider.recovery(for: unworn).assessment.firstMinute == nil)
        try history.write { try $0.execute(sql: "DELETE FROM decoded_second") }
        #expect(await provider.recovery(for: saved).assessment == shown.assessment)
        let changedMaximum = StoredWorkoutRecoveryProvider(history: history, workouts: store,
            profile: InMemoryProfileRepository(), zoneSettings: .init(manualMaximum: 240))
        #expect(await changedMaximum.recovery(for: saved).assessment.firstMinute == nil)
    }

    @Test func loadAwareTargetUsesPriorCompletedDaysAcrossMetricDetail() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let today = calendar.date(from: DateComponents(year: 2026, month: 9, day: 23))!
        let anchor = MetricDetailAnchor(day: today, today: today, calendar: calendar)
        let points = (0...90).map { offset in
            MetricHistoryPoint(day: calendar.date(byAdding: .day, value: -offset, to: today)!,
                value: offset == 0 ? 12 : offset <= 7 ? 18 : 8, source: .band)
        }
        let provider = SIBodyMetricProvider(strain: points, recovery: [MetricHistoryPoint(day: today, value: 74, source: .band)])
        let day = DayIdentity(bodyDate: today, calendar: calendar)
        let bodyHistory = await MetricHistoryBodyProvider(provider: provider, calendar: calendar).bodyHistory(anchor: day)
        #expect(bodyHistory.day(day.bodyAdding(days: -90))?.strain == 8)
        let bodyLoad = BodyTrainingLoad.compute(history: bodyHistory, endingOn: day.bodyAdding(days: -1))
        guard case .ready(let ready) = bodyLoad else { Issue.record("Expected the full prior load history"); return }
        #expect(ready.model.days == 90)
        let model = MetricDetailModel(key: .strain, anchor: anchor)
        await model.load(from: provider, anchor: anchor)
        #expect(model.strainTarget?.range == 12...16)
        #expect(model.strainTarget?.reason == "Lower because your last 7 days were heavy.")
        let source = LooprTodayContextSource(history: provider, timeZone: .gmt,
            sleepDay: { @Sendable _ in nil }, bodyDay: { @Sendable _ in nil },
            journalEntries: { @Sendable _ in [] }, alarmMinute: { @Sendable in nil })
        let context = try await source.context(for: DayIdentity(bodyDate: today, calendar: calendar), summary: nil)
        #expect(context?.suggestedStrainRange == model.strainTarget?.range)
    }
}
nonisolated private struct SIBodyMetricProvider: MetricHistoryProviding {
    let strain: [MetricHistoryPoint]
    let recovery: [MetricHistoryPoint]
    func series(for key: MetricKey, days: Int, endingOn: Date) async throws -> [MetricHistoryPoint] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let last = calendar.startOfDay(for: endingOn)
        guard days > 0, let first = calendar.date(byAdding: .day, value: -(days - 1), to: last) else { return [] }
        let values = key == .strain ? strain : key == .recovery ? recovery : []
        return values.filter { $0.day >= first && $0.day <= last }
    }
}
