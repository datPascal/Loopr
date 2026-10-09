import Foundation
import HealthKitBridge
import XCTest

private enum FinalizationFailure: Error { case injected }

private actor FinalizationEffectsSpy: WorkoutFinalizationEffects {
    var stages: [WorkoutFinalizationStage] = []
    var failAt: WorkoutFinalizationStage?

    init(failAt: WorkoutFinalizationStage? = nil) { self.failAt = failAt }

    func commitLocalData(_ workout: WorkoutFinalizationEnvelope) throws { try append(.commitLocalData) }
    func enqueueHealthKitExport(_ workout: WorkoutFinalizationEnvelope) throws { try append(.enqueueHealthKitExport) }
    func publishSurfaceSnapshot(_ workout: WorkoutFinalizationEnvelope) throws { try append(.publishSurfaceSnapshot) }
    func endLiveActivity(_ workout: WorkoutFinalizationEnvelope) throws { try append(.endLiveActivity) }
    func clearActiveState(_ workout: WorkoutFinalizationEnvelope) throws { try append(.clearActiveState) }
    func values() -> [WorkoutFinalizationStage] { stages }
    func setFailure(_ stage: WorkoutFinalizationStage?) { failAt = stage }

    private func append(_ stage: WorkoutFinalizationStage) throws {
        stages.append(stage)
        if failAt == stage { throw FinalizationFailure.injected }
    }
}

final class WorkoutExportFinalizationTests: XCTestCase {
    private func workout(source: WorkoutFinalizationSource) -> WorkoutFinalizationEnvelope {
        .init(
            workoutID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            source: source,
            startedAt: Date(timeIntervalSince1970: 1_742_774_400),
            endedAt: Date(timeIntervalSince1970: 1_742_781_600)
        )
    }

    func testEveryFinalizationSourceUsesFiveStageOrderingAndIsIdempotent() async throws {
        for source in WorkoutFinalizationSource.allCases {
            let effects = FinalizationEffectsSpy()
            let finalizer = WorkoutHealthExportFinalizer(effects: effects)
            let value = workout(source: source)
            try await finalizer.finalize(value)
            try await finalizer.finalize(value)
            let stages = await effects.values()
            XCTAssertEqual(stages, WorkoutFinalizationStage.allCases)
        }
    }

    func testFailureBeforeClearKeepsActiveStateRecoverable() async {
        let effects = FinalizationEffectsSpy(failAt: .publishSurfaceSnapshot)
        let finalizer = WorkoutHealthExportFinalizer(effects: effects)
        do {
            try await finalizer.finalize(workout(source: .recovered))
            XCTFail("expected injected failure")
        } catch {}
        let stages = await effects.values()
        XCTAssertEqual(stages, [.commitLocalData, .enqueueHealthKitExport, .publishSurfaceSnapshot])
        XCTAssertFalse(stages.contains(.clearActiveState))
    }

    func testCrossMidnightWorkoutRemainsOneExportObject() async throws {
        let effects = FinalizationEffectsSpy()
        let finalizer = WorkoutHealthExportFinalizer(effects: effects)
        let value = workout(source: .live)
        XCTAssertGreaterThan(value.endedAt.timeIntervalSince(value.startedAt), 3600)
        try await finalizer.finalize(value)
        let stages = await effects.values()
        XCTAssertEqual(stages.filter { $0 == .enqueueHealthKitExport }.count, 1)
    }

    func testKillMidFinalizationResumesFromDurableCheckpointWithoutDuplicateExport() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let url = directory.appending(path: "workout-finalization.json")
        let effects = FinalizationEffectsSpy(failAt: .publishSurfaceSnapshot)
        let value = workout(source: .recovered)
        do {
            try await WorkoutHealthExportFinalizer(effects: effects, persistenceURL: url).finalize(value)
            XCTFail("expected interruption")
        } catch FinalizationFailure.injected {}

        await effects.setFailure(nil)
        try await WorkoutHealthExportFinalizer(effects: effects, persistenceURL: url).finalize(value)
        let stages = await effects.values()
        XCTAssertEqual(stages.filter { $0 == .commitLocalData }.count, 1)
        XCTAssertEqual(stages.filter { $0 == .enqueueHealthKitExport }.count, 1)
        XCTAssertEqual(stages.filter { $0 == .publishSurfaceSnapshot }.count, 2)
        XCTAssertEqual(Array(stages.suffix(3)), [.publishSurfaceSnapshot, .endLiveActivity, .clearActiveState])
    }
}
