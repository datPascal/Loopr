import Foundation

public enum ConnectionDiagnosticsKind: String, Codable, CaseIterable, Hashable, Sendable {
    case advertisementSeen
    case gattDiscovery
    case notificationSubscription
    case clockSet
    case clockGet
    case initializationWriteResponse
    case historyMetadataReceived
    case error
    case writeStarted
    case writeCompleted
    case historyDrainStarted
    case historyDrainCompleted
    case historyCommitted
    case acknowledgementEmitted
    case dangerousOpcodeAttempt
    case staleAcknowledgement
    case doubleWrite
    case doubleDrain
    case staleConnection
    case validFrame
    case corruptFrame
}

/// A diagnostics event contains protocol/lifecycle metadata only.  Health
/// payload bytes are never represented by this type.
public struct ConnectionDiagnosticsEvent: Equatable, Sendable {
    public let kind: ConnectionDiagnosticsKind
    public let timestamp: Date
    public let generation: UInt64
    public let correlationID: String?
    public let opcode: UInt8?
    public let label: String?
    public let detail: String?

    public init(
        kind: ConnectionDiagnosticsKind,
        timestamp: Date,
        generation: UInt64,
        correlationID: String? = nil,
        opcode: UInt8? = nil,
        label: String? = nil,
        detail: String? = nil
    ) {
        self.kind = kind
        self.timestamp = timestamp
        self.generation = generation
        self.correlationID = correlationID
        self.opcode = opcode
        self.label = label.map(DiagnosticsHex.redacted)
        self.detail = detail.map(DiagnosticsHex.redacted)
    }
}

public enum ConnectionDiagnosticsViolation: Equatable, Sendable {
    case dangerousOpcode(UInt8)
    case staleAcknowledgement(String?)
    case doubleWrite(String?)
    case doubleDrain(String?)
    case acknowledgementBeforeCommit(String?)
}

public struct ConnectionDiagnosticsSnapshot: Equatable, Sendable {
    public let events: [ConnectionDiagnosticsEvent]
    public let violations: [ConnectionDiagnosticsViolation]

    public init(
        events: [ConnectionDiagnosticsEvent],
        violations: [ConnectionDiagnosticsViolation]
    ) {
        self.events = events
        self.violations = violations
    }

    public var isSafe: Bool { violations.isEmpty }
}

public enum ConnectionDiagnosticsAudit {
    private struct GenerationCorrelation: Hashable {
        let generation: UInt64
        let correlationID: String
    }

    public static let dangerousOpcodes: Set<UInt8> = [
        0x19, // force trim
        0x1D, // reboot
        0x20, // power cycle
        0x9A, // persistent raw/R21
        0x24, // firmware family
        0x25,
        0x26
    ]

    public static func violations(
        in events: [ConnectionDiagnosticsEvent]
    ) -> [ConnectionDiagnosticsViolation] {
        var result: [ConnectionDiagnosticsViolation] = []
        var inFlightWrites = Set<GenerationCorrelation>()
        var inFlightDrains = Set<GenerationCorrelation>()
        var committedBatches = Set<GenerationCorrelation>()
        var committedCorrelationIDs = Set<String>()
        var highestGeneration: UInt64 = 0

        for event in events {
            highestGeneration = max(highestGeneration, event.generation)
            if let opcode = event.opcode, dangerousOpcodes.contains(opcode) {
                result.append(.dangerousOpcode(opcode))
            }

            let correlationKey: (String) -> GenerationCorrelation = {
                GenerationCorrelation(generation: event.generation, correlationID: $0)
            }
            let lifecycleKey = correlationKey(event.correlationID ?? "<generation>")

            switch event.kind {
            case .dangerousOpcodeAttempt:
                if let opcode = event.opcode {
                    result.append(.dangerousOpcode(opcode))
                }
            case .staleAcknowledgement:
                result.append(.staleAcknowledgement(event.correlationID))
            case .doubleWrite:
                result.append(.doubleWrite(event.correlationID))
            case .doubleDrain:
                result.append(.doubleDrain(event.correlationID))
            case .writeStarted:
                if !inFlightWrites.insert(lifecycleKey).inserted {
                    result.append(.doubleWrite(event.correlationID))
                }
            case .writeCompleted:
                inFlightWrites.remove(lifecycleKey)
            case .historyDrainStarted:
                if !inFlightDrains.insert(lifecycleKey).inserted {
                    result.append(.doubleDrain(event.correlationID))
                }
            case .historyDrainCompleted:
                inFlightDrains.remove(lifecycleKey)
            case .historyCommitted:
                if let correlationID = event.correlationID {
                    committedBatches.insert(correlationKey(correlationID))
                    committedCorrelationIDs.insert(correlationID)
                }
            case .acknowledgementEmitted:
                guard let correlationID = event.correlationID else {
                    result.append(.acknowledgementBeforeCommit(nil))
                    continue
                }
                let key = correlationKey(correlationID)
                if event.generation < highestGeneration {
                    // A callback from an older session after a newer
                    // generation has appeared is stale even if that old
                    // generation did commit the same batch.
                    result.append(.staleAcknowledgement(correlationID))
                } else if !committedBatches.contains(key),
                          committedCorrelationIDs.contains(correlationID) {
                    // The ID was committed, but not by this generation.
                    result.append(.staleAcknowledgement(correlationID))
                } else if !committedBatches.contains(key) {
                    result.append(.acknowledgementBeforeCommit(correlationID))
                }
            case .advertisementSeen, .gattDiscovery, .notificationSubscription,
                 .clockSet, .clockGet, .initializationWriteResponse,
                 .historyMetadataReceived, .error,
                 .staleConnection, .validFrame, .corruptFrame:
                break
            }
        }
        return result
    }
}

public enum DiagnosticsHex {
    public static func redacted(_ value: String) -> String {
        let patterns = [
            #"(?i)\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b"#,
            #"(?i)\b(?:[0-9a-f]{2}[ :\-]){3,}[0-9a-f]{2}\b"#,
            #"(?i)\b[0-9a-f]{8,}\b"#
        ]
        return patterns.reduce(value) { partial, pattern in
            partial.replacingOccurrences(
                of: pattern,
                with: "<redacted>",
                options: .regularExpression
            )
        }
    }
}

/// Bounded actor-owned diagnostics log shared by simulator regression tests
/// and the eventual app diagnostics surface.
public actor ConnectionDiagnosticsRecorder {
    public static let defaultCapacity = 1_024
    private let capacity: Int
    private var eventsStorage: [ConnectionDiagnosticsEvent] = []

    public init(capacity: Int = ConnectionDiagnosticsRecorder.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    public func record(_ event: ConnectionDiagnosticsEvent) {
        eventsStorage.append(event)
        if eventsStorage.count > capacity {
            eventsStorage.removeFirst(eventsStorage.count - capacity)
        }
    }

    public func events() -> [ConnectionDiagnosticsEvent] { eventsStorage }

    public func snapshot() -> ConnectionDiagnosticsSnapshot {
        let events = eventsStorage
        return ConnectionDiagnosticsSnapshot(
            events: events,
            violations: ConnectionDiagnosticsAudit.violations(in: events)
        )
    }

    public func audit() -> [ConnectionDiagnosticsViolation] {
        ConnectionDiagnosticsAudit.violations(in: eventsStorage)
    }

    public func reset() { eventsStorage.removeAll(keepingCapacity: true) }
}
