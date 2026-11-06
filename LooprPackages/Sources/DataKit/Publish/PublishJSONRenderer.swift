import Foundation

/// Writes and reads the dashboard JSON file. The layout is documented in docs/DATA_SCHEMA.md.
public enum PublishJSONRenderer {
    public static let fileName = "loopr-dashboard.json"

    public static func render(_ dashboard: PublishDashboard) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(dashboard)
    }

    public static func decode(_ data: Data) throws -> PublishDashboard {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PublishDashboard.self, from: data)
    }
}
