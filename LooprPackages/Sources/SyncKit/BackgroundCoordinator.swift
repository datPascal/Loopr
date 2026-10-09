import Foundation

public enum BackgroundRunKind: String, Codable, CaseIterable, Sendable {
    case restoration
    case processing
    case appRefresh
}

public enum BackgroundExpirationAction: String, Codable, CaseIterable, Sendable {
    case completeOrRollbackTransaction
    case preserveTokenAndCursor
    case stopBLEWork
    case checkpointActiveWorkout
    case deferAnalyticsHealthWidgetsNotifications
}

public enum BackgroundCoordinatorState: String, Codable, CaseIterable, Sendable {
    case idle
    case background
    case foreground
    case stale
}

public enum BackgroundCoordinatorError: Error, Equatable, Sendable, LocalizedError {
    case busy
    case taskAlreadyFinished

    public var errorDescription: String? {
        switch self {
        case .busy:
            return "Another Bluetooth operation already owns the serialized coordinator."
        case .taskAlreadyFinished:
            return "The background task has already finished."
        }
    }
}

/// The background coordinator does not know how to write SQLite or stop BLE;
/// those operations are supplied by the session/storage owner.  Keeping the
/// five expiration actions typed makes their safety order testable.
public protocol BackgroundWorkDriver: Sendable {
    func performExpiration(_ action: BackgroundExpirationAction) async
    func markConnectionStale() async
}

public final class BackgroundTaskCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var didComplete = false
    private let callback: @Sendable (Bool) -> Void

    public init(callback: @escaping @Sendable (Bool) -> Void = { _ in }) {
        self.callback = callback
    }

    /// Invokes the OS completion callback at most once, regardless of whether
    /// normal completion, cancellation, expiration, and task cleanup race.
    @discardableResult
    public func complete(success: Bool) -> Bool {
        let shouldComplete = lock.withLock {
            guard !didComplete else { return false }
            didComplete = true
            return true
        }
        guard shouldComplete else { return false }
        callback(success)
        return true
    }

    public var isComplete: Bool { lock.withLock { didComplete } }
}

public final class BackgroundTaskHandle: @unchecked Sendable {
    public let id: UUID
    public let kind: BackgroundRunKind
    public let completion: BackgroundTaskCompletion
    private let cancelAction: @Sendable () async -> Void

    fileprivate init(
        id: UUID,
        kind: BackgroundRunKind,
        completion: BackgroundTaskCompletion,
        cancelAction: @escaping @Sendable () async -> Void
    ) {
        self.id = id
        self.kind = kind
        self.completion = completion
        self.cancelAction = cancelAction
    }

    public func cancel() async { await cancelAction() }
}

/// Bridges an unstructured task completion and a deadline without putting a
/// non-cooperative task in a structured task group.  A task that ignores
/// cancellation may continue in the background, but expiration itself still
/// returns and the coordinator keeps that run quarantined until it exits.
private final class BackgroundTaskWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var didFinish = false

    func install(_ continuation: CheckedContinuation<Bool, Never>) {
        let resumeImmediately = lock.withLock {
            if didFinish { return true }
            self.continuation = continuation
            return false
        }
        if resumeImmediately { continuation.resume(returning: false) }
    }

    func finish(completed: Bool) {
        let continuation: CheckedContinuation<Bool, Never>? = lock.withLock {
            guard !didFinish else { return nil }
            didFinish = true
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(returning: completed)
    }
}

/// One serialized owner for restoration, BGProcessing, and BGAppRefresh.
///
/// A foreground request first cancels and awaits the background operation, so
/// no foreground GATT work can overlap a background-driven operation.  Task
/// completion is guarded by `BackgroundTaskCompletion`, making expiration and
/// normal completion races harmless.
public actor BackgroundCoordinator {
    public static let defaultCancellationGraceNanoseconds: UInt64 = 1_000_000_000

    private struct ActiveRun {
        let id: UUID
        let kind: BackgroundRunKind
        let completion: BackgroundTaskCompletion
        var task: Task<Void, Never>?
    }

    private let makeID: @Sendable () -> UUID
    private let cancellationGraceNanoseconds: UInt64
    private var activeRun: ActiveRun?
    private var foregroundActive = false
    private var state: BackgroundCoordinatorState = .idle

    public init(
        makeID: @escaping @Sendable () -> UUID = { UUID() },
        cancellationGraceNanoseconds: UInt64 = BackgroundCoordinator.defaultCancellationGraceNanoseconds
    ) {
        self.makeID = makeID
        self.cancellationGraceNanoseconds = cancellationGraceNanoseconds
    }

    public func currentState() -> BackgroundCoordinatorState { state }
    public func hasActiveBackgroundTask() -> Bool { activeRun != nil }
    public func isForegroundActive() -> Bool { foregroundActive }

    /// Starts one background run.  A second BGTask is rejected while the
    /// first owns the coordinator, preventing two drains from sharing GATT.
    public func startBackground(
        id: UUID? = nil,
        kind: BackgroundRunKind,
        completion: BackgroundTaskCompletion = BackgroundTaskCompletion(),
        work: @escaping @Sendable () async -> Void
    ) -> BackgroundTaskHandle? {
        guard activeRun == nil, !foregroundActive else { return nil }

        let runID = id ?? makeID()
        activeRun = ActiveRun(id: runID, kind: kind, completion: completion, task: nil)
        state = .background

        let task = Task { [weak self] in
            await work()
            await self?.finishBackground(id: runID, success: !Task.isCancelled)
        }
        activeRun?.task = task

        return BackgroundTaskHandle(
            id: runID,
            kind: kind,
            completion: completion,
            cancelAction: { [weak self] in
                await self?.cancelBackground(id: runID)
            }
        )
    }

    /// Preempts the background run and awaits its cancellation before running
    /// foreground work.  If a cancellation-aware operation is still unwinding,
    /// this method waits rather than risking overlapping GATT operations.
    public func runForeground<T: Sendable>(
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard !foregroundActive else { throw BackgroundCoordinatorError.busy }
        foregroundActive = true
        state = .foreground
        defer {
            foregroundActive = false
            if activeRun == nil { state = .idle }
        }

        if let active = activeRun {
            active.task?.cancel()
            await active.task?.value
            finishBackground(id: active.id, success: false)
        }
        return try await operation()
    }

    /// Applies Gate H's exact expiration priority.  The current transaction
    /// action is awaited first, followed by cursor preservation, BLE stop,
    /// workout checkpoint, and only then downstream deferral/stale reporting.
    @discardableResult
    public func expireActive(
        driver: any BackgroundWorkDriver
    ) async -> Bool {
        guard let active = activeRun else { return false }

        active.task?.cancel()
        await driver.performExpiration(.completeOrRollbackTransaction)
        await driver.performExpiration(.preserveTokenAndCursor)
        await driver.performExpiration(.stopBLEWork)
        await driver.performExpiration(.checkpointActiveWorkout)
        await driver.performExpiration(.deferAnalyticsHealthWidgetsNotifications)
        await driver.markConnectionStale()

        let completed = await waitForTaskOrTimeout(active.task)
        if activeRun?.id == active.id, completed {
            activeRun = nil
        }
        if activeRun?.id == active.id {
            // Keep a non-cooperative cancelled task owned by the coordinator;
            // this prevents a later foreground/background run from touching
            // GATT while the abandoned closure is still executing.
        }
        state = .stale
        _ = active.completion.complete(success: false)
        return true
    }

    @discardableResult
    public func cancelBackground(id: UUID) async -> Bool {
        guard let active = activeRun, active.id == id else { return false }
        active.task?.cancel()
        await active.task?.value
        activeRun = nil
        state = .idle
        _ = active.completion.complete(success: false)
        return true
    }

    private func finishBackground(id: UUID, success: Bool) {
        guard let active = activeRun, active.id == id else { return }
        activeRun = nil
        state = success ? .idle : .stale
        _ = active.completion.complete(success: success)
    }

    /// Waits at most the configured grace period.  The watcher awaiting the
    /// task is intentionally unstructured, because `Task.cancel()` cannot
    /// force a closure that never checks cancellation to return.
    private func waitForTaskOrTimeout(_ task: Task<Void, Never>?) async -> Bool {
        guard let task else { return true }
        let waiter = BackgroundTaskWaiter()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                waiter.install(continuation)
                Task {
                    await task.value
                    waiter.finish(completed: true)
                }
                Task {
                    if cancellationGraceNanoseconds > 0 {
                        try? await Task.sleep(nanoseconds: cancellationGraceNanoseconds)
                    }
                    waiter.finish(completed: false)
                }
            }
        }, onCancel: {
            waiter.finish(completed: false)
        })
    }
}
