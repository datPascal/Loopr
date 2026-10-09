import Foundation

public enum Gen5GenerationFenceError: Error, Equatable, Sendable {
    case stale(expected: UInt64, received: UInt64)
}

public actor Gen5GenerationFence {
    private var current: UInt64

    public init(initialGeneration: UInt64 = 0) { current = initialGeneration }

    @discardableResult
    public func beginNewConnection() -> UInt64 {
        current &+= 1
        return current
    }

    public func authorize(_ generation: UInt64) throws {
        guard generation == current else {
            throw Gen5GenerationFenceError.stale(expected: current, received: generation)
        }
    }
}
