import Foundation

public struct Gen5R22Reservation: Equatable, Sendable {
    public let sequences: [UInt8]
    fileprivate init(sequences: [UInt8]) { self.sequences = sequences }
}

public enum Gen5R22ReservationError: Error, Equatable, Sendable {
    case collision
    case sequenceNotReserved(UInt8)
    case memoryBoundExceeded
}

public actor Gen5R22SequenceAllocator {
    private var reserved = Set<UInt8>()

    public init() {}

    public func reserveSixteen(startingAt start: UInt8) throws -> Gen5R22Reservation {
        let candidates = (0..<16).map { start &+ UInt8($0) }
        guard candidates.allSatisfy({ !reserved.contains($0) }) else {
            throw Gen5R22ReservationError.collision
        }
        reserved.formUnion(candidates)
        return Gen5R22Reservation(sequences: candidates)
    }

    public func release(_ reservation: Gen5R22Reservation) {
        reserved.subtract(reservation.sequences)
    }

    public func reservationCount() -> Int { reserved.count }
}

public struct Gen5R22StoredFrame: Equatable, Sendable {
    public let sequence: UInt8
    public let bytes: Data
}

public struct Gen5R22FrameStore: Sendable {
    public static let maximumBytes = 64 * 1024
    private let allowed: Set<UInt8>
    private var stored: [Gen5R22StoredFrame] = []
    private var byteCount = 0

    public init(reservation: Gen5R22Reservation) { allowed = Set(reservation.sequences) }

    public mutating func append(sequence: UInt8, bytes: Data) throws {
        guard allowed.contains(sequence) else { throw Gen5R22ReservationError.sequenceNotReserved(sequence) }
        guard byteCount + bytes.count <= Self.maximumBytes else {
            throw Gen5R22ReservationError.memoryBoundExceeded
        }
        stored.append(.init(sequence: sequence, bytes: Data(bytes)))
        byteCount += bytes.count
    }

    public var frames: [Gen5R22StoredFrame] { stored }
}

public enum Gen5V20LayoutResolution: Equatable, Sendable {
    case unresolvedRawArchiveOnly(reason: String)
}

public enum Gen5V20Policy {
    public static let resolution: Gen5V20LayoutResolution = .unresolvedRawArchiveOnly(
        reason: "Competing layouts have only structural synthetic evidence; real captures are required"
    )
    public static let metricMappingEnabled = false
}
