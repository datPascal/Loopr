import BodyKit
import DomainKit
import DesignSystem
import Foundation
import Testing
@testable import Loopr

private struct StubHistory: MetricHistoryProviding {
    let points: [MetricKey: [MetricHistoryPoint]]
    let requests: RequestLog

    func series(for key: MetricKey, days: Int, endingOn: Date) async throws -> [MetricHistoryPoint] {
        await requests.record(key: key, days: days, end: endingOn)
        return points[key] ?? []
    }
}

private actor RequestLog {
    private(set) var entries: [(key: MetricKey, days: Int, end: Date)] = []
    func record(key: MetricKey, days: Int, end: Date) { entries.append((key, days, end)) }
}

struct BodyHistoryAdapterTests {
    private let calendar = Calendar.current
    private let anchor = DayIdentity(year: 2026, month: 9, day: 23)

    private func date(_ day: DayIdentity) -> Date { day.bodyDate(calendar: calendar) ?? Date() }

    @Test func readsFourSeriesThroughTheNextMorningAndKeysThemByDay() async throws {
        let next = anchor.bodyAdding(days: 1)
        let log = RequestLog()
        let stub = StubHistory(points: [
            .strain: [MetricHistoryPoint(day: date(anchor), value: 12.4, source: .band)],
            .recovery: [MetricHistoryPoint(day: date(anchor), value: 71, source: .band),
                         MetricHistoryPoint(day: date(next), value: 58, source: .band)],
            .steps: [MetricHistoryPoint(day: date(anchor), value: 9_000, source: .band),
                     MetricHistoryPoint(day: date(anchor.bodyAdding(days: -1)), value: 12_000, source: .appleHealth)],
            .activeEnergy: [MetricHistoryPoint(day: date(anchor), value: 540, source: .band)]
        ], requests: log)
        let history = await MetricHistoryBodyProvider(provider: stub).bodyHistory(anchor: anchor)

        #expect(history.anchor == anchor)
        #expect(history.day(anchor) == BodyHistoryDay(day: anchor, strain: 12.4, recovery: 71, steps: 9_000, activeEnergy: 540))
        #expect(history.day(next)?.recovery == 58)
        // Apple Health counts never become the usual for the band's estimate.
        #expect(history.day(anchor.bodyAdding(days: -1)) == nil)

        let entries = await log.entries
        #expect(Set(entries.map(\.key)) == [.strain, .recovery, .steps, .activeEnergy])
        #expect(entries.allSatisfy { $0.days == BodyHistory.lookbackDays + 2 })
        #expect(entries.allSatisfy { calendar.isDate($0.end, inSameDayAs: date(next)) })
    }

    @Test func fixtureLaunchesReadTheSharedFixtureStory() async throws {
        let provider = BodyHistorySource.provider(repositories: nil, composition: .populated, metricHistory: EmptyMetricHistoryProvider())
        let history = try #require(await provider?.bodyHistory(anchor: BodyFixtures.day))
        let recovery = try #require(LooprFixtureMetrics.today(LooprMetricLinkID.recovery))
        #expect(history.day(BodyFixtures.day)?.recovery == recovery)
        #expect(recovery == 79)
        let empty = BodyHistorySource.provider(repositories: nil, composition: .empty, metricHistory: EmptyMetricHistoryProvider())
        #expect(await empty?.bodyHistory(anchor: BodyFixtures.day).isEmpty == true)
    }
}
