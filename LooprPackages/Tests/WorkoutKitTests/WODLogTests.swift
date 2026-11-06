import Foundation
import WorkoutKit
import XCTest

/// WOD scores, the ranking rules, benchmark history and the benchmark catalogue.
final class WODLogTests: XCTestCase {
    private func fran(_ seconds: Int?, daysAgo: Double, scaling: WODScaling = .rx, capped: WODScore? = nil) -> WorkoutRecord {
        let start = Date(timeIntervalSince1970: 1_699_927_200 - daysAgo * 86_400)
        let score = capped ?? seconds.map { WODScore.time(seconds: $0) }
        return WorkoutRecord(
            id: UUID(), identity: .init(canonicalKey: UUID().uuidString), activity: .crossfit, source: .manual,
            state: .completed, createdAt: start, startedAt: start, endedAt: start.addingTimeInterval(1_800),
            wod: WODResult(format: .forTime, name: daysAgo > 30 ? "fran" : "Fran", timeCapSeconds: 600, score: score,
                           capped: capped != nil, scaling: scaling))
    }

    func testClockTextAndParsing() {
        XCTAssertEqual(WODScore.parseClock("4:37"), 277)
        XCTAssertEqual(WODScore.parseClock("04:37"), 277)
        XCTAssertEqual(WODScore.parseClock("1:02:05"), 3_725)
        XCTAssertEqual(WODScore.parseClock("277"), 277)
        XCTAssertNil(WODScore.parseClock("4:75"))
        XCTAssertNil(WODScore.parseClock("4:"))
        XCTAssertNil(WODScore.parseClock("abc"))
        XCTAssertEqual(WODScore.clock(277), "4:37")
        XCTAssertEqual(WODScore.clock(3_725), "1:02:05")
    }

    func testScoreTextFollowsItsKind() {
        XCTAssertEqual(WODScore.time(seconds: 306).text, "5:06")
        XCTAssertEqual(WODScore.roundsAndReps(rounds: 5, reps: 12).text, "5 rounds + 12")
        XCTAssertEqual(WODScore.roundsAndReps(rounds: 1, reps: 0).text, "1 round")
        XCTAssertEqual(WODScore.reps(150).text, "150 reps")
        XCTAssertEqual(WODScore.load(kilograms: 60).text, "60 kg")
        let capped = WODResult(format: .forTime, timeCapSeconds: 720, score: .roundsAndReps(rounds: 4, reps: 10),
                               capped: true, scaling: .scaled)
        XCTAssertEqual(capped.scoreLine, "Capped at 12:00, 4 rounds + 10 Scaled")
    }

    func testFormatsChooseTheirScore() {
        XCTAssertEqual(WODFormat.forTime.scoreKind, .time)
        XCTAssertEqual(WODFormat.roundsForTime.scoreKind, .time)
        XCTAssertEqual(WODFormat.amrap.scoreKind, .roundsAndReps)
        XCTAssertEqual(WODFormat.emom.scoreKind, .reps)
        XCTAssertEqual(WODFormat.tabata.scoreKind, .reps)
        XCTAssertNil(WODFormat.other.scoreKind)
        XCTAssertTrue(WODFormat.forTime.canBeCapped)
        XCTAssertFalse(WODFormat.amrap.canBeCapped)
    }

    func testRankingLowerTimeWinsAndAFinishedTimeBeatsACappedOne() {
        let fast = WODResult(format: .forTime, score: .time(seconds: 280))
        let slow = WODResult(format: .forTime, score: .time(seconds: 340))
        let capped = WODResult(format: .forTime, score: .roundsAndReps(rounds: 2, reps: 30), capped: true)
        let cappedFurther = WODResult(format: .forTime, score: .roundsAndReps(rounds: 2, reps: 40), capped: true)
        XCTAssertTrue(fast.beats(slow))
        XCTAssertFalse(slow.beats(fast))
        XCTAssertFalse(fast.beats(fast))
        XCTAssertTrue(slow.beats(capped))
        XCTAssertFalse(capped.beats(slow))
        XCTAssertTrue(cappedFurther.beats(capped))
    }

    func testRankingMoreRoundsAndRepsWinAnAmrap() {
        let more = WODResult(format: .amrap, score: .roundsAndReps(rounds: 19, reps: 2))
        let fewer = WODResult(format: .amrap, score: .roundsAndReps(rounds: 18, reps: 14))
        XCTAssertTrue(more.beats(fewer))
        XCTAssertFalse(fewer.beats(more))
        XCTAssertFalse(more.beats(WODResult(format: .other, score: .load(kilograms: 80))), "Different scores do not compare")
        XCTAssertFalse(WODResult(format: .emom, score: .reps(80)).beats(WODResult(format: .other, score: .load(kilograms: 60))))
    }

    func testHistoryKeepsBestLastAndPRsPerScaling() throws {
        let records = [fran(341, daysAgo: 49), fran(298, daysAgo: 21), fran(306, daysAgo: 0), fran(250, daysAgo: 10, scaling: .scaled)]
        let history = try XCTUnwrap(WODBenchmarkHistory.named("  FRAN ", in: records))
        XCTAssertEqual(history.entries.count, 4)
        XCTAssertEqual(history.last?.result.score, .time(seconds: 306))
        XCTAssertEqual(history.best?.result.score, .time(seconds: 298), "Rx leads; the faster scaled time does not")
        XCTAssertEqual(history.entries.map(\.isPR), [false, false, true, false], "Newest first: 5:06, scaled 4:10, 4:58 PR, 5:41")
        XCTAssertEqual(history.name, "Fran")
    }

    func testTheFirstResultIsNotAPRAndACappedOneNeverBeatsAFinish() throws {
        let records = [fran(nil, daysAgo: 20, capped: .roundsAndReps(rounds: 2, reps: 30)), fran(590, daysAgo: 5)]
        let history = try XCTUnwrap(WODBenchmarkHistory.named("Fran", in: records))
        XCTAssertEqual(history.entries.map(\.isPR), [true, false])
        XCTAssertEqual(history.best?.result.score, .time(seconds: 590))
    }

    func testAllGroupsByNameMostRecentFirst() {
        var cindy = fran(nil, daysAgo: 2, capped: nil)
        cindy.wod = WODResult(format: .amrap, name: "Cindy", score: .roundsAndReps(rounds: 18, reps: 3))
        var unnamed = fran(300, daysAgo: 1)
        unnamed.wod?.name = nil
        let all = WODBenchmarkHistory.all([fran(300, daysAgo: 10), cindy, unnamed])
        XCTAssertEqual(all.map(\.name), ["Cindy", "Fran"])
    }

    func testBenchmarksFillTheirStandardMovements() throws {
        let names = WODBenchmark.catalog.map(\.name)
        XCTAssertEqual(names, ["Fran", "Grace", "Helen", "Diane", "Elizabeth", "Isabel", "Annie", "Cindy", "Karen",
                               "Jackie", "Nancy", "Murph", "DT"])
        let fran = try XCTUnwrap(WODBenchmark.named("fran"))
        XCTAssertEqual(fran.format, .forTime)
        XCTAssertEqual(fran.movements, ["21-15-9", "Thrusters 43/29 kg", "Pull-ups"])
        XCTAssertEqual(WODBenchmark.named("Cindy")?.timeCapSeconds, 1_200)
        XCTAssertEqual(WODBenchmark.named("Cindy")?.format, .amrap)
        XCTAssertEqual(WODBenchmark.suggestions(for: "d").map(\.name), ["Diane", "DT"])
        XCTAssertEqual(WODBenchmark.suggestions(for: "").count, 13)
        XCTAssertTrue(WODBenchmark.suggestions(for: "Fran").isEmpty, "A full match needs no suggestion")
    }

    func testCleaningDropsEmptyLinesAndANoteOnAnRxResult() async throws {
        let now = Date(timeIntervalSince1970: 1_699_927_200)
        let controller = WorkoutSessionController(store: InMemoryWorkoutStore(), now: { now })
        let wod = WODResult(format: .amrap, name: " Cindy ", movements: ["5 pull-ups", "", "  10 push-ups"],
                            timeCapSeconds: 1_200, score: .roundsAndReps(rounds: 18, reps: 3), capped: true,
                            scaling: .rx, scalingNote: "none")
        let record = try await controller.logManual(WorkoutLogEntry(activity: .crossfit, startedAt: now.addingTimeInterval(-1_800),
                                                                     endedAt: now, wod: wod))
        XCTAssertEqual(record.wod?.name, "Cindy")
        XCTAssertEqual(record.wod?.movements, ["5 pull-ups", "10 push-ups"])
        XCTAssertNil(record.wod?.scalingNote)
        XCTAssertEqual(record.wod?.capped, false, "An AMRAP cannot be capped")
        XCTAssertEqual(record.displayTitle, "Cindy")
        let other = try await controller.logManual(WorkoutLogEntry(activity: .yoga, startedAt: now.addingTimeInterval(-3_600),
                                                                    endedAt: now.addingTimeInterval(-1_800), wod: wod))
        XCTAssertNil(other.wod, "Only a CrossFit session keeps a WOD")
    }
}
