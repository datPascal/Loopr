import Foundation
import XCTest
@testable import WorkoutKit

/// The WOD clock's timing, the undo for a Finish tapped by mistake (R3-WOD-01) and its sound cues (R3-WOD-02).
final class WODClockTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func forTime(cap minutes: Int? = nil) -> WODClock {
        WODClock(setup: WODClockSetup(kind: .forTime, limitSeconds: minutes.map { $0 * 60 }), startedAt: start)
    }

    func testForTimeCountsUpAfterTheLeadIn() {
        let clock = forTime()
        XCTAssertEqual(clock.reading(at: start.addingTimeInterval(1)).phase, .leadIn(2))
        let running = clock.reading(at: start.addingTimeInterval(3 + 306))
        XCTAssertEqual(running.phase, .running)
        XCTAssertEqual(running.displaySeconds, 306)
    }

    func testFinishTappedByMistakeCanBeTakenBack() {
        var clock = forTime()
        clock.addRound()
        clock.finish(at: start.addingTimeInterval(3 + 120))
        XCTAssertTrue(clock.isOver(at: start.addingTimeInterval(3 + 125)))
        clock.resume(at: start.addingTimeInterval(3 + 125))
        let reading = clock.reading(at: start.addingTimeInterval(3 + 130))
        XCTAssertEqual(reading.phase, .running)
        XCTAssertEqual(reading.displaySeconds, 130)
        XCTAssertEqual(clock.rounds, 1)
    }

    func testAClockThatRanOutOfTimeStaysOver() {
        var clock = forTime(cap: 1)
        clock.finish(at: start.addingTimeInterval(3 + 90))
        clock.resume(at: start.addingTimeInterval(3 + 90))
        XCTAssertTrue(clock.isOver(at: start.addingTimeInterval(3 + 91)))
    }

    func testCuesForTheCountInMinutesLastTenSecondsAndEnd() {
        let clock = forTime(cap: 2)
        func reading(_ seconds: Double) -> WODClockReading { clock.reading(at: start.addingTimeInterval(seconds)) }
        XCTAssertEqual(clock.cue(from: nil, to: reading(0)), .tick)
        XCTAssertNil(clock.cue(from: reading(0.2), to: reading(0.4)))
        XCTAssertEqual(clock.cue(from: reading(2.9), to: reading(3.1)), .go)
        XCTAssertEqual(clock.cue(from: reading(3 + 59.9), to: reading(3 + 60.1)), .minute)
        XCTAssertNil(clock.cue(from: reading(3 + 30.9), to: reading(3 + 31.1)))
        XCTAssertEqual(clock.cue(from: reading(3 + 110.9), to: reading(3 + 111.1)), .tick)
        XCTAssertEqual(clock.cue(from: reading(3 + 119.9), to: reading(3 + 120.1)), .end)
        XCTAssertNil(clock.cue(from: reading(3 + 120.1), to: reading(3 + 121)))
    }
}
