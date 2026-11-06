import Foundation
import Testing
@testable import Loopr

@MainActor
struct HealthMetricLoadingTests {
    @Test(arguments: [false, true])
    func anOlderReadCannotReplaceTheCurrentDay(cancelOldRead: Bool) async {
        let model = HealthMetricsModel()
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let oldAnchor = MetricDetailAnchor(day: date.addingTimeInterval(-86_400), today: date)
        let currentAnchor = MetricDetailAnchor(day: date, today: date)
        let delayed = DelayedMetricHistory()
        let first = Task { await model.load(keys: [.rmssd], provider: delayed, anchor: oldAnchor) }
        await delayed.waitUntilRequested()
        if cancelOldRead { first.cancel() }
        await model.load(keys: [.steps], provider: CurrentMetricHistory(day: currentAnchor.day), anchor: currentAnchor)
        await delayed.release([.init(day: oldAnchor.day, value: 61, source: .band)])
        await first.value
        #expect(model.reading(.steps, on: currentAnchor.day).value == 0)
        #expect(model.history[.rmssd] == nil)
        #expect(!model.isLoading)
        #expect(model.failures.isEmpty)
    }
}

private actor DelayedMetricHistory: MetricHistoryProviding {
    private var pending: CheckedContinuation<[MetricHistoryPoint], Never>?
    private var listeners: [CheckedContinuation<Void, Never>] = []
    func series(for key: MetricKey, days: Int, endingOn: Date) async -> [MetricHistoryPoint] {
        await withCheckedContinuation { continuation in
            pending = continuation
            for listener in listeners { listener.resume() }
            listeners = []
        }
    }
    func waitUntilRequested() async {
        if pending != nil { return }
        await withCheckedContinuation { listeners.append($0) }
    }
    func release(_ points: [MetricHistoryPoint]) { pending?.resume(returning: points); pending = nil }
}

private nonisolated struct CurrentMetricHistory: MetricHistoryProviding {
    let day: Date
    func series(for key: MetricKey, days: Int, endingOn: Date) async -> [MetricHistoryPoint] {
        [.init(day: day, value: 0, source: .band)]
    }
}
