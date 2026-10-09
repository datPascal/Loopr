import Foundation
import StressKit
import XCTest

private struct BreathingSamplesConsumer: LiveConsumer {
    func acquire(generation: UUID) async throws -> AsyncStream<LiveCardiacSample> { AsyncStream { $0.finish() } }
    func release(generation: UUID) async {}
}

final class BandBreathingTests: XCTestCase, @unchecked Sendable {
    func testSixBreathsPerMinuteSwitchesEveryFiveSeconds() {
        XCTAssertEqual(BreathingCuePhase.phase(elapsed: 0, cadence: 6), .inhale)
        XCTAssertEqual(BreathingCuePhase.phase(elapsed: 4.99, cadence: 6), .inhale)
        XCTAssertEqual(BreathingCuePhase.phase(elapsed: 5, cadence: 6), .exhale)
        XCTAssertEqual(BreathingCuePhase.phase(elapsed: 10, cadence: 6), .inhale)
        XCTAssertEqual(BreathingCuePhase.phase(elapsed: 37, cadence: 6), .exhale)
        XCTAssertNil(BreathingCuePhase.phase(elapsed: 0, cadence: 0))
        XCTAssertNil(BreathingCuePhase.phase(elapsed: .nan, cadence: 6))
    }

    func testResultUsesFirstAndLastObservedHeartRateAndKeepsMissingEndpoints() async throws {
        let controller = BreathingSessionController(consumer: BreathingSamplesConsumer())
        try await controller.start(now: Date(timeIntervalSince1970: 0))
        let token = await controller.currentGeneration()
        let generation = try XCTUnwrap(token)
        try await controller.append(.init(timestamp: Date(timeIntervalSince1970: 1), heartRate: 80), generation: generation)
        try await controller.append(.init(timestamp: Date(timeIntervalSince1970: 2), heartRate: 70), generation: generation)
        let result = try await controller.finish(now: Date(timeIntervalSince1970: 3))
        XCTAssertEqual(result.beforeHeartRate, 80)
        XCTAssertEqual(result.afterHeartRate, 70)
        try await controller.start(now: Date(timeIntervalSince1970: 4))
        let secondToken = await controller.currentGeneration()
        let secondGeneration = try XCTUnwrap(secondToken)
        try await controller.append(.init(timestamp: Date(timeIntervalSince1970: 5), heartRate: 60), generation: secondGeneration)
        try await controller.append(.init(timestamp: Date(timeIntervalSince1970: 6)), generation: secondGeneration)
        let missing = try await controller.finish(now: Date(timeIntervalSince1970: 7))
        XCTAssertEqual(missing.beforeHeartRate, 60)
        XCTAssertNil(missing.afterHeartRate)
    }

    func testStaleHeartRateIsNotAnAfterReading() async throws {
        let controller = BreathingSessionController(consumer: BreathingSamplesConsumer())
        try await controller.start(now: Date(timeIntervalSince1970: 0))
        let token = await controller.currentGeneration()
        let generation = try XCTUnwrap(token)
        try await controller.append(.init(timestamp: Date(timeIntervalSince1970: 1), heartRate: 80), generation: generation)
        let result = try await controller.finish(now: Date(timeIntervalSince1970: 30))
        XCTAssertEqual(result.beforeHeartRate, 80)
        XCTAssertNil(result.afterHeartRate)
    }

    func testBandPacingStartsWithAnInhaleAndReleasesOnCancel() async throws {
        let cue = expectation(description: "Inhale cue")
        let consumer = BreathingSamplesConsumer()
        let controller = BreathingSessionController(consumer: consumer, bandCue: { phase, _ in
            XCTAssertEqual(phase, .inhale)
            cue.fulfill()
        })
        try await controller.start(paceWithBand: true)
        let cueResult = await XCTWaiter.fulfillment(of: [cue], timeout: 2)
        XCTAssertEqual(cueResult, .completed)
        try await controller.cancel()
        let state = await controller.currentState()
        XCTAssertEqual(state, .cancelled)
        let generation = await controller.currentGeneration()
        XCTAssertNil(generation)
    }

    func testOldPersistedResultsDecodeWithoutInventingEndpoints() throws {
        let json = """
        {"id":"00000000-0000-0000-0000-000000000001","startedAt":0,"endedAt":10,"cadence":6,"samples":0}
        """
        let result = try JSONDecoder().decode(BreathingResult.self, from: Data(json.utf8))
        XCTAssertNil(result.beforeHeartRate)
        XCTAssertNil(result.afterHeartRate)
        XCTAssertNil(result.averageHeartRate)
    }
}
