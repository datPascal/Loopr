import Foundation
import DesignSystem
import Testing
import TodayKit
@testable import Loopr

@MainActor struct HealthMetricPinsTests {
    private func withDefaults(_ work: (UserDefaults) throws -> Void) throws {
        let name = "HealthMetricPinsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try work(defaults)
    }
    @Test func defaultsAndReorderedSelectionSurviveRestart() throws {
        try withDefaults { defaults in
            let pins = HealthMetricPins(storage: defaults)
            #expect(pins.metrics == HealthMetricPins.defaults)
            pins.toggle(.recovery)
            pins.toggle(.deepSleep)
            pins.move(.deepSleep, by: -1)
            let restored = HealthMetricPins(storage: defaults)
            #expect(restored.metrics == pins.metrics)
            #expect(!restored.contains(.recovery))
            #expect(restored.metrics.last == .steps)
            #expect(ProductRepositoryKeys.allOwnedDefaultsKeys.contains(HealthMetricPins.key))
        }
    }
    @Test func migrationKeepsUserOrderAndIntentionallyEmptyPins() throws {
        try withDefaults { defaults in
            // The shape an older version saved under the Today preferences key.
            defaults.set(Data(#"{"pinned":["steps","hrv"]}"#.utf8), forKey: TodayPreferencesStore.key)
            let pins = HealthMetricPins(storage: defaults)
            #expect(pins.metrics == [.steps, .rmssd])
            pins.toggle(.steps); pins.toggle(.rmssd)
            #expect(HealthMetricPins(storage: defaults).metrics.isEmpty)
        }
    }
    @Test func unknownPinsAndDuplicatesDoNotEraseKnownPins() throws {
        try withDefaults { defaults in
            defaults.set(try JSONEncoder().encode(["rmssd", "future", "steps", "rmssd"]), forKey: HealthMetricPins.key)
            #expect(HealthMetricPins(storage: defaults).metrics == [.rmssd, .steps])
        }
    }
    @Test func libraryCoversEveryMetricOnceAndSearchesBreathing() {
        let catalog = HealthMetricGroup.allCases.flatMap(\.metrics)
        #expect(catalog.count == MetricKey.allCases.count)
        #expect(Set(catalog) == Set(MetricKey.allCases))
        #expect(HealthMetricGroup.recovery.matching("Breathing") == [.respiratoryRate])
    }
    @Test func yesterdayDoesNotTurnIntoTodaysReadingAndZeroIsAReading() {
        let today = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_790_000_000))
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
        let old = MetricHistoryPoint(day: yesterday, value: 61, source: .band)
        let missing = HealthMetricReading(key: .rmssd, history: [old], day: today, state: .partial)
        #expect(missing.value == nil)
        #expect(missing.state == .absent)
        let zero = HealthMetricReading(key: .steps, history: [.init(day: today, value: 0, source: .band)], day: today, state: .partial)
        #expect(zero.value == 0)
        #expect(zero.comparison == "Estimated")
    }
    @Test func failedReadRemainsFailed() async {
        struct FailedHistory: MetricHistoryProviding {
            func series(for key: MetricKey, days: Int, endingOn: Date) async throws -> [MetricHistoryPoint] { throw CocoaError(.fileReadCorruptFile) }
        }
        let model = HealthMetricsModel()
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let anchor = MetricDetailAnchor(day: date, today: date)
        await model.load(keys: [.rmssd], provider: FailedHistory(), anchor: anchor)
        #expect(!model.isLoading)
        let reading = model.reading(.rmssd, on: date)
        #expect(reading.value == nil)
        #expect(reading.state == .recoverableError)
    }
}
