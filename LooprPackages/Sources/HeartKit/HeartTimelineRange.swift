import Foundation

/// A half-open visible range and a hard rendering budget. The chart asks
/// for about three points per logical pixel, capped to bound work on tablets.
public struct HeartTimelineRangeRequest: Hashable, Sendable {
    public let start: Date
    public let end: Date
    public let maximumPoints: Int
    public init(start: Date, end: Date, pixelWidth: Double) {
        self.start = start; self.end = max(start, end)
        self.maximumPoints = min(2400, max(30, Int(min(800, max(10, pixelWidth.isFinite ? pixelWidth : 10))) * 3))
    }
}

public enum HeartTimelineRange {
    /// One pass over the visible seconds. Each cell preserves both extrema
    /// and its mean, so a short peak survives zooming out. Empty cells stay
    /// absent. No sorting, interpolation or full-day re-derivation occurs.
    /// Work and output memory are O(visible seconds + pixel budget).
    public static func downsample(_ samples: [HeartRateSample], request: HeartTimelineRangeRequest,
                                  unconfirmed: [HeartTimelineBucket] = []) -> [HeartTimelineBucket] {
        let duration = request.end.timeIntervalSince(request.start)
        guard duration > 0 else { return [] }
        let width = max(1, ceil(duration / Double(request.maximumPoints)))
        let count = min(request.maximumPoints, Int(ceil(duration / width)))
        var counts = [Int](repeating: 0, count: count)
        var sums = [Double](repeating: 0, count: count)
        var lows = [Double](repeating: .infinity, count: count)
        var highs = [Double](repeating: -.infinity, count: count)
        var doubts = [Int](repeating: 0, count: count)
        // The coarse timeline already resolved beat agreement. Keep its
        // confidence at every zoom instead of repeating RR checks per pan.
        let doubtful = unconfirmed.filter(\.isUnconfirmed)
        var doubtIndex = 0
        for sample in samples {
            let offset = sample.time - request.start.timeIntervalSince1970
            guard offset >= 0, offset < duration, sample.bpm.isFinite,
                  HeartTimelineBuilder.plausibleRange.contains(sample.bpm) else { continue }
            let slot = Int(offset / width)
            guard slot < count else { continue }
            counts[slot] += 1; sums[slot] += sample.bpm
            lows[slot] = min(lows[slot], sample.bpm); highs[slot] = max(highs[slot], sample.bpm)
            // Sources return timestamp order. A single cursor avoids a
            // confidence search for every second in a 24-hour viewport.
            while doubtIndex < doubtful.count && doubtful[doubtIndex].end.timeIntervalSince1970 <= sample.time { doubtIndex += 1 }
            if doubtIndex < doubtful.count && doubtful[doubtIndex].start.timeIntervalSince1970 <= sample.time { doubts[slot] += 1 }
        }
        return (0..<count).compactMap { index in
            guard counts[index] > 0 else { return nil }
            let start = request.start.addingTimeInterval(Double(index) * width)
            return HeartTimelineBucket(start: start, end: min(request.end, start.addingTimeInterval(width)),
                minimum: lows[index], average: sums[index] / Double(counts[index]), maximum: highs[index],
                sampleCount: counts[index], unconfirmedCount: doubts[index])
        }
    }
}
