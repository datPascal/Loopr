import Foundation
import HealthKitBridge
import SharedSurfaceKit
import Testing
import WorkoutKit

@testable import Loopr

struct WorkoutIntegrationRuntimeTests {
    @Test
    func surfaceHooksNeverOverwriteTheSharedSnapshotOrFakeAHealthExport() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loopr-workout-integrations-\(UUID().uuidString)", isDirectory: true)
        let snapshotURL = root.appendingPathComponent("surface.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let hooks = LooprWorkoutIntegrationRuntime.shared.hooks()
        let workout = WorkoutFixtures.completedRun

        try await hooks.enqueueHealthKit(workout)
        try await hooks.publishSnapshot(workout)
        try await hooks.updateLiveActivity(workout)

        let ledger = HealthExportLedger(persistenceURL: root
            .appendingPathComponent("HealthKitBridge", isDirectory: true)
            .appendingPathComponent("export-ledger.json"))
        #expect(try await ledger.status(for: workout.id) == nil)
        // The widget and Watch snapshot carries the whole day. This hook only
        // knows a workout, so writing one from here would blank every metric
        // on the Home screen. The derived-data publisher owns that file.
        #expect(!FileManager.default.fileExists(atPath: snapshotURL.path))
    }
}
