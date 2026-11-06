import Foundation
import Testing
@testable import DesignSystem

@MainActor
struct MetricTrendTileTests {
    @Test func unavailableStatesNeverAnnounceACachedNumber() {
        for state in [MetricState.loading, .noRecords, .absent, .recoverableError, .destructiveFailure] {
            let tile = LooprMetricTrendTile(title: "HRV", value: "61", unit: "ms", points: [],
                endingOn: Date(), accent: .heart, state: state)
            #expect(tile.displayedValue == nil)
            #expect(!tile.accessibilitySummary.contains("61"))
            #expect(tile.accessibilitySummary.contains(state.title))
        }
    }

    @Test func measuredZeroAndMissingStayDistinct() {
        let zero = LooprMetricTrendTile(title: "Steps", value: "0", points: [],
            endingOn: Date(), accent: .movement, state: .measuredZero)
        let missing = LooprMetricTrendTile(title: "Steps", value: nil, points: [],
            endingOn: Date(), accent: .movement, state: .absent)
        #expect(zero.displayedValue == "0")
        #expect(zero.accessibilitySummary.contains("Measured zero"))
        #expect(missing.displayedValue == nil)
        #expect(missing.accessibilitySummary == "Steps, Not measured")
    }
}
