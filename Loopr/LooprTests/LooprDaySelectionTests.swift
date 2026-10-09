import Foundation
import HeartKit
import Testing
import DesignSystem
import DomainKit
import ProfileKit
import StorageKit
@testable import Loopr

// MARK: Helpers

private struct FixedClock: DateProviding {
    let value: Date
    func now() -> Date { value }
}

/// A clock a test can move.
private final class MovableClock: DateProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    func now() -> Date { lock.withLock { value } }
    func set(_ date: Date) { lock.withLock { value = date } }
}

/// A day source whose answers a test controls, counting derivations.
private final class ScriptedDaySource: LooprDayDataSource, @unchecked Sendable {
    private let lock = NSLock()
    private var knowledgeValue: LooprDayKnowledge
    private var derived: [DayIdentity: Bool]
    private(set) var derivations: [DayIdentity] = []

    init(knowledge: LooprDayKnowledge, derived: [DayIdentity: Bool] = [:]) {
        knowledgeValue = knowledge
        self.derived = derived
    }

    func update(_ change: (inout LooprDayKnowledge) -> Void) { lock.withLock { change(&knowledgeValue) } }
    var derivationCount: Int { lock.withLock { derivations.count } }

    func knowledge(today: DayIdentity) async -> LooprDayKnowledge { lock.withLock { knowledgeValue } }
    func hasData(day: DayIdentity) async -> Bool? {
        lock.withLock {
            derivations.append(day)
            return derived[day] ?? false
        }
    }
    func isCached(day: DayIdentity) async -> Bool { true }
}

private func day(_ year: Int, _ month: Int, _ value: Int) -> DayIdentity {
    DayIdentity(year: year, month: month, day: value)
}

private func calendar(_ identifier: String) -> Calendar {
    LooprDays.calendar(TimeZone(identifier: identifier)!)
}

private func zone(_ identifier: String) -> SystemTimeZoneProvider {
    SystemTimeZoneProvider(timeZone: TimeZone(identifier: identifier)!)
}

/// 24 Sep 2026 09:41 in Perth (UTC+8). The synthetic history ends 23 Sep 22:15.
private let thursdayMorning = Date(timeIntervalSince1970: 1_790_214_060)
private let snapshotEnd = Date(timeIntervalSince1970: 1_790_172_900)

// MARK: Resolution

struct LooprDayResolutionTests {
    private let perth = calendar("Australia/Perth")
    private let today = day(2026, 9, 24)

    @Test func noDataAtAllStaysOnAnEmptyToday() {
        #expect(LooprDayResolution.resolve(today: today, knowledge: LooprDayKnowledge(), calendar: perth) == .show(today))
    }

    @Test func todayWithDataIsShown() {
        var knowledge = LooprDayKnowledge()
        knowledge.withData = [today, day(2026, 9, 23)]
        #expect(LooprDayResolution.resolve(today: today, knowledge: knowledge, calendar: perth) == .show(today))
    }

    @Test func aPartialTodayStillCountsAsToday() {
        // One derived value (say, the morning's steps) is enough: today has
        // data, even though yesterday is far fuller.
        var knowledge = LooprDayKnowledge()
        knowledge.withData = [today, day(2026, 9, 23)]
        knowledge.recorded = [today, day(2026, 9, 23)]
        #expect(LooprDayResolution.resolve(today: today, knowledge: knowledge, calendar: perth) == .show(today))
    }

    @Test func anUnderivedTodayIsDerivedBeforeDeciding() {
        var knowledge = LooprDayKnowledge()
        knowledge.recorded = [today]
        knowledge.withData = [day(2026, 9, 23)]
        #expect(LooprDayResolution.resolve(today: today, knowledge: knowledge, calendar: perth) == .derive(today))
        knowledge.record(day: today, hasData: false)
        #expect(LooprDayResolution.resolve(today: today, knowledge: knowledge, calendar: perth) == .show(day(2026, 9, 23)))
    }

    @Test func beforeTheMorningSyncTheLatestCompleteDayIsShown() {
        // The real snapshot: nothing recorded on the 24th, the 23rd derived.
        var knowledge = LooprDayKnowledge()
        knowledge.recorded = [day(2026, 9, 21), day(2026, 9, 22), day(2026, 9, 23)]
        knowledge.withData = [day(2026, 9, 22), day(2026, 9, 23)]
        knowledge.earliestRecorded = day(2026, 9, 21)
        #expect(LooprDayResolution.resolve(today: today, knowledge: knowledge, calendar: perth) == .show(day(2026, 9, 23)))
    }

    @Test func gapsInHistoryAreWalkedOver() {
        var knowledge = LooprDayKnowledge()
        knowledge.withData = [day(2026, 9, 18)]
        knowledge.recorded = [day(2026, 9, 18), day(2026, 9, 21)]
        knowledge.derivedEmpty = [day(2026, 9, 21)]
        knowledge.earliestRecorded = day(2026, 9, 18)
        #expect(LooprDayResolution.resolve(today: today, knowledge: knowledge, calendar: perth) == .show(day(2026, 9, 18)))
    }

    @Test func anUnderivedDayInsideAGapIsDerivedNotSkipped() {
        var knowledge = LooprDayKnowledge()
        knowledge.withData = [day(2026, 9, 18)]
        knowledge.recorded = [day(2026, 9, 18), day(2026, 9, 21)]
        knowledge.earliestRecorded = day(2026, 9, 18)
        #expect(LooprDayResolution.resolve(today: today, knowledge: knowledge, calendar: perth) == .derive(day(2026, 9, 21)))
    }

    @Test func dataOlderThanTheLookbackLeavesTodayEmpty() {
        var knowledge = LooprDayKnowledge()
        knowledge.withData = [day(2026, 5, 1)]
        knowledge.earliestRecorded = day(2026, 5, 1)
        #expect(LooprDayResolution.resolve(today: today, knowledge: knowledge, calendar: perth) == .show(today))
    }

    @Test func theWalkStopsAtTheEarliestRecordedDay() {
        var knowledge = LooprDayKnowledge()
        knowledge.recorded = [day(2026, 9, 23)]
        knowledge.derivedEmpty = [day(2026, 9, 23)]
        knowledge.earliestRecorded = day(2026, 9, 23)
        #expect(LooprDayResolution.resolve(today: today, knowledge: knowledge, calendar: perth) == .show(today))
    }

    @Test func steppingBackAcrossADaylightSavingChangeVisitsEveryDay() {
        // Berlin leaves summer time on Sun 25 Oct 2026, a 25-hour day.
        let berlin = calendar("Europe/Berlin")
        var knowledge = LooprDayKnowledge()
        knowledge.withData = [day(2026, 10, 25)]
        knowledge.recorded = [day(2026, 10, 25)]
        #expect(LooprDayResolution.resolve(today: day(2026, 10, 26), knowledge: knowledge, calendar: berlin)
                == .show(day(2026, 10, 25)))
        #expect(LooprDays.adding(-1, to: day(2026, 10, 26), calendar: berlin) == day(2026, 10, 25))
        #expect(LooprDays.adding(-1, to: day(2026, 3, 30), calendar: berlin) == day(2026, 3, 29))
        let bounds = LooprDays.bounds(of: day(2026, 10, 25), calendar: berlin)
        let length: TimeInterval = bounds.map { $0.end.timeIntervalSince($0.start) } ?? 0
        #expect(length == 90_000)
    }

    @Test func daysBeforeTheIndexedWindowAreUnknownNotEmpty() {
        var knowledge = LooprDayKnowledge()
        knowledge.coveredFrom = day(2024, 1, 1)
        #expect(knowledge.status(of: day(2023, 12, 31)) == .unknown)
        #expect(knowledge.status(of: day(2024, 1, 2)) == .noData)
    }
}

// MARK: The shared selection

@MainActor
struct LooprDaySelectionStoreTests {
    private let today = day(2026, 9, 24)

    private func snapshotKnowledge() -> LooprDayKnowledge {
        var knowledge = LooprDayKnowledge()
        knowledge.recorded = [day(2026, 9, 21), day(2026, 9, 22), day(2026, 9, 23)]
        knowledge.earliestRecorded = day(2026, 9, 21)
        knowledge.lastRecordAt = snapshotEnd
        return knowledge
    }

    private func defaults() -> UserDefaults {
        let name = "days-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func coldLaunchResolvesToTheLatestCompleteDayAndRemembersIt() async {
        let store = defaults()
        let source = ScriptedDaySource(knowledge: snapshotKnowledge(), derived: [day(2026, 9, 23): true])
        let selection = LooprDaySelection(today: today, dateProvider: FixedClock(value: thursdayMorning),
                                          timeZoneProvider: zone("Australia/Perth"), hints: LooprDayHintStore(defaults: store))
        #expect(selection.isResolving)
        #expect(selection.day == today)
        selection.attach(source)
        await selection.refresh()
        #expect(!selection.isResolving)
        #expect(selection.day == day(2026, 9, 23))
        #expect(selection.navigation.title == "Yesterday")
        #expect(selection.navigation.lastSyncedAt == snapshotEnd)
        // Only the 23rd needed deriving; the 24th has no recorded second.
        #expect(source.derivations == [day(2026, 9, 23)])
        #expect(LooprDayHintStore(defaults: store).day(forToday: today) == day(2026, 9, 23))

        // The next cold launch the same day opens straight on it.
        let relaunched = LooprDaySelection(today: today, dateProvider: FixedClock(value: thursdayMorning),
                                           timeZoneProvider: zone("Australia/Perth"), hints: LooprDayHintStore(defaults: store))
        #expect(!relaunched.isResolving)
        #expect(relaunched.day == day(2026, 9, 23))
        // A hint from another day is ignored.
        #expect(LooprDayHintStore(defaults: store).day(forToday: day(2026, 9, 25)) == nil)
    }

    @Test func anUnchangedDayIndexDoesNotAdvanceItsGeneration() async {
        let source = ScriptedDaySource(knowledge: snapshotKnowledge(), derived: [day(2026, 9, 23): true])
        let selection = LooprDaySelection(today: today, dateProvider: FixedClock(value: thursdayMorning),
                                          timeZoneProvider: zone("Australia/Perth"), hints: LooprDayHintStore(defaults: defaults()))
        selection.attach(source)
        await selection.refresh()
        let generation = selection.generation
        await selection.refresh()
        #expect(selection.generation == generation)
        source.update { $0.lastRecordAt = thursdayMorning }
        await selection.refresh()
        #expect(selection.generation == generation + 1)
    }

    @Test func noDataAnywhereLeavesTodayWithNothingToStepTo() async {
        let selection = LooprDaySelection(today: today, dateProvider: FixedClock(value: thursdayMorning),
                                          timeZoneProvider: zone("Australia/Perth"), hints: LooprDayHintStore(defaults: defaults()))
        selection.attach(ScriptedDaySource(knowledge: LooprDayKnowledge()))
        await selection.refresh()
        #expect(selection.day == today)
        #expect(!selection.navigation.canGoBack)
        #expect(!selection.navigation.canGoForward)
        #expect(selection.navigation.status == .noData)
    }

    @Test func steppingIsBoundedAndStopsFollowingTheDefault() async {
        var knowledge = snapshotKnowledge()
        knowledge.withData = [day(2026, 9, 22), day(2026, 9, 23)]
        let selection = LooprDaySelection(today: today, dateProvider: FixedClock(value: thursdayMorning),
                                          timeZoneProvider: zone("Australia/Perth"),
                                          source: ScriptedDaySource(knowledge: knowledge), knowledge: knowledge)
        #expect(selection.day == day(2026, 9, 23))
        #expect(selection.followsDefault)
        selection.step(by: -1)
        #expect(selection.day == day(2026, 9, 22))
        #expect(!selection.followsDefault)
        selection.step(by: -5)
        #expect(selection.day == day(2026, 9, 21))
        #expect(selection.status == .unknown)
        selection.step(by: 10)
        #expect(selection.day == today)
        #expect(selection.status == .noData)
        selection.navigation.goBack()
        #expect(selection.day == day(2026, 9, 23))
    }

    @Test func theNightLandingMovesADefaultSelectionToToday() async {
        let source = ScriptedDaySource(knowledge: snapshotKnowledge(), derived: [day(2026, 9, 23): true])
        let selection = LooprDaySelection(today: today, dateProvider: FixedClock(value: thursdayMorning),
                                          timeZoneProvider: zone("Australia/Perth"), hints: LooprDayHintStore(defaults: defaults()))
        selection.attach(source)
        await selection.refresh()
        #expect(selection.day == day(2026, 9, 23))
        source.update { $0.withData.insert(day(2026, 9, 24)); $0.recorded.insert(day(2026, 9, 24)) }
        await selection.refresh()
        #expect(selection.day == today)
    }

    @Test func aDayThePersonPickedIsNotTakenAway() async {
        let source = ScriptedDaySource(knowledge: snapshotKnowledge(), derived: [day(2026, 9, 23): true, day(2026, 9, 22): true])
        let selection = LooprDaySelection(today: today, dateProvider: FixedClock(value: thursdayMorning),
                                          timeZoneProvider: zone("Australia/Perth"), hints: LooprDayHintStore(defaults: defaults()))
        selection.attach(source)
        await selection.refresh()
        selection.step(by: -1)
        source.update { $0.withData.insert(day(2026, 9, 24)); $0.recorded.insert(day(2026, 9, 24)) }
        await selection.refresh()
        #expect(selection.day == day(2026, 9, 22))
        #expect(selection.defaultDay == today)
    }

    @Test func midnightRollsTodayForwardAndReleasesAPickedDay() async {
        let clock = MovableClock(thursdayMorning)
        var knowledge = snapshotKnowledge()
        knowledge.withData = [day(2026, 9, 23), today]
        knowledge.recorded.insert(today)
        let source = ScriptedDaySource(knowledge: knowledge)
        let selection = LooprDaySelection(today: today, dateProvider: clock, timeZoneProvider: zone("Australia/Perth"),
                                          hints: LooprDayHintStore(defaults: defaults()))
        selection.attach(source)
        await selection.refresh()
        #expect(selection.day == today)
        selection.step(by: -1)
        clock.set(thursdayMorning.addingTimeInterval(16 * 3600))
        await selection.refresh()
        #expect(selection.today == day(2026, 9, 25))
        #expect(selection.followsDefault)
        // The 25th is empty, so the latest complete day is the 24th, now "Yesterday".
        #expect(selection.day == today)
        #expect(selection.navigation.title == "Yesterday")
    }

    @Test func aLongAbsenceReleasesAPickedDay() async {
        let clock = MovableClock(thursdayMorning)
        var knowledge = snapshotKnowledge()
        knowledge.withData = [day(2026, 9, 22), day(2026, 9, 23)]
        let selection = LooprDaySelection(today: today, dateProvider: clock, timeZoneProvider: zone("Australia/Perth"),
                                          source: ScriptedDaySource(knowledge: knowledge), knowledge: knowledge)
        selection.step(by: -1)
        selection.sceneDidEnterBackground()
        clock.set(thursdayMorning.addingTimeInterval(5 * 60))
        selection.sceneDidBecomeActive()
        #expect(selection.day == day(2026, 9, 22))
        selection.sceneDidEnterBackground()
        clock.set(thursdayMorning.addingTimeInterval(45 * 60))
        selection.sceneDidBecomeActive()
        #expect(selection.day == day(2026, 9, 23))
        #expect(selection.followsDefault)
    }

    @Test func aResolutionPassDerivesAtMostABoundedNumberOfDays() async {
        // Many recorded days that all turn out empty.
        var knowledge = LooprDayKnowledge()
        let recorded = (1...20).map { day(2026, 9, $0) }
        knowledge.recorded = Set(recorded)
        knowledge.earliestRecorded = day(2026, 9, 1)
        let source = ScriptedDaySource(knowledge: knowledge)
        let selection = LooprDaySelection(today: today, dateProvider: FixedClock(value: thursdayMorning),
                                          timeZoneProvider: zone("Australia/Perth"), hints: LooprDayHintStore(defaults: defaults()))
        selection.attach(source)
        await selection.refresh()
        #expect(source.derivationCount == LooprDaySelection.maximumDerivationsPerPass)
        #expect(!selection.isResolving)
        // A second pass keeps what the first learned and walks further back.
        await selection.refresh()
        #expect(source.derivationCount == 2 * LooprDaySelection.maximumDerivationsPerPass)
        #expect(Set(source.derivations).count == source.derivationCount)
    }
}

// MARK: The index behind it

@MainActor
struct LooprDayIndexTests {
    private func databases() throws -> (StorageDatabase, StorageDatabase, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (try StorageDatabase(url: root.appendingPathComponent("history.sqlite")),
                try StorageDatabase(url: root.appendingPathComponent("products.sqlite")), root)
    }

    private func engine(history: StorageDatabase, products: StorageDatabase, zone identifier: String,
                        now: Date) throws -> CanonicalDailyAnalytics {
        try CanonicalDailyAnalytics(history: history, products: products, profile: InMemoryProfileRepository(),
            dateProvider: FixedClock(value: now), timeZoneProvider: zone(identifier),
            budget: LooprDerivationBudget(dates: FixedClock(value: now), foreground: LooprFixedForegroundState(true)),
            sharedGenerations: LooprSharedGenerationCache())
    }

    private func seed(_ database: StorageDatabase, seconds: [Int64]) throws {
        try database.write { db in
            for (index, timestamp) in seconds.enumerated() {
                try db.execute(sql: "INSERT INTO decoded_second(physiological_timestamp, band_counter, absolute_timestamp, local_day, record_version, heart_rate, gravity_x, gravity_y, gravity_z) VALUES (?, ?, ?, '2026-09-23', 24, 60, 0, 0, 1)",
                               arguments: [timestamp, index, timestamp])
            }
        }
    }

    @Test func recordedDaysFollowThePhonesTimeZone() async throws {
        let (history, products, root) = try databases()
        defer { try? FileManager.default.removeItem(at: root) }
        // In Perth (UTC+8): 21 Sep 10:00, 23 Sep 22:15, 23 Sep 23:50 and
        // 24 Sep 00:30. The last one is still 23 Sep in UTC.
        let seconds: [Int64] = [1_789_956_000, 1_790_172_900, 1_790_178_600, 1_790_181_000]
        try seed(history, seconds: seconds)
        let perth = try engine(history: history, products: products, zone: "Australia/Perth", now: thursdayMorning)
        let local = try await perth.dayKnowledge(today: day(2026, 9, 24))
        #expect(local.recorded == [day(2026, 9, 21), day(2026, 9, 23), day(2026, 9, 24)])
        #expect(local.earliestRecorded == day(2026, 9, 21))
        #expect(local.lastRecordAt == Date(timeIntervalSince1970: 1_790_181_000))
        #expect(local.withData.isEmpty)

        let utc = try engine(history: history, products: products, zone: "UTC", now: thursdayMorning)
        let universal = try await utc.dayKnowledge(today: day(2026, 9, 24))
        #expect(universal.recorded == [day(2026, 9, 21), day(2026, 9, 23)])
    }

    @Test func derivedBandValuesMarkDaysWithData() async throws {
        let (history, products, root) = try databases()
        defer { try? FileManager.default.removeItem(at: root) }
        try seed(history, seconds: [1_790_172_900])
        try history.replaceMetricSeries(localDay: "2026-09-22", source: .band, keys: ["sleepDuration"],
            with: [StoredMetricSeriesValue(localDay: "2026-09-22", metricKey: "sleepDuration", source: .band, value: 452)],
            updatedAt: 1)
        try history.replaceMetricSeries(localDay: "2026-09-20", source: .appleHealth, keys: ["steps"],
            with: [StoredMetricSeriesValue(localDay: "2026-09-20", metricKey: "steps", source: .appleHealth, value: 4_000)],
            updatedAt: 1)
        let analytics = try engine(history: history, products: products, zone: "Australia/Perth", now: thursdayMorning)
        let knowledge = try await analytics.dayKnowledge(today: day(2026, 9, 24))
        // Apple Health values are not band data; the tabs show band days.
        #expect(knowledge.withData == [day(2026, 9, 22)])
        #expect(knowledge.status(of: day(2026, 9, 22)) == .hasData)
        #expect(knowledge.status(of: day(2026, 9, 23)) == .unknown)
        #expect(knowledge.status(of: day(2026, 9, 24)) == .noData)
        #expect(knowledge.earliestDay == day(2026, 9, 22))
    }

    @Test func aDayWithOnlyAFewEveningSecondsDerivesToNoData() async throws {
        let (history, products, root) = try databases()
        defer { try? FileManager.default.removeItem(at: root) }
        try seed(history, seconds: Array(1_790_172_000...1_790_172_060))
        let analytics = try engine(history: history, products: products, zone: "Australia/Perth", now: thursdayMorning)
        #expect(try await analytics.dayHasData(day: day(2026, 9, 23)) == false)
        let display = try #require(try await analytics.readDisplay(day: day(2026, 9, 23)))
        #expect(display.projection.heart.metric(.maxHeartRate)?.numericValue == 60)
        #expect(try await analytics.dayKnowledge(today: day(2026, 9, 24)).withData.isEmpty)
        #expect(await analytics.hasSavedDisplay(day: day(2026, 9, 23)))
        #expect(await !analytics.hasSavedDisplay(day: day(2026, 9, 22)))
        #expect(try await analytics.dayHasData(day: day(2026, 9, 22)) == false)
    }

    @Test func aStoredPeakAloneDoesNotMarkADayWithData() async throws {
        let (history, products, root) = try databases()
        defer { try? FileManager.default.removeItem(at: root) }
        try history.upsertMetricSeries([
            .init(localDay: "2026-09-23", metricKey: MetricKey.maxHeartRate.rawValue, source: .band, value: 60),
            .init(localDay: "2026-09-22", metricKey: MetricKey.maxHeartRate.rawValue, source: .band, value: 180),
            .init(localDay: "2026-09-22", metricKey: MetricKey.strain.rawValue, source: .band, value: 12),
            .init(localDay: "2026-09-20", metricKey: MetricKey.maxHeartRate.rawValue, source: .whoopExport, value: 170)
        ], updatedAt: 1)
        let analytics = try engine(history: history, products: products, zone: "UTC", now: thursdayMorning)
        #expect(try await analytics.dayKnowledge(today: day(2026, 9, 24)).withData == [day(2026, 9, 22), day(2026, 9, 20)])
    }
}
