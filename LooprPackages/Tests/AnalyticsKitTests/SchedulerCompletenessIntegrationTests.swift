import AnalyticsKit
import XCTest

final class SchedulerCompletenessIntegrationTests: XCTestCase {
    func testPruningWaitsForEveryCanonicalFamilyGeneration() async {
        let registry = DerivationCompletenessRegistry()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let day = now.addingTimeInterval(-5 * 86_400)
        await registry.setRawSubstrate(
            day: day,
            isComplete: true,
            isDurable: true,
            isVersioned: true
        )
        for family in AnalyticsMetricFamily.pruningFamilies where family != .workout {
            await registry.record(day: day, family: family, state: .complete)
        }
        let incomplete = await registry.state(for: day)
        XCTAssertFalse(incomplete?.isComplete ?? true)
        XCTAssertFalse(incomplete?.allRequiredFamiliesComplete ?? true)

        await registry.record(day: day, family: .workout, state: .complete)
        let complete = await registry.state(for: day)
        XCTAssertTrue(complete?.isComplete ?? false)
        XCTAssertTrue(complete?.allRequiredFamiliesComplete ?? false)

        let scheduler = DerivationScheduler(
            pipeline: EmptyDerivationPipeline(),
            store: InMemoryDerivationStore(),
            stateProvider: registry,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        let prunable = await scheduler.isDayPrunable(day: day, now: now)
        XCTAssertTrue(prunable)
    }

    func testFailedOrUndecodableFamilyBlocksPruningEvenWhenOthersAreComplete() async {
        let registry = DerivationCompletenessRegistry()
        let day = Date(timeIntervalSince1970: 2_000_000_000)
        await registry.setRawSubstrate(day: day, isComplete: true, isDurable: true, isVersioned: true)
        for family in AnalyticsMetricFamily.pruningFamilies {
            await registry.record(
                day: day,
                family: family,
                state: family == .sleep
                    ? DerivationFamilyState(isComplete: false, isDurable: true, isVersioned: true, isDecodable: false, hasFailed: true)
                    : .complete
            )
        }
        let state = await registry.state(for: day)
        XCTAssertFalse(state?.isComplete ?? true)
        XCTAssertTrue(state?.hasFailed ?? false)
        XCTAssertTrue(state?.isPartial ?? false)
    }
}
