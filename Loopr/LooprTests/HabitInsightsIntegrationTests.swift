import AnalyticsKit
import DesignSystem
import DomainKit
import HeartKit
import JournalKit
import SleepKit
import StorageKit
import TodayKit
import XCTest
@testable import Loopr

final class HabitInsightsIntegrationTests: XCTestCase {
    func testHabitVisualFixturesCoverEveryInsightStateAndAuditTrailInput() async {
        XCTAssertEqual(HabitFixtures.allInsightStates.map(\.status), HabitInsightStatus.allCases)
        XCTAssertNotNil(HabitFixtures.estimate(status: .stale).lastValidEstimate)
        XCTAssertNotNil(HabitFixtures.estimate(status: .cannotSeparate).overlappingHabitID)
        XCTAssertEqual(
            HabitFixtures.estimate(status: .unavailable).exclusions.first?.reason,
            .missingMainSleep
        )

        let store = HabitFixtures.store(status: .clearAssociation)
        let definitions = await store.definitions(includeArchived: true)
        let records = await store.dayRecords()
        let estimates = await store.estimates()
        XCTAssertEqual(definitions.count, 2)
        XCTAssertFalse(records.isEmpty)
        XCTAssertEqual(estimates.first?.status, .clearAssociation)
        XCTAssertTrue(estimates.first?.metrics.contains(where: { $0.metricID == .sleepDuration }) == true)
    }

    func testAssociationAnalyzerIsDeterministicAndFindsKnownEffect() throws {
        let baseline = (0..<40).map {
            BinaryExposureBaselineValue(dayOrdinal: $0, value: 50 + Double($0 % 4))
        }
        let rows = (4..<40).map { day in
            let exposure = day.isMultiple(of: 2)
            return BinaryExposureRow(
                dayOrdinal: day,
                outcome: 50 + Double(day % 4) + (exposure ? 5 : 0),
                exposure: exposure,
                weekday: day % 7,
                priorDayStrain: Double(day % 10),
                nuisanceExposures: [day.isMultiple(of: 3) ? 1 : 0]
            )
        }
        let policy = BinaryExposurePolicy(
            baselineWindowDays: 28,
            minimumBaselineValues: 3,
            ridgeLambda: 1,
            bootstrapReplicates: 200,
            blockLength: 3
        )
        let first = try BinaryExposureAnalyzer.analyze(
            rows: rows, baselineValues: baseline, policy: policy, seed: 42
        )
        let repeated = try BinaryExposureAnalyzer.analyze(
            rows: rows, baselineValues: baseline, policy: policy, seed: 42
        )
        XCTAssertEqual(first, repeated)
        XCTAssertGreaterThan(first.adjustedDifference ?? 0, 3)
        XCTAssertEqual(first.adjustedRowCount, rows.count)
    }

    func testHabitAnswersAndTodaySelectionRemainTypedAndDurableInStore() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let habit = HabitDefinition(
            id: HabitID(rawValue: UUID()),
            source: .custom,
            name: "Late meal",
            question: "Did you eat late?",
            sortOrder: 0,
            createdAt: now
        )
        let store = InMemoryHabitStore(definitions: [habit])
        let day = DayIdentity(year: 2026, month: 8, day: 29)
        try await HabitCheckInService(store: store).answer(
            habitID: habit.id,
            day: day,
            timeZoneID: "Asia/Bangkok",
            answer: .no,
            source: .morningCheckIn
        )
        let selection = HabitTodaySelection(habitID: habit.id, selectedAt: now)
        await store.saveTodaySelection(selection)

        let record = await store.dayRecord(for: day)
        XCTAssertEqual(record?.response(for: habit.id)?.answer, .no)
        let restoredSelection = await store.todaySelection()
        XCTAssertEqual(restoredSelection, selection)
    }

    @MainActor
    func testSQLiteHabitRepositoryRoundTripsSourceAndClearsDerivedData() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LooprHabitTests.\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let database = try StorageDatabase(url: url, applicationVersion: "HabitTests (1)")
        let repository = try SQLiteHabitRepository(database: database)
        let now = Date(timeIntervalSince1970: 1_777_500_000)
        let day = DayIdentity(year: 2026, month: 8, day: 29)
        let definition = HabitDefinition(
            id: HabitID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000401")!),
            source: .custom,
            name: "Late meal",
            question: "Did you eat late?",
            sortOrder: 0,
            createdAt: now
        )
        let response = HabitResponse(
            habitID: definition.id,
            behaviorDay: day,
            behaviorTimeZoneID: "Asia/Bangkok",
            answer: .no,
            firstAnsweredAt: now,
            firstAnswerSource: .sameDay
        )
        let record = HabitDayRecord(
            behaviorDay: day,
            behaviorTimeZoneID: "Asia/Bangkok",
            responses: [response],
            createdAt: now
        )
        try await repository.saveDefinition(definition)
        try await repository.saveDayRecord(record)
        try await repository.saveOutcomeExclusion(.init(
            behaviorDay: day,
            reason: .missingMainSleep,
            resolvedAt: now
        ))
        try await repository.saveTodaySelection(.init(habitID: definition.id, selectedAt: now))

        let reopened = try SQLiteHabitRepository(database: database)
        let reopenedDefinition = try await reopened.definition(id: definition.id)
        let reopenedRecord = try await reopened.dayRecord(for: day)
        let reopenedExclusion = try await reopened.outcomeExclusion(for: day)
        XCTAssertEqual(reopenedDefinition, definition)
        XCTAssertEqual(reopenedRecord, record)
        XCTAssertEqual(reopenedExclusion?.reason, .missingMainSleep)

        try await reopened.deleteDerivedData()
        let sourceAfterDerivedDelete = try await reopened.dayRecord(for: day)
        let exclusionAfterDerivedDelete = try await reopened.outcomeExclusion(for: day)
        let selectionAfterDerivedDelete = try await reopened.todaySelection()
        XCTAssertEqual(sourceAfterDerivedDelete, record)
        XCTAssertNil(exclusionAfterDerivedDelete)
        XCTAssertNil(selectionAfterDerivedDelete)

        try await reopened.deleteAllHabitData()
        let definitionsAfterDelete = try await reopened.definitions(includeArchived: true)
        let recordsAfterDelete = try await reopened.dayRecords()
        XCTAssertTrue(definitionsAfterDelete.isEmpty)
        XCTAssertTrue(recordsAfterDelete.isEmpty)
    }

    @MainActor
    func testOutcomeResolverKeepsAvailableMetricsAndRecordsTypedFailures() async throws {
        let behaviorDay = DayIdentity(year: 2026, month: 8, day: 29)
        let outcomeDay = DayIdentity(year: 2026, month: 8, day: 30)
        let now = Date(timeIntervalSince1970: 1_777_500_000)
        let start = Date(timeIntervalSince1970: 1_777_470_000)
        let end = start.addingTimeInterval(8 * 60 * 60)
        let session = SleepSessionSummary(
            id: "main-sleep",
            start: start,
            end: end,
            durationMinutes: 480,
            isMainSleep: true,
            isPartial: false,
            confidence: 0.9,
            state: .measuredZero
        )
        let validSleep = SleepDaySnapshot(
            day: outcomeDay,
            state: .measuredZero,
            mainSleep: session,
            metrics: [SleepMetricValue(
                id: "duration",
                title: "Duration",
                value: "8 h",
                unit: "hours",
                state: .measuredZero,
                source: "test",
                algorithmVersion: "sleep.v1",
                numericValue: 480,
                numericUnit: .minutes
            )],
            source: "test",
            algorithmVersion: "sleep.v1"
        )
        let today = InMemoryTodayRepository()
        let sleep = InMemorySleepRepository(values: [outcomeDay: validSleep])
        let heart = InMemoryHeartRepository()
        let resolver = AppHabitOutcomeResolver(
            today: today,
            sleep: sleep,
            heart: heart,
            dateProvider: FixedTestDateProvider(value: now)
        )
        let record = HabitDayRecord(
            behaviorDay: behaviorDay,
            behaviorTimeZoneID: "Asia/Bangkok",
            createdAt: now
        )

        let valid = await resolver.resolve(record: record)
        guard case .outcome(let snapshot) = valid else {
            return XCTFail("A valid canonical sleep metric should resolve an outcome.")
        }
        XCTAssertEqual(snapshot.outcomeDay, outcomeDay)
        XCTAssertEqual(snapshot.metrics, [.sleepDuration: 480])
        XCTAssertEqual(snapshot.sourceVersions["today"], "missing")
        XCTAssertEqual(snapshot.sourceVersions["heart"], "missing")

        let partialSession = SleepSessionSummary(
            id: session.id,
            start: start,
            end: end,
            durationMinutes: 480,
            isMainSleep: true,
            isPartial: true,
            confidence: 0.9,
            state: .partial
        )
        await sleep.replace(SleepDaySnapshot(
            day: outcomeDay,
            state: .partial,
            mainSleep: partialSession,
            metrics: [],
            source: "test"
        ), for: outcomeDay)
        guard case .excluded(let partial) = await resolver.resolve(record: record) else {
            return XCTFail("A partial main sleep must be excluded.")
        }
        XCTAssertEqual(partial.reason, .partialSleep)

        await sleep.replace(SleepDaySnapshot(
            day: outcomeDay,
            state: .measuredZero,
            mainSleep: session,
            metrics: [SleepMetricValue(
                id: "duration",
                title: "Duration",
                value: "8 h",
                unit: "hours",
                state: .measuredZero,
                source: "test",
                numericValue: 8,
                numericUnit: .hours
            )],
            source: "test"
        ), for: outcomeDay)
        guard case .excluded(let incompatible) = await resolver.resolve(record: record) else {
            return XCTFail("An incompatible canonical unit must be excluded.")
        }
        XCTAssertEqual(incompatible.reason, .incompatibleMetricVersion)

        let staleSession = SleepSessionSummary(
            id: session.id,
            start: start,
            end: end,
            durationMinutes: 480,
            isMainSleep: true,
            isPartial: false,
            confidence: 0.9,
            state: .stale
        )
        await sleep.replace(SleepDaySnapshot(
            day: outcomeDay,
            state: .stale,
            mainSleep: staleSession,
            metrics: [],
            source: "test"
        ), for: outcomeDay)
        guard case .excluded(let stale) = await resolver.resolve(record: record) else {
            return XCTFail("A stale main sleep must be excluded.")
        }
        XCTAssertEqual(stale.reason, .invalidMetric)
    }

    func testProductionGuardrailsCoverTodaySelectionTelemetryAndDST() throws {
        let now = Date(timeIntervalSince1970: 1_777_500_000)
        XCTAssertEqual(HabitSettings().featureStage, .internalOnly)
        XCTAssertFalse(HabitSettings().featureStage.enablesToday)
        XCTAssertEqual(AppHabitFeatureGate.stage(infoDictionary: [
            AppHabitFeatureGate.infoDictionaryKey: "disabled"
        ]), .disabled)
        XCTAssertEqual(AppHabitFeatureGate.stage(infoDictionary: [
            AppHabitFeatureGate.infoDictionaryKey: "beta"
        ]), .beta)

        for name in HabitTelemetryEventName.allCases {
            let data = try HabitTelemetryEvent(
                name: name,
                appVersion: "1.0",
                activeCountBucket: .oneToThree,
                routeSource: .today
            ).encoded()
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(Set(object.keys), HabitTelemetryEvent.allowedEncodedKeys)
        }

        let firstID = HabitID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000301")!)
        let secondID = HabitID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000302")!)
        let recovery = integrationEstimate(
            id: firstID,
            status: .clearAssociation,
            metric: integrationMetric(.recoveryScore, effect: -4, lower: -8, upper: -1),
            calculatedAt: now
        )
        let sleep = integrationEstimate(
            id: secondID,
            status: .noClearAssociation,
            metric: integrationMetric(.sleepScore, effect: 4, lower: 3, upper: 5),
            calculatedAt: now.addingTimeInterval(60)
        )
        XCTAssertEqual(HabitTodaySelectionPolicy.ranked([sleep, recovery]).first?.estimate.habitID, firstID)
        let selection = HabitTodaySelection(habitID: firstID, selectedAt: now)
        XCTAssertTrue(HabitTodaySelectionPolicy.shouldRetain(
            selection,
            at: now.addingTimeInterval(HabitTodaySelectionPolicy.retentionInterval - 1)
        ))
        XCTAssertFalse(HabitTodaySelectionPolicy.shouldRetain(
            selection,
            at: now.addingTimeInterval(HabitTodaySelectionPolicy.retentionInterval)
        ))

        let zone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let springStart = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8)))
        let springDeadline = try XCTUnwrap(HabitEligibility.deadline(
            for: DayIdentity(year: 2026, month: 3, day: 8),
            timeZoneID: zone.identifier
        ))
        XCTAssertEqual(springDeadline.timeIntervalSince(springStart), 71 * 60 * 60, accuracy: 0.001)

        let reminderFireDate = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 3, day: 9, hour: 9
        )))
        XCTAssertEqual(
            CentralNotificationHabitReminderScheduler.behaviorDay(
                before: reminderFireDate,
                calendar: calendar,
                fallback: DayIdentity(year: 1970, month: 1, day: 1)
            ),
            DayIdentity(year: 2026, month: 3, day: 8)
        )
    }

    private func integrationMetric(
        _ id: HabitOutcomeMetricID,
        effect: Double,
        lower: Double,
        upper: Double
    ) -> HabitMetricEstimate {
        HabitMetricEstimate(
            metricID: id,
            yesMean: 55,
            noMean: 50,
            rawDifference: effect,
            adjustedDifference: effect,
            intervalLower: lower,
            intervalUpper: upper,
            adjustedRowCount: 30,
            isClear: true
        )
    }

    private func integrationEstimate(
        id: HabitID,
        status: HabitInsightStatus,
        metric: HabitMetricEstimate,
        calculatedAt: Date
    ) -> HabitImpactEstimate {
        HabitImpactEstimate(
            habitID: id,
            status: status,
            yesCount: 15,
            noCount: 15,
            eligibleDayCount: 30,
            excludedDayCount: 0,
            metrics: [metric],
            windowStart: DayIdentity(year: 2026, month: 6, day: 1),
            windowEnd: DayIdentity(year: 2026, month: 8, day: 29),
            calculatedAt: calculatedAt
        )
    }
}

private struct FixedTestDateProvider: DateProviding {
    let value: Date
    func now() -> Date { value }
}
