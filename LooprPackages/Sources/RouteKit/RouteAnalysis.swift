import Foundation
import WorkoutKit

/// What a finished route adds up to: moving time, climb, splits with heart rate. Pure, so it is tested without a phone.
public enum RouteAnalysis {
    /// Below this speed a stretch counts as stopped.
    static let movingMetersPerSecond = 0.5
    /// A longer silence between two points is a gap, whatever the recorder saw.
    static let gapSeconds: TimeInterval = 30
    /// The climb has to pass this much before it counts, so GPS jitter on a flat road adds nothing.
    static let climbThresholdMeters = 3.0
    static let smoothingPoints = 7
    static let elevationSamples = 120

    private static func isBreak(_ index: Int, route: RouteRecord) -> Bool {
        route.gapStartIndices.contains(index)
    }

    public static func movingSeconds(route: RouteRecord) -> TimeInterval? {
        guard route.points.count > 1 else { return nil }
        var total = 0.0
        for index in 1..<route.points.count where !isBreak(index, route: route) {
            let previous = route.points[index - 1], point = route.points[index]
            let seconds = point.timestamp.timeIntervalSince(previous.timestamp)
            guard seconds > 0, seconds <= gapSeconds else { continue }
            if RouteMath.distanceMeters(from: previous, to: point) / seconds >= movingMetersPerSecond { total += seconds }
        }
        return total
    }

    /// Time the recording had no fix: a marked gap, or a silence longer than a stretch.
    public static func gapSeconds(route: RouteRecord) -> TimeInterval {
        guard route.points.count > 1 else { return 0 }
        var total = 0.0
        for index in 1..<route.points.count {
            let seconds = route.points[index].timestamp.timeIntervalSince(route.points[index - 1].timestamp)
            if isBreak(index, route: route) || seconds > gapSeconds { total += max(0, seconds) }
        }
        return total
    }

    /// Metres between points, leaving out marked gaps and long silences, so a lost signal never adds a straight line.
    public static func distanceMeters(route: RouteRecord) -> Double {
        guard route.points.count > 1 else { return 0 }
        var total = 0.0
        for index in 1..<route.points.count where !isBreak(index, route: route) {
            let previous = route.points[index - 1], point = route.points[index]
            guard point.timestamp.timeIntervalSince(previous.timestamp) <= gapSeconds else { continue }
            total += RouteMath.distanceMeters(from: previous, to: point)
        }
        return total
    }

    /// The line to draw, cut at marked gaps and long silences.
    public static func segments(route: RouteRecord) -> [[RoutePoint]] {
        var output: [[RoutePoint]] = []
        for (index, point) in route.points.enumerated() {
            let cut = index > 0 && (isBreak(index, route: route)
                || point.timestamp.timeIntervalSince(route.points[index - 1].timestamp) > gapSeconds)
            if index == 0 || cut { output.append([]) }
            output[output.count - 1].append(point)
        }
        return output
    }

    /// Altitudes with a median filter to drop spikes, then an average to settle what is left. The window shrinks
    /// towards each end, so the first and last heights stay where they were. Nil where a point has no altitude.
    static func smoothedAltitudes(route: RouteRecord) -> [Double?] {
        func window(_ values: [Double?], around index: Int) -> [Double] {
            let half = min(smoothingPoints / 2, index, values.count - 1 - index)
            return values[(index - half)...(index + half)].compactMap { $0 }
        }
        let raw = route.points.map(\.altitude)
        let medians: [Double?] = raw.indices.map { index in
            guard raw[index] != nil else { return nil }
            let sorted = window(raw, around: index).sorted()
            return sorted[sorted.count / 2]
        }
        return medians.indices.map { index in
            guard medians[index] != nil else { return nil }
            let values = window(medians, around: index)
            return values.reduce(0, +) / Double(values.count)
        }
    }

    /// Metres up and down over a run of smoothed altitudes, with a threshold so jitter does not add up.
    static func climb(_ altitudes: [Double]) -> (up: Double, down: Double) {
        guard var anchor = altitudes.first else { return (0, 0) }
        var up = 0.0, down = 0.0
        for altitude in altitudes.dropFirst() {
            let change = altitude - anchor
            if change >= climbThresholdMeters {
                up += change; anchor = altitude
            } else if change <= -climbThresholdMeters {
                down -= change; anchor = altitude
            }
        }
        // What is left at the end is real ground too, once it is more than noise.
        if let last = altitudes.last {
            let rest = last - anchor
            if rest >= 1 { up += rest } else if rest <= -1 { down -= rest }
        }
        return (up, down)
    }

    /// Splits with the last partial stretch kept, each with its heart rate and climb.
    /// Stretches split on `everyMeters`; a GPS gap does not add distance, and the clock inside a gap is not counted.
    public static func splits(route: RouteRecord, heart: [WorkoutHeartSample], everyMeters: Double) -> [WorkoutPageRoute.Split] {
        guard route.points.count > 1, everyMeters > 0 else { return [] }
        let altitudes = smoothedAltitudes(route: route)
        var output: [WorkoutPageRoute.Split] = []
        var travelled = 0.0, seconds = 0.0, startIndex = 0, boundary = route.points[0].timestamp

        func close(endIndex: Int, endDate: Date, meters: Double, isPartial: Bool) {
            let beats = heart.filter { $0.date >= boundary && $0.date < endDate }.map(\.bpm)
            let heights = altitudes[startIndex...endIndex].compactMap { $0 }
            output.append(.init(number: output.count + 1, meters: meters, seconds: seconds,
                                averageBPM: beats.isEmpty ? nil : Int((beats.reduce(0, +) / Double(beats.count)).rounded()),
                                climbMeters: heights.count >= 2 ? climb(heights).up : nil, isPartial: isPartial))
        }

        for index in 1..<route.points.count {
            guard !isBreak(index, route: route) else { continue }
            let previous = route.points[index - 1], point = route.points[index]
            let legSeconds = point.timestamp.timeIntervalSince(previous.timestamp)
            guard legSeconds > 0, legSeconds <= gapSeconds else { continue }
            var leg = RouteMath.distanceMeters(from: previous, to: point)
            guard leg.isFinite, leg > 0 else { continue }
            var legRemaining = legSeconds
            // A leg can cross a boundary; a fast rider on a sparse fix can cross more than one.
            while travelled + leg >= everyMeters {
                let needed = everyMeters - travelled
                let fraction = needed / leg
                seconds += legRemaining * fraction
                let endDate = point.timestamp.addingTimeInterval(-legRemaining * (1 - fraction))
                close(endIndex: index, endDate: endDate, meters: everyMeters, isPartial: false)
                leg -= needed
                legRemaining *= 1 - fraction
                travelled = 0; seconds = 0; boundary = endDate; startIndex = index
            }
            travelled += leg
            seconds += legRemaining
        }
        // Under 100 m is GPS settling at the finish, not a split anyone ran.
        if travelled >= 100, let last = route.points.last {
            close(endIndex: route.points.count - 1, endDate: last.timestamp, meters: travelled, isPartial: true)
        }
        return output
    }
}

public extension WorkoutPageRoute {
    /// - Parameter usesMiles: Splits per mile instead of per kilometre. A long ride splits every five.
    init(route: RouteRecord, heart: [WorkoutHeartSample] = [], usesMiles: Bool = false) {
        let unit = usesMiles ? 1_609.344 : 1_000.0
        let distance = RouteAnalysis.distanceMeters(route: route)
        let every = route.activity == .cycle && distance >= 30 * unit ? 5 * unit : unit
        let altitudes = RouteAnalysis.smoothedAltitudes(route: route)
        let heights = altitudes.compactMap { $0 }
        // Fewer than half the points with an altitude means a climb number would be a guess.
        let hasAltitude = route.points.count > 1 && heights.count * 2 >= route.points.count
        let climb = hasAltitude ? RouteAnalysis.climb(heights) : nil

        var travelled = 0.0
        var profile: [ElevationPoint] = []
        if hasAltitude {
            let step = max(1, route.points.count / RouteAnalysis.elevationSamples)
            for index in route.points.indices {
                if index > 0, !route.gapStartIndices.contains(index),
                   route.points[index].timestamp.timeIntervalSince(route.points[index - 1].timestamp) <= RouteAnalysis.gapSeconds {
                    travelled += RouteMath.distanceMeters(from: route.points[index - 1], to: route.points[index])
                }
                if index % step == 0, let altitude = altitudes[index] {
                    profile.append(ElevationPoint(meters: travelled, altitude: altitude))
                }
            }
        }
        self.init(
            segments: RouteAnalysis.segments(route: route).map { $0.map { Coordinate(latitude: $0.latitude, longitude: $0.longitude) } },
            distanceMeters: distance,
            movingSeconds: RouteAnalysis.movingSeconds(route: route) ?? 0,
            elapsedSeconds: RouteMath.duration(route: route) ?? 0,
            ascentMeters: climb?.up,
            descentMeters: climb?.down,
            highestMeters: hasAltitude ? heights.max() : nil,
            gapSeconds: RouteAnalysis.gapSeconds(route: route),
            splits: RouteAnalysis.splits(route: route, heart: heart, everyMeters: every),
            elevation: profile,
            pointCount: route.points.count
        )
    }
}
