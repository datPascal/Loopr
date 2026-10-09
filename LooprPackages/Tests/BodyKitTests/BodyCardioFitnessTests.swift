import Foundation
import Testing
import DomainKit
import DesignSystem
import AnalyticsKit
@testable import BodyKit

struct BodyCardioFitnessTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func estimate() throws -> HeartRateRatioEstimate {
        HeartRateRatioEstimate(vo2Max: 51, lower: 42, upper: 61, restingHeartRate: 55,
            maximumHeartRate: 185, maximumHeartRateSource: .agePredicted, restingNights: 4)
    }

    @Test
    func archivedEstimateIsNeverShown() throws {
        let fitness = BodyCardioFitness(estimate: try estimate(), gap: nil, nightsRemaining: 0, age: 33, referenceGroup: .male)
        #expect(fitness.resolve(appleHealth: [], now: now) == nil)
        #expect(BodyCardioFitnessPresenter.present(fitness, resolution: nil) == BodyCardioFitnessPresenter.empty)
    }

    @Test
    func appleHealthReplacesTheEstimate() throws {
        let day = 86_400.0
        let samples = [0.0, 10, 20].map {
            HealthKitVO2MaxSample(vo2max: 38, sampledAt: now.addingTimeInterval(-$0 * day), sourceIdentifier: "watch", testType: .predictionSubMaxExercise)
        }
        let fitness = BodyCardioFitness(estimate: try estimate(), gap: nil, nightsRemaining: 0, age: 33, referenceGroup: .female)
        let resolution = fitness.resolve(appleHealth: samples, now: now, timeZone: TimeZone(secondsFromGMT: 0)!)
        let shown = BodyCardioFitnessPresenter.present(fitness, resolution: resolution)
        #expect(shown.value == "38")
        #expect(shown.eyebrow == "VO₂ max · from Apple Health")
        #expect(shown.level == .high)
        #expect(resolution?.cardioAge?.isAvailable == true)
    }

    @Test
    func missingInputsGiveHonestEmptyStates() {
        let nights = BodyCardioFitnessPresenter.present(
            BodyCardioFitness(estimate: nil, gap: .needsNights, nightsRemaining: 2, age: 33, referenceGroup: .male), resolution: nil)
        #expect(nights.value == nil)
        #expect(nights.eyebrow == "From Apple Health")
        #expect(nights.state == .absent)
        let age = BodyCardioFitnessPresenter.present(
            BodyCardioFitness(estimate: nil, gap: .needsAge, nightsRemaining: 0, age: nil, referenceGroup: nil), resolution: nil)
        #expect(age.detail.contains("outdoor walk, run or hike"))
        #expect(age.state == .absent)
    }

    @Test
    func noSexMeansNoLevel() throws {
        let fitness = BodyCardioFitness(estimate: try estimate(), gap: nil, nightsRemaining: 0, age: 33, referenceGroup: nil)
        let shown = BodyCardioFitnessPresenter.present(fitness, resolution: fitness.resolve(appleHealth: [], now: now))
        #expect(shown.level == nil)
        #expect(shown == BodyCardioFitnessPresenter.empty)
    }

    @Test
    func snapshotRoundTripsAndOldGenerationsDecode() throws {
        let day = DayIdentity(era: 1, year: 2026, month: 9, day: 23)
        let snapshot = BodyDaySnapshot(day: day, state: .partial, metrics: [],
            composition: BodyCompositionContext(weight: nil, height: nil, bodyFat: nil, state: .absent, source: "test"),
            cardioAge: nil, looprAge: nil, source: "test",
            cardioFitness: BodyCardioFitness(estimate: try estimate(), gap: nil, nightsRemaining: 0, age: 33, referenceGroup: .male))
        let decoded = try JSONDecoder().decode(BodyDaySnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded == snapshot)
        #expect(snapshot.replacingCardioFitness(nil).cardioFitness == nil)

        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as! [String: Any]
        json.removeValue(forKey: "cardioFitness")
        let legacy = try JSONDecoder().decode(BodyDaySnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(legacy.cardioFitness == nil)
    }
}
