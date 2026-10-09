import Foundation

/// Zone 2 of the shared five-zone scale, with an optional target-only override.
public struct ZoneTwoRange: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable { case restingHeartRate, maximumHeartRate, manual }
    public let lower: Int
    public let upper: Int
    public let source: Source
    public var range: ClosedRange<Int> { lower...upper }

    public init(lower: Int, upper: Int, source: Source) {
        self.lower = lower; self.upper = upper; self.source = source
    }

    public static func resolve(zones: HeartRateZones?, manual: ClosedRange<Int>? = nil) -> Self? {
        if let manual, manual.lowerBound >= 30, manual.upperBound <= 240, manual.lowerBound < manual.upperBound {
            return .init(lower: manual.lowerBound, upper: manual.upperBound, source: .manual)
        }
        guard let zones, let range = zones.bpmRange(for: 2) else { return nil }
        return .init(lower: range.lowerBound, upper: range.upperBound,
                     source: zones.restingHeartRate == nil ? .maximumHeartRate : .restingHeartRate)
    }

    public static func resolve(maximum: Double?, restingNights: [Double], manual: ClosedRange<Int>? = nil) -> Self? {
        let zones = HeartRateZoneSettings(manualMaximum: maximum).resolved(age: nil, restingNights: restingNights)
        return resolve(zones: zones, manual: manual)
    }
}
