import AnalyticsKit
@testable import DataKit
import Foundation
import StorageKit
import Testing

/// Data ICP follow-up: Blood as an area. The Blood tests snapshot lists each marker's newest value with its history,
/// so every row opens the marker page, and the star map comes with it.
struct LabMarkerRowsTests {
    private func dec(_ text: String) -> Decimal { Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))! }
    private let drawn = Date(timeIntervalSince1970: 1_789_193_700)

    private func report(_ days: Double) -> LabReport {
        let date = drawn.addingTimeInterval(days * 86_400)
        return LabReport(id: UUID(), collectedAt: date, timeZoneIdentifier: "Europe/Berlin", labName: "Labor Berlin", fasting: true,
                         source: .typed, createdAt: date.addingTimeInterval(3_600), note: nil)
    }

    @Test func eachMarkerShowsItsNewestValueWithItsHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LabMarkerRows-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try StorageDatabase(url: root.appendingPathComponent("labs.sqlite"), applicationVersion: "lab-marker-rows")
        defer { try? database.databasePool.close() }
        let store = LabStore(database: database)
        let first = report(0), second = report(120)
        try store.saveReport(first, values: [LabValue(reportID: first.id, subject: .marker(.apoB), value: dec("90"), unit: "mg/dL", source: .typed)])
        try store.saveReport(second, values: [
            LabValue(reportID: second.id, subject: .marker(.apoB), value: dec("78"), unit: "mg/dL", source: .typed),
            LabValue(reportID: second.id, subject: .other(name: "Base excess"), value: dec("-2.5"), unit: nil, source: .typed)
        ])

        let snapshot = try store.listSnapshot(now: drawn.addingTimeInterval(130 * 86_400), calendar: Calendar(identifier: .gregorian))
        #expect(snapshot.markers.count == 1, "only catalog markers are listed")
        let apob = try #require(snapshot.marker(.apoB))
        #expect(apob.value.value == dec("78"))
        #expect(apob.history.map(\.value) == [90, 78])
        #expect(snapshot.markerGroups.count == 1)
        #expect(snapshot.starMap != nil)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let change = try #require(LabsListCopy.change(apob, calendar: calendar))
        #expect(change.hasPrefix("Down 12 since "))
    }

    @Test func aLabStarNamesItsMarker() {
        let star = DataStar(id: "lab-apob", title: "ApoB", system: .cardiovascular, source: .lab, latestText: "78 mg/dL",
                            latestDate: drawn, trend: .steady, brightness: 1, note: "")
        #expect(DataStarMapRule.labMarkerKey(star) == .apoB)
        let band = DataStar(id: "rmssd", title: "HRV", system: .cardiovascular, source: .band, latestText: nil,
                            latestDate: nil, trend: nil, brightness: 0, note: "")
        #expect(DataStarMapRule.labMarkerKey(band) == nil)
    }
}
