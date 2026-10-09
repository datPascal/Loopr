import AnalyticsKit
import XCTest

private let batteryNow = Date(timeIntervalSince1970: 2_000_000_000)
private let batteryWake = batteryNow.addingTimeInterval(11 * 3_600)

private func batteryRun(end: Double, rate: Double, hours: Double = 6, everyMinutes: Int = 30) -> [BatterySample] {
    let steps = Int((hours * 60 / Double(everyMinutes)).rounded())
    return (0...steps).map { index in
        let minutesAgo = index * everyMinutes
        return BatterySample(
            tsSec: Int(batteryNow.timeIntervalSince1970) - minutesAgo * 60,
            pct: end + rate * Double(minutesAgo) / 60,
            charging: false
        )
    }
}

final class ForecastNoteTests: XCTestCase {
    func testPinnedReasonStrings() {
        XCTAssertEqual(ForecastNote.charging, "charging")
        XCTAssertEqual(ForecastNote.notDraining, "not_draining")
        XCTAssertEqual(ForecastNote.rateImplausible, "rate_implausible")
        XCTAssertEqual(ForecastNote.needHistory(2, 4), "need_history:have=2,need=4")
        XCTAssertEqual(ForecastNote.needSpan(.seconds(90), .seconds(7_200)), "need_span:have=1m,need=120m")
    }
}

final class BatteryForecasterDefaultsTests: XCTestCase {
    func testPinnedDefaults() {
        let forecaster = BatteryForecaster()
        XCTAssertEqual(forecaster.minSamples, 4)
        XCTAssertEqual(forecaster.minSpan, .seconds(7_200))
        XCTAssertEqual(forecaster.maxSampleAge, .seconds(172_800))
        XCTAssertEqual(forecaster.maxPlausibleDrainPctPerHour, 25, accuracy: 1e-9)
        XCTAssertEqual(forecaster.reservePct, 5, accuracy: 1e-9)
    }
}

final class DischargeRunDetectionTests: XCTestCase {
    func testUnknownChargingCannotBecomeADischargeEstimate() {
        let recent = batteryRun(end: 55, rate: 3, hours: 5)
        let unknown = recent.map { BatterySample(tsSec: $0.tsSec, pct: $0.pct, charging: nil) }
        let forecast = BatteryForecaster().forecast(samples: unknown, now: batteryNow, wakeAt: batteryWake)
        XCTAssertFalse(forecast.isUsable)
        XCTAssertEqual(forecast.note, ForecastNote.chargingUnknown)
    }

    func testCurrentRunEndsAtChargingAndIgnoresUnorderedInput() {
        let forecaster = BatteryForecaster()
        let recent = batteryRun(end: 55, rate: 3, hours: 5)
        let charging = (1...6).map { index in
            BatterySample(
                tsSec: Int(batteryNow.timeIntervalSince1970) - 5 * 3_600 - index * 1_200,
                pct: 60 + Double(index),
                charging: true
            )
        }
        let forecast = forecaster.forecast(samples: (recent + charging).reversed(), now: batteryNow, wakeAt: batteryWake)
        XCTAssertTrue(forecast.isUsable)
        XCTAssertEqual(forecast.drainPctPerHour!, 3, accuracy: 0.4)
        XCTAssertLessThanOrEqual(forecast.samplesUsed, recent.count)
    }
}

final class TheilSenDrainRateTests: XCTestCase {
    func testMedianSlopeAndAbstentionBranches() {
        let forecaster = BatteryForecaster()
        let usable = forecaster.forecast(samples: batteryRun(end: 40, rate: 2), now: batteryNow, wakeAt: batteryWake)
        XCTAssertEqual(usable.drainPctPerHour!, 2, accuracy: 0.15)

        let few = forecaster.forecast(samples: batteryRun(end: 50, rate: 2, hours: 1), now: batteryNow, wakeAt: batteryWake)
        XCTAssertEqual(few.note, ForecastNote.needHistory(3, 4))
        let narrow = forecaster.forecast(samples: batteryRun(end: 50, rate: 2, hours: 0.5, everyMinutes: 6), now: batteryNow, wakeAt: batteryWake)
        XCTAssertTrue(narrow.note?.hasPrefix("need_span:") == true)
        let flat = forecaster.forecast(samples: batteryRun(end: 80, rate: 0), now: batteryNow, wakeAt: batteryWake)
        XCTAssertEqual(flat.note, ForecastNote.notDraining)
        let implausible = forecaster.forecast(samples: batteryRun(end: 10, rate: 60), now: batteryNow, wakeAt: batteryWake)
        XCTAssertEqual(implausible.note, ForecastNote.rateImplausible)
    }
}

final class BatteryProjectionTests: XCTestCase {
    func testProjectionIsNotClampedAndAbstentionsNeverAlarm() {
        let forecaster = BatteryForecaster()
        let forecast = forecaster.forecast(samples: batteryRun(end: 15, rate: 2), now: batteryNow, wakeAt: batteryWake)
        XCTAssertLessThan(forecast.predictedPctAtWake!, 0)
        XCTAssertTrue(forecaster.willNotSurvive(forecast))
        let abstained = forecaster.forecast(samples: [], now: batteryNow, wakeAt: batteryWake)
        XCTAssertFalse(forecaster.willNotSurvive(abstained))
        XCTAssertNil(abstained.currentPct)
        XCTAssertNil(abstained.predictedEmptyAt)
    }
}

final class NextWakeTimeTests: XCTestCase {
    func testWallClockTimeRollsAcrossMonthAndDSTBoundaries() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        assertWake(now: utc.date(from: DateComponents(year: 2026, month: 1, day: 31, hour: 23))!, calendar: utc, expectedDay: 1)

        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let spring = try XCTUnwrap(losAngeles.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 23, minute: 30)))
        let fall = try XCTUnwrap(losAngeles.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 23, minute: 30)))
        assertWake(now: spring, calendar: losAngeles, expectedDay: 8)
        assertWake(now: fall, calendar: losAngeles, expectedDay: 1)
    }

    private func assertWake(now: Date, calendar: Calendar, expectedDay: Int) {
        let wake = BatteryForecaster.nextWakeTime(now, 7 * 60, calendar: calendar)
        let components = calendar.dateComponents([.day, .hour, .minute], from: wake)
        XCTAssertEqual(components.day, expectedDay)
        XCTAssertEqual(components.hour, 7)
        XCTAssertEqual(components.minute, 0)
    }
}

final class EveningWindowTests: XCTestCase {
    func testMidnightWrapAndFullDayLead() {
        XCTAssertTrue(BatteryForecaster.inEveningWindow(23 * 60, 60))
        XCTAssertTrue(BatteryForecaster.inEveningWindow(30, 60))
        XCTAssertFalse(BatteryForecaster.inEveningWindow(2 * 60, 60))
        XCTAssertTrue(BatteryForecaster.inEveningWindow(500, 600, leadMinutes: 1440))
    }
}

final class BatteryAbstentionTests: XCTestCase {
    func testSparseStaleChargingAndFirmwareChangeNeverProduceNumbers() {
        let forecaster = BatteryForecaster()
        let stale = (0..<10).map { offset in
            BatterySample(tsSec: Int(batteryNow.timeIntervalSince1970) - (72 + offset) * 3_600, pct: 90 - Double(offset), charging: false)
        }
        let charging = batteryRun(end: 40, rate: 2).map { BatterySample(tsSec: $0.tsSec, pct: $0.pct, charging: true) }
        let firmwareJump = batteryRun(end: 50, rate: 2).map { sample in
            sample.tsSec == Int(batteryNow.timeIntervalSince1970)
                ? BatterySample(tsSec: sample.tsSec, pct: sample.pct + 30, charging: false)
                : sample
        }
        let cases: [(BatteryForecast, String?)] = [
            (forecaster.forecast(samples: [], now: batteryNow, wakeAt: batteryWake), ForecastNote.needHistory(0, 4)),
            (forecaster.forecast(samples: stale, now: batteryNow, wakeAt: batteryWake), ForecastNote.needHistory(0, 4)),
            (forecaster.forecast(samples: charging, now: batteryNow, wakeAt: batteryWake), ForecastNote.charging),
            (forecaster.forecast(samples: firmwareJump, now: batteryNow, wakeAt: batteryWake), ForecastNote.needHistory(1, 4))
        ]
        for (result, expectedNote) in cases {
            XCTAssertFalse(result.isUsable)
            if let expectedNote { XCTAssertEqual(result.note, expectedNote) }
            XCTAssertNil(result.drainPctPerHour)
            XCTAssertNil(result.currentPct)
            XCTAssertNil(result.predictedPctAtWake)
            XCTAssertNil(result.predictedEmptyAt)
        }
    }
}

final class BatteryDeterminismTests: XCTestCase {
    func testIdenticalInputsProduceIdenticalOutput() {
        let forecaster = BatteryForecaster()
        let samples = batteryRun(end: 20, rate: 4)
        XCTAssertEqual(
            forecaster.forecast(samples: samples, now: batteryNow, wakeAt: batteryWake),
            forecaster.forecast(samples: samples, now: batteryNow, wakeAt: batteryWake)
        )
    }

    func testForecastIsReadableThroughTheDomainCanonicalSeam() async throws {
        let repository = InMemoryBatterySampleRepository(samples: batteryRun(end: 40, rate: 2))
        let service = BatteryObservationService(sampleRepository: repository)
        let forecast = try await service.forecast(now: batteryNow, wakeAt: batteryWake)
        let latest = try await service.readLatestBatteryForecast()
        XCTAssertEqual(latest, forecast)
    }
}

private actor DelayedBatteryRepository: BatterySampleRepository {
    func samples(through now: Date) async throws -> [BatterySample] {
        try await Task.sleep(nanoseconds: 2_000_000_000)
        return []
    }
}

final class BatteryCancellationTests: XCTestCase {
    func testCancelledObservationDoesNotPublishForecast() async {
        let service = BatteryObservationService(sampleRepository: DelayedBatteryRepository())
        let task = Task { try await service.forecast(now: batteryNow, wakeAt: batteryWake) }
        try? await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancelled observation should not publish")
        } catch is CancellationError {
            XCTAssertTrue(true)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
