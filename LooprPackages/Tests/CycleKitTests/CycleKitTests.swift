import CycleKit
import XCTest

final class CycleKitTests: XCTestCase {
    func testOptInIsExplicitAndDisablePreservesHistory() async throws {
        let repository = CycleRepository()
        let initial = await repository.estimate()
        XCTAssertEqual(initial.sampleSize, 0)
        do {
            _ = try await repository.log(CycleEntry(day: "2026-08-18", kind: .periodStart))
            XCTFail("cycle events must be opt-in")
        } catch CycleError.optedOut { }

        await repository.optIn()
        let entry = try await repository.log(CycleEntry(day: "2026-08-18", kind: .periodStart))
        let populatedState = await repository.state()
        XCTAssertEqual(populatedState, .populated)
        await repository.disable()
        let disabledState = await repository.state()
        XCTAssertEqual(disabledState, .disabled)
        let history = await repository.history()
        XCTAssertEqual(history, [entry])
        do {
            try await repository.log(CycleEntry(day: "2026-08-19", kind: .flow, flow: .light))
            XCTFail("disabled cycle tracking must not accept new events")
        } catch CycleError.optedOut { }
        try await repository.enableAfterDisable()
        let isOptedIn = await repository.isOptedIn()
        XCTAssertTrue(isOptedIn)
    }

    func testEstimateUsesOnlyLoggedStartsAndLabelsUncertainty() async throws {
        let repository = CycleRepository()
        await repository.optIn()
        _ = try await repository.log(CycleEntry(day: "2026-07-01", kind: .periodStart))
        _ = try await repository.log(CycleEntry(day: "2026-07-29", kind: .periodStart))
        _ = try await repository.log(CycleEntry(day: "2026-08-26", kind: .periodStart))
        let estimate = await repository.estimate(today: "2026-08-30")
        XCTAssertEqual(estimate.sampleSize, 3)
        XCTAssertEqual(estimate.nextPeriodDay, "2026-09-23")
        XCTAssertFalse(estimate.uncertainty.lowercased().contains("medical prediction"))
        XCTAssertTrue(CycleRelationshipCopy(metric: "sleep", phase: estimate.phase).text.contains("does not establish causation"))
    }

    func testIrregularHistoryLowersConfidenceAndExportRoundTrips() async throws {
        let regular = CycleRepository()
        await regular.optIn()
        for day in ["2026-01-01", "2026-01-29", "2026-02-26"] {
            _ = try await regular.log(CycleEntry(day: day, kind: .periodStart))
        }
        let regularEstimate = await regular.estimate(today: "2026-03-01")

        let irregular = CycleRepository()
        await irregular.optIn()
        for day in ["2026-01-01", "2026-01-20", "2026-03-25"] {
            _ = try await irregular.log(CycleEntry(day: day, kind: .periodStart))
        }
        let irregularEstimate = await irregular.estimate(today: "2026-03-26")
        XCTAssertLessThan(irregularEstimate.confidence, regularEstimate.confidence)
        XCTAssertTrue(irregularEstimate.uncertainty.contains("Irregular"))
        let export = await irregular.export()
        XCTAssertEqual(export.entries.count, 3)
        XCTAssertEqual(export.entries.map(\.day), ["2026-01-01", "2026-01-20", "2026-03-25"])
    }

    func testInvalidDayAndDeleteAllAreSafe() async throws {
        let repository = CycleRepository()
        await repository.optIn()
        do {
            _ = try await repository.log(CycleEntry(day: "18/08/2026", kind: .symptom))
            XCTFail("day labels must be canonical ISO local days")
        } catch CycleError.invalidDay { }
        try await repository.updateSettings(CycleSettings(remindersEnabled: true, reminderHour: 8))
        await repository.deleteAll()
        let state = await repository.state()
        let settings = await repository.currentSettings()
        XCTAssertEqual(state, .optedOut)
        XCTAssertEqual(settings, CycleSettings())
    }

    func testCycleFixtureKeepsUncertaintyVisible() {
        XCTAssertEqual(CycleFixtures.optedInEstimate.sampleSize, 2)
        XCTAssertTrue(CycleFixtures.optedInEstimate.uncertainty.contains("may vary"))
        XCTAssertTrue(CycleRoute.allCases.contains(.reminders))
    }

    func testCycleEventNamesAreReadyForDisplay() {
        XCTAssertEqual(CycleEventKind.periodStart.displayName, "Period start")
        XCTAssertEqual(CycleEventKind.flow.displayName, "Flow")
        XCTAssertEqual(CycleEventKind.symptom.displayName, "Symptom")
        XCTAssertFalse(CycleEventKind.allCases.map(\.displayName).contains("Periodstart"))
    }

    func testCycleScreenStateMatrixAndAccessibilityFixtures() {
        XCTAssertEqual(CycleScreenStateFixtures.allStates.count, 14)
        XCTAssertTrue(CycleScreenStateFixtures.statesByScreen.values.allSatisfy { $0.count == 14 })
        XCTAssertNotEqual(CycleScreenStateFixtures.accessibilitySummary(for: .absent), CycleScreenStateFixtures.accessibilitySummary(for: .measuredZero))
        XCTAssertTrue(CycleScreenStateFixtures.accessibilityIdentifiers.allSatisfy { !$0.isEmpty })
    }

    @MainActor
    func testReminderDenialDoesNotPersistCycleSettings() async throws {
        let repository = CycleRepository()
        await repository.optIn()
        let scheduler = RecordingCycleReminderScheduler(result: .failure(.reminderDenied))
        let viewModel = CycleViewModel(repository: repository, reminderScheduler: scheduler)

        await viewModel.updateReminders(enabled: true, hour: 8)

        XCTAssertEqual(viewModel.actionError, .reminderDenied)
        let currentSettings = await repository.currentSettings()
        let scheduledHours = await scheduler.scheduledHours()
        XCTAssertEqual(currentSettings, CycleSettings())
        XCTAssertEqual(scheduledHours, [])
    }

    @MainActor
    func testReminderScheduleAndCancelUseTheInjectedBoundary() async throws {
        let repository = CycleRepository()
        await repository.optIn()
        let scheduler = RecordingCycleReminderScheduler(result: .success(()))
        let viewModel = CycleViewModel(repository: repository, reminderScheduler: scheduler)

        await viewModel.updateReminders(enabled: true, hour: 7)
        XCTAssertNil(viewModel.actionError)
        let enabledSettings = await repository.currentSettings()
        let scheduledHours = await scheduler.scheduledHours()
        XCTAssertEqual(enabledSettings, CycleSettings(remindersEnabled: true, reminderHour: 7))
        XCTAssertEqual(scheduledHours, [7])

        await viewModel.updateReminders(enabled: false, hour: 7)
        XCTAssertNil(viewModel.actionError)
        let disabledSettings = await repository.currentSettings()
        let cancellationCount = await scheduler.cancelCount()
        XCTAssertEqual(disabledSettings, CycleSettings())
        XCTAssertEqual(cancellationCount, 1)
    }

    @MainActor
    func testCycleWriteFailureIsVisibleAndDoesNotReportOptInSuccess() async {
        let repository = FailingCycleStore()
        let viewModel = CycleViewModel(repository: repository)

        let optedIn = await viewModel.optIn()
        await viewModel.log(CycleEntry(day: "2026-08-18", kind: .periodStart))

        XCTAssertFalse(optedIn)
        XCTAssertEqual(viewModel.actionError, .storageUnavailable)
    }

    @MainActor
    func testCycleReadFailureIsNotPresentedAsEmptyHistory() async {
        let viewModel = CycleViewModel(repository: FailingCycleStore())

        let loaded = await viewModel.load()

        XCTAssertFalse(loaded)
        XCTAssertEqual(viewModel.snapshot.state, .error)
        XCTAssertEqual(viewModel.actionError, .storageUnavailable)
    }

    @MainActor
    func testReminderScheduleIsCancelledWhenSettingsCannotBeSaved() async {
        let repository = FailingCycleStore()
        let scheduler = RecordingCycleReminderScheduler(result: .success(()))
        let viewModel = CycleViewModel(repository: repository, reminderScheduler: scheduler)

        await viewModel.updateReminders(enabled: true, hour: 8)

        XCTAssertEqual(viewModel.actionError, .storageUnavailable)
        let scheduledHours = await scheduler.scheduledHours()
        let cancellationCount = await scheduler.cancelCount()
        XCTAssertEqual(scheduledHours, [8])
        XCTAssertEqual(cancellationCount, 1)
    }

    @MainActor
    func testReminderIsRestoredWhenDisablingCannotBeSaved() async {
        let repository = SettingsWriteFailingCycleStore()
        let scheduler = RecordingCycleReminderScheduler(result: .success(()))
        let viewModel = CycleViewModel(repository: repository, reminderScheduler: scheduler)
        _ = await viewModel.load()

        await viewModel.updateReminders(enabled: false, hour: 7)

        let cancellationCount = await scheduler.cancelCount()
        let scheduledHours = await scheduler.scheduledHours()
        XCTAssertEqual(viewModel.actionError, .storageUnavailable)
        XCTAssertEqual(cancellationCount, 1)
        XCTAssertEqual(scheduledHours, [7])
    }

    @MainActor
    func testDisableDoesNotClaimSuccessWhenReminderCleanupFails() async {
        let repository = CycleRepository()
        await repository.optIn()
        let scheduler = RecordingCycleReminderScheduler(result: .failure(.reminderUnavailable))
        let viewModel = CycleViewModel(repository: repository, reminderScheduler: scheduler)

        await viewModel.disable()

        XCTAssertEqual(viewModel.actionError, .reminderUnavailable)
        let state = await repository.state()
        XCTAssertEqual(state, .optedIn)
    }

    @MainActor
    func testDisableRestoresReminderWhenStorageMutationFails() async {
        let repository = MutationFailingCycleStore()
        let scheduler = RecordingCycleReminderScheduler(result: .success(()))
        let viewModel = CycleViewModel(repository: repository, reminderScheduler: scheduler)

        await viewModel.disable()

        let cancellationCount = await scheduler.cancelCount()
        let scheduledHours = await scheduler.scheduledHours()
        XCTAssertEqual(viewModel.actionError, .storageUnavailable)
        XCTAssertEqual(cancellationCount, 1)
        XCTAssertEqual(scheduledHours, [7])
    }

    @MainActor
    func testDeleteAllRestoresReminderWhenStorageMutationFails() async {
        let repository = MutationFailingCycleStore()
        let scheduler = RecordingCycleReminderScheduler(result: .success(()))
        let viewModel = CycleViewModel(repository: repository, reminderScheduler: scheduler)

        await viewModel.deleteAll()

        let cancellationCount = await scheduler.cancelCount()
        let scheduledHours = await scheduler.scheduledHours()
        XCTAssertEqual(viewModel.actionError, .storageUnavailable)
        XCTAssertEqual(cancellationCount, 1)
        XCTAssertEqual(scheduledHours, [7])
    }
}

private actor FailingCycleStore: CycleStore {
    private struct WriteFailure: Error {}

    func state() throws -> CycleState { throw WriteFailure() }
    func isOptedIn() throws -> Bool { throw WriteFailure() }
    func optIn() throws { throw WriteFailure() }
    func disable() throws { throw WriteFailure() }
    func enableAfterDisable() throws { throw WriteFailure() }
    func deleteAll() throws { throw WriteFailure() }
    func log(_ entry: CycleEntry) throws -> CycleEntry { throw WriteFailure() }
    func history() throws -> [CycleEntry] { throw WriteFailure() }
    func delete(id: UUID) throws { throw WriteFailure() }
    func updateSettings(_ newValue: CycleSettings) throws { throw WriteFailure() }
    func currentSettings() throws -> CycleSettings { throw WriteFailure() }
    func estimate(today: String?) throws -> CycleEstimate { throw WriteFailure() }
    func export() throws -> CycleExport { throw WriteFailure() }
}

private actor SettingsWriteFailingCycleStore: CycleStore {
    private struct WriteFailure: Error {}
    private let storedSettings = CycleSettings(remindersEnabled: true, reminderHour: 7)

    func state() -> CycleState { .optedIn }
    func isOptedIn() -> Bool { true }
    func optIn() {}
    func disable() {}
    func enableAfterDisable() {}
    func deleteAll() {}
    func log(_ entry: CycleEntry) -> CycleEntry { entry }
    func history() -> [CycleEntry] { [] }
    func delete(id: UUID) {}
    func updateSettings(_ newValue: CycleSettings) throws { throw WriteFailure() }
    func currentSettings() -> CycleSettings { storedSettings }
    func estimate(today: String?) -> CycleEstimate {
        CycleEstimate(phase: .unknown, confidence: 0, uncertainty: "No estimate", sampleSize: 0)
    }
    func export() -> CycleExport { CycleExport(entries: [], settings: storedSettings) }
}

private actor MutationFailingCycleStore: CycleStore {
    private struct WriteFailure: Error {}
    private let storedSettings = CycleSettings(remindersEnabled: true, reminderHour: 7)

    func state() -> CycleState { .optedIn }
    func isOptedIn() -> Bool { true }
    func optIn() {}
    func disable() throws { throw WriteFailure() }
    func enableAfterDisable() {}
    func deleteAll() throws { throw WriteFailure() }
    func log(_ entry: CycleEntry) -> CycleEntry { entry }
    func history() -> [CycleEntry] { [] }
    func delete(id: UUID) {}
    func updateSettings(_ newValue: CycleSettings) {}
    func currentSettings() -> CycleSettings { storedSettings }
    func estimate(today: String?) -> CycleEstimate {
        CycleEstimate(phase: .unknown, confidence: 0, uncertainty: "No estimate", sampleSize: 0)
    }
    func export() -> CycleExport { CycleExport(entries: [], settings: storedSettings) }
}

private actor RecordingCycleReminderScheduler: CycleReminderScheduler {
    enum Result: Sendable {
        case success(Void)
        case failure(CycleError)
    }

    private let result: Result
    private var hours: [Int] = []
    private var cancellations = 0

    init(result: Result) {
        self.result = result
    }

    func schedule(settings: CycleSettings) async throws {
        if case .failure(let error) = result {
            throw error
        }
        if let hour = settings.reminderHour {
            hours.append(hour)
        }
    }

    func cancel() async throws {
        cancellations += 1
        if case .failure(let error) = result {
            throw error
        }
    }

    func scheduledHours() -> [Int] { hours }
    func cancelCount() -> Int { cancellations }
}
