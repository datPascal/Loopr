import Testing
@testable import DesignSystem

struct StorageBreakdownTests {
    @Test func distributionPreservesRatiosAndHandlesEmptyAndNegativeSizes() {
        let segments: [LooprStorageSegment] = [
            .init(id: "band", title: "Band", bytes: 300, accent: .heart),
            .init(id: "journal", title: "Journal", bytes: 100, accent: .cyclePlum),
            .init(id: "other", title: "Other", bytes: -50, accent: .inkSecondary)
        ]
        #expect(LooprStorageSegment.shares(segments) == [0.75, 0.25, 0])
        #expect(LooprStorageSegment.shares([]).isEmpty)
        #expect(LooprStorageSegment.shares([segments[2]]) == [0])
    }
}
