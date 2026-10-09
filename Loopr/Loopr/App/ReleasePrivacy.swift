import Foundation

enum ReleaseLogEvent: Equatable, Sendable {
    case healthMetrics(sampleCount: Int)
    case route(pointCount: Int)
    case journal(entryCount: Int)
    case bluetoothFrame(byteCount: Int)
}

enum ReleaseLogFormatter {
    static func format(_ event: ReleaseLogEvent) -> String {
        switch event {
        case .healthMetrics(let count): "health_metrics count=\(count) payload=[REDACTED]"
        case .route(let count): "route points=\(count) coordinates=[REDACTED]"
        case .journal(let count): "journal entries=\(count) text=[REDACTED]"
        case .bluetoothFrame(let count): "bluetooth_frame bytes=\(count) payload=[REDACTED]"
        }
    }
}

struct SupportDiagnosticsInput: Sendable {
    let peripheralIdentifier: UUID?
    let eventCount: Int
    let storageRowCount: Int
    let rawHealthPayload: Data?
    let rawProtocolFrames: [Data]
}

struct RedactedSupportDiagnostics: Codable, Equatable, Sendable {
    let peripheral: String
    let eventCount: Int
    let storageRowCount: Int
    let rawPayloadsIncluded: Bool
}

enum SupportDiagnosticsError: Error, Equatable, Sendable {
    case confirmationRequired
}

enum SupportDiagnosticsExporter {
    static func preview(_ input: SupportDiagnosticsInput) -> RedactedSupportDiagnostics {
        RedactedSupportDiagnostics(
            peripheral: input.peripheralIdentifier == nil ? "absent" : "[REDACTED]",
            eventCount: input.eventCount,
            storageRowCount: input.storageRowCount,
            rawPayloadsIncluded: false
        )
    }

    static func export(_ input: SupportDiagnosticsInput, userConfirmed: Bool) throws -> Data {
        guard userConfirmed else { throw SupportDiagnosticsError.confirmationRequired }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(preview(input))
    }
}
