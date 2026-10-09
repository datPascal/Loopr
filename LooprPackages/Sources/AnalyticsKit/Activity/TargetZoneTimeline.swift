import Foundation

/// A known reading owns at most five seconds. Missing readings and longer
/// signal gaps remain unclassified rather than extending the last reading.
public enum TargetZoneTimeline {
    public enum Position: String, Codable, Sendable { case below, inside, above }
    public struct Span: Equatable, Sendable {
        public let start: TimeInterval
        public let end: TimeInterval
        public let position: Position
    }
    public static func spans(_ samples: [ActivityHeartRateSample], range: ClosedRange<Int>,
                             start: TimeInterval, end: TimeInterval) -> [Span] {
        guard end > start else { return [] }
        let sorted = samples.sorted { $0.timestamp < $1.timestamp }
        return sorted.enumerated().compactMap { index, sample in
            guard sample.valid, sample.bpm.isFinite, (30...240).contains(sample.bpm) else { return nil }
            let next = index + 1 < sorted.count ? sorted[index + 1].timestamp : end
            let left = max(start, sample.timestamp)
            let right = min(end, min(next, sample.timestamp + 5))
            guard right > left else { return nil }
            let position: Position = sample.bpm < Double(range.lowerBound) ? .below
                : sample.bpm > Double(range.upperBound) ? .above : .inside
            return Span(start: left, end: right, position: position)
        }
    }
}
