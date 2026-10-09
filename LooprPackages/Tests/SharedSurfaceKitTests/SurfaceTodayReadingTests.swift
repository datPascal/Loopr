import Foundation
import SharedSurfaceKit
import XCTest

final class SurfaceTodayReadingTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    private var now: Date { Date(timeIntervalSince1970: 1_788_775_200) }
    private func snapshot(day: String = "2026-09-07", sync: Date? = nil, recovery: Double? = 74,
                          sleepMinutes: Double? = 462, insight: SurfaceDayInsight? = nil) -> SurfaceSnapshot {
        .init(generation: 1, createdAt: now, sourceDay: day, syncDate: sync ?? now,
              metrics: .init(recovery: recovery, sleep: 92, strain: 10.4, sleepMinutes: sleepMinutes),
              battery: nil, activeWorkout: nil, staleReasons: [],
              insight: insight ?? .init(headline: "Your overnight readings are close to usual.",
                  recoveryStyle: .init(verdict: "Ready", lightRGB: 0x16A34A, darkRGB: 0x34D77B), sleepNeedMinutes: 480))
    }
    func testTodayShowsDurationNeedVerdictAndThePublishedSentence() {
        let value = SurfaceTodayReading(snapshot: snapshot(), now: now, calendar: calendar)
        XCTAssertEqual(value.recoveryLine, "Recovery 74 · Ready")
        XCTAssertEqual(value.sleep, "7 h 42 m")
        XCTAssertEqual(value.recoveryText, "74")
        XCTAssertEqual(value.sleepRingText, "7:42")
        XCTAssertEqual(value.strainRingText, "10.4")
        XCTAssertEqual(value.sleepNeedMinutes, 480)
        XCTAssertEqual(value.sleepContext, "-18 min vs need")
        XCTAssertEqual(value.strain, "10.4/21")
        XCTAssertEqual(value.sleepAccessibility, "7 hours, 42 minutes")
        XCTAssertEqual(value.strainAccessibility, "10.4 out of 21")
        XCTAssertEqual(value.headline, "Your overnight readings are close to usual.")
        XCTAssertFalse(value.isStale)
    }
    func testLegacyEfficiencyNeverTurnsIntoHoursOrMinutes() throws {
        let value = try SurfaceSnapshotCodec.decode(JSONEncoder().encode(snapshot(sleepMinutes: nil)))
        XCTAssertEqual(SurfaceTodayReading(snapshot: value, now: now, calendar: calendar).sleep, "—")
        XCTAssertEqual(value.metrics.sleep, 92)
    }
    func testMidnightHidesYesterdaysRecoverySleepAndStrainEvenWithoutStoredStaleFlags() {
        let tomorrow = now.addingTimeInterval(24 * 60 * 60)
        let value = SurfaceTodayReading(snapshot: snapshot(), now: tomorrow, calendar: calendar)
        XCTAssertNil(value.recovery)
        XCTAssertNil(value.sleepMinutes)
        XCTAssertNil(value.sleepNeedMinutes)
        XCTAssertNil(value.strainScore)
        XCTAssertNil(value.headline)
        XCTAssertNil(value.style)
        XCTAssertEqual(value.sleep, "—")
        XCTAssertEqual(value.strain, "—")
        XCTAssertTrue(value.isStale)
        XCTAssertTrue(value.status.hasPrefix("Last synced"))
        XCTAssertFalse(SurfaceTodayReading.dialog(.recovery, snapshot: snapshot(), now: tomorrow, calendar: calendar).contains("74"))
    }
    func testOldSameDayDataStatesSyncTimeAndExpiresFromTimeAlone() {
        let value = SurfaceTodayReading(snapshot: snapshot(sync: now.addingTimeInterval(-7 * 60 * 60)), now: now, calendar: calendar)
        XCTAssertTrue(value.isStale)
        XCTAssertEqual(value.status, "Last synced 03:00")
    }
    func testLearningCountAndMissingDataStayHonest() {
        let value = snapshot(recovery: nil, insight: .init(nightsRecorded: 1, nightsNeeded: 3))
        let reading = SurfaceTodayReading(snapshot: value, now: now, calendar: calendar)
        XCTAssertNil(reading.recovery)
        XCTAssertEqual(reading.unavailableReason, "1 of 3 nights. Wear your band overnight.")
        XCTAssertTrue(SurfaceTodayReading.dialog(.recovery, snapshot: value, now: now, calendar: calendar).contains("1 of 3 nights"))
    }
    func testMissingRingsUseOneDashAndKeepTheLearningVerdict() {
        let empty = SurfaceTodayReading(snapshot: nil, now: now, calendar: calendar)
        XCTAssertEqual(empty.recoveryText, "—")
        XCTAssertEqual(empty.sleepRingText, "—")
        XCTAssertEqual(empty.strainRingText, "—")
        XCTAssertEqual(empty.recoveryVerdict, "Waiting")
        let learning = SurfaceTodayReading(snapshot: snapshot(recovery: nil,
            insight: .init(nightsRecorded: 1, nightsNeeded: 4)), now: now, calendar: calendar)
        XCTAssertEqual(learning.recoveryVerdict, "Learning")
        XCTAssertEqual(learning.recoveryText, "—")
    }

    func testWatchStepsUseTheLocaleNumberFormatter() {
        let base = snapshot()
        let counted = SurfaceSnapshot(generation: 1, createdAt: now, sourceDay: base.sourceDay, syncDate: now,
            metrics: .init(steps: 4_200), battery: nil, activeWorkout: nil, staleReasons: [])
        XCTAssertEqual(WatchSurfaceProjector.project(counted, now: now).steps,
                       4_200.0.formatted(.number.precision(.fractionLength(0))))
    }

    func testTimelineHasAnEntryExactlyAtMidnightAcrossDST() {
        var calendar = self.calendar
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 0, minute: 7))!
        let midnight = calendar.date(from: DateComponents(year: 2026, month: 10, day: 26))!
        let dates = SurfaceTimelineSchedule.dates(now: start, calendar: calendar)
        XCTAssertTrue(dates.contains(midnight))
        XCTAssertEqual(dates, dates.sorted())
        XCTAssertEqual(Set(dates).count, dates.count)
    }

    func testRevocationHidesEveryHealthNumberAndHeadline() {
        let original = snapshot()
        let revoked = SurfaceSnapshot(generation: 2, createdAt: now, sourceDay: original.sourceDay, syncDate: now,
            metrics: original.metrics, battery: nil, activeWorkout: nil, staleReasons: [.permissionRevoked], insight: original.insight)
        let reading = SurfaceTodayReading(snapshot: revoked, now: now, calendar: calendar)
        XCTAssertNil(reading.recovery)
        XCTAssertEqual(reading.sleep, "—")
        XCTAssertEqual(reading.strain, "—")
        XCTAssertNil(reading.headline)
        for metric in [SurfaceTodayReading.Metric.sleep, .strain] {
            XCTAssertTrue(SurfaceTodayReading.dialog(metric, snapshot: revoked, now: now, calendar: calendar)
                .contains("Turn on sharing in Loopr Settings."))
        }
    }
}
