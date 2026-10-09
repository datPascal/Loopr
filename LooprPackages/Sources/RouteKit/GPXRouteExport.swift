import Foundation
import WorkoutKit
#if canImport(CoreTransferable)
import CoreTransferable
import UniformTypeIdentifiers
#endif

/// GPX 1.1 uses WGS84 coordinates and UTC timestamps. TrackPointExtension v1
/// carries optional heart rate. Sources: topografix.com/GPX/1/1 and
/// www8.garmin.com/xmlschemas/TrackPointExtensionv1.xsd.
public extension LocalRouteExporter {
    func gpx(route: RouteRecord, name: String? = nil, samples: [WorkoutSample] = []) throws -> GPXRouteFile {
        guard !route.points.isEmpty else { throw RouteError.missingRoute }
        guard route.points.allSatisfy({
            $0.isFinite && $0.longitude < 180 && $0.timestamp.timeIntervalSince1970.isFinite &&
            ($0.altitude?.isFinite ?? true)
        }) else { throw RouteError.malformedPoint }
        guard zip(route.points, route.points.dropFirst()).allSatisfy({ pair in pair.0.timestamp <= pair.1.timestamp }) else {
            throw RouteError.malformedPoint
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let measured = samples.filter { $0.timestamp.timeIntervalSince1970.isFinite }
            .sorted { $0.timestamp < $1.timestamp }
        var sampleIndex = 0
        var latestSample: WorkoutSample?
        var lines = [
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
            "<gpx version=\"1.1\" creator=\"Loopr\" xmlns=\"http://www.topografix.com/GPX/1/1\" xmlns:gpxtpx=\"http://www.garmin.com/xmlschemas/TrackPointExtension/v1\">",
            "  <trk>",
            "    <name>\(Self.xmlText(name ?? route.activity.rawValue.capitalized))</name>",
            "    <trkseg>"
        ]
        let gaps = Set(route.gapStartIndices)
        for (index, point) in route.points.enumerated() {
            if index > 0, gaps.contains(index) { lines += ["    </trkseg>", "    <trkseg>"] }
            lines.append("      <trkpt lat=\"\(Self.decimal(point.latitude))\" lon=\"\(Self.decimal(point.longitude))\">")
            if let altitude = point.altitude { lines.append("        <ele>\(Self.decimal(altitude))</ele>") }
            lines.append("        <time>\(formatter.string(from: point.timestamp))</time>")
            // Attach the latest measured sample at or before this point only
            // within one second, allowing fractional GPS timestamps. Never
            // interpolate or carry across a signal gap.
            while sampleIndex < measured.count, measured[sampleIndex].timestamp <= point.timestamp {
                latestSample = measured[sampleIndex]
                sampleIndex += 1
            }
            if let sample = latestSample, point.timestamp.timeIntervalSince(sample.timestamp) <= 1,
               let bpm = sample.heartRate, (1...255).contains(bpm) {
                lines.append("        <extensions><gpxtpx:TrackPointExtension><gpxtpx:hr>\(bpm)</gpxtpx:hr></gpxtpx:TrackPointExtension></extensions>")
            }
            lines.append("      </trkpt>")
        }
        lines += ["    </trkseg>", "  </trk>", "</gpx>"]
        return GPXRouteFile(data: Data((lines.joined(separator: "\n") + "\n").utf8), filename: "loopr-route.gpx")
    }

    // GPX coordinates and elevation use xs:decimal, which excludes exponent
    // notation. Expand Swift's shortest representation without rounding.
    private static func decimal(_ value: Double) -> String {
        let original = String(value)
        guard let marker = original.firstIndex(of: "e"),
              let exponent = Int(original[original.index(after: marker)...]) else { return original }
        let coefficient = original[..<marker]
        let negative = coefficient.hasPrefix("-")
        let unsigned = negative ? coefficient.dropFirst() : coefficient
        let parts = unsigned.split(separator: ".", omittingEmptySubsequences: false)
        let digits = parts.joined()
        let position = parts[0].count + exponent
        let expanded: String
        if position <= 0 {
            expanded = "0." + String(repeating: "0", count: -position) + digits
        } else if position >= digits.count {
            expanded = digits + String(repeating: "0", count: position - digits.count) + ".0"
        } else {
            expanded = String(digits.prefix(position)) + "." + String(digits.dropFirst(position))
        }
        return (negative ? "-" : "") + expanded
    }

    private static func xmlText(_ value: String) -> String {
        String(value.unicodeScalars.filter {
            $0.value == 9 || $0.value == 10 || $0.value == 13 ||
            (0x20...0xD7FF).contains($0.value) || (0xE000...0xFFFD).contains($0.value) ||
            (0x10000...0x10FFFF).contains($0.value)
        }).replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

public struct GPXRouteFile: Equatable, Sendable {
    public let data: Data
    public let filename: String
    public init(data: Data, filename: String) { self.data = data; self.filename = filename }
}

#if canImport(CoreTransferable)
public extension UTType {
    static let looprGPX = UTType(exportedAs: "com.loopr.gpx", conformingTo: .xml)
}

extension GPXRouteFile: Transferable {
    public static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .looprGPX) { file in file.data }
            .suggestedFileName { file in file.filename }
    }
}
#endif
