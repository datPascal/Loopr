import Foundation
import WorkoutKit
import XCTest

final class WorkoutListingRowTests: XCTestCase {
    private func record(startedAt: Date, distances: [Double?]) -> WorkoutRecord {
        let samples = distances.enumerated().map { index, distance in
            WorkoutSample(
                timestamp: startedAt.addingTimeInterval(TimeInterval(index)),
                heartRate: 120 + index % 20,
                zone: 2,
                strain: 0.1,
                energyKcal: 0.2,
                distanceMeters: distance
            )
        }
        return WorkoutRecord(
            id: UUID(),
            identity: WorkoutIdentity(canonicalKey: "test:\(startedAt.timeIntervalSince1970)"),
            activity: .run,
            source: .live,
            state: .completed,
            createdAt: startedAt,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(TimeInterval(distances.count)),
            samples: samples,
            checkpointNumber: 3,
            lastCheckpointAt: startedAt.addingTimeInterval(10),
            finalizationStage: .activeStateCleared
        )
    }

    func test_listingRowKeepsEveryFieldAndOnlyTheNewestDistanceSample() {
        let full = record(startedAt: Date(timeIntervalSince1970: 1_700_000_000), distances: [nil, 10, 25, nil, 40, nil])
        let row = full.listingRow
        XCTAssertEqual(row.samples, [WorkoutSample(timestamp: full.samples[4].timestamp, distanceMeters: 40)])
        var expected = full
        expected.samples = row.samples
        XCTAssertEqual(row, expected)
    }

    func test_listingRowWithoutDistanceHasNoSamples() {
        let full = record(startedAt: Date(timeIntervalSince1970: 1_700_000_000), distances: [nil, nil])
        XCTAssertTrue(full.listingRow.samples.isEmpty)
    }

    func test_documentDecodeMatchesListingRow() throws {
        let full = record(startedAt: Date(timeIntervalSince1970: 1_700_000_000), distances: Array(repeating: nil, count: 50) + [12.5, 30, nil])
        let encoded = try JSONEncoder().encode(full)
        let decoded = try JSONDecoder().decode(WorkoutListingRowDocument.self, from: encoded)
        XCTAssertEqual(decoded.row, full.listingRow)
    }

    func test_defaultStoreListingFiltersToTheQueryAndStripsSamples() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let recent = record(startedAt: now.addingTimeInterval(-3_600), distances: [5, 9])
        let old = record(startedAt: now.addingTimeInterval(-200 * 86_400), distances: [5])
        let store = InMemoryWorkoutStore(workouts: [recent, old])
        let rows = await store.listingRows(WorkoutLogQuery(range: .threeMonths, now: now))
        XCTAssertEqual(rows, [recent.listingRow])
    }

    @MainActor
    func test_viewModelLoadsListingRows() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let first = record(startedAt: now.addingTimeInterval(-3_600), distances: [5, 9])
        let store = InMemoryWorkoutStore(workouts: [first])
        let controller = WorkoutSessionController(store: store)
        let viewModel = WorkoutViewModel(controller: controller)
        await viewModel.load(query: WorkoutLogQuery(range: .threeMonths, now: now), detail: .listing)
        let loaded = viewModel.snapshot.value
        XCTAssertEqual(loaded, [first.listingRow])
    }

    func test_listSectionsCallOnlyThisCalendarWeekThisWeek() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        // Thursday 16 Nov 2023, 12:00 UTC. The week starts Monday 13 Nov.
        let now = Date(timeIntervalSince1970: 1_700_136_000)
        let monday = record(startedAt: now.addingTimeInterval(-3 * 86_400 + 3_600), distances: [])
        let lastSunday = record(startedAt: now.addingTimeInterval(-4 * 86_400), distances: [])
        let lastMonth = record(startedAt: now.addingTimeInterval(-40 * 86_400), distances: [])
        let sections = WorkoutListSections(workouts: [monday, lastSunday, lastMonth], now: now, calendar: calendar)
        XCTAssertEqual(sections.thisWeek, [monday])
        XCTAssertEqual(sections.earlier, [lastSunday, lastMonth])
        XCTAssertEqual(sections.headerMeta, "1 THIS WEEK")
        XCTAssertEqual(
            WorkoutListSections(workouts: [lastMonth], now: now, calendar: calendar).headerMeta,
            "NO WORKOUTS THIS WEEK"
        )
    }
}
