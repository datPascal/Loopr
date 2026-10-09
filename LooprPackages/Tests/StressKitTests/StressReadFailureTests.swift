import StressKit
import XCTest

private enum StressStoreFixtureError: Error { case readFailed }

/// A store whose canonical read fails. Before this the failure was swallowed
/// and the hero rendered an empty day, which is a different claim entirely.
private actor FailingReadStressStore: StressStore {
    func latestObservation() async -> StressObservation? { nil }
    func latestObservationChecked() async throws -> StressObservation? {
        throw StressStoreFixtureError.readFailed
    }
    func saveObservation(_ observation: StressObservation) async throws {}
    func spotChecks() async -> [SpotCheckResult] { [] }
    func saveSpotCheck(_ result: SpotCheckResult) async throws {}
    func breathingHistory() async -> [BreathingResult] { [] }
    func saveBreathingResult(_ result: BreathingResult) async throws {}
    func deleteAll() async {}
}

private actor EmptyStressStore: StressStore {
    func latestObservation() async -> StressObservation? { nil }
    func saveObservation(_ observation: StressObservation) async throws {}
    func spotChecks() async -> [SpotCheckResult] { [] }
    func saveSpotCheck(_ result: SpotCheckResult) async throws {}
    func breathingHistory() async -> [BreathingResult] { [] }
    func saveBreathingResult(_ result: BreathingResult) async throws {}
    func deleteAll() async {}
}

@MainActor
final class StressReadFailureTests: XCTestCase {
    func testFailedReadShowsAnErrorRatherThanAnEmptyDay() async {
        let viewModel = StressViewModel(store: FailingReadStressStore())
        await viewModel.refresh()
        XCTAssertEqual(viewModel.snapshot.state, .recoverableError)
        XCTAssertNil(viewModel.snapshot.stress)
    }

    func testDayWithNoDataStillReadsAsAbsent() async {
        let viewModel = StressViewModel(store: EmptyStressStore())
        await viewModel.refresh()
        XCTAssertEqual(viewModel.snapshot.state, .absent)
    }

    func testDefaultCheckedReadMatchesThePlainRead() async throws {
        let observation = StressObservation(day: "2026-09-21", value: 42, coverage: 0.9, confidence: 0.8)
        let store = InMemoryStressStore(observations: [observation])
        let checked = try await store.latestObservationChecked()
        XCTAssertEqual(checked?.day, observation.day)
    }

    func testMeasuredScoreKeepsItsSourceDay() async {
        let observation = StressObservation(day: "2026-09-23", value: 42, coverage: 0.9, confidence: 0.8)
        let viewModel = StressViewModel(store: InMemoryStressStore(observations: [observation]))
        await viewModel.refresh()
        XCTAssertEqual(viewModel.snapshot.day, observation.day)
        XCTAssertEqual(viewModel.snapshot.stress?.value, observation.value)
    }

    func testUnavailableLiveReadingHasAUsefulMessage() {
        XCTAssertEqual(
            StressError.liveUnavailable.localizedDescription,
            "A live reading is unavailable right now. Try again when your band is connected."
        )
    }
}
