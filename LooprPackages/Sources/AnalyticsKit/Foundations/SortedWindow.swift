import Foundation

/// Percentiles of a moving window, without re-sorting the window at every step.
///
/// Several primitives walk a long series and read a percentile of the values
/// around each index: the RR artifact detector over 91 beats, the heart-rate
/// smoother over 300 seconds, the stager over 361 epochs. Sorting the window
/// again at every index costs `O(n · w log w)` and allocates a fresh array per
/// index, which is most of one day's derivation time.
///
/// This holds the window sorted and advances it by removing one value and
/// inserting one, each a binary search plus a move. Percentiles are read with
/// the same rank interpolation `AnalyticsMath.percentile` uses, over the same
/// multiset of values, so every number is unchanged.
///
/// Values must be finite and comparable. Every caller filters first.
struct SortedWindow {
    private var values: [Double]

    init(capacity: Int = 0) {
        values = []
        if capacity > 0 { values.reserveCapacity(capacity) }
    }

    var count: Int { values.count }
    var isEmpty: Bool { values.isEmpty }

    mutating func insert(_ value: Double) {
        values.insert(value, at: lowerBound(value))
    }

    /// Removes one occurrence. A value that is not present leaves the window
    /// untouched, which keeps a caller that filters its input safe.
    mutating func remove(_ value: Double) {
        let index = lowerBound(value)
        guard index < values.count, values[index] == value else { return }
        values.remove(at: index)
    }

    mutating func removeAll() { values.removeAll(keepingCapacity: true) }

    func percentile(_ percentile: Double) -> Double? {
        Self.interpolate(percentile, count: values.count) { values[$0] }
    }

    func median() -> Double? { percentile(50) }

    /// The percentile of the window with one occurrence of `excluded` taken
    /// out. The RR artifact detector compares each beat against its neighbours
    /// and must not let the beat itself sit in that comparison.
    func percentile(_ percentile: Double, excluding excluded: Double) -> Double? {
        let removed = lowerBound(excluded)
        guard removed < values.count, values[removed] == excluded else {
            return Self.interpolate(percentile, count: values.count) { values[$0] }
        }
        return Self.interpolate(percentile, count: values.count - 1) { values[$0 < removed ? $0 : $0 + 1] }
    }

    func median(excluding excluded: Double) -> Double? { percentile(50, excluding: excluded) }

    /// The rank interpolation of `AnalyticsMath.percentile`, read through an
    /// accessor so a window can answer for itself minus one element.
    private static func interpolate(_ percentile: Double, count: Int, element: (Int) -> Double) -> Double? {
        guard count > 0 else { return nil }
        guard count > 1 else { return element(0) }
        let rank = (percentile / 100) * Double(count - 1)
        let lower = Int(floor(rank))
        let upper = Int(ceil(rank))
        guard lower != upper else { return element(lower) }
        return element(lower) + (element(upper) - element(lower)) * (rank - Double(lower))
    }

    private func lowerBound(_ value: Double) -> Int {
        var low = 0
        var high = values.count
        while low < high {
            let mid = (low + high) / 2
            if values[mid] < value { low = mid + 1 } else { high = mid }
        }
        return low
    }
}

/// Walks `0..<count` and keeps a `SortedWindow` covering the inclusive index
/// range `[index - half, index + half]`, clipped to the series. `include`
/// decides which indices belong in the window; `body` reads the window at each
/// index. Both bounds only ever move forward, so each value is inserted and
/// removed at most once.
func withSlidingWindow(
    count: Int,
    half: Int,
    value: (Int) -> Double,
    include: (Int) -> Bool = { _ in true },
    body: (Int, inout SortedWindow) -> Void
) {
    guard count > 0 else { return }
    var window = SortedWindow(capacity: 2 * half + 2)
    var lower = 0
    var upper = 0
    for index in 0..<count {
        let wantLower = max(0, index - half)
        let wantUpper = min(count, index + half + 1)
        while upper < wantUpper {
            if include(upper) { window.insert(value(upper)) }
            upper += 1
        }
        while lower < wantLower {
            if include(lower) { window.remove(value(lower)) }
            lower += 1
        }
        body(index, &window)
    }
}
