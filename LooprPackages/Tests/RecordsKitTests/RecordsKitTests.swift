import RecordsKit
import XCTest

final class RecordsKitTests: XCTestCase {
    func testPersonalRecordsSelectCommittedMaximumAndTimelineDeduplicatesIdentity() async {
        let repository = RecordsRepository()
        await repository.save(MetricSnapshot(day: "2026-08-16", metric: "steps", value: 8_000, algorithmVersion: 1))
        await repository.save(MetricSnapshot(day: "2026-08-17", metric: "steps", value: 12_000, algorithmVersion: 2))
        let records = await repository.personalRecords()
        XCTAssertEqual(records.first?.value, 12_000)
        XCTAssertEqual(records.first?.day, "2026-08-17")

        let original = TimelineEvent(kind: .workout, day: "2026-08-17", title: "Run", sourceID: "w-1")
        let correction = TimelineEvent(kind: .workout, day: "2026-08-17", title: "Run (corrected)", sourceID: "w-1", correctionProvenance: "reanalysis-v2")
        let merged = await repository.mergedTimeline([original, correction])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.title, "Run (corrected)")
    }

    func testStreakUsesLocalCalendarDaysAndRecapSurfacesDiscontinuities() async {
        let repository = RecordsRepository()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        for (day, version) in [("2026-08-16", 1), ("2026-08-17", 1), ("2026-08-18", 2)] {
            await repository.save(MetricSnapshot(day: day, metric: "steps", value: 10_000, algorithmVersion: version))
        }
        await repository.save(TimelineEvent(kind: .notableChange, day: "2026-08-18", title: "Corrected", sourceID: "c-1", correctionProvenance: "import"))
        let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 18))!
        let streak = await repository.streak(metric: "steps", qualifying: { $0.value >= 10_000 }, calendar: calendar, now: now)
        XCTAssertEqual(streak.length, 3)
        let recap = await repository.recap(period: .week, startDay: "2026-08-16", endDay: "2026-08-18")
        XCTAssertEqual(recap.algorithmDiscontinuities, [2])
        XCTAssertEqual(recap.correctionDays, ["2026-08-18"])
    }

    func testLocalDayNavigationIsDSTCorrectAndTimelineIdentityIsStable() async {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let beforeDST = calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 12))!
        let afterOneDay = LocalDayNavigator.addingDays(1, to: beforeDST, calendar: calendar)
        let afterTwoDays = LocalDayNavigator.addingDays(2, to: beforeDST, calendar: calendar)
        XCTAssertEqual(LocalDayNavigator.dayString(for: afterOneDay, calendar: calendar), "2026-03-08")
        XCTAssertEqual(LocalDayNavigator.dayString(for: afterTwoDays, calendar: calendar), "2026-03-09")
        XCTAssertNotEqual(afterOneDay.timeIntervalSince(beforeDST), 86_400)

        let repository = RecordsRepository()
        let events = [
            TimelineEvent(kind: .sleep, day: "2026-08-18", title: "Sleep", sourceID: "sleep-1"),
            TimelineEvent(kind: .workout, day: "2026-08-18", title: "Run", sourceID: "workout-1"),
            TimelineEvent(kind: .journal, day: "2026-08-18", title: "Journal", sourceID: "journal-1"),
            TimelineEvent(kind: .device, day: "2026-08-18", title: "Connected", sourceID: "device-1")
        ]
        let first = await repository.mergedTimeline(events)
        let second = await repository.mergedTimeline(events)
        XCTAssertEqual(first.map(\.id), second.map(\.id))
        XCTAssertEqual(Set(first.map(\.id)).count, 4)
    }

    func testShareCardDefaultsToPrivateContentOff() async {
        let repository = RecordsRepository()
        let card = await repository.shareCard(period: .month, startDay: "2026-08-01", endDay: "2026-08-31")
        XCTAssertFalse(card.includesPrivateContent)
        XCTAssertTrue(card.privateContent.isEmpty)
        let optedIn = await repository.shareCard(period: .month, startDay: "2026-08-01", endDay: "2026-08-31", options: RecordsShareOptions(includeJournal: true))
        XCTAssertTrue(optedIn.includesPrivateContent)
        XCTAssertEqual(optedIn.privateContent, ["journal"])
    }

    func testRecordsFixtureAndTypedDestinationsCoverCorrections() {
        XCTAssertNotNil(RecordsFixtures.correctionEvent.correctionProvenance)
        XCTAssertTrue(RecordsRoute.allCases.contains(.timeline))
        XCTAssertTrue(RecordsRoute.allCases.contains(.recap))
    }

    func testRecordsScreenStateMatrixAndAccessibilityFixtures() {
        XCTAssertEqual(RecordsScreenStateFixtures.allStates.count, 14)
        XCTAssertTrue(RecordsScreenStateFixtures.statesByScreen.values.allSatisfy { $0.count == 14 })
        XCTAssertNotEqual(RecordsScreenStateFixtures.accessibilitySummary(for: .absent), RecordsScreenStateFixtures.accessibilitySummary(for: .measuredZero))
        XCTAssertTrue(RecordsScreenStateFixtures.accessibilityIdentifiers.allSatisfy { !$0.isEmpty })
    }
}
