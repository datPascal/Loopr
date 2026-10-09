import Foundation
import Testing
@testable import DesignSystem

struct UnitFormatterTests {
    /// The formatter is locale aware on purpose, so the expectations are too.
    private func number(_ value: Double, digits: Int) -> String {
        value.formatted(.number.precision(.fractionLength(digits)))
    }

    @Test func metricDistanceSwitchesToKilometresAtOneThousandMetres() {
        #expect(LooprUnitFormatter.distance(meters: 999, system: .metric).unit == "m")
        #expect(LooprUnitFormatter.distance(meters: 999, system: .metric).value == "999")
        let long = LooprUnitFormatter.distance(meters: 5_400, system: .metric)
        #expect(long.unit == "km")
        #expect(long.value == number(5.4, digits: 1))
    }

    @Test func imperialDistanceUsesFeetBelowAMileAndMilesAbove() {
        let short = LooprUnitFormatter.distance(meters: 100, system: .imperial)
        #expect(short.unit == "ft")
        #expect(short.value == "328")
        let long = LooprUnitFormatter.distance(meters: 5_000, system: .imperial)
        #expect(long.unit == "mi")
        #expect(long.value == number(3.1, digits: 1))
    }

    @Test func imperialAndMetricNeverRenderTheSameLabel() {
        let metric = LooprUnitFormatter.distance(meters: 5_000, system: .metric)
        let imperial = LooprUnitFormatter.distance(meters: 5_000, system: .imperial)
        #expect(metric.combined != imperial.combined)
    }

    @Test func weightConvertsToPounds() {
        #expect(LooprUnitFormatter.weight(kilograms: 80, system: .metric).combined == "\(number(80, digits: 1)) kg")
        let pounds = LooprUnitFormatter.weight(kilograms: 80, system: .imperial)
        #expect(pounds.unit == "lb")
        #expect(pounds.value == number(176.4, digits: 1))
    }

    @Test func heightReadsAsFeetAndInchesInImperial() {
        #expect(LooprUnitFormatter.height(centimeters: 180, system: .metric).combined == "180 cm")
        let imperial = LooprUnitFormatter.height(centimeters: 180, system: .imperial)
        #expect(imperial.value == "5′ 11″")
        #expect(imperial.unit.isEmpty)
    }

    @Test func paceConvertsPerMile() {
        #expect(LooprUnitFormatter.pace(secondsPerKilometer: 300, system: .metric).combined == "5:00 /km")
        let imperial = LooprUnitFormatter.pace(secondsPerKilometer: 300, system: .imperial)
        #expect(imperial.unit == "/mi")
        #expect(imperial.value == "8:03")
    }

    @Test func paceAbstainsRatherThanShowingZero() {
        #expect(LooprUnitFormatter.pace(secondsPerKilometer: 0, system: .metric).value == "—")
    }

    @Test func heightFieldRoundTripsThroughInches() {
        let text = LooprUnitFormatter.heightFieldText(centimeters: 180, system: .imperial)
        #expect(text == "71")
        let back = LooprUnitFormatter.heightCentimeters(fromField: text, system: .imperial)
        #expect(back != nil)
        #expect(abs(back! - 180) < 1.5)
    }

    @Test func weightFieldRoundTripsThroughPounds() {
        let text = LooprUnitFormatter.weightFieldText(kilograms: 80, system: .imperial)
        #expect(text == "176.4")
        let back = LooprUnitFormatter.weightKilograms(fromField: text, system: .imperial)
        #expect(back != nil)
        #expect(abs(back! - 80) < 0.1)
    }

    @Test func fieldsAcceptACommaDecimalSeparator() {
        #expect(LooprUnitFormatter.weightKilograms(fromField: "72,5", system: .metric) == 72.5)
        #expect(LooprUnitFormatter.heightCentimeters(fromField: "", system: .metric) == nil)
    }

    @Test func fieldLabelsNameTheUnitTheyExpect() {
        #expect(LooprUnitFormatter.heightFieldLabel(.metric) == "Height (cm)")
        #expect(LooprUnitFormatter.heightFieldLabel(.imperial) == "Height (in)")
        #expect(LooprUnitFormatter.weightFieldLabel(.metric) == "Weight (kg)")
        #expect(LooprUnitFormatter.weightFieldLabel(.imperial) == "Weight (lb)")
    }

    @Test func runtimeCarriesTheMeasurementSystemAndHintPreference() {
        DesignSystemRuntime.reset()
        defer { DesignSystemRuntime.reset() }
        #expect(DesignSystemRuntime.state().measurementSystem == .metric)
        #expect(DesignSystemRuntime.state().voiceOverHints)
        DesignSystemRuntime.apply(.init(measurementSystem: .imperial, voiceOverHints: false))
        #expect(DesignSystemRuntime.state().measurementSystem == .imperial)
        #expect(DesignSystemRuntime.state().voiceOverHints == false)
    }

    @Test func runtimeAnnouncesOnlyRealChanges() async {
        DesignSystemRuntime.reset()
        defer { DesignSystemRuntime.reset() }
        let counter = Counter()
        let token = NotificationCenter.default.addObserver(
            forName: DesignSystemRuntime.didChangeNotification, object: nil, queue: nil
        ) { _ in counter.bump() }
        defer { NotificationCenter.default.removeObserver(token) }

        let imperial = LooprDesignSystemRuntimeState(measurementSystem: .imperial)
        DesignSystemRuntime.apply(imperial)
        DesignSystemRuntime.apply(imperial)
        #expect(counter.value == 1)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func bump() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
