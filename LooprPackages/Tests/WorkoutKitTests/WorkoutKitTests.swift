import WorkoutKit
import XCTest

private enum FinalizationFailure: Error { case injected }

private actor FailingSaveStore: WorkoutStore {
    private var rows: [UUID: WorkoutRecord] = [:]
    private var failNext = false

    func save(_ workout: WorkoutRecord) async throws {
        if failNext {
            failNext = false
            throw FinalizationFailure.injected
        }
        rows[workout.id] = workout
    }

    func failNextSave() { failNext = true }
    func workout(id: UUID) async -> WorkoutRecord? { rows[id] }
    func workout(identity: WorkoutIdentity) async -> WorkoutRecord? { rows.values.first { $0.identity == identity } }
    func all() async -> [WorkoutRecord] { Array(rows.values) }
    func remove(id: UUID) async { rows.removeValue(forKey: id) }
}

private actor LiveSourceFixture: WorkoutLiveSampleSource {
    private var continuation: AsyncStream<WorkoutSample>.Continuation?
    private(set) var releaseCount = 0

    func acquire(generation: UUID) async throws -> WorkoutLiveSampleLease {
        let (stream, continuation) = AsyncStream<WorkoutSample>.makeStream(bufferingPolicy: .bufferingNewest(16))
        self.continuation = continuation
        return WorkoutLiveSampleLease(generation: generation, stream: stream) { [weak self] in
            await self?.release()
        }
    }

    func emit(_ sample: WorkoutSample) {
        _ = continuation?.yield(sample)
    }

    func release() {
        releaseCount += 1
        continuation?.finish()
        continuation = nil
    }
}

private actor WorkoutFinalizationGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        entered = true
        let waitingForEntry = entryWaiters
        entryWaiters.removeAll(keepingCapacity: false)
        for continuation in waitingForEntry { continuation.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        released = true
        let waitingForRelease = releaseWaiters
        releaseWaiters.removeAll(keepingCapacity: false)
        for continuation in waitingForRelease { continuation.resume() }
    }
}

final class WorkoutKitTests: XCTestCase {
    func testCatalogHasOneCanonicalActivityList() {
        XCTAssertTrue(ActivityType.allCases.contains(.run))
        XCTAssertEqual(Set(ActivityType.allCases).count, ActivityType.allCases.count)
    }

    func testStateMachineCheckpointAndRecoveryNeverAutoResumes() async throws {
        let store = InMemoryWorkoutStore()
        let controller = WorkoutSessionController(store: store)
        _ = try await controller.start(activity: .run, id: UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        _ = try await controller.transition(to: .preparing)
        _ = try await controller.transition(to: .active)
        _ = try await controller.checkpoint()
        let recovered = try await controller.recoverInterrupted()
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered[0].state, .interruptedAndRecoverable)
        let activeAfterRecovery = await controller.activeWorkout()
        XCTAssertNil(activeAfterRecovery)
        _ = try await controller.resumeRecovered(id: recovered[0].id)
        let activeAfterResume = await controller.activeWorkout()
        XCTAssertEqual(activeAfterResume?.state, .active)
    }

    func testFinalizationRunsHooksInOrderAndIsIdempotent() async throws {
        let store = InMemoryWorkoutStore()
        let controller = WorkoutSessionController(store: store)
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        _ = try await controller.start(activity: .cycle, id: id)
        _ = try await controller.transition(to: .preparing)
        _ = try await controller.transition(to: .active)
        actor Events { var values: [String] = []; func add(_ value: String) { values.append(value) }; func all() -> [String] { values } }
        let events = Events()
        let hooks = WorkoutFinalizationHooks(
            enqueueHealthKit: { _ in await events.add("health") },
            publishSnapshot: { _ in await events.add("snapshot") },
            updateLiveActivity: { _ in await events.add("activity") }
        )
        let finished = try await controller.finish(id: id, hooks: hooks)
        XCTAssertEqual(finished.state, .completed)
        let firstEvents = await events.all()
        XCTAssertEqual(firstEvents, ["health", "snapshot", "activity"])
        let repeated = try await controller.finish(id: id, hooks: hooks)
        XCTAssertEqual(repeated.id, finished.id)
        let secondEvents = await events.all()
        XCTAssertEqual(secondEvents.count, 3)
        let activeAfterFinish = await controller.activeWorkout()
        XCTAssertNil(activeAfterFinish)
    }

    func testPostCommitFinishSummaryKeepsUUIDAndDoesNotFinalizeAgain() async throws {
        let store = InMemoryWorkoutStore()
        let controller = WorkoutSessionController(store: store)
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        _ = try await controller.start(activity: .run, id: id)
        _ = try await controller.transition(to: .preparing)
        _ = try await controller.transition(to: .active)

        actor HookCounter {
            var count = 0
            func record() { count += 1 }
            func value() -> Int { count }
        }
        let hooksCalled = HookCounter()
        let hooks = WorkoutFinalizationHooks(
            enqueueHealthKit: { _ in await hooksCalled.record() },
            publishSnapshot: { _ in await hooksCalled.record() },
            updateLiveActivity: { _ in await hooksCalled.record() }
        )

        let completed = try await controller.finish(id: id, hooks: hooks)
        let summaryAction = WorkoutFinishSummaryAction(workout: completed)
        XCTAssertEqual(summaryAction.workoutID, id)

        // The completed summary's action is navigation-only. Replaying the
        // legacy finish callback with the same UUID remains idempotent too.
        let repeated = try await controller.finish(id: summaryAction.workoutID, hooks: hooks)
        XCTAssertEqual(repeated.id, summaryAction.workoutID)
        let finalHookCount = await hooksCalled.value()
        XCTAssertEqual(finalHookCount, 3)
    }

    func testConcurrentFinishRejectsReentryAndRunsHooksOnce() async throws {
        let store = InMemoryWorkoutStore()
        let controller = WorkoutSessionController(store: store)
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        _ = try await controller.start(activity: .run, id: id)
        _ = try await controller.transition(to: .preparing)
        _ = try await controller.transition(to: .active)

        actor Events {
            var values: [String] = []
            func add(_ value: String) { values.append(value) }
            func all() -> [String] { values }
        }
        let gate = WorkoutFinalizationGate()
        let events = Events()
        let hooks = WorkoutFinalizationHooks(
            enqueueHealthKit: { _ in
                await events.add("health")
                await gate.enterAndWait()
            },
            publishSnapshot: { _ in await events.add("snapshot") },
            updateLiveActivity: { _ in await events.add("activity") }
        )

        let first = Task { try await controller.finish(id: id, hooks: hooks) }
        await gate.waitUntilEntered()
        do {
            _ = try await controller.finish(id: id, hooks: hooks)
            XCTFail("a concurrent caller must not enter the finalization hooks")
        } catch {
            XCTAssertEqual(error as? WorkoutTransitionError, .finalizationInProgress)
        }
        await gate.release()

        let completed = try await first.value
        XCTAssertEqual(completed.id, id)
        XCTAssertEqual(completed.state, .completed)
        let recordedEvents = await events.all()
        XCTAssertEqual(recordedEvents, ["health", "snapshot", "activity"])
    }

    func testConcurrentDiscardRejectsReentryAndRunsHooksOnce() async throws {
        let store = InMemoryWorkoutStore()
        let controller = WorkoutSessionController(store: store)
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
        _ = try await controller.start(activity: .walk, id: id)

        actor Events {
            var values: [String] = []
            func add(_ value: String) { values.append(value) }
            func all() -> [String] { values }
        }
        let gate = WorkoutFinalizationGate()
        let events = Events()
        let hooks = WorkoutFinalizationHooks(
            enqueueHealthKit: { _ in
                await events.add("health")
                await gate.enterAndWait()
            },
            publishSnapshot: { _ in await events.add("snapshot") },
            updateLiveActivity: { _ in await events.add("activity") }
        )

        let first = Task { try await controller.discard(id: id, hooks: hooks) }
        await gate.waitUntilEntered()
        do {
            _ = try await controller.discard(id: id, hooks: hooks)
            XCTFail("a concurrent discard must not enter the finalization hooks")
        } catch {
            XCTAssertEqual(error as? WorkoutTransitionError, .finalizationInProgress)
        }
        await gate.release()

        let discarded = try await first.value
        XCTAssertEqual(discarded.id, id)
        XCTAssertEqual(discarded.state, .discarded)
        let recordedEvents = await events.all()
        XCTAssertEqual(recordedEvents, ["health", "snapshot", "activity"])
    }

    func testTerminalTransitionExcludesConcurrentFinishAndDiscard() async throws {
        let store = InMemoryWorkoutStore()
        let controller = WorkoutSessionController(store: store)
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000006")!
        _ = try await controller.start(activity: .cycle, id: id)
        _ = try await controller.transition(to: .preparing)
        _ = try await controller.transition(to: .active)
        _ = try await controller.transition(to: .finishing)

        actor Events {
            var values: [String] = []
            func add(_ value: String) { values.append(value) }
            func all() -> [String] { values }
        }
        let gate = WorkoutFinalizationGate()
        let events = Events()
        let hooks = WorkoutFinalizationHooks(
            enqueueHealthKit: { _ in
                await events.add("health")
                await gate.enterAndWait()
            },
            publishSnapshot: { _ in await events.add("snapshot") },
            updateLiveActivity: { _ in await events.add("activity") }
        )

        let transition = Task { try await controller.transition(to: .completed, hooks: hooks) }
        await gate.waitUntilEntered()
        do {
            _ = try await controller.finish(id: id, hooks: hooks)
            XCTFail("finish must not overlap a terminal transition")
        } catch {
            XCTAssertEqual(error as? WorkoutTransitionError, .finalizationInProgress)
        }
        do {
            _ = try await controller.discard(id: id, hooks: hooks)
            XCTFail("discard must not overlap a terminal transition")
        } catch {
            XCTAssertEqual(error as? WorkoutTransitionError, .finalizationInProgress)
        }
        await gate.release()

        let completed = try await transition.value
        XCTAssertEqual(completed.id, id)
        XCTAssertEqual(completed.state, .completed)
        let recordedEvents = await events.all()
        XCTAssertEqual(recordedEvents, ["health", "snapshot", "activity"])
    }

    func testManualAndDetectedIdentityCanConverge() async throws {
        let store = InMemoryWorkoutStore()
        let controller = WorkoutSessionController(store: store)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let identity = WorkoutIdentity.make(activity: .walk, sourceKey: "same-session", startedAt: start, endedAt: start.addingTimeInterval(600))
        let detected = WorkoutRecord(id: UUID(), identity: identity, activity: .walk, source: .detected, state: .completed, createdAt: start, startedAt: start, endedAt: start.addingTimeInterval(600), finalizationStage: .activeStateCleared)
        let imported = WorkoutRecord(id: UUID(), identity: identity, activity: .walk, source: .healthKit, state: .completed, createdAt: start, startedAt: start, endedAt: start.addingTimeInterval(600), finalizationStage: .activeStateCleared)
        let first = try await controller.reconcile(detected)
        let second = try await controller.reconcile(imported)
        XCTAssertEqual(first.id, second.id)
        let rows = await store.all()
        XCTAssertEqual(rows.count, 1)
    }

    func testEveryLegalAndIllegalTransitionIsExplicit() async throws {
        let states = WorkoutLifecycleState.allCases
        let legal: Set<String> = [
            "selectedActivity->preparing", "selectedActivity->discarded",
            "preparing->active", "preparing->discarded", "preparing->interruptedAndRecoverable",
            "active->paused", "active->finishing", "active->interruptedAndRecoverable",
            "paused->active", "paused->finishing", "paused->interruptedAndRecoverable",
            "finishing->completed", "finishing->interruptedAndRecoverable",
            "interruptedAndRecoverable->active", "interruptedAndRecoverable->discarded",
            "completed->completed", "discarded->discarded"
        ]
        for from in states {
            for to in states {
                let key = "\(from.rawValue)->\(to.rawValue)"
                XCTAssertEqual(WorkoutSessionController.isLegal(from: from, to: to), legal.contains(key), key)
            }
        }

        let controller = WorkoutSessionController(store: InMemoryWorkoutStore())
        _ = try await controller.start(activity: .run)
        var terminal: WorkoutRecord?
        for transition in [WorkoutLifecycleState.preparing, .active, .paused, .active, .finishing, .completed] {
            terminal = try await controller.transition(to: transition)
        }
        XCTAssertEqual(terminal?.state, .completed)
        XCTAssertEqual(terminal?.finalizationStage, .activeStateCleared)
        let activeWorkout = await controller.activeWorkout()
        XCTAssertNil(activeWorkout)
        do {
            _ = try await controller.transition(to: .active)
            XCTFail("completed workouts cannot become active")
        } catch WorkoutTransitionError.illegalTransition { }
        catch WorkoutTransitionError.missingWorkout { }
    }

    func testFinalizationLeavesActiveStateAtEveryKillBoundaryAndClearsAfterStepFive() async throws {
        let localStore = FailingSaveStore()
        let localController = WorkoutSessionController(store: localStore)
        _ = try await localController.start(activity: .run)
        _ = try await localController.transition(to: .preparing)
        _ = try await localController.transition(to: .active)
        await localStore.failNextSave()
        do {
            _ = try await localController.finish(hooks: .init())
            XCTFail("local commit failure must be observable")
        } catch FinalizationFailure.injected { }
        let localActive = await localController.activeWorkout()
        XCTAssertNotNil(localActive)

        let stages: [(FinalizationStage, WorkoutFinalizationHooks)] = [
            (.localCommit, WorkoutFinalizationHooks(enqueueHealthKit: { _ in throw FinalizationFailure.injected })),
            (.healthKitEnqueued, WorkoutFinalizationHooks(publishSnapshot: { _ in throw FinalizationFailure.injected })),
            (.snapshotPublished, WorkoutFinalizationHooks(updateLiveActivity: { _ in throw FinalizationFailure.injected }))
        ]
        for (expectedStage, hooks) in stages {
            let store = InMemoryWorkoutStore()
            let controller = WorkoutSessionController(store: store)
            _ = try await controller.start(activity: .cycle)
            _ = try await controller.transition(to: .preparing)
            _ = try await controller.transition(to: .active)
            do {
                _ = try await controller.finish(hooks: hooks)
                XCTFail("injected integration failure must be observable")
            } catch FinalizationFailure.injected { }
            let active = await controller.activeWorkout()
            XCTAssertNotNil(active)
            XCTAssertEqual(active?.finalizationStage, expectedStage)
            XCTAssertEqual(active?.state, .finishing)
        }

        let store = InMemoryWorkoutStore()
        let controller = WorkoutSessionController(store: store)
        _ = try await controller.start(activity: .walk)
        _ = try await controller.transition(to: .preparing)
        _ = try await controller.transition(to: .active)
        let finished = try await controller.finish()
        XCTAssertEqual(finished.finalizationStage, .activeStateCleared)
        let activeAfterStepFive = await controller.activeWorkout()
        XCTAssertNil(activeAfterStepFive)
    }

    func testDiscardRecoveryChoiceFinalizesAndDetailEditDeleteUpdatesLog() async throws {
        let store = InMemoryWorkoutStore()
        let controller = WorkoutSessionController(store: store)
        let started = try await controller.logManual(activity: .strength, startedAt: Date(timeIntervalSince1970: 1_700_000_000), endedAt: Date(timeIntervalSince1970: 1_700_000_600))
        let edited = try await controller.edit(id: started.id, activity: .yoga)
        XCTAssertEqual(edited.activity, .yoga)
        let listed = await controller.list(WorkoutLogQuery(range: .threeMonths, now: Date(timeIntervalSince1970: 1_700_001_000), calendar: Calendar(identifier: .gregorian)))
        XCTAssertEqual(listed.count, 1)
        try await controller.delete(id: started.id)
        let afterDelete = await controller.list(WorkoutLogQuery(range: .threeMonths, now: Date(timeIntervalSince1970: 1_700_001_000), calendar: Calendar(identifier: .gregorian)))
        XCTAssertTrue(afterDelete.isEmpty)

        _ = try await controller.start(activity: .run)
        _ = try await controller.transition(to: .preparing)
        _ = try await controller.transition(to: .active)
        let recovered = try await controller.recoverInterrupted()
        XCTAssertEqual(recovered.count, 1)
        let discarded = try await controller.discard(id: recovered[0].id)
        XCTAssertEqual(discarded.state, .discarded)
        XCTAssertEqual(discarded.finalizationStage, .activeStateCleared)
        let activeAfterDiscard = await controller.activeWorkout()
        XCTAssertNil(activeAfterDiscard)
    }

    func testSelectedIDSurvivesRecoveryFinishAndClearsOnDelete() async throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
        let store = InMemoryWorkoutStore()
        let controller = WorkoutSessionController(store: store, now: { Date(timeIntervalSince1970: 1_700_010_000) })
        _ = try await controller.start(activity: .run, id: id)
        _ = try await controller.transition(to: .preparing)
        _ = try await controller.transition(to: .active)
        _ = try await controller.recoverInterrupted()

        let selectedID = await controller.selectedWorkoutID()
        let selectedAfterRecovery = await controller.selectedWorkout()
        XCTAssertEqual(selectedID, id)
        XCTAssertEqual(selectedAfterRecovery?.state, .interruptedAndRecoverable)
        _ = try await controller.resumeRecovered(id: id)
        let finished = try await controller.finish()
        XCTAssertEqual(finished.id, id)
        XCTAssertEqual(finished.state, .completed)
        let selectedAfterFinish = await controller.selectedWorkout()
        XCTAssertEqual(selectedAfterFinish?.id, id)
        try await controller.delete(id: id)
        let selectedAfterDelete = await controller.selectedWorkout()
        XCTAssertNil(selectedAfterDelete)
    }

    func testLocalShareExporterRequiresCompletedRowAndHonorsOptIns() async throws {
        let exporter = LocalWorkoutShareExporter()
        let request = WorkoutShareRequest(workoutID: WorkoutFixtures.completedRun.id, includeRoute: true, includeLocation: false)
        let preview = try await exporter.makePreview(workout: WorkoutFixtures.completedRun, request: request)
        XCTAssertTrue(preview.includesRoute)
        XCTAssertFalse(preview.includesLocation)
        XCTAssertTrue(preview.summary.contains("Run"))

        do {
            _ = try await exporter.makePreview(workout: WorkoutFixtures.interrupted, request: WorkoutShareRequest(workoutID: WorkoutFixtures.interrupted.id))
            XCTFail("interrupted records must not produce a finalized share preview")
        } catch WorkoutShareError.finalizedPreviewUnavailable { }
        catch { XCTFail("Unexpected error: \(error)") }
    }

    func testImportedWorkoutTotalsSurvivePersistenceAndListingWithoutFakeSamples() throws {
        var workout = WorkoutFixtures.completedRun
        workout.source = .imported
        workout.samples = []
        workout.importedSummary = WorkoutImportedSummary(source: "Account export", strain: 7.3, energyKcal: 220, zonePercentages: [2: 35])
        let payload = try JSONEncoder().encode(workout)
        let restored = try JSONDecoder().decode(WorkoutRecord.self, from: payload)
        let listing = try JSONDecoder().decode(WorkoutListingRowDocument.self, from: payload).row
        XCTAssertEqual(restored.importedSummary, workout.importedSummary)
        XCTAssertEqual(listing.importedSummary, workout.importedSummary)
        XCTAssertTrue(restored.samples.isEmpty)
        XCTAssertNil(restored.importedSummary?.averageHeartRate)
        var older = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        older.removeValue(forKey: "importedSummary")
        let legacy = try JSONDecoder().decode(WorkoutRecord.self, from: JSONSerialization.data(withJSONObject: older))
        XCTAssertNil(legacy.importedSummary)
    }

    func testAllFiveLogRangesUseTheSameCanonicalRows() async throws {
        let store = InMemoryWorkoutStore()
        let controller = WorkoutSessionController(store: store, now: { Date(timeIntervalSince1970: 1_700_000_000) })
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await controller.logManual(activity: .run, startedAt: now.addingTimeInterval(-3_600), endedAt: now.addingTimeInterval(-3_000))
        _ = try await controller.logManual(activity: .cycle, startedAt: now.addingTimeInterval(-8 * 86_400), endedAt: now.addingTimeInterval(-8 * 86_400 + 600))
        _ = try await controller.logManual(activity: .walk, startedAt: now.addingTimeInterval(-35 * 86_400), endedAt: now.addingTimeInterval(-35 * 86_400 + 600))
        _ = try await controller.logManual(activity: .hike, startedAt: now.addingTimeInterval(-500 * 86_400), endedAt: now.addingTimeInterval(-500 * 86_400 + 600))
        var counts: [Int] = []
        for range in WorkoutLogQuery.Range.allCases {
            counts.append(await controller.list(WorkoutLogQuery(range: range, now: now, calendar: calendar)).count)
        }
        // `week` is the inclusive local-today window (today plus six prior
        // local days), while `month`/`threeMonths` are calendar-month
        // lookbacks. The fixture's second row is eight days old and the
        // third is 35 days old, so only the month and three-month views widen
        // the result set respectively.
        XCTAssertEqual(counts, [1, 1, 2, 3, 4])
    }

    func testScreenFixturesAndTypedRoutesCoverRecoveryEntryPoints() {
        XCTAssertEqual(WorkoutFixtures.completedRun.state, .completed)
        XCTAssertEqual(WorkoutFixtures.interrupted.state, .interruptedAndRecoverable)
        XCTAssertTrue(WorkoutRoute.allCases.contains { if case .recovery = $0 { return true }; return false })
        XCTAssertTrue(WorkoutRoute.allCases.contains(.sharePreview))
    }

    func testWorkoutScreenStateMatrixAndAccessibilityFixtures() {
        XCTAssertEqual(WorkoutScreenStateFixtures.allStates.count, 14)
        XCTAssertTrue(WorkoutScreenStateFixtures.statesByScreen.values.allSatisfy { $0.count == 14 })
        XCTAssertNotEqual(WorkoutScreenStateFixtures.accessibilitySummary(for: .absent), WorkoutScreenStateFixtures.accessibilitySummary(for: .measuredZero))
        XCTAssertTrue(WorkoutScreenStateFixtures.accessibilityIdentifiers.allSatisfy { !$0.isEmpty })
    }

    func testLiveSourceBindsSamplesToSelectedSessionAndReleasesOnFinish() async throws {
        let source = LiveSourceFixture()
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000811")!
        let store = InMemoryWorkoutStore()
        let controller = WorkoutSessionController(store: store, liveSource: source)
        _ = try await controller.start(activity: .cycle, source: .live, id: id)
        _ = try await controller.transition(to: .preparing)
        _ = try await controller.transition(to: .active)
        var updates = await controller.updates(for: id).makeAsyncIterator()
        _ = await updates.next()
        await source.emit(WorkoutSample(timestamp: Date(timeIntervalSince1970: 20), heartRate: 148, distanceMeters: 12))
        let updated = await updates.next()
        XCTAssertEqual(updated?.samples.last?.heartRate, 148)
        XCTAssertEqual(updated?.activity, .cycle)
        _ = try await controller.finish(id: id)
        let releaseCount = await source.releaseCount
        XCTAssertEqual(releaseCount, 1)
    }

    func testPausingLiveWorkoutReleasesSamplesAndResumeReacquires() async throws {
        let source = LiveSourceFixture()
        let controller = WorkoutSessionController(store: InMemoryWorkoutStore(), liveSource: source)
        _ = try await controller.start(activity: .run)
        _ = try await controller.transition(to: .preparing)
        _ = try await controller.transition(to: .active)
        _ = try await controller.transition(to: .paused)
        let releasedOnPause = await source.releaseCount
        XCTAssertEqual(releasedOnPause, 1)
        _ = try await controller.transition(to: .active)
        _ = try await controller.finish()
        let releasedOnFinish = await source.releaseCount
        XCTAssertEqual(releasedOnFinish, 2)
    }

    func testDetectedRepositoryAndCorrectionCandidateRemainCanonical() async throws {
        let repository = InMemoryDetectedWorkoutRepository(detections: [WorkoutFixtures.detectedRun])
        let storedDetection = await repository.detection(id: "fixture-detected-run")
        let detection = try XCTUnwrap(storedDetection)
        let correctedStart = Date(timeIntervalSince1970: 1_700_000_500)
        let correctedEnd = Date(timeIntervalSince1970: 1_700_001_200)
        let candidate = try DetectedWorkoutCandidate.record(
            from: detection,
            activity: .hike,
            startedAt: correctedStart,
            endedAt: correctedEnd,
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000812")!
        )
        XCTAssertEqual(candidate.source, .detected)
        XCTAssertEqual(candidate.activity, .hike)
        XCTAssertEqual(candidate.identity.canonicalKey, "source:fixture-detected-run")
        try await repository.remove(id: detection.detectionID)
        let remaining = await repository.allDetections()
        XCTAssertTrue(remaining.isEmpty)
    }
}
