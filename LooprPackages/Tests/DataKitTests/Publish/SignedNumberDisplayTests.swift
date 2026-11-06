import AnalyticsKit
@testable import DataKit
import DesignSystem
import DomainKit
import Foundation
import XCTest

/// LV-10 polish: signed numbers on the Data screens carry U+2212 and read as "minus", while the export and the
/// published JSON keep the ASCII "-" a parser expects.
final class SignedNumberDisplayTests: XCTestCase {
    private let minus = "\u{2212}"

    func testTheYearComparisonDeltaWritesANegativeWithTheTypographicMinus() {
        for value in [-0.5, -23.0, -14.0] {
            let text = DataLabSeries.delta(value)
            XCTAssertTrue(text.hasPrefix(minus), text)
            XCTAssertFalse(text.contains("-"), text)
        }
        XCTAssertEqual(DataLabSeries.delta(-23), "\(minus)23")
        XCTAssertTrue(DataLabSeries.delta(0.5).hasPrefix("+"))
        XCTAssertEqual(DataLabSeries.delta(0), "\u{00B1}0")
        XCTAssertTrue(DataLabSeries.number(-2.5).hasPrefix(minus))
    }

    func testAYearSlopeIsReadAsMinusAndNeverAsAHyphen() {
        let slope = DataYearSlope(id: "resting-heart-rate", title: "Resting heart rate", valueText: "51 bpm", lastYear: 54,
                                  thisYear: 51, deltaText: "\(minus)3", trend: .improving, movement: 1)
        XCTAssertEqual(slope.spokenLabel, "Resting heart rate, 90-day median 51 bpm, minus 3 on last year, \(DataTrend.improving.title)")
        XCTAssertFalse(slope.spokenLabel.contains(minus))
    }

    func testTheExportAndThePublishedJSONKeepTheAsciiHyphen() throws {
        // CSV, the format a spreadsheet reads.
        XCTAssertEqual(CSV.number(-0.5), "-0.5")
        XCTAssertEqual(CSV.number(-23), "-23")
        let csv = CSV.text([["skin_temperature_deviation", CSV.number(-0.5), CSV.number(-14)]])
        XCTAssertEqual(csv, "skin_temperature_deviation,-0.5,-14\r\n")
        XCTAssertFalse(csv.contains(minus))

        // The published JSON, the format a script reads.
        let series = PublishMetricSeries(
            key: "skin_temperature_deviation", name: "Skin temperature", unit: "\u{00B0}C", group: .heart, source: "Loopr band",
            values: [PublishDayValue(date: "2026-10-24", value: -0.5), PublishDayValue(date: "2026-10-25", value: -17.1)])
        let dashboard = PublishDashboard.make(
            series: [series], period: .days30, exportedAt: Date(timeIntervalSince1970: 1_792_929_600),
            timeZone: TimeZone(identifier: "UTC")!, includeBloodTests: false)
        let json = String(decoding: try PublishJSONRenderer.render(dashboard), as: UTF8.self)
        XCTAssertTrue(json.contains("-0.5"), json)
        XCTAssertTrue(json.contains("-17.1"), json)
        XCTAssertFalse(json.contains(minus), "The published JSON must not hold U+2212")
        let decoded = try PublishJSONRenderer.decode(Data(json.utf8))
        XCTAssertEqual(decoded.metrics.first?.values.map(\.value), [-0.5, -17.1])
    }
}
