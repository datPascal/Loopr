import Foundation

/// Caps haptic ticks: at most `maximumPerSecond` in any trailing second and no two closer than
/// `minimumInterval`. Time comes from the caller, so a test can drive it with any clock.
public struct LooprHapticLimiter: Equatable, Sendable {
    public let maximumPerSecond: Int
    public let minimumInterval: TimeInterval
    public private(set) var fired = 0
    public private(set) var coalesced = 0
    private var recent: [TimeInterval] = []

    public init(maximumPerSecond: Int = 30, minimumInterval: TimeInterval? = nil) {
        self.maximumPerSecond = max(maximumPerSecond, 1)
        self.minimumInterval = minimumInterval ?? 1.0 / Double(max(maximumPerSecond, 1))
    }

    /// True when a tick may play at `time`. A refused tick is coalesced into the last one played.
    public mutating func shouldFire(at time: TimeInterval) -> Bool {
        recent.removeAll { $0 <= time - 1 }
        if let last = recent.last, time - last < minimumInterval - 1e-9 {
            coalesced += 1
            return false
        }
        guard recent.count < maximumPerSecond else {
            coalesced += 1
            return false
        }
        recent.append(time)
        fired += 1
        return true
    }
}
