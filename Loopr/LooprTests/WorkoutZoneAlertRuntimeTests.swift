import AnalyticsKit
import BluetoothKit
import Foundation
import ProtocolKit
import SyncKit
import WorkoutKit
import XCTest
@testable import Loopr

final class WorkoutZoneAlertRuntimeTests: XCTestCase {
    func testRuntimeIgnoresStaleSamples() async throws {
        let start = Date(timeIntervalSince1970: 1000)
        let cues = RuntimePhoneRecorder()
        let runtime = WorkoutZoneAlertRuntime(now: { @Sendable in start.addingTimeInterval(70) },
                                              cueQueue: BandCueCommandQueue(wait: {}),
                                              phone: { @Sendable event, vibrate, _ in await cues.append(event, vibrate) })
        let preference = WorkoutZoneAlertPreference(target: .custom(lower: 130, upper: 150), warmUpMinutes: 0)
        let target = WorkoutZoneTarget(preference: preference, zones: nil, zoneTwo: nil)!
        var workout = WorkoutRecord(id: UUID(), identity: .init(canonicalKey: "runtime"), activity: .run, source: .manual,
                                    state: .active, createdAt: start, startedAt: start,
                                    zoneAlertPreference: preference, zoneTargetChanges: [.init(at: start, target: target)])
        let session = WorkoutSessionController(store: InMemoryWorkoutStore(workouts: [workout]))
        await runtime.start(workoutID: workout.id, session: session, zones: nil, preference: preference, band: nil)
        // Keep the signal continuous. Only the final ten seconds are fresh
        // relative to the injected clock, so cannot complete a dwell.
        for seconds in 0...70 {
            workout.samples.append(.init(timestamp: start.addingTimeInterval(Double(seconds)), heartRate: 160))
            if let cue = await runtime.receive(workout) { await cue.value }
        }
        let initial = await cues.events
        XCTAssertTrue(initial.isEmpty)
        await runtime.stop()
    }

    func testBandFourWritesAndBandFiveFallsBackToPhone() async throws {
        for model in [BandModel.whoop4, .whoop5] {
            let start = Date()
            let clock = RuntimeTestClock(start)
            let cues = RuntimePhoneRecorder()
            let band = CueRuntimeFixture(model: model)
            let runtime = WorkoutZoneAlertRuntime(now: { @Sendable in clock.read() }, cueQueue: BandCueCommandQueue(wait: {}),
                phone: { @Sendable event, vibrate, _ in await cues.append(event, vibrate) })
            let preference = WorkoutZoneAlertPreference(target: .custom(lower: 130, upper: 150), warmUpMinutes: 0)
            let target = WorkoutZoneTarget(preference: preference, zones: nil, zoneTwo: nil)!
            var workout = WorkoutRecord(id: UUID(), identity: .init(canonicalKey: "model-runtime"), activity: .run, source: .manual,
                state: .active, createdAt: start, startedAt: start, zoneAlertPreference: preference,
                zoneTargetChanges: [.init(at: start, target: target)])
            let session = WorkoutSessionController(store: InMemoryWorkoutStore(workouts: [workout]))
            await runtime.start(workoutID: workout.id, session: session, zones: nil, preference: preference, band: band)
            for seconds in stride(from: 0, through: 30, by: 1) {
                let date = start.addingTimeInterval(Double(seconds)); clock.set(date)
                workout.samples.append(.init(timestamp: date, heartRate: 160)); if let cue = await runtime.receive(workout) { await cue.value }
            }
            let sent = await band.effects
            XCTAssertEqual(sent, model == .whoop4 ? [2] : [])
            let phone = await cues.events
            XCTAssertEqual(phone.map(\.0), [.tooHigh])
            XCTAssertEqual(phone.map(\.1), [model != .whoop4])
            await runtime.stop()
        }
    }

    func testShortSignalGapRestartsTheThirtySecondDwell() async throws {
        let start = Date()
        let clock = RuntimeTestClock(start)
        let cues = RuntimePhoneRecorder()
        let runtime = WorkoutZoneAlertRuntime(now: { @Sendable in clock.read() }, cueQueue: BandCueCommandQueue(wait: {}),
            phone: { @Sendable event, vibrate, _ in await cues.append(event, vibrate) })
        let preference = WorkoutZoneAlertPreference(target: .custom(lower: 130, upper: 150), warmUpMinutes: 0)
        let target = WorkoutZoneTarget(preference: preference, zones: nil, zoneTwo: nil)!
        var workout = WorkoutRecord(id: UUID(), identity: .init(canonicalKey: "gap-runtime"), activity: .run, source: .manual,
            state: .active, createdAt: start, startedAt: start, zoneAlertPreference: preference,
            zoneTargetChanges: [.init(at: start, target: target)])
        let session = WorkoutSessionController(store: InMemoryWorkoutStore(workouts: [workout]))
        await runtime.start(workoutID: workout.id, session: session, zones: nil, preference: preference, band: nil)
        for seconds in Array(0...29) + Array(34...63) {
            let date = start.addingTimeInterval(Double(seconds)); clock.set(date)
            workout.samples.append(.init(timestamp: date, heartRate: 160)); if let cue = await runtime.receive(workout) { await cue.value }
        }
        let before = await cues.events
        XCTAssertTrue(before.isEmpty)
        clock.set(start.addingTimeInterval(64))
        workout.samples.append(.init(timestamp: start.addingTimeInterval(64), heartRate: 160))
        if let cue = await runtime.receive(workout) { await cue.value }
        let after = await cues.events
        XCTAssertEqual(after.map(\.0), [.tooHigh])
        await runtime.stop()
    }

    func testPauseCancelsRemainingLowCuePulses() async throws {
        let start = Date()
        let clock = RuntimeTestClock(start)
        let gate = RuntimeCueGate()
        var waiting = gate.signal.makeAsyncIterator()
        let phone = RuntimePhoneRecorder()
        let band = CueRuntimeFixture()
        let runtime = WorkoutZoneAlertRuntime(now: { @Sendable in clock.read() },
            cueQueue: BandCueCommandQueue(wait: { @Sendable in await gate.wait() }),
            phone: { @Sendable event, vibrate, _ in await phone.append(event, vibrate) })
        let preference = WorkoutZoneAlertPreference(target: .custom(lower: 130, upper: 150), alertWhenTooLow: true, warmUpMinutes: 0)
        let target = WorkoutZoneTarget(preference: preference, zones: nil, zoneTwo: nil)!
        var workout = WorkoutRecord(id: UUID(), identity: .init(canonicalKey: "cancel-cue"), activity: .run, source: .manual,
            state: .active, createdAt: start, startedAt: start, zoneAlertPreference: preference,
            zoneTargetChanges: [.init(at: start, target: target)])
        let session = WorkoutSessionController(store: InMemoryWorkoutStore(workouts: [workout]))
        await runtime.start(workoutID: workout.id, session: session, zones: nil, preference: preference, band: band)
        for seconds in 0..<30 {
            let date = start.addingTimeInterval(Double(seconds)); clock.set(date)
            workout.samples.append(.init(timestamp: date, heartRate: 120))
            _ = await runtime.receive(workout)
        }
        clock.set(start.addingTimeInterval(30))
        workout.samples.append(.init(timestamp: start.addingTimeInterval(30), heartRate: 120))
        let cue = await runtime.receive(workout)
        _ = await waiting.next()
        workout.state = .paused
        _ = await runtime.receive(workout)
        await gate.release()
        await cue?.value
        let effects = await band.effects
        XCTAssertEqual(effects, [0])
        let phoneEvents = await phone.events
        XCTAssertTrue(phoneEvents.isEmpty)
        await runtime.stop()
    }

    func testRuntimeAlertsAndResetsOnPause() async throws {
        let start = Date()
        let cues = RuntimePhoneRecorder()
        let clock = RuntimeTestClock(start)
        let runtime = WorkoutZoneAlertRuntime(now: { @Sendable in clock.read() }, cueQueue: BandCueCommandQueue(wait: {}),
                                              phone: { @Sendable event, vibrate, _ in await cues.append(event, vibrate) })
        let preference = WorkoutZoneAlertPreference(target: .custom(lower: 130, upper: 150), warmUpMinutes: 0)
        let target = WorkoutZoneTarget(preference: preference, zones: nil, zoneTwo: nil)!
        var workout = WorkoutRecord(id: UUID(), identity: .init(canonicalKey: "pause-runtime"), activity: .run, source: .manual,
                                    state: .active, createdAt: start, startedAt: start,
                                    zoneAlertPreference: preference, zoneTargetChanges: [.init(at: start, target: target)])
        let session = WorkoutSessionController(store: InMemoryWorkoutStore(workouts: [workout]))
        await runtime.start(workoutID: workout.id, session: session, zones: nil, preference: preference, band: nil)
        for seconds in stride(from: 0, through: 30, by: 1) {
            let date = start.addingTimeInterval(Double(seconds)); clock.set(date)
            workout.samples.append(.init(timestamp: date, heartRate: 160)); if let cue = await runtime.receive(workout) { await cue.value }
        }
        let alerts = await cues.events
        XCTAssertEqual(alerts.map(\.0), [.tooHigh])
        XCTAssertEqual(alerts.map(\.1), [true])
        workout.state = .paused; if let cue = await runtime.receive(workout) { await cue.value }
        workout.state = .active
        for seconds in stride(from: 35, through: 55, by: 1) {
            let date = start.addingTimeInterval(Double(seconds)); clock.set(date)
            workout.samples.append(.init(timestamp: date, heartRate: 140)); if let cue = await runtime.receive(workout) { await cue.value }
        }
        let afterPause = await cues.events
        XCTAssertEqual(afterPause.map(\.0), [.tooHigh])
        await runtime.stop()
    }
}

private actor RuntimePhoneRecorder {
    private(set) var events: [(WorkoutZoneAlertEvent, Bool)] = []
    func append(_ event: WorkoutZoneAlertEvent, _ vibrate: Bool) { events.append((event, vibrate)) }
}
nonisolated private final class RuntimeTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    func read() -> Date { lock.withLock { date } }
    func set(_ date: Date) { lock.withLock { self.date = date } }
}

private actor RuntimeCueGate {
    nonisolated let signal: AsyncStream<Void>
    private let signalled: AsyncStream<Void>.Continuation
    private var continuation: CheckedContinuation<Void, Never>?
    init() {
        let pair = AsyncStream<Void>.makeStream()
        signal = pair.stream; signalled = pair.continuation
    }
    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            signalled.yield(())
        }
    }
    func release() { continuation?.resume(); continuation = nil }
}
