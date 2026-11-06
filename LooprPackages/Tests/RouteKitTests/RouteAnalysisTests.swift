import Foundation
import Testing
@testable import RouteKit
import WorkoutKit

@Suite("Route analysis")
struct RouteAnalysisTests {
    private static let start = Date(timeIntervalSince1970: 1_700_000_000)
    /// About 111 m of latitude per 0.001 degrees.
    private func route(_ activity: RouteActivity = .run, seconds: Int, every: Int = 5, metersPerSecond: Double = 3,
                       altitude: (Int) -> Double? = { _ in 40 }, gaps: [Int] = []) -> RouteRecord {
        let points = stride(from: 0, to: seconds, by: every).map { second in
            RoutePoint(timestamp: Self.start.addingTimeInterval(Double(second)),
                       latitude: 52 + Double(second) * metersPerSecond / 111_195, longitude: 13,
                       horizontalAccuracy: 5, altitude: altitude(second))
        }
        return RouteRecord(workoutID: "w", activity: activity, points: points, completed: true, gapStartIndices: gaps)
    }

    @Test func hikeIsAnEligibleRouteActivity() {
        #expect(RouteActivity(rawValue: "hike") == .hike)
        #expect(RouteActivity(rawValue: "swim") == nil)
    }

    @Test func splitsCarryPaceHeartRateAndKeepThePartialLastStretch() throws {
        let heart = stride(from: 0, to: 1_000, by: 5).map {
            WorkoutHeartSample(date: Self.start.addingTimeInterval(Double($0)), bpm: 140)
        }
        // 3 m/s for 1,000 s: three full kilometres, not quite.
        let splits = RouteAnalysis.splits(route: route(seconds: 1_000), heart: heart, everyMeters: 1_000)
        #expect(splits.filter { !$0.isPartial }.count == 2)
        let first = try #require(splits.first)
        #expect(abs(first.seconds - 333) < 5)
        #expect(abs(first.secondsPerKilometer - 333) < 5)
        #expect(first.averageBPM == 140)
        #expect(splits.last?.isPartial == true)
        #expect(abs((splits.last?.meters ?? 0) - 970) < 30)
    }

    @Test func aGpsGapAddsNoDistanceAndCutsTheLine() {
        var record = route(seconds: 600)
        // Remove the middle: a straight line across would add ground never recorded.
        let kept = Array(record.points[..<40]) + Array(record.points[80...])
        record = RouteRecord(workoutID: "w", activity: .run, points: kept, completed: true, gapStartIndices: [40])
        let page = WorkoutPageRoute(route: record)
        #expect(page.segments.count == 2)
        #expect(page.distanceMeters < 1_250)
        #expect(page.gapSeconds >= 200)
    }

    @Test func aLongSilenceWithNoMarkedGapIsStillAGap() {
        let record = route(seconds: 600)
        let kept = Array(record.points[..<40]) + Array(record.points[80...])
        let silent = RouteRecord(workoutID: "w", activity: .run, points: kept, completed: true)
        #expect(RouteAnalysis.segments(route: silent).count == 2)
        #expect(RouteAnalysis.distanceMeters(route: silent) < 1_250)
        #expect(RouteMath.distanceMeters(route: silent) > 1_500)
    }

    @Test func aFixAfterALongDropoutIsAcceptedSoTheRouteCarriesOn() {
        let filter = RouteFilter()
        let before = RoutePoint(timestamp: Self.start, latitude: 52, longitude: 13, horizontalAccuracy: 5)
        // 1.2 km further on, after six minutes without GPS at a running pace.
        let after = RoutePoint(timestamp: Self.start.addingTimeInterval(360), latitude: 52.0108, longitude: 13, horizontalAccuracy: 5)
        #expect(filter.accepts(after, after: before))
        // The same 1.2 km one second later is a jump, not a run.
        let jump = RoutePoint(timestamp: Self.start.addingTimeInterval(1), latitude: 52.0108, longitude: 13, horizontalAccuracy: 5)
        #expect(!filter.accepts(jump, after: before))
    }

    @Test func movingTimeLeavesOutStops() throws {
        var points = route(seconds: 300).points
        let stoppedAt = try #require(points.last)
        // Three minutes standing at a traffic light.
        for second in stride(from: 5.0, through: 180, by: 5) {
            points.append(RoutePoint(timestamp: stoppedAt.timestamp.addingTimeInterval(second), latitude: stoppedAt.latitude,
                                     longitude: stoppedAt.longitude, horizontalAccuracy: 5))
        }
        let record = RouteRecord(workoutID: "w", activity: .run, points: points, completed: true)
        let moving = try #require(RouteAnalysis.movingSeconds(route: record))
        #expect(abs(moving - 295) < 6)
        #expect(try #require(RouteMath.duration(route: record)) > 470)
    }

    @Test func jitterOnAFlatRoadAddsNoClimb() {
        let jitter = route(seconds: 600) { 40 + ($0 % 10 == 0 ? 2 : -2) }
        let page = WorkoutPageRoute(route: jitter)
        #expect((page.ascentMeters ?? 99) < 3)
    }

    @Test func aRealHillIsCounted() throws {
        let hill = route(seconds: 600) { second in 40 + sin(Double(second) / 600 * .pi) * 100 }
        let page = WorkoutPageRoute(route: hill)
        #expect(abs(try #require(page.ascentMeters) - 100) < 8)
        #expect(abs(try #require(page.descentMeters) - 100) < 8)
        #expect(abs(try #require(page.highestMeters) - 140) < 3)
        #expect(page.elevation.count >= 2)
    }

    @Test func routesWithoutAltitudeClaimNoClimb() {
        let page = WorkoutPageRoute(route: route(seconds: 600) { _ in nil })
        #expect(page.ascentMeters == nil && page.highestMeters == nil && page.elevation.isEmpty)
    }

    @Test func aLongRideSplitsEveryFiveKilometres() {
        // 10 m/s for 1 hour: 36 km.
        let ride = route(.cycle, seconds: 3_600, metersPerSecond: 10)
        let splits = WorkoutPageRoute(route: ride).splits
        #expect(splits.first?.meters == 5_000)
        let short = WorkoutPageRoute(route: route(.cycle, seconds: 1_200, metersPerSecond: 10)).splits
        #expect(short.first?.meters == 1_000)
    }

    @Test func gpxSaysWhichSport() throws {
        let file = try LocalRouteExporter().gpx(route: route(.hike, seconds: 60))
        #expect(String(decoding: file.data, as: UTF8.self).contains("<type>hiking</type>"))
    }
}
