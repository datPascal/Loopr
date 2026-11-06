import AnalyticsKit
import DesignSystem
import Foundation
import Testing
@testable import Loopr

/// Data ICP rounds (docs/design/2026-11-04-data-tab): the root's tiles and its line in words.
@MainActor
struct DataAreaTilesTests {
    @Test func comparisonsReadInWords() {
        #expect(DataAreaTileContent.short("+14 vs usual") == "14 above your usual")
        #expect(DataAreaTileContent.short("−4 bpm vs usual") == "4 bpm below your usual")
        #expect(DataAreaTileContent.short("-2.5 vs usual") == "2.5 below your usual")
        #expect(DataAreaTileContent.short("Within your usual range") == "Within your usual")
        #expect(DataAreaTileContent.short("Learning your usual range") == "Learning your usual")
        #expect(DataAreaTileContent.words("Estimated") == "Estimated")
    }

    @Test func theLineInWordsUsesOnlyWhatWasMeasured() {
        let sleep = DataAreaTileContent(value: "7 h 42 m", unit: "", status: "Within your usual", points: [])
        let recovery = DataAreaTileContent(value: "79", unit: "/100", status: "14 above your usual", points: [])
        let none = DataAreaTileContent(value: nil, unit: "", status: "No night yet", points: [])
        #expect(DataAreaGrid.sentence(sleep: sleep, recovery: recovery)
            == "You slept 7 h 42 m, within your usual. Recovery is 79, 14 above your usual.")
        #expect(DataAreaGrid.sentence(sleep: none, recovery: recovery) == "Recovery is 79, 14 above your usual.")
        #expect(DataAreaGrid.sentence(sleep: none, recovery: none) == nil)
    }

    @Test func bloodTestsCountReportsAndValues() {
        #expect(DataAreaTileContent.blood(reports: 0, values: 0).status == "Add your first report")
        #expect(DataAreaTileContent.blood(reports: 0, values: 0).value == nil)
        let two = DataAreaTileContent.blood(reports: 2, values: 21)
        #expect(two.value == "2" && two.unit == "reports" && two.status == "21 values")
    }

    @Test func everyAreaOpensItsOwnPage() {
        #expect(DataArea.all.map(\.title) == ["Sleep", "Recovery", "Strain", "Stress", "Body", "Blood tests"])
        #expect(Set(DataArea.all.map(\.identifier)).count == DataArea.all.count)
        #expect(DataArea(kind: .strain).route == .bodyHome)
        #expect(DataArea(kind: .body).route == .bodyMeasures)
        #expect(DataArea(kind: .recovery).route == .heartHome)
    }

    @Test func skinTemperatureNeverReadsAsZeroDegrees() {
        let flat = HealthMetricReading(key: .skinTemperatureDeviation,
                                       history: [MetricHistoryPoint(day: Calendar.current.startOfDay(for: .now), value: 0.01, source: .band)],
                                       day: .now, state: .partial)
        #expect(HealthPinnedSection.valueText(.skinTemperatureDeviation, reading: flat).value == "No change")
    }
}

/// Data ICP follow-up: Blood as an area, routes to a marker, and a chart as a CSV.
@MainActor
struct DataBloodAndExportTests {
    @Test func theBloodTileShowsAStateOnceMarkersCompare() {
        let none = DataAreaTileContent.blood(reports: 2, values: 21)
        #expect(none.value == "2" && none.status == "21 values")
        let compared = DataAreaTileContent.blood(reports: 2, values: 21, markers: DataBloodMarkers(measured: 21, moved: 3, steady: 18))
        #expect(compared.value == "21" && compared.unit == "markers" && compared.status == "3 of 21 retested moved")
        let held = DataAreaTileContent.blood(reports: 2, values: 21, markers: DataBloodMarkers(measured: 21, moved: 0, steady: 9))
        #expect(held.status == "None moved since your last test")
        let first = DataAreaTileContent.blood(reports: 1, values: 9, markers: DataBloodMarkers(measured: 9))
        #expect(first.status == "From 1 report")
    }

    @Test func areaRangesWaitForThatMuchHistory() {
        let end = Date(timeIntervalSince1970: 1_763_000_000)
        let calendar = Calendar.current
        let points = (0..<60).map { LooprChartPoint(date: calendar.date(byAdding: .day, value: -$0, to: calendar.startOfDay(for: end))!, value: 50) }
        #expect(DataAreaTrend.locked(points: points, endingOn: end) == [.halfYear, .year, .twoYears])
        #expect(DataAreaTrend.locked(points: [], endingOn: end).contains(.month))
    }

    @Test func yearRowsOpenTheirOwnHistory() {
        #expect(DataRootRouting.slope("rmssd") == .metric(.rmssd))
        #expect(DataRootRouting.slope("lab-apob") == .labMarker(.apoB))
        #expect(DataRootRouting.slope("lab-not-a-marker") == .labs)
    }

    @Test func aChartExportsWithItsUnitAndOnlyItsRange() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let end = calendar.date(from: DateComponents(year: 2026, month: 11, day: 14))!
        let points = (0..<40).map { LooprChartPoint(date: calendar.date(byAdding: .day, value: -$0, to: end)!, value: 60 + Double($0 % 3)) }
        let csv = DataChartCSV.make(key: .rmssd, points: points, range: .week, endingOn: end, calendar: calendar)
        let lines = csv.text.split(separator: "\n")
        #expect(lines.first == "date,HRV (ms)")
        #expect(lines.count == 8)
        #expect(lines.last == "2026-11-14,60.00")
        #expect(csv.fileName == "Loopr HRV 7D.csv")
    }
}
