import DomainKit
import Foundation
import JournalKit
import XCTest

@MainActor final class JournalInsightsTests: XCTestCase {
    private let zone = "Australia/Perth"
    private let start = Date(timeIntervalSince1970: 1_699_977_600) // 15 November, local midnight.
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: zone)!; return c }
    private var definition: HabitDefinition {
        .init(id: .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000001501")!),
              source: .custom, name: "Read before sleep", question: "Read before sleep?", sortOrder: 0, createdAt: start)
    }
    private func day(_ offset: Int) -> DayIdentity {
        let c = calendar.dateComponents([.year, .month, .day], from: start.addingTimeInterval(Double(offset) * 86400))
        return .init(year: c.year!, month: c.month!, day: c.day!)
    }
    private func rated(_ offset: Int, value: JournalRating = .four, delay: TimeInterval = 9 * 3600) -> HabitDayRecord {
        let date = start.addingTimeInterval(Double(offset) * 86400)
        return .init(behaviorDay: day(offset), behaviorTimeZoneID: zone, createdAt: date,
            wellbeing: .init(mood: value, firstAnsweredAt: ["Mood": date.addingTimeInterval(delay)]))
    }

    func testTargetsUseTheirOwnMetricAndSample() {
        XCTAssertEqual(JournalInsightTarget.allCases.map(\.metric), [.recoveryScore, .hrvRMSSD, .deepSleepMinutes, .restingHeartRate, .mood])
        let metric = HabitMetricEstimate(metricID: .mood, yesMean: 4, noMean: 3, rawDifference: 1,
            adjustedDifference: 0.8, intervalLower: 0.4, intervalUpper: 1.2,
            adjustedRowCount: 28, isClear: true,
            sample: .init(yesCount: 18, noCount: 19, status: .clearAssociation, validThrough: day(40)))
        let estimate = HabitImpactEstimate(habitID: definition.id, status: .collecting, yesCount: 1, noCount: 0,
            eligibleDayCount: 1, excludedDayCount: 36, metrics: [metric], windowStart: day(0), windowEnd: day(40), calculatedAt: start)
        let row = JournalInsightRow(definition: definition, target: .mood, estimate: estimate)
        XCTAssertEqual(row.status, .clearAssociation)
        XCTAssertEqual(row.difference, 0.8)
        XCTAssertTrue(row.evidence.contains("18 days with, 19 without"))
        XCTAssertTrue(row.detail.hasPrefix("Mood was "))
        XCTAssertTrue(row.detail.contains("points higher"))
        let absent = JournalInsightRow(definition: definition, target: .hrv, estimate: estimate)
        XCTAssertEqual(absent.status, .unavailable)
        XCTAssertNil(absent.difference)
        XCTAssertFalse(absent.evidence.contains("1 days"))
    }

    func testMoodUsesTheNextRecordedCivilDayWithoutInventingSleep() throws {
        let outcome = try XCTUnwrap(JournalMoodOutcomes.merge(records: [rated(1)], outcomes: [],
            builtAt: start.addingTimeInterval(3 * 86400)).first)
        XCTAssertEqual(outcome.behaviorDay, day(0))
        XCTAssertEqual(outcome.outcomeDay, day(1))
        XCTAssertEqual(outcome.metrics, [.mood: 4])
        XCTAssertNil(outcome.sleepSessionID)
        XCTAssertNil(outcome.sleepStartedAt)
        XCTAssertNil(outcome.sleepEndedAt)
        XCTAssertEqual(outcome.sourceVersions["journal.mood"], "rating.v1")
        let reopened = try JSONDecoder().decode(HabitOutcomeSnapshot.self, from: JSONEncoder().encode(outcome))
        XCTAssertEqual(reopened, outcome)
    }

    func testMissingLateFutureAndTimezoneConflictedMoodStayAbsent() {
        var missingTime = rated(1)
        missingTime.wellbeing?.firstAnsweredAt = nil
        let now = start.addingTimeInterval(6 * 86400)
        XCTAssertTrue(JournalMoodOutcomes.merge(records: [missingTime], outcomes: [], builtAt: now).isEmpty)
        XCTAssertTrue(JournalMoodOutcomes.merge(records: [rated(1, delay: 4 * 86400)], outcomes: [], builtAt: now).isEmpty)
        XCTAssertTrue(JournalMoodOutcomes.merge(records: [rated(1)], outcomes: [], builtAt: start).isEmpty)
        let oldZone = HabitDayRecord(behaviorDay: day(0), behaviorTimeZoneID: "UTC", createdAt: start)
        XCTAssertTrue(JournalMoodOutcomes.merge(records: [oldZone, rated(1)], outcomes: [], builtAt: now).isEmpty)
        let oldMood = HabitOutcomeSnapshot(behaviorDay: day(0), behaviorTimeZoneID: zone, outcomeDay: day(1),
            metrics: [.mood: 5, .hrvRMSSD: 55], priorDayStrain: nil, sourceVersions: [:], builtAt: start)
        XCTAssertEqual(JournalMoodOutcomes.merge(records: [], outcomes: [oldMood], builtAt: now).first?.metrics, [.hrvRMSSD: 55])
    }

    func testEngineCountsAndClassifiesMoodIndependentlyOfRecoveryThenRetainsStaleResult() async throws {
        let store = try makeStore()
        let now = start.addingTimeInterval(72 * 86400)
        let engine = HabitInsightEngine(policy: shortBootstrapPolicy)
        let estimates = try await engine.recalculateAll(store: store, calculatedAt: now)
        let estimate = try XCTUnwrap(estimates.first)
        let mood = try XCTUnwrap(estimate.metric(.mood))
        XCTAssertEqual(mood.sample?.yesCount, 35)
        XCTAssertEqual(mood.sample?.noCount, 35)
        XCTAssertEqual(estimate.metric(.recoveryScore)?.sample?.yesCount, 7)
        XCTAssertEqual(estimate.metric(.recoveryScore)?.sample?.noCount, 7)
        XCTAssertEqual(estimate.metric(.recoveryScore)?.sample?.status, .earlySignal)
        XCTAssertEqual(mood.rawDifference, 2)
        XCTAssertNotNil(mood.adjustedPValue)
        XCTAssertTrue([.clearAssociation, .noClearAssociation].contains(mood.sample!.status))
        for var record in await store.dayRecords() where record.behaviorDay.habitKey > day(3).habitKey {
            record.responses = []
            try await store.saveDayRecord(record)
        }
        let refreshed = try await engine.recalculateAll(store: store, calculatedAt: now)
        let stale = try XCTUnwrap(refreshed.first?.metric(.mood))
        XCTAssertEqual(stale.sample?.status, .stale)
        XCTAssertEqual(stale.sample?.yesCount, 2)
        XCTAssertEqual(stale.sample?.noCount, 2)
        XCTAssertEqual(stale.sample?.validThrough, mood.sample?.validThrough)
        XCTAssertEqual(stale.adjustedDifference, mood.adjustedDifference)
        XCTAssertFalse(stale.isClear)
        XCTAssertNil(JournalInsightRow(definition: definition, target: .mood, estimate: refreshed.first).difference)
    }

    func testOverlapIsCheckedForMoodEvenWithoutRecovery() async throws {
        let store = try makeStore(includeRecovery: false, overlapping: true)
        let result = try await HabitInsightEngine(policy: shortBootstrapPolicy).recalculateAll(
            store: store, calculatedAt: start.addingTimeInterval(72 * 86400))
        for estimate in result {
            XCTAssertEqual(estimate.metric(.mood)?.sample?.status, .cannotSeparate)
            XCTAssertNotNil(estimate.metric(.mood)?.sample?.overlappingHabitID)
            XCTAssertFalse(estimate.metric(.mood)?.isClear ?? true)
        }
    }

    func testCancelledCalculationDoesNotPublishEstimates() async throws {
        let store = try makeStore()
        let now = start.addingTimeInterval(72 * 86400)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await HabitInsightEngine().recalculateAll(store: store, calculatedAt: now)
        }
        do { _ = try await task.value; XCTFail("Cancellation must propagate") }
        catch is CancellationError { }
        let estimates = await store.estimates()
        XCTAssertTrue(estimates.isEmpty)
    }

    func testGatePreventsPreparationAndFailureKeepsTheLastComparison() async throws {
        let store = try makeStore()
        let model = HabitViewModel(store: store, featureStageOverride: .disabled,
            prepareInsights: { throw JournalAutoFillError.invalidEvidence })
        await model.refreshInsights()
        XCTAssertNil(model.errorMessage)
        let previous = HabitImpactEstimate(habitID: definition.id, status: .noClearAssociation,
            yesCount: 20, noCount: 21, eligibleDayCount: 41, excludedDayCount: 0,
            windowStart: day(0), windowEnd: day(40), calculatedAt: start)
        await store.saveEstimate(previous)
        let enabled = HabitViewModel(store: store, featureStageOverride: .public,
            prepareInsights: { throw JournalAutoFillError.invalidEvidence })
        await enabled.load()
        await enabled.refreshInsights()
        XCTAssertNotNil(enabled.errorMessage)
        XCTAssertFalse(enabled.isRefreshingInsights)
        let estimates = await store.estimates()
        XCTAssertEqual(estimates, [previous])
        XCTAssertEqual(enabled.estimates, [previous])
    }

    private func makeStore(includeRecovery: Bool = true, overlapping: Bool = false) throws -> InMemoryHabitStore {
        let other = HabitDefinition(id: .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000001502")!),
            source: .custom, name: "Other habit", question: "Other habit?", sortOrder: 1, createdAt: start)
        let definitions = overlapping ? [definition, other] : [definition]
        var records: [HabitDayRecord] = []
        var outcomes: [HabitOutcomeSnapshot] = []
        for index in 0...70 {
            let date = start.addingTimeInterval(Double(index) * 86400)
            let value: JournalRating = (index - 1).isMultiple(of: 2) ? .four : .two
            var record = rated(index, value: value)
            if index == 0 { record.wellbeing = nil }
            if index < 70 {
                record.responses = definitions.map {
                    .init(habitID: $0.id, behaviorDay: day(index), behaviorTimeZoneID: zone,
                        answer: index.isMultiple(of: 2) ? .yes : .no, firstAnsweredAt: date.addingTimeInterval(21 * 3600), firstAnswerSource: .sameDay)
                }
            }
            records.append(record)
            if includeRecovery && index < 14 {
                outcomes.append(.init(behaviorDay: day(index), behaviorTimeZoneID: zone, sleepSessionID: "night-\(index)",
                    sleepStartedAt: date.addingTimeInterval(23 * 3600), sleepEndedAt: date.addingTimeInterval(31 * 3600),
                    outcomeDay: day(index + 1), metrics: [.recoveryScore: index.isMultiple(of: 2) ? 70 : 60],
                    priorDayStrain: nil, sourceVersions: [:], builtAt: date))
            }
        }
        return InMemoryHabitStore(definitions: definitions, dayRecords: records, outcomes: outcomes)
    }
    private var shortBootstrapPolicy: HabitImpactPolicy {
        let p = HabitImpactPolicy.default
        return .init(algorithmVersion: p.algorithmVersion, windowDays: p.windowDays, earlyPerGroup: p.earlyPerGroup,
            maturePerGroup: p.maturePerGroup, matureEligibleDays: p.matureEligibleDays, minimumAdjustedRows: p.minimumAdjustedRows,
            trailingBaselineDays: p.trailingBaselineDays, minimumBaselineDays: p.minimumBaselineDays, ridgeLambda: p.ridgeLambda,
            bootstrapReplicates: 40, bootstrapBlockDays: p.bootstrapBlockDays, overlapPhiThreshold: p.overlapPhiThreshold,
            minimumDiscordantDays: p.minimumDiscordantDays, practicalThresholds: p.practicalThresholds)
    }
}
