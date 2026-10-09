import DomainKit
import XCTest

private struct AgeValue: Sendable, Equatable { let years: Int }
private struct BatteryValue: Sendable, Equatable { let pct: Double }
private struct TestRRQualityValue: Sendable, Equatable { let cleanFraction: Double }
private struct TestHRVValue: Sendable, Equatable { let rmssdMilliseconds: Double }
private struct TestNocturnalRHRValue: Sendable, Equatable { let bpm: Double }
private struct TestRespirationValue: Sendable, Equatable { let brpm: Double }
private struct TestSleepDerivationValue: Sendable, Equatable {
    let algorithmVersion: String
    let segmentationPresent: Bool
    let segmentationIsPartial: Bool
    let hasAccounting: Bool
    let hasHypnogram: Bool
}

private actor AgeRepositoryDouble: CanonicalAgeResultRepository {
    typealias Value = AgeValue
    var value: AgeValue?
    init(value: AgeValue? = nil) { self.value = value }
    func readLatestAgeResult() async throws -> AgeValue? { value }
}

private actor BatteryRepositoryDouble: CanonicalBatteryForecastRepository {
    typealias Value = BatteryValue
    var value: BatteryValue?
    init(value: BatteryValue? = nil) { self.value = value }
    func readLatestBatteryForecast() async throws -> BatteryValue? { value }
}

private actor AnalyticsRepositoryDouble: CanonicalAnalyticsRepository {
    typealias RRQualityValue = TestRRQualityValue
    typealias HRVValue = TestHRVValue
    typealias NocturnalRHRValue = TestNocturnalRHRValue
    typealias RespirationValue = TestRespirationValue

    let rrQuality: RRQualityValue?
    let hrv: HRVValue?
    let nocturnalRHR: NocturnalRHRValue?
    let respiration: RespirationValue?

    init(
        rrQuality: RRQualityValue? = nil,
        hrv: HRVValue? = nil,
        nocturnalRHR: NocturnalRHRValue? = nil,
        respiration: RespirationValue? = nil
    ) {
        self.rrQuality = rrQuality
        self.hrv = hrv
        self.nocturnalRHR = nocturnalRHR
        self.respiration = respiration
    }

    func readLatestRRQuality() async throws -> RRQualityValue? { rrQuality }
    func readLatestHRV() async throws -> HRVValue? { hrv }
    func readLatestNocturnalRHR() async throws -> NocturnalRHRValue? { nocturnalRHR }
    func readLatestRespiration() async throws -> RespirationValue? { respiration }
}

private actor SleepRepositoryDouble: CanonicalSleepAnalyticsRepository {
    typealias Value = TestSleepDerivationValue
    let derivation: Value?

    init(derivation: Value? = nil) { self.derivation = derivation }

    func readLatestSleepDerivation() async throws -> Value? { derivation }
}

final class CanonicalAnalyticsRepositoryTests: XCTestCase {
    func testDomainKitExposesOneTypedAgeReadMethod() async {
        let repository = AgeRepositoryDouble(value: AgeValue(years: 42))
        let value = try? await repository.readLatestAgeResult()
        XCTAssertEqual(value, AgeValue(years: 42))
    }

    func testDomainKitExposesOneTypedBatteryReadMethod() async {
        let repository = BatteryRepositoryDouble(value: BatteryValue(pct: 80))
        let value = try? await repository.readLatestBatteryForecast()
        XCTAssertEqual(value, BatteryValue(pct: 80))
    }

    func testDomainKitExposesOneCanonicalReadPathForANA02Outputs() async {
        let repository = AnalyticsRepositoryDouble(
            rrQuality: TestRRQualityValue(cleanFraction: 0.98),
            hrv: TestHRVValue(rmssdMilliseconds: 42),
            nocturnalRHR: TestNocturnalRHRValue(bpm: 55),
            respiration: TestRespirationValue(brpm: 14)
        )

        let rrQuality = try? await repository.readLatestRRQuality()
        let hrv = try? await repository.readLatestHRV()
        let nocturnalRHR = try? await repository.readLatestNocturnalRHR()
        let respiration = try? await repository.readLatestRespiration()
        XCTAssertEqual(rrQuality, TestRRQualityValue(cleanFraction: 0.98))
        XCTAssertEqual(hrv, TestHRVValue(rmssdMilliseconds: 42))
        XCTAssertEqual(nocturnalRHR, TestNocturnalRHRValue(bpm: 55))
        XCTAssertEqual(respiration, TestRespirationValue(brpm: 14))
    }

    func testCanonicalAnalyticsRepositoryPreservesAbsence() async {
        let repository = AnalyticsRepositoryDouble()
        let rrQuality = try? await repository.readLatestRRQuality()
        let hrv = try? await repository.readLatestHRV()
        let nocturnalRHR = try? await repository.readLatestNocturnalRHR()
        let respiration = try? await repository.readLatestRespiration()
        XCTAssertNil(rrQuality)
        XCTAssertNil(hrv)
        XCTAssertNil(nocturnalRHR)
        XCTAssertNil(respiration)
    }

    func testDomainKitExposesOneCanonicalReadPathForSharedSleepDerivation() async {
        let derivation = TestSleepDerivationValue(
            algorithmVersion: "loopr.sleep.1",
            segmentationPresent: true,
            segmentationIsPartial: false,
            hasAccounting: true,
            hasHypnogram: true
        )
        let repository = SleepRepositoryDouble(derivation: derivation)
        let value = try? await repository.readLatestSleepDerivation()
        XCTAssertEqual(value, derivation)
    }

    func testCanonicalSleepRepositoryPreservesAbsence() async {
        let repository = SleepRepositoryDouble()
        let value = try? await repository.readLatestSleepDerivation()
        XCTAssertNil(value)
    }
}
