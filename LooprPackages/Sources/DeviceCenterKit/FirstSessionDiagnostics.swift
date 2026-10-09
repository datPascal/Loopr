import Foundation
import SyncKit

public enum DeviceFirstSessionDiagnosticCategory: String, CaseIterable, Hashable, Sendable {
    case advertisement
    case gattDiscovery
    case notificationSubscription
    case clockSet
    case clockGet
    case initializationWrite
    case historyMetadata
    case historyCommit
    case historyAcknowledgement
    case error
}

public struct DeviceFirstSessionDiagnosticRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let category: DeviceFirstSessionDiagnosticCategory
    public let title: String
    public let detail: String
    public let timestamp: Date?

    public init(
        id: String,
        category: DeviceFirstSessionDiagnosticCategory,
        title: String,
        detail: String,
        timestamp: Date?
    ) {
        self.id = id
        self.category = category
        self.title = DiagnosticsHex.redacted(title)
        self.detail = DiagnosticsHex.redacted(detail)
        self.timestamp = timestamp
    }
}

public struct DeviceFirstSessionDiagnostics: Equatable, Sendable {
    public let rows: [DeviceFirstSessionDiagnosticRow]
    public let errors: [DeviceFirstSessionDiagnosticRow]
    public let committedChunkCount: Int
    public let acknowledgedChunkCount: Int

    public init(snapshot: ConnectionDiagnosticsSnapshot) {
        let events = snapshot.events
        committedChunkCount = events.count { $0.kind == .historyCommitted }
        acknowledgedChunkCount = events.count { $0.kind == .acknowledgementEmitted }

        var result: [DeviceFirstSessionDiagnosticRow] = []
        Self.appendLatest(.advertisementSeen, as: .advertisement, from: events, to: &result)
        Self.appendLatest(.gattDiscovery, as: .gattDiscovery, from: events, to: &result)
        Self.appendAll(.notificationSubscription, as: .notificationSubscription, from: events, to: &result)
        Self.appendLatest(.clockSet, as: .clockSet, from: events, to: &result)
        Self.appendLatest(.clockGet, as: .clockGet, from: events, to: &result)
        Self.appendAll(.initializationWriteResponse, as: .initializationWrite, from: events, to: &result)
        Self.appendLatest(.historyMetadataReceived, as: .historyMetadata, from: events, to: &result)

        let latestCommit = events.last { $0.kind == .historyCommitted }
        result.append(Self.row(
            category: .historyCommit,
            title: "History chunks committed",
            detail: String(committedChunkCount),
            timestamp: latestCommit?.timestamp,
            ordinal: result.count
        ))

        let latestAcknowledgement = events.last { $0.kind == .acknowledgementEmitted }
        result.append(Self.row(
            category: .historyAcknowledgement,
            title: "History chunks ACKed",
            detail: String(acknowledgedChunkCount),
            timestamp: latestAcknowledgement?.timestamp,
            ordinal: result.count
        ))

        let recentErrors = events
            .filter { $0.kind == .error }
            .suffix(5)
            .enumerated()
            .map { index, event in
                Self.eventRow(event, category: .error, ordinal: index)
            }
        errors = recentErrors
        result.append(contentsOf: recentErrors)
        rows = result
    }

    public static var empty: DeviceFirstSessionDiagnostics {
        DeviceFirstSessionDiagnostics(
            snapshot: ConnectionDiagnosticsSnapshot(events: [], violations: [])
        )
    }

    private static func appendLatest(
        _ kind: ConnectionDiagnosticsKind,
        as category: DeviceFirstSessionDiagnosticCategory,
        from events: [ConnectionDiagnosticsEvent],
        to rows: inout [DeviceFirstSessionDiagnosticRow]
    ) {
        guard let event = events.last(where: { $0.kind == kind }) else { return }
        rows.append(eventRow(event, category: category, ordinal: rows.count))
    }

    private static func appendAll(
        _ kind: ConnectionDiagnosticsKind,
        as category: DeviceFirstSessionDiagnosticCategory,
        from events: [ConnectionDiagnosticsEvent],
        to rows: inout [DeviceFirstSessionDiagnosticRow]
    ) {
        for event in events where event.kind == kind {
            rows.append(eventRow(event, category: category, ordinal: rows.count))
        }
    }

    private static func eventRow(
        _ event: ConnectionDiagnosticsEvent,
        category: DeviceFirstSessionDiagnosticCategory,
        ordinal: Int
    ) -> DeviceFirstSessionDiagnosticRow {
        row(
            category: category,
            title: event.label ?? fallbackTitle(for: category),
            detail: event.detail ?? "Recorded",
            timestamp: event.timestamp,
            ordinal: ordinal
        )
    }

    private static func row(
        category: DeviceFirstSessionDiagnosticCategory,
        title: String,
        detail: String,
        timestamp: Date?,
        ordinal: Int
    ) -> DeviceFirstSessionDiagnosticRow {
        DeviceFirstSessionDiagnosticRow(
            id: "\(category.rawValue)-\(ordinal)-\(timestamp?.timeIntervalSince1970 ?? 0)",
            category: category,
            title: title,
            detail: detail,
            timestamp: timestamp
        )
    }

    private static func fallbackTitle(
        for category: DeviceFirstSessionDiagnosticCategory
    ) -> String {
        switch category {
        case .advertisement: "Advertisement"
        case .gattDiscovery: "GATT discovery"
        case .notificationSubscription: "Notification subscription"
        case .clockSet: "SET_CLOCK"
        case .clockGet: "GET_CLOCK"
        case .initializationWrite: "Initialization command"
        case .historyMetadata: "History metadata"
        case .historyCommit: "History chunks committed"
        case .historyAcknowledgement: "History chunks ACKed"
        case .error: "Error"
        }
    }
}

public protocol DeviceCenterDiagnosticsRepository: Sendable {
    func readConnectionDiagnostics() async -> DeviceFirstSessionDiagnostics
}

public enum DeviceFirstSessionDiagnosticsTextExporter {
    public static func make(
        report: DeviceFirstSessionDiagnostics,
        deviceName: String,
        generatedAt: Date
    ) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var lines = [
            "Loopr",
            "First-session diagnostics",
            "Device: \(DiagnosticsHex.redacted(deviceName))",
            "Generated: \(formatter.string(from: generatedAt))",
            "History chunks committed: \(report.committedChunkCount)",
            "History chunks ACKed: \(report.acknowledgedChunkCount)"
        ]

        for row in report.rows where row.category != .historyCommit && row.category != .historyAcknowledgement {
            let timestamp = row.timestamp.map(formatter.string(from:)) ?? "No timestamp"
            lines.append("[\(timestamp)] \(row.title): \(row.detail)")
        }
        return lines.joined(separator: "\n")
    }
}
