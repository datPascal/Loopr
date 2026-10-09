import Foundation
import ProtocolKit

public struct Gen5ShadowFrame: Equatable, Sendable {
    public let model: BandModel
    public let connectionGeneration: UInt64
    public let burstID: UUID
    public let rawFrame: Data
    public let marker: Data
    public let token: Data?
    public let decodeOutcome: String

    public init(
        model: BandModel,
        connectionGeneration: UInt64,
        burstID: UUID,
        rawFrame: Data,
        marker: Data,
        token: Data?,
        decodeOutcome: String
    ) {
        self.model = model
        self.connectionGeneration = connectionGeneration
        self.burstID = burstID
        self.rawFrame = rawFrame
        self.marker = marker
        self.token = token
        self.decodeOutcome = decodeOutcome
    }
}

public protocol Gen5ShadowLedgerSink: Sendable {
    func append(_ frame: Gen5ShadowFrame, ordinal: Int) async throws
}

public enum Gen5ShadowModePolicy {
    public static let sendsAcknowledgement = false
    public static let requestsDeepBuffers = false
    public static let encodableHistoryCommands: Set<String> = ["dataRange", "boundedHistory"]
}

/// One actor is the ordered queue for shadow frames. Its public surface has no
/// ACK callback and no deep-buffer command, so either action is absent by
/// construction while research evidence is unverified.
public actor Gen5ShadowModeCoordinator {
    private let sink: any Gen5ShadowLedgerSink
    private var nextOrdinalByBurst: [UUID: Int] = [:]

    public init(sink: any Gen5ShadowLedgerSink) { self.sink = sink }

    public func receive(_ frame: Gen5ShadowFrame) async throws {
        let ordinal = nextOrdinalByBurst[frame.burstID, default: 0]
        try await sink.append(frame, ordinal: ordinal)
        nextOrdinalByBurst[frame.burstID] = ordinal + 1
    }
}
