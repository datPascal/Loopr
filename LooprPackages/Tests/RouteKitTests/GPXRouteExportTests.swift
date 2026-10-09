import Foundation
import RouteKit
import WorkoutKit
import XCTest

final class GPXRouteExportTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 0)

    func testGPXFixtureEscapesNameAndIncludesOnlyMeasuredValues() throws {
        let point = RoutePoint(timestamp: date, latitude: -8.5, longitude: 115.25, horizontalAccuracy: 3, altitude: 12)
        let route = RouteRecord(workoutID: "a", activity: .run, points: [point])
        let file = try LocalRouteExporter().gpx(route: route, name: "Run & <walk> \"today\" 'test'\u{01}", samples: [.init(timestamp: date, heartRate: 72)])
        let expected = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Loopr" xmlns="http://www.topografix.com/GPX/1/1" xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1">
          <trk>
            <name>Run &amp; &lt;walk&gt; &quot;today&quot; &apos;test&apos;</name>
            <trkseg>
              <trkpt lat="-8.5" lon="115.25">
                <ele>12.0</ele>
                <time>1970-01-01T00:00:00.000Z</time>
                <extensions><gpxtpx:TrackPointExtension><gpxtpx:hr>72</gpxtpx:hr></gpxtpx:TrackPointExtension></extensions>
              </trkpt>
            </trkseg>
          </trk>
        </gpx>
        """ + "\n"
        XCTAssertEqual(file.data, Data(expected.utf8))
        XCTAssertTrue(XMLParser(data: file.data).parse())
        XCTAssertEqual(file.filename, "loopr-route.gpx")
    }

    func testGapStartsNewSegmentAndMissingMetricsStayAbsent() throws {
        let points = [0.0, 1.0].map { RoutePoint(timestamp: date.addingTimeInterval($0), latitude: 1, longitude: 2, horizontalAccuracy: 3) }
        let route = RouteRecord(workoutID: "a", activity: .walk, points: points, gapStartIndices: [1])
        let file = try LocalRouteExporter().gpx(route: route, samples: [.init(timestamp: date.addingTimeInterval(2), heartRate: 80)])
        let xml = String(decoding: file.data, as: UTF8.self)
        XCTAssertEqual(xml.components(separatedBy: "<trkseg>").count - 1, 2)
        XCTAssertFalse(xml.contains("<ele>"))
        XCTAssertFalse(xml.contains("gpxtpx:hr>"))
        XCTAssertTrue(XMLParser(data: file.data).parse())
    }

    func testFractionalGPSMatchesOnlyAFreshEarlierMeasuredSample() throws {
        let points = [0.5, 2.0].map { RoutePoint(timestamp: date.addingTimeInterval($0), latitude: 1, longitude: 2, horizontalAccuracy: 3) }
        let route = RouteRecord(workoutID: "a", activity: .run, points: points)
        let samples = [WorkoutSample(timestamp: date, heartRate: 80)]
        let xml = String(decoding: try LocalRouteExporter().gpx(route: route, samples: samples).data, as: UTF8.self)
        XCTAssertEqual(xml.components(separatedBy: "<gpxtpx:hr>80</gpxtpx:hr>").count - 1, 1)
        let missing = try LocalRouteExporter().gpx(route: route, samples: samples + [.init(timestamp: date.addingTimeInterval(0.25))])
        XCTAssertFalse(String(decoding: missing.data, as: UTF8.self).contains("gpxtpx:hr>"))
    }

    func testSmallCoordinatesAndLargeElevationUseSchemaDecimalNotation() throws {
        let point = RoutePoint(timestamp: date, latitude: 1e-7, longitude: -2e-8, horizontalAccuracy: 3, altitude: 1e20)
        let route = RouteRecord(workoutID: "a", activity: .run, points: [point])
        let file = try LocalRouteExporter().gpx(route: route)
        let xml = String(decoding: file.data, as: UTF8.self)
        XCTAssertTrue(xml.contains("lat=\"0.0000001\" lon=\"-0.00000002\""))
        XCTAssertTrue(xml.contains("<ele>100000000000000000000.0</ele>"))
        XCTAssertTrue(XMLParser(data: file.data).parse())
    }

    func testEmptyAndInvalidRoutesCannotExport() {
        XCTAssertThrowsError(try LocalRouteExporter().gpx(route: .init(workoutID: "a", activity: .run))) { XCTAssertEqual($0 as? RouteError, .missingRoute) }
        let point = RoutePoint(timestamp: date, latitude: .nan, longitude: 2, horizontalAccuracy: 3)
        XCTAssertThrowsError(try LocalRouteExporter().gpx(route: .init(workoutID: "a", activity: .run, points: [point]))) { XCTAssertEqual($0 as? RouteError, .malformedPoint) }
    }
}
