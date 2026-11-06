@testable import DataKit
import XCTest

/// ICP R2-LAB-12, 13 and 14: the screen says who sees the file, the blood test switch says what goes on the page and
/// changes with the switch, and the picker counts what is picked and can pick a whole group.
final class PublishCopyTests: XCTestCase {
    func testTheTopSaysWhoSeesTheFile() {
        XCTAssertTrue(PublishCopy.audience.contains("until you send it"))
        XCTAssertTrue(PublishCopy.audience.contains("Whoever you send it to sees every number"))
        for text in [PublishCopy.title, PublishCopy.intro, PublishCopy.audience] {
            XCTAssertFalse(text.contains("—") || text.contains("\""), text)
        }
    }

    func testTheBloodSwitchLineChangesWithTheSwitch() {
        let off = PublishCopy.bloodSwitch(hasBloodTests: true, isOn: false)
        let on = PublishCopy.bloodSwitch(hasBloodTests: true, isOn: true)
        XCTAssertNotEqual(off, on)
        XCTAssertTrue(off.hasPrefix("Off by default"))
        XCTAssertTrue(on.hasPrefix("On.") && on.contains("lab's name and range are left out"), on)
        XCTAssertEqual(PublishCopy.bloodSwitch(hasBloodTests: false, isOn: false), "You have no blood tests saved, so there is nothing to add.")
    }

    func testThePreviewSaysWhichBloodValuesAreOnThePage() {
        XCTAssertNil(PublishCopy.previewBlood(hasBloodTests: false, isOn: false, pickedNames: []))
        XCTAssertEqual(PublishCopy.previewBlood(hasBloodTests: true, isOn: false, pickedNames: []), "No blood test values are on this page.")
        XCTAssertEqual(PublishCopy.previewBlood(hasBloodTests: true, isOn: true, pickedNames: []),
                       "No blood marker is picked, so the page has no blood test values.")
        let named = PublishCopy.previewBlood(hasBloodTests: true, isOn: true, pickedNames: ["Glucose", "Ferritin"]) ?? ""
        XCTAssertTrue(named.hasPrefix("Blood test values on this page: ") && named.contains("Glucose") && named.contains("Ferritin"), named)
        XCTAssertEqual(PublishCopy.pickedCount(0), "None picked")
        XCTAssertEqual(PublishCopy.pickedCount(3), "3 picked")
    }

    /// What the switch line promises is what the page holds: a blood card carries the marker, its values and unit,
    /// and the generic source, with no lab name or range.
    func testABloodCardHoldsNoLabNameOrRange() {
        let exportedAt = Date(timeIntervalSince1970: 1_792_929_600)
        let glucose = PublishMetricSeries(key: "lab_glucose", name: "Glucose", unit: "mg/dL", group: .bloodTests,
                                          source: "Blood test reports", values: [PublishDayValue(date: "2026-10-20", value: 92)])
        let dashboard = PublishDashboard.make(series: [glucose], period: .days30, exportedAt: exportedAt,
                                              timeZone: TimeZone(identifier: "UTC")!, includeBloodTests: true)
        let html = PublishHTMLRenderer.render(dashboard)
        XCTAssertTrue(html.contains("Glucose") && html.contains("mg/dL") && html.contains("Source: Blood test reports"))
        XCTAssertFalse(html.lowercased().contains("range"))
    }

    @MainActor func testAGroupCanBePickedAndClearedAtOnce() async {
        let candidates = [
            PublishMetricDescriptor(key: "rmssd", name: "HRV", unit: "ms", group: .heart, hasData: true),
            PublishMetricDescriptor(key: "resting_heart_rate", name: "Resting heart rate", unit: "bpm", group: .heart, hasData: true),
            PublishMetricDescriptor(key: "max_heart_rate", name: "Max heart rate", unit: "bpm", group: .heart, hasData: false),
            PublishMetricDescriptor(key: "lab_glucose", name: "Glucose", unit: "mg/dL", group: .bloodTests, hasData: true)
        ]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PublishCopyTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = PublishDashboardModel(timeZone: TimeZone(identifier: "UTC")!, now: { Date(timeIntervalSince1970: 1_792_929_600) },
                                          loadCandidates: { candidates }, loadSeries: { _, _ in [] }, directory: directory)
        await model.load()
        XCTAssertTrue(model.hasBloodTests)
        XCTAssertTrue(model.canPickAny(.heart))
        model.toggleAll(.heart)
        XCTAssertEqual(model.picked, ["rmssd", "resting_heart_rate"], "a metric with no data stays out")
        XCTAssertTrue(model.allPicked(.heart))
        model.toggleAll(.heart)
        XCTAssertTrue(model.picked.isEmpty)
        // Blood markers cannot be picked, one by one or as a group, until the switch is on.
        XCTAssertFalse(model.canPickAny(.bloodTests))
        model.toggleAll(.bloodTests)
        XCTAssertTrue(model.picked.isEmpty)
        model.includeBloodTests = true
        model.toggleAll(.bloodTests)
        XCTAssertEqual(model.pickedBloodNames, ["Glucose"])
    }
}
