import Foundation

/// An actor alone is reentrant at every await. Keep each complete alarm
/// transaction together, including its band confirmation and phone schedule.
actor LooprAlarmOperationQueue {
    static let shared = LooprAlarmOperationQueue()

    private var locked = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var isArming = false

    func withLock<T: Sendable>(_ operation: @Sendable () async throws -> T) async rethrows -> T {
        if locked {
            await withCheckedContinuation { waiting.append($0) }
        } else {
            locked = true
        }
        defer {
            if waiting.isEmpty {
                locked = false
            } else {
                waiting.removeFirst().resume()
            }
        }
        return try await operation()
    }

    func setArming(_ value: Bool) {
        isArming = value
    }
}
