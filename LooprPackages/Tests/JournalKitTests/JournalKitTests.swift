import Foundation
import JournalKit
import DomainKit
import XCTest

final class JournalKitTests: XCTestCase {
    func testCreateEditSearchHistoryAndDeleteAreDurable() async throws {
        let repo = JournalRepository()
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        _ = try await repo.create(day: "2026-08-18", tags: ["coffee"], note: "Late cup", id: id)
        _ = try await repo.edit(id: id, tags: ["coffee", "late"], note: "Updated")
        let hits = await repo.search(.init(text: "updated"))
        XCTAssertEqual(hits.map(\.id), [id])
        try await repo.delete(id: id)
        let history = await repo.history()
        XCTAssertTrue(history.isEmpty)
    }

    func testJournalContentIsExcludedUnlessExplicitlySelected() async throws {
        let repo = JournalRepository()
        let entry = try await repo.create(day: "2026-08-18", tags: ["private"], note: "Sensitive")
        let redacted = await repo.redactedSnapshot()
        XCTAssertTrue(redacted.entries.isEmpty)
        let selected = JournalPrivacyPayload(entries: [entry]).forAIContext(selected: [entry.id])
        XCTAssertEqual(selected.entries, [entry])
        let export = await repo.export(includeContent: false)
        XCTAssertFalse(export.includesJournalContent)
    }

    func testHabitStoreEnforcesTenActiveBinaryHabits() async throws {
        let store = InMemoryHabitStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<HabitStoreValidator.activeLimit {
            try await store.saveDefinition(HabitDefinition(
                id: HabitID(rawValue: UUID()),
                source: .custom,
                name: "Habit \(index)",
                question: "Did habit \(index) happen?",
                sortOrder: index,
                createdAt: now
            ))
        }
        do {
            try await store.saveDefinition(HabitDefinition(
                id: HabitID(rawValue: UUID()),
                source: .custom,
                name: "Eleventh",
                question: "Did the eleventh habit happen?",
                sortOrder: 10,
                createdAt: now
            ))
            XCTFail("the active habit limit must be enforced")
        } catch HabitStoreError.activeLimitReached {}
    }

    func testAIProposalRequiresReview() async throws {
        let repo = JournalRepository()
        let proposal = JournalProposal(day: "2026-08-18", tags: ["walk"], note: "Suggested")
        do {
            _ = try await repo.saveProposal(proposal, accepted: true)
            XCTFail("proposal must require explicit review")
        } catch JournalError.proposalNotReviewed { }
        await repo.approve(proposal)
        let saved = try await repo.saveProposal(proposal, accepted: true)
        XCTAssertNotNil(saved)
    }

    func testJournalFixtureAndTypedPrivacyDestinationExist() {
        XCTAssertEqual(JournalFixtures.privateEntry.day, "2026-08-18")
        XCTAssertTrue(JournalFixtures.privateEntry.tags.contains("private"))
        XCTAssertTrue(JournalRoute.fixtures.contains(.privacy))
        XCTAssertTrue(JournalRoute.fixtures.contains(.habitInsights))
    }

    func testJournalScreenStateMatrixAndAccessibilityFixtures() {
        XCTAssertEqual(JournalScreenStateFixtures.allStates.count, 14)
        XCTAssertTrue(JournalScreenStateFixtures.statesByScreen.values.allSatisfy { $0.count == 14 })
        XCTAssertNotEqual(JournalScreenStateFixtures.accessibilitySummary(for: .absent), JournalScreenStateFixtures.accessibilitySummary(for: .measuredZero))
        XCTAssertTrue(JournalScreenStateFixtures.accessibilityIdentifiers.allSatisfy { !$0.isEmpty })
    }

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

    func testExportOptInAndDeletionRemovePrivateEntry() async throws {
        let repo = JournalRepository()
        let entry = try await repo.create(day: "2026-08-18", tags: ["rest"], note: "private text")
        let redacted = await repo.export(includeContent: false)
        XCTAssertEqual(redacted.entries.first?.note, nil)
        let selected = await repo.export(includeContent: true)
        XCTAssertEqual(selected.entries.first?.note, "private text")
        try await repo.delete(id: entry.id)
        let deletedEntry = await repo.entry(id: entry.id)
        XCTAssertNil(deletedEntry)
    }

    func testCheckInPreservesFirstAnswerAndTreatsSkipAsExcluded() async throws {
        let habit = HabitDefinition(
            id: HabitID(rawValue: UUID()), source: .custom,
            name: "Late meal", question: "Did you eat late?", sortOrder: 0,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let store = InMemoryHabitStore(definitions: [habit])
        let service = HabitCheckInService(store: store)
        let day = DayIdentity(year: 2026, month: 8, day: 29)
        try await service.answer(
            habitID: habit.id, day: day, timeZoneID: "Asia/Bangkok",
            answer: .yes, source: .morningCheckIn
        )
        let firstRecord = await store.dayRecord(for: day)
        let first = try XCTUnwrap(firstRecord?.response(for: habit.id))
        try await service.answer(
            habitID: habit.id, day: day, timeZoneID: "Asia/Bangkok",
            answer: .skipped, source: .historyEdit
        )
        let editedRecord = await store.dayRecord(for: day)
        let edited = try XCTUnwrap(editedRecord?.response(for: habit.id))
        XCTAssertEqual(edited.firstAnsweredAt, first.firstAnsweredAt)
        XCTAssertEqual(edited.firstAnswerSource, .morningCheckIn)
        XCTAssertEqual(edited.lastUpdateSource, .historyEdit)
        XCTAssertEqual(HabitEligibility.exclusion(for: edited), .skipped)
    }

    func testHabitPrivacyRequiresExplicitHabitAndDaySelection() {
        let definition = HabitFixtures.definition
        let response = HabitResponse(
            habitID: definition.id,
            behaviorDay: HabitFixtures.day,
            behaviorTimeZoneID: "Asia/Bangkok",
            answer: .yes,
            firstAnsweredAt: HabitFixtures.now,
            firstAnswerSource: .sameDay
        )
        let dayRecord = HabitDayRecord(
            behaviorDay: HabitFixtures.day,
            behaviorTimeZoneID: "Asia/Bangkok",
            responses: [response],
            createdAt: HabitFixtures.now
        )
        let payload = JournalPrivacyPayload(
            habitDefinitions: [definition],
            habitDayRecords: [dayRecord]
        )
        XCTAssertTrue(payload.forAIContext().habitDefinitions.isEmpty)
        let selected = payload.forAIContext(
            selectedHabits: [definition.id],
            dayRange: "2026-08-29"..."2026-08-29"
        )
        XCTAssertEqual(selected.habitDefinitions, [definition])
        XCTAssertEqual(selected.habitDayRecords.count, 1)
    }

    func testCleanInstallKeepsRemindersOffAndTodayDisabled() {
        let settings = HabitSettings()
        XCTAssertFalse(settings.reminderEnabled)
        XCTAssertEqual(settings.featureStage, .internalOnly)
        XCTAssertFalse(settings.featureStage.enablesToday)
    }

    func testOutcomeResolverExclusionReasonSurvivesInsightRecalculation() async throws {
        let day = DayIdentity(year: 2026, month: 8, day: 29)
        let now = Date(timeIntervalSince1970: 1_777_500_000)
        let definition = HabitDefinition(
            id: HabitID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!),
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
            answer: .yes,
            firstAnsweredAt: try XCTUnwrap(HabitEligibility.deadline(
                for: day,
                timeZoneID: "Asia/Bangkok"
            )),
            firstAnswerSource: .sameDay
        )
        let record = HabitDayRecord(
            behaviorDay: day,
            behaviorTimeZoneID: "Asia/Bangkok",
            responses: [response],
            createdAt: now
        )
        let store = InMemoryHabitStore(definitions: [definition], dayRecords: [record])
        await store.saveOutcomeExclusion(.init(
            behaviorDay: day,
            reason: .partialSleep,
            resolvedAt: now
        ))

        let estimates = try await HabitInsightEngine().recalculateAll(store: store, calculatedAt: now)

        let estimate = try XCTUnwrap(estimates.first)
        XCTAssertEqual(estimate.status, .unavailable)
        XCTAssertEqual(estimate.exclusions, [.init(day: day, reason: .partialSleep)])
        XCTAssertEqual(estimate.excludedDayCount, 1)
    }

    func testTodaySelectionIsRecoveryFirstStableAndRetainedForLessThanSevenDays() throws {
        let calculatedAt = Date(timeIntervalSince1970: 1_777_500_000)
        let recoveryID = HabitID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000201")!)
        let narrowSleepID = HabitID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000202")!)
        let wideSleepID = HabitID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000203")!)
        let recovery = impactEstimate(
            id: recoveryID,
            status: .clearAssociation,
            metric: clearMetric(.recoveryScore, effect: -4, lower: -8, upper: -1),
            calculatedAt: calculatedAt
        )
        let narrowSleep = impactEstimate(
            id: narrowSleepID,
            status: .noClearAssociation,
            metric: clearMetric(.sleepScore, effect: 4, lower: 3, upper: 5),
            calculatedAt: calculatedAt
        )
        let wideSleep = impactEstimate(
            id: wideSleepID,
            status: .noClearAssociation,
            metric: clearMetric(.sleepScore, effect: 4, lower: 0, upper: 8),
            calculatedAt: calculatedAt.addingTimeInterval(60)
        )

        let ranked = HabitTodaySelectionPolicy.ranked([wideSleep, narrowSleep, recovery])
        XCTAssertEqual(ranked.map(\.estimate.habitID), [recoveryID, narrowSleepID, wideSleepID])

        let selection = HabitTodaySelection(habitID: recoveryID, selectedAt: calculatedAt)
        XCTAssertTrue(HabitTodaySelectionPolicy.shouldRetain(
            selection,
            at: calculatedAt.addingTimeInterval(HabitTodaySelectionPolicy.retentionInterval - 1)
        ))
        XCTAssertFalse(HabitTodaySelectionPolicy.shouldRetain(
            selection,
            at: calculatedAt.addingTimeInterval(HabitTodaySelectionPolicy.retentionInterval)
        ))
        XCTAssertFalse(HabitTodaySelectionPolicy.shouldRetain(
            selection,
            at: calculatedAt.addingTimeInterval(-1)
        ))
    }

    func testHabitTelemetryUsesOnlyTheApprovedPayloadForEveryEvent() throws {
        for name in HabitTelemetryEventName.allCases {
            let data = try HabitTelemetryEvent(
                name: name,
                appVersion: "1.0",
                activeCountBucket: .fourToSix,
                routeSource: .journal
            ).encoded()
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(Set(object.keys), HabitTelemetryEvent.allowedEncodedKeys, "Unexpected payload for \(name)")
        }
    }

    func testEligibilityDeadlineAddsElapsedHoursAcrossDSTChanges() throws {
        let springDay = DayIdentity(year: 2026, month: 3, day: 8)
        let fallDay = DayIdentity(year: 2026, month: 11, day: 1)
        let zone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let springStart = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8)))
        let fallStart = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1)))
        let springDeadline = try XCTUnwrap(HabitEligibility.deadline(for: springDay, timeZoneID: zone.identifier))
        let fallDeadline = try XCTUnwrap(HabitEligibility.deadline(for: fallDay, timeZoneID: zone.identifier))

        XCTAssertEqual(springDeadline.timeIntervalSince(springStart), 71 * 60 * 60, accuracy: 0.001)
        XCTAssertEqual(fallDeadline.timeIntervalSince(fallStart), 73 * 60 * 60, accuracy: 0.001)

        let onDeadline = HabitResponse(
            habitID: HabitFixtures.definition.id,
            behaviorDay: springDay,
            behaviorTimeZoneID: zone.identifier,
            answer: .yes,
            firstAnsweredAt: springDeadline,
            firstAnswerSource: .historyEdit
        )
        var afterDeadline = onDeadline
        afterDeadline = HabitResponse(
            habitID: onDeadline.habitID,
            behaviorDay: onDeadline.behaviorDay,
            behaviorTimeZoneID: onDeadline.behaviorTimeZoneID,
            answer: onDeadline.answer,
            firstAnsweredAt: springDeadline.addingTimeInterval(0.001),
            firstAnswerSource: onDeadline.firstAnswerSource
        )
        XCTAssertNil(HabitEligibility.exclusion(for: onDeadline))
        XCTAssertEqual(HabitEligibility.exclusion(for: afterDeadline), .lateFirstEntry)
    }

    func testRestoreRejectsInvalidCivilDaysAndEmptyRecordsWithInvalidTimeZones() {
        let definition = HabitFixtures.definition
        let invalidDay = HabitDayRecord(
            behaviorDay: DayIdentity(year: 2026, month: 2, day: 30),
            behaviorTimeZoneID: "Asia/Bangkok",
            createdAt: HabitFixtures.now
        )
        XCTAssertThrowsError(try HabitStoreValidator.validateRestore(
            definitions: [definition],
            records: [invalidDay]
        )) { XCTAssertEqual($0 as? HabitStoreError, .invalidDay) }

        let invalidZone = HabitDayRecord(
            behaviorDay: HabitFixtures.day,
            behaviorTimeZoneID: "Not/A_Time_Zone",
            createdAt: HabitFixtures.now
        )
        XCTAssertThrowsError(try HabitStoreValidator.validateRestore(
            definitions: [definition],
            records: [invalidZone]
        )) { XCTAssertEqual($0 as? HabitStoreError, .timeZoneMismatch) }
    }

    func testDeletingDerivedAndAllHabitDataClearsExclusionsAndTodaySelection() async throws {
        let store = InMemoryHabitStore(
            definitions: [HabitFixtures.definition],
            outcomeExclusions: [.init(
                behaviorDay: HabitFixtures.day,
                reason: .missingMetric,
                resolvedAt: HabitFixtures.now
            )],
            todaySelection: .init(habitID: HabitFixtures.definition.id, selectedAt: HabitFixtures.now)
        )
        await store.deleteDerivedData()
        let derivedExclusions = await store.outcomeExclusions()
        let derivedSelection = await store.todaySelection()
        XCTAssertTrue(derivedExclusions.isEmpty)
        XCTAssertNil(derivedSelection)

        await store.saveOutcomeExclusion(.init(
            behaviorDay: HabitFixtures.day,
            reason: .missingMainSleep,
            resolvedAt: HabitFixtures.now
        ))
        await store.deleteAllHabitData()
        let allExclusions = await store.outcomeExclusions()
        XCTAssertTrue(allExclusions.isEmpty)
    }

    private func clearMetric(
        _ metricID: HabitOutcomeMetricID,
        effect: Double,
        lower: Double,
        upper: Double
    ) -> HabitMetricEstimate {
        HabitMetricEstimate(
            metricID: metricID,
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

    private func impactEstimate(
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
