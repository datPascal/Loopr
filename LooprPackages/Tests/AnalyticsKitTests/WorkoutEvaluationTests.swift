import XCTest
@testable import AnalyticsKit

final class WorkoutEvaluationTests: XCTestCase {
    func testPinnedParityGateRemainsTheDefault() {
        let walk = WorkoutEvaluationFixtures.all.first { $0.name == "long walk" }!
        XCTAssertEqual(WorkoutAnalytics.detect(walk.heartRate, motion: walk.motion,
            restingHR: 60, maxHR: 190).value?.count, 0)
    }

    func testFullDayRuntimeWithOneHertzHeartRate() {
        let heartRate = (0..<86_400).map { second in
            WorkoutHRPoint(timestamp: Double(second), bpm: (43_200..<45_600).contains(second) ? 150 : 60)
        }
        let motion = (0..<1_440).map { minute in
            WorkoutMotionPoint(timestamp: Double(minute * 60),
                intensity: (720..<760).contains(minute) ? 0.5 : 0.02)
        }
        let started = DispatchTime.now().uptimeNanoseconds
        let result = WorkoutAnalytics.detect(heartRate, motion: motion, restingHR: 60, maxHR: 190,
            includeSustainedModerate: true)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        print(String(format: "WORKOUT_SPEED|86400 HR|1440 motion|%.1f ms", elapsed))
        XCTAssertEqual(result.value?.count, 1)
    }

    func testLabelledScenariosReportPrecisionRecallAndBoundaryError() {
        for fixture in WorkoutEvaluationFixtures.all {
            let actual = WorkoutAnalytics.detect(
                fixture.heartRate, motion: fixture.motion, restingHR: 60, maxHR: 190,
                savedSpans: fixture.saved, includeSustainedModerate: true
            ).value ?? []
            var unmatched = Array(fixture.expected.indices)
            var matched = 0
            var startErrors: [Int] = []
            var endErrors: [Int] = []
            for bout in actual {
                guard let position = unmatched.firstIndex(where: {
                    let label = fixture.expected[$0]
                    let shared = min(bout.end, label.end) - max(bout.start, label.start)
                    return shared > 0 && shared >= 0.5 * (label.end - label.start)
                }) else { continue }
                let label = fixture.expected[unmatched.remove(at: position)]
                matched += 1
                startErrors.append(Int(abs(bout.start - label.start)))
                endErrors.append(Int(abs(bout.end - label.end)))
            }
            let precision = actual.isEmpty ? (fixture.expected.isEmpty ? 1.0 : 0.0) : Double(matched) / Double(actual.count)
            let recall = fixture.expected.isEmpty ? 1.0 : Double(matched) / Double(fixture.expected.count)
            print("WORKOUT_EVAL|\(fixture.name)|\(actual.count)|\(fixture.expected.count)|\(String(format: "%.2f", precision))|\(String(format: "%.2f", recall))|\(startErrors.map(String.init).joined(separator: ","))|\(endErrors.map(String.init).joined(separator: ","))")
            XCTAssertEqual(actual.count, fixture.expected.count, fixture.name)
            XCTAssertEqual(matched, fixture.expected.count, fixture.name)
            XCTAssertTrue(startErrors.allSatisfy { $0 <= 60 }, fixture.name)
            XCTAssertTrue(endErrors.allSatisfy { $0 <= 60 }, fixture.name)
        }
    }
}
