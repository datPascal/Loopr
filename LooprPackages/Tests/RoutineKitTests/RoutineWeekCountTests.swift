import DomainKit
import Foundation
import RoutineKit
import Testing

/// ICP R2-DES-04, R2-VET-02: one function counts a week for the hero, the weekly review and the share pass.
@Suite("Routine week count")
struct RoutineWeekCountTests {
    @Test("Kept over answered; skipped, not known, pending and missing checks are left out")
    func countsKeptOverAnswered() {
        let count = RoutineWeekCount(states: [.kept, .kept, .missed, .skipped, .unknown, .pending, nil, .kept])
        #expect(count.kept == 3)
        #expect(count.missed == 1)
        #expect(count.skipped == 1)
        #expect(count.unknown == 1)
        #expect(count.decided == 4)
        #expect(count.percent == 75)
    }

    @Test("Nothing answered has no share, never 0 percent")
    func nothingAnswered() {
        #expect(RoutineWeekCount(states: [CheckState.skipped, .unknown, nil] as [CheckState?]).percent == nil)
        #expect(RoutineWeekCount(states: [CheckState?]()).percent == nil)
        #expect(RoutineWeekCount(states: [CheckState.missed] as [CheckState?]).percent == 0)
    }

    @Test("The share rounds to the nearest whole percent: 12 of 13 is 92, 58 of 60 is 97, 1 of 8 is 13")
    func rounds() {
        func percent(_ kept: Int, of decided: Int) -> Int? { RoutineWeekCount(kept: kept, missed: decided - kept).percent }
        #expect(percent(12, of: 13) == 92)
        #expect(percent(58, of: 60) == 97)
        #expect(percent(1, of: 8) == 13)
        #expect(percent(2, of: 3) == 67)
    }
}
